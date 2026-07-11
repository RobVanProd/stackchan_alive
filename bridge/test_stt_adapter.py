import json
import os
import sys
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

BRIDGE_DIR = Path(__file__).resolve().parent
if str(BRIDGE_DIR) not in sys.path:
    sys.path.insert(0, str(BRIDGE_DIR))

from stt_adapter import (
    STT_COMMAND_ENV,
    SttConfigurationError,
    SttExecutionError,
    normalize_transcript_output,
    parse_transcript_output,
    transcribe_pcm,
)
from stt_normalization import normalize_stackchan_terms
from whisper_cpp_stt import (
    clean_whisper_text,
    read_whisper_transcript,
    transcribe_pcm_with_whisper_cpp,
    write_pcm_wav as write_whisper_pcm_wav,
)
from windows_speech_stt import (
    clamp_sample_rate,
    parse_recognizer_output,
    write_pcm_wav,
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

    def test_transcript_output_preserves_normalization_metadata(self):
        transcript, metadata = parse_transcript_output(
            json.dumps(
                {
                    "transcript": "Hello Stackchan",
                    "raw_transcript": "Hello stack shed",
                    "transcript_normalized": True,
                }
            ).encode()
        )

        self.assertEqual("Hello Stackchan", transcript)
        self.assertEqual("Hello stack shed", metadata["raw_transcript"])
        self.assertTrue(metadata["transcript_normalized"])

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

    def test_windows_speech_adapter_writes_pcm_wav_contract(self):
        with tempfile.TemporaryDirectory() as temp_dir:
            wav_path = Path(temp_dir) / "utterance.wav"
            write_pcm_wav(wav_path, b"\x01\x00\x02\x00", 16000)

            import wave

            with wave.open(str(wav_path), "rb") as wav:
                self.assertEqual(1, wav.getnchannels())
                self.assertEqual(2, wav.getsampwidth())
                self.assertEqual(16000, wav.getframerate())
                self.assertEqual(b"\x01\x00\x02\x00", wav.readframes(2))

    def test_windows_speech_adapter_normalizes_recognizer_json(self):
        result = parse_recognizer_output(
            json.dumps(
                {
                    "transcript": "  hello   stack shed ",
                    "confidence": "0.5",
                    "recognizer": "MS-1033-80-DESK",
                    "culture": "en-US",
                }
            ).encode("utf-8")
        )

        self.assertEqual("hello Stackchan", result.transcript)
        self.assertEqual("hello stack shed", result.raw_transcript)
        self.assertEqual(0.5, result.confidence)
        self.assertEqual("MS-1033-80-DESK", result.recognizer)
        self.assertEqual("en-US", result.culture)
        self.assertEqual(8000, clamp_sample_rate(1))
        self.assertEqual(48000, clamp_sample_rate(96000))

    def test_windows_speech_adapter_normalizes_stackchan_name_variants_only(self):
        self.assertEqual("Hello Stackchan", normalize_stackchan_terms("Hello stack shed"))
        self.assertEqual("Hello Stackchan", normalize_stackchan_terms("Hello stack chan"))
        self.assertEqual("Stackchan is awake", normalize_stackchan_terms("stack chin is awake"))
        self.assertEqual("Please stack the blocks", normalize_stackchan_terms("Please stack the blocks"))

    def test_whisper_adapter_writes_pcm_wav_contract(self):
        with tempfile.TemporaryDirectory() as temp_dir:
            wav_path = Path(temp_dir) / "utterance.wav"
            write_whisper_pcm_wav(wav_path, b"\x01\x00\x02\x00", 16000)

            import wave

            with wave.open(str(wav_path), "rb") as wav:
                self.assertEqual(1, wav.getnchannels())
                self.assertEqual(2, wav.getsampwidth())
                self.assertEqual(16000, wav.getframerate())
                self.assertEqual(b"\x01\x00\x02\x00", wav.readframes(2))

    def test_whisper_adapter_cleans_timestamped_output(self):
        text = """
        whisper_model_load: loading model
        [00:00:00.000 --> 00:00:01.000]   hey   stack shed
        [00:00:01.000 --> 00:00:02.000]  are you awake
        """

        self.assertEqual("hey stack shed are you awake", clean_whisper_text(text))

    def test_whisper_adapter_prefers_output_text_file(self):
        with tempfile.TemporaryDirectory() as temp_dir:
            prefix = Path(temp_dir) / "utterance"
            prefix.with_suffix(".txt").write_text(" hello stack chan \n", encoding="utf-8")

            self.assertEqual("hello stack chan", read_whisper_transcript(prefix, b"noisy stdout"))

    def test_whisper_adapter_runs_fake_whisper_cli_and_normalizes(self):
        with tempfile.TemporaryDirectory() as temp_dir:
            temp_path = Path(temp_dir)
            fake = temp_path / "fake_whisper.py"
            model = temp_path / "ggml-base.en.bin"
            model.write_bytes(b"fake model")
            fake.write_text(
                "\n".join(
                    [
                        "import sys",
                        "from pathlib import Path",
                        "args = sys.argv[1:]",
                        "out = Path(args[args.index('-of') + 1])",
                        "out.with_suffix('.txt').write_text('hey stack shed', encoding='utf-8')",
                    ]
                ),
                encoding="utf-8",
            )

            result = transcribe_pcm_with_whisper_cpp(
                b"\x01\x00\x02\x00",
                16000,
                whisper_exe=f"{sys.executable} {fake}",
                model=str(model),
            )

        self.assertEqual("hey Stackchan", result.transcript)
        self.assertEqual("hey stack shed", result.raw_transcript)
        self.assertEqual(str(model), result.model)


if __name__ == "__main__":
    unittest.main()
