#!/usr/bin/env python3
"""Run a command with bounded timeout and explicit process-tree cancellation."""

from __future__ import annotations

import os
import signal
import subprocess
import time
from dataclasses import dataclass
from typing import Mapping

from cancellation import CancellationToken, OperationCancelledError


class ProcessTimeoutError(RuntimeError):
    """Raised after a cancellable process exceeds its deadline."""


@dataclass(frozen=True)
class CancellableProcessResult:
    returncode: int
    stdout: bytes
    stderr: bytes
    elapsed_ms: float


def _stop_process_tree(process: subprocess.Popen[bytes]) -> None:
    if process.poll() is not None:
        return
    try:
        if os.name == "nt":
            subprocess.run(
                ["taskkill", "/PID", str(process.pid), "/T", "/F"],
                stdout=subprocess.DEVNULL,
                stderr=subprocess.DEVNULL,
                check=False,
                timeout=3,
            )
        else:
            os.killpg(process.pid, signal.SIGTERM)
    except (OSError, subprocess.SubprocessError):
        try:
            process.terminate()
        except OSError:
            pass
    try:
        process.wait(timeout=1)
    except subprocess.TimeoutExpired:
        try:
            process.kill()
        except OSError:
            pass


def run_cancellable_process(
    command: str,
    *,
    input_data: bytes,
    timeout_ms: int,
    cancellation: CancellationToken | None = None,
    env: Mapping[str, str] | None = None,
) -> CancellableProcessResult:
    token = cancellation or CancellationToken()
    token.raise_if_cancelled()
    started = time.perf_counter()
    deadline = started + max(1, timeout_ms) / 1000.0
    process = subprocess.Popen(
        command,
        stdin=subprocess.PIPE,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        shell=True,
        env=dict(env) if env is not None else None,
        creationflags=subprocess.CREATE_NEW_PROCESS_GROUP if os.name == "nt" else 0,
        start_new_session=os.name != "nt",
    )
    first_communicate = True
    while True:
        if token.cancelled:
            _stop_process_tree(process)
            try:
                process.communicate(timeout=1)
            except subprocess.SubprocessError:
                pass
            raise OperationCancelledError(token.reason)
        remaining = deadline - time.perf_counter()
        if remaining <= 0:
            _stop_process_tree(process)
            try:
                process.communicate(timeout=1)
            except subprocess.SubprocessError:
                pass
            raise ProcessTimeoutError(f"command timed out after {timeout_ms} ms")
        try:
            stdout, stderr = process.communicate(
                input=input_data if first_communicate else None,
                timeout=min(0.05, remaining),
            )
            elapsed_ms = (time.perf_counter() - started) * 1000.0
            return CancellableProcessResult(process.returncode, stdout, stderr, elapsed_ms)
        except subprocess.TimeoutExpired:
            first_communicate = False
