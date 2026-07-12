import unittest
from datetime import datetime, timedelta, timezone

from bridge_memory import BridgeMemory
from trusted_facts_smoke import PASSTHROUGH_CASES, ROUTED_CASES, build_report


class TrustedFactsSmokeTests(unittest.TestCase):
    def test_report_proves_silent_model_bypass_and_passthrough_guards(self):
        now = datetime(2026, 7, 12, 14, 5, tzinfo=timezone(timedelta(hours=-4), name="EDT"))
        report = build_report(BridgeMemory(preferred_name="Rob"), now=now)

        self.assertTrue(report["ready"], report["issues"])
        self.assertEqual(0, report["modelInvocations"])
        self.assertFalse(report["audioPlayed"])
        self.assertEqual(len(ROUTED_CASES), report["routedCases"])
        self.assertEqual(len(PASSTHROUGH_CASES), report["passthroughCases"])
        self.assertEqual({"local_clock": 7, "memory_recall": 2}, report["routes"])
        self.assertTrue(report["preferredNamePresent"])

    def test_unknown_preferred_name_is_an_honest_ready_response(self):
        report = build_report(BridgeMemory())

        self.assertTrue(report["ready"], report["issues"])
        self.assertFalse(report["preferredNamePresent"])


if __name__ == "__main__":
    unittest.main()
