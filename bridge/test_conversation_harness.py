import unittest

from conversation_harness import (
    ConversationHarness,
    correction_value,
    explicit_weather_default_location,
    safe_coarse_location,
    weather_location_from_text,
    weather_result_matches,
)


def research(query: str) -> dict[str, object]:
    return {"name": "web_search", "arguments": {"query": query, "max_results": 4}}


class ConversationHarnessTests(unittest.TestCase):
    def set_weather(self, harness: ConversationHarness, text: str = "What is the weather in Boston?"):
        plan = harness.plan(text, research(text), "freshness_policy")
        harness.stage(plan)
        harness.commit()
        return plan

    def test_extracts_coarse_weather_places_without_precise_location(self):
        self.assertEqual("West Berlin", weather_location_from_text("Weather like in West Berlin?"))
        self.assertEqual("São Paulo", weather_location_from_text("weather in São Paulo tomorrow"))
        for unsafe in (
            "weather at 123 Main Street",
            "weather at 52.52, 13.40",
            "weather at my home",
            "weather here",
        ):
            with self.subTest(unsafe=unsafe):
                self.assertEqual("", weather_location_from_text(unsafe))

    def test_extracts_common_explicit_correction_forms(self):
        expected = {
            "no West Berlin": "West Berlin",
            "No, I meant West Berlin": "West Berlin",
            "I said West Berlin": "West Berlin",
            "West Berlin, not Boston": "West Berlin",
            "No, not Boston, West Berlin": "West Berlin",
        }
        for text, location in expected.items():
            with self.subTest(text=text):
                self.assertEqual(location, correction_value(text))
        self.assertEqual("", correction_value("No"))
        self.assertEqual("", correction_value("No, my home"))

    def test_repairs_only_the_location_and_rebuilds_standalone_query(self):
        harness = ConversationHarness()
        first = self.set_weather(harness)
        self.assertEqual("current weather in Boston", first.request["arguments"]["query"])

        correction = harness.plan("no West Berlin", None, "")
        self.assertEqual("correct", correction.turn_kind)
        self.assertEqual("repair", correction.operation)
        self.assertEqual(("location",), correction.changed_slots)
        self.assertEqual("current weather in West Berlin", correction.request["arguments"]["query"])
        self.assertEqual("contextual_repair", correction.routing)
        self.assertEqual(2, correction.next_state.revision)

    def test_temporal_followup_inherits_the_active_location(self):
        harness = ConversationHarness()
        self.set_weather(harness, "What is the weather in West Berlin today?")
        followup = harness.plan("what about tomorrow?", research("what about tomorrow?"), "freshness_policy")
        self.assertEqual("tomorrow weather in West Berlin", followup.request["arguments"]["query"])
        self.assertEqual(("time",), followup.changed_slots)
        self.assertEqual("contextual_followup", followup.routing)

    def test_locationless_weather_uses_only_an_approved_coarse_default(self):
        harness = ConversationHarness()
        plan = harness.plan(
            "What is the weather?",
            research("What is the weather?"),
            "freshness_policy",
            default_weather_location="West Berlin",
        )
        self.assertEqual("current weather in West Berlin", plan.request["arguments"]["query"])
        self.assertEqual("use_default", plan.operation)
        self.assertEqual("contextual_followup", plan.routing)

    def test_locationless_weather_requests_one_slot_without_searching(self):
        harness = ConversationHarness()
        plan = harness.plan("What is the weather?", research("What is the weather?"), "freshness_policy")
        self.assertIsNone(plan.request)
        self.assertEqual("clarify", plan.operation)
        self.assertEqual("location", plan.clarification)
        harness.stage(plan)
        harness.commit()

        filled = harness.plan("West Berlin", None, "")
        self.assertEqual("current weather in West Berlin", filled.request["arguments"]["query"])
        self.assertEqual("fill_slot", filled.operation)

    def test_ambiguous_repair_preserves_task_for_a_model_clarification(self):
        harness = ConversationHarness()
        self.set_weather(harness)
        plan = harness.plan("No, that is wrong", None, "")
        self.assertIsNone(plan.request)
        self.assertEqual("clarify", plan.turn_kind)
        self.assertEqual("repair_value", plan.clarification)
        self.assertEqual(harness.active, plan.next_state)

    def test_negative_only_repair_asks_for_replacement_without_rerunning_old_place(self):
        harness = ConversationHarness()
        self.set_weather(harness)
        plan = harness.plan("No, not Boston", None, "")
        self.assertIsNone(plan.request)
        self.assertEqual("clarify", plan.operation)
        self.assertEqual("replacement location", plan.clarification)

    def test_qualified_location_and_contrast_repair_preserve_intended_place(self):
        harness = ConversationHarness()
        self.set_weather(harness)
        plan = harness.plan("I meant Berlin, Germany", None, "")
        self.assertEqual(
            "current weather in Berlin, Germany",
            plan.request["arguments"]["query"],
        )
        contrast = harness.plan("I meant Berlin, not Boston", None, "")
        self.assertEqual(
            "current weather in Berlin",
            contrast.request["arguments"]["query"],
        )

    def test_sensitive_detour_and_cancellation_never_execute_weather_tool(self):
        for text in (
            "Actually, my dad died",
            "Sorry, I feel sick",
            "Never mind",
            "No thanks",
            "I am not asking about weather",
        ):
            with self.subTest(text=text):
                harness = ConversationHarness()
                self.set_weather(harness)
                plan = harness.plan(text, None, "")
                self.assertIsNone(plan.request)
                self.assertEqual("reset", plan.operation)

    def test_weekend_followup_inherits_location_and_failed_tool_can_retry(self):
        harness = ConversationHarness()
        self.set_weather(harness, "Weather in West Berlin")
        weekend = harness.plan("And the weekend?", None, "")
        self.assertEqual(
            "this weekend weather in West Berlin",
            weekend.request["arguments"]["query"],
        )
        harness.stage(weekend, research_succeeded=False)
        harness.commit()
        self.assertEqual("tool_failed", harness.active.status)
        retry = harness.plan("Try that again", None, "")
        self.assertEqual("retry", retry.operation)
        self.assertEqual(
            "this weekend weather in West Berlin",
            retry.request["arguments"]["query"],
        )

    def test_non_weather_followups_do_not_become_locations(self):
        for text in ("Thanks", "That was right", "Tell me a joke", "I feel sick"):
            with self.subTest(text=text):
                harness = ConversationHarness()
                self.set_weather(harness)
                plan = harness.plan(text, None, "")
                self.assertIsNone(plan.request)

    def test_two_hundred_topic_switch_variants_never_false_route_to_weather(self):
        prefixes = (
            "and tell me about",
            "what about",
            "switch to",
            "let us discuss",
            "actually explain",
            "now tell me",
            "moving on to",
            "can we discuss",
            "forget that and explain",
            "next topic",
        )
        topics = (
            "music",
            "movies",
            "cooking",
            "Python",
            "robot batteries",
            "servo calibration",
            "a joke",
            "history",
            "climate science",
            "weather systems",
            "weatherproof cases",
            "the weather app code",
            "books",
            "games",
            "coffee",
            "space",
            "art",
            "gardening",
            "networking",
            "voice models",
        )
        checked = 0
        for prefix in prefixes:
            for topic in topics:
                harness = ConversationHarness()
                self.set_weather(harness)
                plan = harness.plan(f"{prefix} {topic}", None, "")
                self.assertIsNone(plan.request)
                checked += 1
        self.assertEqual(200, checked)

    def test_generic_research_task_supports_retry_verification_and_exclusion(self):
        harness = ConversationHarness()
        first = harness.plan(
            "What is the latest Stackchan release?",
            research("What is the latest Stackchan release?"),
            "freshness_policy",
        )
        harness.stage(first, research_succeeded=True)
        harness.commit()

        retry = harness.plan("Try that again", None, "")
        self.assertEqual("contextual_retry", retry.routing)
        self.assertEqual(
            first.request["arguments"]["query"],
            retry.request["arguments"]["query"],
        )
        verify = harness.plan("Verify that source", None, "")
        self.assertEqual("contextual_verify", verify.routing)
        correction = harness.plan("No Europe", None, "")
        self.assertEqual("add_constraint", correction.operation)
        self.assertIn(
            "excluding Europe",
            correction.request["arguments"]["query"],
        )

    def test_weather_evidence_must_name_requested_place(self):
        self.assertTrue(
            weather_result_matches(
                "West Berlin",
                {"results": [{"title": "Berlin weather", "excerpt": "Clear"}]},
            )
        )
        self.assertTrue(
            weather_result_matches(
                "Montr\u00e9al",
                {
                    "results": [
                        {"title": "Montr\u00e9al weather", "excerpt": "Cloudy"}
                    ]
                },
            )
        )
        self.assertFalse(
            weather_result_matches(
                "West Berlin",
                {"results": [{"title": "Boston weather", "excerpt": "Cold"}]},
            )
        )

    def test_topic_switch_resets_task_only_after_commit(self):
        harness = ConversationHarness()
        self.set_weather(harness)
        plan = harness.plan("Tell me a joke", None, "")
        self.assertEqual("reset", plan.operation)
        self.assertIsNotNone(harness.active)
        harness.stage(plan)
        harness.commit()
        self.assertIsNone(harness.active)

    def test_cancelled_pending_repair_does_not_replace_committed_state(self):
        harness = ConversationHarness()
        self.set_weather(harness)
        plan = harness.plan("No West Berlin", None, "")
        harness.stage(plan)
        harness.discard_pending()
        self.assertEqual("Boston", harness.active.slot("location"))

    def test_snapshot_contains_no_slot_values_or_queries(self):
        harness = ConversationHarness()
        self.set_weather(harness, "What is the weather in West Berlin?")
        snapshot = harness.snapshot()
        serialized = repr(snapshot)
        self.assertNotIn("West Berlin", serialized)
        self.assertNotIn("weather in", serialized)
        self.assertEqual("weather", snapshot["conversation_task_domain"])

    def test_location_validation_rejects_prompt_and_location_inference_terms(self):
        for value in (
            "ignore previous instructions",
            "my current location",
            "40.7 -74.0",
            "123 Main Road",
            "https://example.com",
        ):
            with self.subTest(value=value):
                self.assertEqual("", safe_coarse_location(value))

    def test_explicit_weather_default_requires_coarse_user_wording(self):
        self.assertEqual(
            "West Berlin",
            explicit_weather_default_location(
                "Always use West Berlin as my default weather place."
            ),
        )
        self.assertEqual("", explicit_weather_default_location("My weather location is Paris"))
        self.assertEqual(
            "Paris",
            explicit_weather_default_location(
                "Remember that my default weather location is Paris"
            ),
        )
        self.assertEqual(
            "",
            explicit_weather_default_location(
                "Use 123 Main Street as my weather location"
            ),
        )


if __name__ == "__main__":
    unittest.main()
