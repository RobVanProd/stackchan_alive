#!/usr/bin/env python3
"""Minimal LAN WebSocket bridge service for stackchan.bridge.v1."""

from __future__ import annotations

import argparse
import base64
import copy
import hashlib
import json
import queue
import re
import socket
import threading
import time
import wave
from dataclasses import dataclass, field, replace
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Callable

from local_runner import RUNNER_PROFILES, RunnerConfigurationError, RunnerExecutionError, run_runner_profile
from reference_bridge import (
    AudioBeat,
    PROTOCOL,
    BridgeMemory,
    bridge_frames,
    load_bridge_memory,
    save_bridge_memory,
    turn_from_character_response,
)
from stt_adapter import DEFAULT_STT_TIMEOUT_MS, SttConfigurationError, SttExecutionError, transcribe_pcm
from tts_adapter import (
    DEFAULT_TTS_TIMEOUT_MS,
    DEFAULT_TTS_VOICE,
    TtsConfigurationError,
    TtsExecutionError,
    split_spoken_phrases,
    synthesize_speech,
)
from research_broker import (
    ResearchBroker,
    ResearchBrokerConfig,
    ResearchPolicyError,
    ResearchTransportError,
    evidence_prompt,
    source_urls,
)
from robot_embodiment import RobotEmbodimentState

WEBSOCKET_GUID = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"
MAX_TEXT_BYTES = 65535
DEFAULT_SAMPLE_RATE = 16000
DEFAULT_MAX_AUDIO_BYTES = 512 * 1024
DEFAULT_DOWNLINK_AUDIO_CHUNK_BYTES = 4096
DEFAULT_DOWNLINK_BINARY_FRAME_DELAY_MS = 180
DEFAULT_DOWNLINK_TEXT_FRAME_DELAY_MS = 40
DEFAULT_CLIENT_IDLE_TIMEOUT_S = 20.0
DEFAULT_TCP_KEEPALIVE_IDLE_MS = 5_000
DEFAULT_TCP_KEEPALIVE_INTERVAL_MS = 1_000
DEFAULT_TTS_PHRASE_MAX_CHARS = 96
MAX_DOWNLINK_AUDIO_CHUNK_BYTES = 4096
MAX_TRUSTED_ENDPOINTS = 8
STACKCHAN_WAKE_PHRASE = re.compile(
    r"\bstack[\s-]*(?:chan|chin|chain|can|chad|shan|shen|shed)\b",
    flags=re.IGNORECASE,
)
IDENTITY_QUESTION = re.compile(
    r"\b(?:what(?:'s| is)\s+(?:your|ur)\s+name|who\s+(?:are|r)\s+you|your\s+name)\b",
    flags=re.IGNORECASE,
)


class WebSocketProtocolError(RuntimeError):
    """Raised when a client sends an invalid WebSocket handshake or frame."""


def now_ms() -> int:
    return int(time.time() * 1000)


def utc_timestamp() -> str:
    return datetime.now(timezone.utc).replace(microsecond=0).isoformat().replace("+00:00", "Z")


def mouth_frame_for_audio_window(
    beats: tuple[object, ...],
    start_ms: float,
    duration_ms: float,
) -> dict[str, object]:
    window_start = max(0.0, float(start_ms))
    window_duration = max(1.0, float(duration_ms))
    window_end = window_start + window_duration
    cursor = 0.0
    weighted_env = 0.0
    overlap_total = 0.0
    strongest_env = -1.0
    strongest_viseme = "neutral"
    for beat in beats:
        beat_duration = max(1.0, float(getattr(beat, "duration_ms", 20)))
        beat_end = cursor + beat_duration
        overlap = max(0.0, min(window_end, beat_end) - max(window_start, cursor))
        if overlap > 0.0:
            env = max(0.0, min(1.0, float(getattr(beat, "env", 0.0))))
            weighted_env += env * overlap
            overlap_total += overlap
            if env > strongest_env:
                strongest_env = env
                strongest_viseme = str(getattr(beat, "viseme", "neutral"))
        cursor = beat_end
        if cursor >= window_end:
            break
    envelope = weighted_env / overlap_total if overlap_total > 0.0 else 0.0
    if envelope < 0.02:
        strongest_viseme = "neutral"
    return {
        "env": round(envelope, 3),
        "viseme": strongest_viseme,
        "duration_ms": max(10, min(200, int(round(window_duration)))),
        "final": False,
    }


def normalize_text(value: object, default: str = "", max_len: int = 64) -> str:
    text = " ".join(str(value or default).split())
    return text[:max_len]


def normalize_endpoint_id(value: object) -> str:
    text = normalize_text(value, max_len=64)
    allowed = []
    for char in text:
        if char.isalnum() or char in ("-", "_", "."):
            allowed.append(char)
    return "".join(allowed)[:64]


def normalize_capabilities(value: object) -> tuple[str, ...]:
    if not isinstance(value, list):
        return ()
    capabilities: list[str] = []
    for item in value:
        capability = normalize_endpoint_id(str(item).lower())
        if capability and capability not in capabilities:
            capabilities.append(capability)
    return tuple(capabilities[:32])


def default_bridge_settings() -> dict[str, object]:
    return {
        "persona": {"active": "spark"},
        "voice": {"profile": "rvc-bright", "volume": 0.8},
        "display": {"brightness": 1.0, "reduced_motion": False},
        "motion": {"servo_enabled": False, "calibration_status": "unknown", "safe_stop": False},
        "bridge": {"mode_policy": "auto", "active_brain_owner": "", "trusted_endpoint_count": 0},
        "privacy": {"wake_gate_required": True, "raw_audio_retention": "none"},
        "model": {"profile": "gemma4-e2b-gguf", "runner_status": "unconfigured"},
        "diagnostics": {"export_logs": False},
    }


SAFETY_LOCKED_SETTING_PATHS = {
    ("motion", "servo_enabled"),
    ("motion", "servo_armed"),
    ("privacy", "wake_gate_required"),
    ("privacy", "raw_audio_retention"),
}


@dataclass
class EndpointRecord:
    endpoint_id: str
    endpoint_name: str = ""
    endpoint_kind: str = "dev"
    public_key_fingerprint: str = ""
    priority: int = 0
    auto_connect: bool = True
    capabilities: tuple[str, ...] = ()
    app_version: str = ""
    supports_binary_audio: bool = False
    last_seen_ms: int = 0

    @classmethod
    def from_message(cls, message: dict[str, Any]) -> "EndpointRecord":
        endpoint_id = normalize_endpoint_id(message.get("endpoint_id"))
        if not endpoint_id:
            raise ValueError("endpoint_id_required")
        try:
            priority = int(message.get("priority", 0))
        except (TypeError, ValueError):
            priority = 0
        priority = max(0, min(100, priority))
        endpoint_kind = normalize_endpoint_id(str(message.get("endpoint_kind", "dev")).lower()) or "dev"
        return cls(
            endpoint_id=endpoint_id,
            endpoint_name=normalize_text(message.get("endpoint_name") or endpoint_id, max_len=80),
            endpoint_kind=endpoint_kind[:32],
            public_key_fingerprint=normalize_text(message.get("public_key_fingerprint"), max_len=96),
            priority=priority,
            auto_connect=bool(message.get("auto_connect", True)),
            capabilities=normalize_capabilities(message.get("capabilities")),
            app_version=normalize_text(message.get("app_version"), max_len=32),
            supports_binary_audio=bool(message.get("supports_binary_audio", False)),
            last_seen_ms=now_ms(),
        )

    def to_dict(self) -> dict[str, object]:
        return {
            "endpoint_id": self.endpoint_id,
            "endpoint_name": self.endpoint_name,
            "endpoint_kind": self.endpoint_kind,
            "public_key_fingerprint": self.public_key_fingerprint,
            "priority": self.priority,
            "auto_connect": self.auto_connect,
            "capabilities": list(self.capabilities),
            "app_version": self.app_version,
            "supports_binary_audio": self.supports_binary_audio,
            "last_seen_ms": self.last_seen_ms,
        }


@dataclass
class BridgeControlState:
    trusted_endpoints: dict[str, EndpointRecord] = field(default_factory=dict)
    active_brain_owner: str = ""
    settings_version: int = 1
    settings: dict[str, object] = field(default_factory=default_bridge_settings)

    def register_endpoint(self, message: dict[str, Any]) -> dict[str, object]:
        try:
            endpoint = EndpointRecord.from_message(message)
        except ValueError as exc:
            return error_frame(str(exc))
        if endpoint.endpoint_id not in self.trusted_endpoints and len(self.trusted_endpoints) >= MAX_TRUSTED_ENDPOINTS:
            return error_frame("endpoint_registry_full")
        self.trusted_endpoints[endpoint.endpoint_id] = endpoint
        return {
            "type": "endpoint_hello_result",
            "protocol": PROTOCOL,
            "endpoint_id": endpoint.endpoint_id,
            "trusted": True,
            "active_brain_owner": self.active_brain_owner,
            "trusted_endpoint_count": len(self.trusted_endpoints),
            "capabilities": list(endpoint.capabilities),
        }

    def touch_endpoint(self, endpoint_id: object) -> str:
        normalized = normalize_endpoint_id(endpoint_id)
        if normalized and normalized in self.trusted_endpoints:
            self.trusted_endpoints[normalized].last_seen_ms = now_ms()
        return normalized

    def owner_status(self, state: str = "healthy") -> dict[str, object]:
        owner = self.trusted_endpoints.get(self.active_brain_owner)
        return {
            "type": "owner_status",
            "active_brain_owner": self.active_brain_owner,
            "owner_kind": owner.endpoint_kind if owner else "",
            "state": state if self.active_brain_owner else "offline",
            "trusted_endpoint_count": len(self.trusted_endpoints),
        }

    def claim_brain(self, message: dict[str, Any]) -> dict[str, object]:
        endpoint_id = self.touch_endpoint(message.get("endpoint_id"))
        if not endpoint_id:
            return error_frame("endpoint_id_required")
        if endpoint_id not in self.trusted_endpoints:
            return error_frame("endpoint_not_trusted", endpoint_id)
        self.active_brain_owner = endpoint_id
        return self.owner_status("healthy")

    def release_brain(self, message: dict[str, Any]) -> dict[str, object]:
        endpoint_id = self.touch_endpoint(message.get("endpoint_id"))
        if endpoint_id and self.active_brain_owner and endpoint_id != self.active_brain_owner:
            return error_frame("brain_owner_mismatch", endpoint_id)
        released = self.active_brain_owner
        self.active_brain_owner = ""
        promoted = self.promote_best_endpoint(exclude=released)
        return self.owner_status("healthy" if promoted else "released")

    def promote_best_endpoint(self, *, exclude: str = "") -> str:
        candidates = [
            endpoint
            for endpoint in self.trusted_endpoints.values()
            if endpoint.auto_connect and endpoint.endpoint_id != exclude
        ]
        if not candidates:
            return ""
        candidates.sort(key=lambda endpoint: (endpoint.priority, endpoint.last_seen_ms), reverse=True)
        self.active_brain_owner = candidates[0].endpoint_id
        return self.active_brain_owner

    def trusted_endpoints_frame(self) -> dict[str, object]:
        endpoints = sorted(
            (endpoint.to_dict() for endpoint in self.trusted_endpoints.values()),
            key=lambda item: (-int(item.get("priority", 0)), str(item.get("endpoint_id", ""))),
        )
        return {
            "type": "trusted_endpoints_result",
            "active_brain_owner": self.active_brain_owner,
            "endpoints": endpoints,
        }

    def forget_endpoint(self, message: dict[str, Any]) -> dict[str, object]:
        endpoint_id = normalize_endpoint_id(message.get("endpoint_id"))
        if not endpoint_id:
            return error_frame("endpoint_id_required")
        removed = endpoint_id in self.trusted_endpoints
        self.trusted_endpoints.pop(endpoint_id, None)
        if self.active_brain_owner == endpoint_id:
            self.active_brain_owner = ""
            self.promote_best_endpoint(exclude=endpoint_id)
        return {
            "type": "forget_endpoint_result",
            "endpoint_id": endpoint_id,
            "ok": removed,
            "active_brain_owner": self.active_brain_owner,
            "trusted_endpoint_count": len(self.trusted_endpoints),
        }

    def _settings_snapshot_dict(self) -> dict[str, object]:
        snapshot = copy.deepcopy(self.settings)
        bridge_settings = snapshot.setdefault("bridge", {})
        if isinstance(bridge_settings, dict):
            bridge_settings["active_brain_owner"] = self.active_brain_owner
            bridge_settings["trusted_endpoint_count"] = len(self.trusted_endpoints)
        return snapshot

    def settings_snapshot(self, domains: object = None) -> dict[str, object]:
        settings = self._settings_snapshot_dict()
        if isinstance(domains, list) and domains:
            wanted = {str(domain) for domain in domains}
            settings = {key: value for key, value in settings.items() if key in wanted}
        return {"type": "settings_snapshot", "version": self.settings_version, "settings": settings}

    def settings_set(self, message: dict[str, Any]) -> dict[str, object]:
        requested_version = message.get("version")
        if requested_version is not None:
            try:
                parsed_version = int(requested_version)
            except (TypeError, ValueError):
                return error_frame("settings_version_invalid")
            if parsed_version != self.settings_version:
                return {
                    "type": "settings_result",
                    "ok": False,
                    "code": "settings_version_conflict",
                    "version": self.settings_version,
                    "settings": self._settings_snapshot_dict(),
                }
        updates = message.get("settings")
        if not isinstance(updates, dict):
            return error_frame("settings_payload_invalid")
        locked = self._locked_paths(updates)
        if locked:
            return {
                "type": "settings_result",
                "ok": False,
                "code": "safety_locked_setting",
                "locked": [".".join(path) for path in locked],
                "version": self.settings_version,
            }
        self._deep_merge(self.settings, updates)
        self.settings_version += 1
        return {"type": "settings_result", "ok": True, "version": self.settings_version}

    def _locked_paths(self, updates: dict[str, object], prefix: tuple[str, ...] = ()) -> list[tuple[str, ...]]:
        locked: list[tuple[str, ...]] = []
        for key, value in updates.items():
            path = prefix + (str(key),)
            if path in SAFETY_LOCKED_SETTING_PATHS:
                locked.append(path)
            if isinstance(value, dict):
                locked.extend(self._locked_paths(value, path))
        return locked

    def _deep_merge(self, target: dict[str, object], updates: dict[str, object]) -> None:
        for key, value in updates.items():
            if isinstance(value, dict) and isinstance(target.get(key), dict):
                self._deep_merge(target[key], value)  # type: ignore[index]
            else:
                target[str(key)] = copy.deepcopy(value)

    def diagnostics_snapshot(self, config: LanBridgeConfig) -> dict[str, object]:
        return {
            "type": "diagnostics_snapshot",
            "bridge": {
                "protocol": PROTOCOL,
                "active_brain_owner": self.active_brain_owner,
                "trusted_endpoint_count": len(self.trusted_endpoints),
                "settings_version": self.settings_version,
                "mode_policy": self._settings_snapshot_dict().get("bridge", {}).get("mode_policy", "auto"),
            },
            "model": {
                "profile": config.runner_profile,
                "require_runner": config.require_runner,
            },
            "research": {
                "enabled": config.research_enabled,
                "tools": ["web_search", "web_fetch"] if config.research_enabled else [],
            },
            "audio": {
                "sample_rate": DEFAULT_SAMPLE_RATE,
                "downlink_chunk_bytes": config.downlink_audio_chunk_bytes,
                "downlink_enabled": not config.disable_audio_downlink,
                "max_upload_bytes": config.max_audio_bytes,
                "evidence_dir": str(config.audio_evidence_dir or ""),
            },
        }


@dataclass(frozen=True)
class LanBridgeConfig:
    host: str = "127.0.0.1"
    port: int = 8765
    runner_profile: str = "gemma4-e2b-gguf"
    runner_case: str = "greeting"
    runner_command: str = ""
    require_runner: bool = False
    runner_timeout_ms: int = 60000
    stt_command: str = ""
    stt_timeout_ms: int = DEFAULT_STT_TIMEOUT_MS
    require_audio_wake_phrase: bool = False
    tts_command: str = ""
    tts_voice: str = DEFAULT_TTS_VOICE
    tts_timeout_ms: int = DEFAULT_TTS_TIMEOUT_MS
    stream_tts_phrases: bool = False
    tts_phrase_max_chars: int = DEFAULT_TTS_PHRASE_MAX_CHARS
    downlink_audio_chunk_bytes: int = DEFAULT_DOWNLINK_AUDIO_CHUNK_BYTES
    downlink_binary_frame_delay_ms: int = DEFAULT_DOWNLINK_BINARY_FRAME_DELAY_MS
    downlink_text_frame_delay_ms: int = DEFAULT_DOWNLINK_TEXT_FRAME_DELAY_MS
    client_idle_timeout_s: float = DEFAULT_CLIENT_IDLE_TIMEOUT_S
    disable_audio_downlink: bool = False
    max_audio_bytes: int = DEFAULT_MAX_AUDIO_BYTES
    audio_evidence_dir: Path | None = None
    memory_file: Path | None = None
    turn_log_file: Path | None = None
    auto_turn_text: str = ""
    research_enabled: bool = False
    searxng_url: str = "http://127.0.0.1:8080"
    once: bool = False


@dataclass
class AudioUpload:
    sample_rate: int = DEFAULT_SAMPLE_RATE
    active: bool = False
    bytes_received: int = 0
    chunks: int = 0
    truncated: bool = False
    buffer: bytearray = field(default_factory=bytearray)

    def start(self, sample_rate: object = DEFAULT_SAMPLE_RATE) -> None:
        self.clear()
        try:
            parsed_rate = int(sample_rate)
        except (TypeError, ValueError):
            parsed_rate = DEFAULT_SAMPLE_RATE
        self.sample_rate = max(8000, min(48000, parsed_rate))
        self.active = True

    def clear(self) -> None:
        self.active = False
        self.bytes_received = 0
        self.chunks = 0
        self.truncated = False
        self.buffer.clear()

    def append(self, payload: bytes, max_bytes: int) -> None:
        if not self.active:
            raise WebSocketProtocolError("audio received before utterance_start")
        self.chunks += 1
        allowed = max(0, int(max_bytes) - self.bytes_received)
        self.bytes_received += len(payload)
        if len(payload) > allowed:
            self.truncated = True
        if allowed > 0:
            self.buffer.extend(payload[:allowed])

    @property
    def stored_bytes(self) -> int:
        return len(self.buffer)

    @property
    def duration_ms(self) -> int:
        if self.sample_rate <= 0:
            return 0
        return int((self.bytes_received / 2) / self.sample_rate * 1000)

    def summary(self) -> dict[str, object]:
        return {
            "audio_bytes": self.bytes_received,
            "audio_stored_bytes": self.stored_bytes,
            "audio_chunks": self.chunks,
            "audio_sample_rate": self.sample_rate,
            "audio_duration_ms": self.duration_ms,
            "audio_truncated": self.truncated,
        }

    def finish_and_clear(self) -> dict[str, object]:
        summary = self.summary()
        self.clear()
        return summary


def websocket_accept_value(client_key: str) -> str:
    digest = hashlib.sha1((client_key.strip() + WEBSOCKET_GUID).encode("ascii")).digest()
    return base64.b64encode(digest).decode("ascii")


def parse_http_headers(request: bytes) -> dict[str, str]:
    text = request.decode("iso-8859-1")
    lines = text.split("\r\n")
    if not lines or not lines[0].startswith("GET "):
        raise WebSocketProtocolError("websocket handshake must start with GET")
    headers: dict[str, str] = {}
    for line in lines[1:]:
        if not line or ":" not in line:
            continue
        key, value = line.split(":", 1)
        headers[key.strip().lower()] = value.strip()
    return headers


def build_handshake_response(request: bytes) -> bytes:
    headers = parse_http_headers(request)
    upgrade = headers.get("upgrade", "").lower()
    connection = headers.get("connection", "").lower()
    client_key = headers.get("sec-websocket-key", "")
    if upgrade != "websocket" or "upgrade" not in connection or not client_key:
        raise WebSocketProtocolError("missing WebSocket upgrade headers")
    accept = websocket_accept_value(client_key)
    response = (
        "HTTP/1.1 101 Switching Protocols\r\n"
        "Upgrade: websocket\r\n"
        "Connection: Upgrade\r\n"
        f"Sec-WebSocket-Accept: {accept}\r\n"
        "\r\n"
    )
    return response.encode("ascii")


def recv_exact(conn: socket.socket, count: int) -> bytes:
    chunks: list[bytes] = []
    remaining = count
    while remaining > 0:
        chunk = conn.recv(remaining)
        if not chunk:
            raise WebSocketProtocolError("unexpected websocket disconnect")
        chunks.append(chunk)
        remaining -= len(chunk)
    return b"".join(chunks)


def encode_ws_frame(payload: bytes, opcode: int = 0x1) -> bytes:
    if len(payload) > MAX_TEXT_BYTES:
        raise WebSocketProtocolError("websocket payload too large")
    first = 0x80 | (opcode & 0x0F)
    if len(payload) < 126:
        header = bytes([first, len(payload)])
    else:
        header = bytes([first, 126]) + len(payload).to_bytes(2, "big")
    return header + payload


def encode_ws_text(message: str) -> bytes:
    return encode_ws_frame(message.encode("utf-8"), opcode=0x1)


def encode_ws_close() -> bytes:
    return encode_ws_frame(b"", opcode=0x8)


def read_ws_frame(conn: socket.socket) -> tuple[int, bytes]:
    header = recv_exact(conn, 2)
    first, second = header[0], header[1]
    opcode = first & 0x0F
    masked = bool(second & 0x80)
    length = second & 0x7F
    if length == 126:
        length = int.from_bytes(recv_exact(conn, 2), "big")
    elif length == 127:
        raise WebSocketProtocolError("large websocket frames are not supported")
    if length > MAX_TEXT_BYTES:
        raise WebSocketProtocolError("websocket payload too large")
    mask = recv_exact(conn, 4) if masked else b""
    payload = recv_exact(conn, length)
    if masked:
        payload = bytes(value ^ mask[index % 4] for index, value in enumerate(payload))
    return opcode, payload


def configure_client_socket(
    conn: socket.socket,
    idle_timeout_s: float,
    *,
    low_latency: bool = False,
) -> None:
    """Bound stale-session recovery without changing turn execution timeouts."""
    conn.settimeout(max(1.0, float(idle_timeout_s)))
    try:
        conn.setsockopt(socket.SOL_SOCKET, socket.SO_KEEPALIVE, 1)
    except OSError:
        pass
    if low_latency:
        try:
            conn.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
        except OSError:
            pass

    # Windows exposes keepalive timing through SIO_KEEPALIVE_VALS. POSIX hosts
    # use the TCP_* options when available. Both paths are best-effort because
    # the heartbeat-aware idle timeout remains the final recovery bound.
    if hasattr(socket, "SIO_KEEPALIVE_VALS"):
        try:
            conn.ioctl(
                socket.SIO_KEEPALIVE_VALS,
                (1, DEFAULT_TCP_KEEPALIVE_IDLE_MS, DEFAULT_TCP_KEEPALIVE_INTERVAL_MS),
            )
        except OSError:
            pass
        return

    keepalive_options = (
        ("TCP_KEEPIDLE", max(1, DEFAULT_TCP_KEEPALIVE_IDLE_MS // 1000)),
        ("TCP_KEEPINTVL", max(1, DEFAULT_TCP_KEEPALIVE_INTERVAL_MS // 1000)),
        ("TCP_KEEPCNT", 3),
    )
    for option_name, value in keepalive_options:
        option = getattr(socket, option_name, None)
        if option is None:
            continue
        try:
            conn.setsockopt(socket.IPPROTO_TCP, option, value)
        except OSError:
            pass


def frame_to_text(frame: dict[str, object]) -> str:
    return json.dumps(frame, separators=(",", ":"), ensure_ascii=True)


def error_frame(code: str, detail: str = "") -> dict[str, object]:
    frame: dict[str, object] = {"type": "error", "code": code}
    if detail:
        frame["detail"] = detail[:160]
    return frame


def audio_downlink_frames(seq: int, tts, chunk_bytes: int) -> list[dict[str, object] | bytes]:
    audio = getattr(tts, "audio_data", b"")
    if not audio:
        return []
    safe_chunk_bytes = max(1, min(MAX_DOWNLINK_AUDIO_CHUNK_BYTES, int(chunk_bytes or DEFAULT_DOWNLINK_AUDIO_CHUNK_BYTES)))
    chunks = [audio[index : index + safe_chunk_bytes] for index in range(0, len(audio), safe_chunk_bytes)]
    frames: list[dict[str, object] | bytes] = [
        {
            "type": "audio_stream_start",
            "seq": seq,
            "format": tts.audio_format or "binary",
            "sample_rate": tts.sample_rate,
            "audio_bytes": len(audio),
            "chunk_bytes": safe_chunk_bytes,
            "chunks": len(chunks),
        }
    ]
    frames.extend(chunks)
    frames.append({"type": "audio_stream_end", "seq": seq, "audio_bytes": len(audio), "chunks": len(chunks)})
    return frames


def prompt_case_for_text(text: str, requested: str, default_case: str) -> str:
    if requested:
        return requested
    lowered = text.lower()
    if "forget" in lowered:
        return "forget"
    if "picked" in lowered or "pick" in lowered:
        return "picked_up"
    if "battery" in lowered or "power" in lowered:
        return "low_battery"
    if "confused" in lowered or "ambiguous" in lowered or not text.strip():
        return "confused"
    if "?" in text:
        return "question"
    return default_case


def is_identity_question(text: str) -> bool:
    return bool(IDENTITY_QUESTION.search(" ".join(str(text or "").split())))


def identity_character_response() -> str:
    return json.dumps(
        {
            "spoken_text": "I am Stackchan.",
            "mode": "happy",
            "earcon": "confirm",
            "emotion": {"arousal": 0.15, "valence": 0.35},
            "memory_write": {},
            "memory_forget": [],
        },
        separators=(",", ":"),
        ensure_ascii=True,
    )


def contains_stackchan_wake_phrase(text: str) -> bool:
    return bool(STACKCHAN_WAKE_PHRASE.search(" ".join(str(text or "").split())))


def write_pcm_wav(path: Path, pcm: bytes, sample_rate: int) -> Path:
    path.parent.mkdir(parents=True, exist_ok=True)
    sample_rate = max(8000, min(48000, int(sample_rate or DEFAULT_SAMPLE_RATE)))
    pcm = pcm[: len(pcm) - (len(pcm) % 2)]
    with wave.open(str(path), "wb") as wav:
        wav.setnchannels(1)
        wav.setsampwidth(2)
        wav.setframerate(sample_rate)
        wav.writeframes(pcm)
    return path


class LanBridgeSession:
    def __init__(
        self,
        config: LanBridgeConfig,
        memory: BridgeMemory | None = None,
        control_state: BridgeControlState | None = None,
        research_broker: ResearchBroker | None = None,
    ):
        self.config = config
        self.memory = memory if memory is not None else BridgeMemory()
        self.control_state = control_state if control_state is not None else BridgeControlState()
        self.session = "lan"
        self.endpoint_id = ""
        self.next_seq = 1
        self.audio = AudioUpload()
        self.robot_embodiment = RobotEmbodimentState()
        self.research_broker = research_broker
        if self.research_broker is None and config.research_enabled:
            self.research_broker = ResearchBroker(ResearchBrokerConfig(searxng_url=config.searxng_url))

    @staticmethod
    def _tool_request(raw_response: str) -> dict[str, object] | None:
        try:
            parsed = json.loads(raw_response)
        except json.JSONDecodeError:
            return None
        if not isinstance(parsed, dict) or "tool_request" not in parsed:
            return None
        request = parsed.get("tool_request")
        if not isinstance(request, dict):
            raise ResearchPolicyError("tool_request_not_object")
        return request

    @staticmethod
    def _clear_research_memory_writes(raw_response: str) -> str:
        try:
            parsed = json.loads(raw_response)
        except json.JSONDecodeError:
            return raw_response
        if not isinstance(parsed, dict):
            return raw_response
        parsed["memory_write"] = {}
        parsed["memory_forget"] = []
        return json.dumps(parsed, separators=(",", ":"), ensure_ascii=True)

    def _save_memory(self) -> None:
        if self.config.memory_file:
            save_bridge_memory(self.config.memory_file, self.memory)

    def _append_turn_log(self, record: dict[str, object]) -> None:
        if not self.config.turn_log_file:
            return
        self.config.turn_log_file.parent.mkdir(parents=True, exist_ok=True)
        with self.config.turn_log_file.open("a", encoding="utf-8") as handle:
            handle.write(json.dumps(record, separators=(",", ":"), ensure_ascii=True) + "\n")

    def _write_audio_evidence(
        self,
        *,
        seq: int,
        pcm: bytes,
        audio_summary: dict[str, object],
    ) -> dict[str, object]:
        if not self.config.audio_evidence_dir or not pcm:
            return {}
        timestamp = utc_timestamp().replace(":", "").replace("-", "")
        sample_rate = int(audio_summary.get("audio_sample_rate", DEFAULT_SAMPLE_RATE))
        path = self.config.audio_evidence_dir / f"utterance_{timestamp}_seq{seq:04d}.wav"
        try:
            written = write_pcm_wav(path, pcm, sample_rate)
        except (OSError, ValueError, wave.Error) as exc:
            return {"audio_evidence_error": str(exc)[:160]}
        return {"audio_evidence_file": str(written)}

    def _append_audio_error_log(
        self,
        *,
        seq: int,
        audio_summary: dict[str, object],
        code: str,
        detail: str,
        transcript: str = "",
    ) -> None:
        record: dict[str, object] = {
            "schema": "stackchan.lan-turn-summary.v1",
            "generated_at": utc_timestamp(),
            "seq": seq,
            "session": self.session,
            "source": "audio",
            "audio_bytes": int(audio_summary.get("audio_bytes", 0)),
            "audio_chunks": int(audio_summary.get("audio_chunks", 0)),
            "audio_sample_rate": int(audio_summary.get("audio_sample_rate", DEFAULT_SAMPLE_RATE)),
            "transcript": transcript,
            "rejected": True,
            "reject_code": code,
            "stt_error": detail[:500],
        }
        for key in ("audio_evidence_file", "audio_evidence_error"):
            if key in audio_summary:
                record[key] = str(audio_summary[key])
        self._append_turn_log(record)

    def _append_completed_turn_log(
        self,
        *,
        seq: int,
        has_audio: bool,
        audio_summary: dict[str, object],
        user_text: str,
        runner_case: str,
        turn,
        validation_issues: list[str],
        stt_log: dict[str, object],
        runner_summary: dict[str, object],
        tts_summary: dict[str, object],
        tts_error: str,
        audio_evidence_log: dict[str, object],
        turn_started: float,
    ) -> None:
        record: dict[str, object] = {
            "schema": "stackchan.lan-turn-summary.v1",
            "generated_at": utc_timestamp(),
            "seq": seq,
            "session": self.session,
            "source": "audio" if has_audio else "text",
            "audio_bytes": int(audio_summary.get("audio_bytes", 0)),
            "audio_chunks": int(audio_summary.get("audio_chunks", 0)),
            "audio_sample_rate": int(audio_summary.get("audio_sample_rate", DEFAULT_SAMPLE_RATE)),
            "transcript": user_text,
            "runner_profile": self.config.runner_profile,
            "runner_case": runner_case,
            "response_text": turn.text,
            "response_intent": turn.intent,
            "tts_voice": str(tts_summary.get("tts_voice", "")),
            "tts_audio_payload_bytes": int(tts_summary.get("tts_audio_payload_bytes", 0)),
            "tts_error": tts_error,
            "validation_issues": list(validation_issues),
        }
        record.update(stt_log)
        record.update(runner_summary)
        record.update(tts_summary)
        record.update(audio_evidence_log)
        record["turn_elapsed_ms"] = round((time.perf_counter() - turn_started) * 1000.0, 2)
        self._append_turn_log(record)

    def handle_text(
        self,
        text: str,
        *,
        suppress_thinking: bool = False,
        frame_sink: Callable[[dict[str, object] | bytes], None] | None = None,
    ) -> list[dict[str, object] | bytes]:
        try:
            message = json.loads(text)
        except json.JSONDecodeError:
            return [error_frame("malformed_json")]
        if not isinstance(message, dict):
            return [error_frame("message_not_object")]

        message_type = str(message.get("type", "")).strip().lower()
        if message_type == "hello":
            self.session = str(message.get("session") or message.get("device_id") or self.session)[:48]
            return [{"type": "hello", "protocol": PROTOCOL, "session": self.session}]
        if message_type == "endpoint_hello":
            frame = self.control_state.register_endpoint(message)
            self.endpoint_id = str(frame.get("endpoint_id", self.endpoint_id)) if frame.get("type") != "error" else self.endpoint_id
            return [frame]
        if message_type == "heartbeat":
            self.robot_embodiment.update(message)
            endpoint_id = self.control_state.touch_endpoint(message.get("endpoint_id") or self.endpoint_id)
            frame: dict[str, object] = {"type": "heartbeat", "active_brain_owner": self.control_state.active_brain_owner}
            if endpoint_id:
                frame["endpoint_id"] = endpoint_id
            return [frame]
        if message_type == "claim_brain":
            return [self.control_state.claim_brain(message)]
        if message_type == "release_brain":
            return [self.control_state.release_brain(message)]
        if message_type == "owner_status":
            return [self.control_state.owner_status()]
        if message_type == "trusted_endpoints":
            return [self.control_state.trusted_endpoints_frame()]
        if message_type == "forget_endpoint":
            return [self.control_state.forget_endpoint(message)]
        if message_type == "settings_get":
            return [self.control_state.settings_snapshot(message.get("domains"))]
        if message_type == "settings_set":
            return [self.control_state.settings_set(message)]
        if message_type == "diagnostics_request":
            return [self.control_state.diagnostics_snapshot(self.config)]
        if message_type == "capability_update":
            return [self._handle_capability_update(message)]
        if message_type == "utterance_start":
            owner_error = self._owner_gate(message)
            if owner_error is not None:
                return [owner_error]
            self.audio.start(message.get("sample_rate", DEFAULT_SAMPLE_RATE))
            return [{"type": "listening", **self.audio.summary()}]
        if message_type == "cancel":
            self.audio.clear()
            return [error_frame("cancelled")]
        if message_type == "utterance_audio":
            owner_error = self._owner_gate(message)
            if owner_error is not None:
                return [owner_error]
            return self._handle_text_audio(message)
        if message_type == "utterance_end":
            owner_error = self._owner_gate(message)
            if owner_error is not None:
                return [owner_error]
            return self._handle_utterance_end(
                message,
                suppress_thinking=suppress_thinking,
                frame_sink=frame_sink,
            )
        return [error_frame("unsupported_message", message_type)]

    def _owner_gate(self, message: dict[str, Any]) -> dict[str, object] | None:
        endpoint_id = normalize_endpoint_id(message.get("endpoint_id") or self.endpoint_id)
        if not endpoint_id:
            return None
        self.control_state.touch_endpoint(endpoint_id)
        owner = self.control_state.active_brain_owner
        if owner and endpoint_id != owner:
            return error_frame("brain_owner_mismatch", endpoint_id)
        return None

    def _handle_capability_update(self, message: dict[str, Any]) -> dict[str, object]:
        endpoint_id = self.control_state.touch_endpoint(message.get("endpoint_id") or self.endpoint_id)
        if not endpoint_id:
            return error_frame("endpoint_id_required")
        endpoint = self.control_state.trusted_endpoints.get(endpoint_id)
        if endpoint is None:
            return error_frame("endpoint_not_trusted", endpoint_id)
        endpoint.capabilities = normalize_capabilities(message.get("capabilities"))
        endpoint.supports_binary_audio = bool(message.get("supports_binary_audio", endpoint.supports_binary_audio))
        endpoint.last_seen_ms = now_ms()
        return {
            "type": "capability_update_result",
            "endpoint_id": endpoint_id,
            "capabilities": list(endpoint.capabilities),
            "supports_binary_audio": endpoint.supports_binary_audio,
        }

    def early_thinking_frame(self, text: str) -> dict[str, object] | None:
        try:
            message = json.loads(text)
        except json.JSONDecodeError:
            return None
        if not isinstance(message, dict):
            return None
        if str(message.get("type", "")).strip().lower() != "utterance_end":
            return None
        try:
            seq = int(message.get("seq") or self.next_seq)
        except (TypeError, ValueError):
            seq = self.next_seq
        frame: dict[str, object] = {"type": "thinking", "seq": seq}
        if self.audio.bytes_received > 0 or self.audio.active:
            frame.update(self.audio.summary())
        return frame

    def handle_binary(self, payload: bytes) -> list[dict[str, object]]:
        if self.endpoint_id and self.control_state.active_brain_owner and self.endpoint_id != self.control_state.active_brain_owner:
            return [error_frame("brain_owner_mismatch", self.endpoint_id)]
        try:
            self.audio.append(payload, self.config.max_audio_bytes)
        except WebSocketProtocolError as exc:
            return [error_frame("audio_without_utterance", str(exc))]
        return [{"type": "heartbeat", **self.audio.summary()}]

    def _handle_text_audio(self, message: dict[str, Any]) -> list[dict[str, object]]:
        encoded = str(message.get("pcm_b64") or message.get("audio_b64") or "").strip()
        if not encoded:
            return [error_frame("audio_payload_missing", "send binary WebSocket PCM or pcm_b64")]
        try:
            payload = base64.b64decode(encoded, validate=True)
        except (ValueError, base64.binascii.Error):
            return [error_frame("audio_payload_invalid", "pcm_b64 is not valid base64")]
        return self.handle_binary(payload)

    def _stream_tts_turn(
        self,
        turn,
        *,
        turn_started: float,
        validation_issues: list[str],
        frame_sink: Callable[[dict[str, object] | bytes], None] | None,
    ) -> tuple[list[dict[str, object] | bytes], dict[str, object], str]:
        emitted: list[dict[str, object] | bytes] = []

        def emit(frame: dict[str, object] | bytes) -> None:
            if frame_sink is None:
                emitted.append(frame)
            else:
                frame_sink(frame)

        if validation_issues:
            emit(error_frame("character_validation", ",".join(validation_issues)))
        emit(
            {
                "type": "response_start",
                "seq": turn.seq,
                "intent": turn.intent,
                "arousal": round(max(0.0, min(1.0, turn.arousal)), 2),
                "valence": round(max(0.0, min(1.0, turn.valence)), 2),
                "text": turn.text,
                "tts_streaming": True,
            }
        )

        phrases = split_spoken_phrases(turn.text, self.config.tts_phrase_max_chars)
        total_bytes = 0
        total_chunks = 0
        total_tts_ms = 0.0
        total_duration_ms = 0
        first_audio_ms = 0.0
        first_audio_after_text_ms = 0.0
        tts_started = time.perf_counter()
        stream_started = False
        stream_format = ""
        stream_rate = 0
        command_source = ""
        voice = self.config.tts_voice
        phrase_elapsed_ms: list[float] = []
        mouth_frames = 0
        tts_error = ""
        rendered: queue.Queue[tuple[str, object]] = queue.Queue()

        def render_phrases() -> None:
            for phrase in phrases:
                try:
                    result = synthesize_speech(
                        phrase,
                        command=self.config.tts_command,
                        voice=self.config.tts_voice,
                        timeout_ms=self.config.tts_timeout_ms,
                    )
                    if bool(result.diagnostics.get("audio_truncated", False)):
                        raise TtsExecutionError("streaming TTS refused a truncated phrase")
                    if not result.audio_data:
                        raise TtsExecutionError("streaming TTS phrase produced no audio")
                except Exception as exc:
                    rendered.put(("error", exc))
                    return
                rendered.put(("result", result))
            rendered.put(("done", None))

        producer = threading.Thread(target=render_phrases, name="stackchan-tts-producer", daemon=True)
        producer.start()
        try:
            while True:
                item_type, item = rendered.get()
                if item_type == "done":
                    break
                if item_type == "error":
                    raise TtsExecutionError(str(item))
                result = item
                if not stream_started:
                    stream_format = result.audio_format or "pcm16"
                    stream_rate = result.sample_rate
                    command_source = result.command_source
                    voice = result.voice
                    emit(
                        {
                            "type": "audio_stream_start",
                            "seq": turn.seq,
                            "format": stream_format,
                            "sample_rate": stream_rate,
                            "audio_bytes": 0,
                            "chunk_bytes": max(
                                1,
                                min(
                                    MAX_DOWNLINK_AUDIO_CHUNK_BYTES,
                                    int(self.config.downlink_audio_chunk_bytes),
                                ),
                            ),
                            "chunks": 0,
                            "streaming": True,
                        }
                    )
                    stream_started = True
                elif result.audio_format != stream_format or result.sample_rate != stream_rate:
                    raise TtsExecutionError("streaming TTS phrase format changed within one response")

                safe_chunk_bytes = max(
                    1,
                    min(MAX_DOWNLINK_AUDIO_CHUNK_BYTES, int(self.config.downlink_audio_chunk_bytes)),
                )
                phrase_audio_offset_ms = 0.0
                for offset in range(0, len(result.audio_data), safe_chunk_bytes):
                    chunk = result.audio_data[offset : offset + safe_chunk_bytes]
                    chunk_duration_ms = (
                        (len(chunk) / 2.0) / max(1, result.sample_rate) * 1000.0
                    )
                    if first_audio_ms == 0.0:
                        now = time.perf_counter()
                        first_audio_ms = (now - turn_started) * 1000.0
                        first_audio_after_text_ms = (now - tts_started) * 1000.0
                    mouth = mouth_frame_for_audio_window(
                        getattr(result, "beats", ()),
                        phrase_audio_offset_ms,
                        chunk_duration_ms,
                    )
                    emit({"type": "audio", "seq": turn.seq, **mouth})
                    mouth_frames += 1
                    emit(chunk)
                    total_bytes += len(chunk)
                    total_chunks += 1
                    phrase_audio_offset_ms += chunk_duration_ms
                total_tts_ms += result.elapsed_ms
                total_duration_ms += result.duration_ms
                phrase_elapsed_ms.append(round(result.elapsed_ms, 2))
        except (TtsConfigurationError, TtsExecutionError, ValueError) as exc:
            tts_error = str(exc)

        stream_complete = not tts_error and len(phrase_elapsed_ms) == len(phrases)
        stream_partial = stream_started and not stream_complete

        if stream_started:
            emit(
                {
                    "type": "audio_stream_end",
                    "seq": turn.seq,
                    "audio_bytes": total_bytes,
                    "chunks": total_chunks,
                    "streaming": True,
                }
            )
        if tts_error:
            emit(error_frame("tts_error", tts_error))
        emit(
            {
                "type": "audio",
                "seq": turn.seq,
                "env": 0.0,
                "viseme": "neutral",
                "duration_ms": 20,
                "final": True,
            }
        )
        emit({"type": "response_end", "seq": turn.seq})

        summary: dict[str, object] = {
            "tts_streaming": True,
            "tts_phrases": len(phrases),
            "tts_phrases_completed": len(phrase_elapsed_ms),
            "tts_phrase_elapsed_ms": phrase_elapsed_ms,
            "tts_elapsed_ms": round(total_tts_ms, 2),
            "tts_first_audio_ms": round(first_audio_ms, 2),
            "tts_first_audio_after_text_ms": round(first_audio_after_text_ms, 2),
            "tts_command_source": command_source,
            "tts_voice": voice,
            "tts_duration_ms": total_duration_ms,
            "tts_audio_format": stream_format,
            "tts_sample_rate": stream_rate,
            "tts_audio_bytes": total_bytes,
            "tts_audio_payload_bytes": total_bytes,
            "tts_audio_chunks": total_chunks,
            "tts_mouth_frames": mouth_frames,
            "tts_audio_truncated": stream_partial,
            "tts_stream_complete": stream_complete,
        }
        return emitted, summary, tts_error

    def _handle_utterance_end(
        self,
        message: dict[str, Any],
        *,
        suppress_thinking: bool = False,
        frame_sink: Callable[[dict[str, object] | bytes], None] | None = None,
    ) -> list[dict[str, object] | bytes]:
        turn_started = time.perf_counter()
        seq = int(message.get("seq") or self.next_seq)
        self.next_seq = max(self.next_seq, seq + 1)
        user_text = " ".join(str(message.get("text") or message.get("transcript") or "").split())
        pcm = bytes(self.audio.buffer)
        audio_summary = self.audio.finish_and_clear()
        has_audio = int(audio_summary["audio_bytes"]) > 0
        audio_evidence_log = self._write_audio_evidence(seq=seq, pcm=pcm, audio_summary=audio_summary) if has_audio else {}
        audio_summary.update(audio_evidence_log)
        stt_log: dict[str, object] = {}
        if not has_audio and not user_text:
            return [error_frame("empty_utterance", "utterance_end had no audio or transcript") | audio_summary]
        if has_audio and not user_text:
            try:
                stt = transcribe_pcm(
                    pcm,
                    int(audio_summary["audio_sample_rate"]),
                    command=self.config.stt_command,
                    timeout_ms=self.config.stt_timeout_ms,
                )
            except SttConfigurationError:
                detail = f"received {audio_summary['audio_bytes']} PCM bytes; configure STT or provide transcript"
                self._append_audio_error_log(
                    seq=seq,
                    audio_summary=audio_summary,
                    code="stt_not_implemented",
                    detail=detail,
                )
                return [
                    error_frame(
                        "stt_not_implemented",
                        detail,
                    )
                    | audio_summary
                ]
            except (SttExecutionError, ValueError) as exc:
                self._append_audio_error_log(
                    seq=seq,
                    audio_summary=audio_summary,
                    code="stt_error",
                    detail=str(exc),
                )
                return [error_frame("stt_error", str(exc)) | audio_summary]
            user_text = stt.transcript
            audio_summary["stt_elapsed_ms"] = round(stt.elapsed_ms, 2)
            audio_summary["stt_command_source"] = stt.command_source
            stt_log = {
                "stt_transcript": stt.transcript,
                "stt_elapsed_ms": round(stt.elapsed_ms, 2),
                "stt_command_source": stt.command_source,
            }
            if stt.raw_transcript and stt.raw_transcript != stt.transcript:
                stt_log["stt_raw_transcript"] = stt.raw_transcript
            if stt.transcript_normalized:
                stt_log["stt_transcript_normalized"] = True
        if has_audio and self.config.require_audio_wake_phrase and not contains_stackchan_wake_phrase(user_text):
            rejected_log: dict[str, object] = {
                "schema": "stackchan.lan-turn-summary.v1",
                "generated_at": utc_timestamp(),
                "seq": seq,
                "session": self.session,
                "source": "audio",
                "audio_bytes": int(audio_summary.get("audio_bytes", 0)),
                "audio_chunks": int(audio_summary.get("audio_chunks", 0)),
                "audio_sample_rate": int(audio_summary.get("audio_sample_rate", DEFAULT_SAMPLE_RATE)),
                "transcript": user_text,
                "rejected": True,
                "reject_code": "wake_phrase_required",
            }
            rejected_log.update(stt_log)
            rejected_log.update(audio_evidence_log)
            self._append_turn_log(rejected_log)
            return [error_frame("wake_phrase_required", "audio transcript did not contain Stackchan") | audio_summary]
        if user_text:
            self.memory = self.memory.remember_user_text(user_text)

        requested_case = str(message.get("runner_case", "")).strip()
        runner_summary: dict[str, object] = {}
        research_result: dict[str, object] | None = None
        if not requested_case and is_identity_question(user_text):
            runner_case = "identity"
            raw_response = identity_character_response()
            runner_summary["runner_command_source"] = "local_identity"
            runner_summary["runner_elapsed_ms"] = 0.0
        else:
            runner_case = prompt_case_for_text(user_text, requested_case, self.config.runner_case)
            try:
                runner = run_runner_profile(
                    self.config.runner_profile,
                    case_name=runner_case,
                    command=self.config.runner_command,
                    require_runner=self.config.require_runner,
                    timeout_ms=self.config.runner_timeout_ms,
                    user_text=user_text,
                    research_tools_enabled=self.config.research_enabled,
                    embodiment_lines=self.robot_embodiment.prompt_lines(),
                )
            except (RunnerConfigurationError, RunnerExecutionError, ValueError) as exc:
                return [error_frame("runner_error", str(exc))]
            raw_response = runner.raw_response
            runner_summary["runner_command_source"] = runner.command_source
            if runner.elapsed_ms is not None:
                runner_summary["runner_elapsed_ms"] = round(runner.elapsed_ms, 2)
            if runner.approx_tokens_per_sec is not None:
                runner_summary["runner_approx_tokens_per_sec"] = round(runner.approx_tokens_per_sec, 2)

            if self.config.research_enabled:
                try:
                    tool_request = self._tool_request(raw_response)
                except ResearchPolicyError as exc:
                    tool_request = {"name": "invalid", "arguments": {}}
                    runner_summary["research_error"] = str(exc)
                if tool_request is not None:
                    if self.research_broker is None:
                        research_result = {
                            "schema": "stackchan.research.v1",
                            "tool": str(tool_request.get("name", "")),
                            "error": "research_broker_unavailable",
                            "results": [],
                        }
                    else:
                        try:
                            research_result = self.research_broker.execute(tool_request)
                        except (ResearchPolicyError, ResearchTransportError, ValueError, TypeError) as exc:
                            research_result = {
                                "schema": "stackchan.research.v1",
                                "tool": str(tool_request.get("name", "")),
                                "error": str(exc)[:120],
                                "results": [],
                            }
                    evidence_user_text = f"{user_text}\n\n{evidence_prompt(research_result)}"
                    try:
                        researched = run_runner_profile(
                            self.config.runner_profile,
                            case_name=runner_case,
                            command=self.config.runner_command,
                            require_runner=self.config.require_runner,
                            timeout_ms=self.config.runner_timeout_ms,
                            user_text=evidence_user_text,
                            research_tools_enabled=False,
                            embodiment_lines=self.robot_embodiment.prompt_lines(),
                        )
                    except (RunnerConfigurationError, RunnerExecutionError, ValueError) as exc:
                        return [error_frame("runner_error", str(exc))]
                    raw_response = self._clear_research_memory_writes(researched.raw_response)
                    runner_summary["research_tool"] = str(research_result.get("tool", ""))
                    runner_summary["research_source_urls"] = list(source_urls(research_result))
                    runner_summary["research_error"] = str(research_result.get("error", ""))
                    if researched.elapsed_ms is not None:
                        runner_summary["research_runner_elapsed_ms"] = round(researched.elapsed_ms, 2)

        turn, self.memory, validation = turn_from_character_response(
            raw_response,
            self.memory,
            session=self.session,
            seq=seq,
        )
        if research_result is not None:
            turn = replace(turn, citations=source_urls(research_result))
        if (
            self.config.stream_tts_phrases
            and self.config.tts_command
            and not self.config.disable_audio_downlink
        ):
            frames, tts_summary, tts_error = self._stream_tts_turn(
                turn,
                turn_started=turn_started,
                validation_issues=list(validation.issues),
                frame_sink=frame_sink,
            )
            self._save_memory()
            self._append_completed_turn_log(
                seq=seq,
                has_audio=has_audio,
                audio_summary=audio_summary,
                user_text=user_text,
                runner_case=runner_case,
                turn=turn,
                validation_issues=list(validation.issues),
                stt_log=stt_log,
                runner_summary=runner_summary,
                tts_summary=tts_summary,
                tts_error=tts_error,
                audio_evidence_log=audio_evidence_log,
                turn_started=turn_started,
            )
            return frames
        tts_summary: dict[str, object] = {}
        downlink_frames: list[dict[str, object] | bytes] = []
        tts_error = ""
        try:
            tts = synthesize_speech(
                turn.text,
                command=self.config.tts_command,
                voice=self.config.tts_voice,
                timeout_ms=self.config.tts_timeout_ms,
            )
            turn = replace(
                turn,
                beats=tuple(
                    AudioBeat(beat.env, beat.viseme, beat.duration_ms, beat.final) for beat in tts.beats
                ),
            )
            tts_summary = {
                "tts_elapsed_ms": round(tts.elapsed_ms, 2),
                "tts_command_source": tts.command_source,
                "tts_voice": tts.voice,
                "tts_beats": len(tts.beats),
                "tts_duration_ms": tts.duration_ms,
            }
            if tts.audio_format:
                tts_summary["tts_audio_format"] = tts.audio_format
            if tts.sample_rate:
                tts_summary["tts_sample_rate"] = tts.sample_rate
            if tts.audio_bytes:
                tts_summary["tts_audio_bytes"] = tts.audio_bytes
            for key, value in tts.diagnostics.items():
                tts_summary[f"tts_{key}"] = value
            if tts.audio_data:
                tts_summary["tts_audio_payload_bytes"] = len(tts.audio_data)
                if self.config.disable_audio_downlink:
                    tts_summary["tts_audio_downlink_disabled"] = True
                else:
                    downlink_frames = audio_downlink_frames(seq, tts, self.config.downlink_audio_chunk_bytes)
        except TtsConfigurationError:
            pass
        except (TtsExecutionError, ValueError) as exc:
            tts_error = str(exc)
        self._save_memory()
        frames = [frame for frame in bridge_frames(turn) if frame.get("type") not in ("hello", "listening")]
        if suppress_thinking:
            frames = [frame for frame in frames if frame.get("type") != "thinking"]
        if has_audio:
            audio_frame_type = "response_start" if suppress_thinking else "thinking"
            for frame in frames:
                if frame.get("type") == audio_frame_type:
                    frame.update(audio_summary)
                    break
        if tts_summary:
            for frame in frames:
                if frame.get("type") == "response_start":
                    frame.update(tts_summary)
                    if downlink_frames:
                        audio_seen = 0
                        sparse_frames: list[dict[str, object]] = []
                        for candidate in frames:
                            if candidate.get("type") != "audio":
                                sparse_frames.append(candidate)
                                continue
                            audio_seen += 1
                            if audio_seen <= 4 or candidate.get("final"):
                                sparse_frames.append(candidate)
                        frames = sparse_frames
                        index = frames.index(frame)
                        frames[index + 1:index + 1] = downlink_frames
                    break
        prefix_errors: list[dict[str, object]] = []
        if validation.issues:
            prefix_errors.append(error_frame("character_validation", ",".join(validation.issues)))
        if tts_error:
            prefix_errors.append(error_frame("tts_error", tts_error))
        self._append_completed_turn_log(
            seq=seq,
            has_audio=has_audio,
            audio_summary=audio_summary,
            user_text=user_text,
            runner_case=runner_case,
            turn=turn,
            validation_issues=list(validation.issues),
            stt_log=stt_log,
            runner_summary=runner_summary,
            tts_summary=tts_summary,
            tts_error=tts_error,
            audio_evidence_log=audio_evidence_log,
            turn_started=turn_started,
        )
        return prefix_errors + frames


def read_http_request(conn: socket.socket) -> bytes:
    data = bytearray()
    while b"\r\n\r\n" not in data:
        chunk = conn.recv(4096)
        if not chunk:
            raise WebSocketProtocolError("client closed before websocket handshake")
        data.extend(chunk)
        if len(data) > 8192:
            raise WebSocketProtocolError("websocket handshake too large")
    return bytes(data)


def send_connection_frame(
    conn: socket.socket,
    config: LanBridgeConfig,
    frame: dict[str, object] | bytes,
    *,
    final_binary_chunk: bool = True,
) -> None:
    if isinstance(frame, bytes):
        conn.sendall(encode_ws_frame(frame, opcode=0x2))
        delay_ms = config.downlink_binary_frame_delay_ms
        if final_binary_chunk and len(frame) < config.downlink_audio_chunk_bytes:
            delay_ms = max(delay_ms, 250)
        if delay_ms > 0:
            time.sleep(delay_ms / 1000.0)
        return
    conn.sendall(encode_ws_text(frame_to_text(frame)))
    if config.downlink_text_frame_delay_ms > 0:
        time.sleep(config.downlink_text_frame_delay_ms / 1000.0)


def handle_connection(
    conn: socket.socket,
    config: LanBridgeConfig,
    memory: BridgeMemory,
    control_state: BridgeControlState | None = None,
) -> BridgeMemory:
    session = LanBridgeSession(config, memory, control_state)
    request = read_http_request(conn)
    print(f"[bridge-lan] handshake_bytes={len(request)}", flush=True)
    conn.sendall(build_handshake_response(request))
    configure_client_socket(
        conn,
        config.client_idle_timeout_s,
        low_latency=config.stream_tts_phrases,
    )
    print("[bridge-lan] handshake_accepted=1", flush=True)
    conn.sendall(encode_ws_text(frame_to_text({"type": "hello", "protocol": PROTOCOL, "session": session.session})))
    print("[bridge-lan] session_hello=1", flush=True)

    pending_short_chunk: bytes | None = None

    def send_live(frame: dict[str, object] | bytes) -> None:
        nonlocal pending_short_chunk
        if pending_short_chunk is not None:
            send_connection_frame(
                conn,
                config,
                pending_short_chunk,
                final_binary_chunk=not isinstance(frame, bytes),
            )
            pending_short_chunk = None
        if (
            config.stream_tts_phrases
            and isinstance(frame, bytes)
            and len(frame) < config.downlink_audio_chunk_bytes
        ):
            pending_short_chunk = frame
            return
        send_connection_frame(conn, config, frame)

    if config.auto_turn_text:
        seq = now_ms() % 1000000
        auto_turn = {"type": "utterance_end", "seq": seq, "text": config.auto_turn_text}
        print(f"[bridge-lan] auto_turn_start seq={seq}", flush=True)
        conn.sendall(encode_ws_text(frame_to_text({"type": "thinking", "seq": seq})))
        frames = session.handle_text(
            json.dumps(auto_turn),
            suppress_thinking=True,
            frame_sink=send_live if config.stream_tts_phrases else None,
        )
        text_frames = 0
        binary_frames = 0
        binary_bytes = 0
        text_types: list[str] = []
        for frame in frames:
            if isinstance(frame, bytes):
                binary_frames += 1
                binary_bytes += len(frame)
            else:
                text_frames += 1
                frame_type = str(frame.get("type", ""))
                if frame_type and len(text_types) < 12:
                    text_types.append(frame_type)
            send_live(frame)
        print(
            f"[bridge-lan] auto_turn_sent seq={seq} frames={len(frames)} "
            f"text_frames={text_frames} binary_frames={binary_frames} "
            f"binary_bytes={binary_bytes} text_types={','.join(text_types)}",
            flush=True,
        )
    while True:
        opcode, payload = read_ws_frame(conn)
        if opcode == 0x8:
            conn.sendall(encode_ws_close())
            break
        if opcode == 0x9:
            conn.sendall(encode_ws_frame(payload, opcode=0xA))
            continue
        if opcode == 0x1:
            text = payload.decode("utf-8")
            text_message_type = ""
            try:
                parsed_text = json.loads(text)
                if isinstance(parsed_text, dict):
                    text_message_type = str(parsed_text.get("type", "")).strip().lower()
            except json.JSONDecodeError:
                text_message_type = ""
            if '"type":"heartbeat"' in text or '"type": "heartbeat"' in text:
                if '"mww_' in text or '"wake_' in text:
                    print(f"[bridge-lan] heartbeat {text}", flush=True)
                else:
                    print("[bridge-lan] heartbeat", flush=True)
            elif '"type":"utterance_start"' in text or '"type": "utterance_start"' in text:
                print("[bridge-lan] utterance_start", flush=True)
            elif '"type":"utterance_end"' in text or '"type": "utterance_end"' in text:
                print("[bridge-lan] utterance_end", flush=True)
            early_frame = session.early_thinking_frame(text)
            if early_frame is not None:
                conn.sendall(encode_ws_text(frame_to_text(early_frame)))
            frames = session.handle_text(
                text,
                suppress_thinking=early_frame is not None,
                frame_sink=(
                    send_live
                    if config.stream_tts_phrases and text_message_type == "utterance_end"
                    else None
                ),
            )
            if text_message_type == "heartbeat":
                frames = []
        elif opcode == 0x2:
            before_chunks = session.audio.chunks
            frames = session.handle_binary(payload)
            if session.audio.chunks != before_chunks and (
                session.audio.chunks == 1 or session.audio.chunks % 20 == 0
            ):
                print(
                    f"[bridge-lan] utterance_audio chunks={session.audio.chunks} "
                    f"bytes={session.audio.bytes_received}",
                    flush=True,
                )
            frames = []
        else:
            frames = [error_frame("unsupported_websocket_opcode", str(opcode))]
        for frame in frames:
            send_live(frame)
    return session.memory


def serve(config: LanBridgeConfig) -> None:
    memory = load_bridge_memory(config.memory_file) if config.memory_file else BridgeMemory()
    control_state = BridgeControlState()
    with socket.create_server((config.host, config.port), reuse_port=False) as server:
        server.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        print(f"[bridge-lan] listening ws://{config.host}:{config.port} protocol={PROTOCOL}", flush=True)
        while True:
            conn, address = server.accept()
            print(f"[bridge-lan] client={address[0]}:{address[1]}", flush=True)
            with conn:
                conn.settimeout(5.0)
                try:
                    memory = handle_connection(conn, config, memory, control_state)
                except WebSocketProtocolError as exc:
                    print(f"[bridge-lan] client_disconnect={address[0]}:{address[1]} reason=\"{exc}\"", flush=True)
                except OSError as exc:
                    print(f"[bridge-lan] client_disconnect={address[0]}:{address[1]} reason=\"socket:{exc}\"", flush=True)
            if config.once:
                break


def build_arg_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description="Run the local Stackchan P7 LAN WebSocket bridge.")
    parser.add_argument("--host", default="127.0.0.1")
    parser.add_argument("--port", type=int, default=8765)
    parser.add_argument("--once", action="store_true", help="Handle one client and exit.")
    parser.add_argument("--runner-profile", choices=sorted(RUNNER_PROFILES), default="gemma4-e2b-gguf")
    parser.add_argument("--runner-case", default="greeting")
    parser.add_argument("--runner-command", default="")
    parser.add_argument("--require-runner", action="store_true")
    parser.add_argument("--runner-timeout-ms", type=int, default=60000)
    parser.add_argument("--stt-command", default="")
    parser.add_argument("--stt-timeout-ms", type=int, default=DEFAULT_STT_TIMEOUT_MS)
    parser.add_argument("--require-audio-wake-phrase", action="store_true")
    parser.add_argument("--tts-command", default="")
    parser.add_argument("--tts-voice", default=DEFAULT_TTS_VOICE)
    parser.add_argument("--tts-timeout-ms", type=int, default=DEFAULT_TTS_TIMEOUT_MS)
    parser.add_argument("--stream-tts-phrases", action="store_true")
    parser.add_argument("--tts-phrase-max-chars", type=int, default=DEFAULT_TTS_PHRASE_MAX_CHARS)
    parser.add_argument("--downlink-audio-chunk-bytes", type=int, default=DEFAULT_DOWNLINK_AUDIO_CHUNK_BYTES)
    parser.add_argument("--downlink-binary-frame-delay-ms", type=int, default=DEFAULT_DOWNLINK_BINARY_FRAME_DELAY_MS)
    parser.add_argument("--downlink-text-frame-delay-ms", type=int, default=DEFAULT_DOWNLINK_TEXT_FRAME_DELAY_MS)
    parser.add_argument("--client-idle-timeout-s", type=float, default=DEFAULT_CLIENT_IDLE_TIMEOUT_S)
    parser.add_argument("--disable-audio-downlink", action="store_true")
    parser.add_argument("--max-audio-bytes", type=int, default=DEFAULT_MAX_AUDIO_BYTES)
    parser.add_argument("--audio-evidence-dir", type=Path)
    parser.add_argument("--memory-file", type=Path)
    parser.add_argument("--turn-log-file", type=Path)
    parser.add_argument("--auto-turn-text", default="")
    parser.add_argument("--enable-research", action="store_true")
    parser.add_argument("--searxng-url", default="http://127.0.0.1:8080")
    parser.add_argument("--reset-memory", action="store_true")
    return parser


def main() -> int:
    args = build_arg_parser().parse_args()
    if args.reset_memory and args.memory_file and args.memory_file.exists():
        args.memory_file.unlink()
    config = LanBridgeConfig(
        host=args.host,
        port=args.port,
        once=args.once,
        runner_profile=args.runner_profile,
        runner_case=args.runner_case,
        runner_command=args.runner_command,
        require_runner=args.require_runner,
        runner_timeout_ms=args.runner_timeout_ms,
        stt_command=args.stt_command,
        stt_timeout_ms=args.stt_timeout_ms,
        require_audio_wake_phrase=args.require_audio_wake_phrase,
        tts_command=args.tts_command,
        tts_voice=args.tts_voice,
        tts_timeout_ms=args.tts_timeout_ms,
        stream_tts_phrases=args.stream_tts_phrases,
        tts_phrase_max_chars=max(24, min(240, args.tts_phrase_max_chars)),
        downlink_audio_chunk_bytes=args.downlink_audio_chunk_bytes,
        downlink_binary_frame_delay_ms=max(0, args.downlink_binary_frame_delay_ms),
        downlink_text_frame_delay_ms=max(0, args.downlink_text_frame_delay_ms),
        client_idle_timeout_s=max(1.0, args.client_idle_timeout_s),
        disable_audio_downlink=args.disable_audio_downlink,
        max_audio_bytes=args.max_audio_bytes,
        audio_evidence_dir=args.audio_evidence_dir,
        memory_file=args.memory_file,
        turn_log_file=args.turn_log_file,
        auto_turn_text=args.auto_turn_text,
        research_enabled=args.enable_research,
        searxng_url=args.searxng_url,
    )
    serve(config)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
