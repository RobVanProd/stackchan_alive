import unittest
import sys
from pathlib import Path

BRIDGE_DIR = Path(__file__).resolve().parent
if str(BRIDGE_DIR) not in sys.path:
    sys.path.insert(0, str(BRIDGE_DIR))

from stt_supervisor import SttServerSupervisor, SttSupervisorConfig


class SttServerSupervisorTests(unittest.TestCase):
    def test_two_failed_probes_trigger_one_verified_restart(self):
        outcomes = iter([False, False, True])
        restarts: list[tuple[str, float]] = []

        def probe(_url: str, _timeout: float) -> bool:
            return next(outcomes)

        def restart(command: str, timeout: float) -> int:
            restarts.append((command, timeout))
            return 1234

        supervisor = SttServerSupervisor(
            SttSupervisorConfig(
                server_url="http://127.0.0.1:5061",
                restart_command="restart-stt",
                failure_threshold=2,
            ),
            health_probe=probe,
            restart_runner=restart,
        )

        first = supervisor.check_once()
        second = supervisor.check_once()

        self.assertFalse(first["healthy"])
        self.assertTrue(second["healthy"])
        self.assertEqual(1, second["restarts"])
        self.assertEqual(2, second["failures"])
        self.assertEqual([("restart-stt", 45.0)], restarts)

    def test_unsupervised_dependency_reports_failure_without_restart(self):
        supervisor = SttServerSupervisor(
            SttSupervisorConfig(server_url="http://127.0.0.1:5061"),
            health_probe=lambda _url, _timeout: False,
        )

        status = supervisor.check_once()

        self.assertFalse(status["healthy"])
        self.assertFalse(status["supervised"])
        self.assertEqual(0, status["restarts"])
        self.assertNotIn("command", status)

    def test_failed_restart_is_bounded_and_aggregate_only(self):
        supervisor = SttServerSupervisor(
            SttSupervisorConfig(
                server_url="http://127.0.0.1:5061",
                restart_command="private restart details",
                failure_threshold=1,
            ),
            health_probe=lambda _url, _timeout: False,
            restart_runner=lambda _command, _timeout: 0,
        )

        status = supervisor.check_once()

        self.assertFalse(status["healthy"])
        self.assertEqual(1, status["restartFailures"])
        self.assertIn("OSError", status["lastError"])
        self.assertNotIn("private restart details", str(status))


if __name__ == "__main__":
    unittest.main()
