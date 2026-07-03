import json
import os
import sys
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

from stt_adapter import (
    STT_COMMAND_ENV,
    SttConfigurationError,
    SttExecutionError,
    normalize_transcript_output,
    transcribe_pcm,
)


class SttAdapterTests(unittest.TestCase):
    def test_unconfigured_stt_raises_clear_error(self):
        with patch.dict(os.environ, {STT_COMMAND_ENV: ""}, clear=False):
            with self.assertRaises(SttConfigurationError):
                transcribe_pcm(b"\x00\x00", 16000)

    def test_transcript_output_accepts_plain_text_and_json(self):
        self.assertEqual("hello stackchan", normalize_transcript_output(b" hello   stackchan \n"))
        self.assertEqual("hello json", normalize_transcript_output(json.dumps({"transcript": "hello json"}).encode()))
        self.assertEqual("hello text", normalize_transcript_output(json.dumps({"text": "hello text"}).encode()))

    def test_stt_command_receives_pcm_and_audio_environment(self):
        with tempfile.TemporaryDirectory() as temp_dir:
            script = Path(temp_dir) / "fake_stt.py"
            script.write_text(
                "\n".join(
                    [
                        "import os",
                        "import sys",
                        "payload = sys.stdin.buffer.read()",
                        "assert os.environ['STACKCHAN_AUDIO_SAMPLE_RATE'] == '16000'",
                        "assert os.environ['STACKCHAN_AUDIO_FORMAT'] == 's16le_mono'",
                        "assert os.environ['STACKCHAN_AUDIO_BYTES'] == str(len(payload))",
                        "print('I picked you up gently.')",
                    ]
                ),
                encoding="utf-8",
            )
            command = f'"{sys.executable}" "{script}"'

            result = transcribe_pcm(b"\x01\x00\x02\x00", 16000, command=command)

        self.assertEqual("I picked you up gently.", result.transcript)
        self.assertEqual("cli", result.command_source)
        self.assertEqual(16000, result.sample_rate)
        self.assertEqual(4, result.audio_bytes)
        self.assertGreater(result.elapsed_ms, 0.0)

    def test_empty_stt_output_is_an_execution_error(self):
        with tempfile.TemporaryDirectory() as temp_dir:
            script = Path(temp_dir) / "empty_stt.py"
            script.write_text("import sys\nsys.stdin.buffer.read()\n", encoding="utf-8")
            command = f'"{sys.executable}" "{script}"'

            with self.assertRaises(SttExecutionError):
                transcribe_pcm(b"\x01\x00", 16000, command=command)


if __name__ == "__main__":
    unittest.main()
