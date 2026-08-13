import tempfile
import unittest
from pathlib import Path

from affect_state import (
    AffectState,
    MOOD_VALENCE_BAND,
    affect_prompt_lines,
    load_affect_state,
    observe_turn,
    save_affect_state,
)


class AffectStateTests(unittest.TestCase):
    def test_round_trip_persists_bounded_state(self):
        with tempfile.TemporaryDirectory() as temp_dir:
            path = Path(temp_dir) / "affect_state.json"
            state = AffectState(mood_valence=0.2, mood_arousal=0.1, rapport=0.4, updated_at_s=1000.0)
            self.assertTrue(save_affect_state(path, state))
            loaded = load_affect_state(path)
        self.assertAlmostEqual(0.2, loaded.mood_valence, places=3)
        self.assertAlmostEqual(0.4, loaded.rapport, places=3)

    def test_missing_or_corrupt_file_loads_neutral(self):
        self.assertEqual(AffectState(), load_affect_state("does-not-exist.json"))
        with tempfile.TemporaryDirectory() as temp_dir:
            path = Path(temp_dir) / "affect_state.json"
            path.write_text("{not json", encoding="utf-8")
            self.assertEqual(AffectState(), load_affect_state(path))
            path.write_text('{"schema":"wrong","mood_valence":9}', encoding="utf-8")
            self.assertEqual(AffectState(), load_affect_state(path))

    def test_loaded_state_is_clamped_to_temperament_bands(self):
        with tempfile.TemporaryDirectory() as temp_dir:
            path = Path(temp_dir) / "affect_state.json"
            path.write_text(
                '{"schema":"stackchan.host-affect-state.v1","mood_valence":5.0,'
                '"mood_arousal":-4.0,"rapport":7.0,"updated_at_s":0}',
                encoding="utf-8",
            )
            loaded = load_affect_state(path)
        self.assertLessEqual(loaded.mood_valence, MOOD_VALENCE_BAND)
        self.assertLessEqual(loaded.rapport, 1.0)

    def test_good_turns_warm_mood_and_build_rapport_slowly(self):
        state = AffectState()
        for turn in range(20):
            state = observe_turn(
                state, arousal=0.3, valence=0.8, turn_ok=True, now_s=1000.0 + turn
            )
        self.assertGreater(state.mood_valence, 0.1)
        self.assertLessEqual(state.mood_valence, MOOD_VALENCE_BAND)
        self.assertAlmostEqual(0.4, state.rapport, places=2)
        # One bad turn does not erase a warm baseline.
        after_bad = observe_turn(state, arousal=0.0, valence=-1.0, turn_ok=False, now_s=1021.0)
        self.assertGreater(after_bad.mood_valence, 0.1)

    def test_rapport_relaxes_over_idle_days(self):
        state = AffectState(rapport=0.8, updated_at_s=1.0)
        state = observe_turn(
            state, arousal=0.0, valence=0.0, turn_ok=True, now_s=30.0 * 86400.0
        )
        self.assertLess(state.rapport, 0.4)

    def test_prompt_lines_stay_silent_near_neutral(self):
        self.assertEqual((), affect_prompt_lines(AffectState()))
        warm = AffectState(mood_valence=0.2, rapport=0.6)
        lines = affect_prompt_lines(warm)
        self.assertEqual(1, len(lines))
        self.assertIn("affect_baseline:", lines[0])
        self.assertIn("warm", lines[0])
        self.assertIn("familiar", lines[0])
        # Coarse words only: the line must not leak raw numbers for the model
        # to recite as fake telemetry.
        self.assertNotIn("0.", lines[0])


if __name__ == "__main__":
    unittest.main()
