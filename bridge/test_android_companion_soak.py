import tempfile
import unittest
from pathlib import Path

from android_companion_soak import build_soak_report, write_outputs


def pass_probe(url, timeout, require_android):
    return {
        "status": "pass",
        "elapsed_ms": 8.0,
        "endpoint_hello": {
            "endpoint_id": "android-companion-test",
            "endpoint_kind": "android",
        },
        "issues": [],
    }


def fail_probe(url, timeout, require_android):
    return {
        "status": "fail",
        "issues": ["ProbeError: server closed before sending a WebSocket frame"],
    }


class FakeClock:
    def __init__(self):
        self.now = 0.0
        self.sleeps = []

    def monotonic(self):
        return self.now

    def sleep(self, seconds):
        self.sleeps.append(seconds)
        self.now += seconds


class AndroidCompanionSoakTest(unittest.TestCase):
    def test_soak_passes_when_all_samples_pass(self):
        clock = FakeClock()

        report = build_soak_report(
            "ws://127.0.0.1:8765/bridge",
            duration_seconds=2.0,
            interval_seconds=1.0,
            timeout=0.1,
            require_android=True,
            min_success_rate=1.0,
            max_failures=0,
            sleep_fn=clock.sleep,
            monotonic_fn=clock.monotonic,
            probe_fn=pass_probe,
        )

        self.assertEqual("pass", report["status"])
        self.assertEqual(3, report["sample_count"])
        self.assertEqual(1.0, report["success_rate"])
        self.assertEqual([1.0, 1.0], clock.sleeps)

    def test_soak_fails_when_any_strict_sample_fails(self):
        report = build_soak_report(
            "ws://127.0.0.1:8765/bridge",
            duration_seconds=0.0,
            interval_seconds=1.0,
            timeout=0.1,
            require_android=True,
            min_success_rate=1.0,
            max_failures=0,
            probe_fn=fail_probe,
        )

        self.assertEqual("fail", report["status"])
        self.assertEqual(1, report["failed_count"])
        self.assertIn("failed samples 1 exceeded max failures 0", report["issues"])
        self.assertIn("server closed", report["issues"][-1])

    def test_write_outputs_include_logcat_follow_up(self):
        report = build_soak_report(
            "ws://127.0.0.1:8765/bridge",
            duration_seconds=0.0,
            interval_seconds=1.0,
            timeout=0.1,
            require_android=True,
            min_success_rate=1.0,
            max_failures=0,
            probe_fn=pass_probe,
        )

        with tempfile.TemporaryDirectory() as temp_dir:
            json_path, md_path = write_outputs(report, Path(temp_dir))
            self.assertTrue(json_path.exists())
            text = md_path.read_text(encoding="utf-8")

        self.assertIn("Android Companion Screen-Off Soak", text)
        self.assertIn("RUN_ANDROID_LOGCAT_CAPTURE.cmd", text)
        self.assertIn("android-companion-test", text)


if __name__ == "__main__":
    unittest.main()
