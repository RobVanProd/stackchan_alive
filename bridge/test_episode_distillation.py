import json
import unittest
from unittest.mock import patch

from bridge_memory import BridgeMemory
from episode_distillation import (
    DISTILLATION_SCHEMA,
    _local_generate_url,
    apply_distillation,
    distillation_prompt,
    distillation_turns_safe,
    request_distillation,
    validate_distillation,
)


class FakeResponse:
    def __init__(self, payload):
        self.payload = payload

    def __enter__(self):
        return self

    def __exit__(self, exc_type, exc, traceback):
        return False

    def read(self):
        return json.dumps(self.payload).encode("utf-8")


class EpisodeDistillationTests(unittest.TestCase):
    def test_valid_result_applies_one_episode(self):
        raw = json.dumps(
            {
                "episode": "Talked about tuning the servo bracket",
            }
        )
        result = validate_distillation(raw)
        self.assertIsNotNone(result)
        memory = apply_distillation(BridgeMemory(), result, now="2026-07-15T12:00:00Z")
        self.assertEqual(1, memory.episode_count)
        self.assertEqual(0, memory.open_loop_count)

    def test_invalid_or_private_result_drops_whole_payload(self):
        fixtures = (
            "not-json",
            [],
            {"episode": "valid", "extra": True},
            {"episode": "x" * 121},
            {"episode": 4},
            {"episode": "Talked about medical treatment"},
            {"episode": "Talked about my home address"},
            {"episode": "Met at 123 Main Street"},
            {"episode": "Alice's apartment was discussed"},
            {"episode": "Talked about servos", "open_loop": None},
        )
        memory = BridgeMemory()
        for fixture in fixtures:
            self.assertIsNone(validate_distillation(fixture))
            memory = memory.note_distill_drop()
        self.assertEqual(len(fixtures), memory.distill_dropped)
        self.assertEqual(0, memory.episode_count)
        self.assertEqual(0, memory.open_loop_count)

    def test_private_or_web_tainted_turns_never_reach_distillation(self):
        self.assertTrue(
            distillation_turns_safe((("We tuned the servo", "It is stable"),))
        )
        for turns in (
            (("My address is 123 Main Street", "Understood"),),
            (("Alice's apartment is nearby", "Understood"),),
            (("Check https://example.com", "I found it"),),
            (("Remember my diagnosis", "I cannot store that"),),
        ):
            with self.subTest(turns=turns):
                self.assertFalse(distillation_turns_safe(turns))

    def test_prompt_covers_the_full_bounded_session(self):
        turns = [(f"question {index}", f"answer {index}") for index in range(24)]
        prompt = distillation_prompt(turns)
        self.assertIn("question 0", prompt)
        self.assertIn("question 23", prompt)
        self.assertEqual(24, prompt.count(" user:"))
        self.assertLess(len(prompt), 12_000)

    def test_prompt_drops_only_turns_beyond_the_session_bound(self):
        turns = [(f"question {index}", f"answer {index}") for index in range(26)]
        prompt = distillation_prompt(turns)
        user_values = [
            line.partition(" user: ")[2]
            for line in prompt.splitlines()
            if " user: " in line
        ]
        self.assertNotIn("question 0", user_values)
        self.assertNotIn("question 1", user_values)
        self.assertEqual("question 2", user_values[0])
        self.assertEqual("question 25", user_values[-1])

    def test_request_uses_loopback_and_exact_episode_schema(self):
        response = {"response": '{"episode":"Talked about Rhea"}'}
        with patch(
            "episode_distillation.urllib.request.urlopen",
            return_value=FakeResponse(response),
        ) as urlopen:
            raw = request_distillation(
                (("question", "answer"),),
                model="gemma4:test",
                endpoint="http://127.0.0.1:11434",
            )

        request = urlopen.call_args.args[0]
        payload = json.loads(request.data.decode("utf-8"))
        self.assertEqual('{"episode":"Talked about Rhea"}', raw)
        self.assertEqual("gemma4:test", payload["model"])
        self.assertEqual(DISTILLATION_SCHEMA, payload["format"])
        self.assertNotIn("open_loop", payload["prompt"])
        self.assertEqual("http://127.0.0.1:11434/api/generate", request.full_url)

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
