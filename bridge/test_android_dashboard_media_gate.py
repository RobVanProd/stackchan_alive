import json
import shutil
import subprocess
import tempfile
from pathlib import Path
import unittest


ROOT = Path(__file__).resolve().parents[1]
PROGRESS_SCRIPT = ROOT / "tools" / "check_hardware_evidence_progress.ps1"
REQUIRED_DASHBOARD_NOTES = (
    "Android dashboard connected state; robot identity; firmware/version signal; "
    "last bridge frame; active brain owner; foreground service state"
)


def _powershell() -> str | None:
    return shutil.which("pwsh") or shutil.which("powershell")


def _write(path: Path, text: str) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(text, encoding="utf-8")


def _display_log() -> str:
    return "\n".join(
        [
            "[boot] stackchan_alive mode=display_only serial=v1",
            "[display] M5 display renderer ready",
            "[servo] dry-run mode",
            "[display] frame_ms_avg=16 fps_window=60 frame_budget_us=33333 slow_frames=0",
            "[face] mode=1 blink_count=1 saccade_count=1 gesture_active=0 speech_active=0 speech_env=idle",
            "[control] command=mode_listen at_ms=100",
            "[speech] seq=1 at_ms=120 intent=idle priority=1 earcon=none earcon_delay_ms=0 text=hello",
            "[system] heap_free=100000 heap_min=90000 stack_loop_hwm=100 stack_motion_hwm=100 stack_face_hwm=100 stack_intent_hwm=100",
        ]
    )


def _packet(root: Path) -> None:
    _write(root / "logs" / "package_verify.log", "Release package verified:\n")
    _write(root / "logs" / "display_only_serial.log", _display_log())
    _write(root / "photos" / "generic-bench-photo.jpg", "not-empty")
    _write(
        root / "android" / "companion-probe" / "android_companion_probe.json",
        json.dumps(
            {
                "schema": "stackchan.android-companion-probe.v1",
                "status": "pass",
                "issues": [],
            }
        ),
    )
    _write(
        root / "metadata.json",
        json.dumps(
            {
                "androidCompanionProbes": {
                    "companionProbeReport": "android/companion-probe/android_companion_probe.json"
                }
            }
        ),
    )


@unittest.skipIf(_powershell() is None, "PowerShell is required for hardware evidence progress tests")
class AndroidDashboardMediaGateTest(unittest.TestCase):
    def run_progress(self, evidence_root: Path) -> dict:
        status_path = evidence_root / "BENCH_STATUS.json"
        result = subprocess.run(
            [
                _powershell(),
                "-NoProfile",
                "-ExecutionPolicy",
                "Bypass",
                "-File",
                str(PROGRESS_SCRIPT),
                "-EvidenceRoot",
                str(evidence_root),
                "-ReportPath",
                str(status_path),
            ],
            cwd=ROOT,
            text=True,
            capture_output=True,
        )
        self.assertEqual(result.returncode, 2, result.stdout + result.stderr)
        return json.loads(status_path.read_text(encoding="utf-8-sig"))

    def test_android_probe_requires_dashboard_media_notes(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            evidence_root = Path(tmp)
            _packet(evidence_root)

            status = self.run_progress(evidence_root)

        self.assertEqual(
            status["nextAction"],
            "Import the Android connected-dashboard screenshot with the required evidence notes.",
        )
        self.assertIn("RUN_ADD_MEDIA.cmd -Type Photo -Notes", status["nextCommand"])
        self.assertIn(REQUIRED_DASHBOARD_NOTES, status["nextCommand"])
        self.assertTrue(
            any("media_manifest.json is missing the connected-dashboard" in finding for finding in status["findings"])
        )

    def test_matching_dashboard_media_notes_clear_android_dashboard_finding(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            evidence_root = Path(tmp)
            _packet(evidence_root)
            _write(
                evidence_root / "media_manifest.json",
                json.dumps(
                    {
                        "schema": "stackchan.hardware-media-manifest.v1",
                        "entries": [
                            {
                                "kind": "photo",
                                "relativePath": "photos/generic-bench-photo.jpg",
                                "notes": REQUIRED_DASHBOARD_NOTES,
                            }
                        ],
                    }
                ),
            )

            status = self.run_progress(evidence_root)

        self.assertFalse(
            any("Android dashboard connected state" in finding for finding in status["findings"]),
            status["findings"],
        )
        self.assertNotEqual(
            status["nextAction"],
            "Import the Android connected-dashboard screenshot with the required evidence notes.",
        )


if __name__ == "__main__":
    unittest.main()
