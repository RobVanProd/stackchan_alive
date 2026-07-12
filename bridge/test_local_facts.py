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

    def test_unrelated_time_and_date_words_do_not_trigger_local_facts(self):
        phrases = (
            "I have a date tomorrow.",
            "Which time zone setting should I use?",
            "The movie starts at what time?",
        )

        for phrase in phrases:
            with self.subTest(phrase=phrase):
                self.assertIsNone(resolve_local_fact(phrase, BridgeMemory(), now=self.now))

    def test_natural_clock_phrasings_bypass_the_model(self):
        phrases = (
            "Do you have the time?",
            "Can you tell me what time it is?",
            "Could you tell me the current time?",
            "What time do you have?",
            "Current time please.",
        )

        for phrase in phrases:
            with self.subTest(phrase=phrase):
                result = resolve_local_fact(phrase, BridgeMemory(), now=self.now)
                self.assertIsNotNone(result)
                self.assertEqual("local_clock", result.tool)
                self.assertIn("2:05 PM", result.spoken_text)

    def test_natural_date_and_timezone_phrasings_bypass_the_model(self):
        cases = (
            ("Can you tell me what day it is?", "Sunday, July 12, 2026"),
            ("Current date please.", "Sunday, July 12, 2026"),
            ("What time zone is this?", "EDT"),
            ("Could you tell me our timezone?", "EDT"),
        )

        for phrase, expected in cases:
            with self.subTest(phrase=phrase):
                result = resolve_local_fact(phrase, BridgeMemory(), now=self.now)
                self.assertIsNotNone(result)
                self.assertEqual("local_clock", result.tool)
                self.assertIn(expected, result.spoken_text)

    def test_memory_recall_answers_known_and_unknown_names(self):
        known = resolve_local_fact("Do you remember my name?", BridgeMemory(preferred_name="Rob"), now=self.now)
        unknown = resolve_local_fact("What is my name?", BridgeMemory(), now=self.now)

        self.assertEqual("memory_recall", known.tool)
        self.assertEqual("You asked me to call you Rob.", known.spoken_text)
        self.assertIn("do not know", unknown.spoken_text)

    def test_natural_name_recall_phrasings_bypass_the_model(self):
        phrases = (
            "Can you remember my name?",
            "Do you remember who I am?",
            "Tell me my name.",
            "Could you tell me who I am?",
        )

        for phrase in phrases:
            with self.subTest(phrase=phrase):
                result = resolve_local_fact(phrase, BridgeMemory(preferred_name="Rob"), now=self.now)
                self.assertIsNotNone(result)
                self.assertEqual("memory_recall", result.tool)
                self.assertIn("Rob", result.spoken_text)


if __name__ == "__main__":
    unittest.main()
