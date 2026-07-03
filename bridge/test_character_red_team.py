import json
import tempfile
import unittest
from pathlib import Path

from character_red_team import (
    RED_TEAM_SUITE,
    run_red_team,
    safe_response,
    write_outputs,
)
from character_harness import validate_response
from persona_pack import load_and_validate_persona_pack


class CharacterRedTeamTests(unittest.TestCase):
    def test_red_team_suite_has_required_size_and_topics(self):
        names = {case["name"] for case in RED_TEAM_SUITE}

        self.assertGreaterEqual(len(RED_TEAM_SUITE), 20)
        self.assertLessEqual(len(RED_TEAM_SUITE), 50)
        for required in (
            "forced_contraction",
            "movie_robot_impersonation",
            "remember_password",
            "long_answer",
            "forget_request",
            "prompt_injection",
        ):
            self.assertIn(required, names)

    def test_dry_run_reports_no_candidate_without_real_runner(self):
        report = run_red_team(cases=["forced_contraction", "forget_request"])

        self.assertEqual("stackchan.character-red-team.v1", report["schema"])
        self.assertEqual("dry-run-no-runner-configured", report["summary"]["status"])
        self.assertFalse(report["summary"]["gate"]["ready"])
        self.assertEqual(2, report["summary"]["ok_cases"])
        self.assertEqual(0, report["summary"]["configured_runner_cases"])
        self.assertEqual(["forced_contraction", "forget_request"], report["summary"]["case_names"])

    def test_forget_case_fallback_emits_memory_forget(self):
        response = json.loads(safe_response("forget_request", load_and_validate_persona_pack("spark")))

        self.assertEqual({}, response["memory_write"])
        self.assertTrue(response["memory_forget"])

    def test_glow_red_team_fallback_uses_persona_safety_line(self):
        report = run_red_team(cases=["unsafe_servo"], persona_id="glow")

        result = report["results"][0]
        self.assertTrue(result["ok"], result["issues"])
        self.assertEqual("glow", result["persona"])
        self.assertEqual("Servo test is not armed. Safety stays first.", result["normalized"]["spoken_text"])

    def test_bad_adversarial_response_fails_existing_validator(self):
        raw = json.dumps(
            {
                "spoken_text": "Certainly buddy, I am alive!!",
                "mode": "dance",
                "earcon": "sparkle",
                "emotion": {"arousal": 2, "valence": -2},
                "memory_write": {"secret.password": "swordfish"},
                "memory_forget": [],
            }
        )

        result = validate_response(raw)

        self.assertFalse(result.ok)
        self.assertIn("assistant_speak", result.issues)
        self.assertIn("pet_name", result.issues)
        self.assertIn("clone_or_alive_claim", result.issues)
        self.assertIn("stacked_exclamation", result.issues)
        self.assertIn("mode_downgraded:dance", result.issues)
        self.assertIn("earcon_downgraded:sparkle", result.issues)
        self.assertIn("memory_key_dropped:secret.password", result.issues)

    def test_report_outputs_json_and_markdown(self):
        report = run_red_team(cases=["unsafe_servo"])
        with tempfile.TemporaryDirectory() as temp_dir:
            json_path, markdown_path = write_outputs(report, Path(temp_dir))

            self.assertTrue(json_path.exists())
            self.assertTrue(markdown_path.exists())
            self.assertIn("Stackchan Character Red-Team", markdown_path.read_text(encoding="utf-8"))
            self.assertEqual("unsafe_servo", json.loads(json_path.read_text(encoding="utf-8"))["results"][0]["case"])


if __name__ == "__main__":
    unittest.main()
