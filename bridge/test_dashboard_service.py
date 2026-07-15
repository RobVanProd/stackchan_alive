import json
import socket
import sys
import threading
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
)
from lan_service import LanBridgeConfig, encode_ws_frame, encode_ws_text, read_ws_frame, serve  # noqa: E402


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

    def test_resume_requires_explicit_robot_clear_confirmation(self) -> None:
        with patch.object(self.runtime, "_fetch_robot") as fetch:
            result = self.runtime.set_motion(True)

        self.assertFalse(result["ok"])
        self.assertFalse(result["commandSent"] if "commandSent" in result else False)
        fetch.assert_not_called()

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

    def test_resume_calls_firmware_endpoint_and_verifies_state(self) -> None:
        command = {"debug_motion_accepted": True}
        enabled = {
            "motion_enabled": True,
            "servo_rail_enabled": True,
            "servo_torque_enabled": True,
        }
        with patch.object(self.runtime, "_fetch_robot", side_effect=[command, enabled]) as fetch:
            result = self.runtime.set_motion(True, "robot_clear")

        self.assertTrue(result["ok"])
        self.assertEqual("/motion-resume", fetch.call_args_list[0].args[0])
        self.assertEqual("/debug", fetch.call_args_list[1].args[0])

    def test_resume_does_not_claim_success_while_power_suppressed(self) -> None:
        command = {"debug_motion_accepted": True}
        suppressed = {
            "motion_enabled": True,
            "servo_rail_enabled": True,
            "servo_torque_enabled": True,
            "motion_power_suppressed": True,
        }
        with (
            patch.object(self.runtime, "_fetch_robot", side_effect=[command] + [suppressed] * 6),
            patch("dashboard_service.time.sleep"),
        ):
            result = self.runtime.set_motion(True, "robot_clear")

        self.assertFalse(result["ok"])
        self.assertFalse(result["verified"])


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
            "Sec-WebSocket-Version: 13\r\n\r\n"
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
            with urllib.request.urlopen(status_url, timeout=3.0) as response:
                status = json.load(response)
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
