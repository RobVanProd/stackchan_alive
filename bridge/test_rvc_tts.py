import os
import unittest
from unittest.mock import patch

from rvc_tts import tts_delivery_style


class RvcTtsStyleTests(unittest.TestCase):
    def test_delivery_style_uses_mode_and_energy_without_changing_voice_identity(self):
        with patch.dict(
            os.environ,
            {
                "STACKCHAN_RVC_BASE_TTS_RATE": "1",
                "STACKCHAN_TTS_MODE": "happy",
                "STACKCHAN_TTS_AROUSAL": "0.82",
                "STACKCHAN_TTS_VALENCE": "0.64",
            },
            clear=False,
        ):
            style = tts_delivery_style()

        self.assertEqual("happy", style["mode"])
        self.assertEqual(3, style["base_tts_rate"])
        self.assertEqual(0.82, style["arousal"])
        self.assertEqual(0.64, style["valence"])

    def test_delivery_style_slows_concern_and_sleep_with_bounded_inputs(self):
        cases = (("concern", 0.38, 0), ("sleep", 0.10, -2))
        for mode, arousal, expected_rate in cases:
            with self.subTest(mode=mode), patch.dict(
                os.environ,
                {
                    "STACKCHAN_RVC_BASE_TTS_RATE": "1",
                    "STACKCHAN_TTS_MODE": mode,
                    "STACKCHAN_TTS_AROUSAL": str(arousal),
                    "STACKCHAN_TTS_VALENCE": "-0.4",
                },
                clear=False,
            ):
                self.assertEqual(expected_rate, tts_delivery_style()["base_tts_rate"])

    def test_unknown_mode_and_invalid_emotion_fall_back_safely(self):
        with patch.dict(
            os.environ,
            {
                "STACKCHAN_RVC_BASE_TTS_RATE": "1",
                "STACKCHAN_TTS_MODE": "dramatic",
                "STACKCHAN_TTS_AROUSAL": "not-a-number",
                "STACKCHAN_TTS_VALENCE": "not-a-number",
            },
            clear=False,
        ):
            style = tts_delivery_style()

        self.assertEqual("speak", style["mode"])
        self.assertEqual(1, style["base_tts_rate"])
        self.assertEqual(0.5, style["arousal"])
        self.assertEqual(0.0, style["valence"])


if __name__ == "__main__":
    unittest.main()
