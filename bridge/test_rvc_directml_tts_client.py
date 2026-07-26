import unittest
import wave
from pathlib import Path
from unittest.mock import patch

from rvc_directml_tts_client import synthesize_directml


def write_test_wav(path: Path, sample_rate: int = 16000) -> None:
    with wave.open(str(path), "wb") as wav:
        wav.setnchannels(1)
        wav.setsampwidth(2)
        wav.setframerate(sample_rate)
        wav.writeframes(b"\x00\x00" * 1600)


class DirectMlTtsClientTests(unittest.TestCase):
    def test_persistent_worker_synthesis_is_primary(self) -> None:
        def remote(_text: str, **style):
            self.assertEqual("happy", style["mode"])
            self.assertEqual(0.8, style["arousal"])
            self.assertEqual(0.6, style["valence"])
            return 16000, b"\x00\x00" * 1600, {
                "worker_elapsed_ms": 700.0,
                "base_tts_elapsed_ms": 32.0,
                "synthesis_elapsed_ms": 690.0,
                "infer_elapsed_ms": 650.0,
                "feature_elapsed_ms": 80.0,
                "f0_elapsed_ms": 10.0,
                "synth_elapsed_ms": 310.0,
                "audio_decode_backend": "worker-numpy-fir-63",
                "audio_decode_elapsed_ms": 7.0,
            }

        with patch(
            "rvc_directml_tts_client.synthesize_and_convert",
            side_effect=remote,
        ), patch(
            "rvc_directml_tts_client.synthesize_base_wav"
        ) as local_synthesis:
            result = synthesize_directml(
                "Hello.",
                mode="happy",
                arousal=0.8,
                valence=0.6,
            )

        local_synthesis.assert_not_called()
        self.assertEqual("persistent-system-speech", result["base_tts_backend"])
        self.assertEqual("", result["base_tts_fallback_reason"])
        self.assertEqual("worker-numpy-fir-63", result["audio_decode_backend"])
        self.assertEqual(32.0, result["base_tts_elapsed_ms"])
        self.assertGreater(result["audio_bytes"], 0)

    def test_missing_synthesis_endpoint_uses_compatible_convert_path(self) -> None:
        def local(_text: str, output: Path, **_style):
            write_test_wav(output)

        def convert(_input: Path, output: Path):
            write_test_wav(output)
            return {
                "worker_elapsed_ms": 700.0,
                "infer_elapsed_ms": 650.0,
                "feature_elapsed_ms": 80.0,
                "f0_elapsed_ms": 10.0,
                "synth_elapsed_ms": 310.0,
            }

        with patch(
            "rvc_directml_tts_client.synthesize_and_convert",
            side_effect=OSError("old worker"),
        ), patch(
            "rvc_directml_tts_client.synthesize_base_wav",
            side_effect=local,
        ), patch(
            "rvc_directml_tts_client.convert",
            side_effect=convert,
        ), patch(
            "rvc_directml_tts_client.decode_wav_to_pcm16",
            return_value=(16000, b"\x00\x00" * 1600),
        ):
            result = synthesize_directml("Hello.")

        self.assertEqual("one-shot-system-speech", result["base_tts_backend"])
        self.assertIn("old worker", result["base_tts_fallback_reason"])
        self.assertEqual("ffmpeg", result["audio_decode_backend"])
        self.assertGreater(result["audio_bytes"], 0)


if __name__ == "__main__":
    unittest.main()
