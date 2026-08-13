#!/usr/bin/env python3
"""Minimal LAN WebSocket bridge service for stackchan.bridge.v1."""

from __future__ import annotations

import argparse
import base64
import copy
import hashlib
import ipaddress
import json
import math
import os
import queue
import re
import socket
import sys
import threading
import time
import wave
from array import array
from dataclasses import dataclass, field, replace
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Callable

from cancellation import CancellationToken, OperationCancelledError
from bridge_memory import RelationshipCard, explicit_forget_keys, topics_for_user_text
from character_harness import trusted_visual_context_available
from episode_distillation import (
    apply_distillation,
    distillation_turns_safe,
    request_distillation,
    validate_distillation,
)
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
    reset_bridge_memory,
    save_bridge_memory,
    turn_from_character_response,
)
from stt_adapter import (
    DEFAULT_STT_TIMEOUT_MS,
    SttConfigurationError,
    SttExecutionError,
    SttNoTranscriptError,
    transcribe_pcm,
)
from stt_supervisor import SttServerSupervisor, SttSupervisorConfig
from transcript_diagnostics import (
    expected_transcript_metrics,
    validate_critical_tokens,
    validate_expected_text,
)
from tts_adapter import (
    DEFAULT_TTS_TIMEOUT_MS,
    DEFAULT_TTS_VOICE,
    TtsConfigurationError,
    TtsExecutionError,
    split_spoken_phrases,
    synthesize_speech,
)
from utterance_text import normalize_user_utterance
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
from conversation_harness import ConversationTurnPlan, weather_result_matches
from conversation_session import ConversationConfig, ConversationPhase, ConversationSession
from initiative_policy import (
    MIN_UNPROMPTED_INTERVAL_MS,
    InitiativeConfig,
    InitiativeDecision,
    InitiativePolicy,
)
from room_context import (
    ExternalRoomVisionModel,
    PrivateCameraFrameSource,
    RoomContextRuntime,
    RoomObservationConfig,
    RoomSceneSummary,
)
from dashboard_service import (
    DEFAULT_DASHBOARD_HOST,
    DEFAULT_DASHBOARD_PORT,
    DEFAULT_ROBOT_HTTP_PORT,
    DashboardConfig,
    DashboardRuntime,
    start_dashboard_server,
    stop_dashboard_server,
)

WEBSOCKET_GUID = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"
MAX_TEXT_BYTES = 65535
DEFAULT_SAMPLE_RATE = 16000
DEFAULT_MAX_AUDIO_BYTES = 512 * 1024
DEFAULT_AUDIO_CAPTURE_ABSOLUTE_LEASE_MS = 14_500
DEFAULT_AUDIO_CAPTURE_INACTIVITY_LEASE_MS = 4_000
DEFAULT_DOWNLINK_AUDIO_CHUNK_BYTES = 4096
DEFAULT_DOWNLINK_BINARY_FRAME_DELAY_MS = 180
DEFAULT_DOWNLINK_TEXT_FRAME_DELAY_MS = 40
MIN_DOWNLINK_PACING_HEADROOM_MS = 25.0
DEFAULT_CLIENT_IDLE_TIMEOUT_S = 20.0
DEFAULT_TCP_KEEPALIVE_IDLE_MS = 5_000
DEFAULT_TCP_KEEPALIVE_INTERVAL_MS = 1_000
DEFAULT_TTS_PHRASE_MAX_CHARS = 96
DEFAULT_BRAIN_OWNER_LEASE_MS = 15_000
MAX_DOWNLINK_AUDIO_CHUNK_BYTES = 4096
MAX_TRUSTED_ENDPOINTS = 8
BRIDGE_WEBSOCKET_PATH = "/bridge"
MAX_BRIDGE_DEVICE_ID_CHARS = 64
MAX_WEBSOCKET_KEY_CHARS = 128
MAX_WEBSOCKET_KEY_DECODED_BYTES = 96
_BRIDGE_DEVICE_ID_RE = re.compile(
    rf"[A-Za-z0-9._-]{{1,{MAX_BRIDGE_DEVICE_ID_CHARS}}}\Z"
)
_SECURITY_CRITICAL_UPGRADE_HEADERS = frozenset(
    {
        "upgrade",
        "connection",
        "sec-websocket-key",
        "sec-websocket-version",
        "x-stackchan-protocol",
        "x-stackchan-device",
        "origin",
    }
)
REPLY_PCM_CHUNK_MS = 50
REPLY_PCM_MINIMUM_SPEECH_MS = 150
REPLY_PCM_INITIAL_NOISE_FLOOR = 0.015
REPLY_PCM_MINIMUM_SPEECH_LEVEL = 0.040
REPLY_PCM_SPEECH_NOISE_MULTIPLIER = 2.6
REPLY_PCM_SPEECH_ZCR_MIN = 0.025
REPLY_PCM_SPEECH_ZCR_MAX = 0.35
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
FRESH_RESEARCH_SIGNAL = re.compile(
    r"\b(?:today|tonight|tomorrow|yesterday|latest|current|currently|recent|recently|"
    r"this (?:week|month|year)|right now|breaking|newest|up[- ]to[- ]date|"
    r"news|weather|forecast|price|stock|market|score|schedule|standings|traffic|"
    r"release|version|update|election|president|prime minister|governor|mayor|ceo|"
    r"availability)\b",
    flags=re.IGNORECASE,
)
VERIFICATION_RESEARCH_SIGNAL = re.compile(
    r"\b(?:check|verify|fact[- ]check|confirm|find out|research)\b",
    flags=re.IGNORECASE,
)
INFORMATION_REQUEST = re.compile(
    r"(?:\?|\b(?:what|who|when|where|why|how|which|is|are|was|were|did|does|do|can|"
    r"tell me|give me|check|find)\b)",
    flags=re.IGNORECASE,
)
PRIVATE_OR_EMBODIED_RESEARCH_TEXT = re.compile(
    r"\b(?:how are you|what do you (?:see|hear|feel)|your (?:current )?(?:mood|feeling|battery|power|"
    r"sensor|touch|servo|camera|microphone|body|connection|wifi|bridge)|"
    r"my (?:calendar|email|inbox|messages|files|account|location))\b",
    flags=re.IGNORECASE,
)
SENSITIVE_RESEARCH_TEXT = re.compile(
    r"\b(?:password|passcode|api key|private key|credit card|bank account|social security|"
    r"medical|diagnosis|phone number|email address|home address)\b",
    flags=re.IGNORECASE,
)
DISABLE_INITIATIVE_REQUEST = re.compile(
    r"^\s*(?:please\s+)?(?:"
    r"stop checking in|"
    r"do not (?:start conversations|speak unless i (?:ask|start)|check in)|"
    r"turn off (?:initiative|check[- ]?ins?|proactive prompts?)|"
    r"no (?:initiative|check[- ]?ins?|proactive prompts?)"
    r")\s*[.!?]*$",
    flags=re.IGNORECASE,
)
ENABLE_INITIATIVE_REQUEST = re.compile(
    r"^\s*(?:please\s+)?(?:"
    r"you (?:can|may) check in again|"
    r"you (?:can|may) start conversations again|"
    r"turn on (?:initiative|check[- ]?ins?|proactive prompts?)|"
    r"resume (?:initiative|check[- ]?ins?|proactive prompts?)"
    r")\s*[.!?]*$",
    flags=re.IGNORECASE,
)
RESEARCH_ACCESS_DENIAL = re.compile(
    r"\b(?:i (?:do not|don't|cannot|can't) (?:access|browse|search|use|check)|"
    r"i (?:do not|don't) have access to|no access to|unable to (?:access|browse|search|use))"
    r".{0,48}\b(?:internet|web|online|browser)\b",
    flags=re.IGNORECASE | re.DOTALL,
)
VISUAL_COLOR_REQUEST = re.compile(
    r"\b(?:what|which) colou?r (?:is|are) (?:this|that|it|these|those|my)\b|"
    r"\bcan you (?:tell|see|check).{0,32}\bcolou?r\b|"
    r"\bcolou?r (?:of|on) (?:this|that|it|these|those|my)\b",
    flags=re.IGNORECASE,
)
VISUAL_CONTEXT_REQUEST = re.compile(
    r"\bwhat (?:do|can) you see\b|"
    r"\b(?:can|do) you see (?!if\b|whether\b)|"
    r"\blook at (?:this|that|it|me|my|the room|the desk)\b|"
    r"\bwhat(?:'s| is) (?:in front of you|in (?:this|the) room|on my desk)\b|"
    r"\bhow many (?:people|persons|objects) (?:do|can) you see\b",
    flags=re.IGNORECASE,
)
CONVERSATIONAL_QUESTION = re.compile(
    r"^(?:what|who|when|where|why|how|which|is|are|was|were|did|does|do|"
    r"can|could|would|will|should|have|has|tell me|give me|check|find)\b",
    flags=re.IGNORECASE,
)
GREETING_ONLY = re.compile(
    r"^(?:(?:hello|hi|hey)(?: there)?|good (?:morning|afternoon|evening))[.!?]*$",
    flags=re.IGNORECASE,
)
LEADING_GREETING = re.compile(
    r"^(?:(?:hello|hi|hey)(?: there)?|good (?:morning|afternoon|evening))[,!.:; -]*",
    flags=re.IGNORECASE,
)


class WebSocketProtocolError(RuntimeError):
    """Raised when a client sends an invalid WebSocket handshake or frame."""


def now_ms() -> int:
    return int(time.time() * 1000)


def utc_timestamp() -> str:
    return datetime.now(timezone.utc).replace(microsecond=0).isoformat().replace("+00:00", "Z")


def analyze_reply_pcm16_speech(pcm: bytes, sample_rate: int) -> dict[str, object]:
    """Mirror the device reply VAD so ambient max-duration captures do not reach STT."""

    diagnostics: dict[str, object] = {
        "reply_pcm_speech_gate_applied": True,
        "reply_pcm_speech_detected": None,
        "reply_pcm_detection_reason": "invalid_pcm",
    }
    if sample_rate <= 0 or not pcm or len(pcm) % 2:
        return diagnostics

    samples = array("h")
    samples.frombytes(pcm)
    if sys.byteorder != "little":
        samples.byteswap()
    if not samples:
        return diagnostics

    chunk_samples = max(1, (sample_rate * REPLY_PCM_CHUNK_MS) // 1000)
    noise_floor = REPLY_PCM_INITIAL_NOISE_FLOOR
    consecutive_speech_ms = 0
    maximum_consecutive_speech_ms = 0
    speech_chunks = 0
    chunks = 0
    peak_level = 0.0
    speech_seen = False

    for offset in range(0, len(samples), chunk_samples):
        chunk = samples[offset : offset + chunk_samples]
        if not chunk:
            continue
        chunks += 1
        squares = sum((float(sample) / 32768.0) ** 2 for sample in chunk)
        level = min(1.0, math.sqrt(squares / len(chunk)))
        peak_level = max(peak_level, level)

        crossings = 0
        previous = chunk[0]
        for current in chunk[1:]:
            if (previous < 0 <= current) or (previous >= 0 > current):
                crossings += 1
            previous = current
        zero_crossing_rate = crossings / max(1, len(chunk) - 1)
        speech_threshold = max(
            noise_floor * REPLY_PCM_SPEECH_NOISE_MULTIPLIER,
            REPLY_PCM_MINIMUM_SPEECH_LEVEL,
        )
        speech = (
            REPLY_PCM_SPEECH_ZCR_MIN <= zero_crossing_rate <= REPLY_PCM_SPEECH_ZCR_MAX
            and level >= speech_threshold
        )
        chunk_ms = max(1, math.ceil(len(chunk) * 1000 / sample_rate))
        if speech:
            speech_chunks += 1
            consecutive_speech_ms += chunk_ms
            maximum_consecutive_speech_ms = max(
                maximum_consecutive_speech_ms,
                consecutive_speech_ms,
            )
            if consecutive_speech_ms >= REPLY_PCM_MINIMUM_SPEECH_MS:
                speech_seen = True
        else:
            consecutive_speech_ms = 0
            if not speech_seen:
                adapt = 0.04 if level < noise_floor else 0.01
                noise_floor = max(0.005, noise_floor + ((level - noise_floor) * adapt))

    diagnostics.update(
        {
            "reply_pcm_speech_detected": speech_seen,
            "reply_pcm_detection_reason": "speech" if speech_seen else "no_speech",
            "reply_pcm_chunks_analyzed": chunks,
            "reply_pcm_speech_chunks": speech_chunks,
            "reply_pcm_max_consecutive_speech_ms": maximum_consecutive_speech_ms,
            "reply_pcm_peak_level": round(peak_level, 6),
            "reply_pcm_final_noise_floor": round(noise_floor, 6),
        }
    )
    return diagnostics


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
    in_process_ollama_runner: bool = False
    require_runner: bool = False
    runner_timeout_ms: int = 60000
    persona_id: str = DEFAULT_PERSONA_ID
    stt_command: str = ""
    stt_server_url: str = ""
    stt_restart_command: str = ""
    stt_health_interval_s: float = 2.0
    stt_timeout_ms: int = DEFAULT_STT_TIMEOUT_MS
    stt_min_confidence: float = 0.45
    stt_diagnostic_expected_text: str = ""
    stt_diagnostic_critical_tokens: tuple[str, ...] = ()
    require_audio_wake_phrase: bool = False
    tts_command: str = ""
    in_process_directml_tts: bool = False
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
    audio_capture_absolute_lease_ms: int = DEFAULT_AUDIO_CAPTURE_ABSOLUTE_LEASE_MS
    audio_capture_inactivity_lease_ms: int = DEFAULT_AUDIO_CAPTURE_INACTIVITY_LEASE_MS
    audio_evidence_dir: Path | None = None
    memory_file: Path | None = None
    turn_log_file: Path | None = None
    redact_turn_text: bool = False
    auto_turn_text: str = ""
    research_enabled: bool = False
    searxng_url: str = "http://127.0.0.1:8080"
    conversation_v2_enabled: bool = False
    conversation_reply_window_ms: int = 10_000
    conversation_reply_window_min_ms: int = 10_000
    conversation_reply_window_step_ms: int = 0
    conversation_acoustic_tail_ms: int = 250
    conversation_cooldown_ms: int = 300
    conversation_max_turns: int = 24
    conversation_max_context_turns: int = 24
    conversation_max_context_chars: int = 160
    initiative_enabled: bool = False
    initiative_min_interval_ms: int = MIN_UNPROMPTED_INTERVAL_MS
    room_observation_enabled: bool = False
    room_observation_interval_seconds: int = 300
    room_vision_command: str = ""
    room_vision_timeout_ms: int = 30_000
    camera_pairing_code_file: Path | None = None
    episode_distillation_enabled: bool = False
    dashboard_enabled: bool = False
    dashboard_host: str = DEFAULT_DASHBOARD_HOST
    dashboard_port: int = DEFAULT_DASHBOARD_PORT
    robot_host: str = ""
    robot_http_port: int = DEFAULT_ROBOT_HTTP_PORT
    once: bool = False

    def __post_init__(self) -> None:
        ConversationConfig(
            reply_window_ms=self.conversation_reply_window_ms,
            reply_window_min_ms=self.conversation_reply_window_min_ms,
            reply_window_step_ms=self.conversation_reply_window_step_ms,
            acoustic_tail_ms=self.conversation_acoustic_tail_ms,
            cooldown_ms=self.conversation_cooldown_ms,
            max_turns=self.conversation_max_turns,
            max_context_turns=self.conversation_max_context_turns,
            max_context_chars=self.conversation_max_context_chars,
        )
        InitiativeConfig(
            enabled=self.initiative_enabled,
            min_interval_ms=self.initiative_min_interval_ms,
        )
        RoomObservationConfig(
            enabled=self.room_observation_enabled,
            interval_seconds=self.room_observation_interval_seconds,
            command=self.room_vision_command,
            timeout_ms=self.room_vision_timeout_ms,
        )
        if self.stt_server_url:
            SttSupervisorConfig(
                server_url=self.stt_server_url,
                restart_command=self.stt_restart_command,
                health_interval_seconds=self.stt_health_interval_s,
            )
        if not 0.0 <= float(self.stt_min_confidence) <= 1.0:
            raise ValueError("stt_min_confidence must be between zero and one")
        if not 12_500 <= int(self.audio_capture_absolute_lease_ms) <= 15_000:
            raise ValueError("audio_capture_absolute_lease_ms must be between 12500 and 15000")
        if not 1_000 <= int(self.audio_capture_inactivity_lease_ms) < int(
            self.audio_capture_absolute_lease_ms
        ):
            raise ValueError(
                "audio_capture_inactivity_lease_ms must be between 1000 and the absolute lease"
            )
        if self.stt_diagnostic_expected_text:
            validate_expected_text(self.stt_diagnostic_expected_text)
            if self.turn_log_file is None:
                raise ValueError("STT expected-utterance diagnostics require a turn log")
            if not self.redact_turn_text:
                raise ValueError("STT expected-utterance diagnostics require redacted turn logs")
            if self.audio_evidence_dir is not None:
                raise ValueError("STT expected-utterance diagnostics forbid PCM evidence persistence")
            validate_critical_tokens(
                self.stt_diagnostic_expected_text,
                self.stt_diagnostic_critical_tokens,
            )
        elif self.stt_diagnostic_critical_tokens:
            raise ValueError("critical STT tokens require an expected diagnostic utterance")
        if not bridge_bind_is_loopback(self.host) and not self.robot_host.strip():
            raise ValueError("robot_host is required when the bridge bind is not loopback")


@dataclass(frozen=True)
class FinalizedAudioUpload:
    pcm: bytes
    summary: dict[str, object]


@dataclass
class AudioUpload:
    sample_rate: int = DEFAULT_SAMPLE_RATE
    active: bool = False
    bytes_received: int = 0
    chunks: int = 0
    truncated: bool = False
    buffer: bytearray = field(default_factory=bytearray)
    seq: int = 0
    absolute_lease_ms: int = DEFAULT_AUDIO_CAPTURE_ABSOLUTE_LEASE_MS
    inactivity_lease_ms: int = DEFAULT_AUDIO_CAPTURE_INACTIVITY_LEASE_MS
    started_at_monotonic: float | None = None
    last_activity_at_monotonic: float | None = None

    def start(
        self,
        sample_rate: object = DEFAULT_SAMPLE_RATE,
        *,
        seq: int = 0,
        absolute_lease_ms: int = DEFAULT_AUDIO_CAPTURE_ABSOLUTE_LEASE_MS,
        inactivity_lease_ms: int = DEFAULT_AUDIO_CAPTURE_INACTIVITY_LEASE_MS,
    ) -> None:
        self.clear()
        try:
            parsed_rate = int(sample_rate)
        except (TypeError, ValueError):
            parsed_rate = DEFAULT_SAMPLE_RATE
        self.sample_rate = max(8000, min(48000, parsed_rate))
        self.seq = max(0, int(seq))
        self.absolute_lease_ms = max(1, int(absolute_lease_ms))
        self.inactivity_lease_ms = max(1, int(inactivity_lease_ms))
        self.active = True
        self.started_at_monotonic = time.perf_counter()
        self.last_activity_at_monotonic = self.started_at_monotonic

    def clear(self) -> None:
        self.active = False
        self.bytes_received = 0
        self.chunks = 0
        self.truncated = False
        self.seq = 0
        self.started_at_monotonic = None
        self.last_activity_at_monotonic = None
        self.buffer.clear()

    def expiry_code(self, at_monotonic: float | None = None) -> str:
        if not self.active or self.started_at_monotonic is None:
            return ""
        current = time.perf_counter() if at_monotonic is None else float(at_monotonic)
        absolute_elapsed_ms = (current - self.started_at_monotonic) * 1000.0
        if absolute_elapsed_ms >= self.absolute_lease_ms:
            return "audio_capture_absolute_lease_expired"
        if self.last_activity_at_monotonic is not None:
            inactivity_elapsed_ms = (current - self.last_activity_at_monotonic) * 1000.0
            if inactivity_elapsed_ms >= self.inactivity_lease_ms:
                return "audio_capture_inactivity_expired"
        return ""

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
        self.last_activity_at_monotonic = time.perf_counter()

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
            "audio_capture_seq": self.seq,
            "audio_capture_absolute_lease_ms": self.absolute_lease_ms,
            "audio_capture_inactivity_lease_ms": self.inactivity_lease_ms,
        }
        if self.started_at_monotonic is not None:
            current = time.perf_counter()
            summary["audio_capture_elapsed_ms"] = round(
                (current - self.started_at_monotonic) * 1000.0,
                2,
            )
            if self.last_activity_at_monotonic is not None:
                summary["audio_capture_inactivity_ms"] = round(
                    (current - self.last_activity_at_monotonic) * 1000.0,
                    2,
                )
        return summary

    def finish_and_clear(self) -> dict[str, object]:
        summary = self.summary()
        self.clear()
        return summary

    def finalize(self) -> FinalizedAudioUpload:
        pcm = bytes(self.buffer)
        return FinalizedAudioUpload(pcm=pcm, summary=self.finish_and_clear())


def websocket_accept_value(client_key: str) -> str:
    digest = hashlib.sha1((client_key.strip() + WEBSOCKET_GUID).encode("ascii")).digest()
    return base64.b64encode(digest).decode("ascii")


@dataclass(frozen=True)
class WebSocketAdmission:
    client_key: str
    device_id: str


def bridge_bind_is_loopback(host: str) -> bool:
    candidate = str(host).strip()
    if candidate.lower() == "localhost":
        return True
    try:
        return ipaddress.ip_address(candidate).is_loopback
    except ValueError:
        return False


def normalize_peer_address(value: object) -> str:
    candidate = str(value).strip()
    if not candidate or "%" in candidate:
        return ""
    try:
        address = ipaddress.ip_address(candidate)
    except ValueError:
        return ""
    if isinstance(address, ipaddress.IPv6Address) and address.ipv4_mapped is not None:
        address = address.ipv4_mapped
    elif isinstance(address, ipaddress.IPv6Address) and address.is_link_local:
        return ""
    return str(address)


def resolve_robot_peer_addresses(config: LanBridgeConfig) -> frozenset[str] | None:
    if bridge_bind_is_loopback(config.host):
        return None
    try:
        resolved = socket.getaddrinfo(config.robot_host, None, type=socket.SOCK_STREAM)
    except socket.gaierror as exc:
        raise ValueError(f"robot_host could not be resolved: {config.robot_host}") from exc
    addresses = frozenset(
        normalized
        for normalized in (normalize_peer_address(item[4][0]) for item in resolved)
        if normalized
    )
    if not addresses:
        raise ValueError(f"robot_host resolved to no usable addresses: {config.robot_host}")
    return addresses


def peer_address_allowed(peer_address: object, allowed_addresses: frozenset[str]) -> bool:
    normalized = normalize_peer_address(peer_address)
    return bool(normalized and normalized in allowed_addresses)


def _parse_http_upgrade(request: bytes) -> tuple[str, dict[str, str]]:
    try:
        text = request.decode("iso-8859-1")
    except UnicodeDecodeError as exc:  # pragma: no cover - iso-8859-1 decodes all bytes
        raise WebSocketProtocolError("websocket handshake is not decodable") from exc
    header_text = text.split("\r\n\r\n", 1)[0]
    lines = header_text.split("\r\n")
    request_line = lines[0] if lines else ""
    headers: dict[str, str] = {}
    seen: set[str] = set()
    for line in lines[1:]:
        if not line:
            continue
        if ":" not in line:
            raise WebSocketProtocolError("malformed WebSocket upgrade header")
        key, value = line.split(":", 1)
        normalized_key = key.strip().lower()
        if not normalized_key:
            raise WebSocketProtocolError("malformed WebSocket upgrade header")
        if normalized_key in seen and normalized_key in _SECURITY_CRITICAL_UPGRADE_HEADERS:
            raise WebSocketProtocolError(f"duplicate WebSocket upgrade header: {normalized_key}")
        seen.add(normalized_key)
        headers[normalized_key] = value.strip()
    return request_line, headers


def parse_http_headers(request: bytes) -> dict[str, str]:
    _request_line, headers = _parse_http_upgrade(request)
    return headers


def validate_websocket_upgrade(request: bytes) -> WebSocketAdmission:
    request_line, headers = _parse_http_upgrade(request)
    if request_line != f"GET {BRIDGE_WEBSOCKET_PATH} HTTP/1.1":
        raise WebSocketProtocolError("websocket request target must be GET /bridge HTTP/1.1")
    upgrade = headers.get("upgrade", "").lower()
    connection_tokens = {
        token.strip().lower()
        for token in headers.get("connection", "").split(",")
        if token.strip()
    }
    client_key = headers.get("sec-websocket-key", "")
    version = headers.get("sec-websocket-version", "")
    protocol = headers.get("x-stackchan-protocol", "")
    device_id = headers.get("x-stackchan-device", "")
    if "origin" in headers:
        raise WebSocketProtocolError("browser Origin is not admitted")
    if upgrade != "websocket" or "upgrade" not in connection_tokens or not client_key:
        raise WebSocketProtocolError("missing WebSocket upgrade headers")
    if len(client_key) > MAX_WEBSOCKET_KEY_CHARS:
        raise WebSocketProtocolError("invalid Sec-WebSocket-Key")
    try:
        decoded_key = base64.b64decode(client_key.encode("ascii"), validate=True)
    except (UnicodeEncodeError, ValueError) as exc:
        raise WebSocketProtocolError("invalid Sec-WebSocket-Key") from exc
    if not decoded_key or len(decoded_key) > MAX_WEBSOCKET_KEY_DECODED_BYTES:
        raise WebSocketProtocolError("invalid Sec-WebSocket-Key")
    if version != "13":
        raise WebSocketProtocolError("unsupported WebSocket version")
    if protocol != PROTOCOL:
        raise WebSocketProtocolError("Stackchan bridge protocol mismatch")
    if not _BRIDGE_DEVICE_ID_RE.fullmatch(device_id):
        raise WebSocketProtocolError("Stackchan device header is missing or invalid")
    return WebSocketAdmission(client_key=client_key, device_id=device_id)


def _handshake_response(admission: WebSocketAdmission) -> bytes:
    client_key = admission.client_key
    accept = websocket_accept_value(client_key)
    response = (
        "HTTP/1.1 101 Switching Protocols\r\n"
        "Upgrade: websocket\r\n"
        "Connection: Upgrade\r\n"
        f"Sec-WebSocket-Accept: {accept}\r\n"
        "\r\n"
    )
    return response.encode("ascii")


def build_handshake_response(request: bytes) -> bytes:
    return _handshake_response(validate_websocket_upgrade(request))


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


def prompt_case_for_text(
    text: str,
    requested: str,
    default_case: str,
    *,
    has_conversation_context: bool = False,
) -> str:
    if requested:
        return requested
    clean = normalize_user_utterance(text)
    lowered = clean.lower()
    if "forget" in lowered:
        return "forget"
    if "picked" in lowered or "pick" in lowered:
        return "picked_up"
    if "battery" in lowered or "power" in lowered:
        return "low_battery"
    if "confused" in lowered or "ambiguous" in lowered:
        return "confused"
    if not clean:
        return "greeting" if contains_stackchan_wake_phrase(text) else "confused"
    if GREETING_ONLY.fullmatch(clean):
        return "greeting"
    question_text = LEADING_GREETING.sub("", clean).strip()
    if "?" in clean or CONVERSATIONAL_QUESTION.search(question_text):
        return "question"
    if has_conversation_context:
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


def no_speech_character_response() -> str:
    return json.dumps(
        {
            "spoken_text": "I did not catch that. Try again?",
            "mode": "concern",
            "earcon": "concern",
            "emotion": {"arousal": -0.1, "valence": -0.05},
            "memory_write": {},
            "memory_forget": [],
        },
        separators=(",", ":"),
        ensure_ascii=True,
    )


def low_confidence_character_response() -> str:
    return json.dumps(
        {
            "spoken_text": "I did not catch that cleanly. Say it once more?",
            "mode": "concern",
            "earcon": "concern",
            "emotion": {"arousal": -0.1, "valence": -0.05},
            "memory_write": {},
            "memory_forget": [],
        },
        separators=(",", ":"),
        ensure_ascii=True,
    )


def research_unavailable_character_response() -> str:
    return json.dumps(
        {
            "spoken_text": "I could not verify that just now. I can try again in a moment.",
            "mode": "concern",
            "earcon": "concern",
            "emotion": {"arousal": -0.1, "valence": -0.1},
            "memory_write": {},
            "memory_forget": [],
        },
        separators=(",", ":"),
        ensure_ascii=True,
    )


def model_failure_character_response() -> str:
    # Spoken when the character model itself fails. The user hears a short
    # in-character recovery line instead of unexplained silence; the real error
    # stays in runner telemetry, and the wire contract remains a normal turn.
    return json.dumps(
        {
            "spoken_text": "I lost my train of thought. Ask me once more?",
            "mode": "concern",
            "earcon": "concern",
            "emotion": {"arousal": -0.1, "valence": -0.1},
            "memory_write": {},
            "memory_forget": [],
        },
        separators=(",", ":"),
        ensure_ascii=True,
    )


def initiative_preference_from_text(text: object) -> bool | None:
    clean = " ".join(str(text or "").split())
    if DISABLE_INITIATIVE_REQUEST.fullmatch(clean):
        return False
    if ENABLE_INITIATIVE_REQUEST.fullmatch(clean):
        return True
    return None


def initiative_preference_character_response(
    enabled: bool,
    *,
    available: bool = True,
) -> str:
    if not available:
        spoken_text = "Proactive check-ins are unavailable in this bridge mode."
    elif not enabled:
        spoken_text = "I will wait for you to start conversations."
    else:
        spoken_text = "I can check in again, within the quiet-hour and rate limits."
    return json.dumps(
        {
            "spoken_text": spoken_text,
            "mode": "speak",
            "earcon": "confirm",
            "emotion": {"arousal": 0.0, "valence": 0.1},
            "memory_write": {},
            "memory_forget": [],
        },
        separators=(",", ":"),
        ensure_ascii=True,
    )


def grayscale_color_character_response() -> str:
    return json.dumps(
        {
            "spoken_text": "My current camera feed is grayscale, so I cannot determine that color.",
            "mode": "speak",
            "earcon": "none",
            "emotion": {"arousal": 0.0, "valence": 0.0},
            "memory_write": {},
            "memory_forget": [],
        },
        separators=(",", ":"),
        ensure_ascii=True,
    )


def visual_observation_unavailable_response(reason: str) -> str:
    if reason == "observation_disabled":
        spoken_text = "Room observation is turned off right now."
    elif reason == "observation_not_configured":
        spoken_text = "My local camera observer is not configured right now."
    else:
        spoken_text = "My camera check failed just now."
    return json.dumps(
        {
            "spoken_text": spoken_text,
            "mode": "concern",
            "earcon": "concern",
            "emotion": {"arousal": -0.1, "valence": -0.1},
            "memory_write": {},
            "memory_forget": [],
        },
        separators=(",", ":"),
        ensure_ascii=True,
    )


def forget_character_response(keys: tuple[str, ...]) -> str:
    return json.dumps(
        {
            "spoken_text": "Deleted. It is gone.",
            "mode": "concern",
            "earcon": "confirm",
            "emotion": {"arousal": 0.0, "valence": -0.1},
            "memory_write": {},
            "memory_forget": list(keys),
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


def natural_research_request(text: str) -> tuple[dict[str, object] | None, str]:
    """Route explicit or time-sensitive public questions without relying on a small model's tool choice."""
    query = " ".join(str(text or "").split())
    if not query or len(query) > 240 or SENSITIVE_RESEARCH_TEXT.search(query):
        return None, ""
    if PRIVATE_OR_EMBODIED_RESEARCH_TEXT.search(query) or is_visual_context_request(query):
        return None, ""
    explicit = explicit_research_request(query)
    if explicit is not None:
        return explicit, "explicit_user_request"
    if not INFORMATION_REQUEST.search(query):
        return None, ""
    if FRESH_RESEARCH_SIGNAL.search(query):
        routing = "freshness_policy"
    elif VERIFICATION_RESEARCH_SIGNAL.search(query):
        routing = "verification_request"
    else:
        return None, ""
    return {"name": "web_search", "arguments": {"query": query, "max_results": 4}}, routing


def research_result_succeeded(result: object) -> bool:
    if not isinstance(result, dict) or result.get("error"):
        return False
    rows = result.get("results")
    if isinstance(rows, list) and rows:
        return True
    return bool(str(result.get("excerpt", "")).strip())


def is_visual_color_request(text: str) -> bool:
    return bool(VISUAL_COLOR_REQUEST.search(" ".join(str(text or "").split())))


def is_visual_context_request(text: str) -> bool:
    query = " ".join(str(text or "").split())
    return bool(VISUAL_COLOR_REQUEST.search(query) or VISUAL_CONTEXT_REQUEST.search(query))


def model_denies_research_access(raw_response: str) -> bool:
    try:
        parsed = json.loads(raw_response)
    except (json.JSONDecodeError, TypeError):
        return False
    if not isinstance(parsed, dict):
        return False
    spoken_text = parsed.get("spoken_text", parsed.get("s", ""))
    return bool(RESEARCH_ACCESS_DENIAL.search(str(spoken_text or "")))


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
        initiative_policy: InitiativePolicy | None = None,
        room_context: RoomContextRuntime | None = None,
        dashboard_runtime: DashboardRuntime | None = None,
        transport_admitted: bool = True,
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
        self._memory_lock = threading.Lock()
        self._active_turn_token: CancellationToken | None = None
        self._memory_revision = 0
        self._injected_open_loops: set[str] = set()
        self._session_topics: list[str] = []
        self._session_non_research_turns = 0
        self._session_research_turns = 0
        self._session_persona_id = self.control_state.active_persona_id()
        self._finalized_session_number = 0
        self._last_robot_heartbeat: dict[str, object] = {}
        self.initiative_policy = initiative_policy
        self.room_context = room_context
        self.dashboard_runtime = dashboard_runtime
        self.transport_admitted = bool(transport_admitted)
        self.conversation: ConversationSession | None = None
        self.conversation_response_seq = 0
        self.playback_response_seq = 0
        self.conversation_playback_complete_seq = 0
        self.audio_protocol_errors = 0
        self.audio_uploads_started = 0
        self.audio_uploads_cancelled = 0
        self.audio_uploads_expired = 0
        self.audio_stale_ends_rejected = 0
        self.audio_last_reject_code = ""
        self._rejected_audio_turns: dict[int, str] = {}
        self._stt_diagnostic_pending = bool(config.stt_diagnostic_expected_text)
        saved_initiative = self.memory.fact_value("user.initiative_enabled")
        if self.initiative_policy is not None and saved_initiative == "false":
            self.initiative_policy.set_enabled(False)
        if config.initiative_enabled and (
            not config.tts_command or config.disable_audio_downlink
        ):
            raise ValueError(
                "initiative requires configured TTS and audio downlink"
            )
        if config.conversation_v2_enabled:
            if not config.tts_command or config.disable_audio_downlink:
                raise ValueError(
                    "conversation v2 requires configured TTS and audio downlink for playback confirmation"
                )
            self.conversation = ConversationSession(
                ConversationConfig(
                    reply_window_ms=config.conversation_reply_window_ms,
                    reply_window_min_ms=config.conversation_reply_window_min_ms,
                    reply_window_step_ms=config.conversation_reply_window_step_ms,
                    acoustic_tail_ms=config.conversation_acoustic_tail_ms,
                    cooldown_ms=config.conversation_cooldown_ms,
                    max_turns=config.conversation_max_turns,
                    max_context_turns=config.conversation_max_context_turns,
                    max_context_chars=config.conversation_max_context_chars,
                )
            )
        self.research_broker = research_broker
        if self.research_broker is None and config.research_enabled:
            self.research_broker = ResearchBroker(ResearchBrokerConfig(searxng_url=config.searxng_url))

    @property
    def conversation_harness(self):
        """Compatibility view; the conversation lease owns all transient task state."""

        if self.conversation is None:
            raise RuntimeError("conversation_v2_disabled")
        return self.conversation.harness

    def _conversation_payload(self, transition=None, *, observed_ms: int | None = None) -> dict[str, object]:
        if self.conversation is None:
            return {}
        current_ms = now_ms() if observed_ms is None else int(observed_ms)
        payload: dict[str, object] = {
            "conversation_v2_enabled": True,
            **self.conversation.snapshot(current_ms),
        }
        if transition is not None:
            self._observe_conversation_transition(transition)
            payload["conversation_actions"] = list(transition.actions)
            payload["conversation_reason"] = transition.reason
        return payload

    def _conversation_heartbeat(self, transition=None, *, observed_ms: int | None = None) -> dict[str, object]:
        return {"type": "heartbeat", **self._conversation_payload(transition, observed_ms=observed_ms)}

    def _conversation_ready_frame(self, transition=None) -> dict[str, object]:
        # The device uses hello, not heartbeat, to leave an already-announced thinking state.
        return {
            "type": "hello",
            "protocol": PROTOCOL,
            "session": self.session,
            **self._conversation_payload(transition),
        }

    def _conversation_context_lines(self) -> tuple[str, ...]:
        return self.conversation.context_lines() if self.conversation is not None else ()

    def _embodiment_context_lines(self) -> tuple[str, ...]:
        room_lines = self.room_context.prompt_lines() if self.room_context is not None else ()
        return self.robot_embodiment.prompt_lines() + room_lines

    def _refresh_visual_context(self) -> str:
        if self.room_context is None:
            return "observation_not_configured"
        status = self.room_context.status()
        if not bool(status.get("enabled")):
            return "observation_disabled"
        if not bool(status.get("configured")):
            return "observation_not_configured"
        try:
            self.room_context.observe_once(now_ms=now_ms())
        except Exception:
            status = self.room_context.status()
            return str(status.get("lastError") or "observation_failed")
        return ""

    def _relationship_card(self, query: str, *, suppress_session_context: bool = False) -> RelationshipCard:
        session_turns = self.conversation.turns if self.conversation is not None else 0
        if suppress_session_context:
            session_turns = 3
        card = self.memory.relationship_card(
            query,
            session_turns=session_turns,
            persona_id=self.control_state.active_persona_id(),
            excluded_open_loops=self._injected_open_loops,
        )
        summary = (
            self.room_context.latest_summary()
            if self.room_context is not None
            else None
        )
        if summary is not None and (summary.person_count or 0) > 1:
            personal_prefixes = (
                "preferred_name:",
                "episode:",
                "ask_about:",
                "approved_fact user.",
            )
            card = RelationshipCard(
                tuple(
                    line
                    for line in card.lines
                    if not line.startswith(personal_prefixes)
                )
            )
        if card.open_loop_id:
            self._injected_open_loops.add(card.open_loop_id)
        return card

    def _reset_session_memory_tracking(self) -> None:
        self._injected_open_loops.clear()
        self._session_topics.clear()
        self._session_non_research_turns = 0
        self._session_research_turns = 0
        self._session_persona_id = self.control_state.active_persona_id()
        if self.conversation is not None:
            self.conversation.harness.clear()

    def _commit_memory(self, memory: BridgeMemory) -> None:
        with self._memory_lock:
            self.memory = memory
            self._memory_revision += 1
            if self.config.memory_file:
                save_bridge_memory(self.config.memory_file, self.memory)

    def _run_episode_distillation(
        self,
        turns: tuple[tuple[str, str], ...],
        session_number: int,
        expected_memory_revision: int,
        persona_id: str = DEFAULT_PERSONA_ID,
    ) -> None:
        dropped = False
        if not distillation_turns_safe(turns):
            result = None
        else:
            try:
                result = validate_distillation(request_distillation(turns))
            except (OSError, ValueError, TypeError, json.JSONDecodeError):
                result = None
        with self._memory_lock:
            with self._active_turn_lock:
                active = self._active_turn_token is not None
            stale = (
                self._memory_revision != expected_memory_revision
                or self.conversation is None
                or self.conversation.session_number != session_number
                or self.conversation.phase
                not in (ConversationPhase.COOLDOWN, ConversationPhase.IDLE)
            )
            if result is None or active or stale:
                self.memory = self.memory.note_distill_drop()
                dropped = True
            else:
                self.memory = apply_distillation(
                    self.memory,
                    result,
                    persona_id=persona_id,
                )
            self._memory_revision += 1
            if self.config.memory_file:
                save_bridge_memory(self.config.memory_file, self.memory)
            diagnostics = self.memory.diagnostics()
        self._append_turn_log(
            {
                "schema": "stackchan.memory-session.v1",
                "generated_at": utc_timestamp(),
                "session_number": session_number,
                "event": "episode_distillation",
                "distill_dropped": dropped,
                **diagnostics,
            }
        )

    def _finalize_memory_session(self) -> None:
        if self.conversation is None:
            return
        session_number = self.conversation.session_number
        if session_number <= 0 or session_number == self._finalized_session_number:
            return
        self._finalized_session_number = session_number
        turns = self.conversation.take_closed_turns()
        updated = self.memory.add_episode_from_topics(
            self._session_topics,
            len(turns),
            persona_id=self._session_persona_id,
        )
        self._commit_memory(updated)
        self._append_turn_log(
            {
                "schema": "stackchan.memory-session.v1",
                "generated_at": utc_timestamp(),
                "session_number": session_number,
                "event": "session_closed",
                "session_turn_count": len(turns),
                "session_topic_count": len(set(self._session_topics)),
                "session_non_research_turns": self._session_non_research_turns,
                "session_research_turns": self._session_research_turns,
                "distillation_skipped_research": bool(
                    self._session_research_turns
                ),
                **self.memory.diagnostics(),
            }
        )
        if (
            self.config.episode_distillation_enabled
            and turns
            and self._session_research_turns == 0
        ):
            expected_memory_revision = self._memory_revision
            threading.Thread(
                target=self._run_episode_distillation,
                args=(
                    turns,
                    session_number,
                    expected_memory_revision,
                    self._session_persona_id,
                ),
                name=f"stackchan-memory-distill-{session_number}",
                daemon=True,
            ).start()
        self._reset_session_memory_tracking()

    def _observe_conversation_transition(self, transition) -> None:
        if transition is None:
            return
        actions = tuple(str(action) for action in transition.actions)
        reason = str(transition.reason or "")
        if actions or reason not in {"", "no_change"}:
            snapshot = self.conversation.snapshot(now_ms()) if self.conversation is not None else {}
            self._append_turn_log(
                {
                    "schema": "stackchan.conversation-event.v1",
                    "generated_at": utc_timestamp(),
                    "event": reason or "transition",
                    "actions": list(actions),
                    **snapshot,
                }
            )
        if any(
            action in {"session_closing", "session_closed"} for action in transition.actions
        ):
            self._finalize_memory_session()

    def connection_closed(self) -> None:
        self._cancel_audio_capture(
            reason="bridge connection closed before a terminal marker",
            code="audio_capture_connection_closed",
        )
        if self.conversation is not None and self.conversation.phase != ConversationPhase.IDLE:
            self._conversation_payload(self.conversation.bridge_lost())

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
        with self._memory_lock:
            with self._active_turn_lock:
                if self._active_turn_token is not None:
                    return False
                self._active_turn_token = token
        if self.room_context is not None:
            self.room_context.set_foreground_active(True)
        return True

    def _finish_active_turn(self, token: CancellationToken) -> None:
        finished = False
        with self._active_turn_lock:
            if self._active_turn_token is token:
                self._active_turn_token = None
                finished = True
        if finished and self.room_context is not None:
            self.room_context.set_foreground_active(False)

    def _stage_conversation_turn(
        self,
        user_text: str,
        response_text: str,
        tts_error: str,
        conversation_plan: ConversationTurnPlan,
        *,
        research_succeeded: bool = False,
    ) -> None:
        if self.conversation is not None and not tts_error:
            self.conversation.stage_turn(
                user_text,
                response_text,
                task_plan=conversation_plan,
                research_succeeded=research_succeeded,
            )
        elif tts_error and self.conversation is not None:
            self.conversation.harness.discard_pending()

    def _begin_conversation_capture(self, owner_id: str) -> dict[str, object] | None:
        if self.initiative_policy is not None:
            self.initiative_policy.note_user_activity(now_ms=now_ms())
        if self.conversation is None:
            return None
        current_ms = now_ms()
        self._observe_conversation_transition(self.conversation.tick(current_ms))
        if self.conversation.phase == ConversationPhase.IDLE:
            self._reset_session_memory_tracking()
            self._observe_conversation_transition(self.conversation.wake(current_ms, owner_id))
        elif self.conversation.phase in (ConversationPhase.THINKING, ConversationPhase.SPEAKING):
            self.cancel_active_turn("barge_in")
            self._observe_conversation_transition(self.conversation.barge_in(current_ms))
        transition = self.conversation.utterance_started(current_ms)
        self._observe_conversation_transition(transition)
        if "reject_utterance" in transition.actions:
            return error_frame("conversation_capture_closed", transition.reason)
        return None

    def _conversation_failure(self, code: str, detail: str) -> dict[str, object]:
        frame = error_frame(code, detail)
        if self.dashboard_runtime is not None:
            service = (
                "model"
                if code.startswith(("runner", "model"))
                else "research"
                if code.startswith("research")
                else "voice"
                if code.startswith("tts")
                else "knowledge"
                if code.startswith(("memory", "distill"))
                else ""
            )
            self.dashboard_runtime.note_pipeline_stage("failed")
            if service:
                self.dashboard_runtime.note_pipeline_result(
                    service,
                    ok=False,
                    error_code=code,
                )
        if self.conversation is not None:
            self.conversation.harness.discard_pending()
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
            with self._memory_lock:
                save_bridge_memory(self.config.memory_file, self.memory)

    def _append_turn_log(self, record: dict[str, object]) -> None:
        if not self.config.turn_log_file:
            return
        serialized = dict(record)
        if self.config.redact_turn_text:
            for key in (
                "transcript",
                "response_text",
                "stt_transcript",
                "stt_raw_transcript",
            ):
                if key in serialized:
                    serialized[f"{key}_present"] = bool(str(serialized.pop(key, "")).strip())
        self.config.turn_log_file.parent.mkdir(parents=True, exist_ok=True)
        with self.config.turn_log_file.open("a", encoding="utf-8") as handle:
            handle.write(json.dumps(serialized, separators=(",", ":"), ensure_ascii=True) + "\n")

    def _take_stt_diagnostic_metrics(self, recognized_text: str) -> dict[str, object]:
        if not self._stt_diagnostic_pending:
            return {}
        self._stt_diagnostic_pending = False
        return expected_transcript_metrics(
            self.config.stt_diagnostic_expected_text,
            recognized_text,
            critical_tokens=self.config.stt_diagnostic_critical_tokens,
        )

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
        for key in (
            "audio_declared_bytes",
            "audio_declared_chunks",
            "audio_end_counts_match",
        ):
            if key in audio_summary:
                record[key] = audio_summary[key]
        self._append_turn_log(record)

    def _append_audio_protocol_event(
        self,
        *,
        code: str,
        payload_bytes: int,
        seq: int = 0,
        detail: str = "",
    ) -> None:
        self.audio_protocol_errors += 1
        record: dict[str, object] = {
            "schema": "stackchan.audio-protocol-event.v1",
            "generated_at": utc_timestamp(),
            "session": self.session,
            "code": code,
            "payload_bytes": max(0, int(payload_bytes)),
            "audio_protocol_errors": self.audio_protocol_errors,
        }
        if seq > 0:
            record["seq"] = seq
        if detail:
            record["detail"] = detail[:160]
        self._append_turn_log(record)

    def _append_audio_capture_event(
        self,
        *,
        code: str,
        payload_bytes: int,
        seq: int = 0,
        detail: str = "",
    ) -> None:
        record: dict[str, object] = {
            "schema": "stackchan.audio-capture-event.v1",
            "generated_at": utc_timestamp(),
            "session": self.session,
            "code": code,
            "payload_bytes": max(0, int(payload_bytes)),
        }
        if seq > 0:
            record["seq"] = seq
        if detail:
            record["detail"] = detail[:160]
        self._append_turn_log(record)

    @staticmethod
    def _audio_message_seq(message: dict[str, Any]) -> int:
        try:
            return max(0, int(message.get("seq") or 0))
        except (TypeError, ValueError):
            return 0

    def _audio_upload_telemetry(self) -> dict[str, object]:
        return {
            "audio_upload_active": self.audio.active,
            "audio_uploads_started": self.audio_uploads_started,
            "audio_uploads_cancelled": self.audio_uploads_cancelled,
            "audio_uploads_expired": self.audio_uploads_expired,
            "audio_stale_ends_rejected": self.audio_stale_ends_rejected,
            "audio_protocol_errors": self.audio_protocol_errors,
            "audio_last_reject_code": self.audio_last_reject_code,
            "audio_capture_absolute_lease_ms": self.config.audio_capture_absolute_lease_ms,
            "audio_capture_inactivity_lease_ms": self.config.audio_capture_inactivity_lease_ms,
        }

    def _remember_audio_rejection(self, seq: int, code: str) -> None:
        self.audio_last_reject_code = code
        if seq <= 0:
            return
        self._rejected_audio_turns[seq] = code
        while len(self._rejected_audio_turns) > 16:
            self._rejected_audio_turns.pop(next(iter(self._rejected_audio_turns)))

    def _cancel_audio_capture(self, *, reason: str, code: str) -> dict[str, object] | None:
        if not self.audio.active:
            return None
        summary = self.audio.summary()
        seq = self.audio.seq
        payload_bytes = self.audio.bytes_received
        self.audio.clear()
        self.audio_uploads_cancelled += 1
        self._remember_audio_rejection(seq, code)
        self._append_audio_capture_event(
            code=code,
            payload_bytes=payload_bytes,
            seq=seq,
            detail=reason,
        )
        summary.update(self._audio_upload_telemetry())
        return summary

    def _expire_audio_capture(self) -> dict[str, object] | None:
        code = self.audio.expiry_code()
        if not code:
            return None
        summary = self.audio.summary()
        seq = self.audio.seq
        payload_bytes = self.audio.bytes_received
        self.audio.clear()
        self.audio_uploads_expired += 1
        self._remember_audio_rejection(seq, code)
        self._append_audio_capture_event(
            code=code,
            payload_bytes=payload_bytes,
            seq=seq,
            detail="partial PCM discarded before STT",
        )
        transition = self.conversation.cancel(now_ms(), code) if self.conversation is not None else None
        frame = error_frame(code, "partial PCM discarded before STT")
        frame.update(summary)
        frame.update(self._audio_upload_telemetry())
        frame.update(self._conversation_payload(transition))
        return frame

    def prepare_utterance_end(
        self,
        message: dict[str, Any],
        *,
        finalized_audio: FinalizedAudioUpload | None = None,
    ) -> dict[str, object] | None:
        seq = self._audio_message_seq(message)
        if finalized_audio is not None:
            finalized_reject = str(
                finalized_audio.summary.get("audio_capture_reject_code", "")
            )
            if finalized_reject:
                frame = error_frame(finalized_reject, "partial PCM discarded before STT")
                frame.update(finalized_audio.summary)
                frame.update(self._audio_upload_telemetry())
                return frame
        expired = self._expire_audio_capture()
        if expired is not None:
            return expired
        if self.audio.active and self.audio.seq > 0 and seq > 0 and seq != self.audio.seq:
            self.audio_stale_ends_rejected += 1
            self.audio_last_reject_code = "utterance_end_seq_mismatch"
            self._append_audio_protocol_event(
                code="utterance_end_seq_mismatch",
                payload_bytes=0,
                seq=seq,
                detail=f"active capture seq is {self.audio.seq}",
            )
            frame = error_frame("utterance_end_seq_mismatch", f"active capture seq is {self.audio.seq}")
            frame.update(self._audio_upload_telemetry())
            return frame
        rejected_code = self._rejected_audio_turns.get(seq, "") if seq > 0 else ""
        if not self.audio.active and rejected_code:
            self.audio_stale_ends_rejected += 1
            self.audio_last_reject_code = "utterance_end_stale"
            self._append_audio_protocol_event(
                code="utterance_end_stale",
                payload_bytes=0,
                seq=seq,
                detail=rejected_code,
            )
            frame = error_frame("utterance_end_stale", rejected_code)
            frame["audio_capture_reject_code"] = rejected_code
            frame.update(self._audio_upload_telemetry())
            return frame
        return None

    @staticmethod
    def _validate_audio_end_declaration(
        message: dict[str, Any],
        audio_summary: dict[str, object],
    ) -> str:
        declarations = (
            ("audio_bytes", "audio_bytes", "audio_declared_bytes"),
            ("chunks", "audio_chunks", "audio_declared_chunks"),
        )
        mismatches: list[str] = []
        saw_declaration = False
        for message_key, summary_key, declared_key in declarations:
            if message_key not in message:
                continue
            saw_declaration = True
            try:
                declared = int(message[message_key])
            except (TypeError, ValueError):
                audio_summary["audio_end_counts_match"] = False
                return f"{message_key} is not an integer"
            if declared < 0:
                audio_summary["audio_end_counts_match"] = False
                return f"{message_key} is negative"
            actual = int(audio_summary.get(summary_key, 0))
            audio_summary[declared_key] = declared
            if declared != actual:
                mismatches.append(f"{message_key} declared {declared}, received {actual}")
        if saw_declaration:
            audio_summary["audio_end_counts_match"] = not mismatches
        return "; ".join(mismatches)

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
        host_reaction_ms: float | None,
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
        for key in (
            "audio_declared_bytes",
            "audio_declared_chunks",
            "audio_end_counts_match",
        ):
            if key in audio_summary:
                record[key] = audio_summary[key]
        record.update(self.memory.diagnostics())
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
                host_reaction_ms=host_reaction_ms,
            )
        )
        self._append_turn_log(record)
        if self.dashboard_runtime is not None:
            runner_elapsed = runner_summary.get(
                "research_runner_elapsed_ms",
                runner_summary.get("runner_elapsed_ms"),
            )
            runner_source = str(
                runner_summary.get("runner_command_source", "")
            ).casefold()
            model_invoked = (
                "research_runner_elapsed_ms" in runner_summary
                or not runner_source.startswith(
                    ("local_", "trusted_", "deterministic_")
                )
            )
            if model_invoked:
                self.dashboard_runtime.note_pipeline_result(
                    "model",
                    ok=True,
                    elapsed_ms=(
                        float(runner_elapsed)
                        if isinstance(runner_elapsed, (int, float))
                        else None
                    ),
                )
            if "research_status" in runner_summary:
                research_status = str(runner_summary.get("research_status", ""))
                self.dashboard_runtime.note_pipeline_result(
                    "research",
                    ok=research_status == "ok",
                    error_code=(
                        str(runner_summary.get("research_error", ""))
                        or f"research_{research_status}"
                    ),
                )
            self.dashboard_runtime.note_pipeline_result(
                "voice",
                ok=not bool(tts_error),
                error_code=tts_error,
                elapsed_ms=(
                    float(tts_summary["tts_elapsed_ms"])
                    if isinstance(tts_summary.get("tts_elapsed_ms"), (int, float))
                    else None
                ),
            )
            self.dashboard_runtime.note_pipeline_result("knowledge", ok=True)
            self.dashboard_runtime.note_pipeline_stage(
                "awaiting_playback"
                if self.conversation is not None
                else "idle",
                turn_seq=seq,
                task_domain=str(
                    runner_summary.get("conversation_task_domain", "")
                ),
                task_status=str(
                    runner_summary.get("conversation_task_operation", "")
                ),
            )

    def handle_text(
        self,
        text: str,
        *,
        suppress_thinking: bool = False,
        frame_sink: Callable[[dict[str, object] | bytes], float | None] | None = None,
        finalized_audio: FinalizedAudioUpload | None = None,
    ) -> list[dict[str, object] | bytes]:
        try:
            message = json.loads(text)
        except json.JSONDecodeError:
            return [error_frame("malformed_json")]
        if not isinstance(message, dict):
            return [error_frame("message_not_object")]

        message_type = str(message.get("type", "")).strip().lower()
        if not self.transport_admitted:
            return [error_frame("admission_required")]
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
            audio_expired = self._expire_audio_capture()
            self.robot_embodiment.update(message)
            self._last_robot_heartbeat = dict(message)
            if (
                self.initiative_policy is not None
                and self._truthy(message.get("camera_active"))
                and "camera_target_fresh" in message
            ):
                self.initiative_policy.observe_presence(
                    self._truthy(message.get("camera_target_fresh")),
                    now_ms=now_ms(),
                )
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
            return ([audio_expired] if audio_expired is not None else []) + [frame]
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
            audio_diagnostics = frame.get("audio")
            if isinstance(audio_diagnostics, dict):
                audio_diagnostics.update(self._audio_upload_telemetry())
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
            capture_seq = self._audio_message_seq(message)
            self._cancel_audio_capture(
                reason="a newer utterance_start superseded the capture",
                code="audio_capture_superseded",
            )
            if capture_seq > 0:
                self._rejected_audio_turns.pop(capture_seq, None)
            self.audio.start(
                message.get("sample_rate", DEFAULT_SAMPLE_RATE),
                seq=capture_seq,
                absolute_lease_ms=self.config.audio_capture_absolute_lease_ms,
                inactivity_lease_ms=self.config.audio_capture_inactivity_lease_ms,
            )
            self.audio_uploads_started += 1
            return [
                {
                    "type": "listening",
                    **self.audio.summary(),
                    **self._audio_upload_telemetry(),
                    **self._conversation_payload(),
                }
            ]
        if message_type == "utterance_cancel":
            owner_error = self._owner_gate(message)
            if owner_error is not None:
                return [owner_error]
            reason = str(message.get("reason") or "capture_cancelled")
            seq = self._audio_message_seq(message)
            if self.audio.active and self.audio.seq > 0 and seq > 0 and seq != self.audio.seq:
                return [
                    error_frame("utterance_cancel_seq_mismatch", f"active capture seq is {self.audio.seq}")
                    | self._audio_upload_telemetry()
                ]
            known_duplicate = seq > 0 and seq in self._rejected_audio_turns
            summary = self._cancel_audio_capture(
                reason=reason,
                code="audio_capture_cancelled",
            )
            transition = None
            if summary is not None or not known_duplicate:
                if summary is None:
                    self._remember_audio_rejection(seq, "audio_capture_cancelled")
                self.cancel_active_turn(reason)
                transition = (
                    self.conversation.cancel(now_ms(), reason)
                    if self.conversation is not None
                    else None
                )
            frame: dict[str, object] = {
                "type": "heartbeat",
                "utterance_cancelled": True,
                "utterance_cancel_seq": seq,
                "utterance_cancel_duplicate": summary is None,
                **self._audio_upload_telemetry(),
            }
            if summary is not None:
                frame.update(summary)
            frame.update(self._conversation_payload(transition))
            return [frame]
        if message_type == "cancel":
            reason = str(message.get("reason") or "cancelled")
            self._cancel_audio_capture(reason=reason, code="audio_capture_cancelled")
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
            audio_end_error = self.prepare_utterance_end(
                message,
                finalized_audio=finalized_audio,
            )
            if audio_end_error is not None:
                return [audio_end_error]
            return self._handle_utterance_end(
                message,
                suppress_thinking=suppress_thinking,
                frame_sink=frame_sink,
                finalized_audio=finalized_audio,
            )
        if message_type == "playback_complete":
            try:
                seq = max(0, int(message.get("seq", 0)))
            except (TypeError, ValueError):
                return [error_frame("playback_complete_seq_invalid")]
            interrupted = message.get("interrupted", False)
            if not isinstance(interrupted, bool):
                return [error_frame("playback_complete_interrupted_invalid")]
            frame: dict[str, object] = {"type": "heartbeat", "playback_complete_seq": seq}
            if self.conversation is not None:
                if seq == 0 or seq != self.playback_response_seq:
                    if self.dashboard_runtime is not None:
                        self.dashboard_runtime.note_pipeline_result(
                            "playback",
                            ok=False,
                            error_code="playback_complete_seq_mismatch",
                        )
                    return [error_frame("playback_complete_seq_mismatch", str(seq))]
                if seq == self.conversation_playback_complete_seq:
                    frame["playback_complete_duplicate"] = True
                    if interrupted:
                        frame["playback_interrupted"] = True
                    frame.update(self._conversation_payload())
                    return [frame]
                if (
                    seq == self.conversation_response_seq
                    and self.conversation.phase == ConversationPhase.SPEAKING
                ):
                    if interrupted:
                        transition = self.conversation.cancel(
                            now_ms(), "playback_interrupted"
                        )
                        frame["playback_complete_terminal"] = True
                        frame["playback_interrupted"] = True
                    else:
                        transition = self.conversation.playback_completed(now_ms())
                        committed_plan, research_succeeded = (
                            self.conversation.take_committed_task()
                        )
                        committed_state = (
                            committed_plan.next_state
                            if committed_plan is not None
                            else None
                        )
                        research_attempted = bool(
                            committed_plan is not None
                            and committed_plan.request is not None
                        )
                        if (
                            research_attempted
                            and committed_state is not None
                            and committed_state.domain == "weather"
                        ):
                            self._session_research_turns += 1
                            if "weather" not in self._session_topics:
                                self._session_topics.append("weather")
                        elif research_attempted and committed_state is not None:
                            self._session_research_turns += 1
                            if "web research" not in self._session_topics:
                                self._session_topics.append("web research")
                        if "playback_complete" in transition.actions:
                            frame = {
                                "type": "conversation_reply_window",
                                "seq": seq,
                                "open_after_ms": self.config.conversation_acoustic_tail_ms,
                                "window_ms": self.conversation.current_reply_window_ms(),
                            }
                        else:
                            frame["playback_complete_terminal"] = True
                    frame.update(self._conversation_payload(transition))
                else:
                    frame["playback_complete_terminal"] = True
                    if interrupted:
                        frame["playback_interrupted"] = True
                    frame.update(self._conversation_payload())
                self.conversation_playback_complete_seq = seq
                if self.dashboard_runtime is not None:
                    self.dashboard_runtime.note_pipeline_result(
                        "playback",
                        ok=not interrupted,
                        error_code="playback_interrupted" if interrupted else "",
                    )
                    self.dashboard_runtime.note_pipeline_stage(
                        "reply_window"
                        if self.conversation.phase
                        in (ConversationPhase.ENGAGED, ConversationPhase.REPLY_WINDOW)
                        else "idle",
                        turn_seq=seq,
                    )
            return [frame]
        return [error_frame("unsupported_message", message_type)]

    def _owner_gate(self, message: dict[str, Any]) -> dict[str, object] | None:
        endpoint_id = normalize_endpoint_id(message.get("endpoint_id") or self.endpoint_id)
        if not endpoint_id:
            self.control_state.reconcile_owner()
            if self.control_state.active_brain_owner:
                return error_frame("endpoint_id_required")
            return None
        self.control_state.touch_endpoint(endpoint_id)
        self.control_state.reconcile_owner()
        owner = self.control_state.active_brain_owner
        if owner and endpoint_id != owner:
            return error_frame("brain_owner_mismatch", endpoint_id)
        return None

    @staticmethod
    def _truthy(value: object) -> bool:
        return value is True or value == 1 or str(value).strip().lower() in {"1", "true", "yes", "on"}

    def initiative_decision(
        self,
        *,
        observed_ms: int | None = None,
        local_hour: int | None = None,
    ) -> InitiativeDecision | None:
        if self.initiative_policy is None:
            return None
        try:
            persona = self._active_persona()
        except (OSError, PersonaPackError, ValueError):
            return None
        circadian = persona.behavior.get("circadian")
        if not isinstance(circadian, dict):
            return None
        heartbeat = self._last_robot_heartbeat
        try:
            robot_mode_id = int(heartbeat.get("robot_mode", -1))
        except (TypeError, ValueError):
            robot_mode_id = -1
        robot_modes = {
            0: "booting",
            1: "idle",
            2: "attending",
            3: "listening",
            4: "thinking",
            5: "speaking",
            6: "reacting",
            7: "sleeping",
            8: "error",
        }
        safety_clear = not any(
            self._truthy(heartbeat.get(key))
            for key in (
                "motion_thermal_suppressed",
                "motion_power_suppressed",
                "speaker_active",
                "imu_picked_up",
            )
        )
        session_active = (
            self.conversation is not None and self.conversation.phase != ConversationPhase.IDLE
        )
        return self.initiative_policy.decide(
            now_ms=now_ms() if observed_ms is None else int(observed_ms),
            local_hour=datetime.now().hour if local_hour is None else int(local_hour),
            night_start_hour=int(circadian.get("night_start_hour", 21)),
            morning_start_hour=int(circadian.get("morning_start_hour", 6)),
            robot_mode=robot_modes.get(robot_mode_id, "unknown"),
            session_active=session_active,
            turn_busy=self.active_turn_in_progress(),
            safety_clear=safety_clear,
        )

    def run_initiative(
        self,
        decision: InitiativeDecision,
        *,
        frame_sink: Callable[[dict[str, object] | bytes], float | None] | None = None,
    ) -> list[dict[str, object] | bytes]:
        if self.initiative_policy is None:
            return [error_frame("initiative_disabled")]
        cancellation = CancellationToken()
        if not self._register_active_turn(cancellation):
            self.initiative_policy.note_attempt_failed(now_ms=now_ms())
            return [error_frame("turn_busy", "a response is already being generated")]
        started = time.perf_counter()
        try:
            active_persona = self._active_persona()
            seq = self.next_seq
            self.next_seq += 1
            embodiment_lines = self._embodiment_context_lines()
            runner = run_runner_profile(
                self.config.runner_profile,
                case_name="question",
                command=self.config.runner_command,
                in_process_ollama=self.config.in_process_ollama_runner,
                require_runner=self.config.require_runner,
                timeout_ms=self.config.runner_timeout_ms,
                user_text=decision.prompt,
                research_tools_enabled=False,
                embodiment_lines=embodiment_lines,
                memory_lines=(),
                conversation_lines=(),
                cancellation=cancellation,
                persona_id=active_persona.pack_id,
            )
            if not getattr(runner, "configured_runner", False):
                raise RunnerConfigurationError(
                    "initiative requires a configured local model runner"
                )
            raw_response = self._clear_research_memory_writes(runner.raw_response)
            turn, _, validation = turn_from_character_response(
                raw_response,
                self.memory,
                session=self.session,
                seq=seq,
                persona=active_persona,
                allow_visual_claims=trusted_visual_context_available(embodiment_lines),
                grounding_text="\n".join((decision.prompt, *embodiment_lines)),
            )
            frames, tts_summary, tts_error = self._stream_tts_turn(
                turn,
                turn_started=started,
                validation_issues=list(validation.issues),
                frame_sink=frame_sink,
                cancellation=cancellation,
            )
            if tts_error or not bool(tts_summary.get("tts_stream_complete")):
                self.initiative_policy.note_attempt_failed(now_ms=now_ms())
            else:
                self.initiative_policy.note_spoken(now_ms=now_ms())
                self._append_turn_log(
                    {
                        "schema": "stackchan.initiative-turn.v1",
                        "generated_at": utc_timestamp(),
                        "seq": seq,
                        "event": "initiative_spoken",
                        "reason": decision.reason,
                        "persona_id": active_persona.pack_id,
                        "validation_issues": list(validation.issues),
                        "tts_first_audio_ms": tts_summary.get("tts_first_audio_ms", 0),
                    }
                )
            return frames
        except OperationCancelledError as exc:
            self.initiative_policy.note_attempt_failed(now_ms=now_ms())
            return [error_frame("turn_cancelled", str(exc))]
        except (
            OSError,
            PersonaPackError,
            RunnerConfigurationError,
            RunnerExecutionError,
            TtsConfigurationError,
            TtsExecutionError,
            ValueError,
        ) as exc:
            self.initiative_policy.note_attempt_failed(now_ms=now_ms())
            return [error_frame("initiative_error", str(exc))]
        finally:
            self._finish_active_turn(cancellation)

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

    def finalize_audio_upload(self) -> FinalizedAudioUpload:
        expired = self._expire_audio_capture()
        if expired is not None:
            summary = {
                key: value
                for key, value in expired.items()
                if key not in {"type", "code", "detail"}
            }
            summary["audio_capture_reject_code"] = str(expired["code"])
            return FinalizedAudioUpload(pcm=b"", summary=summary)
        return self.audio.finalize()

    def handle_binary(self, payload: bytes) -> list[dict[str, object]]:
        if not self.transport_admitted:
            return [error_frame("admission_required")]
        self.control_state.touch_endpoint(self.endpoint_id)
        self.control_state.reconcile_owner()
        if self.endpoint_id and self.control_state.active_brain_owner and self.endpoint_id != self.control_state.active_brain_owner:
            return [error_frame("brain_owner_mismatch", self.endpoint_id)]
        expired = self._expire_audio_capture()
        if expired is not None:
            return [expired]
        try:
            self.audio.append(payload, self.config.max_audio_bytes)
        except WebSocketProtocolError as exc:
            self._append_audio_protocol_event(
                code="audio_without_utterance",
                payload_bytes=len(payload),
            )
            frame = error_frame("audio_without_utterance", str(exc))
            frame["audio_protocol_errors"] = self.audio_protocol_errors
            return [frame]
        return [
            {
                "type": "heartbeat",
                **self.audio.summary(),
                **self._audio_upload_telemetry(),
            }
        ]

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
        frame_sink: Callable[[dict[str, object] | bytes], float | None] | None,
        cancellation: CancellationToken | None = None,
    ) -> tuple[list[dict[str, object] | bytes], dict[str, object], str]:
        cancellation = cancellation or CancellationToken()
        emitted: list[dict[str, object] | bytes] = []

        def emit(frame: dict[str, object] | bytes) -> float | None:
            cancellation.raise_if_cancelled()
            if frame_sink is None:
                emitted.append(frame)
                return None
            return frame_sink(frame)

        emit(
            {
                "type": "response_start",
                "seq": turn.seq,
                "intent": turn.intent,
                "arousal": round(max(0.0, min(1.0, turn.arousal)), 2),
                # Valence is signed end to end: firmware constrains it to
                # [-1, 1], and TTS styling already uses the signed value. A
                # [0, 1] clamp here silently zeroed every concerned face while
                # the voice stayed concerned.
                "valence": round(max(-1.0, min(1.0, turn.valence)), 2),
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
                        mode=turn.intent,
                        arousal=turn.arousal,
                        valence=turn.valence,
                        directml_in_process=self.config.in_process_directml_tts,
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
        stream_chunk_bytes = max(
            1,
            min(MAX_DOWNLINK_AUDIO_CHUNK_BYTES, int(self.config.downlink_audio_chunk_bytes)),
        )
        chunk_audio_ms = (
            (stream_chunk_bytes / 2.0) / stream_rate * 1000.0
            if stream_rate > 0
            else 0.0
        )
        mouth_control_delay_ms = downlink_text_frame_delay_ms(
            self.config,
            {"type": "audio"},
        )
        configured_cadence_ms = (
            float(self.config.downlink_binary_frame_delay_ms) + mouth_control_delay_ms
        )
        pacing_headroom_ms = chunk_audio_ms - configured_cadence_ms
        pacing_safe = (
            stream_started
            and pacing_headroom_ms >= MIN_DOWNLINK_PACING_HEADROOM_MS
        )

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
            failure_frame = error_frame("tts_error", tts_error)
            if (
                self.conversation is not None
                and self.conversation.phase
                in (ConversationPhase.THINKING, ConversationPhase.SPEAKING)
            ):
                transition = self.conversation.turn_failed(now_ms(), "tts_error")
                failure_frame.update(self._conversation_payload(transition))
            emit(failure_frame)
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
            "tts_downlink_chunk_audio_ms": round(chunk_audio_ms, 2),
            "tts_downlink_configured_cadence_ms": round(configured_cadence_ms, 2),
            "tts_downlink_pacing_headroom_ms": round(pacing_headroom_ms, 2),
            "tts_downlink_pacing_safe": pacing_safe,
            "tts_mode": turn.intent,
            "tts_arousal": round(max(0.0, min(1.0, turn.arousal)), 3),
            "tts_valence": round(max(-1.0, min(1.0, turn.valence)), 3),
        }
        return emitted, summary, tts_error

    def _handle_utterance_end(
        self,
        message: dict[str, Any],
        *,
        suppress_thinking: bool = False,
        frame_sink: Callable[[dict[str, object] | bytes], float | None] | None = None,
        finalized_audio: FinalizedAudioUpload | None = None,
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
                finalized_audio=finalized_audio,
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
        frame_sink: Callable[[dict[str, object] | bytes], float | None] | None,
        cancellation: CancellationToken,
        finalized_audio: FinalizedAudioUpload | None,
    ) -> list[dict[str, object] | bytes]:
        turn_started = time.perf_counter()
        cancellation.raise_if_cancelled()
        seq = int(message.get("seq") or self.next_seq)
        if self.dashboard_runtime is not None:
            self.dashboard_runtime.note_pipeline_stage(
                "transcribing",
                turn_seq=seq,
            )
        try:
            host_reaction_ms = max(0.0, float(message["_bridge_host_reaction_ms"]))
        except (KeyError, TypeError, ValueError):
            host_reaction_ms = None
        self.next_seq = max(self.next_seq, seq + 1)
        user_text = " ".join(str(message.get("text") or message.get("transcript") or "").split())
        finalized = finalized_audio if finalized_audio is not None else self.finalize_audio_upload()
        pcm = finalized.pcm
        audio_summary = dict(finalized.summary)
        finalized_reject = str(audio_summary.get("audio_capture_reject_code", ""))
        if finalized_reject:
            frame = error_frame(finalized_reject, "partial PCM discarded before STT")
            frame.update(audio_summary)
            frame.update(self._audio_upload_telemetry())
            return [frame]
        has_audio = int(audio_summary["audio_bytes"]) > 0
        declaration_error = self._validate_audio_end_declaration(message, audio_summary)
        if declaration_error:
            self._append_audio_error_log(
                seq=seq,
                audio_summary=audio_summary,
                code="audio_count_mismatch",
                detail=declaration_error,
                transcript=user_text,
            )
            return [
                self._conversation_failure("audio_count_mismatch", declaration_error)
                | audio_summary
            ]
        audio_evidence_log = self._write_audio_evidence(seq=seq, pcm=pcm, audio_summary=audio_summary) if has_audio else {}
        audio_summary.update(audio_evidence_log)
        stt_log: dict[str, object] = {}
        no_speech_detail = ""
        stt_low_confidence = False
        silent_reply_close = False
        if not has_audio and not user_text:
            no_speech_detail = "utterance_end had no audio or transcript"
        is_conversation_followup = self.conversation is not None and self.conversation.turns > 0
        if has_audio and not user_text and is_conversation_followup:
            speech_diagnostics = analyze_reply_pcm16_speech(
                pcm,
                int(audio_summary["audio_sample_rate"]),
            )
            audio_summary.update(speech_diagnostics)
            stt_log.update(speech_diagnostics)
            if speech_diagnostics["reply_pcm_speech_detected"] is False:
                no_speech_detail = "conversation reply PCM contained no speech"
                silent_reply_close = True
                stt_log["stt_bypassed"] = True
                stt_log["stt_bypass_reason"] = "reply_pcm_no_speech"
        if has_audio and not user_text and not no_speech_detail:
            try:
                stt = transcribe_pcm(
                    pcm,
                    int(audio_summary["audio_sample_rate"]),
                    command=self.config.stt_command,
                    server_url=self.config.stt_server_url,
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
            except SttNoTranscriptError as exc:
                no_speech_detail = str(exc)
                stt_log.update(
                    {
                        "stt_no_transcript": True,
                        "stt_command_source": (
                            "whisper.cpp-server"
                            if self.config.stt_server_url
                            else "configured-command"
                        ),
                    }
                )
                stt_log.update(self._take_stt_diagnostic_metrics(""))
            except (SttExecutionError, ValueError) as exc:
                self._append_audio_error_log(
                    seq=seq,
                    audio_summary=audio_summary,
                    code="stt_error",
                    detail=str(exc),
                )
                return [self._conversation_failure("stt_error", str(exc)) | audio_summary]
            else:
                user_text = stt.transcript
                audio_summary["stt_elapsed_ms"] = round(stt.elapsed_ms, 2)
                audio_summary["stt_command_source"] = stt.command_source
                stt_log.update(
                    {
                        "stt_transcript": stt.transcript,
                        "stt_elapsed_ms": round(stt.elapsed_ms, 2),
                        "stt_command_source": stt.command_source,
                    }
                )
                if stt.raw_transcript and stt.raw_transcript != stt.transcript:
                    stt_log["stt_raw_transcript"] = stt.raw_transcript
                if stt.transcript_normalized:
                    stt_log["stt_transcript_normalized"] = True
                diagnostic_text = stt.raw_transcript or stt.transcript
                diagnostic_metrics = self._take_stt_diagnostic_metrics(diagnostic_text)
                if diagnostic_metrics:
                    diagnostic_metrics["stt_expected_diagnostic_used_raw_transcript"] = bool(
                        stt.raw_transcript
                    )
                    stt_log.update(diagnostic_metrics)
                stt_confidence = getattr(stt, "confidence", None)
                if stt_confidence is not None:
                    stt_log["stt_confidence"] = round(stt_confidence, 4)
                    stt_low_confidence = (
                        stt_confidence < self.config.stt_min_confidence
                    )
                    if stt_low_confidence:
                        stt_log["stt_low_confidence"] = True
        cancellation.raise_if_cancelled()
        require_wake_phrase = self.config.require_audio_wake_phrase and (
            self.conversation is None or self.conversation.turns == 0
        )
        if (
            has_audio
            and not no_speech_detail
            and require_wake_phrase
            and not contains_stackchan_wake_phrase(user_text)
        ):
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
        if self.dashboard_runtime is not None:
            self.dashboard_runtime.note_pipeline_stage("routing", turn_seq=seq)
        requested_initiative = (
            None
            if stt_low_confidence
            else initiative_preference_from_text(user_text)
        )
        requested_forget_keys = (
            () if stt_low_confidence else explicit_forget_keys(user_text)
        )
        if self.conversation is not None:
            transition = self.conversation.utterance_committed(now_ms(), user_text)
            if silent_reply_close:
                record: dict[str, object] = {
                    "schema": "stackchan.lan-turn-summary.v1",
                    "generated_at": utc_timestamp(),
                    "seq": seq,
                    "session": self.session,
                    "source": "audio",
                    "audio_bytes": int(audio_summary.get("audio_bytes", 0)),
                    "audio_chunks": int(audio_summary.get("audio_chunks", 0)),
                    "audio_sample_rate": int(
                        audio_summary.get("audio_sample_rate", DEFAULT_SAMPLE_RATE)
                    ),
                    "ignored": True,
                    "ignore_code": "reply_pcm_no_speech",
                }
                record.update(stt_log)
                record.update(audio_evidence_log)
                self._append_turn_log(record)
                terminal_frame = (
                    self._conversation_ready_frame(transition)
                    if suppress_thinking
                    else self._conversation_heartbeat(transition)
                )
                terminal_frame.update(audio_summary)
                terminal_frame.update(stt_log)
                return [terminal_frame]
            if "begin_generation" not in transition.actions and not no_speech_detail:
                if suppress_thinking:
                    return [self._conversation_ready_frame(transition)]
                return [self._conversation_heartbeat(transition)]
            self._observe_conversation_transition(transition)
        if user_text and not stt_low_confidence:
            self._commit_memory(self.memory.remember_user_text(user_text))
            # Persist transcript-owned facts before model/TTS work so an explicit
            # remember request survives a later runner or audio failure.

        try:
            active_persona = self._active_persona()
        except (OSError, PersonaPackError, ValueError) as exc:
            return [self._conversation_failure("persona_error", str(exc))]
        requested_case = str(message.get("runner_case", "")).strip()
        runner_summary: dict[str, object] = {"persona_id": active_persona.pack_id}
        conversation_plan = (
            self.conversation.harness.plan(user_text, None, "")
            if self.conversation is not None
            else ConversationTurnPlan()
        )
        research_result: dict[str, object] | None = None
        relationship_card = RelationshipCard(())
        local_fact = resolve_local_fact(user_text, self.memory) if not requested_case else None
        visual_request = bool(
            not requested_case
            and local_fact is None
            and is_visual_context_request(user_text)
        )
        visual_color_request = visual_request and is_visual_color_request(user_text)
        visual_observation_error = ""
        if visual_request:
            runner_summary["visual_routing"] = (
                "grayscale_color_limit" if visual_color_request else "on_demand_observation"
            )
        if visual_request and not visual_color_request:
            visual_observation_error = self._refresh_visual_context()
            runner_summary["visual_observation_status"] = (
                visual_observation_error or "fresh"
            )
        embodiment_lines = self._embodiment_context_lines()
        if stt_low_confidence:
            runner_case = "low_confidence_speech"
            raw_response = low_confidence_character_response()
            runner_summary["runner_command_source"] = "local_stt_confidence_guard"
            runner_summary["runner_elapsed_ms"] = 0.0
            runner_summary["stt_low_confidence"] = True
        elif requested_initiative is not None:
            initiative_available = bool(
                self.initiative_policy is not None
                and self.config.tts_command
                and not self.config.disable_audio_downlink
            )
            enabled = bool(requested_initiative and initiative_available)
            if self.initiative_policy is not None:
                self.initiative_policy.set_enabled(enabled)
            self._commit_memory(
                self.memory.remember_initiative_preference(enabled)
            )
            runner_case = "initiative_preference"
            raw_response = initiative_preference_character_response(
                enabled,
                available=initiative_available or not requested_initiative,
            )
            runner_summary["runner_command_source"] = "local_initiative_preference"
            runner_summary["runner_elapsed_ms"] = 0.0
            runner_summary["initiative_requested"] = requested_initiative
            runner_summary["initiative_enabled"] = enabled
        elif no_speech_detail:
            runner_case = "no_speech"
            raw_response = no_speech_character_response()
            runner_summary["runner_command_source"] = "local_no_speech"
            runner_summary["runner_elapsed_ms"] = 0.0
            runner_summary["stt_no_transcript"] = True
        elif requested_forget_keys:
            runner_case = "forget"
            raw_response = forget_character_response(requested_forget_keys)
            runner_summary["runner_command_source"] = "local_forget"
            runner_summary["runner_elapsed_ms"] = 0.0
        elif local_fact is not None:
            runner_case = "local_fact"
            raw_response = local_fact.character_response()
            runner_summary["runner_command_source"] = f"trusted_{local_fact.tool}"
            runner_summary["runner_elapsed_ms"] = 0.0
            runner_summary["local_fact_tool"] = local_fact.tool
        elif visual_color_request:
            runner_case = "visual_color_limit"
            raw_response = grayscale_color_character_response()
            runner_summary["runner_command_source"] = "local_grayscale_limit"
            runner_summary["runner_elapsed_ms"] = 0.0
        elif visual_request and visual_observation_error:
            runner_case = "visual_unavailable"
            raw_response = visual_observation_unavailable_response(visual_observation_error)
            runner_summary["runner_command_source"] = "local_visual_status"
            runner_summary["runner_elapsed_ms"] = 0.0
        elif not requested_case and is_identity_question(user_text):
            runner_case = "identity"
            identity_name = (
                "Stackchan" if active_persona.pack_id == DEFAULT_PERSONA_ID else active_persona.display_name
            )
            raw_response = identity_character_response(identity_name)
            runner_summary["runner_command_source"] = "local_identity"
            runner_summary["runner_elapsed_ms"] = 0.0
        else:
            anticipated_research, anticipated_routing = natural_research_request(user_text)
            if self.conversation is not None:
                conversation_plan = self.conversation.harness.plan(
                    user_text,
                    anticipated_research,
                    anticipated_routing,
                    default_weather_location=self.memory.weather_location(),
                )
                anticipated_research = conversation_plan.request
                anticipated_routing = conversation_plan.routing
                runner_summary.update(conversation_plan.diagnostic_fields())
            runner_case = prompt_case_for_text(
                user_text,
                requested_case,
                self.config.runner_case,
                has_conversation_context=bool(self._conversation_context_lines())
                or conversation_plan.turn_kind != "new",
            )
            relationship_card = self._relationship_card(
                user_text,
                suppress_session_context=self.config.research_enabled and anticipated_research is not None,
            )
            if self.config.research_enabled and anticipated_research is not None:
                raw_response = json.dumps(
                    {"tool_request": anticipated_research},
                    separators=(",", ":"),
                    ensure_ascii=True,
                )
                runner_summary["runner_command_source"] = "deterministic_research_router"
                runner_summary["runner_elapsed_ms"] = 0.0
                runner_summary["research_routing"] = anticipated_routing
            else:
                try:
                    if self.dashboard_runtime is not None:
                        self.dashboard_runtime.note_pipeline_stage(
                            "generating",
                            turn_seq=seq,
                        )
                    runner = run_runner_profile(
                        self.config.runner_profile,
                        case_name=runner_case,
                        command=self.config.runner_command,
                        in_process_ollama=self.config.in_process_ollama_runner,
                        require_runner=self.config.require_runner,
                        timeout_ms=self.config.runner_timeout_ms,
                        user_text=user_text,
                        research_tools_enabled=(
                            self.config.research_enabled
                            and not conversation_plan.clarification
                        ),
                        embodiment_lines=embodiment_lines,
                        memory_lines=relationship_card.lines,
                        conversation_lines=self._conversation_context_lines(),
                        task_lines=conversation_plan.trusted_task_lines(),
                        cancellation=cancellation,
                        persona_id=active_persona.pack_id,
                    )
                except (RunnerConfigurationError, RunnerExecutionError, ValueError) as exc:
                    # A model failure used to return a bare error frame: the
                    # user got silence plus a face change. Speak a short
                    # in-character recovery line through the normal TTS and
                    # downlink path instead, keeping the turn wire-ordinary.
                    runner_summary["runner_error"] = str(exc)
                    runner_summary["runner_fallback_spoken"] = True
                    raw_response = model_failure_character_response()
                else:
                    raw_response = runner.raw_response
                    runner_summary["runner_command_source"] = runner.command_source
                    if getattr(runner, "response_repaired", False):
                        runner_summary["runner_response_repaired"] = True
                        runner_summary["runner_repair_reason"] = str(
                            getattr(runner, "repair_reason", "")
                        )
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
                if SENSITIVE_RESEARCH_TEXT.search(user_text):
                    tool_request = None
                    runner_summary["research_routing"] = "sensitive_query_blocked"
                elif (
                    PRIVATE_OR_EMBODIED_RESEARCH_TEXT.search(user_text)
                    or is_visual_context_request(user_text)
                ):
                    tool_request = None
                    runner_summary["research_routing"] = "private_or_embodied_query_blocked"
                elif conversation_plan.clarification:
                    tool_request = None
                    runner_summary["research_routing"] = "conversation_clarification"
                elif tool_request is None:
                    tool_request, routing = natural_research_request(user_text)
                    if tool_request is not None:
                        runner_summary["research_routing"] = routing
                    elif model_denies_research_access(raw_response):
                        tool_request = {
                            "name": "web_search",
                            "arguments": {"query": user_text, "max_results": 4},
                        }
                        runner_summary["research_routing"] = "model_access_denial_recovery"
                else:
                    runner_summary.setdefault("research_routing", "model_request")
                if tool_request is not None:
                    if (
                        self.conversation is not None
                        and conversation_plan.request is None
                        and not conversation_plan.clarification
                    ):
                        conversation_plan = self.conversation.harness.plan(
                            user_text,
                            tool_request,
                            str(runner_summary.get("research_routing", "model_request")),
                        )
                        runner_summary.update(conversation_plan.diagnostic_fields())
                    if self.research_broker is None:
                        research_result = {
                            "schema": "stackchan.research.v1",
                            "tool": str(tool_request.get("name", "")),
                            "error": "research_broker_unavailable",
                            "results": [],
                        }
                    else:
                        try:
                            if self.dashboard_runtime is not None:
                                self.dashboard_runtime.note_pipeline_stage(
                                    "researching",
                                    turn_seq=seq,
                                    task_domain=(
                                        conversation_plan.next_state.domain
                                        if conversation_plan.next_state is not None
                                        else "research"
                                    ),
                                )
                            research_result = self.research_broker.execute(tool_request)
                        except (ResearchPolicyError, ResearchTransportError, ValueError, TypeError) as exc:
                            research_result = {
                                "schema": "stackchan.research.v1",
                                "tool": str(tool_request.get("name", "")),
                                "error": str(exc)[:120],
                                "results": [],
                            }
                    active_task = conversation_plan.next_state
                    if (
                        active_task is not None
                        and active_task.domain == "weather"
                        and research_result_succeeded(research_result)
                        and not weather_result_matches(
                            active_task.slot("location"),
                            research_result,
                        )
                    ):
                        research_result = {
                            "schema": "stackchan.research.v1",
                            "tool": str(research_result.get("tool", "")),
                            "error": "research_result_context_mismatch",
                            "results": [],
                        }
                    research_routing = str(runner_summary.get("research_routing", ""))
                    runner_summary["research_result_count"] = len(
                        research_result.get("results", ())
                        if isinstance(research_result.get("results"), list)
                        else ()
                    )
                    runner_summary["research_status"] = (
                        "error"
                        if research_result.get("error")
                        else "ok"
                        if runner_summary["research_result_count"]
                        else "empty"
                    )
                    if (
                        self.research_broker is not None
                        and research_result.get("tool") == "web_search"
                        and research_routing
                        in {
                            "verification_request",
                            "model_access_denial_recovery",
                            "contextual_verify",
                        }
                    ):
                        top_urls = source_urls(research_result)
                        if top_urls:
                            try:
                                top_source = self.research_broker.execute(
                                    {
                                        "name": "web_fetch",
                                        "arguments": {
                                            "url": top_urls[0],
                                            "max_chars": 5000,
                                        },
                                    }
                                )
                            except (
                                ResearchPolicyError,
                                ResearchTransportError,
                                ValueError,
                                TypeError,
                            ) as exc:
                                runner_summary["research_fetch_status"] = str(exc)[:120]
                            else:
                                fetch_error = str(top_source.get("error", ""))
                                runner_summary["research_fetch_status"] = fetch_error or "ok"
                                if not fetch_error:
                                    research_result = dict(research_result)
                                    research_result["top_source"] = top_source
                    if research_result_succeeded(research_result):
                        evidence_user_text = (
                            f"{user_text}\n\n{evidence_prompt(research_result)}"
                        )
                        try:
                            if self.dashboard_runtime is not None:
                                self.dashboard_runtime.note_pipeline_stage(
                                    "generating",
                                    turn_seq=seq,
                                    task_domain=(
                                        conversation_plan.next_state.domain
                                        if conversation_plan.next_state is not None
                                        else "research"
                                    ),
                                )
                            researched = run_runner_profile(
                                self.config.runner_profile,
                                case_name=runner_case,
                                command=self.config.runner_command,
                                in_process_ollama=self.config.in_process_ollama_runner,
                                require_runner=self.config.require_runner,
                                timeout_ms=self.config.runner_timeout_ms,
                                user_text=evidence_user_text,
                                research_tools_enabled=False,
                                embodiment_lines=embodiment_lines,
                                memory_lines=relationship_card.lines,
                                conversation_lines=self._conversation_context_lines(),
                                task_lines=conversation_plan.trusted_task_lines(),
                                cancellation=cancellation,
                                persona_id=active_persona.pack_id,
                            )
                        except (
                            RunnerConfigurationError,
                            RunnerExecutionError,
                            ValueError,
                        ) as exc:
                            # Same recovery as the first model call: speak a
                            # short in-character line rather than going silent.
                            runner_summary["runner_error"] = str(exc)
                            runner_summary["runner_fallback_spoken"] = True
                            raw_response = model_failure_character_response()
                        else:
                            raw_response = self._clear_research_memory_writes(
                                researched.raw_response
                            )
                            runner_summary["research_tool"] = str(
                                research_result.get("tool", "")
                            )
                            runner_summary["research_source_count"] = len(
                                source_urls(research_result)
                            )
                            runner_summary["research_error"] = str(
                                research_result.get("error", "")
                            )
                            if researched.elapsed_ms is not None:
                                runner_summary["research_runner_elapsed_ms"] = round(
                                    researched.elapsed_ms,
                                    2,
                                )
                            if getattr(researched, "response_repaired", False):
                                runner_summary["research_response_repaired"] = True
                                runner_summary["research_repair_reason"] = str(
                                    getattr(researched, "repair_reason", "")
                                )

        if research_result is not None and not research_result_succeeded(
            research_result
        ):
            raw_response = research_unavailable_character_response()
            runner_summary["research_fallback"] = "local_unavailable"

        cancellation.raise_if_cancelled()
        turn, candidate_memory, validation = turn_from_character_response(
            raw_response,
            self.memory,
            session=self.session,
            seq=seq,
            persona=active_persona,
            allow_identity=runner_case == "identity",
            allow_visual_claims=trusted_visual_context_available(embodiment_lines),
            grounding_text="\n".join(
                (
                    user_text,
                    *embodiment_lines,
                    *relationship_card.lines,
                    *self._conversation_context_lines(),
                    *conversation_plan.trusted_task_lines(),
                )
            ),
            conversation_lines=self._conversation_context_lines(),
        )
        if research_result is not None:
            turn = replace(turn, citations=source_urls(research_result))
        elif not no_speech_detail and not stt_low_confidence:
            candidate_memory = candidate_memory.capture_open_loop(
                user_text,
                persona_id=active_persona.pack_id,
            )
            for topic in topics_for_user_text(user_text):
                if topic not in self._session_topics:
                    self._session_topics.append(topic)
            self._session_non_research_turns += 1
        candidate_memory, callback_consumed = candidate_memory.consume_open_loop(
            relationship_card.open_loop_id,
            turn.text,
        )
        runner_summary["memory_callback_consumed"] = callback_consumed
        if self.conversation is not None:
            self.playback_response_seq = seq
            if not no_speech_detail:
                transition = self.conversation.response_started(now_ms())
                if "reject_response" in transition.actions:
                    return [self._conversation_failure("conversation_response_rejected", transition.reason)]
                self._observe_conversation_transition(transition)
                self.conversation_response_seq = seq
        response_text_ready_ms = (time.perf_counter() - turn_started) * 1000.0
        if (
            self.config.stream_tts_phrases
            and self.config.tts_command
            and not self.config.disable_audio_downlink
        ):
            if self.dashboard_runtime is not None:
                self.dashboard_runtime.note_pipeline_stage(
                    "synthesizing",
                    turn_seq=seq,
                )
            frames, tts_summary, tts_error = self._stream_tts_turn(
                turn,
                turn_started=turn_started,
                validation_issues=list(validation.issues),
                frame_sink=frame_sink,
                cancellation=cancellation,
            )
            cancellation.raise_if_cancelled()
            self._commit_memory(candidate_memory)
            if not no_speech_detail and not stt_low_confidence:
                self._stage_conversation_turn(
                    user_text,
                    turn.text,
                    tts_error,
                    conversation_plan,
                    research_succeeded=research_result_succeeded(research_result),
                )
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
                host_reaction_ms=host_reaction_ms,
            )
            return frames
        tts_summary: dict[str, object] = {}
        downlink_frames: list[dict[str, object] | bytes] = []
        tts_error = ""
        try:
            if self.dashboard_runtime is not None:
                self.dashboard_runtime.note_pipeline_stage(
                    "synthesizing",
                    turn_seq=seq,
                )
            tts = synthesize_speech(
                turn.text,
                command=self.config.tts_command,
                voice=self.config.tts_voice,
                timeout_ms=self.config.tts_timeout_ms,
                cancellation=cancellation,
                mode=turn.intent,
                arousal=turn.arousal,
                valence=turn.valence,
                directml_in_process=self.config.in_process_directml_tts,
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
                "tts_mode": turn.intent,
                "tts_arousal": round(max(0.0, min(1.0, turn.arousal)), 3),
                "tts_valence": round(max(-1.0, min(1.0, turn.valence)), 3),
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
        except TtsConfigurationError as exc:
            if self.config.tts_command:
                # A configured TTS that cannot start is a real failure the
                # turn must report, not a silent text-only success.
                tts_error = str(exc)
            else:
                # Deliberate text-only deployment; the log says so instead of
                # the turn masquerading as spoken.
                tts_summary["tts_skipped"] = "no_tts_command"
        except (TtsExecutionError, ValueError) as exc:
            tts_error = str(exc)
        failure_payload: dict[str, object] = {}
        if tts_error and self.conversation is not None and not no_speech_detail:
            failure_payload = self._conversation_payload(
                self.conversation.turn_failed(now_ms(), "tts_error")
            )
        cancellation.raise_if_cancelled()
        self._commit_memory(candidate_memory)
        if not no_speech_detail and not stt_low_confidence:
            self._stage_conversation_turn(
                user_text,
                turn.text,
                tts_error,
                conversation_plan,
                research_succeeded=research_result_succeeded(research_result),
            )
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
        if tts_error:
            failure_frame = error_frame("tts_error", tts_error)
            failure_frame.update(failure_payload)
            prefix_errors.append(failure_frame)
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
            host_reaction_ms=host_reaction_ms,
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
) -> float:
    if isinstance(frame, bytes):
        conn.sendall(encode_ws_frame(frame, opcode=0x2))
        sent_at = time.perf_counter()
        delay_ms = config.downlink_binary_frame_delay_ms
        if final_binary_chunk and len(frame) < config.downlink_audio_chunk_bytes:
            delay_ms = max(delay_ms, 250)
        if delay_ms > 0:
            time.sleep(delay_ms / 1000.0)
        return sent_at
    conn.sendall(encode_ws_text(frame_to_text(frame)))
    sent_at = time.perf_counter()
    delay_ms = downlink_text_frame_delay_ms(config, frame)
    if delay_ms > 0:
        time.sleep(delay_ms / 1000.0)
    return sent_at


def downlink_text_frame_delay_ms(
    config: LanBridgeConfig,
    frame: dict[str, object],
) -> float:
    if config.stream_tts_phrases and frame.get("type") == "audio":
        return 0.0
    return float(config.downlink_text_frame_delay_ms)


def ends_audio_stream(frame: dict[str, object] | bytes) -> bool:
    return isinstance(frame, dict) and frame.get("type") == "audio_stream_end"


@dataclass
class ResponseWireState:
    active_seq: int | None = None
    aborting: bool = False

    def validate(self, frame: dict[str, object] | bytes) -> tuple[str, int] | None:
        if not isinstance(frame, dict):
            return None
        frame_type = str(frame.get("type", ""))
        if frame_type not in ("response_start", "response_end"):
            return None
        try:
            seq = int(frame.get("seq"))
        except (TypeError, ValueError):
            return ("response_seq_invalid", -1)
        if frame_type == "response_start" and self.active_seq is not None:
            return ("response_overlap", seq)
        if frame_type == "response_end":
            if self.active_seq is None:
                return ("response_end_without_start", seq)
            if seq != self.active_seq:
                return ("response_seq_mismatch", seq)
        return None

    def note_sent(self, frame: dict[str, object] | bytes) -> None:
        if not isinstance(frame, dict):
            return
        frame_type = str(frame.get("type", ""))
        if frame_type == "response_start":
            self.active_seq = int(frame["seq"])
            self.aborting = False
        elif frame_type == "response_end":
            self.active_seq = None
            self.aborting = False


def handle_connection(
    conn: socket.socket,
    config: LanBridgeConfig,
    memory: BridgeMemory,
    control_state: BridgeControlState | None = None,
    dashboard_runtime: DashboardRuntime | None = None,
    initiative_policy: InitiativePolicy | None = None,
    room_context: RoomContextRuntime | None = None,
    on_admitted: Callable[[WebSocketAdmission], None] | None = None,
) -> BridgeMemory:
    request = read_http_request(conn)
    print(f"[bridge-lan] handshake_bytes={len(request)}", flush=True)
    admission = validate_websocket_upgrade(request)
    session = LanBridgeSession(
        config,
        memory,
        control_state,
        initiative_policy=initiative_policy,
        room_context=room_context,
        dashboard_runtime=dashboard_runtime,
        transport_admitted=True,
    )
    conn.sendall(_handshake_response(admission))
    configure_client_socket(
        conn,
        config.client_idle_timeout_s,
        low_latency=config.stream_tts_phrases,
    )
    print("[bridge-lan] handshake_accepted=1", flush=True)
    if on_admitted is not None:
        on_admitted(admission)
    conn.sendall(encode_ws_text(frame_to_text({"type": "hello", "protocol": PROTOCOL, "session": session.session})))
    print("[bridge-lan] session_hello=1", flush=True)

    pending_short_chunk: bytes | None = None
    deferred_response_end: dict[str, object] | None = None
    audio_stream_ended_seq: int | None = None
    send_lock = threading.RLock()
    response_wire = ResponseWireState()
    turn_thread: threading.Thread | None = None
    turn_errors: queue.Queue[BaseException] = queue.Queue()

    def record_response_wire_event(
        code: str,
        *,
        seq: int,
        recovered: bool,
        reason: str = "",
    ) -> None:
        record: dict[str, object] = {
            "schema": "stackchan.response-wire-event.v1",
            "generated_at": utc_timestamp(),
            "session": session.session,
            "code": code,
            "seq": seq,
            "active_seq": response_wire.active_seq,
            "recovered": recovered,
        }
        if reason:
            record["reason"] = reason
        session._append_turn_log(record)

    def send_live(frame: dict[str, object] | bytes) -> float | None:
        nonlocal pending_short_chunk, deferred_response_end, audio_stream_ended_seq
        with send_lock:
            response_error = response_wire.validate(frame)
            if response_error is not None:
                code, seq = response_error
                record_response_wire_event(code, seq=seq, recovered=False)
                raise WebSocketProtocolError(code)
            aborting_response = (
                response_wire.active_seq is not None
                and isinstance(frame, dict)
                and frame.get("type") == "error"
            )
            if aborting_response:
                pending_short_chunk = None
            frame_type = str(frame.get("type", "")) if isinstance(frame, dict) else ""
            if config.conversation_v2_enabled and frame_type == "response_start":
                session.playback_response_seq = max(0, int(frame.get("seq", 0)))
            if response_wire.aborting and (
                isinstance(frame, bytes)
                or frame_type in ("audio", "audio_stream_start", "audio_stream_end")
            ):
                pending_short_chunk = None
                return None
            if (
                config.conversation_v2_enabled
                and frame_type == "response_end"
                and not response_wire.aborting
                and audio_stream_ended_seq == int(frame.get("seq", -1))
            ):
                deferred_response_end = dict(frame)
                record_response_wire_event(
                    "response_end_deferred",
                    seq=audio_stream_ended_seq,
                    recovered=True,
                    reason="awaiting_playback_complete",
                )
                return None
            if pending_short_chunk is not None:
                send_connection_frame(
                    conn,
                    config,
                    pending_short_chunk,
                    final_binary_chunk=ends_audio_stream(frame),
                )
                pending_short_chunk = None
            if (
                config.stream_tts_phrases
                and isinstance(frame, bytes)
                and len(frame) < config.downlink_audio_chunk_bytes
            ):
                pending_short_chunk = frame
                return None
            sent_at = send_connection_frame(conn, config, frame)
            if frame_type == "audio_stream_end":
                audio_stream_ended_seq = int(frame["seq"])
            response_wire.note_sent(frame)
            if aborting_response:
                response_wire.aborting = True
            return sent_at

    def flush_deferred_response_end(seq: int) -> bool:
        nonlocal deferred_response_end, audio_stream_ended_seq
        with send_lock:
            if deferred_response_end is None:
                return False
            deferred_seq = int(deferred_response_end.get("seq", -1))
            if deferred_seq != seq:
                raise WebSocketProtocolError("playback_complete_deferred_response_mismatch")
            frame = deferred_response_end
            send_connection_frame(conn, config, frame)
            response_wire.note_sent(frame)
            deferred_response_end = None
            audio_stream_ended_seq = None
            record_response_wire_event(
                "response_end_after_playback_complete",
                seq=seq,
                recovered=True,
            )
            return True

    def discard_pending_audio() -> None:
        nonlocal pending_short_chunk
        with send_lock:
            pending_short_chunk = None

    def close_interrupted_response(
        reason: str,
        *,
        preserve_deferred: bool = False,
    ) -> None:
        nonlocal pending_short_chunk, deferred_response_end, audio_stream_ended_seq
        with send_lock:
            seq = response_wire.active_seq
            if seq is None:
                return
            if preserve_deferred and deferred_response_end is not None:
                return
            pending_short_chunk = None
            try:
                send_connection_frame(conn, config, error_frame("response_aborted"))
                response_wire.aborting = True
                end_frame: dict[str, object] = {"type": "response_end", "seq": seq}
                send_connection_frame(conn, config, end_frame)
                response_wire.note_sent(end_frame)
                deferred_response_end = None
                audio_stream_ended_seq = None
            except Exception:
                record_response_wire_event(
                    "response_unclosed",
                    seq=seq,
                    recovered=False,
                    reason=reason,
                )
                raise
            record_response_wire_event(
                "response_forced_closed",
                seq=seq,
                recovered=True,
                reason=reason,
            )

    def run_turn(
        text: str,
        suppress_thinking: bool,
        finalized_audio: FinalizedAudioUpload,
    ) -> None:
        worker_error: BaseException | None = None
        try:
            frames = session.handle_text(
                text,
                suppress_thinking=suppress_thinking,
                frame_sink=send_live if config.stream_tts_phrases else None,
                finalized_audio=finalized_audio,
            )
            for frame in frames:
                send_live(frame)
        except Exception as exc:  # surfaced on the connection thread
            worker_error = exc
        finally:
            try:
                close_interrupted_response(
                    "turn_interrupted",
                    preserve_deferred=worker_error is None,
                )
            except Exception as exc:
                if worker_error is None:
                    worker_error = exc
            if worker_error is not None:
                turn_errors.put(worker_error)

    def run_initiative_turn(decision: InitiativeDecision) -> None:
        worker_error: BaseException | None = None
        try:
            frames = session.run_initiative(
                decision,
                frame_sink=send_live if config.stream_tts_phrases else None,
            )
            for frame in frames:
                send_live(frame)
        except Exception as exc:  # surfaced on the connection thread
            worker_error = exc
        finally:
            try:
                close_interrupted_response(
                    "initiative_interrupted",
                    preserve_deferred=worker_error is None,
                )
            except Exception as exc:
                if worker_error is None:
                    worker_error = exc
            if worker_error is not None:
                turn_errors.put(worker_error)

    if config.auto_turn_text:
        seq = now_ms() % 1000000
        auto_turn = {"type": "utterance_end", "seq": seq, "text": config.auto_turn_text}
        print(f"[bridge-lan] auto_turn_start seq={seq}", flush=True)
        conn.sendall(encode_ws_text(frame_to_text({"type": "thinking", "seq": seq})))
        auto_turn_error: BaseException | None = None
        try:
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
        except Exception as exc:
            auto_turn_error = exc
        finally:
            try:
                close_interrupted_response(
                    "auto_turn_interrupted",
                    preserve_deferred=auto_turn_error is None,
                )
            except Exception as exc:
                if auto_turn_error is None:
                    auto_turn_error = exc
        if auto_turn_error is not None:
            raise auto_turn_error
    try:
        while True:
            if not turn_errors.empty():
                raise turn_errors.get_nowait()
            opcode, payload = read_ws_frame(conn)
            frame_received_at = time.perf_counter()
            text_message_type = ""
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
                if (
                    dashboard_runtime is not None
                    and text_message_type == "heartbeat"
                    and isinstance(parsed_text, dict)
                ):
                    dashboard_runtime.note_heartbeat(parsed_text)
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
                    if deferred_response_end is not None:
                        close_interrupted_response("barge_in")
                if (
                    text_message_type == "playback_complete"
                    and isinstance(parsed_text, dict)
                    and parsed_text.get("interrupted") is True
                ):
                    session.cancel_active_turn("playback_interrupted")
                    discard_pending_audio()
                    if deferred_response_end is None:
                        close_interrupted_response("playback_interrupted")

                if text_message_type == "utterance_end":
                    if isinstance(parsed_text, dict):
                        audio_end_error = session.prepare_utterance_end(parsed_text)
                        if audio_end_error is not None:
                            send_live(audio_end_error)
                            continue
                    if turn_thread is not None and turn_thread.is_alive():
                        turn_thread.join(timeout=1.5)
                    if turn_thread is not None and turn_thread.is_alive():
                        send_live(error_frame("turn_busy", "the cancelled response is still stopping"))
                        continue
                    early_frame = session.early_thinking_frame(text)
                    finalized_audio = session.finalize_audio_upload()
                    if isinstance(parsed_text, dict):
                        audio_end_error = session.prepare_utterance_end(
                            parsed_text,
                            finalized_audio=finalized_audio,
                        )
                        if audio_end_error is not None:
                            send_live(audio_end_error)
                            continue
                    if early_frame is not None:
                        sent_at = send_live(early_frame)
                        if sent_at is not None and isinstance(parsed_text, dict):
                            parsed_text["_bridge_host_reaction_ms"] = max(
                                0.0, (sent_at - frame_received_at) * 1000.0
                            )
                            text = json.dumps(parsed_text, separators=(",", ":"), ensure_ascii=True)
                    turn_thread = threading.Thread(
                        target=run_turn,
                        args=(text, early_frame is not None, finalized_audio),
                        name="stackchan-turn-worker",
                        daemon=True,
                    )
                    turn_thread.start()
                    continue

                frames = session.handle_text(text)
                if text_message_type == "playback_complete":
                    completion_seq = next(
                        (
                            int(frame.get("seq", frame.get("playback_complete_seq", 0)))
                            for frame in frames
                            if isinstance(frame, dict)
                            and (
                                frame.get("type") == "conversation_reply_window"
                                or (
                                    frame.get("type") == "heartbeat"
                                    and frame.get("playback_complete_seq") is not None
                                )
                            )
                        ),
                        0,
                    )
                    if completion_seq > 0:
                        flush_deferred_response_end(completion_seq)
                endpoint_heartbeat = (
                    text_message_type == "heartbeat"
                    and isinstance(parsed_text, dict)
                    and bool(normalize_endpoint_id(parsed_text.get("endpoint_id")))
                )
                if text_message_type == "heartbeat" and not endpoint_heartbeat:
                    frames = []
            elif opcode == 0x2:
                before_chunks = session.audio.chunks
                frames = session.handle_binary(payload)
                if session.audio.chunks != before_chunks:
                    if session.audio.chunks == 1 or session.audio.chunks % 20 == 0:
                        print(
                            f"[bridge-lan] utterance_audio chunks={session.audio.chunks} "
                            f"bytes={session.audio.bytes_received}",
                            flush=True,
                        )
                else:
                    code = ""
                    if frames and isinstance(frames[0], dict):
                        code = str(frames[0].get("code", ""))
                    print(
                        f"[bridge-lan] rejected_binary code={code or 'unknown'} "
                        f"bytes={len(payload)}",
                        flush=True,
                    )
                frames = []
            else:
                frames = [error_frame("unsupported_websocket_opcode", str(opcode))]
            for frame in frames:
                send_live(frame)
            if text_message_type == "heartbeat" and (
                turn_thread is None or not turn_thread.is_alive()
            ):
                decision = session.initiative_decision()
                if decision is not None:
                    turn_thread = threading.Thread(
                        target=run_initiative_turn,
                        args=(decision,),
                        name="stackchan-initiative-worker",
                        daemon=True,
                    )
                    turn_thread.start()
    finally:
        session.cancel_active_turn("connection_closed")
        session.connection_closed()
        discard_pending_audio()
        if turn_thread is not None and turn_thread.is_alive():
            turn_thread.join(timeout=2.0)
    return session.memory


def serve(config: LanBridgeConfig) -> None:
    allowed_robot_peers = resolve_robot_peer_addresses(config)
    memory = load_bridge_memory(config.memory_file) if config.memory_file else BridgeMemory()
    control_state = BridgeControlState()
    initiative_policy = InitiativePolicy(
        InitiativeConfig(
            enabled=config.initiative_enabled,
            min_interval_ms=config.initiative_min_interval_ms,
        )
    )
    stt_supervisor = (
        SttServerSupervisor(
            SttSupervisorConfig(
                server_url=config.stt_server_url,
                restart_command=config.stt_restart_command,
                health_interval_seconds=config.stt_health_interval_s,
            )
        )
        if config.stt_server_url
        else None
    )
    if stt_supervisor is not None:
        stt_supervisor.start()
    frame_source = None
    model_observer = None
    room_configuration_error = ""
    if config.robot_host and config.camera_pairing_code_file:
        try:
            pairing_code = config.camera_pairing_code_file.read_text(encoding="ascii").strip()
            frame_source = PrivateCameraFrameSource(
                f"http://{config.robot_host}:{config.robot_http_port}",
                pairing_code,
            )
        except (OSError, UnicodeError, ValueError) as exc:
            room_configuration_error = str(exc)
    if config.room_vision_command:
        try:
            model_observer = ExternalRoomVisionModel(
                config.room_vision_command,
                timeout_ms=config.room_vision_timeout_ms,
            )
        except ValueError as exc:
            room_configuration_error = str(exc)

    def note_room_summary(summary: RoomSceneSummary) -> None:
        if summary.person_present is not None:
            initiative_policy.observe_presence(
                summary.person_present,
                face_count=summary.person_count,
                now_ms=summary.observed_ms,
            )
        initiative_policy.observe_scene_changes(summary.changes, now_ms=summary.observed_ms)

    room_context = RoomContextRuntime(
        RoomObservationConfig(
            enabled=config.room_observation_enabled,
            interval_seconds=config.room_observation_interval_seconds,
            command=config.room_vision_command,
            timeout_ms=config.room_vision_timeout_ms,
        ),
        frame_source=frame_source,
        model_observer=model_observer,
        on_summary=note_room_summary,
    )
    if room_configuration_error:
        print(f"[bridge-room] configuration_degraded={room_configuration_error}", flush=True)
    room_context.start()
    dashboard_runtime: DashboardRuntime | None = None
    dashboard_server = None
    dashboard_thread = None
    if config.dashboard_enabled:
        dashboard_runtime = DashboardRuntime(
            DashboardConfig(
                host=config.dashboard_host,
                port=config.dashboard_port,
                robot_host=config.robot_host,
                robot_http_port=config.robot_http_port,
                bridge_host=config.host,
                bridge_port=config.port,
                runner_profile=config.runner_profile,
                tts_voice=config.tts_voice,
                research_enabled=config.research_enabled,
                conversation_v2_enabled=config.conversation_v2_enabled,
                stt_server_url=config.stt_server_url,
            ),
            initiative_policy=initiative_policy,
            room_context=room_context,
            stt_supervisor=stt_supervisor,
        )
        dashboard_server, dashboard_thread = start_dashboard_server(dashboard_runtime)
    try:
        with socket.create_server((config.host, config.port), reuse_port=False) as server:
            server.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
            if dashboard_runtime is not None:
                dashboard_runtime.set_bridge_listening(True)
            print(f"[bridge-lan] listening ws://{config.host}:{config.port} protocol={PROTOCOL}", flush=True)
            while True:
                conn, address = server.accept()
                print(f"[bridge-lan] client={address[0]}:{address[1]}", flush=True)
                if allowed_robot_peers is not None and not peer_address_allowed(
                    address[0], allowed_robot_peers
                ):
                    print(
                        f"[bridge-lan] peer_rejected={address[0]}:{address[1]}",
                        flush=True,
                    )
                    conn.close()
                    continue
                admitted = False

                def note_admitted(_admission: WebSocketAdmission) -> None:
                    nonlocal admitted
                    admitted = True
                    if dashboard_runtime is not None:
                        dashboard_runtime.note_client_connected(address[0], address[1])

                try:
                    with conn:
                        conn.settimeout(5.0)
                        try:
                            memory = handle_connection(
                                conn,
                                config,
                                memory,
                                control_state,
                                dashboard_runtime,
                                initiative_policy,
                                room_context,
                                note_admitted,
                            )
                        except WebSocketProtocolError as exc:
                            print(f"[bridge-lan] client_disconnect={address[0]}:{address[1]} reason=\"{exc}\"", flush=True)
                        except OSError as exc:
                            print(f"[bridge-lan] client_disconnect={address[0]}:{address[1]} reason=\"socket:{exc}\"", flush=True)
                finally:
                    if admitted and dashboard_runtime is not None:
                        dashboard_runtime.note_client_disconnected(address[0])
                if config.once and admitted:
                    break
    finally:
        room_context.stop()
        if stt_supervisor is not None:
            stt_supervisor.stop()
        if dashboard_runtime is not None:
            dashboard_runtime.set_bridge_listening(False)
        if dashboard_server is not None and dashboard_thread is not None:
            stop_dashboard_server(dashboard_server, dashboard_thread)


def build_arg_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        description="Run the local Stackchan P7 LAN WebSocket bridge.",
        allow_abbrev=False,
    )
    parser.add_argument("--host", default="127.0.0.1")
    parser.add_argument("--port", type=int, default=8765)
    parser.add_argument("--once", action="store_true", help="Handle one client and exit.")
    parser.add_argument("--runner-profile", choices=sorted(RUNNER_PROFILES), default="gemma4-e2b-gguf")
    parser.add_argument("--runner-case", default="greeting")
    parser.add_argument("--runner-command", default="")
    parser.add_argument("--in-process-ollama-runner", action="store_true")
    parser.add_argument("--require-runner", action="store_true")
    parser.add_argument("--runner-timeout-ms", type=int, default=60000)
    parser.add_argument("--persona", default=DEFAULT_PERSONA_ID, help="Validated persona pack id.")
    parser.add_argument("--stt-command", default="")
    parser.add_argument("--stt-server-url", default="")
    parser.add_argument("--stt-restart-command", default="")
    parser.add_argument("--stt-health-interval-s", type=float, default=2.0)
    parser.add_argument("--stt-timeout-ms", type=int, default=DEFAULT_STT_TIMEOUT_MS)
    parser.add_argument("--stt-min-confidence", type=float, default=0.45)
    parser.add_argument("--stt-diagnostic-expected-file", type=Path)
    parser.add_argument("--stt-diagnostic-critical-token", action="append", default=[])
    parser.add_argument("--require-audio-wake-phrase", action="store_true")
    parser.add_argument("--tts-command", default="")
    parser.add_argument("--in-process-directml-tts", action="store_true")
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
    parser.add_argument(
        "--audio-capture-absolute-lease-ms",
        type=int,
        default=DEFAULT_AUDIO_CAPTURE_ABSOLUTE_LEASE_MS,
    )
    parser.add_argument(
        "--audio-capture-inactivity-lease-ms",
        type=int,
        default=DEFAULT_AUDIO_CAPTURE_INACTIVITY_LEASE_MS,
    )
    parser.add_argument("--audio-evidence-dir", type=Path)
    parser.add_argument("--memory-file", type=Path)
    parser.add_argument("--turn-log-file", type=Path)
    parser.add_argument("--redact-turn-text", action="store_true")
    parser.add_argument("--auto-turn-text", default="")
    parser.add_argument("--enable-research", action="store_true")
    parser.add_argument("--searxng-url", default="http://127.0.0.1:8080")
    parser.add_argument("--conversation-v2", action="store_true")
    parser.add_argument("--conversation-reply-window-ms", type=int, default=10000)
    parser.add_argument("--conversation-reply-window-min-ms", type=int, default=10000)
    parser.add_argument("--conversation-reply-window-step-ms", type=int, default=0)
    parser.add_argument("--conversation-acoustic-tail-ms", type=int, default=250)
    parser.add_argument("--conversation-cooldown-ms", type=int, default=300)
    parser.add_argument("--conversation-max-turns", type=int, default=24)
    parser.add_argument("--conversation-max-context-turns", type=int, default=24)
    parser.add_argument("--conversation-max-context-chars", type=int, default=160)
    parser.add_argument("--enable-initiative", action="store_true")
    parser.add_argument(
        "--initiative-min-interval-seconds",
        type=int,
        default=MIN_UNPROMPTED_INTERVAL_MS // 1000,
    )
    parser.add_argument("--room-observation", action="store_true")
    parser.add_argument("--room-observation-interval-seconds", type=int, default=300)
    parser.add_argument("--room-vision-command", default="")
    parser.add_argument("--room-vision-timeout-ms", type=int, default=30000)
    parser.add_argument("--camera-pairing-code-file", type=Path)
    parser.add_argument(
        "--enable-episode-distillation",
        action="store_true",
        help="Opt in to persisting strictly validated local-model session summaries.",
    )
    parser.add_argument("--dashboard", action="store_true", help="Serve the loopback bridge dashboard.")
    parser.add_argument("--dashboard-host", default=DEFAULT_DASHBOARD_HOST)
    parser.add_argument("--dashboard-port", type=int, default=DEFAULT_DASHBOARD_PORT)
    parser.add_argument("--robot-host", default="", help="Robot host for verified dashboard controls.")
    parser.add_argument("--robot-http-port", type=int, default=DEFAULT_ROBOT_HTTP_PORT)
    parser.add_argument("--reset-memory", action="store_true")
    return parser


def main() -> int:
    parser = build_arg_parser()
    args = parser.parse_args()
    if args.dashboard and args.dashboard_host not in {"127.0.0.1", "::1", "localhost"}:
        parser.error("Dashboard must bind to a loopback host.")
    if not 1_000 <= args.conversation_reply_window_ms <= 30_000:
        parser.error("--conversation-reply-window-ms must be between 1000 and 30000")
    if not 1_000 <= args.conversation_reply_window_min_ms <= args.conversation_reply_window_ms:
        parser.error(
            "--conversation-reply-window-min-ms must be between 1000 and the initial window"
        )
    if args.conversation_reply_window_step_ms < 0:
        parser.error("--conversation-reply-window-step-ms cannot be negative")
    if not 0.0 <= args.stt_min_confidence <= 1.0:
        parser.error("--stt-min-confidence must be between 0 and 1")
    if not 12_500 <= args.audio_capture_absolute_lease_ms <= 15_000:
        parser.error("--audio-capture-absolute-lease-ms must be between 12500 and 15000")
    if not 1_000 <= args.audio_capture_inactivity_lease_ms < args.audio_capture_absolute_lease_ms:
        parser.error(
            "--audio-capture-inactivity-lease-ms must be between 1000 and the absolute lease"
        )
    if not 0 <= args.conversation_acoustic_tail_ms <= 2_000:
        parser.error("--conversation-acoustic-tail-ms must be between 0 and 2000")
    if args.initiative_min_interval_seconds < MIN_UNPROMPTED_INTERVAL_MS // 1000:
        parser.error("--initiative-min-interval-seconds must be at least 600")
    if not 120 <= args.room_observation_interval_seconds <= 1_800:
        parser.error("--room-observation-interval-seconds must be between 120 and 1800")
    if args.reset_memory and args.memory_file:
        reset_bridge_memory(args.memory_file)
    diagnostic_expected_text = ""
    if args.stt_diagnostic_expected_file is not None:
        try:
            diagnostic_expected_text = args.stt_diagnostic_expected_file.read_text(
                encoding="utf-8"
            ).strip()
        except OSError as exc:
            parser.error(f"could not read --stt-diagnostic-expected-file: {exc}")
        if not diagnostic_expected_text or len(diagnostic_expected_text) > 500:
            parser.error("--stt-diagnostic-expected-file must contain 1 to 500 characters")
    conversation_max_turns = max(1, min(50, args.conversation_max_turns))
    config = LanBridgeConfig(
        host=args.host,
        port=args.port,
        once=args.once,
        runner_profile=args.runner_profile,
        runner_case=args.runner_case,
        runner_command=args.runner_command,
        in_process_ollama_runner=args.in_process_ollama_runner,
        require_runner=args.require_runner,
        runner_timeout_ms=args.runner_timeout_ms,
        persona_id=args.persona,
        stt_command=args.stt_command,
        stt_server_url=args.stt_server_url,
        stt_restart_command=args.stt_restart_command,
        stt_health_interval_s=args.stt_health_interval_s,
        stt_timeout_ms=args.stt_timeout_ms,
        stt_min_confidence=args.stt_min_confidence,
        stt_diagnostic_expected_text=diagnostic_expected_text,
        stt_diagnostic_critical_tokens=tuple(args.stt_diagnostic_critical_token),
        require_audio_wake_phrase=args.require_audio_wake_phrase,
        tts_command=args.tts_command,
        in_process_directml_tts=args.in_process_directml_tts,
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
        audio_capture_absolute_lease_ms=args.audio_capture_absolute_lease_ms,
        audio_capture_inactivity_lease_ms=args.audio_capture_inactivity_lease_ms,
        audio_evidence_dir=args.audio_evidence_dir,
        memory_file=args.memory_file,
        turn_log_file=args.turn_log_file,
        redact_turn_text=args.redact_turn_text,
        auto_turn_text=args.auto_turn_text,
        research_enabled=args.enable_research,
        searxng_url=args.searxng_url,
        conversation_v2_enabled=args.conversation_v2,
        conversation_reply_window_ms=args.conversation_reply_window_ms,
        conversation_reply_window_min_ms=args.conversation_reply_window_min_ms,
        conversation_reply_window_step_ms=args.conversation_reply_window_step_ms,
        conversation_acoustic_tail_ms=args.conversation_acoustic_tail_ms,
        conversation_cooldown_ms=max(0, min(5000, args.conversation_cooldown_ms)),
        conversation_max_turns=conversation_max_turns,
        conversation_max_context_turns=max(
            1,
            min(conversation_max_turns, args.conversation_max_context_turns),
        ),
        conversation_max_context_chars=max(64, min(320, args.conversation_max_context_chars)),
        initiative_enabled=args.enable_initiative,
        initiative_min_interval_ms=args.initiative_min_interval_seconds * 1000,
        room_observation_enabled=args.room_observation,
        room_observation_interval_seconds=args.room_observation_interval_seconds,
        room_vision_command=args.room_vision_command,
        room_vision_timeout_ms=args.room_vision_timeout_ms,
        camera_pairing_code_file=args.camera_pairing_code_file,
        episode_distillation_enabled=(
            args.enable_episode_distillation
            or os.environ.get("STACKCHAN_ENABLE_EPISODE_DISTILLATION", "").strip().lower()
            in {"1", "true", "yes", "on"}
        ),
        dashboard_enabled=args.dashboard,
        dashboard_host=args.dashboard_host,
        dashboard_port=max(1, min(65535, args.dashboard_port)),
        robot_host=args.robot_host,
        robot_http_port=max(1, min(65535, args.robot_http_port)),
    )
    serve(config)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
