import unittest

from ltr553_calibration import accepted_sample, analyze_samples


def samples(values):
    return [
        {"proximity_raw": value, "ambient_combined_raw": 400 + index, "read_failures": 0}
        for index, value in enumerate(values)
    ]


class Ltr553CalibrationTests(unittest.TestCase):
    def test_debug_sample_requires_ready_unsaturated_adapter(self):
        sample, reason = accepted_sample(
            {
                "compiled_enable_proximity_ambient": True,
                "proximity_ambient_ready": True,
                "proximity_saturated": False,
                "proximity_raw": 345,
                "ambient_combined_raw": 1234,
                "proximity_ambient_read_failures": 2,
                "proximity_ambient_consecutive_failures": 0,
            }
        )
        rejected, rejected_reason = accepted_sample(
            {
                "compiled_enable_proximity_ambient": True,
                "proximity_ambient_ready": True,
                "proximity_saturated": True,
                "proximity_raw": 2047,
            }
        )

        self.assertEqual("", reason)
        self.assertEqual(345, sample["proximity_raw"])
        self.assertIsNone(rejected)
        self.assertEqual("proximity_saturated", rejected_reason)

    def test_analysis_emits_ordered_hysteresis_only_for_separated_samples(self):
        result = analyze_samples(
            samples(list(range(90, 130)) + [135] * 10),
            samples(list(range(350, 390)) + [400] * 10),
            min_samples=30,
        )

        self.assertTrue(result["ok"], result["issues"])
        self.assertGreater(result["suggested"]["enter_threshold"], result["suggested"]["exit_threshold"])
        self.assertGreater(result["suggested"]["exit_threshold"], result["far"]["proximity_p90"])
        self.assertLess(result["suggested"]["enter_threshold"], result["near"]["proximity_p10"])
        self.assertFalse(result["automatic_firmware_change"])

    def test_analysis_rejects_overlap_and_short_captures(self):
        overlap = analyze_samples(samples([100] * 40), samples([95] * 40), min_samples=30)
        short = analyze_samples(samples([10] * 5), samples([500] * 5), min_samples=30)

        self.assertFalse(overlap["ok"])
        self.assertIn("near_far_distributions_overlap", overlap["issues"])
        self.assertFalse(short["ok"])
        self.assertIn("far_samples_insufficient", short["issues"])
        self.assertIn("near_samples_insufficient", short["issues"])

    def test_analysis_rejects_peripheral_failure_growth(self):
        far = samples([100] * 40)
        near = samples([500] * 40)
        near[-1]["read_failures"] = 1

        result = analyze_samples(far, near, min_samples=30)

        self.assertFalse(result["ok"])
        self.assertIn("near_read_failures_increased", result["issues"])


if __name__ == "__main__":
    unittest.main()
