import os
import socket
import tempfile
import unittest
from pathlib import Path

from lan_service import read_ws_frame
from lan_smoke import build_report, encode_client_frame, read_handshake_response, write_outputs


class LanSmokeTests(unittest.TestCase):
    def test_handshake_reader_preserves_coalesced_first_websocket_frame(self):
        server, client = socket.socketpair()
        try:
            server.sendall(
                b"HTTP/1.1 101 Switching Protocols\r\nConnection: Upgrade\r\n\r\n"
                b"\x81\x02hi"
            )
            response = read_handshake_response(client)
            opcode, payload = read_ws_frame(client)
        finally:
            server.close()
            client.close()

        self.assertIn("101 Switching Protocols", response)
        self.assertEqual(0x1, opcode)
        self.assertEqual(b"hi", payload)

    def test_client_frames_are_masked_for_server_protocol_path(self):
        frame = encode_client_frame(b"hi", opcode=0x1)

        self.assertEqual(0x81, frame[0])
        self.assertEqual(0x80 | 2, frame[1])
        self.assertEqual(4 + 2, len(frame[2:]))

    def test_build_report_exercises_text_and_audio_socket_paths(self):
        with tempfile.TemporaryDirectory() as temp_dir:
            report = build_report(Path(temp_dir))

        self.assertEqual("stackchan.lan-smoke.v1", report["schema"])
        self.assertEqual("pass", report["status"])
        scenarios = {scenario["scenario"]: scenario for scenario in report["scenarios"]}
        self.assertEqual(
            {"text-turn", "audio-loop", "thinking-latency", "endpoint-controls", "owner-failover"},
            set(scenarios),
        )
        self.assertEqual("pass", scenarios["text-turn"]["status"])
        self.assertEqual("pass", scenarios["audio-loop"]["status"])
        self.assertEqual("pass", scenarios["thinking-latency"]["status"])
        self.assertEqual("pass", scenarios["endpoint-controls"]["status"])
        self.assertEqual("pass", scenarios["owner-failover"]["status"])
        self.assertIn("thinking", scenarios["text-turn"]["frame_types"])
        self.assertIn("audio_stream_start", scenarios["audio-loop"]["frame_types"])
        self.assertIn("owner_status", scenarios["endpoint-controls"]["frame_types"])
        self.assertIn("forget_endpoint_result", scenarios["endpoint-controls"]["frame_types"])
        failover = scenarios["owner-failover"]["evidence"]
        self.assertEqual("pc-studio-01", failover["initial_owner"])
        self.assertEqual("brain_owner_mismatch", failover["observer_audio_error"])
        self.assertEqual("phone-rob-01", failover["timeout_owner"])
        self.assertEqual("promoted", failover["timeout_state"])
        self.assertEqual("pc-studio-01", failover["handback_owner"])
        self.assertEqual("", failover["offline_owner"])
        self.assertEqual("offline", failover["offline_state"])
        self.assertEqual(1, failover["promotion_expirations"])
        self.assertEqual(2, failover["owner_expirations"])
        self.assertEqual(1, failover["owner_promotions"])
        self.assertGreater(scenarios["audio-loop"]["binary_frames"], 0)
        self.assertGreater(scenarios["audio-loop"]["binary_bytes"], 0)
        self.assertEqual(
            ["hello", "listening", "thinking"],
            scenarios["thinking-latency"]["frame_sequence"][:3],
        )
        timings = {item["type"]: item["elapsed_ms"] for item in scenarios["thinking-latency"]["frame_timings"]}
        self.assertLessEqual(timings["thinking"], 200.0)
        self.assertGreaterEqual(timings["response_end"], 250.0)
        self.assertTrue(scenarios["thinking-latency"]["evidence"]["host_reaction_under_300"])
        self.assertLess(scenarios["thinking-latency"]["evidence"]["host_reaction_ms"], 300.0)

    def test_write_outputs_creates_json_markdown_and_per_scenario_reports(self):
        with tempfile.TemporaryDirectory() as temp_dir:
            out_dir = Path(temp_dir)
            report = build_report(out_dir)
            paths = write_outputs(report, out_dir)

            self.assertTrue(paths["json"].exists())
            self.assertTrue(paths["markdown"].exists())
            self.assertTrue((out_dir / "text-turn.json").exists())
            self.assertTrue((out_dir / "audio-loop.json").exists())
            self.assertTrue((out_dir / "thinking-latency.json").exists())
            self.assertTrue((out_dir / "endpoint-controls.json").exists())
            self.assertTrue((out_dir / "owner-failover.json").exists())
            markdown = paths["markdown"].read_text(encoding="utf-8")

        self.assertIn("Stackchan LAN Bridge Smoke", markdown)
        self.assertIn("socket-level no-hardware proxy", markdown)
        self.assertIn("thinking-latency", markdown)
        self.assertIn("endpoint-controls", markdown)
        self.assertIn("owner-failover", markdown)

    def test_smoke_report_does_not_leak_configured_runner_environment(self):
        key = "STACKCHAN_MODEL_COMMAND"
        old = os.environ.get(key)
        os.environ[key] = "definitely-not-a-real-command"
        try:
            with tempfile.TemporaryDirectory() as temp_dir:
                report = build_report(Path(temp_dir), scenarios=("text-turn",))
        finally:
            if old is None:
                os.environ.pop(key, None)
            else:
                os.environ[key] = old

        self.assertEqual("pass", report["status"])


if __name__ == "__main__":
    unittest.main()
