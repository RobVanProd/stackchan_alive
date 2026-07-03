import json
import os
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

from local_runner import GENERIC_COMMAND_ENV, RUNNER_PROFILES
from prearrival_sim_check import SCHEMA, build_report, write_report
from stt_adapter import STT_COMMAND_ENV
from tts_adapter import TTS_COMMAND_ENV

ENGINE_ENV = {
    GENERIC_COMMAND_ENV: "",
    STT_COMMAND_ENV: "",
    TTS_COMMAND_ENV: "",
}
for profile in RUNNER_PROFILES.values():
    ENGINE_ENV[profile["command_env"]] = ""


class PrearrivalSimCheckTests(unittest.TestCase):
    def test_unconfigured_engines_do_not_fail_hardware_proxy(self):
        with tempfile.TemporaryDirectory() as temp_dir, patch.dict(os.environ, ENGINE_ENV, clear=False):
            report = build_report(Path(temp_dir), profiles=["gemma4-e2b-gguf"])

        self.assertEqual(SCHEMA, report["schema"])
        self.assertEqual("pass", report["status"])
        self.assertEqual("proxy-pass-engines-unconfigured", report["readiness_class"])
        self.assertEqual("pass", report["hardware_simulation"]["status"])
        self.assertEqual("unconfigured", report["engine_readiness"]["status"])
        self.assertFalse(report["promotion_ready"])

    def test_write_report_includes_machine_and_human_outputs(self):
        with tempfile.TemporaryDirectory() as temp_dir, patch.dict(os.environ, ENGINE_ENV, clear=False):
            out_dir = Path(temp_dir)
            report = build_report(out_dir, profiles=["gemma4-e2b-litert-lm"])
            json_path, markdown_path = write_report(report, out_dir)

            payload = json.loads(json_path.read_text(encoding="utf-8"))
            markdown = markdown_path.read_text(encoding="utf-8")

            self.assertEqual(SCHEMA, payload["schema"])
            self.assertTrue((out_dir / "hardware-sim" / "hardware_simulation.json").exists())
            self.assertTrue((out_dir / "engine-probe" / "engine_probe.json").exists())
            self.assertIn("Stackchan Pre-Arrival Simulation Check", markdown)
            self.assertIn("Conversation audio loop", markdown)
            self.assertIn("gemma4-e2b-litert-lm", markdown)


if __name__ == "__main__":
    unittest.main()
