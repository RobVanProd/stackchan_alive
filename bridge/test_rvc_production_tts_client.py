import os
import unittest
import wave
from pathlib import Path
from unittest.mock import patch

from rvc_production_tts_client import synthesize_production


def write_test_wav(path: Path) -> None:
    with wave.open(str(path), "wb") as wav:
        wav.setnchannels(1)
        wav.setsampwidth(2)
        wav.setframerate(16000)
        wav.writeframes(b"\x00\x00" * 1600)


class ProductionTtsClientTests(unittest.TestCase):
    def test_directml_result_is_marked_as_primary(self) -> None:
        direct = {"schema": "stackchan.tts-metadata.v1", "voice": "stackchan-rvc-directml-v2"}
        with patch("rvc_production_tts_client.synthesize_directml", return_value=direct):
            result = synthesize_production("Hello.")
        self.assertEqual("directml", result["voice_backend"])
        self.assertFalse(result["voice_fallback"])

    def test_worker_failure_returns_fast_clear_audio_fallback(self) -> None:
        with patch("rvc_production_tts_client.synthesize_directml", side_effect=OSError("offline")), patch(
            "rvc_production_tts_client.synthesize_base_wav", side_effect=lambda _text, path: write_test_wav(path)
        ):
            result = synthesize_production("Hello.")
        self.assertEqual("clear-local-fallback", result["voice_backend"])
        self.assertTrue(result["voice_fallback"])
        self.assertGreater(result["audio_bytes"], 0)
        self.assertFalse(result["audio_truncated"])

    def test_strict_mode_refuses_fallback(self) -> None:
        with patch.dict(os.environ, {"STACKCHAN_VOICE_REQUIRE_DIRECTML": "1"}), patch(
            "rvc_production_tts_client.synthesize_directml", side_effect=OSError("offline")
        ):
            with self.assertRaises(OSError):
                synthesize_production("Hello.")


if __name__ == "__main__":
    unittest.main()
