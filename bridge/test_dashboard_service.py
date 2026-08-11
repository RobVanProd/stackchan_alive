import io
import json
import socket
import sys
import threading
import time
import unittest
import urllib.error
import urllib.request
from pathlib import Path
from unittest.mock import patch

BRIDGE_DIR = Path(__file__).resolve().parent
if str(BRIDGE_DIR) not in sys.path:
    sys.path.insert(0, str(BRIDGE_DIR))

from dashboard_service import (  # noqa: E402
    DashboardConfig,
    DashboardHttpServer,
    DashboardRuntime,
    _safe_host,
    build_arg_parser,
)
from initiative_policy import InitiativeConfig, InitiativePolicy  # noqa: E402
from lan_service import LanBridgeConfig, encode_ws_frame, encode_ws_text, read_ws_frame, serve  # noqa: E402
from reference_bridge import PROTOCOL  # noqa: E402
from room_context import RoomContextRuntime, RoomObservationConfig  # noqa: E402


class DashboardRuntimeTests(unittest.TestCase):
    def setUp(self) -> None:
        self.runtime = DashboardRuntime(
            DashboardConfig(robot_host="192.168.1.238", robot_http_port=8789)
        )

    def test_host_validation_blocks_url_injection(self) -> None:
        self.assertEqual("192.168.1.238", _safe_host("192.168.1.238"))
        self.assertEqual("stackchan.local", _safe_host("Stackchan.local"))
        with self.assertRaises(ValueError):
            _safe_host("127.0.0.1/path")

    def test_standalone_flags_report_only_enabled_bridge_features(self) -> None:
        args = build_arg_parser().parse_args(
            [
                "--robot-host",
                "192.168.1.238",
                "--research-enabled",
                "--conversation-v2-enabled",
            ]
        )
        runtime = DashboardRuntime(
            DashboardConfig(
                robot_host=args.robot_host,
                research_enabled=args.research_enabled,
                conversation_v2_enabled=args.conversation_v2_enabled,
            )
        )

        bridge = runtime.status()["bridge"]

        self.assertTrue(bridge["researchEnabled"])
        self.assertTrue(bridge["conversationV2Enabled"])

    def test_speech_dependency_controls_operational_readiness(self) -> None:
        class FakeSupervisor:
            def status(self):
                return {
                    "configured": True,
                    "healthy": False,
                    "supervised": True,
                    "recovering": True,
                    "checks": 4,
                    "failures": 2,
                    "consecutiveFailures": 2,
                    "restarts": 0,
                    "restartFailures": 0,
                    "lastCheckAt": "2026-07-30T00:00:00+00:00",
                    "lastHealthyAt": "",
                    "lastRestartAt": "",
                    "lastError": "health probe failed",
                }

        runtime = DashboardRuntime(
            DashboardConfig(stt_server_url="http://127.0.0.1:5061"),
            stt_supervisor=FakeSupervisor(),
        )
        runtime.set_bridge_listening(True)
        runtime.note_client_connected("192.168.1.238", 50123)

        status = runtime.status()

        self.assertFalse(status["bridge"]["operational"])
        self.assertFalse(status["bridge"]["speechReady"])
        self.assertTrue(status["services"]["speechRecognition"]["recovering"])

    def test_heartbeat_status_is_allowlisted(self) -> None:
        self.runtime.note_client_connected("192.168.1.238", 50123)
        self.runtime.note_heartbeat(
            {
                "type": "heartbeat",
                "robot_mode": 3,
                "motion_enabled": True,
                "battery_percent": 82,
                "private_text": "must not leave the bridge",
            }
        )

        status = self.runtime.status()

        self.assertTrue(status["robot"]["connected"])
        self.assertEqual("Listening", status["robot"]["mode"])
        self.assertEqual(82, status["robot"]["batteryPercent"])
        self.assertNotIn("private_text", json.dumps(status))

    def test_sustained_heartbeat_silence_reports_the_robot_as_gone(self) -> None:
        # Observed on the reference robot: the console reported connected and
        # "Thinking" on a heartbeat 4.3 days old, with no socket at the OS level.
        self.runtime.note_client_connected("192.168.1.238", 50123)
        self.runtime.note_heartbeat({"type": "heartbeat", "robot_mode": 4})
        self.runtime._record_debug({"network_state": "connected", "bridge_state": "ready"})

        fresh = self.runtime.status()
        self.assertTrue(fresh["robot"]["connected"])
        self.assertEqual("Thinking", fresh["robot"]["mode"])

        # Neither latched source is cleared here: the socket never reported a
        # disconnect and the retained /debug snapshot still says ready. Only the
        # heartbeat gap should decide it.
        self.runtime._last_heartbeat_at -= 10_000.0

        stale = self.runtime.status()
        self.assertFalse(stale["robot"]["connected"])
        self.assertEqual("Unknown", stale["robot"]["mode"])
        self.assertFalse(stale["bridge"]["connected"])

    def test_brief_heartbeat_gap_is_not_treated_as_a_robot_failure(self) -> None:
        self.runtime.note_client_connected("192.168.1.238", 50123)
        self.runtime.note_heartbeat({"type": "heartbeat", "robot_mode": 1})

        # A few missed samples must not flip the console to disconnected.
        self.runtime._last_heartbeat_at -= 10.0

        status = self.runtime.status()
        self.assertTrue(status["robot"]["connected"])
        self.assertEqual("Idle", status["robot"]["mode"])

    def test_connected_robot_reads_connected_before_its_first_heartbeat(self) -> None:
        self.runtime.note_client_connected("192.168.1.238", 50123)

        status = self.runtime.status()

        self.assertTrue(status["robot"]["connected"])
        self.assertIsNone(status["robot"]["heartbeatAgeSeconds"])

    def test_pipeline_health_attributes_failures_without_turn_content(self) -> None:
        self.runtime.note_pipeline_stage(
            "researching",
            turn_seq=12,
            task_domain="weather",
            task_status="repair",
        )
        self.runtime.note_pipeline_result(
            "research",
            ok=False,
            error_code="research_result_context_mismatch",
            elapsed_ms=42.5,
        )

        status = self.runtime.status()
        self.assertEqual("researching", status["conversationPipeline"]["stage"])
        self.assertEqual("weather", status["conversationPipeline"]["taskDomain"])
        research = status["services"]["research"]
        self.assertFalse(research["healthy"])
        self.assertEqual(
            "research_result_context_mismatch",
            research["lastErrorCode"],
        )
        serialized = json.dumps(status)
        self.assertNotIn("West Berlin", serialized)
        self.assertNotIn("current weather", serialized)

    def test_resume_requires_explicit_robot_clear_confirmation(self) -> None:
        with patch.object(self.runtime, "_fetch_robot") as fetch:
            result = self.runtime.set_motion(True)

        self.assertFalse(result["ok"])
        self.assertFalse(result["commandSent"] if "commandSent" in result else False)
        fetch.assert_not_called()

    def test_motion_resume_policy_emergency_stop_only_disables_resume(self) -> None:
        self.runtime._record_debug(
            {
                "network_state": "connected",
                "bridge_state": "ready",
                "debug_http_control_policy": "emergency_stop_only",
            }
        )

        robot = self.runtime.status()["robot"]

        self.assertFalse(robot.get("motionResumeAvailable", True))
        self.assertEqual("emergency_stop_only", robot.get("motionResumePolicy"))

    def test_motion_resume_policy_missing_unknown_malformed_and_stale_fail_closed(self) -> None:
        for value in (None, "future_policy", 42):
            runtime = DashboardRuntime(self.runtime.config)
            if value is not None:
                runtime._record_debug({"debug_http_control_policy": value})
            robot = runtime.status()["robot"]
            self.assertFalse(robot.get("motionResumeAvailable", True))
            self.assertEqual("unknown", robot.get("motionResumePolicy"))

        with patch("dashboard_service.time.monotonic", return_value=100.0):
            runtime = DashboardRuntime(self.runtime.config)
            runtime._record_debug({"debug_http_control_policy": "emergency_stop_only"})
        with patch("dashboard_service.time.monotonic", return_value=115.0):
            boundary_robot = runtime.status()["robot"]
        self.assertFalse(boundary_robot.get("motionResumeAvailable", True))
        self.assertEqual("emergency_stop_only", boundary_robot.get("motionResumePolicy"))
        with patch("dashboard_service.time.monotonic", return_value=115.001):
            stale_robot = runtime.status()["robot"]
        self.assertFalse(stale_robot.get("motionResumeAvailable", True))
        self.assertEqual("unknown", stale_robot.get("motionResumePolicy"))

    def test_motion_resume_policy_refuses_before_robot_request(self) -> None:
        self.runtime._record_debug({"debug_http_control_policy": "emergency_stop_only"})
        blocked = {"debug_motion_accepted": False}
        with (
            patch.object(self.runtime, "_fetch_robot", return_value=blocked) as fetch,
            patch("dashboard_service.time.sleep"),
        ):
            result = self.runtime.set_motion(True, "robot_clear")

        self.assertFalse(result["ok"])
        self.assertFalse(result.get("commandSent", True))
        self.assertIn("emergency stop only", result.get("error", ""))
        fetch.assert_not_called()

    def test_fetch_robot_accepts_emergency_stop_admission_202(self) -> None:
        class AcceptedResponse:
            status = 202

            def __enter__(self):
                return self

            def __exit__(self, exc_type, exc_value, traceback):
                return False

            @staticmethod
            def read(_limit):
                return b'{"ok":true,"accepted":true}'

        with patch("dashboard_service.urllib.request.urlopen", return_value=AcceptedResponse()):
            result = self.runtime._fetch_robot("/motion-stop")

        self.assertTrue(result["accepted"])

    def test_debug_status_distinguishes_running_host_vision(self) -> None:
        self.runtime._record_debug(
            {
                "network_state": "connected",
                "bridge_state": "ready",
                "camera_enabled": True,
                "camera_active": True,
                "camera_host_frame_requests": 12,
                "camera_host_frame_failures": 0,
                "camera_host_target_updates": 12,
                "camera_host_auth_failures": 0,
                "camera_face_batches": 12,
                "camera_faces_observed": 3,
                "camera_target_valid": True,
            }
        )

        robot = self.runtime.status()["robot"]

        self.assertEqual(12, robot["visionFrameRequests"])
        self.assertEqual(12, robot["visionTargetUpdates"])
        self.assertEqual(3, robot["visionFacesObserved"])
        self.assertTrue(robot["visionTargetValid"])

    def test_failed_standalone_refresh_clears_cached_connected_state(self) -> None:
        self.runtime._record_debug({"network_state": "connected", "bridge_state": "ready"})
        self.assertTrue(self.runtime.status()["robot"]["connected"])

        with patch.object(self.runtime, "_fetch_robot", side_effect=RuntimeError("offline")):
            result = self.runtime.refresh_robot()

        self.assertFalse(result["ok"])
        self.assertFalse(result["status"]["robot"]["connected"])

    def test_stop_requires_motion_rail_and_torque_verification(self) -> None:
        command = {"debug_motion_accepted": True}
        stopped = {
            "motion_enabled": False,
            "servo_rail_enabled": False,
            "servo_torque_enabled": False,
            "bridge_state": "ready",
            "network_state": "connected",
        }
        with patch.object(self.runtime, "_fetch_robot", side_effect=[command, stopped]):
            result = self.runtime.set_motion(False)

        self.assertTrue(result["ok"])
        self.assertTrue(result["verified"])
        self.assertFalse(result["status"]["robot"]["motionEnabled"])

    def test_stop_accepts_bounded_admission_response_and_verifies_state(self) -> None:
        command = {"accepted": True}
        stopped = {
            "motion_enabled": False,
            "servo_rail_enabled": False,
            "servo_torque_enabled": False,
        }
        with patch.object(self.runtime, "_fetch_robot", side_effect=[command, stopped]) as fetch:
            result = self.runtime.set_motion(False)

        self.assertTrue(result["ok"])
        self.assertTrue(result["accepted"])
        self.assertTrue(result["verified"])
        self.assertEqual(2, fetch.call_count)
        self.assertEqual("/motion-stop", fetch.call_args_list[0].args[0])
        self.assertEqual("/debug", fetch.call_args_list[1].args[0])

    def test_stop_remains_available_under_emergency_stop_only_policy(self) -> None:
        self.runtime._record_debug(
            {"debug_http_control_policy": "emergency_stop_only"}
        )
        command = {"accepted": True}
        stopped = {
            "motion_enabled": False,
            "servo_rail_enabled": False,
            "servo_torque_enabled": False,
            "debug_http_control_policy": "emergency_stop_only",
        }
        with patch.object(self.runtime, "_fetch_robot", side_effect=[command, stopped]) as fetch:
            result = self.runtime.set_motion(False)

        self.assertTrue(result["ok"])
        self.assertTrue(result["accepted"])
        self.assertTrue(result["verified"])
        self.assertEqual(["/motion-stop", "/debug"], [call.args[0] for call in fetch.call_args_list])

    def test_stop_rejects_false_missing_or_non_boolean_admission(self) -> None:
        stopped = {
            "motion_enabled": False,
            "servo_rail_enabled": False,
            "servo_torque_enabled": False,
        }
        for command in ({"accepted": False}, {}, {"accepted": "true"}):
            with self.subTest(command=command):
                with patch.object(
                    self.runtime, "_fetch_robot", side_effect=[command, stopped]
                ) as fetch:
                    result = self.runtime.set_motion(False)

                self.assertFalse(result["ok"])
                self.assertFalse(result.get("accepted", True))
                self.assertTrue(result["verified"])
                self.assertEqual(2, fetch.call_count)
                self.assertEqual("/motion-stop", fetch.call_args_list[0].args[0])
                self.assertEqual("/debug", fetch.call_args_list[1].args[0])

    def test_stop_parses_wire_503_rejection_and_still_verifies_state(self) -> None:
        class DebugResponse:
            status = 200

            def __enter__(self):
                return self

            def __exit__(self, exc_type, exc_value, traceback):
                return False

            @staticmethod
            def read(_limit):
                return (
                    b'{"motion_enabled":false,"servo_rail_enabled":false,'
                    b'"servo_torque_enabled":false}'
                )

        rejected = urllib.error.HTTPError(
            "http://192.168.1.238:8789/motion-stop",
            503,
            "Service Unavailable",
            None,
            io.BytesIO(b'{"ok":false,"accepted":false,"error":"control_disabled"}'),
        )
        with patch(
            "dashboard_service.urllib.request.urlopen",
            side_effect=[rejected, DebugResponse()],
        ) as fetch:
            result = self.runtime.set_motion(False)

        self.assertFalse(result["ok"])
        self.assertTrue(result["commandSent"])
        self.assertFalse(result["accepted"])
        self.assertTrue(result["verified"])
        self.assertEqual(2, fetch.call_count)

    def test_stop_does_not_claim_success_when_torque_remains_on(self) -> None:
        command = {"debug_motion_accepted": True}
        unsafe = {
            "motion_enabled": False,
            "servo_rail_enabled": False,
            "servo_torque_enabled": True,
        }
        with (
            patch.object(self.runtime, "_fetch_robot", side_effect=[command] + [unsafe] * 6),
            patch("dashboard_service.time.sleep"),
        ):
            result = self.runtime.set_motion(False)

        self.assertFalse(result["ok"])
        self.assertFalse(result["verified"])
        self.assertIn("did not verify", result["error"])

    def test_resume_without_supported_authority_never_calls_firmware_endpoint(self) -> None:
        self.runtime._record_debug({"debug_http_control_policy": "future_policy"})
        with patch.object(self.runtime, "_fetch_robot") as fetch:
            result = self.runtime.set_motion(True, "robot_clear")

        self.assertFalse(result["ok"])
        self.assertFalse(result.get("commandSent", True))
        self.assertIn("emergency stop only", result.get("error", ""))
        fetch.assert_not_called()

    def test_resume_missing_policy_does_not_claim_success(self) -> None:
        with patch.object(self.runtime, "_fetch_robot") as fetch:
            result = self.runtime.set_motion(True, "robot_clear")

        self.assertFalse(result["ok"])
        self.assertFalse(result.get("commandSent", True))
        self.assertFalse(result.get("verified", False))
        fetch.assert_not_called()

    def test_awareness_controls_are_host_only_and_aggregate(self) -> None:
        policy = InitiativePolicy(
            InitiativeConfig(enabled=False),
            now_ms=0,
        )
        room = RoomContextRuntime(RoomObservationConfig(interval_seconds=300))
        runtime = DashboardRuntime(
            DashboardConfig(robot_host="192.168.1.238"),
            initiative_policy=policy,
            room_context=room,
        )

        initiative = runtime.set_initiative(True)
        observation = runtime.set_room_observation(enabled=True, interval_seconds=600)

        self.assertTrue(initiative["ok"])
        self.assertTrue(observation["ok"])
        behavior = observation["status"]["behavior"]
        self.assertTrue(behavior["initiative"]["enabled"])
        self.assertTrue(behavior["roomObservation"]["enabled"])
        self.assertEqual(600, behavior["roomObservation"]["intervalSeconds"])
        self.assertNotIn("frame", json.dumps(behavior).lower())


class DashboardHttpTests(unittest.TestCase):
    def setUp(self) -> None:
        with socket.create_server(("127.0.0.1", 0)) as probe:
            self.port = int(probe.getsockname()[1])
        self.runtime = DashboardRuntime(
            DashboardConfig(host="127.0.0.1", port=self.port, robot_host="192.168.1.238")
        )
        self.server = DashboardHttpServer(("127.0.0.1", self.port), self.runtime)
        self.thread = threading.Thread(target=self.server.serve_forever, daemon=True)
        self.thread.start()

    def tearDown(self) -> None:
        self.server.shutdown()
        self.server.server_close()
        self.thread.join(timeout=3.0)

    def request(self, path: str, *, data: bytes | None = None, headers=None):
        request = urllib.request.Request(
            f"http://127.0.0.1:{self.port}{path}",
            data=data,
            headers=headers or {},
            method="POST" if data is not None else "GET",
        )
        return urllib.request.urlopen(request, timeout=3.0)

    def test_serves_dashboard_and_security_headers(self) -> None:
        with self.request("/") as response:
            body = response.read().decode("utf-8")

        self.assertIn("Stackchan Alive Bridge", body)
        self.assertEqual("DENY", response.headers["X-Frame-Options"])
        self.assertIn("default-src 'self'", response.headers["Content-Security-Policy"])
        self.assertIsNone(response.headers.get("Access-Control-Allow-Origin"))

    def test_status_is_aggregate_json(self) -> None:
        with self.request("/api/status") as response:
            payload = json.load(response)

        self.assertEqual("stackchan.bridge-dashboard.v1", payload["schema"])
        self.assertNotIn("memory", json.dumps(payload).lower())

    def test_write_without_dashboard_header_is_rejected(self) -> None:
        with self.assertRaises(urllib.error.HTTPError) as caught:
            self.request(
                "/api/motion",
                data=b'{"enabled":false}',
                headers={"Content-Type": "application/json"},
            )

        self.assertEqual(403, caught.exception.code)

    def test_cross_origin_write_is_rejected(self) -> None:
        with self.assertRaises(urllib.error.HTTPError) as caught:
            self.request(
                "/api/motion",
                data=b'{"enabled":false}',
                headers={
                    "Content-Type": "application/json",
                    "X-Stackchan-Dashboard": "1",
                    "Origin": "https://example.com",
                },
            )

        self.assertEqual(403, caught.exception.code)

    def test_unknown_asset_does_not_traverse_filesystem(self) -> None:
        with self.assertRaises(urllib.error.HTTPError) as caught:
            self.request("/../README.md")

        self.assertEqual(404, caught.exception.code)

    def test_awareness_write_requires_valid_bounded_controls(self) -> None:
        policy = InitiativePolicy(InitiativeConfig(), now_ms=0)
        room = RoomContextRuntime(RoomObservationConfig(interval_seconds=300))
        self.runtime.initiative_policy = policy
        self.runtime.room_context = room
        headers = {
            "Content-Type": "application/json",
            "X-Stackchan-Dashboard": "1",
        }

        with self.request("/api/initiative", data=b'{"enabled":true}', headers=headers) as response:
            initiative = json.load(response)
        with self.request(
            "/api/room-observation",
            data=b'{"enabled":true,"intervalSeconds":600}',
            headers=headers,
        ) as response:
            observation = json.load(response)

        self.assertTrue(initiative["ok"])
        self.assertTrue(observation["ok"])
        self.assertTrue(observation["status"]["behavior"]["roomObservation"]["enabled"])
        with self.assertRaises(urllib.error.HTTPError) as caught:
            self.request(
                "/api/room-observation",
                data=b'{"enabled":true,"intervalSeconds":30}',
                headers=headers,
            )
        self.assertEqual(409, caught.exception.code)


class DashboardBridgeIntegrationTests(unittest.TestCase):
    def test_bridge_dashboard_receives_live_robot_heartbeat(self) -> None:
        with socket.create_server(("127.0.0.1", 0)) as probe:
            bridge_port = int(probe.getsockname()[1])
        with socket.create_server(("127.0.0.1", 0)) as probe:
            dashboard_port = int(probe.getsockname()[1])
        errors: list[BaseException] = []

        def run() -> None:
            try:
                serve(
                    LanBridgeConfig(
                        host="127.0.0.1",
                        port=bridge_port,
                        once=True,
                        dashboard_enabled=True,
                        dashboard_port=dashboard_port,
                        downlink_text_frame_delay_ms=0,
                    )
                )
            except BaseException as exc:  # pragma: no cover - surfaced below
                errors.append(exc)

        thread = threading.Thread(target=run, daemon=True)
        thread.start()
        status_url = f"http://127.0.0.1:{dashboard_port}/api/status"
        for _ in range(50):
            try:
                urllib.request.urlopen(status_url, timeout=0.25).close()
                break
            except (urllib.error.URLError, OSError):
                threading.Event().wait(0.02)
        else:
            self.fail("integrated dashboard did not start")

        request = (
            "GET /bridge HTTP/1.1\r\n"
            f"Host: 127.0.0.1:{bridge_port}\r\n"
            "Upgrade: websocket\r\n"
            "Connection: Upgrade\r\n"
            "Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\n"
            "Sec-WebSocket-Version: 13\r\n"
            f"X-Stackchan-Protocol: {PROTOCOL}\r\n"
            "X-Stackchan-Device: stackchan\r\n\r\n"
        ).encode("ascii")
        with socket.create_connection(("127.0.0.1", bridge_port), timeout=3.0) as client:
            client.sendall(request)
            response = bytearray()
            while b"\r\n\r\n" not in response:
                response.extend(client.recv(1))
            read_ws_frame(client)
            client.sendall(
                encode_ws_text(
                    json.dumps(
                        {
                            "type": "heartbeat",
                            "robot_mode": 3,
                            "motion_enabled": True,
                            "battery_percent": 74,
                        }
                    )
                )
            )
            status_deadline = time.monotonic() + 3.0
            while True:
                remaining = status_deadline - time.monotonic()
                if remaining <= 0.0:
                    break
                with urllib.request.urlopen(status_url, timeout=min(0.25, remaining)) as response:
                    status = json.load(response)
                if (
                    status["robot"]["mode"] == "Listening"
                    and status["robot"]["batteryPercent"] == 74
                ):
                    break
                remaining = status_deadline - time.monotonic()
                if remaining <= 0.0:
                    break
                threading.Event().wait(min(0.02, remaining))
            client.sendall(encode_ws_frame(b"", opcode=0x8))

        thread.join(timeout=5.0)
        self.assertFalse(thread.is_alive())
        self.assertEqual([], errors)
        self.assertTrue(status["bridge"]["listening"])
        self.assertTrue(status["robot"]["connected"])
        self.assertEqual("Listening", status["robot"]["mode"])
        self.assertEqual(74, status["robot"]["batteryPercent"])


if __name__ == "__main__":
    unittest.main()
