import json
import os
import base64
import io
import sys
import tempfile
import unittest
import wave
from pathlib import Path
from unittest.mock import patch

from tts_adapter import (
    TTS_COMMAND_ENV,
    TtsConfigurationError,
    TtsExecutionError,
    normalize_tts_output,
    synthesize_speech,
)


def make_pcm16_wav(samples: list[int], sample_rate: int = 22050) -> bytes:
    buffer = io.BytesIO()
    with wave.open(buffer, "wb") as wav:
        wav.setnchannels(1)
        wav.setsampwidth(2)
        wav.setframerate(sample_rate)
        wav.writeframes(b"".join(int(sample).to_bytes(2, "little", signed=True) for sample in samples))
    return buffer.getvalue()


class TtsAdapterTests(unittest.TestCase):
    def test_unconfigured_tts_raises_clear_error(self):
        with patch.dict(os.environ, {TTS_COMMAND_ENV: ""}, clear=False):
            with self.assertRaises(TtsConfigurationError):
                synthesize_speech("Hello Stackchan.")

    def test_compact_beat_output_normalizes_and_marks_final(self):
        beats, metadata = normalize_tts_output(
            json.dumps(
                {
                    "audio_format": "wav",
                    "sample_rate": 22050,
                    "audio_bytes": 1234,
                    "beats": [
                        {"env": 0.25, "viseme": "ah", "duration_ms": 30},
                        {"envelope": 2.0, "viseme": "ee", "durationMs": 40},
                    ],
                }
            ).encode()
        )

        self.assertEqual(2, len(beats))
        self.assertEqual(0.25, beats[0].env)
        self.assertEqual("ah", beats[0].viseme)
        self.assertEqual(30, beats[0].duration_ms)
        self.assertFalse(beats[0].final)
        self.assertEqual(1.0, beats[1].env)
        self.assertEqual("ee", beats[1].viseme)
        self.assertEqual(40, beats[1].duration_ms)
        self.assertTrue(beats[1].final)
        self.assertEqual("wav", metadata["audio_format"])
        self.assertEqual(22050, metadata["sample_rate"])
        self.assertEqual(1234, metadata["audio_bytes"])

    def test_sidecar_frame_output_uses_frame_timing(self):
        beats, metadata = normalize_tts_output(
            json.dumps(
                {
                    "sourceWav": "output.wav",
                    "frameMs": 20,
                    "sampleRate": 48000,
                    "frames": [
                        {"tMs": 0, "envelope": 0.1, "viseme": "neutral"},
                        {"tMs": 20, "envelope": 0.7, "viseme": "oh"},
                        {"tMs": 60, "envelope": 0.0, "viseme": "neutral"},
                    ],
                }
            ).encode()
        )

        self.assertEqual([20, 40, 20], [beat.duration_ms for beat in beats])
        self.assertEqual("oh", beats[1].viseme)
        self.assertTrue(beats[-1].final)
        self.assertEqual(48000, metadata["sample_rate"])
        self.assertEqual("output.wav", metadata["audio_path"])

    def test_optional_audio_b64_is_decoded_and_counted(self):
        payload = b"\x00\x00\xff\x7f"
        beats, metadata = normalize_tts_output(
            json.dumps(
                {
                    "audio_format": "s16le",
                    "sample_rate": 22050,
                    "audio_b64": base64.b64encode(payload).decode("ascii"),
                    "beats": [{"env": 0.4, "viseme": "ah", "duration_ms": 20}],
                }
            ).encode()
        )

        self.assertEqual(1, len(beats))
        self.assertEqual("pcm16", metadata["audio_format"])
        self.assertEqual(22050, metadata["sample_rate"])
        self.assertEqual(payload, metadata["audio_data"])
        self.assertEqual(len(payload), metadata["audio_bytes"])

    def test_wav_audio_b64_is_decoded_to_pcm16_for_downlink(self):
        samples = [0, 1200, -1200, 32767, -32768]
        wav_payload = make_pcm16_wav(samples, sample_rate=24000)
        expected_pcm = b"".join(int(sample).to_bytes(2, "little", signed=True) for sample in samples)

        beats, metadata = normalize_tts_output(
            json.dumps(
                {
                    "audio_format": "wav",
                    "audio_b64": base64.b64encode(wav_payload).decode("ascii"),
                    "beats": [{"env": 0.4, "viseme": "ah", "duration_ms": 20}],
                }
            ).encode()
        )

        self.assertEqual(1, len(beats))
        self.assertEqual("pcm16", metadata["audio_format"])
        self.assertEqual(24000, metadata["sample_rate"])
        self.assertEqual(expected_pcm, metadata["audio_data"])
        self.assertEqual(len(expected_pcm), metadata["audio_bytes"])

    def test_invalid_wav_audio_b64_is_an_execution_error(self):
        with self.assertRaises(TtsExecutionError):
            normalize_tts_output(
                json.dumps(
                    {
                        "audio_format": "wav",
                        "audio_b64": base64.b64encode(b"not a real wav").decode("ascii"),
                        "beats": [{"env": 0.4, "viseme": "ah", "duration_ms": 20}],
                    }
                ).encode()
            )

    def test_invalid_audio_b64_is_an_execution_error(self):
        with self.assertRaises(TtsExecutionError):
            normalize_tts_output(
                json.dumps(
                    {
                        "audio_b64": "not base64",
                        "beats": [{"env": 0.4, "viseme": "ah", "duration_ms": 20}],
                    }
                ).encode()
            )

    def test_tts_command_receives_text_and_voice_environment(self):
        with tempfile.TemporaryDirectory() as temp_dir:
            script = Path(temp_dir) / "fake_tts.py"
            script.write_text(
                "\n".join(
                    [
                        "import json",
                        "import os",
                        "import sys",
                        "text = sys.stdin.buffer.read().decode('utf-8')",
                        "assert text == 'Hello. I am Stackchan.'",
                        "assert os.environ['STACKCHAN_TTS_TEXT_BYTES'] == str(len(text.encode('utf-8')))",
                        "assert os.environ['STACKCHAN_TTS_VOICE'] == 'rvc-bright'",
                        "assert os.environ['STACKCHAN_TTS_OUTPUT'] == 'stackchan.tts-metadata.v1'",
                        "print(json.dumps({'audio_format':'wav','sample_rate':22050,'audio_bytes':99,'beats':[{'env':0.4,'viseme':'ah','duration_ms':25}]}))",
                    ]
                ),
                encoding="utf-8",
            )
            command = f'"{sys.executable}" "{script}"'

            result = synthesize_speech("Hello. I am Stackchan.", command=command, voice="rvc-bright")

        self.assertEqual("cli", result.command_source)
        self.assertEqual("rvc-bright", result.voice)
        self.assertEqual(1, len(result.beats))
        self.assertEqual(25, result.duration_ms)
        self.assertEqual(99, result.audio_bytes)
        self.assertGreater(result.elapsed_ms, 0.0)

    def test_empty_tts_output_is_an_execution_error(self):
        with tempfile.TemporaryDirectory() as temp_dir:
            script = Path(temp_dir) / "empty_tts.py"
            script.write_text("import sys\nsys.stdin.buffer.read()\n", encoding="utf-8")
            command = f'"{sys.executable}" "{script}"'

            with self.assertRaises(TtsExecutionError):
                synthesize_speech("Hello.", command=command)


if __name__ == "__main__":
    unittest.main()
