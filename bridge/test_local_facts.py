import json
import unittest
from datetime import datetime, timedelta, timezone

from bridge_memory import BridgeMemory
from local_facts import resolve_local_fact


class LocalFactTests(unittest.TestCase):
    def setUp(self):
        self.now = datetime(2026, 7, 12, 14, 5, tzinfo=timezone(timedelta(hours=-4), name="EDT"))

    def test_local_clock_answers_time_date_and_timezone_without_model_inference(self):
        result = resolve_local_fact(
            "Hey Stackchan, what time is it, what is today's date, and what time zone are we in?",
            BridgeMemory(),
            now=self.now,
        )

        self.assertIsNotNone(result)
        self.assertEqual("local_clock", result.tool)
        response = json.loads(result.character_response())
        self.assertIn("2:05 PM", response["spoken_text"])
        self.assertIn("Sunday, July 12, 2026", response["spoken_text"])
        self.assertIn("EDT", response["spoken_text"])
        self.assertEqual({}, response["memory_write"])

    def test_remote_city_time_is_not_misreported_as_local_time(self):
        self.assertIsNone(resolve_local_fact("What time is it in Tokyo?", BridgeMemory(), now=self.now))

    def test_memory_recall_answers_known_and_unknown_names(self):
        known = resolve_local_fact("Do you remember my name?", BridgeMemory(preferred_name="Rob"), now=self.now)
        unknown = resolve_local_fact("What is my name?", BridgeMemory(), now=self.now)

        self.assertEqual("memory_recall", known.tool)
        self.assertEqual("You asked me to call you Rob.", known.spoken_text)
        self.assertIn("do not know", unknown.spoken_text)


if __name__ == "__main__":
    unittest.main()
