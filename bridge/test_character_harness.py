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

    def test_prompt_suite_and_profiles_cover_mobile_target(self):
        self.assertGreaterEqual(len(PROMPT_SUITE), 5)
        self.assertIn("gemma4-e2b-litert-lm", MODEL_PROFILES)
        prompt = build_prompt(PROMPT_SUITE[0])
        self.assertIn("Return only one JSON object", prompt)
        self.assertIn("spoken_text", prompt)
        self.assertIn('"mode":"idle|attend|listen|think|speak|react|happy|concern|sleep|error|safety"', prompt)
        self.assertIn('"earcon":"none|wake|confirm|think|happy|concern|sleep|error|safety"', prompt)
        self.assertIn('"emotion":{"arousal":0.0,"valence":0.0}', prompt)
        self.assertIn("Do not use any other mode or earcon value", prompt)

    def test_enums_match_character_lock_contract(self):
        for mode in ("idle", "attend", "listen", "think", "speak", "react", "happy", "concern", "sleep", "error", "safety"):
            self.assertIn(mode, ALLOWED_MODES)
        for earcon in ("none", "wake", "confirm", "think", "happy", "concern", "sleep", "error", "safety"):
            self.assertIn(earcon, ALLOWED_EARCONS)


if __name__ == "__main__":
    unittest.main()
