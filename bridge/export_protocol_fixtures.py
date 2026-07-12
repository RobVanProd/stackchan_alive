#!/usr/bin/env python3
"""Write deterministic stackchan.bridge.v1 protocol fixtures."""

from __future__ import annotations

import argparse
import json
from pathlib import Path
from typing import Any

from reference_bridge import PROTOCOL, BridgeTurn, bridge_frames

ROOT = Path(__file__).resolve().parents[1]
FIXTURE_DIR = ROOT / "protocol-fixtures"


def _bridge_frame(frame_type: str) -> dict[str, Any]:
    turn = BridgeTurn(session="stackchan-001", seq=41, text="Hello. I am awake and looking.")
    for frame in bridge_frames(turn):
        if frame["type"] == frame_type:
            return dict(frame)
    raise ValueError(f"reference bridge did not emit {frame_type!r}")


def fixture_documents() -> dict[str, dict[str, Any]]:
    return {
        "device_hello.json": {
            "type": "hello",
            "protocol": PROTOCOL,
            "device_id": "stackchan-001",
            "device_name": "Stackchan Alive",
            "firmware_version": "dev",
            "sample_rate": 16000,
            "capabilities": ["wake_gate", "pcm16_upload", "pcm16_downlink", "settings"],
            "trusted_endpoint_count": 2,
            "active_brain_owner": "pc-studio-01",
        },
        "bridge_hello.json": _bridge_frame("hello"),
        "endpoint_hello.json": {
            "type": "endpoint_hello",
            "protocol": PROTOCOL,
            "endpoint_id": "phone-rob-01",
            "endpoint_name": "Rob's Phone",
            "endpoint_kind": "android",
            "app_version": "1.0.0",
            "pairing_code": "7K9PQ2",
            "priority": 60,
            "supports_binary_audio": True,
            "capabilities": [
                "stt",
                "llm",
                "tts",
                "settings",
                "persona_select",
                "model_profiles",
                "diagnostics",
            ],
        },
        "utterance_start.json": {
            "type": "utterance_start",
            "seq": 41,
            "sample_rate": 16000,
        },
        "utterance_audio.json": {
            "type": "utterance_audio",
            "seq": 41,
            "pcm_b64": "AQACAAMA",
        },
        "utterance_end.json": {
            "type": "utterance_end",
            "seq": 41,
            "transcript": "Hello Stackchan.",
        },
        "cancel.json": {
            "type": "cancel",
            "seq": 41,
            "reason": "barge_in",
        },
        "playback_complete.json": {
            "type": "playback_complete",
            "seq": 41,
            "at_ms": 123456,
        },
        "conversation_reply_window.json": {
            "type": "conversation_reply_window",
            "seq": 41,
            "open_after_ms": 250,
            "window_ms": 8000,
        },
        "listening.json": _bridge_frame("listening"),
        "thinking.json": _bridge_frame("thinking"),
        "response_start.json": _bridge_frame("response_start"),
        "audio.json": _bridge_frame("audio"),
        "response_end.json": _bridge_frame("response_end"),
        "audio_stream_start.json": {
            "type": "audio_stream_start",
            "seq": 41,
            "format": "pcm16",
            "sample_rate": 22050,
            "audio_bytes": 4096,
            "chunk_bytes": 4096,
            "chunks": 1,
        },
        "audio_stream_end.json": {
            "type": "audio_stream_end",
            "seq": 41,
            "audio_bytes": 4096,
            "chunks": 1,
        },
        "heartbeat.json": {
            "type": "heartbeat",
            "seq": 41,
            "owner": "phone-rob-01",
        },
        "error.json": {
            "type": "error",
            "seq": 41,
            "code": "bridge_timeout",
            "detail": "No bridge traffic before timeout window.",
            "recoverable": True,
        },
        "claim_brain.json": {
            "type": "claim_brain",
            "endpoint_id": "phone-rob-01",
            "reason": "user_selected",
        },
        "release_brain.json": {
            "type": "release_brain",
            "endpoint_id": "phone-rob-01",
            "reason": "handoff_to_pc",
        },
        "owner_status.json": {
            "type": "owner_status",
            "active_brain_owner": "phone-rob-01",
            "owner_kind": "android",
            "state": "healthy",
        },
        "settings_get.json": {
            "type": "settings_get",
            "domains": ["persona", "voice", "motion", "display", "bridge", "privacy"],
        },
        "settings_snapshot.json": {
            "type": "settings_snapshot",
            "version": 12,
            "settings": {
                "persona": {"active": "spark"},
                "display": {"reduced_motion": True},
                "motion": {"servo_enabled": False},
            },
        },
        "settings_set.json": {
            "type": "settings_set",
            "version": 12,
            "settings": {
                "display": {"reduced_motion": True},
                "bridge": {"preferred_mode_policy": "mobile_preferred"},
            },
        },
        "settings_result.json": {
            "type": "settings_result",
            "ok": True,
            "version": 13,
        },
        "trusted_endpoints.json": {
            "type": "trusted_endpoints",
        },
        "trusted_endpoints_result.json": {
            "type": "trusted_endpoints_result",
            "endpoints": [
                {
                    "endpoint_id": "pc-studio-01",
                    "endpoint_name": "Studio PC",
                    "endpoint_kind": "pc",
                    "public_key_fingerprint": "sha256:1111222233334444",
                    "priority": 80,
                    "auto_connect": True,
                    "capabilities": ["stt", "llm", "tts", "rvc", "settings", "audio_downlink"],
                    "last_seen_ms": 1720000000000,
                },
                {
                    "endpoint_id": "phone-rob-01",
                    "endpoint_name": "Rob's Phone",
                    "endpoint_kind": "android",
                    "public_key_fingerprint": "sha256:aaaabbbbccccdddd",
                    "priority": 60,
                    "auto_connect": True,
                    "capabilities": ["stt", "llm", "tts", "settings", "persona_select"],
                    "last_seen_ms": 1720000000100,
                },
            ],
        },
        "forget_endpoint.json": {
            "type": "forget_endpoint",
            "endpoint_id": "phone-rob-01",
        },
        "forget_endpoint_result.json": {
            "type": "forget_endpoint_result",
            "endpoint_id": "phone-rob-01",
            "ok": True,
        },
        "diagnostics_request.json": {
            "type": "diagnostics_request",
            "domains": ["bridge", "audio", "model", "firmware", "battery"],
        },
        "diagnostics_snapshot.json": {
            "type": "diagnostics_snapshot",
            "bridge": {"state": "ready", "timeouts": 0},
            "audio": {"sample_rate": 16000, "stream_bytes": 4096},
            "model": {"profile": "fake", "latency_ms": 120},
            "firmware": {"version": "dev"},
            "battery": {"percent": 87, "charging": False},
        },
        "capability_update.json": {
            "type": "capability_update",
            "endpoint_id": "phone-rob-01",
            "capabilities": ["settings", "llm", "tts"],
        },
        "unknown_future_message.json": {
            "type": "future_probe",
            "protocol": PROTOCOL,
            "future_field": "ignored",
        },
    }


def invalid_fixture_documents() -> dict[str, dict[str, Any]]:
    return {
        "invalid/missing_type.json": {
            "protocol": PROTOCOL,
            "endpoint_id": "phone-rob-01",
        },
        "invalid/wrong_protocol.json": {
            "type": "endpoint_hello",
            "protocol": "stackchan.bridge.v2",
            "endpoint_id": "phone-rob-01",
            "endpoint_name": "Rob's Phone",
            "endpoint_kind": "android",
            "app_version": "1.0.0",
            "priority": 60,
            "supports_binary_audio": True,
            "capabilities": ["settings"],
        },
        "invalid/missing_endpoint_id.json": {
            "type": "endpoint_hello",
            "protocol": PROTOCOL,
            "endpoint_name": "Rob's Phone",
            "endpoint_kind": "android",
            "app_version": "1.0.0",
            "priority": 60,
            "supports_binary_audio": True,
            "capabilities": ["settings"],
        },
        "invalid/camel_case_field.json": {
            "type": "claim_brain",
            "endpointId": "phone-rob-01",
            "reason": "user_selected",
        },
    }


def all_documents() -> dict[str, dict[str, Any]]:
    return {**fixture_documents(), **invalid_fixture_documents()}


def render_document(document: dict[str, Any]) -> str:
    return json.dumps(document, indent=2, sort_keys=True, ensure_ascii=True) + "\n"


def write_fixtures(directory: Path) -> None:
    for relative_path, document in all_documents().items():
        path = directory / relative_path
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(render_document(document), encoding="utf-8")


def main() -> int:
    parser = argparse.ArgumentParser(description="Export deterministic protocol fixture JSON files.")
    parser.add_argument("--out-dir", type=Path, default=FIXTURE_DIR)
    args = parser.parse_args()
    write_fixtures(args.out_dir)
    print(f"Wrote {len(all_documents())} protocol fixtures to {args.out_dir}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
