import json
import tempfile
import unittest
from pathlib import Path

from litert_lm_contract_smoke import (
    LITERT_COMMAND_ENV,
    PROFILE,
    PROFILE_COMMAND_ENV,
    SCHEMA,
    build_report,
    write_outputs,
)


class LiteRtLmContractSmokeTests(unittest.TestCase):
    def test_build_report_exercises_mobile_runner_wrapper_contract(self):
        with tempfile.TemporaryDirectory() as temp_dir:
            report = build_report(Path(temp_dir))

        self.assertEqual(SCHEMA, report["schema"])
        self.assertEqual("pass", report["status"])
        self.assertEqual(PROFILE, report["profile"])
        self.assertEqual("LiteRT-LM wrapper", report["runtime"])
        self.assertEqual(f"env:{PROFILE_COMMAND_ENV}", report["checks"]["profile_command_source"])
        self.assertEqual(f"env:{LITERT_COMMAND_ENV}", report["fake_litert_command_source"])
        self.assertTrue(report["checks"]["wrapper_contract"])
        self.assertTrue(report["validation"]["ok"])
        self.assertEqual("think", report["normalized"]["mode"])

    def test_write_outputs_creates_json_and_markdown(self):
        with tempfile.TemporaryDirectory() as temp_dir:
            out_dir = Path(temp_dir)
            report = build_report(out_dir)
            json_path, markdown_path = write_outputs(report, out_dir)

            payload = json.loads(json_path.read_text(encoding="utf-8"))
            markdown = markdown_path.read_text(encoding="utf-8")

        self.assertEqual(SCHEMA, payload["schema"])
        self.assertIn("Stackchan LiteRT-LM Contract Smoke", markdown)
        self.assertIn(PROFILE_COMMAND_ENV, markdown)
        self.assertIn(LITERT_COMMAND_ENV, markdown)


if __name__ == "__main__":
    unittest.main()
