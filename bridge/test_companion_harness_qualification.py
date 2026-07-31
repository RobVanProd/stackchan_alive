import unittest

from companion_harness_qualification import (
    CONTROLS,
    complaint_ids,
    matrix_snapshot,
    reference_exists,
    structural_errors,
)


class CompanionHarnessQualificationTests(unittest.TestCase):
    def test_matrix_covers_100_complaints_and_exactly_20_ranked_controls(self):
        self.assertEqual(100, len(complaint_ids()))
        self.assertEqual(100, len(set(complaint_ids())))
        self.assertEqual(list(range(1, 21)), [control.rank for control in CONTROLS])
        self.assertEqual(20, len({control.cluster for control in CONTROLS}))
        self.assertEqual((), structural_errors())

    def test_every_control_names_at_least_one_existing_regression_test(self):
        for control in CONTROLS:
            self.assertTrue(control.tests, control.cluster)
            for reference in control.tests:
                self.assertTrue(reference_exists(reference), reference)

    def test_snapshot_is_machine_readable_and_complete(self):
        snapshot = matrix_snapshot()
        self.assertTrue(snapshot["ok"])
        self.assertEqual(100, snapshot["complaint_count"])
        self.assertEqual(20, snapshot["control_count"])
        self.assertGreaterEqual(snapshot["unique_test_count"], 20)
        self.assertEqual(20, len(snapshot["controls"]))


if __name__ == "__main__":
    unittest.main()
