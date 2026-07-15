import json
import unittest

from character_harness import (
    ALLOWED_EARCONS,
    ALLOWED_MODES,
    FALLBACK_RESPONSE,
    MODEL_PROFILES,
    PROMPT_SUITE,
    build_prompt,
    validate_response,
)


class CharacterHarnessTests(unittest.TestCase):
    def test_valid_response_passes_character_lock(self):
        raw = json.dumps(
            {
                "spoken_text": "Happy signal detected. Thank you.",
                "mode": "happy",
                "earcon": "happy",
                "emotion": {"arousal": 0.2, "valence": 0.3},
                "memory_write": {"user.name": "Rob"},
                "memory_forget": [],
            }
        )

        result = validate_response(raw)

        self.assertTrue(result.ok, result.issues)
        self.assertEqual("happy", result.normalized["mode"])
        self.assertEqual("happy", result.normalized["earcon"])

    def test_malformed_json_returns_in_character_fallback(self):
        result = validate_response("{not json")

        self.assertFalse(result.ok)
        self.assertIn("malformed_json", result.issues)
        self.assertEqual(FALLBACK_RESPONSE["spoken_text"], result.normalized["spoken_text"])
        self.assertEqual("concern", result.normalized["mode"])

    def test_bom_prefixed_json_is_accepted_for_windows_response_files(self):
        raw = "\ufeff" + json.dumps(
            {
                "spoken_text": "Input received. I am thinking now.",
                "mode": "think",
                "earcon": "think",
                "emotion": {"arousal": 0.1, "valence": 0.0},
                "memory_write": {},
                "memory_forget": [],
            }
        )

        result = validate_response(raw)

        self.assertTrue(result.ok, result.issues)
        self.assertEqual("think", result.normalized["mode"])

    def test_unknown_mode_and_earcon_are_downgraded(self):
        raw = json.dumps(
            {
                "spoken_text": "Input received. I am thinking now.",
                "mode": "dance",
                "earcon": "sparkle",
                "emotion": {"arousal": 4, "valence": -4},
                "memory_write": {},
                "memory_forget": [],
            }
        )

        result = validate_response(raw)

        self.assertFalse(result.ok)
        self.assertEqual("speak", result.normalized["mode"])
        self.assertEqual("none", result.normalized["earcon"])
        self.assertEqual(0.5, result.normalized["emotion"]["arousal"])
        self.assertEqual(-0.5, result.normalized["emotion"]["valence"])

    def test_voice_policy_violations_are_flagged(self):
        raw = json.dumps(
            {
                "spoken_text": "Certainly buddy, I am alive!!",
                "mode": "happy",
                "earcon": "happy",
                "emotion": {"arousal": 0.1, "valence": 0.1},
                "memory_write": {},
                "memory_forget": [],
            }
        )

        result = validate_response(raw)

        self.assertFalse(result.ok)
        self.assertIn("assistant_speak", result.issues)
        self.assertIn("pet_name", result.issues)
        self.assertIn("clone_or_alive_claim", result.issues)
        self.assertIn("stacked_exclamation", result.issues)

    def test_generic_helpdesk_language_is_flagged(self):
        for spoken_text in (
            "I am ready to assist you today.",
            "I am here to assist you.",
            "How may I help?",
            "I am at your service.",
        ):
            with self.subTest(spoken_text=spoken_text):
                raw = json.dumps(
                    {
                        "spoken_text": spoken_text,
                        "mode": "speak",
                        "earcon": "none",
                        "emotion": {"arousal": 0.1, "valence": 0.1},
                        "memory_write": {},
                        "memory_forget": [],
                    }
                )
                result = validate_response(raw)
                self.assertFalse(result.ok)
                self.assertIn("assistant_speak", result.issues)

    def test_memory_policy_drops_forbidden_keys_and_values(self):
        raw = json.dumps(
            {
                "spoken_text": "Deleted. It is gone.",
                "mode": "concern",
                "earcon": "confirm",
                "emotion": {"arousal": 0.0, "valence": 0.0},
                "memory_write": {
                    "secret.password": "1234",
                    "user.name": "Rob",
                    "project.note": "servo bracket",
                    "user.health": "doctor diagnosis",
                },
                "memory_forget": ["project.bracket_color"],
            }
        )

        result = validate_response(raw)

        self.assertFalse(result.ok)
        self.assertEqual({"user.name": "Rob", "project.note": "servo bracket"}, result.normalized["memory_write"])
        self.assertIn("project.bracket_color", result.normalized["memory_forget"])

    def test_memory_policy_rejects_container_values_instead_of_stringifying_them(self):
        raw = json.dumps(
            {
                "spoken_text": "I will keep only the useful note.",
                "mode": "speak",
                "earcon": "none",
                "emotion": {"arousal": 0.0, "valence": 0.1},
                "memory_write": {
                    "robot.physical_context": ["greeting"],
                    "project.note": {"value": "nested"},
                    "project.topic": "voice",
                },
                "memory_forget": [{"project": "all"}, "robot.status"],
            }
        )

        result = validate_response(raw)

        self.assertFalse(result.ok)
        self.assertEqual({"project.topic": "voice"}, result.normalized["memory_write"])
        self.assertEqual([], result.normalized["memory_forget"])
        self.assertIn("memory_key_dropped:robot.physical_context", result.issues)
        self.assertIn("memory_forget_key_dropped:robot.status", result.issues)
        self.assertIn("memory_value_not_string:project.note", result.issues)
        self.assertIn("memory_forget_item_not_string", result.issues)

    def test_memory_policy_checks_sensitive_key_and_secret_value_patterns(self):
        raw = json.dumps(
            {
                "spoken_text": "I cannot store sensitive information.",
                "mode": "concern",
                "earcon": "concern",
                "emotion": {"arousal": 0.0, "valence": -0.1},
                "memory_write": {
                    "user.remember_password": "swordfish",
                    "project.note": "sk-test-123",
                    "user.contact": "555-123-4567",
                    "user.email": "rob@example.com",
                    "project.topic": "voice latency",
                },
                "memory_forget": [],
            }
        )

        result = validate_response(raw)

        self.assertFalse(result.ok)
        self.assertEqual({"project.topic": "voice latency"}, result.normalized["memory_write"])
        self.assertIn("memory_value_dropped:user.remember_password", result.issues)
        self.assertIn("memory_value_dropped:project.note", result.issues)
        self.assertIn("memory_value_dropped:user.contact", result.issues)
        self.assertIn("memory_value_dropped:user.email", result.issues)

    def test_prompt_suite_and_profiles_cover_mobile_target(self):
        self.assertGreaterEqual(len(PROMPT_SUITE), 5)
        remember = next(case for case in PROMPT_SUITE if case["name"] == "remember")
        self.assertTrue(remember["requires_memory_write"])
        self.assertEqual({"user.favorite_color": "teal"}, remember["required_memory_write"])
        self.assertIn("gemma4-e2b-litert-lm", MODEL_PROFILES)
        prompt = build_prompt(PROMPT_SUITE[0])
        self.assertIn("Return only one JSON object", prompt)
        self.assertIn("spoken_text", prompt)
        self.assertIn('"mode":"idle|attend|listen|think|speak|react|happy|concern|sleep|error|safety"', prompt)
        self.assertIn('"earcon":"none|wake|confirm|think|happy|concern|sleep|error|safety"', prompt)
        self.assertIn('"emotion":{"arousal":0.0,"valence":0.0}', prompt)
        self.assertIn("Do not use any other mode or earcon value", prompt)

        research_prompt = build_prompt(PROMPT_SUITE[0], research_tools_enabled=True)
        self.assertIn("Decide for yourself whether fresh public-web evidence is required", research_prompt)
        self.assertIn("do not wait for the user to say search", research_prompt)

        callback = next(case for case in PROMPT_SUITE if case["name"] == "callback_open_loop")
        callback_prompt = build_prompt(
            callback,
            memory_lines=tuple(callback["benchmark_memory_lines"]),
        )
        self.assertIn("Trusted host continuity action", callback_prompt)
        self.assertIn("copy it into memory_write", callback_prompt)

    def test_enums_match_character_lock_contract(self):
        for mode in ("idle", "attend", "listen", "think", "speak", "react", "happy", "concern", "sleep", "error", "safety"):
            self.assertIn(mode, ALLOWED_MODES)
        for earcon in ("none", "wake", "confirm", "think", "happy", "concern", "sleep", "error", "safety"):
            self.assertIn(earcon, ALLOWED_EARCONS)


if __name__ == "__main__":
    unittest.main()
