import json
import tempfile
import unittest
from pathlib import Path

from hardware_simulator import (
    SIM_SCHEMA,
    VirtualStackchanHardware,
    full_audio_downlink_frames,
    run_many,
    run_simulation,
    write_outputs,
)


class HardwareSimulatorTests(unittest.TestCase):
    def test_reference_scenario_reaches_ready_with_mouth_frames(self):
        hardware = run_simulation("reference")
        report = hardware.report("reference")

        self.assertEqual("pass", report["status"], report["issues"])
        self.assertEqual("Ready", report["telemetry"]["bridge_state"])
        self.assertEqual("idle", report["telemetry"]["face_mode"])
        self.assertGreaterEqual(report["telemetry"]["speech_frames"], 5)
        self.assertGreater(report["telemetry"]["mouth_peak"], 0.5)
        self.assertEqual(0, report["telemetry"]["parse_errors"])

    def test_lan_text_scenario_exercises_local_bridge_path(self):
        hardware = run_simulation("lan-text")
        report = hardware.report("lan-text")

        self.assertEqual("pass", report["status"], report["issues"])
        self.assertTrue(report["telemetry"]["bridge_ready"])
        self.assertEqual("Ready", report["telemetry"]["bridge_state"])
        self.assertIn("Curiosity systems", report["telemetry"]["response_text"])

    def test_audio_downlink_counts_binary_stream_payload(self):
        hardware = run_simulation("audio-downlink")
        report = hardware.report("audio-downlink")

        self.assertEqual("pass", report["status"], report["issues"])
        self.assertEqual(1, report["telemetry"]["audio_streams_started"])
        self.assertEqual(1, report["telemetry"]["audio_streams_ended"])
        self.assertEqual(9, report["telemetry"]["audio_stream_bytes_expected"])
        self.assertEqual(9, report["telemetry"]["audio_stream_bytes_received"])
        self.assertEqual(3, report["telemetry"]["audio_stream_chunks_expected"])
        self.assertEqual(3, report["telemetry"]["audio_stream_chunks_received"])
        self.assertEqual(1, report["telemetry"]["speaker_playback_starts"])
        self.assertEqual(3, report["telemetry"]["speaker_frames_submitted"])
        self.assertGreater(report["telemetry"]["mouth_display_frames"], 0)

    def test_arrival_rehearsal_exercises_virtual_device_shell(self):
        hardware = run_simulation("arrival-rehearsal")
        report = hardware.report("arrival-rehearsal")
        telemetry = report["telemetry"]

        self.assertEqual("pass", report["status"], report["issues"])
        self.assertTrue(telemetry["display_ready"])
        self.assertGreater(telemetry["display_frames"], 0)
        self.assertEqual(telemetry["display_frames"], telemetry["display_label_frames"])
        self.assertLessEqual(telemetry["display_frame_gap_max_ms"], 40)
        self.assertEqual(5, telemetry["core_inputs"])
        self.assertGreaterEqual(telemetry["control_events"], 7)
        self.assertEqual(1, telemetry["speaker_playback_starts"])
        self.assertEqual(3, telemetry["speaker_frames_submitted"])
        self.assertGreater(telemetry["mouth_display_frames"], 0)
        self.assertEqual(2, telemetry["boot_count"])
        self.assertEqual(1, telemetry["power_cycles"])
        self.assertEqual("Ready", telemetry["bridge_state"])
        for mode in ("listen", "think", "react", "speak", "concern", "happy", "idle"):
            self.assertIn(mode, telemetry["modes_seen"])

    def test_bridge_kill_recovery_uses_offline_fallback_and_returns_ready(self):
        hardware = run_simulation("bridge-kill-recovery")
        report = hardware.report("bridge-kill-recovery")
        telemetry = report["telemetry"]

        self.assertEqual("pass", report["status"], report["issues"])
        self.assertEqual(1, telemetry["bridge_errors"])
        self.assertEqual(1, telemetry["offline_fallback_prompts"])
        self.assertEqual(1, telemetry["bridge_recoveries"])
        self.assertEqual("Ready", telemetry["bridge_state"])
        self.assertEqual("idle", telemetry["face_mode"])
        self.assertIn("error", telemetry["modes_seen"])
        self.assertEqual(1, telemetry["audio_streams_aborted"])
        self.assertGreaterEqual(telemetry["speech_frames"], 4)
        self.assertEqual(0, telemetry["parse_errors"])
        self.assertEqual(0, telemetry["timeouts"])
        self.assertTrue(any("intent=error" in line for line in hardware.serial_lines))
        self.assertTrue(any("bridge_closed" in line for line in hardware.serial_lines))

    def test_binary_without_audio_stream_fails(self):
        hardware = VirtualStackchanHardware()
        hardware.process(b"abc", at_ms=0)
        report = hardware.report("bad-binary")

        self.assertEqual("fail", report["status"])
        self.assertIn("binary_without_audio_stream", report["issues"])
        self.assertEqual(1, report["telemetry"]["parse_errors"])

    def test_truncated_audio_stream_fails(self):
        frames = full_audio_downlink_frames()
        broken = [frame for frame in frames if frame != b"ghi"]
        hardware = VirtualStackchanHardware()
        now_ms = 0
        for frame in broken:
            hardware.process(frame, at_ms=now_ms)
            now_ms += 20
        hardware.finish()
        report = hardware.report("truncated")

        self.assertEqual("fail", report["status"])
        self.assertIn("audio_stream_payload_bytes_mismatch", report["issues"])
        self.assertIn("audio_stream_payload_chunks_mismatch", report["issues"])

    def test_timeout_scenario_reports_expected_failure(self):
        hardware = run_simulation("timeout")
        report = hardware.report("timeout")

        self.assertEqual("fail", report["status"])
        self.assertIn("bridge_timeout", report["issues"])
        self.assertEqual(1, report["telemetry"]["timeouts"])

    def test_summary_and_output_files_are_written(self):
        with tempfile.TemporaryDirectory() as temp_dir:
            summary = write_outputs(Path(temp_dir), ["reference", "audio-downlink"])
            report_path = Path(temp_dir) / "hardware_simulation.json"
            markdown_path = Path(temp_dir) / "HARDWARE_SIMULATION.md"
            serial_path = Path(temp_dir) / "audio-downlink.serial.log"

            decoded = json.loads(report_path.read_text(encoding="utf-8"))
            self.assertTrue(markdown_path.exists())
            self.assertTrue(serial_path.exists())

        self.assertEqual("pass", summary["status"])
        self.assertEqual(SIM_SCHEMA, decoded["schema"])
        self.assertEqual("pass", decoded["status"])

    def test_run_many_fails_if_any_scenario_fails(self):
        summary = run_many(["reference", "timeout"])

        self.assertEqual("fail", summary["status"])
        self.assertEqual(["reference", "timeout"], [item["scenario"] for item in summary["scenarios"]])


if __name__ == "__main__":
    unittest.main()
