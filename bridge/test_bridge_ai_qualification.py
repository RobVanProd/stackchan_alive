import hashlib
import json
import tempfile
import unittest
from pathlib import Path

from bridge.bridge_ai_qualification import (
    PR216_FIRMWARE_BASELINE_COMMIT,
    check_evidence,
)


class BridgeAiQualificationTests(unittest.TestCase):
    def _write_ready_fixture(self, root: Path) -> None:
        firmware_acceptance = (
            f"Accepted source commit `{'d' * 40}`, "
            f"firmware SHA-256 `{'b' * 64}`."
        )
        firmware_acceptance_bytes = firmware_acceptance.encode("utf-8")
        session = {
            "schema": "stackchan.bridge-ai-supervised-session.v3",
            "mode": "bridge-ai-supervised",
            "sourceCommit": "a" * 40,
            "sourceWorktreeClean": True,
            "packageCommit": "a" * 40,
            "packageZipPath": "C:/candidate.zip",
            "packageSha256": "c" * 64,
            "packageVerified": True,
            "expectedFirmwareSha256": "b" * 64,
            "expectedFirmwareSourceCommit": "d" * 40,
            "requiredFirmwareBaselineCommit": PR216_FIRMWARE_BASELINE_COMMIT,
            "firmwareAcceptanceEvidence": "accepted-main-firmware-status.md",
            "firmwareAcceptanceBase": "origin/main",
            "firmwareAcceptanceEvidenceSha256": hashlib.sha256(
                firmware_acceptance_bytes
            ).hexdigest(),
            "runtimeSourceCommit": "a" * 40,
            "runtimeSourceRoot": "C:/stackchan_alive",
            "runtimeBridgePid": 1234,
            "operatorPresent": True,
            "motionOffConfirmed": True,
            "minReplyWindows": 100,
        }
        before_debug = {
            "ota_expected_sha256": "b" * 64,
            "ota_current_app_confirmed": True,
            "network_state": "connected",
            "bridge_state": "ready",
            "motion_enabled": False,
            "servo_rail_enabled": False,
            "servo_torque_enabled": False,
            "display_window_max_frame_us": 20_000,
            "conversation_reply_window_started": 10,
            "bridge_uplink_errors": 4,
            "bridge_uplink_queue_failures": 2,
            "mww_uplink_dropped": 1,
            "mww_uplink_submit_failed": 2,
            "wake_cue_captures_failed": 0,
            "bridge_network_writer_frame_buffered": False,
            "bridge_network_writer_text_queued": 11,
            "bridge_network_writer_binary_queued": 10,
            "bridge_network_writer_text_dropped": 0,
            "bridge_network_writer_binary_dropped": 0,
            "bridge_network_writer_last_error": "",
            "bridge_reply_windows_rejected": 1,
            "conversation_reply_window_rejected": 1,
            "bridge_downlink_playback_errors": 3,
            "bridge_audio_safety_stops": 1,
            "bridge_audio_disconnect_stops": 1,
            "bridge_audio_watchdog_stops": 1,
            "speaker_stream_play_raw_failed": 2,
            "speaker_stream_forced_stops": 1,
            "bridge_audio_remote_stop_requests": 2,
            "compiled_enable_camera": 1,
            "compiled_enable_camera_host_vision": 1,
            "camera_ready": True,
            "camera_active": True,
            "camera_capture_ready": True,
            "camera_host_frame_requests": 20,
            "camera_host_frame_failures": 1,
            "camera_host_target_updates": 20,
            "camera_host_auth_failures": 0,
            "camera_face_batches": 20,
            "camera_faces_observed": 5,
            "camera_events": 4,
        }
        after_debug = {
            **before_debug,
            "display_window_max_frame_us": 30_000,
            "conversation_reply_window_started": 110,
            "bridge_audio_remote_stop_requests": 3,
            "audio_stream_active": False,
            "bridge_downlink_playback_awaiting_drain": False,
            "speaker_channel_state": 0,
            "camera_host_frame_requests": 40,
            "camera_host_target_updates": 40,
            "camera_face_batches": 40,
            "camera_faces_observed": 10,
            "camera_events": 9,
        }
        before_dashboard = {
            "bridge": {"conversationV2Enabled": True},
            "behavior": {
                "initiative": {"available": True, "enabled": True},
                "roomObservation": {
                    "available": True,
                    "configured": True,
                    "enabled": True,
                },
            },
        }
        after_dashboard = {
            "behavior": {
                "initiative": {
                    "ignoredOpeners": 2,
                    "backoffRemainingSeconds": 20_000,
                },
                "roomObservation": {
                    "observations": 2,
                    "failures": 0,
                    "enabled": False,
                    "personCount": None,
                    "ageSeconds": None,
                },
            }
        }
        observations = {
            "oneWakeMultiTurn": True,
            "conversationNatural": True,
            "echoFree": True,
            "exitPhraseClosed": True,
            "silenceClosed": True,
            "bargeInStoppedAudio": True,
            "bridgeLossLocalRecovery": True,
            "cleanCompleteAudio": True,
            "researchGrounded": True,
            "visualContextGrounded": True,
            "grayscaleLimitationTruthful": True,
            "memoryRecallAccurate": True,
            "noUnrelatedMemoryHijack": True,
            "initiativeNatural": True,
            "initiativeRateFloor": True,
            "initiativeIgnoredBackoff": True,
            "initiativeNightSuppressed": True,
            "personNoticingGrounded": True,
            "roomContextGrounded": True,
            "roomOffCleared": True,
            "noFramePersisted": True,
            "echoWindowsObserved": 100,
        }
        runtime_manifest = {
            "schema": "stackchan.pc-brain-runtime.v1",
            "sourceCommit": "a" * 40,
            "sourceRoot": "C:/stackchan_alive",
            "sourceWorktreeClean": True,
            "bridgePid": 1234,
        }
        after_runtime = {
            "schema": "stackchan.bridge-ai-runtime-after.v1",
            "sourceCommit": "a" * 40,
            "sourceWorktreeClean": True,
            "listenerPid": 1234,
            "packageSha256": "c" * 64,
            "runtimeManifest": runtime_manifest,
        }
        for name, payload in (
            ("session.json", session),
            ("before-debug.json", before_debug),
            ("after-debug.json", after_debug),
            ("before-dashboard.json", before_dashboard),
            ("after-dashboard.json", after_dashboard),
            ("runtime-manifest.json", runtime_manifest),
            ("after-runtime.json", after_runtime),
            ("operator-observations.json", observations),
        ):
            (root / name).write_text(json.dumps(payload), encoding="utf-8")
        (root / "accepted-main-firmware-status.md").write_bytes(
            firmware_acceptance_bytes
        )

        records = [
            {
                "schema": "stackchan.conversation-event.v1",
                "event": "wake",
                "actions": ["session_started", "open_capture"],
                "conversation_turns": 0,
            },
            {
                "schema": "stackchan.conversation-event.v1",
                "event": "reply_pending",
                "actions": ["playback_complete", "acoustic_tail"],
                "conversation_turns": 1,
            },
            {
                "schema": "stackchan.conversation-event.v1",
                "event": "reply_window_open",
                "actions": ["open_capture"],
                "conversation_turns": 1,
            },
            {
                "schema": "stackchan.conversation-event.v1",
                "event": "barge_in",
                "actions": ["cancel_generation", "cancel_playback", "open_capture"],
                "conversation_turns": 2,
            },
            {
                "schema": "stackchan.conversation-event.v1",
                "event": "exit_phrase",
                "actions": ["session_closing"],
                "conversation_turns": 2,
            },
            {
                "schema": "stackchan.conversation-event.v1",
                "event": "reply_timeout",
                "actions": ["session_closing"],
                "conversation_turns": 1,
            },
            {
                "schema": "stackchan.conversation-event.v1",
                "event": "bridge_lost",
                "actions": ["session_closed"],
                "conversation_turns": 0,
            },
        ]
        for index in range(3):
            record = {
                "schema": "stackchan.lan-turn-summary.v1",
                "latency_schema": "stackchan.conversation-latency.v1",
                "latency_first_audio_ms": 2_500 + index * 100,
                "latency_host_reaction_ms": 1,
                "latency_text_ready_ms": 1_800,
                "latency_turn_total_ms": 5_000,
                "latency_tts_render_rtf": 0.5,
                "latency_gate_host_reaction_under_300": True,
                "latency_gate_first_audio_under_3000": True,
                "latency_gate_render_faster_than_realtime": True,
                "latency_gate_zero_truncation": True,
                "tts_streaming": True,
                "tts_downlink_pacing_headroom_ms": 58.0,
                "tts_downlink_pacing_safe": True,
            }
            if index == 0:
                record.update(
                    {
                        "research_tool": "web_search",
                        "research_source_urls": ["https://example.com/fact"],
                        "research_error": "",
                    }
                )
            elif index == 1:
                record.update(
                    {
                        "visual_routing": "on_demand_observation",
                        "visual_observation_status": "fresh",
                    }
                )
            else:
                record.update(
                    {
                        "visual_routing": "grayscale_color_limit",
                        "runner_command_source": "local_grayscale_limit",
                    }
                )
            records.append(record)
        records.append(
            {
                "schema": "stackchan.lan-turn-summary.v1",
                "runner_command_source": "trusted_memory_recall",
                "local_fact_tool": "memory_recall",
            }
        )
        records.extend(
            [
                {
                    "schema": "stackchan.initiative-turn.v1",
                    "event": "initiative_spoken",
                    "generated_at": "2026-07-24T12:00:00Z",
                },
                {
                    "schema": "stackchan.initiative-turn.v1",
                    "event": "initiative_spoken",
                    "generated_at": "2026-07-24T12:10:00Z",
                },
            ]
        )
        (root / "turns.jsonl").write_text(
            "\n".join(json.dumps(record) for record in records) + "\n",
            encoding="utf-8",
        )

    def test_complete_evidence_is_ready(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            root = Path(temp_dir)
            self._write_ready_fixture(root)

            report = check_evidence(root)

        self.assertEqual("bridge-ai-supervised-ready", report["status"])
        self.assertEqual(0, report["failed"])
        self.assertEqual(0, report["pending"])

    def test_missing_operator_confirmation_stays_pending(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            root = Path(temp_dir)
            self._write_ready_fixture(root)
            observations = json.loads(
                (root / "operator-observations.json").read_text(encoding="utf-8")
            )
            del observations["cleanCompleteAudio"]
            (root / "operator-observations.json").write_text(
                json.dumps(observations),
                encoding="utf-8",
            )

            report = check_evidence(root)

        self.assertEqual("bridge-ai-supervised-pending", report["status"])
        self.assertEqual(0, report["failed"])
        self.assertEqual(1, report["pending"])

    def test_accepted_main_firmware_mismatch_fails_exact_gate(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            root = Path(temp_dir)
            self._write_ready_fixture(root)
            session = json.loads((root / "session.json").read_text(encoding="utf-8"))
            session["expectedFirmwareSha256"] = "d" * 64
            (root / "session.json").write_text(json.dumps(session), encoding="utf-8")

            report = check_evidence(root)

        firmware = next(
            check
            for check in report["checks"]
            if check["id"] == "accepted-main-firmware-exact"
        )
        self.assertEqual("bridge-ai-supervised-not-ready", report["status"])
        self.assertEqual("fail", firmware["status"])

    def test_unrecorded_firmware_source_commit_fails_provenance_gate(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            root = Path(temp_dir)
            self._write_ready_fixture(root)
            session = json.loads((root / "session.json").read_text(encoding="utf-8"))
            session["expectedFirmwareSourceCommit"] = "e" * 40
            (root / "session.json").write_text(json.dumps(session), encoding="utf-8")

            report = check_evidence(root)

        provenance = next(
            check
            for check in report["checks"]
            if check["id"] == "accepted-main-firmware-provenance"
        )
        self.assertEqual("bridge-ai-supervised-not-ready", report["status"])
        self.assertEqual("fail", provenance["status"])

    def test_pre_pr216_firmware_baseline_fails_provenance_gate(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            root = Path(temp_dir)
            self._write_ready_fixture(root)
            session = json.loads((root / "session.json").read_text(encoding="utf-8"))
            session["requiredFirmwareBaselineCommit"] = "e" * 40
            (root / "session.json").write_text(json.dumps(session), encoding="utf-8")

            report = check_evidence(root)

        provenance = next(
            check
            for check in report["checks"]
            if check["id"] == "accepted-main-firmware-provenance"
        )
        self.assertEqual("bridge-ai-supervised-not-ready", report["status"])
        self.assertEqual("fail", provenance["status"])

    def test_restarted_bridge_fails_runtime_binding(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            root = Path(temp_dir)
            self._write_ready_fixture(root)
            after_runtime = json.loads(
                (root / "after-runtime.json").read_text(encoding="utf-8")
            )
            after_runtime["listenerPid"] = 5678
            (root / "after-runtime.json").write_text(
                json.dumps(after_runtime),
                encoding="utf-8",
            )

            report = check_evidence(root)

        runtime = next(
            check for check in report["checks"] if check["id"] == "bridge-runtime-stable"
        )
        self.assertEqual("bridge-ai-supervised-not-ready", report["status"])
        self.assertEqual("fail", runtime["status"])

    def test_persisted_room_frame_fails_privacy_gate(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            root = Path(temp_dir)
            self._write_ready_fixture(root)
            (root / "room-frame.pgm").write_bytes(b"P5\n1 1\n255\n\x00")

            report = check_evidence(root)

        self.assertEqual("bridge-ai-supervised-not-ready", report["status"])
        privacy = next(
            check
            for check in report["checks"]
            if check["id"] == "evidence-has-no-room-frames"
        )
        self.assertEqual("fail", privacy["status"])

    def test_camera_frames_without_host_targets_fail_vision_gate(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            root = Path(temp_dir)
            self._write_ready_fixture(root)
            after = json.loads((root / "after-debug.json").read_text(encoding="utf-8"))
            before = json.loads((root / "before-debug.json").read_text(encoding="utf-8"))
            for key in (
                "camera_host_target_updates",
                "camera_face_batches",
                "camera_faces_observed",
                "camera_events",
            ):
                after[key] = before[key]
            (root / "after-debug.json").write_text(json.dumps(after), encoding="utf-8")

            report = check_evidence(root)

        vision = next(
            check for check in report["checks"] if check["id"] == "robot-host-vision-advancing"
        )
        self.assertEqual("bridge-ai-supervised-not-ready", report["status"])
        self.assertEqual("fail", vision["status"])

    def test_late_audio_protocol_event_fails_order_gate(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            root = Path(temp_dir)
            self._write_ready_fixture(root)
            with (root / "turns.jsonl").open("a", encoding="utf-8") as handle:
                handle.write(
                    json.dumps(
                        {
                            "schema": "stackchan.audio-protocol-event.v1",
                            "code": "audio_without_utterance",
                            "payload_bytes": 1600,
                        }
                    )
                    + "\n"
                )

            report = check_evidence(root)

        audio_order = next(
            check for check in report["checks"] if check["id"] == "host-audio-order-clean"
        )
        self.assertEqual("bridge-ai-supervised-not-ready", report["status"])
        self.assertEqual("fail", audio_order["status"])

    def test_missing_cited_research_turn_fails_route_gate(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            root = Path(temp_dir)
            self._write_ready_fixture(root)
            records = [
                json.loads(line)
                for line in (root / "turns.jsonl").read_text(encoding="utf-8").splitlines()
            ]
            for record in records:
                record.pop("research_source_urls", None)
            (root / "turns.jsonl").write_text(
                "\n".join(json.dumps(record) for record in records) + "\n",
                encoding="utf-8",
            )

            report = check_evidence(root)

        research = next(
            check
            for check in report["checks"]
            if check["id"] == "host-research-route-exercised"
        )
        self.assertEqual("bridge-ai-supervised-not-ready", report["status"])
        self.assertEqual("fail", research["status"])

    def test_unsafe_downlink_pacing_fails_candidate_gate(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            root = Path(temp_dir)
            self._write_ready_fixture(root)
            records = [
                json.loads(line)
                for line in (root / "turns.jsonl").read_text(encoding="utf-8").splitlines()
            ]
            audio_turn = next(
                record
                for record in records
                if record.get("schema") == "stackchan.lan-turn-summary.v1"
            )
            audio_turn["tts_downlink_pacing_headroom_ms"] = 18.0
            audio_turn["tts_downlink_pacing_safe"] = False
            (root / "turns.jsonl").write_text(
                "\n".join(json.dumps(record) for record in records) + "\n",
                encoding="utf-8",
            )

            report = check_evidence(root)

        pacing = next(
            check for check in report["checks"] if check["id"] == "host-audio-pacing-safe"
        )
        self.assertEqual("bridge-ai-supervised-not-ready", report["status"])
        self.assertEqual("fail", pacing["status"])

    def test_unrecovered_response_wire_event_fails_candidate_gate(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            root = Path(temp_dir)
            self._write_ready_fixture(root)
            with (root / "turns.jsonl").open("a", encoding="utf-8") as handle:
                handle.write(
                    json.dumps(
                        {
                            "schema": "stackchan.response-wire-event.v1",
                            "code": "response_unclosed",
                            "seq": 42,
                            "active_seq": 42,
                            "recovered": False,
                        }
                    )
                    + "\n"
                )

            report = check_evidence(root)

        response_wire = next(
            check for check in report["checks"] if check["id"] == "host-response-wire-clean"
        )
        self.assertEqual("bridge-ai-supervised-not-ready", report["status"])
        self.assertEqual("fail", response_wire["status"])

    def test_recovered_cancelled_response_keeps_wire_gate_clean(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            root = Path(temp_dir)
            self._write_ready_fixture(root)
            with (root / "turns.jsonl").open("a", encoding="utf-8") as handle:
                handle.write(
                    json.dumps(
                        {
                            "schema": "stackchan.response-wire-event.v1",
                            "code": "response_forced_closed",
                            "seq": 42,
                            "active_seq": None,
                            "recovered": True,
                        }
                    )
                    + "\n"
                )

            report = check_evidence(root)

        response_wire = next(
            check for check in report["checks"] if check["id"] == "host-response-wire-clean"
        )
        self.assertEqual("pass", response_wire["status"])

    def test_missing_writer_telemetry_fails_candidate_gate(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            root = Path(temp_dir)
            self._write_ready_fixture(root)
            for name in ("before-debug.json", "after-debug.json"):
                path = root / name
                debug = json.loads(path.read_text(encoding="utf-8"))
                del debug["bridge_network_writer_binary_dropped"]
                path.write_text(json.dumps(debug), encoding="utf-8")

            report = check_evidence(root)

        telemetry = next(
            check
            for check in report["checks"]
            if check["id"] == "robot-writer-telemetry"
        )
        self.assertEqual("bridge-ai-supervised-not-ready", report["status"])
        self.assertEqual("fail", telemetry["status"])

    def test_new_mww_submit_failure_fails_transport_gate(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            root = Path(temp_dir)
            self._write_ready_fixture(root)
            after = json.loads((root / "after-debug.json").read_text(encoding="utf-8"))
            after["mww_uplink_submit_failed"] += 1
            (root / "after-debug.json").write_text(json.dumps(after), encoding="utf-8")

            report = check_evidence(root)

        transport = next(
            check
            for check in report["checks"]
            if check["id"] == "robot-zero-transport-errors"
        )
        self.assertEqual("bridge-ai-supervised-not-ready", report["status"])
        self.assertEqual("fail", transport["status"])

    def test_missing_transport_telemetry_fails_candidate_gate(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            root = Path(temp_dir)
            self._write_ready_fixture(root)
            for name in ("before-debug.json", "after-debug.json"):
                path = root / name
                debug = json.loads(path.read_text(encoding="utf-8"))
                del debug["mww_uplink_submit_failed"]
                path.write_text(json.dumps(debug), encoding="utf-8")

            report = check_evidence(root)

        telemetry = next(
            check
            for check in report["checks"]
            if check["id"] == "robot-transport-telemetry"
        )
        self.assertEqual("bridge-ai-supervised-not-ready", report["status"])
        self.assertEqual("fail", telemetry["status"])


if __name__ == "__main__":
    unittest.main()
