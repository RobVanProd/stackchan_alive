#!/usr/bin/env python3
"""LAN WebSocket bridge smoke report.

This exercises the real TCP/WebSocket handshake and frame path with a temporary
single-client server. It is a no-hardware proxy, not a replacement for CoreS3
bench evidence.
"""

from __future__ import annotations

import argparse
import base64
import json
import os
import queue
import socket
import sys
import tempfile
import threading
import time
from contextlib import contextmanager
from dataclasses import dataclass, field
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Iterable

from lan_service import BridgeControlState, LanBridgeConfig, WebSocketProtocolError, handle_connection, read_ws_frame
from local_runner import GENERIC_COMMAND_ENV, RUNNER_PROFILES
from reference_bridge import PROTOCOL, BridgeMemory
from stt_adapter import STT_COMMAND_ENV
from tts_adapter import DEFAULT_TTS_VOICE, TTS_COMMAND_ENV

SCHEMA = "stackchan.lan-smoke.v1"
DEFAULT_OUT_DIR = Path("output/lan-smoke/latest")
DEFAULT_SCENARIOS = ("text-turn", "audio-loop", "thinking-latency", "endpoint-controls", "owner-failover")
CLIENT_MASK = b"\x37\xfa\x21\x3d"
THINKING_LATENCY_MAX_MS = 200.0
DELAYED_RESPONSE_MIN_MS = 250.0
ENV_KEYS_TO_CLEAR = (
    GENERIC_COMMAND_ENV,
    STT_COMMAND_ENV,
    TTS_COMMAND_ENV,
    *(profile["command_env"] for profile in RUNNER_PROFILES.values()),
)


@dataclass
class ReceivedFrame:
    opcode: int
    payload: bytes
    elapsed_ms: float

    @property
    def is_text(self) -> bool:
        return self.opcode == 0x1

    @property
    def is_binary(self) -> bool:
        return self.opcode == 0x2

    def text_payload(self) -> dict[str, Any]:
        return json.loads(self.payload.decode("utf-8"))


@dataclass
class ScenarioResult:
    scenario: str
    status: str = "pass"
    issues: list[str] = field(default_factory=list)
    frames: list[dict[str, Any]] = field(default_factory=list)
    frame_sequence: list[str] = field(default_factory=list)
    frame_timings: list[dict[str, Any]] = field(default_factory=list)
    binary_frames: int = 0
    binary_bytes: int = 0
    elapsed_ms: float = 0.0
    response_text: str = ""
    handshake_status: str = ""
    server_errors: list[str] = field(default_factory=list)
    evidence: dict[str, Any] = field(default_factory=dict)

    def fail(self, issue: str) -> None:
        self.status = "fail"
        self.issues.append(issue)

    def to_dict(self) -> dict[str, Any]:
        return {
            "scenario": self.scenario,
            "status": self.status,
            "issues": list(self.issues),
            "frame_types": [frame.get("type", "") for frame in self.frames],
            "frame_sequence": list(self.frame_sequence),
            "frame_timings": list(self.frame_timings),
            "text_frames": len(self.frames),
            "binary_frames": self.binary_frames,
            "binary_bytes": self.binary_bytes,
            "elapsed_ms": round(self.elapsed_ms, 2),
            "response_text": self.response_text,
            "handshake_status": self.handshake_status,
            "server_errors": list(self.server_errors),
            "evidence": dict(self.evidence),
        }


@contextmanager
def cleared_bridge_env() -> Iterable[None]:
    saved = {key: os.environ.get(key) for key in ENV_KEYS_TO_CLEAR}
    for key in ENV_KEYS_TO_CLEAR:
        os.environ.pop(key, None)
    try:
        yield
    finally:
        for key, value in saved.items():
            if value is None:
                os.environ.pop(key, None)
            else:
                os.environ[key] = value


def utc_timestamp() -> str:
    return datetime.now(timezone.utc).replace(microsecond=0).isoformat().replace("+00:00", "Z")


def encode_client_frame(payload: bytes, opcode: int = 0x1) -> bytes:
    if len(payload) > 65535:
        raise ValueError("client frame payload too large")
    first = 0x80 | (opcode & 0x0F)
    if len(payload) < 126:
        header = bytes([first, 0x80 | len(payload)])
    else:
        header = bytes([first, 0x80 | 126]) + len(payload).to_bytes(2, "big")
    masked = bytes(value ^ CLIENT_MASK[index % len(CLIENT_MASK)] for index, value in enumerate(payload))
    return header + CLIENT_MASK + masked


def encode_client_text(frame: dict[str, Any]) -> bytes:
    payload = json.dumps(frame, separators=(",", ":"), ensure_ascii=True).encode("utf-8")
    return encode_client_frame(payload, opcode=0x1)


def make_handshake(host: str, port: int) -> bytes:
    return (
        "GET /bridge HTTP/1.1\r\n"
        f"Host: {host}:{port}\r\n"
        "Upgrade: websocket\r\n"
        "Connection: Upgrade\r\n"
        "Sec-WebSocket-Key: ZGV2LWxhbi1zbW9rZS1rZXk=\r\n"
        "Sec-WebSocket-Version: 13\r\n"
        "\r\n"
    ).encode("ascii")


def read_handshake_response(sock: socket.socket) -> str:
    data = bytearray()
    while b"\r\n\r\n" not in data:
        # Do not consume a coalesced first WebSocket frame. This helper is also
        # used by pc_brain_probe, whose next read expects the complete frame.
        chunk = sock.recv(1)
        if not chunk:
            raise WebSocketProtocolError("server closed before handshake response")
        data.extend(chunk)
        if len(data) > 8192:
            raise WebSocketProtocolError("handshake response too large")
    return data.decode("iso-8859-1", errors="replace")


class SmokeServer:
    def __init__(self, config: LanBridgeConfig, control_state: BridgeControlState | None = None):
        self.config = config
        self.control_state = control_state
        self.port_queue: queue.Queue[int] = queue.Queue(maxsize=1)
        self.errors: list[str] = []
        self.thread = threading.Thread(target=self._run, daemon=True)

    def __enter__(self) -> "SmokeServer":
        self.thread.start()
        return self

    def __exit__(self, exc_type, exc, tb) -> None:
        self.thread.join(timeout=5.0)
        if self.thread.is_alive():
            self.errors.append("server_thread_left_running")

    def port(self) -> int:
        try:
            return self.port_queue.get(timeout=5.0)
        except queue.Empty as exc:
            raise RuntimeError("LAN smoke server did not bind a port") from exc

    def _run(self) -> None:
        try:
            with socket.create_server((self.config.host, 0), reuse_port=False) as server:
                server.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
                self.port_queue.put(int(server.getsockname()[1]))
                conn, _address = server.accept()
                with conn:
                    handle_connection(conn, self.config, BridgeMemory(), self.control_state)
        except Exception as exc:  # pragma: no cover - surfaced in scenario report
            self.errors.append(f"{type(exc).__name__}: {exc}")


class SmokeClient:
    def __init__(self, host: str, port: int):
        self.host = host
        self.port = port
        self.sock = socket.create_connection((host, port), timeout=5.0)
        self.sock.settimeout(5.0)
        self.started = time.perf_counter()

    def __enter__(self) -> "SmokeClient":
        self.sock.sendall(make_handshake(self.host, self.port))
        response = read_handshake_response(self.sock)
        if "101 Switching Protocols" not in response:
            raise WebSocketProtocolError("server did not accept WebSocket handshake")
        return self

    def __exit__(self, exc_type, exc, tb) -> None:
        try:
            self.sock.sendall(encode_client_frame(b"", opcode=0x8))
            read_ws_frame(self.sock)
        except Exception:
            pass
        self.sock.close()

    def send_text(self, frame: dict[str, Any]) -> None:
        self.sock.sendall(encode_client_text(frame))

    def send_binary(self, payload: bytes) -> None:
        self.sock.sendall(encode_client_frame(payload, opcode=0x2))

    def read(self) -> ReceivedFrame:
        opcode, payload = read_ws_frame(self.sock)
        elapsed_ms = (time.perf_counter() - self.started) * 1000.0
        return ReceivedFrame(opcode=opcode, payload=payload, elapsed_ms=elapsed_ms)

    def read_many(self, stop_types: set[str], max_frames: int = 64) -> list[ReceivedFrame]:
        frames: list[ReceivedFrame] = []
        for _ in range(max_frames):
            received = self.read()
            frames.append(received)
            if received.is_text:
                frame_type = str(received.text_payload().get("type", ""))
                if frame_type in stop_types:
                    return frames
        raise WebSocketProtocolError(f"did not receive {sorted(stop_types)} within {max_frames} frames")


def write_fake_stt(path: Path, transcript: str = "I picked you up gently.") -> str:
    path.write_text(
        "\n".join(
            [
                "import json",
                "import os",
                "import sys",
                "payload = sys.stdin.buffer.read()",
                "if os.environ.get('STACKCHAN_AUDIO_BYTES') != str(len(payload)):",
                "    raise SystemExit('audio byte count mismatch')",
                f"print(json.dumps({{'transcript': {transcript!r}}}))",
            ]
        ),
        encoding="utf-8",
    )
    return f'"{sys.executable}" "{path}"'


def write_fake_tts(path: Path, sleep_ms: int = 0) -> str:
    audio = base64.b64encode((b"stackchan-audio-" * 240)[:3200]).decode("ascii")
    beats = [
        {"env": 0.18, "viseme": "ah", "duration_ms": 40},
        {"env": 0.62, "viseme": "ee", "duration_ms": 45},
        {"env": 0.36, "viseme": "oh", "duration_ms": 50},
        {"env": 0.0, "viseme": "neutral", "duration_ms": 35, "final": True},
    ]
    path.write_text(
        "\n".join(
            [
                "import json",
                "import os",
                "import sys",
                "import time",
                "text = sys.stdin.buffer.read().decode('utf-8')",
                "if not text.strip():",
                "    raise SystemExit('missing TTS text')",
                f"time.sleep({max(0, int(sleep_ms))} / 1000.0)",
                f"audio_b64 = {audio!r}",
                f"beats = {json.dumps(beats, separators=(',', ':'))!r}",
                "print(json.dumps({'audio_format':'pcm16','sample_rate':22050,'audio_b64':audio_b64,'beats':json.loads(beats)}))",
            ]
        ),
        encoding="utf-8",
    )
    return f'"{sys.executable}" "{path}"'


def append_received(result: ScenarioResult, received: ReceivedFrame) -> None:
    if received.is_binary:
        result.binary_frames += 1
        result.binary_bytes += len(received.payload)
        result.frame_sequence.append(f"binary:{len(received.payload)}")
        result.frame_timings.append({"type": "binary", "elapsed_ms": round(received.elapsed_ms, 2)})
        return
    if not received.is_text:
        result.fail(f"unexpected_opcode_{received.opcode}")
        return
    frame = received.text_payload()
    result.frames.append(frame)
    frame_type = str(frame.get("type", ""))
    result.frame_sequence.append(frame_type)
    result.frame_timings.append({"type": frame_type, "elapsed_ms": round(received.elapsed_ms, 2)})
    if frame.get("type") == "response_start":
        result.response_text = str(frame.get("text", ""))


def require_frame(result: ScenarioResult, frame_type: str) -> dict[str, Any] | None:
    for frame in result.frames:
        if frame.get("type") == frame_type:
            return frame
    result.fail(f"missing_{frame_type}")
    return None


def require_order(result: ScenarioResult, ordered: tuple[str, ...]) -> None:
    types = [str(frame.get("type", "")) for frame in result.frames]
    cursor = -1
    for expected in ordered:
        try:
            next_index = types.index(expected, cursor + 1)
        except ValueError:
            result.fail(f"missing_ordered_{expected}")
            return
        cursor = next_index


def receive_session_hello(result: ScenarioResult, client: SmokeClient) -> None:
    append_received(result, client.read())
    if not result.frames or result.frames[-1].get("type") != "hello":
        result.fail("missing_initial_session_hello")


def run_text_turn(host: str, config: LanBridgeConfig) -> ScenarioResult:
    result = ScenarioResult(scenario="text-turn")
    start = time.perf_counter()
    with SmokeServer(config) as server:
        port = server.port()
        with SmokeClient(host, port) as client:
            result.handshake_status = "accepted"
            receive_session_hello(result, client)
            client.send_text({"type": "utterance_start", "seq": 11, "sample_rate": 16000})
            append_received(result, client.read())
            client.send_text({"type": "utterance_end", "seq": 11, "text": "Hello Stackchan."})
            for frame in client.read_many({"response_end"}):
                append_received(result, frame)
        result.server_errors.extend(server.errors)
    result.elapsed_ms = (time.perf_counter() - start) * 1000.0
    validate_text_turn(result)
    return result


def run_audio_loop(host: str, base_config: LanBridgeConfig, temp_dir: Path) -> ScenarioResult:
    result = ScenarioResult(scenario="audio-loop")
    start = time.perf_counter()
    config = LanBridgeConfig(
        host=base_config.host,
        runner_profile=base_config.runner_profile,
        runner_case="greeting",
        stt_command=write_fake_stt(temp_dir / "fake_stt.py"),
        tts_command=write_fake_tts(temp_dir / "fake_tts.py"),
        tts_voice=DEFAULT_TTS_VOICE,
        downlink_audio_chunk_bytes=1024,
        max_audio_bytes=base_config.max_audio_bytes,
    )
    with SmokeServer(config) as server:
        port = server.port()
        with SmokeClient(host, port) as client:
            result.handshake_status = "accepted"
            receive_session_hello(result, client)
            client.send_text({"type": "utterance_start", "seq": 12, "sample_rate": 16000})
            append_received(result, client.read())
            client.send_binary((b"\x01\x00\x02\x00" * 800)[:3200])
            client.send_binary((b"\x03\x00\x04\x00" * 800)[:3200])
            client.send_text({"type": "utterance_end", "seq": 12})
            for frame in client.read_many({"response_end"}):
                append_received(result, frame)
        result.server_errors.extend(server.errors)
    result.elapsed_ms = (time.perf_counter() - start) * 1000.0
    validate_audio_loop(result)
    return result


def run_thinking_latency(host: str, base_config: LanBridgeConfig, temp_dir: Path) -> ScenarioResult:
    result = ScenarioResult(scenario="thinking-latency")
    start = time.perf_counter()
    config = LanBridgeConfig(
        host=base_config.host,
        runner_profile=base_config.runner_profile,
        runner_case="greeting",
        tts_command=write_fake_tts(temp_dir / "fake_tts_slow.py", sleep_ms=350),
        tts_voice=DEFAULT_TTS_VOICE,
        downlink_audio_chunk_bytes=1024,
        max_audio_bytes=base_config.max_audio_bytes,
    )
    with SmokeServer(config) as server:
        port = server.port()
        with SmokeClient(host, port) as client:
            result.handshake_status = "accepted"
            receive_session_hello(result, client)
            client.send_text({"type": "utterance_start", "seq": 13, "sample_rate": 16000})
            append_received(result, client.read())
            result.frame_timings.clear()
            client.started = time.perf_counter()
            client.send_text({"type": "utterance_end", "seq": 13, "text": "Hello Stackchan."})
            append_received(result, client.read())
            for frame in client.read_many({"response_end"}):
                append_received(result, frame)
        result.server_errors.extend(server.errors)
    result.elapsed_ms = (time.perf_counter() - start) * 1000.0
    validate_thinking_latency(result)
    return result


def run_endpoint_controls(host: str, config: LanBridgeConfig) -> ScenarioResult:
    result = ScenarioResult(scenario="endpoint-controls")
    start = time.perf_counter()
    with SmokeServer(config) as server:
        port = server.port()
        with SmokeClient(host, port) as client:
            result.handshake_status = "accepted"
            receive_session_hello(result, client)
            client.send_text(
                {
                    "type": "endpoint_hello",
                    "endpoint_id": "pc-studio-01",
                    "endpoint_name": "Studio PC",
                    "endpoint_kind": "pc",
                    "priority": 80,
                    "supports_binary_audio": True,
                    "capabilities": [
                        "stt",
                        "llm",
                        "tts",
                        "settings",
                        "audio_downlink",
                        "brain_owner",
                    ],
                }
            )
            append_received(result, client.read())
            client.send_text({"type": "claim_brain", "endpoint_id": "pc-studio-01"})
            append_received(result, client.read())
            client.send_text({"type": "settings_get", "domains": ["bridge", "display"]})
            settings_frame = client.read()
            append_received(result, settings_frame)
            version = int(settings_frame.text_payload().get("version", 0))
            client.send_text(
                {
                    "type": "settings_set",
                    "version": version,
                    "settings": {"display": {"reduced_motion": True}},
                }
            )
            append_received(result, client.read())
            client.send_text({"type": "diagnostics_request", "domains": ["bridge", "model"]})
            append_received(result, client.read())
            client.send_text({"type": "trusted_endpoints"})
            append_received(result, client.read())
            client.send_text({"type": "forget_endpoint", "endpoint_id": "pc-studio-01"})
            append_received(result, client.read())
        result.server_errors.extend(server.errors)
    result.elapsed_ms = (time.perf_counter() - start) * 1000.0
    validate_endpoint_controls(result)
    return result


def run_owner_failover(host: str, config: LanBridgeConfig) -> ScenarioResult:
    result = ScenarioResult(scenario="owner-failover")
    start = time.perf_counter()
    control_state = BridgeControlState(owner_lease_ms=1_000)
    with SmokeServer(config, control_state) as server:
        port = server.port()
        with SmokeClient(host, port) as client:
            result.handshake_status = "accepted"
            receive_session_hello(result, client)
            for endpoint_id, endpoint_name, endpoint_kind, priority in (
                ("pc-studio-01", "Studio PC", "pc", 90),
                ("phone-rob-01", "Rob's Phone", "android", 60),
            ):
                client.send_text(
                    {
                        "type": "endpoint_hello",
                        "endpoint_id": endpoint_id,
                        "endpoint_name": endpoint_name,
                        "endpoint_kind": endpoint_kind,
                        "priority": priority,
                        "auto_connect": True,
                        "capabilities": ["brain_owner", "audio_downlink", "settings"],
                    }
                )
                append_received(result, client.read())

            client.send_text({"type": "claim_brain", "endpoint_id": "pc-studio-01"})
            append_received(result, client.read())
            client.send_text(
                {
                    "type": "utterance_start",
                    "endpoint_id": "phone-rob-01",
                    "seq": 21,
                    "sample_rate": 16000,
                }
            )
            append_received(result, client.read())

            time.sleep(1.05)
            client.send_text({"type": "heartbeat", "endpoint_id": "phone-rob-01"})
            append_received(result, client.read())
            client.send_text({"type": "owner_status"})
            append_received(result, client.read())

            client.send_text({"type": "claim_brain", "endpoint_id": "pc-studio-01"})
            append_received(result, client.read())

            time.sleep(1.05)
            client.send_text({"type": "owner_status"})
            append_received(result, client.read())
        result.server_errors.extend(server.errors)
    result.elapsed_ms = (time.perf_counter() - start) * 1000.0
    validate_owner_failover(result)
    return result


def validate_common(result: ScenarioResult) -> None:
    if result.server_errors:
        result.fail("server_errors_present")
    require_frame(result, "hello")
    require_frame(result, "listening")
    require_frame(result, "thinking")
    require_frame(result, "response_start")
    require_frame(result, "response_end")
    require_order(result, ("hello", "listening", "thinking", "response_start", "response_end"))
    errors = [frame for frame in result.frames if frame.get("type") == "error"]
    if errors:
        result.fail("error_frames_present")
    if not result.response_text:
        result.fail("missing_response_text")


def validate_text_turn(result: ScenarioResult) -> None:
    validate_common(result)
    if result.binary_frames != 0:
        result.fail("text_turn_unexpected_binary_frames")


def validate_audio_loop(result: ScenarioResult) -> None:
    validate_common(result)
    thinking = require_frame(result, "thinking") or {}
    response_start = require_frame(result, "response_start") or {}
    stream_start = require_frame(result, "audio_stream_start") or {}
    stream_end = require_frame(result, "audio_stream_end") or {}
    require_order(result, ("response_start", "audio_stream_start", "audio_stream_end", "response_end"))
    if int(thinking.get("audio_bytes", 0)) <= 0:
        result.fail("missing_uploaded_audio_telemetry")
    if str(response_start.get("stt_command_source", "")) != "cli":
        result.fail("fake_stt_not_used")
    expected_bytes = int(stream_start.get("audio_bytes", 0))
    if expected_bytes <= 0:
        result.fail("missing_audio_stream_bytes")
    if result.binary_frames <= 0 or result.binary_bytes != expected_bytes:
        result.fail("binary_downlink_byte_mismatch")
    if stream_end.get("audio_bytes") != stream_start.get("audio_bytes"):
        result.fail("audio_stream_end_mismatch")


def validate_thinking_latency(result: ScenarioResult) -> None:
    validate_common(result)
    if result.frame_sequence[:3] != ["hello", "listening", "thinking"]:
        result.fail("thinking_not_first_after_utterance_end")
    thinking = next((item for item in result.frame_timings if item.get("type") == "thinking"), {})
    response_end = next((item for item in result.frame_timings if item.get("type") == "response_end"), {})
    thinking_ms = float(thinking.get("elapsed_ms", THINKING_LATENCY_MAX_MS + 1.0))
    response_end_ms = float(response_end.get("elapsed_ms", 0.0))
    if thinking_ms > THINKING_LATENCY_MAX_MS:
        result.fail("thinking_latency_too_slow")
    if response_end_ms < DELAYED_RESPONSE_MIN_MS:
        result.fail("delayed_response_not_observed")


def validate_endpoint_controls(result: ScenarioResult) -> None:
    if result.server_errors:
        result.fail("server_errors_present")
    require_order(
        result,
        (
            "endpoint_hello_result",
            "owner_status",
            "settings_snapshot",
            "settings_result",
            "diagnostics_snapshot",
            "trusted_endpoints_result",
            "forget_endpoint_result",
        ),
    )
    owner = require_frame(result, "owner_status") or {}
    settings_result = require_frame(result, "settings_result") or {}
    diagnostics = require_frame(result, "diagnostics_snapshot") or {}
    trusted = require_frame(result, "trusted_endpoints_result") or {}
    forgotten = require_frame(result, "forget_endpoint_result") or {}
    if owner.get("active_brain_owner") != "pc-studio-01":
        result.fail("claim_brain_owner_mismatch")
    if settings_result.get("ok") is not True:
        result.fail("settings_set_failed")
    if diagnostics.get("bridge", {}).get("active_brain_owner") != "pc-studio-01":
        result.fail("diagnostics_owner_mismatch")
    if len(trusted.get("endpoints", [])) != 1:
        result.fail("trusted_endpoint_missing")
    if forgotten.get("ok") is not True or forgotten.get("trusted_endpoint_count") != 0:
        result.fail("forget_endpoint_failed")


def validate_owner_failover(result: ScenarioResult) -> None:
    if result.server_errors:
        result.fail("server_errors_present")
    owners = [frame for frame in result.frames if frame.get("type") == "owner_status"]
    heartbeat = next((frame for frame in result.frames if frame.get("type") == "heartbeat"), {})
    blocked = next((frame for frame in result.frames if frame.get("type") == "error"), {})
    result.evidence = {
        "initial_owner": owners[0].get("active_brain_owner", "") if owners else "",
        "observer_audio_error": blocked.get("code", ""),
        "timeout_owner": heartbeat.get("active_brain_owner", ""),
        "timeout_state": heartbeat.get("owner_state", ""),
        "handback_owner": owners[2].get("active_brain_owner", "") if len(owners) > 2 else "",
        "offline_owner": owners[3].get("active_brain_owner", "") if len(owners) > 3 else "",
        "offline_state": owners[3].get("state", "") if len(owners) > 3 else "",
        "promotion_expirations": owners[1].get("owner_expirations", 0) if len(owners) > 1 else 0,
        "owner_expirations": owners[3].get("owner_expirations", 0) if len(owners) > 3 else 0,
        "owner_promotions": owners[3].get("owner_promotions", 0) if len(owners) > 3 else 0,
    }
    if len(owners) != 4:
        result.fail("owner_status_count_mismatch")
        return
    if owners[0].get("active_brain_owner") != "pc-studio-01" or owners[0].get("state") != "claimed":
        result.fail("initial_pc_claim_failed")
    if blocked.get("code") != "brain_owner_mismatch":
        result.fail("observer_audio_not_blocked")
    if heartbeat.get("active_brain_owner") != "phone-rob-01" or heartbeat.get("owner_state") != "promoted":
        result.fail("phone_timeout_promotion_failed")
    if owners[1].get("active_brain_owner") != "phone-rob-01":
        result.fail("phone_owner_status_mismatch")
    if owners[1].get("owner_expirations") != 1 or owners[1].get("owner_promotions") != 1:
        result.fail("failover_counters_mismatch")
    if owners[2].get("active_brain_owner") != "pc-studio-01" or owners[2].get("state") != "claimed":
        result.fail("explicit_pc_handback_failed")
    if owners[3].get("active_brain_owner") or owners[3].get("state") != "offline":
        result.fail("offline_fallback_failed")
    if owners[3].get("owner_expirations") != 2 or owners[3].get("owner_promotions") != 1:
        result.fail("offline_counters_mismatch")


def build_report(out_dir: Path = DEFAULT_OUT_DIR, scenarios: Iterable[str] = DEFAULT_SCENARIOS) -> dict[str, Any]:
    selected = tuple(scenarios)
    results: list[ScenarioResult] = []
    config = LanBridgeConfig(host="127.0.0.1", runner_case="greeting", require_runner=False)
    with cleared_bridge_env(), tempfile.TemporaryDirectory() as temp:
        temp_dir = Path(temp)
        for scenario in selected:
            if scenario == "text-turn":
                results.append(run_text_turn(config.host, config))
            elif scenario == "audio-loop":
                results.append(run_audio_loop(config.host, config, temp_dir))
            elif scenario == "thinking-latency":
                results.append(run_thinking_latency(config.host, config, temp_dir))
            elif scenario == "endpoint-controls":
                results.append(run_endpoint_controls(config.host, config))
            elif scenario == "owner-failover":
                results.append(run_owner_failover(config.host, config))
            else:
                result = ScenarioResult(scenario=scenario, status="fail")
                result.issues.append("unknown_scenario")
                results.append(result)
    status = "pass" if all(result.status == "pass" for result in results) else "fail"
    return {
        "schema": SCHEMA,
        "generated_at": utc_timestamp(),
        "protocol": PROTOCOL,
        "status": status,
        "scenario_count": len(results),
        "scenarios": [result.to_dict() for result in results],
        "artifacts": {
            "markdown": str(out_dir / "LAN_SMOKE.md"),
            "json": str(out_dir / "lan_smoke.json"),
        },
        "notes": [
            "This report exercises the real local TCP/WebSocket bridge path with deterministic fake engines.",
            "It does not prove Wi-Fi, firmware networking, speaker output, microphone capture, display, servo, or thermal behavior.",
        ],
    }


def render_markdown(report: dict[str, Any]) -> str:
    lines = [
        "# Stackchan LAN Bridge Smoke",
        "",
        f"Schema: `{report['schema']}`",
        f"Generated: `{report['generated_at']}`",
        f"Protocol: `{report['protocol']}`",
        f"Status: `{report['status']}`",
        "",
        "This is the socket-level no-hardware proxy for the P7 brain bridge.",
        "It starts a temporary bridge server, performs a real WebSocket handshake, sends device-style frames, and validates response ordering.",
        "",
        "| Scenario | Status | Text frames | Binary frames | Binary bytes | Key response |",
        "|---|---:|---:|---:|---:|---|",
    ]
    for scenario in report["scenarios"]:
        response = str(scenario.get("response_text", "")).replace("|", "\\|")
        if len(response) > 72:
            response = response[:69] + "..."
        lines.append(
            f"| `{scenario['scenario']}` | `{scenario['status']}` | {scenario['text_frames']} | "
            f"{scenario['binary_frames']} | {scenario['binary_bytes']} | {response} |"
        )
    lines.extend(["", "## Gates", ""])
    for scenario in report["scenarios"]:
        frame_sequence = ", ".join(f"`{item}`" for item in scenario.get("frame_sequence", []))
        lines.append(f"- `{scenario['scenario']}` frame sequence: {frame_sequence}")
        timings = {item.get("type"): item.get("elapsed_ms") for item in scenario.get("frame_timings", [])}
        if scenario.get("scenario") == "thinking-latency":
            lines.append(
                "- `thinking-latency` measured "
                f"`thinking` at {timings.get('thinking', 'n/a')} ms and "
                f"`response_end` at {timings.get('response_end', 'n/a')} ms after `utterance_end`."
            )
        if scenario.get("issues"):
            issues = ", ".join(f"`{item}`" for item in scenario["issues"])
            lines.append(f"- `{scenario['scenario']}` issues: {issues}")
    lines.extend(["", "## Limits", ""])
    for note in report["notes"]:
        lines.append(f"- {note}")
    lines.append("")
    return "\n".join(lines)


def write_outputs(report: dict[str, Any], out_dir: Path = DEFAULT_OUT_DIR) -> dict[str, Path]:
    out_dir.mkdir(parents=True, exist_ok=True)
    json_path = out_dir / "lan_smoke.json"
    markdown_path = out_dir / "LAN_SMOKE.md"
    json_path.write_text(json.dumps(report, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    markdown_path.write_text(render_markdown(report), encoding="utf-8")
    for scenario in report["scenarios"]:
        scenario_path = out_dir / f"{scenario['scenario']}.json"
        scenario_path.write_text(json.dumps(scenario, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    return {"json": json_path, "markdown": markdown_path}


def build_arg_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description="Run a deterministic LAN WebSocket bridge smoke check.")
    parser.add_argument("--out-dir", type=Path, default=DEFAULT_OUT_DIR)
    parser.add_argument("--scenario", action="append", choices=DEFAULT_SCENARIOS, help="Scenario to run. Repeatable.")
    parser.add_argument("--json", action="store_true", help="Print the summary JSON to stdout.")
    return parser


def main() -> int:
    args = build_arg_parser().parse_args()
    report = build_report(args.out_dir, args.scenario or DEFAULT_SCENARIOS)
    paths = write_outputs(report, args.out_dir)
    if args.json:
        print(json.dumps(report, indent=2, sort_keys=True))
    else:
        print(f"Wrote {paths['markdown']}")
        print(f"Wrote {paths['json']}")
        print(f"Status: {report['status']}")
    return 0 if report["status"] == "pass" else 1


if __name__ == "__main__":
    raise SystemExit(main())
