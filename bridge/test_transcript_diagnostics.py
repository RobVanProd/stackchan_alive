import unittest
import sys
from pathlib import Path

BRIDGE_DIR = Path(__file__).resolve().parent
if str(BRIDGE_DIR) not in sys.path:
    sys.path.insert(0, str(BRIDGE_DIR))

from transcript_diagnostics import (
    expected_transcript_metrics,
    normalized_tokens,
    validate_critical_tokens,
    validate_expected_text,
    word_edit_distance,
)


class TranscriptDiagnosticTests(unittest.TestCase):
    def test_normalized_match_ignores_case_spacing_and_punctuation(self):
        metrics = expected_transcript_metrics(
            "A dog and a cat: are they the same animal?",
            "a DOG and a cat are they the same animal",
            critical_tokens=("dog", "cat", "same", "animal"),
        )

        self.assertFalse(metrics["stt_expected_exact_match"])
        self.assertTrue(metrics["stt_expected_normalized_match"])
        self.assertEqual(10, metrics["stt_expected_token_count"])
        self.assertEqual(10, metrics["stt_recognized_token_count"])
        self.assertEqual(0, metrics["stt_word_edit_distance"])
        self.assertEqual(0.0, metrics["stt_word_error_rate"])
        self.assertEqual(4, metrics["stt_critical_expected_token_hits"])
        self.assertEqual(1.0, metrics["stt_critical_expected_token_coverage"])
        self.assertNotIn("dog", str(metrics).lower())

    def test_partial_transcript_reports_wer_and_critical_coverage_without_text(self):
        metrics = expected_transcript_metrics(
            "wait until I finish then compare dog and cat",
            "wait until I finish",
            critical_tokens=("finish", "dog", "cat"),
        )

        self.assertEqual(9, metrics["stt_expected_token_count"])
        self.assertEqual(4, metrics["stt_recognized_token_count"])
        self.assertEqual(5, metrics["stt_word_edit_distance"])
        self.assertEqual(0.5556, metrics["stt_word_error_rate"])
        self.assertEqual(1, metrics["stt_critical_expected_token_hits"])
        self.assertEqual(0.3333, metrics["stt_critical_expected_token_coverage"])
        self.assertFalse(any(isinstance(value, (list, tuple, set)) for value in metrics.values()))

    def test_no_transcript_is_full_deletion(self):
        metrics = expected_transcript_metrics("one two three", "")

        self.assertEqual(3, metrics["stt_word_edit_distance"])
        self.assertEqual(1.0, metrics["stt_word_error_rate"])
        self.assertEqual(0, metrics["stt_recognized_token_count"])
        self.assertIsNone(metrics["stt_critical_expected_token_coverage"])

    def test_critical_tokens_must_be_single_tokens_present_in_expectation(self):
        self.assertEqual(
            ("dog", "cat"),
            validate_critical_tokens("Dog and cat", ("DOG", "cat", "dog")),
        )
        with self.assertRaises(ValueError):
            validate_critical_tokens("Dog and cat", ("same animal",))
        with self.assertRaises(ValueError):
            validate_critical_tokens("Dog and cat", ("bird",))

    def test_expected_text_requires_a_bounded_word_bearing_phrase(self):
        self.assertEqual("say this", validate_expected_text("say this"))
        for invalid in ("", "   ", "...", "x" * 501):
            with self.subTest(invalid=invalid[:10]):
                with self.assertRaises(ValueError):
                    validate_expected_text(invalid)

    def test_word_edit_distance_covers_insert_delete_and_replace(self):
        self.assertEqual(1, word_edit_distance(("a", "b"), ("a", "x", "b")))
        self.assertEqual(1, word_edit_distance(("a", "b"), ("a",)))
        self.assertEqual(1, word_edit_distance(("a", "b"), ("a", "x")))
        self.assertEqual(("can't", "stop"), normalized_tokens("CAN\u2019T_stop"))


if __name__ == "__main__":
    unittest.main()
