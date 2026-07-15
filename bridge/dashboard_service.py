#!/usr/bin/env python3
"""Loopback-only browser dashboard for the Stackchan PC bridge."""

from __future__ import annotations

import argparse
import ipaddress
import json
import threading
import time
import urllib.error
import urllib.request
from dataclasses import dataclass
from datetime import datetime, timezone
from http import HTTPStatus
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path


DEFAULT_DASHBOARD_HOST = "127.0.0.1"
DEFAULT_DASHBOARD_PORT = 8766
DEFAULT_ROBOT_HTTP_PORT = 8789
MAX_REQUEST_BYTES = 4096
DASHBOARD_DIR = Path(__file__).resolve().parent / "dashboard"

HEARTBEAT_FIELDS = {
    "robot_mode",
    "emotion_arousal",
    "emotion_valence",
    "emotion_focus",
    "emotion_fatigue",
    "external_power",
    "battery_percent",
    "charging_state",
    "energy_state",
    "motion_enabled",
    "speaker_active",
    "imu_picked_up",
    "touch_ready",
    "camera_enabled",
    "camera_active",
    "camera_target_fresh",
    "chip_temp_c",
}

DEBUG_FIELDS = {
    "schema",
    "network_state",
    "bridge_state",
    "motion_enabled",
    "motion_actuator_ready",
    "motion_last_reason",
    "motion_thermal_suppressed",
    "motion_power_suppressed",
    "servo_rail_enabled",
    "servo_torque_enabled",
    "power_vbus_mv",
    "battery_percent",
    "chip_temp_c",
    "touch_ready",
    "camera_enabled",
    "camera_active",
    "bridge_uplink_ready",
    "bridge_uplink_active",
    "network_error",
}

MODE_NAMES = {
    0: "Booting",
    1: "Idle",
    2: "Attending",
    3: "Listening",
    4: "Thinking",
    5: "Speaking",
    6: "Reacting",
    7: "Sleeping",
    8: "Error",
}


def _utc_now() -> str:
    return datetime.now(timezone.utc).isoformat()


def _safe_host(value: str) -> str:
    host = str(value or "").strip()
    if not host:
        return ""
    try:
        return str(ipaddress.ip_address(host))
    except ValueError:
        if len(host) > 253 or any(part == "" for part in host.split(".")):
            raise ValueError("robot host must be an IP address or DNS name")
        if not all(part.replace("-", "").isalnum() for part in host.split(".")):
            raise ValueError("robot host must be an IP address or DNS name")
        return host.lower()


def _json_value(value: object) -> object:
    if isinstance(value, (str, int, float, bool)) or value is None:
        return value
    return str(value)[:160]


@dataclass(frozen=True)
class DashboardConfig:
    host: str = DEFAULT_DASHBOARD_HOST
    port: int = DEFAULT_DASHBOARD_PORT
    robot_host: str = ""
    robot_http_port: int = DEFAULT_ROBOT_HTTP_PORT
    bridge_host: str = "0.0.0.0"
    bridge_port: int = 8765
    runner_profile: str = "gemma4-e2b-gguf"
    tts_voice: str = ""
    research_enabled: bool = False


class DashboardRuntime:
    """Thread-safe, aggregate-only dashboard state and robot control adapter."""

    def __init__(self, config: DashboardConfig):
        self.config = config
        self._lock = threading.RLock()
        self._started_at = time.monotonic()
        self._bridge_listening = False
        self._robot_connected = False
        self._robot_peer_host = ""
        self._robot_peer_port = 0
        self._last_heartbeat_at = 0.0
        self._last_heartbeat_utc = ""
        self._heartbeat: dict[str, object] = {}
        self._debug: dict[str, object] = {}
        self._debug_at_utc = ""
        self._last_action: dict[str, object] = {}
        self._event_id = 0
        self._events: list[dict[str, object]] = []
        self._add_event("Dashboard ready", "system")

    def _add_event(self, message: str, kind: str = "info") -> None:
        self._event_id += 1
        self._events.append(
            {"id": self._event_id, "at": _utc_now(), "kind": kind, "message": str(message)[:180]}
        )
        self._events = self._events[-20:]

    def set_bridge_listening(self, listening: bool) -> None:
        with self._lock:
            if self._bridge_listening != bool(listening):
                self._add_event("Bridge listener online" if listening else "Bridge listener stopped", "bridge")
            self._bridge_listening = bool(listening)

    def note_client_connected(self, host: str, port: int) -> None:
        with self._lock:
            self._robot_connected = True
            self._robot_peer_host = _safe_host(host)
            self._robot_peer_port = int(port)
            self._add_event(f"Robot link connected from {self._robot_peer_host}", "robot")

    def note_client_disconnected(self, host: str) -> None:
        with self._lock:
            if not host or self._robot_peer_host == str(host):
                self._robot_connected = False
                self._add_event("Robot link disconnected", "warning")

    def note_heartbeat(self, heartbeat: dict[str, object]) -> None:
        if str(heartbeat.get("type", "")).strip().lower() != "heartbeat":
            return
        filtered = {key: _json_value(heartbeat.get(key)) for key in HEARTBEAT_FIELDS if key in heartbeat}
        with self._lock:
            self._heartbeat = filtered
            self._last_heartbeat_at = time.monotonic()
            self._last_heartbeat_utc = _utc_now()

    def _robot_host(self) -> str:
        configured = _safe_host(self.config.robot_host)
        with self._lock:
            return configured or self._robot_peer_host

    def _robot_url(self, path: str) -> str:
        host = self._robot_host()
        if not host:
            raise RuntimeError("robot host is unavailable until Stackchan connects")
        url_host = f"[{host}]" if ":" in host else host
        return f"http://{url_host}:{int(self.config.robot_http_port)}{path}"

    def _fetch_robot(self, path: str, timeout: float = 4.0) -> dict[str, object]:
        request = urllib.request.Request(
            self._robot_url(path),
            headers={"Accept": "application/json", "Connection": "close"},
            method="GET",
        )
        try:
            with urllib.request.urlopen(request, timeout=timeout) as response:
                if response.status != HTTPStatus.OK:
                    raise RuntimeError(f"robot returned HTTP {response.status}")
                payload = response.read(512 * 1024)
        except (urllib.error.URLError, TimeoutError, OSError) as exc:
            reason = getattr(exc, "reason", exc)
            raise RuntimeError(f"robot control request failed: {reason}") from exc
        try:
            parsed = json.loads(payload.decode("utf-8"))
        except (UnicodeDecodeError, json.JSONDecodeError) as exc:
            raise RuntimeError("robot returned an invalid status response") from exc
        if not isinstance(parsed, dict):
            raise RuntimeError("robot returned an invalid status object")
        return parsed

    def _record_debug(self, debug: dict[str, object]) -> None:
        filtered = {key: _json_value(debug.get(key)) for key in DEBUG_FIELDS if key in debug}
        with self._lock:
            self._debug = filtered
            self._debug_at_utc = _utc_now()
            if debug.get("bridge_state") == "ready" and debug.get("network_state") == "connected":
                self._robot_connected = True

    def refresh_robot(self) -> dict[str, object]:
        try:
            debug = self._fetch_robot("/debug")
            self._record_debug(debug)
            with self._lock:
                self._add_event("Robot status refreshed", "robot")
            return {"ok": True, "verified": True, "status": self.status()}
        except RuntimeError as exc:
            with self._lock:
                if not self._bridge_listening:
                    self._robot_connected = False
                    self._debug["network_state"] = "unknown"
                    self._debug["bridge_state"] = "unknown"
                self._add_event(str(exc), "error")
            return {"ok": False, "verified": False, "error": str(exc), "status": self.status()}

    @staticmethod
    def _motion_matches(debug: dict[str, object], enabled: bool) -> bool:
        if enabled:
            return (
                debug.get("motion_enabled") is True
                and debug.get("servo_rail_enabled") is True
                and debug.get("servo_torque_enabled") is True
                and debug.get("motion_thermal_suppressed") is not True
                and debug.get("motion_power_suppressed") is not True
            )
        return (
            debug.get("motion_enabled") is False
            and debug.get("servo_rail_enabled") is False
            and debug.get("servo_torque_enabled") is False
        )

    def set_motion(self, enabled: bool, confirmation: str = "") -> dict[str, object]:
        if enabled and confirmation != "robot_clear":
            return {
                "ok": False,
                "verified": False,
                "error": "motion resume requires robot-clear confirmation",
                "status": self.status(),
            }

        target = "enabled" if enabled else "stopped"
        endpoint = "/motion-resume" if enabled else "/motion-stop"
        command_sent = False
        accepted = False
        debug: dict[str, object] = {}
        error = ""
        try:
            command = self._fetch_robot(endpoint)
            command_sent = True
            accepted = command.get("debug_motion_accepted") is True
            for attempt in range(6):
                if attempt:
                    time.sleep(0.2)
                debug = self._fetch_robot("/debug")
                self._record_debug(debug)
                if self._motion_matches(debug, enabled):
                    break
            verified = self._motion_matches(debug, enabled)
            if not accepted:
                error = "robot did not accept the motion command"
            elif not verified:
                error = f"robot did not verify motion {target}"
        except RuntimeError as exc:
            verified = False
            error = str(exc)

        result = {
            "ok": bool(command_sent and accepted and verified),
            "commandSent": command_sent,
            "accepted": accepted,
            "verified": verified,
            "targetEnabled": enabled,
            "error": error,
        }
        with self._lock:
            self._last_action = {**result, "at": _utc_now()}
            if result["ok"]:
                self._add_event(f"Motion {target} and verified", "motion")
            else:
                self._add_event(error or f"Motion {target} was not verified", "error")
        result["status"] = self.status()
        return result

    def status(self) -> dict[str, object]:
        with self._lock:
            heartbeat = dict(self._heartbeat)
            debug = dict(self._debug)
            heartbeat_age = (
                max(0.0, time.monotonic() - self._last_heartbeat_at)
                if self._last_heartbeat_at
                else None
            )
            motion = debug.get("motion_enabled", heartbeat.get("motion_enabled"))
            robot_mode = heartbeat.get("robot_mode")
            try:
                mode_name = MODE_NAMES.get(int(robot_mode), "Unknown")
            except (TypeError, ValueError):
                mode_name = "Unknown"
            robot_connected = self._robot_connected or (
                debug.get("network_state") == "connected" and debug.get("bridge_state") == "ready"
            )
            return {
                "schema": "stackchan.bridge-dashboard.v1",
                "generatedAt": _utc_now(),
                "bridge": {
                    "listening": self._bridge_listening,
                    "connected": robot_connected,
                    "host": self.config.bridge_host,
                    "port": self.config.bridge_port,
                    "uptimeSeconds": int(max(0.0, time.monotonic() - self._started_at)),
                    "runnerProfile": self.config.runner_profile,
                    "ttsVoice": self.config.tts_voice,
                    "researchEnabled": self.config.research_enabled,
                    "networkState": debug.get("network_state", "unknown"),
                    "bridgeState": debug.get("bridge_state", "unknown"),
                },
                "robot": {
                    "connected": robot_connected,
                    "host": _safe_host(self.config.robot_host) or self._robot_peer_host,
                    "lastHeartbeatAt": self._last_heartbeat_utc,
                    "heartbeatAgeSeconds": round(heartbeat_age, 1) if heartbeat_age is not None else None,
                    "mode": mode_name,
                    "motionEnabled": motion if isinstance(motion, bool) else None,
                    "motionVerified": "motion_enabled" in debug,
                    "servoRailEnabled": debug.get("servo_rail_enabled"),
                    "servoTorqueEnabled": debug.get("servo_torque_enabled"),
                    "batteryPercent": heartbeat.get("battery_percent", debug.get("battery_percent")),
                    "externalPower": heartbeat.get("external_power"),
                    "chipTempC": heartbeat.get("chip_temp_c", debug.get("chip_temp_c")),
                    "powerVbusMv": debug.get("power_vbus_mv"),
                    "touchReady": heartbeat.get("touch_ready", debug.get("touch_ready")),
                    "cameraEnabled": heartbeat.get("camera_enabled", debug.get("camera_enabled")),
                    "cameraActive": heartbeat.get("camera_active", debug.get("camera_active")),
                    "speakerActive": heartbeat.get("speaker_active"),
                    "held": heartbeat.get("imu_picked_up"),
                    "thermalSuppressed": debug.get("motion_thermal_suppressed"),
                    "powerSuppressed": debug.get("motion_power_suppressed"),
                    "lastMotionReason": debug.get("motion_last_reason", ""),
                    "debugAt": self._debug_at_utc,
                },
                "lastAction": dict(self._last_action),
                "events": list(reversed(self._events[-8:])),
            }


class DashboardHttpServer(ThreadingHTTPServer):
    daemon_threads = True
    allow_reuse_address = True

    def __init__(self, address: tuple[str, int], runtime: DashboardRuntime):
        self.runtime = runtime
        super().__init__(address, dashboard_handler(runtime))


def dashboard_handler(runtime: DashboardRuntime) -> type[BaseHTTPRequestHandler]:
    class Handler(BaseHTTPRequestHandler):
        server_version = "StackchanDashboard/1"

        def log_message(self, format: str, *args: object) -> None:
            print(f"[bridge-dashboard] {self.address_string()} {format % args}", flush=True)

        def _security_headers(self, content_type: str, content_length: int) -> None:
            self.send_header("Content-Type", content_type)
            self.send_header("Content-Length", str(content_length))
            self.send_header("Cache-Control", "no-store")
            self.send_header("X-Content-Type-Options", "nosniff")
            self.send_header("X-Frame-Options", "DENY")
            self.send_header("Referrer-Policy", "no-referrer")
            self.send_header(
                "Content-Security-Policy",
                "default-src 'self'; connect-src 'self'; img-src 'self' data:; "
                "style-src 'self'; script-src 'self'; object-src 'none'; "
                "base-uri 'none'; frame-ancestors 'none'; form-action 'none'",
            )

        def _send_bytes(self, status: int, payload: bytes, content_type: str) -> None:
            self.send_response(status)
            self._security_headers(content_type, len(payload))
            self.end_headers()
            if self.command != "HEAD":
                self.wfile.write(payload)

        def _send_json(self, status: int, payload: dict[str, object]) -> None:
            data = json.dumps(payload, separators=(",", ":"), ensure_ascii=True).encode("utf-8")
            self._send_bytes(status, data, "application/json; charset=utf-8")

        def _same_origin(self) -> bool:
            origin = self.headers.get("Origin", "")
            if not origin:
                return True
            allowed = {
                f"http://{runtime.config.host}:{runtime.config.port}",
                f"http://localhost:{runtime.config.port}",
                f"http://127.0.0.1:{runtime.config.port}",
            }
            return origin.rstrip("/") in allowed

        def _read_json(self) -> dict[str, object] | None:
            if not self._same_origin() or self.headers.get("X-Stackchan-Dashboard") != "1":
                self._send_json(HTTPStatus.FORBIDDEN, {"ok": False, "error": "request origin rejected"})
                return None
            if not self.headers.get("Content-Type", "").lower().startswith("application/json"):
                self._send_json(HTTPStatus.UNSUPPORTED_MEDIA_TYPE, {"ok": False, "error": "JSON required"})
                return None
            try:
                length = int(self.headers.get("Content-Length", "0"))
            except ValueError:
                length = -1
            if length < 0 or length > MAX_REQUEST_BYTES:
                self._send_json(HTTPStatus.REQUEST_ENTITY_TOO_LARGE, {"ok": False, "error": "request too large"})
                return None
            try:
                payload = json.loads(self.rfile.read(length).decode("utf-8") or "{}")
            except (UnicodeDecodeError, json.JSONDecodeError):
                self._send_json(HTTPStatus.BAD_REQUEST, {"ok": False, "error": "invalid JSON"})
                return None
            if not isinstance(payload, dict):
                self._send_json(HTTPStatus.BAD_REQUEST, {"ok": False, "error": "JSON object required"})
                return None
            return payload

        def do_OPTIONS(self) -> None:
            self.send_response(HTTPStatus.NO_CONTENT)
            self.send_header("Allow", "GET, HEAD, POST, OPTIONS")
            self.send_header("Content-Length", "0")
            self.send_header("X-Frame-Options", "DENY")
            self.end_headers()

        def do_HEAD(self) -> None:
            self.do_GET()

        def do_GET(self) -> None:
            if self.path == "/api/status":
                self._send_json(HTTPStatus.OK, runtime.status())
                return
            assets = {
                "/": ("index.html", "text/html; charset=utf-8"),
                "/index.html": ("index.html", "text/html; charset=utf-8"),
                "/styles.css": ("styles.css", "text/css; charset=utf-8"),
                "/app.js": ("app.js", "text/javascript; charset=utf-8"),
            }
            asset = assets.get(self.path)
            if not asset:
                self._send_json(HTTPStatus.NOT_FOUND, {"ok": False, "error": "not found"})
                return
            try:
                data = (DASHBOARD_DIR / asset[0]).read_bytes()
            except OSError:
                self._send_json(HTTPStatus.INTERNAL_SERVER_ERROR, {"ok": False, "error": "dashboard asset missing"})
                return
            self._send_bytes(HTTPStatus.OK, data, asset[1])

        def do_POST(self) -> None:
            payload = self._read_json()
            if payload is None:
                return
            if self.path == "/api/refresh":
                result = runtime.refresh_robot()
                self._send_json(HTTPStatus.OK if result["ok"] else HTTPStatus.BAD_GATEWAY, result)
                return
            if self.path == "/api/motion":
                enabled = payload.get("enabled")
                if not isinstance(enabled, bool):
                    self._send_json(HTTPStatus.BAD_REQUEST, {"ok": False, "error": "enabled must be boolean"})
                    return
                result = runtime.set_motion(enabled, str(payload.get("confirmation", "")))
                self._send_json(HTTPStatus.OK if result["ok"] else HTTPStatus.CONFLICT, result)
                return
            self._send_json(HTTPStatus.NOT_FOUND, {"ok": False, "error": "not found"})

    return Handler


def start_dashboard_server(runtime: DashboardRuntime) -> tuple[DashboardHttpServer, threading.Thread]:
    server = DashboardHttpServer((runtime.config.host, runtime.config.port), runtime)
    thread = threading.Thread(target=server.serve_forever, name="stackchan-dashboard", daemon=True)
    thread.start()
    print(f"[bridge-dashboard] listening http://{runtime.config.host}:{runtime.config.port}/", flush=True)
    return server, thread


def stop_dashboard_server(server: DashboardHttpServer, thread: threading.Thread) -> None:
    server.shutdown()
    server.server_close()
    thread.join(timeout=3.0)


def build_arg_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description="Run the local Stackchan bridge dashboard.")
    parser.add_argument("--host", default=DEFAULT_DASHBOARD_HOST)
    parser.add_argument("--port", type=int, default=DEFAULT_DASHBOARD_PORT)
    parser.add_argument("--robot-host", required=True)
    parser.add_argument("--robot-http-port", type=int, default=DEFAULT_ROBOT_HTTP_PORT)
    parser.add_argument("--bridge-host", default="0.0.0.0")
    parser.add_argument("--bridge-port", type=int, default=8765)
    parser.add_argument("--runner-profile", default="gemma4-e2b-gguf")
    parser.add_argument("--tts-voice", default="")
    parser.add_argument("--research-enabled", action="store_true")
    return parser


def main() -> int:
    args = build_arg_parser().parse_args()
    if args.host not in {"127.0.0.1", "::1", "localhost"}:
        raise SystemExit("Dashboard must bind to a loopback host.")
    runtime = DashboardRuntime(
        DashboardConfig(
            host=args.host,
            port=args.port,
            robot_host=_safe_host(args.robot_host),
            robot_http_port=args.robot_http_port,
            bridge_host=args.bridge_host,
            bridge_port=args.bridge_port,
            runner_profile=args.runner_profile,
            tts_voice=args.tts_voice,
            research_enabled=args.research_enabled,
        )
    )
    runtime.refresh_robot()
    server = DashboardHttpServer((args.host, args.port), runtime)
    print(f"[bridge-dashboard] listening http://{args.host}:{args.port}/", flush=True)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        server.server_close()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
