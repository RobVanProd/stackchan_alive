import unittest
from unittest.mock import patch

import bridge_memory
from bridge_memory import (
    LEGACY_V3_MEMORY_SCHEMA,
    LEGACY_V3_MEMORY_SCHEMA_VERSION,
    MAX_EPISODES,
    MAX_OPEN_LOOPS,
    MEMORY_BLOCK_MAX_CHARS,
    BridgeMemory,
    captured_open_loop,
    due_at_for_phrase,
)


NOW = "2026-07-15T12:00:00Z"


def fact(key: str, value: str) -> dict[str, object]:
    return {
        "key": key,
        "value": value,
        "created_at": "2026-07-10T12:00:00Z",
        "updated_at": "2026-07-10T12:00:00Z",
        "last_used_at": "2026-07-10T12:00:00Z",
        "importance": 0.7,
        "expires_at": None,
    }


class BridgeMemoryV4Tests(unittest.TestCase):
    def test_v3_migration_is_lossless_and_idempotent(self):
        data = {
            "schema": LEGACY_V3_MEMORY_SCHEMA,
            "schema_version": LEGACY_V3_MEMORY_SCHEMA_VERSION,
            "durable_facts": [fact("user.preferred_name", "Rob"), fact("project.color", "blue")],
            "recent_context": [fact("project.topic", "servos")],
            "preferred_name": "Rob",
            "recent_topics": ["servos"],
            "physical_context": [],
            "turns_seen": 8,
            "capture_rejections": 99,
            "distill_dropped": 99,
            "durable_evictions": 99,
        }
        migrated = BridgeMemory.from_dict(data)
        encoded = migrated.to_dict()

        self.assertEqual("stackchan.bridge-memory.v4", encoded["schema"])
        self.assertEqual(2, len(encoded["durable_facts"]))
        self.assertEqual(1, len(encoded["recent_context"]))
        self.assertEqual([], encoded["episodes"])
        self.assertEqual([], encoded["open_loops"])
        self.assertEqual(0, encoded["capture_rejections"])
        self.assertEqual(0, encoded["distill_dropped"])
        self.assertEqual(0, encoded["durable_evictions"])
        self.assertEqual(encoded, BridgeMemory.from_dict(encoded).to_dict() | {"updated_at": encoded["updated_at"]})

    def test_episode_dedup_refresh_and_deterministic_prune(self):
        memory = BridgeMemory().add_episode(
            "Talked about servo tuning and bracket alignment",
            importance=0.4,
            now="2026-07-01T00:00:00Z",
        )
        memory = memory.add_episode(
            "Servo bracket alignment and tuning discussion",
            importance=0.8,
            now="2026-07-02T00:00:00Z",
        )
        self.assertEqual(1, memory.episode_count)
        episode = memory.to_dict()["episodes"][0]
        self.assertEqual(0.8, episode["importance"])
        self.assertEqual("2026-07-02T00:00:00Z", episode["last_used_at"])

        for index in range(MAX_EPISODES + 2):
            code = f"code{chr(97 + index // 26)}{chr(97 + index % 26)}"
            memory = memory.add_episode(
                f"Workshop {code}",
                importance=0.1 if index < 2 else 0.9,
                now=f"2026-06-{index + 1:02d}T00:00:00Z" if index < 29 else f"2026-07-{index - 28:02d}T00:00:00Z",
            )
        self.assertEqual(MAX_EPISODES, memory.episode_count)
        texts = {item["text"] for item in memory.to_dict()["episodes"]}
        self.assertNotIn("Workshop codeaa", texts)

    def test_open_loop_capture_fixture_has_zero_false_captures(self):
        positives = (
            "I have a demo tomorrow.",
            "I'm going to finish the print tonight.",
            "I'll present the prototype next week.",
            "We're testing servos on Friday.",
            "I have calibration on Monday.",
            "I'm going to tune the speaker this weekend.",
            "I'll run the benchmark tomorrow.",
            "We're assembling brackets on Tuesday.",
            "I have a workshop next week.",
            "I'll check the battery tonight.",
        )
        negatives = (
            "I don't have anything tomorrow.",
            "Do I have a demo tomorrow?",
            "She has a demo tomorrow.",
            "Rob will test the servos next week.",
            "I tested the servos yesterday.",
            "I'll tune the speaker eventually.",
            "What will I do tomorrow?",
            "I won't run the benchmark tomorrow.",
            "We're not going to test tonight.",
            "The print finishes tonight.",
            "Are we testing servos on Friday?",
            "I have nothing planned this weekend.",
        )
        captures = [captured_open_loop(text, now=NOW) is not None for text in positives]
        false_captures = [text for text in negatives if captured_open_loop(text, now=NOW) is not None]

        self.assertGreaterEqual(sum(captures), 6)
        self.assertEqual([], false_captures)

    def test_due_mapping_is_utc_deterministic(self):
        self.assertEqual("2026-07-16T12:00:00Z", due_at_for_phrase("tomorrow", now=NOW))
        self.assertEqual("2026-07-22T12:00:00Z", due_at_for_phrase("next week", now=NOW))
        self.assertEqual("2026-07-18T12:00:00Z", due_at_for_phrase("this weekend", now=NOW))
        self.assertEqual(
            "2026-07-18T12:00:00Z",
            due_at_for_phrase("this weekend", now="2026-07-18T12:00:00Z"),
        )
        self.assertEqual("2026-07-20T12:00:00Z", due_at_for_phrase("on Monday", now=NOW))

    def test_loop_expiry_asked_retention_and_cap(self):
        pending = {
            "text": "I have a demo tomorrow",
            "created_at": "2026-07-01T00:00:00Z",
            "due_at": "2026-07-02T00:00:00Z",
            "status": "pending",
            "asked_at": None,
        }
        asked_old = {
            "text": "I have a workshop next week",
            "created_at": "2026-06-01T00:00:00Z",
            "due_at": "2026-06-08T00:00:00Z",
            "status": "asked",
            "asked_at": "2026-06-10T00:00:00Z",
        }
        payload = {
            "schema": "stackchan.bridge-memory.v4",
            "schema_version": 4,
            "durable_facts": [],
            "recent_context": [],
            "episodes": [],
            "open_loops": [pending, asked_old],
        }
        with patch.object(bridge_memory, "_utc_now", return_value=NOW):
            loaded = BridgeMemory.from_dict(payload).to_dict()
        self.assertEqual(1, len(loaded["open_loops"]))
        self.assertEqual("expired", loaded["open_loops"][0]["status"])

        memory = BridgeMemory()
        for index in range(MAX_OPEN_LOOPS + 2):
            code = f"task{chr(97 + index // 26)}{chr(97 + index % 26)}"
            memory = memory.add_open_loop(
                f"I have {code} tomorrow",
                due_at="2026-07-16T12:00:00Z",
                now=f"2026-07-{index + 1:02d}T12:00:00Z",
            )
        self.assertEqual(MAX_OPEN_LOOPS, memory.open_loop_count)

    def test_new_record_types_apply_denylist_on_create_and_load(self):
        memory = BridgeMemory().add_episode("Talked about a doctor appointment", now=NOW)
        memory = memory.add_open_loop("I have a relationship meeting tomorrow", due_at=NOW, now=NOW)
        self.assertEqual(0, memory.episode_count)
        self.assertEqual(0, memory.open_loop_count)

        payload = memory.to_dict()
        payload["episodes"] = [{
            "text": "Talked about medical treatment",
            "created_at": NOW,
            "last_used_at": NOW,
            "use_count": 0,
            "importance": 0.5,
        }]
        payload["open_loops"] = [{
            "text": "I have therapy tomorrow",
            "created_at": NOW,
            "due_at": NOW,
            "status": "pending",
            "asked_at": None,
        }]
        loaded = BridgeMemory.from_dict(payload)
        self.assertEqual(0, loaded.episode_count)
        self.assertEqual(0, loaded.open_loop_count)

    def test_relationship_card_budget_and_one_shot_consumption(self):
        memory = BridgeMemory(preferred_name="Rob", turns_seen=99)
        for index in range(24):
            memory = memory.apply_character_memory(
                {"memory_write": {f"project.fixture_{index}": "x" * 90 + str(index)}, "memory_forget": []}
            )
        memory = memory.add_episode("Talked about servo tuning and voice calibration", now="2026-07-14T00:00:00Z")
        memory = memory.add_open_loop(
            "I have a servo calibration demo tomorrow",
            due_at="2026-07-14T00:00:00Z",
            now="2026-07-13T00:00:00Z",
        )
        card = memory.relationship_card("fixture", session_turns=1, now=NOW)

        self.assertLessEqual(len("\n".join(card.lines)), MEMORY_BLOCK_MAX_CHARS)
        self.assertTrue(card.open_loop_id)
        self.assertTrue(any(line.startswith("preferred_name:") for line in card.lines))
        consumed, did_consume = memory.consume_open_loop(
            card.open_loop_id,
            "How did that servo calibration go?",
            now=NOW,
        )
        self.assertTrue(did_consume)
        next_card = consumed.relationship_card("servo", session_turns=1, now=NOW)
        self.assertFalse(next_card.open_loop_id)

        excluded_card = memory.relationship_card(
            "servo",
            session_turns=2,
            excluded_open_loops=(card.open_loop_id,),
            now=NOW,
        )
        self.assertFalse(excluded_card.open_loop_id)

    def test_relationship_card_truncates_episode_before_callback_and_facts(self):
        memory = BridgeMemory(preferred_name="Fixture", turns_seen=99)
        for index in range(8):
            key = (f"project.fixture_{index}_" + "k" * 64)[:64]
            value = ("fixture " + f"{index} " + "v" * 96)[:96]
            memory = memory.apply_character_memory(
                {"memory_write": {key: value}, "memory_forget": []}
            )
        memory = memory.add_episode("Episode " + "e" * 112, now="2026-07-14T00:00:00Z")
        memory = memory.add_open_loop(
            "I have a fixture calibration demonstration tomorrow " + "q" * 44,
            due_at="2026-07-14T00:00:00Z",
            now="2026-07-13T00:00:00Z",
        )

        card = memory.relationship_card("fixture", session_turns=1, now=NOW)
        block = "\n".join(card.lines)

        self.assertLessEqual(len(block), MEMORY_BLOCK_MAX_CHARS)
        self.assertTrue(card.open_loop_id)
        self.assertEqual(8, sum(line.startswith("approved_fact ") for line in card.lines))
        self.assertFalse(any(line.startswith("episode: ") for line in card.lines))
        self.assertTrue(card.lines[-1].startswith("style:"))

    def test_durable_eviction_counter_is_instrumented(self):
        memory = BridgeMemory()
        for index in range(25):
            memory = memory.apply_character_memory(
                {"memory_write": {f"project.item_{index}": f"value {index}"}, "memory_forget": []}
            )
        self.assertEqual(1, memory.durable_evictions)
        self.assertEqual(1, memory.diagnostics()["memory_durable_evictions"])


if __name__ == "__main__":
    unittest.main()
