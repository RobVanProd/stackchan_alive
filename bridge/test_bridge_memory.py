import json
import os
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

from bridge_memory import (
    MAX_DURABLE_FACTS,
    MAX_MEMORY_ITEMS,
    MAX_RECENT_CONTEXT,
    MEMORY_SCHEMA,
    MEMORY_SCHEMA_VERSION,
)
from reference_bridge import BridgeMemory, load_bridge_memory, save_bridge_memory


class BridgeMemoryStoreTests(unittest.TestCase):
    @staticmethod
    def record(key: str, value: str, *, expires_at: str | None = None) -> dict[str, object]:
        return {
            "key": key,
            "value": value,
            "created_at": "2026-01-01T00:00:00Z",
            "updated_at": "2026-01-02T00:00:00Z",
            "last_used_at": "2026-01-03T00:00:00Z",
            "importance": 0.6,
            "expires_at": expires_at,
        }

    def test_versioned_schema_separates_durable_facts_from_recent_context(self):
        memory = BridgeMemory().apply_character_memory(
            {
                "memory_write": {
                    "user.name": "Rob",
                    "project.note": "servo bracket",
                    "robot.physical_context": "room is dark",
                },
                "memory_forget": [],
            }
        )

        data = memory.to_dict()

        self.assertEqual(MEMORY_SCHEMA, data["schema"])
        self.assertEqual(MEMORY_SCHEMA_VERSION, data["schema_version"])
        self.assertEqual({"user.name", "project.note"}, {item["key"] for item in data["durable_facts"]})
        self.assertEqual(["robot.physical_context"], [item["key"] for item in data["recent_context"]])
        for item in (*data["durable_facts"], *data["recent_context"]):
            self.assertIn("created_at", item)
            self.assertIn("updated_at", item)
            self.assertIn("last_used_at", item)
            self.assertIn("importance", item)
            self.assertIn("expires_at", item)
        self.assertIsNone(data["durable_facts"][0]["expires_at"])
        self.assertIsNotNone(data["recent_context"][0]["expires_at"])

    def test_flat_schema_migrates_without_losing_public_fields(self):
        legacy = {
            "preferred_name": "Rob",
            "recent_topics": ["voice"],
            "physical_context": ["room is dark"],
            "turns_seen": 3,
        }

        memory = BridgeMemory.from_dict(legacy)
        data = memory.to_dict()

        self.assertEqual("Rob", memory.preferred_name)
        self.assertEqual(("voice",), memory.recent_topics)
        self.assertEqual(("room is dark",), memory.physical_context)
        self.assertEqual(3, memory.turns_seen)
        self.assertEqual(["voice"], data["recent_topics"])
        self.assertTrue(any(item["key"] == "user.preferred_name" for item in data["durable_facts"]))
        self.assertEqual(
            {"project.topic", "robot.physical_context"},
            {item["key"] for item in data["recent_context"]},
        )

    def test_expired_records_are_pruned_on_load(self):
        data = {
            "schema": MEMORY_SCHEMA,
            "schema_version": MEMORY_SCHEMA_VERSION,
            "durable_facts": [
                self.record("user.preferred_name", "Rob"),
                self.record("project.old", "old bracket", expires_at="2001-01-01T00:00:00Z"),
            ],
            "recent_context": [
                self.record("project.topic", "stale topic", expires_at="2001-01-01T00:00:00Z"),
                self.record("robot.physical_context", "room is dark", expires_at="2999-01-01T00:00:00Z"),
            ],
            "preferred_name": "stale projection",
            "recent_topics": ["stale topic"],
            "physical_context": ["room is dark"],
            "turns_seen": 4,
        }

        memory = BridgeMemory.from_dict(data)
        saved = memory.to_dict()

        self.assertEqual("Rob", memory.preferred_name)
        self.assertEqual((), memory.recent_topics)
        self.assertEqual(("room is dark",), memory.physical_context)
        self.assertNotIn("old bracket", json.dumps(saved))
        self.assertNotIn("stale topic", json.dumps(saved))

    def test_schema_is_bounded_on_load_and_save(self):
        data = {
            "schema": MEMORY_SCHEMA,
            "schema_version": MEMORY_SCHEMA_VERSION,
            "durable_facts": [self.record(f"project.fact_{index}", f"fact {index}") for index in range(40)],
            "recent_context": [
                self.record(
                    "project.topic" if index % 2 == 0 else "robot.physical_context",
                    f"context {index}",
                    expires_at="2999-01-01T00:00:00Z",
                )
                for index in range(30)
            ],
            "turns_seen": 2,
        }

        memory = BridgeMemory.from_dict(data)
        saved = memory.to_dict()

        self.assertLessEqual(len(saved["durable_facts"]), MAX_DURABLE_FACTS)
        self.assertLessEqual(len(saved["recent_context"]), MAX_RECENT_CONTEXT)
        self.assertLessEqual(len(memory.recent_topics), MAX_MEMORY_ITEMS)
        self.assertLessEqual(len(memory.physical_context), MAX_MEMORY_ITEMS)

    def test_privacy_policy_rejects_sensitive_and_raw_content(self):
        memory = BridgeMemory().remember_user_text(
            "Please store the raw audio transcript while we tune the voice."
        )
        memory = memory.apply_character_memory(
            {
                "memory_write": {
                    "user.password": "swordfish",
                    "user.note": "sk-test-123",
                    "user.health": "asthma treatment",
                    "project.finance": "bank details",
                    "user.relationship": "romantic partner notes",
                    "user.contact": "Alice's phone number",
                    "user.other_contact": "Jen's private note",
                    "robot.raw_audio": "room recording",
                    "project.transcript": "verbatim session",
                    "project.note": "servo bracket",
                },
                "memory_forget": [],
            }
        )

        encoded = json.dumps(memory.to_dict()).lower()

        self.assertIn("servo bracket", encoded)
        self.assertIn("voice", encoded)
        for forbidden in (
            "swordfish",
            "sk-test-123",
            "asthma",
            "bank details",
            "romantic partner",
            "alice",
            "jen's private note",
            "raw_audio",
            "raw audio",
            "transcript",
            "verbatim session",
        ):
            self.assertNotIn(forbidden, encoded)

    def test_forget_removes_matching_namespaces_and_wins_over_writes(self):
        memory = BridgeMemory().apply_character_memory(
            {
                "memory_write": {
                    "user.name": "Rob",
                    "project.note": "servo bracket",
                    "robot.status": "low battery",
                },
                "memory_forget": ["project.note"],
            }
        )

        self.assertEqual("Rob", memory.preferred_name)
        self.assertEqual((), memory.recent_topics)
        self.assertEqual(("low battery",), memory.physical_context)
        self.assertFalse(any(item["key"].startswith("project.") for item in memory.to_dict()["durable_facts"]))
        self.assertEqual(BridgeMemory(), memory.apply_character_memory({"memory_forget": ["*"]}))

    def test_save_uses_atomic_replace_and_leaves_valid_json(self):
        with tempfile.TemporaryDirectory() as temp_dir:
            path = Path(temp_dir) / "nested" / "memory.json"
            with patch("bridge_memory.os.replace", wraps=os.replace) as atomic_replace:
                save_bridge_memory(path, BridgeMemory(preferred_name="Rob"))

            atomic_replace.assert_called_once()
            source, destination = atomic_replace.call_args.args
            self.assertEqual(path, destination)
            self.assertEqual(path.parent, Path(source).parent)
            self.assertEqual("Rob", load_bridge_memory(path).preferred_name)
            self.assertEqual([], list(path.parent.glob(f".{path.name}.*.tmp")))


if __name__ == "__main__":
    unittest.main()
