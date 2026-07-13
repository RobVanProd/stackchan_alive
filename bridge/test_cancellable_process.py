import sys
import tempfile
import threading
import time
import unittest
from pathlib import Path

BRIDGE_DIR = Path(__file__).resolve().parent
if str(BRIDGE_DIR) not in sys.path:
    sys.path.insert(0, str(BRIDGE_DIR))

from cancellation import CancellationToken, OperationCancelledError
from cancellable_process import ProcessTimeoutError, run_cancellable_process


class CancellableProcessTests(unittest.TestCase):
    def test_process_returns_binary_output_and_elapsed_time(self):
        command = f'"{sys.executable}" -c "import sys;sys.stdout.buffer.write(sys.stdin.buffer.read()[::-1])"'
        result = run_cancellable_process(command, input_data=b"stackchan", timeout_ms=2000)

        self.assertEqual(0, result.returncode)
        self.assertEqual(b"nahckcats", result.stdout)
        self.assertGreater(result.elapsed_ms, 0)

    def test_cancellation_stops_process_before_its_side_effect(self):
        with tempfile.TemporaryDirectory() as temp_dir:
            marker = Path(temp_dir) / "finished.txt"
            script = Path(temp_dir) / "slow.py"
            script.write_text(
                "import pathlib,sys,time\n"
                "time.sleep(3)\n"
                "pathlib.Path(sys.argv[1]).write_text('finished')\n",
                encoding="utf-8",
            )
            token = CancellationToken()
            timer = threading.Timer(0.12, token.cancel, args=("barge_in",))
            timer.start()
            started = time.perf_counter()
            try:
                with self.assertRaisesRegex(OperationCancelledError, "barge_in"):
                    run_cancellable_process(
                        f'"{sys.executable}" "{script}" "{marker}"',
                        input_data=b"",
                        timeout_ms=5000,
                        cancellation=token,
                    )
            finally:
                timer.cancel()

            self.assertLess(time.perf_counter() - started, 2.0)
            time.sleep(0.2)
            self.assertFalse(marker.exists())

    def test_timeout_is_distinct_from_cancellation(self):
        command = f'"{sys.executable}" -c "import time;time.sleep(2)"'
        with self.assertRaises(ProcessTimeoutError):
            run_cancellable_process(command, input_data=b"", timeout_ms=80)


if __name__ == "__main__":
    unittest.main()
