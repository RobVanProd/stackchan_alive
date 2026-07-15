import json
import unittest

from bridge_memory import BridgeMemory
from episode_distillation import (
    _local_generate_url,
    apply_distillation,
    distillation_prompt,
    validate_distillation,
)


class EpisodeDistillationTests(unittest.TestCase):
    def test_valid_result_applies_both_records(self):
        raw = json.dumps(
            {
                "episode": "Talked about tuning the servo bracket",
                "open_loop": {"text": "I have a bracket demo tomorrow", "days_until_due": 2},
            }
        )
        result = validate_distillation(raw)
        self.assertIsNotNone(result)
        memory = apply_distillation(BridgeMemory(), result, now="2026-07-15T12:00:00Z")
        self.assertEqual(1, memory.episode_count)
        self.assertEqual(1, memory.open_loop_count)

    def test_invalid_or_private_result_drops_whole_payload(self):
        fixtures = (
            "not-json",
            [],
            {"episode": "valid", "open_loop": None, "extra": True},
            {"episode": "x" * 121, "open_loop": None},
            {"episode": 4, "open_loop": None},
            {"episode": "Talked about servos", "open_loop": {"text": "demo", "days_until_due": 0}},
            {"episode": "Talked about servos", "open_loop": {"text": "demo", "days_until_due": True}},
            {"episode": "Talked about medical treatment", "open_loop": None},
            {
                "episode": "Talked about servos",
                "open_loop": {"text": "I have therapy tomorrow", "days_until_due": 1},
            },
        )
        memory = BridgeMemory()
        for fixture in fixtures:
            self.assertIsNone(validate_distillation(fixture))
            memory = memory.note_distill_drop()
        self.assertEqual(len(fixtures), memory.distill_dropped)
        self.assertEqual(0, memory.episode_count)
        self.assertEqual(0, memory.open_loop_count)

    def test_prompt_is_bounded_to_four_turns(self):
        turns = [(f"question {index}", f"answer {index}") for index in range(6)]
        prompt = distillation_prompt(turns)
        self.assertNotIn("question 0", prompt)
        self.assertNotIn("question 1", prompt)
        self.assertIn("question 5", prompt)
        self.assertEqual(4, prompt.count(" user:"))

    def test_distillation_endpoint_is_loopback_only(self):
        self.assertEqual(
            "http://127.0.0.1:11434/api/generate",
            _local_generate_url("http://127.0.0.1:11434"),
        )
        self.assertEqual(
            "http://[::1]:11434/api/generate",
            _local_generate_url("http://[::1]:11434/api/generate"),
        )
        for endpoint in (
            "https://127.0.0.1:11434/api/generate",
            "http://192.168.1.2:11434",
            "http://example.com:11434",
            "http://user:pass@127.0.0.1:11434",
        ):
            with self.subTest(endpoint=endpoint):
                with self.assertRaises(ValueError):
                    _local_generate_url(endpoint)


if __name__ == "__main__":
    unittest.main()
