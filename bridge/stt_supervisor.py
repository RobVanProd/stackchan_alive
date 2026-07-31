#!/usr/bin/env python3
"""Health supervision and bounded recovery for a local STT server."""

from __future__ import annotations

import json
import os
import shlex
import subprocess
import threading
import time
import urllib.error
import urllib.request
from collections.abc import Callable
from dataclasses import dataclass
from datetime import datetime, timezone
from typing import Any


def _utc_now() -> str:
    return datetime.now(timezone.utc).isoformat()


def _health_url(server_url: str) -> str:
    return f"{str(server_url).rstrip('/')}/health"


def probe_stt_health(server_url: str, timeout_seconds: float) -> bool:
    request = urllib.request.Request(
        _health_url(server_url),
        headers={"Accept": "application/json", "Connection": "close"},
        method="GET",
    )
    try:
        with urllib.request.urlopen(request, timeout=timeout_seconds) as response:
            if response.status != 200:
                return False
            payload = response.read(16 * 1024)
    except (urllib.error.URLError, TimeoutError, OSError):
        return False
    try:
        parsed = json.loads(payload.decode("utf-8"))
    except (UnicodeDecodeError, json.JSONDecodeError):
        return False
    return isinstance(parsed, dict) and str(parsed.get("status", "")).lower() == "ok"


def run_restart_command(command: str, _timeout_seconds: float) -> int:
    if not str(command).strip():
        raise ValueError("STT restart command is empty")
    args: str | list[str]
    if os.name == "nt":
        args = command
    else:
        args = shlex.split(command)
    process = subprocess.Popen(
        args,
        stdin=subprocess.DEVNULL,
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
        shell=False,
        close_fds=True,
        creationflags=subprocess.CREATE_NO_WINDOW if os.name == "nt" else 0,
        start_new_session=os.name != "nt",
    )
    return int(process.pid)


@dataclass(frozen=True)
class SttSupervisorConfig:
    server_url: str
    restart_command: str = ""
    health_interval_seconds: float = 2.0
    health_timeout_seconds: float = 0.75
    failure_threshold: int = 2
    restart_backoff_seconds: float = 15.0
    restart_timeout_seconds: float = 45.0

    def __post_init__(self) -> None:
        if not str(self.server_url).strip():
            raise ValueError("STT supervisor requires a server URL")
        if not 0.25 <= float(self.health_interval_seconds) <= 60.0:
            raise ValueError("STT health interval must be between 0.25 and 60 seconds")
        if not 0.1 <= float(self.health_timeout_seconds) <= 10.0:
            raise ValueError("STT health timeout must be between 0.1 and 10 seconds")
        if not 1 <= int(self.failure_threshold) <= 10:
            raise ValueError("STT failure threshold must be between 1 and 10")
        if not 1.0 <= float(self.restart_backoff_seconds) <= 600.0:
            raise ValueError("STT restart backoff must be between 1 and 600 seconds")
        if not 5.0 <= float(self.restart_timeout_seconds) <= 180.0:
            raise ValueError("STT restart timeout must be between 5 and 180 seconds")


class SttServerSupervisor:
    """Keep a cached health state and recover a failed local STT process."""

    def __init__(
        self,
        config: SttSupervisorConfig,
        *,
        health_probe: Callable[[str, float], bool] = probe_stt_health,
        restart_runner: Callable[[str, float], int] = run_restart_command,
    ):
        self.config = config
        self._health_probe = health_probe
        self._restart_runner = restart_runner
        self._state_lock = threading.RLock()
        self._check_lock = threading.Lock()
        self._stop = threading.Event()
        self._thread: threading.Thread | None = None
        self._healthy: bool | None = None
        self._checks = 0
        self._failures = 0
        self._consecutive_failures = 0
        self._restarts = 0
        self._restart_failures = 0
        self._recovering = False
        self._last_check_at = ""
        self._last_healthy_at = ""
        self._last_restart_at = ""
        self._last_error = ""
        self._last_restart_monotonic = float("-inf")

    def start(self) -> None:
        with self._state_lock:
            if self._thread is not None and self._thread.is_alive():
                return
            self._stop.clear()
        self.check_once()
        thread = threading.Thread(
            target=self._run,
            name="stackchan-stt-supervisor",
            daemon=True,
        )
        with self._state_lock:
            self._thread = thread
        thread.start()

    def stop(self) -> None:
        self._stop.set()
        with self._state_lock:
            thread = self._thread
        if thread is not None:
            thread.join(timeout=max(2.0, self.config.health_timeout_seconds + 1.0))

    def _run(self) -> None:
        while not self._stop.wait(self.config.health_interval_seconds):
            self.check_once()

    def _probe(self) -> bool:
        try:
            return bool(
                self._health_probe(
                    self.config.server_url,
                    self.config.health_timeout_seconds,
                )
            )
        except Exception:
            return False

    def check_once(self) -> dict[str, object]:
        if not self._check_lock.acquire(blocking=False):
            return self.status()
        try:
            healthy = self._probe()
            now_utc = _utc_now()
            with self._state_lock:
                was_healthy = self._healthy
                self._checks += 1
                self._last_check_at = now_utc
                self._healthy = healthy
                if healthy:
                    self._consecutive_failures = 0
                    self._last_healthy_at = now_utc
                    self._last_error = ""
                else:
                    self._failures += 1
                    self._consecutive_failures += 1
                    self._last_error = "health probe failed"
                should_restart = (
                    not healthy
                    and bool(self.config.restart_command.strip())
                    and self._consecutive_failures >= self.config.failure_threshold
                    and (
                        time.monotonic() - self._last_restart_monotonic
                        >= self.config.restart_backoff_seconds
                    )
                )
            if was_healthy is True and not healthy:
                print("[bridge-stt] health_degraded", flush=True)
            if should_restart:
                self._restart()
            return self.status()
        finally:
            self._check_lock.release()

    def _restart(self) -> None:
        started = time.perf_counter()
        with self._state_lock:
            self._recovering = True
            self._last_restart_monotonic = time.monotonic()
            self._last_restart_at = _utc_now()
        print("[bridge-stt] restart_start", flush=True)
        try:
            launcher_pid = self._restart_runner(
                self.config.restart_command,
                self.config.restart_timeout_seconds,
            )
            if launcher_pid <= 0:
                raise OSError("STT restart launcher did not start")
            recovered = False
            deadline = time.monotonic() + self.config.restart_timeout_seconds
            while not self._stop.is_set() and time.monotonic() < deadline:
                if self._probe():
                    recovered = True
                    break
                time.sleep(0.25)
            with self._state_lock:
                if recovered:
                    self._healthy = True
                    self._consecutive_failures = 0
                    self._restarts += 1
                    self._last_healthy_at = _utc_now()
                    self._last_error = ""
                else:
                    self._healthy = False
                    self._restart_failures += 1
                    self._last_error = "restart failed health verification"
        except (OSError, ValueError) as exc:
            recovered = False
            with self._state_lock:
                self._healthy = False
                self._restart_failures += 1
                self._last_error = f"restart failed: {type(exc).__name__}"
        finally:
            with self._state_lock:
                self._recovering = False
        elapsed_ms = (time.perf_counter() - started) * 1000.0
        outcome = "recovered" if recovered else "failed"
        print(f"[bridge-stt] restart_{outcome} elapsed_ms={elapsed_ms:.1f}", flush=True)

    def status(self) -> dict[str, Any]:
        with self._state_lock:
            return {
                "configured": True,
                "healthy": self._healthy,
                "supervised": bool(self.config.restart_command.strip()),
                "recovering": self._recovering,
                "checks": self._checks,
                "failures": self._failures,
                "consecutiveFailures": self._consecutive_failures,
                "restarts": self._restarts,
                "restartFailures": self._restart_failures,
                "lastCheckAt": self._last_check_at,
                "lastHealthyAt": self._last_healthy_at,
                "lastRestartAt": self._last_restart_at,
                "lastError": self._last_error,
            }
