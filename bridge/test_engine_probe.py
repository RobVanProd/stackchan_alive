import json
import os
import sys
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

from engine_probe import SCHEMA, run_probe, write_outputs
from local_runner import GENERIC_COMMAND_ENV, RUNNER_PROFILES
from stt_adapter import STT_COMMAND_ENV
from tts_adapter import TTS_COMMAND_ENV

ENGINE_ENV = {
    GENERIC_COMMAND_ENV: "",
    STT_COMMAND_ENV: "",
    TTS_COMMAND_ENV: "",
}
for profile in RUNNER_PROFILES.values():
    ENGINE_ENV[profile["command_env"]] = ""


class EngineProbeTests(unittest.TestCase):
    def test_unconfigured_probe_reports_clear_summary(self):
        with patch.dict(os.environ, ENGINE_ENV, clear=False):
            report = run_probe(profiles=["gemma4-e2b-gguf"])

        self.assertEqual(SCHEMA, report["schema"])
        self.assertEqual("unconfigured", report["summary"]["status"])
        self.assertEqual("unconfigured", report["model_profiles"][0]["status"])
        self.assertFalse(report["model_profiles"][0]["ok"])
        self.assertEqual("unconfigured", report["stt"]["status"])
        self.assertEqual("unconfigured", report["tts"]["status"])

    def test_fake_engines_can_pass_smoke_probe(self):
        with tempfile.TemporaryDirectory() as temp_dir:
            temp_path = Path(temp_dir)
            model_script = temp_path / "fake_model.py"
            model_script.write_text(
                "\n".join(
                    [
                        "import json",
                        "import sys",
                        "sys.stdin.read()",
                        "print(json.dumps({",
                        "  'spoken_text': 'Signal received. Curiosity systems are online.',",
                        "  'mode': 'happy',",
                        "  'earcon': 'happy',",
                        "  'emotion': {'arousal': 0.1, 'valence': 0.2},",
                        "  'memory_write': {'robot.status': 'ready'},",
                        "  'memory_forget': []",
                        "}))",
                    ]
                ),
                encoding="utf-8",
            )
            stt_script = temp_path / "fake_stt.py"
            stt_script.write_text(
                "\n".join(
                    [
                        "import json",
                        "import os",
                        "import sys",
                        "payload = sys.stdin.buffer.read()",
                        "assert os.environ['STACKCHAN_AUDIO_BYTES'] == str(len(payload))",
                        "assert os.environ['STACKCHAN_AUDIO_SAMPLE_RATE'] == '22050'",
                        "print(json.dumps({'transcript': 'hello stackchan'}))",
                    ]
                ),
                encoding="utf-8",
            )
            tts_script = temp_path / "fake_tts.py"
            tts_script.write_text(
                "\n".join(
                    [
                        "import json",
                        "import os",
                        "import sys",
                        "text = sys.stdin.buffer.read().decode('utf-8')",
                        "assert 'Stackchan' in text",
                        "assert os.environ['STACKCHAN_TTS_VOICE'] == 'probe-voice'",
                        "print(json.dumps({",
                        "  'audio_format': 'wav',",
                        "  'sample_rate': 22050,",
                        "  'audio_bytes': 256,",
                        "  'beats': [{'env': 0.2, 'viseme': 'ah', 'duration_ms': 20}]",
                        "}))",
                    ]
                ),
                encoding="utf-8",
            )
            env = {
                **ENGINE_ENV,
                "STACKCHAN_GEMMA4_E2B_GGUF_COMMAND": f'"{sys.executable}" "{model_script}"',
            }

            with patch.dict(os.environ, env, clear=False):
                report = run_probe(
                    profiles=["gemma4-e2b-gguf"],
                    run_model_smoke=True,
                    stt_command=f'"{sys.executable}" "{stt_script}"',
                    stt_pcm=b"\x11\x00\x22\x00",
                    stt_sample_rate=22050,
                    stt_audio_source="fixture.raw",
                    tts_command=f'"{sys.executable}" "{tts_script}"',
                    tts_voice="probe-voice",
                )

        self.assertEqual("pass", report["summary"]["status"])
        self.assertEqual("pass", report["model_profiles"][0]["status"])
        self.assertTrue(report["model_profiles"][0]["smoke"]["ok"])
        self.assertEqual("pass", report["stt"]["status"])
        self.assertEqual("hello stackchan", report["stt"]["transcript"])
        self.assertEqual("fixture.raw", report["stt"]["audio_source"])
        self.assertEqual(22050, report["stt"]["sample_rate"])
        self.assertEqual(4, report["stt"]["audio_bytes"])
        self.assertEqual("pass", report["tts"]["status"])
        self.assertEqual(1, report["tts"]["beats"])
        self.assertEqual("probe-voice", report["tts"]["voice"])

    def test_write_outputs_includes_json_and_markdown(self):
        with patch.dict(os.environ, ENGINE_ENV, clear=False):
            report = run_probe(profiles=["gemma4-e2b-gguf"])

        with tempfile.TemporaryDirectory() as temp_dir:
            json_path, markdown_path = write_outputs(report, Path(temp_dir))
            payload = json.loads(json_path.read_text(encoding="utf-8"))
            markdown = markdown_path.read_text(encoding="utf-8")

        self.assertEqual(SCHEMA, payload["schema"])
        self.assertIn("Stackchan Engine Probe", markdown)
        self.assertIn("gemma4-e2b-gguf", markdown)
        self.assertIn("STACKCHAN_GEMMA4_E2B_GGUF_COMMAND", markdown)


if __name__ == "__main__":
    unittest.main()
