import json
import re
import sys
import unittest
from pathlib import Path
from typing import Any

sys.path.insert(0, str(Path(__file__).resolve().parent))

from export_protocol_fixtures import (
    FIXTURE_DIR,
    PROTOCOL,
    all_documents,
    fixture_documents,
    invalid_fixture_documents,
    render_document,
)

KNOWN_TYPES = {
    "audio",
    "audio_stream_end",
    "audio_stream_start",
    "cancel",
    "capability_update",
    "claim_brain",
    "diagnostics_request",
    "diagnostics_snapshot",
    "endpoint_hello",
    "error",
    "forget_endpoint",
    "forget_endpoint_result",
    "future_probe",
    "heartbeat",
    "hello",
    "listening",
    "owner_status",
    "playback_complete",
    "release_brain",
    "response_end",
    "response_start",
    "settings_get",
    "settings_result",
    "settings_set",
    "settings_snapshot",
    "thinking",
    "trusted_endpoints",
    "trusted_endpoints_result",
    "utterance_audio",
    "utterance_end",
    "utterance_start",
}

REQUIRED_FIELDS = {
    "audio": {"seq", "env", "viseme", "duration_ms"},
    "audio_stream_end": {"seq", "audio_bytes", "chunks"},
    "audio_stream_start": {"seq", "format", "sample_rate", "audio_bytes", "chunk_bytes", "chunks"},
    "cancel": {"seq", "reason"},
    "capability_update": {"endpoint_id", "capabilities"},
    "claim_brain": {"endpoint_id", "reason"},
    "diagnostics_request": {"domains"},
    "diagnostics_snapshot": {"bridge"},
    "endpoint_hello": {
        "protocol",
        "endpoint_id",
        "endpoint_name",
        "endpoint_kind",
        "app_version",
        "priority",
        "supports_binary_audio",
        "capabilities",
    },
    "error": {"code"},
    "forget_endpoint": {"endpoint_id"},
    "forget_endpoint_result": {"endpoint_id", "ok"},
    "heartbeat": set(),
    "hello": {"protocol"},
    "listening": set(),
    "owner_status": {"active_brain_owner", "owner_kind", "state"},
    "playback_complete": {"seq", "at_ms"},
    "release_brain": {"endpoint_id", "reason"},
    "response_end": {"seq"},
    "response_start": {"seq", "intent", "text"},
    "settings_get": {"domains"},
    "settings_result": {"ok", "version"},
    "settings_set": {"version", "settings"},
    "settings_snapshot": {"version", "settings"},
    "thinking": {"seq"},
    "trusted_endpoints": set(),
    "trusted_endpoints_result": {"endpoints"},
    "utterance_audio": {"seq", "pcm_b64"},
    "utterance_end": {"seq"},
    "utterance_start": {"seq", "sample_rate"},
}


def walk_keys(value: Any):
    if isinstance(value, dict):
        for key, child in value.items():
            yield key
            yield from walk_keys(child)
    elif isinstance(value, list):
        for child in value:
            yield from walk_keys(child)


def assert_lower_snake_keys(test_case: unittest.TestCase, document: dict[str, Any]) -> None:
    for key in walk_keys(document):
        test_case.assertRegex(key, r"^[a-z][a-z0-9_]*$", key)


def validate_protocol_document(document: dict[str, Any]) -> None:
    message_type = document.get("type")
    if not isinstance(message_type, str) or not message_type:
        raise ValueError("protocol fixture is missing a string type")
    if message_type not in KNOWN_TYPES:
        raise ValueError(f"unknown protocol fixture type: {message_type}")
    if not re.fullmatch(r"[a-z][a-z0-9_]*", message_type):
        raise ValueError(f"message type is not lower_snake_case: {message_type}")

    for key in walk_keys(document):
        if not re.fullmatch(r"[a-z][a-z0-9_]*", key):
            raise ValueError(f"field is not lower_snake_case: {key}")

    if "protocol" in document and document["protocol"] != PROTOCOL:
        raise ValueError(f"unsupported protocol: {document['protocol']}")

    missing = REQUIRED_FIELDS.get(message_type, set()) - set(document)
    if missing:
        raise ValueError(f"{message_type} missing required fields: {sorted(missing)}")


class ProtocolFixtureTests(unittest.TestCase):
    def test_committed_fixtures_match_deterministic_exporter(self):
        for relative_path, document in all_documents().items():
            path = FIXTURE_DIR / relative_path
            self.assertTrue(path.exists(), f"missing fixture {relative_path}")
            self.assertEqual(render_document(document), path.read_text(encoding="utf-8"), relative_path)

    def test_valid_fixtures_are_parseable_control_messages(self):
        for relative_path in fixture_documents():
            with self.subTest(relative_path=relative_path):
                document = json.loads((FIXTURE_DIR / relative_path).read_text(encoding="utf-8"))
                assert_lower_snake_keys(self, document)
                validate_protocol_document(document)

    def test_invalid_fixtures_are_rejected(self):
        for relative_path in invalid_fixture_documents():
            with self.subTest(relative_path=relative_path):
                document = json.loads((FIXTURE_DIR / relative_path).read_text(encoding="utf-8"))
                with self.assertRaises(ValueError):
                    validate_protocol_document(document)

    def test_fixture_directory_has_no_untracked_json_contract_files(self):
        expected = set(all_documents())
        actual = {
            str(path.relative_to(FIXTURE_DIR)).replace("\\", "/")
            for path in FIXTURE_DIR.rglob("*.json")
        }
        self.assertEqual(expected, actual)


if __name__ == "__main__":
    unittest.main()
