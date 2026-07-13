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

    def test_remote_city_clock_queries_are_not_misreported_as_local_facts(self):
        phrases = (
            "What time is it in Tokyo?",
            "What day is it in Tokyo?",
            "What is the date in London?",
            "Can you tell me what time it is in Tokyo?",
            "Could you tell me what date it is in London?",
            "What is the time for the meeting?",
            "What's the date for the launch?",
        )

        for phrase in phrases:
            with self.subTest(phrase=phrase):
                self.assertIsNone(resolve_local_fact(phrase, BridgeMemory(), now=self.now))

    def test_unrelated_time_and_date_words_do_not_trigger_local_facts(self):
        phrases = (
            "I have a date tomorrow.",
            "Can you check the date format?",
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
            "Can you check the time?",
            "Can I get the time?",
            "Give me the time please.",
            "Time please.",
            "Like, what's the time?",
            "Okay Stackchan, whats the time?",
            "Hey Stack-chan, would you happen to know the time?",
            "Could I have the local time?",
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
            ("Can you check today's date?", "Sunday, July 12, 2026"),
            ("Can I get the current date?", "Sunday, July 12, 2026"),
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
            "What was my name?",
            "Remind me what my name was.",
            "What name did I give you?",
        )

        for phrase in phrases:
            with self.subTest(phrase=phrase):
                result = resolve_local_fact(phrase, BridgeMemory(preferred_name="Rob"), now=self.now)
                self.assertIsNotNone(result)
                self.assertEqual("memory_recall", result.tool)
                self.assertIn("Rob", result.spoken_text)

    def test_explicit_durable_facts_are_recalled_without_model_inference(self):
        memory = BridgeMemory().remember_user_text("Remember that my favorite color is teal.")
        memory = memory.remember_user_text("Remember the project codename is Johnny Alive.")

        user_fact = resolve_local_fact("What is my favorite color?", memory, now=self.now)
        project_fact = resolve_local_fact("Do you remember the project codename?", memory, now=self.now)

        self.assertEqual("memory_recall", user_fact.tool)
        self.assertEqual("You told me your favorite color is teal.", user_fact.spoken_text)
        self.assertEqual("memory_recall", project_fact.tool)
        self.assertIn("Johnny Alive", project_fact.spoken_text)

    def test_natural_durable_fact_recall_variants_bypass_model_inference(self):
        memory = BridgeMemory().remember_user_text("Remember that my favorite color is teal.")
        memory = memory.remember_user_text("Remember the project codename is Johnny Alive.")
        cases = (
            ("What was my favorite color?", "teal"),
            ("Do you remember what my favorite color was?", "teal"),
            ("What do you remember about my favorite color?", "teal"),
            ("Remind me what my favorite color is.", "teal"),
            ("What is my favorite color again?", "teal"),
            ("What do you remember about the project codename?", "Johnny Alive"),
            ("Remind me what the project's codename was.", "Johnny Alive"),
            ("Okay Stackchan, could you remind me what my favorite color is?", "teal"),
            ("Do you know what my favorite color is?", "teal"),
            ("Hey Stack-chan, can you tell me what the project codename is?", "Johnny Alive"),
        )

        for phrase, expected in cases:
            with self.subTest(phrase=phrase):
                result = resolve_local_fact(phrase, memory, now=self.now)
                self.assertIsNotNone(result)
                self.assertEqual("memory_recall", result.tool)
                self.assertIn(expected, result.spoken_text)

    def test_unknown_generic_personal_question_still_reaches_the_model(self):
        self.assertIsNone(resolve_local_fact("What is my plan for tomorrow?", BridgeMemory(), now=self.now))

    def test_explicit_unknown_recall_is_honest_and_deterministic(self):
        result = resolve_local_fact("Do you remember my favorite color?", BridgeMemory(), now=self.now)

        self.assertEqual("memory_recall", result.tool)
        self.assertIn("do not remember", result.spoken_text)


if __name__ == "__main__":
    unittest.main()
