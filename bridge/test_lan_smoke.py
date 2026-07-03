import os
import tempfile
import unittest
from pathlib import Path

from lan_smoke import build_report, encode_client_frame, write_outputs


class LanSmokeTests(unittest.TestCase):
    def test_client_frames_are_masked_for_server_protocol_path(self):
        frame = encode_client_frame(b"hi", opcode=0x1)

        self.assertEqual(0x81, frame[0])
        self.assertEqual(0x80 | 2, frame[1])
        self.assertEqual(4 + 2, len(frame[2:]))

    def test_build_report_exercises_text_and_audio_socket_paths(self):
        with tempfile.TemporaryDirectory() as temp_dir:
            report = build_report(Path(temp_dir))

        self.assertEqual("stackchan.lan-smoke.v1", report["schema"])
        self.assertEqual("pass", report["status"])
        scenarios = {scenario["scenario"]: scenario for scenario in report["scenarios"]}
        self.assertEqual({"text-turn", "audio-loop"}, set(scenarios))
        self.assertEqual("pass", scenarios["text-turn"]["status"])
        self.assertEqual("pass", scenarios["audio-loop"]["status"])
        self.assertIn("thinking", scenarios["text-turn"]["frame_types"])
        self.assertIn("audio_stream_start", scenarios["audio-loop"]["frame_types"])
        self.assertGreater(scenarios["audio-loop"]["binary_frames"], 0)
        self.assertGreater(scenarios["audio-loop"]["binary_bytes"], 0)

    def test_write_outputs_creates_json_markdown_and_per_scenario_reports(self):
        with tempfile.TemporaryDirectory() as temp_dir:
            out_dir = Path(temp_dir)
            report = build_report(out_dir)
            paths = write_outputs(report, out_dir)

            self.assertTrue(paths["json"].exists())
            self.assertTrue(paths["markdown"].exists())
            self.assertTrue((out_dir / "text-turn.json").exists())
            self.assertTrue((out_dir / "audio-loop.json").exists())
            markdown = paths["markdown"].read_text(encoding="utf-8")

        self.assertIn("Stackchan LAN Bridge Smoke", markdown)
        self.assertIn("socket-level no-hardware proxy", markdown)

    def test_smoke_report_does_not_leak_configured_runner_environment(self):
        key = "STACKCHAN_MODEL_COMMAND"
        old = os.environ.get(key)
        os.environ[key] = "definitely-not-a-real-command"
        try:
            with tempfile.TemporaryDirectory() as temp_dir:
                report = build_report(Path(temp_dir), scenarios=("text-turn",))
        finally:
            if old is None:
                os.environ.pop(key, None)
            else:
                os.environ[key] = old

        self.assertEqual("pass", report["status"])


if __name__ == "__main__":
    unittest.main()
