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

from cancellation import CancellationToken, OperationCancelledError
from local_runner import RUNNER_PROFILES, RunnerConfigurationError, RunnerExecutionError, run_runner_profile
from persona_pack import (
    DEFAULT_PERSONA_ID,
    PersonaPack,
    PersonaPackError,
    load_and_validate_persona_pack,
    normalize_persona_id,
)
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
from local_facts import resolve_local_fact
from robot_embodiment import RobotEmbodimentState
from conversation_latency import build_conversation_latency_record
from conversation_session import ConversationConfig, ConversationPhase, ConversationSession

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
DEFAULT_BRAIN_OWNER_LEASE_MS = 15_000
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
EXPLICIT_RESEARCH_REQUEST = re.compile(
    r"\b(?:search(?: the)? web|search online|look (?:it|this|that|.+?) up|browse(?: the)? web|"
    r"find (?:it|this|that|.+?) online|latest (?:news|information|release|version)|"
    r"current (?:news|weather|price|score))\b",
    flags=re.IGNORECASE,
)
SENSITIVE_RESEARCH_TEXT = re.compile(
    r"\b(?:password|passcode|api key|private key|credit card|bank account|social security|"
    r"medical|diagnosis|phone number|email address|home address)\b",
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
        "persona": {"active": DEFAULT_PERSONA_ID},
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
    persona_initialized: bool = False
    owner_lease_ms: int = DEFAULT_BRAIN_OWNER_LEASE_MS
    owner_expirations: int = 0
    owner_promotions: int = 0

    @staticmethod
    def _validated_persona_id(value: object) -> str:
        try:
            raw_persona_id = str(value or "").strip().lower()
            persona_id = normalize_persona_id(raw_persona_id)
            if raw_persona_id != persona_id:
                raise PersonaPackError("persona id must not contain path or normalization characters")
            return load_and_validate_persona_pack(persona_id).pack_id
        except (OSError, PersonaPackError, ValueError) as exc:
            raise ValueError(f"persona_invalid:{exc}") from exc

    def initialize_persona(self, value: object) -> str:
        if self.persona_initialized:
            return self.active_persona_id()
        persona_id = self._validated_persona_id(value or DEFAULT_PERSONA_ID)
        persona = self.settings.setdefault("persona", {})
        if not isinstance(persona, dict):
            persona = {}
            self.settings["persona"] = persona
        persona["active"] = persona_id
        self.persona_initialized = True
        return persona_id

    def active_persona_id(self) -> str:
        persona = self.settings.get("persona", {})
        if not isinstance(persona, dict):
            return DEFAULT_PERSONA_ID
        try:
            return normalize_persona_id(str(persona.get("active") or DEFAULT_PERSONA_ID))
        except PersonaPackError:
            return DEFAULT_PERSONA_ID

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

    def endpoint_healthy(self, endpoint: EndpointRecord, observed_ms: int) -> bool:
        lease_ms = max(1_000, int(self.owner_lease_ms))
        age_ms = max(0, observed_ms - endpoint.last_seen_ms)
        return endpoint.last_seen_ms > 0 and age_ms <= lease_ms

    def reconcile_owner(self, observed_ms: int | None = None) -> str:
        current_ms = now_ms() if observed_ms is None else max(0, int(observed_ms))
        owner = self.trusted_endpoints.get(self.active_brain_owner)
        if (
            owner is not None
            and "brain_owner" in owner.capabilities
            and self.endpoint_healthy(owner, current_ms)
        ):
            return "healthy"
        expired_owner = self.active_brain_owner
        if expired_owner:
            self.owner_expirations += 1
        self.active_brain_owner = ""
        promoted = self.promote_best_endpoint(exclude=expired_owner, observed_ms=current_ms)
        if promoted:
            self.owner_promotions += 1
            return "promoted"
        return "offline"

    def owner_status(self, state: str = "") -> dict[str, object]:
        resolved_state = state or self.reconcile_owner()
        owner = self.trusted_endpoints.get(self.active_brain_owner)
        return {
            "type": "owner_status",
            "active_brain_owner": self.active_brain_owner,
            "owner_kind": owner.endpoint_kind if owner else "",
            "state": resolved_state if self.active_brain_owner else "offline",
            "trusted_endpoint_count": len(self.trusted_endpoints),
            "owner_lease_ms": max(1_000, int(self.owner_lease_ms)),
            "owner_expirations": self.owner_expirations,
            "owner_promotions": self.owner_promotions,
        }

    def claim_brain(self, message: dict[str, Any]) -> dict[str, object]:
        endpoint_id = self.touch_endpoint(message.get("endpoint_id"))
        if not endpoint_id:
            return error_frame("endpoint_id_required")
        if endpoint_id not in self.trusted_endpoints:
            return error_frame("endpoint_not_trusted", endpoint_id)
        candidate = self.trusted_endpoints[endpoint_id]
        if "brain_owner" not in candidate.capabilities:
            return error_frame("brain_owner_capability_missing", endpoint_id)
        self.active_brain_owner = endpoint_id
        return self.owner_status("claimed")

    def release_brain(self, message: dict[str, Any]) -> dict[str, object]:
        endpoint_id = self.touch_endpoint(message.get("endpoint_id"))
        if not endpoint_id:
            return error_frame("endpoint_id_required")
        if endpoint_id and self.active_brain_owner and endpoint_id != self.active_brain_owner:
            return error_frame("brain_owner_mismatch", endpoint_id)
        released = self.active_brain_owner
        self.active_brain_owner = ""
        promoted = self.promote_best_endpoint(exclude=released, observed_ms=now_ms())
        if promoted:
            self.owner_promotions += 1
        return self.owner_status("promoted" if promoted else "released")

    def promote_best_endpoint(self, *, exclude: str = "", observed_ms: int | None = None) -> str:
        current_ms = now_ms() if observed_ms is None else max(0, int(observed_ms))
        candidates = [
            endpoint
            for endpoint in self.trusted_endpoints.values()
            if endpoint.auto_connect
            and endpoint.endpoint_id != exclude
            and "brain_owner" in endpoint.capabilities
            and self.endpoint_healthy(endpoint, current_ms)
        ]
        if not candidates:
            return ""
        candidates.sort(key=lambda endpoint: (endpoint.priority, endpoint.last_seen_ms), reverse=True)
        self.active_brain_owner = candidates[0].endpoint_id
        return self.active_brain_owner

    def trusted_endpoints_frame(self) -> dict[str, object]:
        self.reconcile_owner()
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
            if self.promote_best_endpoint(exclude=endpoint_id, observed_ms=now_ms()):
                self.owner_promotions += 1
        return {
            "type": "forget_endpoint_result",
            "endpoint_id": endpoint_id,
            "ok": removed,
            "active_brain_owner": self.active_brain_owner,
            "trusted_endpoint_count": len(self.trusted_endpoints),
        }

    def _settings_snapshot_dict(self) -> dict[str, object]:
        self.reconcile_owner()
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
        updates = copy.deepcopy(updates)
        persona_update = updates.get("persona")
        if "persona" in updates and not isinstance(persona_update, dict):
            return error_frame("persona_invalid", "persona settings must be an object")
        if isinstance(persona_update, dict) and "active" in persona_update:
            try:
                persona_update["active"] = self._validated_persona_id(persona_update.get("active"))
            except ValueError as exc:
                return error_frame("persona_invalid", str(exc).split(":", 1)[-1])
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
        if isinstance(persona_update, dict) and "active" in persona_update:
            self.persona_initialized = True
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
        owner_state = self.reconcile_owner()
        return {
            "type": "diagnostics_snapshot",
            "bridge": {
                "protocol": PROTOCOL,
                "active_brain_owner": self.active_brain_owner,
                "owner_state": owner_state,
                "owner_lease_ms": max(1_000, int(self.owner_lease_ms)),
                "owner_expirations": self.owner_expirations,
                "owner_promotions": self.owner_promotions,
                "trusted_endpoint_count": len(self.trusted_endpoints),
                "settings_version": self.settings_version,
                "mode_policy": self._settings_snapshot_dict().get("bridge", {}).get("mode_policy", "auto"),
            },
            "model": {
                "profile": config.runner_profile,
                "require_runner": config.require_runner,
                "persona": self.active_persona_id(),
            },
            "research": {
                "enabled": config.research_enabled,
                "tools": ["local_clock", "memory_recall"]
                + (["web_search", "web_fetch"] if config.research_enabled else []),
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
    persona_id: str = DEFAULT_PERSONA_ID
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
    conversation_v2_enabled: bool = False
    conversation_reply_window_ms: int = 8_000
    conversation_acoustic_tail_ms: int = 250
    conversation_cooldown_ms: int = 300
    conversation_max_turns: int = 12
    once: bool = False


@dataclass
class AudioUpload:
    sample_rate: int = DEFAULT_SAMPLE_RATE
    active: bool = False
    bytes_received: int = 0
    chunks: int = 0
    truncated: bool = False
    buffer: bytearray = field(default_factory=bytearray)
    started_at_monotonic: float = 0.0

    def start(self, sample_rate: object = DEFAULT_SAMPLE_RATE) -> None:
        self.clear()
        try:
            parsed_rate = int(sample_rate)
        except (TypeError, ValueError):
            parsed_rate = DEFAULT_SAMPLE_RATE
        self.sample_rate = max(8000, min(48000, parsed_rate))
        self.active = True
        self.started_at_monotonic = time.perf_counter()

    def clear(self) -> None:
        self.active = False
        self.bytes_received = 0
        self.chunks = 0
        self.truncated = False
        self.started_at_monotonic = 0.0
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
        summary: dict[str, object] = {
            "audio_bytes": self.bytes_received,
            "audio_stored_bytes": self.stored_bytes,
            "audio_chunks": self.chunks,
            "audio_sample_rate": self.sample_rate,
            "audio_duration_ms": self.duration_ms,
            "audio_truncated": self.truncated,
        }
        if self.started_at_monotonic > 0.0:
            summary["audio_capture_elapsed_ms"] = round(
                (time.perf_counter() - self.started_at_monotonic) * 1000.0,
                2,
            )
        return summary

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


def identity_character_response(display_name: str = "Stackchan") -> str:
    clean_name = " ".join(str(display_name or "Stackchan").split())[:80] or "Stackchan"
    return json.dumps(
        {
            "spoken_text": f"I am {clean_name}.",
            "mode": "happy",
            "earcon": "confirm",
            "emotion": {"arousal": 0.15, "valence": 0.35},
            "memory_write": {},
            "memory_forget": [],
        },
        separators=(",", ":"),
        ensure_ascii=True,
    )


def explicit_research_request(text: str) -> dict[str, object] | None:
    query = " ".join(str(text or "").split())
    if not query or len(query) > 240 or SENSITIVE_RESEARCH_TEXT.search(query):
        return None
    if not EXPLICIT_RESEARCH_REQUEST.search(query):
        return None
    return {"name": "web_search", "arguments": {"query": query, "max_results": 4}}


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
        try:
            self.control_state.initialize_persona(config.persona_id)
        except ValueError as exc:
            raise ValueError(str(exc)) from exc
        self.session = "lan"
        self.endpoint_id = ""
        self.next_seq = 1
        self.audio = AudioUpload()
        self.robot_embodiment = RobotEmbodimentState()
        self._active_turn_lock = threading.Lock()
        self._active_turn_token: CancellationToken | None = None
        self.conversation: ConversationSession | None = None
        self.conversation_response_seq = 0
        if config.conversation_v2_enabled:
            if not config.tts_command or config.disable_audio_downlink:
                raise ValueError(
                    "conversation v2 requires configured TTS and audio downlink for playback confirmation"
                )
            self.conversation = ConversationSession(
                ConversationConfig(
                    reply_window_ms=config.conversation_reply_window_ms,
                    acoustic_tail_ms=config.conversation_acoustic_tail_ms,
                    cooldown_ms=config.conversation_cooldown_ms,
                    max_turns=config.conversation_max_turns,
                )
            )
        self.research_broker = research_broker
        if self.research_broker is None and config.research_enabled:
            self.research_broker = ResearchBroker(ResearchBrokerConfig(searxng_url=config.searxng_url))

    def _conversation_payload(self, transition=None, *, observed_ms: int | None = None) -> dict[str, object]:
        if self.conversation is None:
            return {}
        current_ms = now_ms() if observed_ms is None else int(observed_ms)
        payload: dict[str, object] = {
            "conversation_v2_enabled": True,
            **self.conversation.snapshot(current_ms),
        }
        if transition is not None:
            payload["conversation_actions"] = list(transition.actions)
            payload["conversation_reason"] = transition.reason
        return payload

    def _conversation_heartbeat(self, transition=None, *, observed_ms: int | None = None) -> dict[str, object]:
        return {"type": "heartbeat", **self._conversation_payload(transition, observed_ms=observed_ms)}

    def _conversation_context_lines(self) -> tuple[str, ...]:
        return self.conversation.context_lines() if self.conversation is not None else ()

    def cancel_active_turn(self, reason: str = "cancelled") -> bool:
        with self._active_turn_lock:
            token = self._active_turn_token
        if token is None:
            return False
        token.cancel(reason)
        return True

    def active_turn_in_progress(self) -> bool:
        with self._active_turn_lock:
            return self._active_turn_token is not None

    def _active_persona(self) -> PersonaPack:
        return load_and_validate_persona_pack(self.control_state.active_persona_id())

    def _handle_settings_set(self, message: dict[str, Any]) -> dict[str, object]:
        updates = message.get("settings")
        persona_update = updates.get("persona") if isinstance(updates, dict) else None
        changes_persona = isinstance(persona_update, dict) and "active" in persona_update
        if changes_persona and self.active_turn_in_progress():
            return error_frame("persona_busy", "wait for the active turn to finish or cancel it")
        previous_persona = self.control_state.active_persona_id()
        frame = self.control_state.settings_set(message)
        current_persona = self.control_state.active_persona_id()
        if frame.get("type") == "settings_result" and frame.get("ok") and current_persona != previous_persona:
            frame["persona_active"] = current_persona
            frame["persona_previous"] = previous_persona
            if self.conversation is not None:
                transition = self.conversation.cancel(now_ms(), "persona_changed")
                frame.update(self._conversation_payload(transition))
        return frame

    def _register_active_turn(self, token: CancellationToken) -> bool:
        with self._active_turn_lock:
            if self._active_turn_token is not None:
                return False
            self._active_turn_token = token
            return True

    def _finish_active_turn(self, token: CancellationToken) -> None:
        with self._active_turn_lock:
            if self._active_turn_token is token:
                self._active_turn_token = None

    def _stage_conversation_turn(self, user_text: str, response_text: str, tts_error: str) -> None:
        if self.conversation is not None and not tts_error:
            self.conversation.stage_turn(user_text, response_text)

    def _begin_conversation_capture(self, owner_id: str) -> dict[str, object] | None:
        if self.conversation is None:
            return None
        current_ms = now_ms()
        self.conversation.tick(current_ms)
        if self.conversation.phase == ConversationPhase.IDLE:
            self.conversation.wake(current_ms, owner_id)
        elif self.conversation.phase in (ConversationPhase.THINKING, ConversationPhase.SPEAKING):
            self.cancel_active_turn("barge_in")
            self.conversation.barge_in(current_ms)
        transition = self.conversation.utterance_started(current_ms)
        if "reject_utterance" in transition.actions:
            return error_frame("conversation_capture_closed", transition.reason)
        return None

    def _conversation_failure(self, code: str, detail: str) -> dict[str, object]:
        frame = error_frame(code, detail)
        if self.conversation is not None:
            if self.conversation.phase in (ConversationPhase.THINKING, ConversationPhase.SPEAKING):
                transition = self.conversation.turn_failed(now_ms(), code)
            else:
                transition = self.conversation.cancel(now_ms(), code)
            frame.update(self._conversation_payload(transition))
        return frame

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
        response_text_ready_ms: float,
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
            "response_gesture": turn.gesture,
            "tts_voice": str(tts_summary.get("tts_voice", "")),
            "tts_audio_payload_bytes": int(tts_summary.get("tts_audio_payload_bytes", 0)),
            "tts_error": tts_error,
            "validation_issues": list(validation_issues),
        }
        record.update(stt_log)
        record.update(runner_summary)
        record.update(tts_summary)
        record.update(audio_evidence_log)
        turn_elapsed_ms = (time.perf_counter() - turn_started) * 1000.0
        record["turn_elapsed_ms"] = round(turn_elapsed_ms, 2)
        record.update(
            build_conversation_latency_record(
                audio_summary=audio_summary,
                stt_summary=stt_log,
                brain_summary=runner_summary,
                tts_summary=tts_summary,
                response_text_ready_ms=response_text_ready_ms,
                turn_total_ms=turn_elapsed_ms,
            )
        )
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
            return [
                {
                    "type": "hello",
                    "protocol": PROTOCOL,
                    "session": self.session,
                    **self._conversation_payload(),
                }
            ]
        if message_type == "endpoint_hello":
            frame = self.control_state.register_endpoint(message)
            self.endpoint_id = str(frame.get("endpoint_id", self.endpoint_id)) if frame.get("type") != "error" else self.endpoint_id
            return [frame]
        if message_type == "heartbeat":
            self.robot_embodiment.update(message)
            conversation_transition = None
            if self.conversation is not None:
                conversation_transition = self.conversation.tick(now_ms())
            endpoint_id = self.control_state.touch_endpoint(message.get("endpoint_id") or self.endpoint_id)
            owner_state = self.control_state.reconcile_owner()
            frame: dict[str, object] = {
                "type": "heartbeat",
                "active_brain_owner": self.control_state.active_brain_owner,
                "owner_state": owner_state,
            }
            if endpoint_id:
                frame["endpoint_id"] = endpoint_id
            frame.update(self._conversation_payload(conversation_transition))
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
            return [self._handle_settings_set(message)]
        if message_type == "diagnostics_request":
            frame = self.control_state.diagnostics_snapshot(self.config)
            frame.update(self._conversation_payload())
            return [frame]
        if message_type == "capability_update":
            return [self._handle_capability_update(message)]
        if message_type == "utterance_start":
            owner_error = self._owner_gate(message)
            if owner_error is not None:
                return [owner_error]
            conversation_error = self._begin_conversation_capture(
                normalize_endpoint_id(message.get("endpoint_id") or self.endpoint_id)
            )
            if conversation_error is not None:
                return [conversation_error]
            self.audio.start(message.get("sample_rate", DEFAULT_SAMPLE_RATE))
            return [{"type": "listening", **self.audio.summary(), **self._conversation_payload()}]
        if message_type == "cancel":
            self.audio.clear()
            reason = str(message.get("reason") or "cancelled")
            self.cancel_active_turn(reason)
            if self.conversation is not None:
                transition = self.conversation.cancel(now_ms(), reason)
                return [self._conversation_heartbeat(transition)]
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
        if message_type == "playback_complete":
            try:
                seq = max(0, int(message.get("seq", 0)))
            except (TypeError, ValueError):
                return [error_frame("playback_complete_seq_invalid")]
            frame: dict[str, object] = {"type": "heartbeat", "playback_complete_seq": seq}
            if self.conversation is not None:
                if seq == 0 or seq != self.conversation_response_seq:
                    return [error_frame("playback_complete_seq_mismatch", str(seq))]
                transition = self.conversation.playback_completed(now_ms())
                frame = {
                    "type": "conversation_reply_window",
                    "seq": seq,
                    "open_after_ms": self.config.conversation_acoustic_tail_ms,
                    "window_ms": self.config.conversation_reply_window_ms,
                }
                frame.update(self._conversation_payload(transition))
            return [frame]
        return [error_frame("unsupported_message", message_type)]

    def _owner_gate(self, message: dict[str, Any]) -> dict[str, object] | None:
        endpoint_id = normalize_endpoint_id(message.get("endpoint_id") or self.endpoint_id)
        if not endpoint_id:
            return None
        self.control_state.touch_endpoint(endpoint_id)
        self.control_state.reconcile_owner()
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
        owner_state = self.control_state.reconcile_owner()
        return {
            "type": "capability_update_result",
            "endpoint_id": endpoint_id,
            "capabilities": list(endpoint.capabilities),
            "supports_binary_audio": endpoint.supports_binary_audio,
            "active_brain_owner": self.control_state.active_brain_owner,
            "owner_state": owner_state,
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
        self.control_state.touch_endpoint(self.endpoint_id)
        self.control_state.reconcile_owner()
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
        cancellation: CancellationToken | None = None,
    ) -> tuple[list[dict[str, object] | bytes], dict[str, object], str]:
        cancellation = cancellation or CancellationToken()
        emitted: list[dict[str, object] | bytes] = []

        def emit(frame: dict[str, object] | bytes) -> None:
            cancellation.raise_if_cancelled()
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
                "gesture": getattr(turn, "gesture", "none"),
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
                        cancellation=cancellation,
                    )
                    if bool(result.diagnostics.get("audio_truncated", False)):
                        raise TtsExecutionError("streaming TTS refused a truncated phrase")
                    if not result.audio_data:
                        raise TtsExecutionError("streaming TTS phrase produced no audio")
                except OperationCancelledError as exc:
                    rendered.put(("cancelled", exc))
                    return
                except Exception as exc:
                    rendered.put(("error", exc))
                    return
                rendered.put(("result", result))
            rendered.put(("done", None))

        producer = threading.Thread(target=render_phrases, name="stackchan-tts-producer", daemon=True)
        producer.start()
        try:
            while True:
                cancellation.raise_if_cancelled()
                try:
                    item_type, item = rendered.get(timeout=0.1)
                except queue.Empty:
                    continue
                if item_type == "done":
                    break
                if item_type == "cancelled":
                    raise item
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
                    cancellation.raise_if_cancelled()
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
        cancellation = CancellationToken()
        if not self._register_active_turn(cancellation):
            return [error_frame("turn_busy", "a response is already being generated")]
        try:
            return self._run_utterance_end(
                message,
                suppress_thinking=suppress_thinking,
                frame_sink=frame_sink,
                cancellation=cancellation,
            )
        except OperationCancelledError as exc:
            frame = error_frame("turn_cancelled", str(exc))
            frame.update(self._conversation_payload())
            return [frame]
        finally:
            self._finish_active_turn(cancellation)

    def _run_utterance_end(
        self,
        message: dict[str, Any],
        *,
        suppress_thinking: bool,
        frame_sink: Callable[[dict[str, object] | bytes], None] | None,
        cancellation: CancellationToken,
    ) -> list[dict[str, object] | bytes]:
        turn_started = time.perf_counter()
        cancellation.raise_if_cancelled()
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
            return [
                self._conversation_failure(
                    "empty_utterance", "utterance_end had no audio or transcript"
                )
                | audio_summary
            ]
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
                    self._conversation_failure(
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
                return [self._conversation_failure("stt_error", str(exc)) | audio_summary]
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
        cancellation.raise_if_cancelled()
        require_wake_phrase = self.config.require_audio_wake_phrase and (
            self.conversation is None or self.conversation.turns == 0
        )
        if has_audio and require_wake_phrase and not contains_stackchan_wake_phrase(user_text):
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
            return [
                self._conversation_failure(
                    "wake_phrase_required", "audio transcript did not contain Stackchan"
                )
                | audio_summary
            ]
        if self.conversation is not None:
            transition = self.conversation.utterance_committed(now_ms(), user_text)
            if "begin_generation" not in transition.actions:
                return [self._conversation_heartbeat(transition)]
        if user_text:
            self.memory = self.memory.remember_user_text(user_text)
            # Persist transcript-owned facts before model/TTS work so an explicit
            # remember request survives a later runner or audio failure.
            self._save_memory()

        try:
            active_persona = self._active_persona()
        except (OSError, PersonaPackError, ValueError) as exc:
            return [self._conversation_failure("persona_error", str(exc))]
        requested_case = str(message.get("runner_case", "")).strip()
        runner_summary: dict[str, object] = {"persona_id": active_persona.pack_id}
        research_result: dict[str, object] | None = None
        local_fact = resolve_local_fact(user_text, self.memory) if not requested_case else None
        if local_fact is not None:
            runner_case = "local_fact"
            raw_response = local_fact.character_response()
            runner_summary["runner_command_source"] = f"trusted_{local_fact.tool}"
            runner_summary["runner_elapsed_ms"] = 0.0
            runner_summary["local_fact_tool"] = local_fact.tool
        elif not requested_case and is_identity_question(user_text):
            runner_case = "identity"
            identity_name = (
                "Stackchan" if active_persona.pack_id == DEFAULT_PERSONA_ID else active_persona.display_name
            )
            raw_response = identity_character_response(identity_name)
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
                    memory_lines=tuple(self.memory.context_lines(user_text)),
                    conversation_lines=self._conversation_context_lines(),
                    cancellation=cancellation,
                    persona_id=active_persona.pack_id,
                )
            except (RunnerConfigurationError, RunnerExecutionError, ValueError) as exc:
                return [self._conversation_failure("runner_error", str(exc))]
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
                if tool_request is None:
                    tool_request = explicit_research_request(user_text)
                    if tool_request is not None:
                        runner_summary["research_routing"] = "explicit_user_request"
                else:
                    runner_summary["research_routing"] = "model_request"
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
                            memory_lines=tuple(self.memory.context_lines(user_text)),
                            conversation_lines=self._conversation_context_lines(),
                            cancellation=cancellation,
                            persona_id=active_persona.pack_id,
                        )
                    except (RunnerConfigurationError, RunnerExecutionError, ValueError) as exc:
                        return [self._conversation_failure("runner_error", str(exc))]
                    raw_response = self._clear_research_memory_writes(researched.raw_response)
                    runner_summary["research_tool"] = str(research_result.get("tool", ""))
                    runner_summary["research_source_urls"] = list(source_urls(research_result))
                    runner_summary["research_error"] = str(research_result.get("error", ""))
                    if researched.elapsed_ms is not None:
                        runner_summary["research_runner_elapsed_ms"] = round(researched.elapsed_ms, 2)

        cancellation.raise_if_cancelled()
        turn, candidate_memory, validation = turn_from_character_response(
            raw_response,
            self.memory,
            session=self.session,
            seq=seq,
            persona=active_persona,
        )
        if research_result is not None:
            turn = replace(turn, citations=source_urls(research_result))
        if self.conversation is not None:
            transition = self.conversation.response_started(now_ms())
            if "reject_response" in transition.actions:
                return [self._conversation_failure("conversation_response_rejected", transition.reason)]
            self.conversation_response_seq = seq
        response_text_ready_ms = (time.perf_counter() - turn_started) * 1000.0
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
                cancellation=cancellation,
            )
            if tts_error and self.conversation is not None:
                self.conversation.turn_failed(now_ms(), "tts_error")
            cancellation.raise_if_cancelled()
            self.memory = candidate_memory
            self._stage_conversation_turn(user_text, turn.text, tts_error)
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
                response_text_ready_ms=response_text_ready_ms,
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
                cancellation=cancellation,
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
                tts_summary["tts_first_audio_ms"] = round(
                    (time.perf_counter() - turn_started) * 1000.0,
                    2,
                )
                if self.config.disable_audio_downlink:
                    tts_summary["tts_audio_downlink_disabled"] = True
                else:
                    downlink_frames = audio_downlink_frames(seq, tts, self.config.downlink_audio_chunk_bytes)
        except TtsConfigurationError:
            pass
        except (TtsExecutionError, ValueError) as exc:
            tts_error = str(exc)
        if tts_error and self.conversation is not None:
            self.conversation.turn_failed(now_ms(), "tts_error")
        cancellation.raise_if_cancelled()
        self.memory = candidate_memory
        self._stage_conversation_turn(user_text, turn.text, tts_error)
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
            response_text_ready_ms=response_text_ready_ms,
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
    send_lock = threading.RLock()
    turn_thread: threading.Thread | None = None
    turn_errors: queue.Queue[BaseException] = queue.Queue()

    def send_live(frame: dict[str, object] | bytes) -> None:
        nonlocal pending_short_chunk
        with send_lock:
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

    def discard_pending_audio() -> None:
        nonlocal pending_short_chunk
        with send_lock:
            pending_short_chunk = None

    def run_turn(text: str, suppress_thinking: bool) -> None:
        try:
            frames = session.handle_text(
                text,
                suppress_thinking=suppress_thinking,
                frame_sink=send_live if config.stream_tts_phrases else None,
            )
            for frame in frames:
                send_live(frame)
        except Exception as exc:  # surfaced on the connection thread
            turn_errors.put(exc)

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
    try:
        while True:
            if not turn_errors.empty():
                raise turn_errors.get_nowait()
            opcode, payload = read_ws_frame(conn)
            if opcode == 0x8:
                session.cancel_active_turn("connection_closed")
                discard_pending_audio()
                with send_lock:
                    conn.sendall(encode_ws_close())
                break
            if opcode == 0x9:
                with send_lock:
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

                if text_message_type in ("cancel", "utterance_start"):
                    session.cancel_active_turn(
                        str(parsed_text.get("reason") or "barge_in")
                        if isinstance(parsed_text, dict)
                        else "barge_in"
                    )
                    discard_pending_audio()

                if text_message_type == "utterance_end":
                    if turn_thread is not None and turn_thread.is_alive():
                        turn_thread.join(timeout=1.5)
                    if turn_thread is not None and turn_thread.is_alive():
                        send_live(error_frame("turn_busy", "the cancelled response is still stopping"))
                        continue
                    early_frame = session.early_thinking_frame(text)
                    if early_frame is not None:
                        send_live(early_frame)
                    turn_thread = threading.Thread(
                        target=run_turn,
                        args=(text, early_frame is not None),
                        name="stackchan-turn-worker",
                        daemon=True,
                    )
                    turn_thread.start()
                    continue

                frames = session.handle_text(text)
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
    finally:
        session.cancel_active_turn("connection_closed")
        discard_pending_audio()
        if turn_thread is not None and turn_thread.is_alive():
            turn_thread.join(timeout=2.0)
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
    parser.add_argument("--persona", default=DEFAULT_PERSONA_ID, help="Validated persona pack id.")
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
    parser.add_argument("--conversation-v2", action="store_true")
    parser.add_argument("--conversation-reply-window-ms", type=int, default=8000)
    parser.add_argument("--conversation-acoustic-tail-ms", type=int, default=250)
    parser.add_argument("--conversation-cooldown-ms", type=int, default=300)
    parser.add_argument("--conversation-max-turns", type=int, default=12)
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
        persona_id=args.persona,
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
        conversation_v2_enabled=args.conversation_v2,
        conversation_reply_window_ms=max(1000, min(30000, args.conversation_reply_window_ms)),
        conversation_acoustic_tail_ms=max(0, min(2000, args.conversation_acoustic_tail_ms)),
        conversation_cooldown_ms=max(0, min(5000, args.conversation_cooldown_ms)),
        conversation_max_turns=max(1, min(50, args.conversation_max_turns)),
    )
    serve(config)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
