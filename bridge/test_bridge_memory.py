import json
import os
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

from bridge_memory import (
    LEGACY_MEMORY_SCHEMA,
    LEGACY_MEMORY_SCHEMA_VERSION,
    MAX_DURABLE_FACTS,
    MAX_MEMORY_ITEMS,
    MAX_PROMPT_FACTS,
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
        memory = BridgeMemory().remember_user_text("My name is Rob.").apply_character_memory(
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
        self.assertEqual(
            {"user.preferred_name", "project.note"},
            {item["key"] for item in data["durable_facts"]},
        )
        self.assertEqual([], data["recent_context"])
        self.assertEqual((), memory.physical_context)
        for item in data["durable_facts"]:
            self.assertIn("created_at", item)
            self.assertIn("updated_at", item)
            self.assertIn("last_used_at", item)
            self.assertIn("importance", item)
            self.assertIn("expires_at", item)
        self.assertIsNone(data["durable_facts"][0]["expires_at"])

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
        self.assertEqual((), memory.physical_context)
        self.assertEqual(3, memory.turns_seen)
        self.assertEqual(["voice"], data["recent_topics"])
        self.assertTrue(any(item["key"] == "user.preferred_name" for item in data["durable_facts"]))
        self.assertEqual(
            {"project.topic"},
            {item["key"] for item in data["recent_context"]},
        )

    def test_flat_schema_rejects_observed_corruption_shapes(self):
        corrupted = {
            "preferred_name": "happy",
            "recent_topics": ["voice", ["bridge"]],
            "physical_context": [["Greeting was successfully processed."], "['greeting']", "low_battery", "1"],
            "turns_seen": 113,
        }

        memory = BridgeMemory.from_dict(corrupted)

        self.assertEqual("", memory.preferred_name)
        self.assertEqual(("voice",), memory.recent_topics)
        self.assertEqual((), memory.physical_context)
        self.assertNotIn("['", json.dumps(memory.to_dict()))

    def test_v2_migration_preserves_user_and_project_but_drops_untrusted_robot_state(self):
        legacy = {
            "schema": LEGACY_MEMORY_SCHEMA,
            "schema_version": LEGACY_MEMORY_SCHEMA_VERSION,
            "durable_facts": [
                self.record("user.preferred_name", "Rob"),
                self.record("project.note", "servo bracket"),
            ],
            "recent_context": [
                self.record("project.topic", "voice", expires_at="2999-01-01T00:00:00Z"),
                self.record("robot.status", "low battery", expires_at="2999-01-01T00:00:00Z"),
            ],
            "turns_seen": 7,
        }

        memory = BridgeMemory.from_dict(legacy)
        saved = memory.to_dict()

        self.assertEqual("Rob", memory.preferred_name)
        self.assertEqual(("servo bracket", "voice"), memory.recent_topics)
        self.assertEqual((), memory.physical_context)
        self.assertNotIn("low battery", json.dumps(saved))
        self.assertEqual(MEMORY_SCHEMA, saved["schema"])
        self.assertEqual(MEMORY_SCHEMA_VERSION, saved["schema_version"])

    def test_only_explicit_user_language_establishes_preferred_name(self):
        memory = BridgeMemory().remember_user_text("I'm happy you're my friend.")
        memory = memory.apply_character_memory(
            {"memory_write": {"user.name": "happy"}, "memory_forget": []}
        )
        self.assertEqual("", memory.preferred_name)

        memory = memory.remember_user_text("You can call me Rob.")
        memory = memory.apply_character_memory(
            {"memory_write": {"user.name": "Rob"}, "memory_forget": []}
        )
        self.assertEqual("Rob", memory.preferred_name)

        replaced = memory.apply_character_memory(
            {"memory_write": {"user.name": "Alice"}, "memory_forget": []}
        )
        self.assertEqual("Rob", replaced.preferred_name)

    def test_explicit_user_and_project_facts_are_captured_without_model_cooperation(self):
        memory = BridgeMemory().remember_user_text("Remember that my favorite color is teal.")
        memory = memory.remember_user_text("Please remember the project codename is Johnny Alive.")

        self.assertEqual("teal", memory.fact_value("user.favorite_color"))
        self.assertEqual("Johnny Alive", memory.fact_value("project.codename"))
        saved = memory.to_dict()
        self.assertEqual(
            {"user.favorite_color", "project.codename"},
            {item["key"] for item in saved["durable_facts"]},
        )

    def test_explicit_fact_capture_still_rejects_sensitive_or_ambiguous_memory(self):
        memory = BridgeMemory().remember_user_text("Remember that my password is swordfish.")
        memory = memory.remember_user_text("Remember that my thing is vague.")

        self.assertEqual("", memory.fact_value("user.password"))
        self.assertEqual("", memory.fact_value("user.thing"))
        self.assertEqual([], memory.to_dict()["durable_facts"])

    def test_explicit_forget_is_transcript_owned_and_immediate(self):
        memory = BridgeMemory().remember_user_text("My name is Rob.")
        memory = memory.remember_user_text("Remember that my favorite color is teal.")
        memory = memory.remember_user_text("Remember the project codename is Johnny Alive.")

        memory = memory.remember_user_text("Please forget my favorite color.")
        self.assertEqual("", memory.fact_value("user.favorite_color"))
        self.assertEqual("Rob", memory.preferred_name)
        self.assertEqual("Johnny Alive", memory.fact_value("project.codename"))

        memory = memory.remember_user_text("Forget everything you remember about me.")
        self.assertEqual("", memory.preferred_name)
        self.assertEqual("Johnny Alive", memory.fact_value("project.codename"))

        memory = memory.remember_user_text("Forget everything.")
        self.assertEqual(BridgeMemory(), memory)

    def test_wake_addressed_memory_commands_remain_transcript_owned(self):
        memory = BridgeMemory().remember_user_text(
            "Okay Stackchan, remember that my favorite color is teal."
        )
        memory = memory.remember_user_text(
            "Hey Stack-chan, remember the project’s codename is Johnny Alive."
        )

        self.assertEqual("teal", memory.fact_value("user.favorite_color"))
        self.assertEqual("Johnny Alive", memory.fact_value("project.codename"))

        memory = memory.remember_user_text("Like, Stackchan, please forget my favorite color.")
        self.assertEqual("", memory.fact_value("user.favorite_color"))
        self.assertEqual("Johnny Alive", memory.fact_value("project.codename"))

    def test_user_text_and_character_output_cannot_invent_robot_state(self):
        memory = BridgeMemory().remember_user_text(
            "I picked you up, touched you, and think your battery is low."
        )
        memory = memory.apply_character_memory(
            {"memory_write": {"robot.status": "low battery"}, "memory_forget": []}
        )

        self.assertEqual((), memory.physical_context)
        self.assertFalse(any(item["key"].startswith("robot.") for item in memory.to_dict()["recent_context"]))

    def test_trusted_runtime_override_can_add_bounded_robot_context(self):
        memory = BridgeMemory().with_overrides(physical_context=("user picked Stackchan up",))

        self.assertEqual(("user picked Stackchan up",), memory.physical_context)
        self.assertEqual(
            ["robot.physical_context"],
            [item["key"] for item in memory.to_dict()["recent_context"]],
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

    def test_prompt_context_ranks_query_matching_facts_inside_the_bound(self):
        memory = BridgeMemory()
        for index in range(12):
            memory = memory.apply_character_memory(
                {"memory_write": {f"project.fact_{index}": f"unrelated note {index}"}}
            )
        memory = memory.apply_character_memory(
            {"memory_write": {"project.servo_bracket_color": "the servo bracket is teal"}}
        )

        lines = memory.context_lines("What color is the servo bracket?")
        facts = [line for line in lines if line.startswith("approved_fact ")]

        self.assertLessEqual(len(facts), 8)
        self.assertTrue(any("servo_bracket_color" in line and "teal" in line for line in facts))

    def test_prompt_context_can_select_relevant_recent_context_over_durable_fill(self):
        memory = BridgeMemory()
        for index in range(MAX_PROMPT_FACTS + 2):
            memory = memory.apply_character_memory(
                {"memory_write": {f"project.fact_{index}": f"unrelated durable note {index}"}}
            )
        memory = memory.with_overrides(
            physical_context=("beside the blue launch notebook",)
        )

        lines = memory.context_lines("Where are you beside the blue launch notebook?")

        self.assertTrue(
            any("beside the blue launch notebook" in line for line in lines),
            lines,
        )

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
                    "user.generic_contact": "555-123-4567",
                    "user.generic_email": "rob@example.com",
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
            "555-123-4567",
            "rob@example.com",
            "jen's private note",
            "raw_audio",
            "raw audio",
            "transcript",
            "verbatim session",
        ):
            self.assertNotIn(forbidden, encoded)

    def test_forget_removes_matching_namespaces_and_wins_over_writes(self):
        memory = BridgeMemory().remember_user_text("My name is Rob.").apply_character_memory(
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
        self.assertEqual((), memory.physical_context)
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
