#!/usr/bin/env python3
"""Minimal LAN WebSocket bridge service for stackchan.bridge.v1."""

from __future__ import annotations

import argparse
import base64
import copy
import hashlib
import json
import socket
import time
from dataclasses import dataclass, field, replace
from pathlib import Path
from typing import Any

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
from tts_adapter import DEFAULT_TTS_TIMEOUT_MS, DEFAULT_TTS_VOICE, TtsConfigurationError, TtsExecutionError, synthesize_speech

WEBSOCKET_GUID = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"
MAX_TEXT_BYTES = 65535
DEFAULT_SAMPLE_RATE = 16000
DEFAULT_MAX_AUDIO_BYTES = 512 * 1024
DEFAULT_DOWNLINK_AUDIO_CHUNK_BYTES = 4096
DEFAULT_DOWNLINK_BINARY_FRAME_DELAY_MS = 180
DEFAULT_DOWNLINK_TEXT_FRAME_DELAY_MS = 40
MAX_DOWNLINK_AUDIO_CHUNK_BYTES = 4096
MAX_TRUSTED_ENDPOINTS = 8


class WebSocketProtocolError(RuntimeError):
    """Raised when a client sends an invalid WebSocket handshake or frame."""


def now_ms() -> int:
    return int(time.time() * 1000)


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
            "audio": {
                "sample_rate": DEFAULT_SAMPLE_RATE,
                "downlink_chunk_bytes": config.downlink_audio_chunk_bytes,
                "max_upload_bytes": config.max_audio_bytes,
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
    tts_command: str = ""
    tts_voice: str = DEFAULT_TTS_VOICE
    tts_timeout_ms: int = DEFAULT_TTS_TIMEOUT_MS
    downlink_audio_chunk_bytes: int = DEFAULT_DOWNLINK_AUDIO_CHUNK_BYTES
    downlink_binary_frame_delay_ms: int = DEFAULT_DOWNLINK_BINARY_FRAME_DELAY_MS
    downlink_text_frame_delay_ms: int = DEFAULT_DOWNLINK_TEXT_FRAME_DELAY_MS
    max_audio_bytes: int = DEFAULT_MAX_AUDIO_BYTES
    memory_file: Path | None = None
    auto_turn_text: str = ""
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
    if "?" in text or "confused" in lowered:
        return "confused"
    return default_case


class LanBridgeSession:
    def __init__(
        self,
        config: LanBridgeConfig,
        memory: BridgeMemory | None = None,
        control_state: BridgeControlState | None = None,
    ):
        self.config = config
        self.memory = memory if memory is not None else BridgeMemory()
        self.control_state = control_state if control_state is not None else BridgeControlState()
        self.session = "lan"
        self.endpoint_id = ""
        self.next_seq = 1
        self.audio = AudioUpload()

    def _save_memory(self) -> None:
        if self.config.memory_file:
            save_bridge_memory(self.config.memory_file, self.memory)

    def handle_text(self, text: str, *, suppress_thinking: bool = False) -> list[dict[str, object] | bytes]:
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
            return self._handle_utterance_end(message, suppress_thinking=suppress_thinking)
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

    def _handle_utterance_end(
        self, message: dict[str, Any], *, suppress_thinking: bool = False
    ) -> list[dict[str, object] | bytes]:
        seq = int(message.get("seq") or self.next_seq)
        self.next_seq = max(self.next_seq, seq + 1)
        user_text = " ".join(str(message.get("text") or message.get("transcript") or "").split())
        pcm = bytes(self.audio.buffer)
        audio_summary = self.audio.finish_and_clear()
        has_audio = int(audio_summary["audio_bytes"]) > 0
        if has_audio and not user_text:
            try:
                stt = transcribe_pcm(
                    pcm,
                    int(audio_summary["audio_sample_rate"]),
                    command=self.config.stt_command,
                    timeout_ms=self.config.stt_timeout_ms,
                )
            except SttConfigurationError:
                return [
                    error_frame(
                        "stt_not_implemented",
                        f"received {audio_summary['audio_bytes']} PCM bytes; configure STT or provide transcript",
                    )
                    | audio_summary
                ]
            except (SttExecutionError, ValueError) as exc:
                return [error_frame("stt_error", str(exc)) | audio_summary]
            user_text = stt.transcript
            audio_summary["stt_elapsed_ms"] = round(stt.elapsed_ms, 2)
            audio_summary["stt_command_source"] = stt.command_source
        if user_text:
            self.memory = self.memory.remember_user_text(user_text)

        requested_case = str(message.get("runner_case", "")).strip()
        runner_case = prompt_case_for_text(user_text, requested_case, self.config.runner_case)
        try:
            runner = run_runner_profile(
                self.config.runner_profile,
                case_name=runner_case,
                command=self.config.runner_command,
                require_runner=self.config.require_runner,
                timeout_ms=self.config.runner_timeout_ms,
            )
        except (RunnerConfigurationError, RunnerExecutionError, ValueError) as exc:
            return [error_frame("runner_error", str(exc))]

        turn, self.memory, validation = turn_from_character_response(
            runner.raw_response,
            self.memory,
            session=self.session,
            seq=seq,
        )
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
            if tts.audio_data:
                tts_summary["tts_audio_payload_bytes"] = len(tts.audio_data)
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
    conn.settimeout(30.0)
    print("[bridge-lan] handshake_accepted=1", flush=True)
    if config.auto_turn_text:
        seq = now_ms() % 1000000
        auto_turn = {"type": "utterance_end", "seq": seq, "text": config.auto_turn_text}
        print(f"[bridge-lan] auto_turn_start seq={seq}", flush=True)
        conn.sendall(encode_ws_text(frame_to_text({"type": "thinking", "seq": seq})))
        frames = session.handle_text(json.dumps(auto_turn), suppress_thinking=True)
        text_frames = 0
        binary_frames = 0
        binary_bytes = 0
        text_types: list[str] = []
        for frame in frames:
            if isinstance(frame, bytes):
                binary_frames += 1
                binary_bytes += len(frame)
                conn.sendall(encode_ws_frame(frame, opcode=0x2))
                delay_ms = config.downlink_binary_frame_delay_ms
                if len(frame) < config.downlink_audio_chunk_bytes:
                    delay_ms = max(delay_ms, 250)
                if delay_ms > 0:
                    time.sleep(delay_ms / 1000.0)
            else:
                text_frames += 1
                frame_type = str(frame.get("type", ""))
                if frame_type and len(text_types) < 12:
                    text_types.append(frame_type)
                conn.sendall(encode_ws_text(frame_to_text(frame)))
                if config.downlink_text_frame_delay_ms > 0:
                    time.sleep(config.downlink_text_frame_delay_ms / 1000.0)
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
            early_frame = session.early_thinking_frame(text)
            if early_frame is not None:
                conn.sendall(encode_ws_text(frame_to_text(early_frame)))
            frames = session.handle_text(text, suppress_thinking=early_frame is not None)
        elif opcode == 0x2:
            frames = session.handle_binary(payload)
        else:
            frames = [error_frame("unsupported_websocket_opcode", str(opcode))]
        for frame in frames:
            if isinstance(frame, bytes):
                conn.sendall(encode_ws_frame(frame, opcode=0x2))
                delay_ms = config.downlink_binary_frame_delay_ms
                if len(frame) < config.downlink_audio_chunk_bytes:
                    delay_ms = max(delay_ms, 250)
                if delay_ms > 0:
                    time.sleep(delay_ms / 1000.0)
            else:
                conn.sendall(encode_ws_text(frame_to_text(frame)))
                if config.downlink_text_frame_delay_ms > 0:
                    time.sleep(config.downlink_text_frame_delay_ms / 1000.0)
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
    parser.add_argument("--tts-command", default="")
    parser.add_argument("--tts-voice", default=DEFAULT_TTS_VOICE)
    parser.add_argument("--tts-timeout-ms", type=int, default=DEFAULT_TTS_TIMEOUT_MS)
    parser.add_argument("--downlink-audio-chunk-bytes", type=int, default=DEFAULT_DOWNLINK_AUDIO_CHUNK_BYTES)
    parser.add_argument("--downlink-binary-frame-delay-ms", type=int, default=DEFAULT_DOWNLINK_BINARY_FRAME_DELAY_MS)
    parser.add_argument("--downlink-text-frame-delay-ms", type=int, default=DEFAULT_DOWNLINK_TEXT_FRAME_DELAY_MS)
    parser.add_argument("--max-audio-bytes", type=int, default=DEFAULT_MAX_AUDIO_BYTES)
    parser.add_argument("--memory-file", type=Path)
    parser.add_argument("--auto-turn-text", default="")
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
        tts_command=args.tts_command,
        tts_voice=args.tts_voice,
        tts_timeout_ms=args.tts_timeout_ms,
        downlink_audio_chunk_bytes=args.downlink_audio_chunk_bytes,
        downlink_binary_frame_delay_ms=max(0, args.downlink_binary_frame_delay_ms),
        downlink_text_frame_delay_ms=max(0, args.downlink_text_frame_delay_ms),
        max_audio_bytes=args.max_audio_bytes,
        memory_file=args.memory_file,
        auto_turn_text=args.auto_turn_text,
    )
    serve(config)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
