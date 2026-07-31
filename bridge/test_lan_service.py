import json
import os
import base64
import math
import socket
import sys
import tempfile
import threading
import time
import unittest
import wave
from array import array
from pathlib import Path
from types import SimpleNamespace
from unittest.mock import Mock, patch

BRIDGE_DIR = Path(__file__).resolve().parent
if str(BRIDGE_DIR) not in sys.path:
    sys.path.insert(0, str(BRIDGE_DIR))

from lan_service import (
    BridgeControlState,
    EndpointRecord,
    LanBridgeConfig,
    LanBridgeSession,
    audio_downlink_frames,
    analyze_reply_pcm16_speech,
    build_handshake_response,
    contains_stackchan_wake_phrase,
    configure_client_socket,
    downlink_text_frame_delay_ms,
    ends_audio_stream,
    encode_ws_frame,
    encode_ws_text,
    is_identity_question,
    is_visual_color_request,
    is_visual_context_request,
    explicit_research_request,
    model_denies_research_access,
    natural_research_request,
    mouth_frame_for_audio_window,
    no_speech_character_response,
    prompt_case_for_text,
    read_ws_frame,
    send_connection_frame,
    serve,
    websocket_accept_value,
)
from cancellation import CancellationToken, OperationCancelledError
from bridge_memory import BridgeMemory
from conversation_session import ConversationPhase
from episode_distillation import DistilledMemory
from initiative_policy import InitiativeConfig, InitiativePolicy
from local_runner import RunnerExecutionError, run_runner_profile
from reference_bridge import PROTOCOL, load_bridge_memory
from room_context import RoomContextRuntime, RoomObservationConfig
from stt_adapter import STT_COMMAND_ENV
from tts_adapter import TTS_COMMAND_ENV, TtsConfigurationError

RUNNER_ENV = {
    "STACKCHAN_GEMMA4_E2B_GGUF_COMMAND": "",
    "STACKCHAN_GEMMA4_E2B_LITERT_COMMAND": "",
    "STACKCHAN_GEMMA4_E4B_GGUF_COMMAND": "",
    "STACKCHAN_MODEL_COMMAND": "",
    TTS_COMMAND_ENV: "",
}


def connect_loopback(port: int, timeout: float = 5.0) -> socket.socket:
    deadline = time.monotonic() + timeout
    while True:
        try:
            remaining = max(0.1, deadline - time.monotonic())
            return socket.create_connection(
                ("127.0.0.1", port),
                timeout=min(1.0, remaining),
            )
        except ConnectionRefusedError:
            if time.monotonic() >= deadline:
                raise
            time.sleep(0.01)


class LanServiceTests(unittest.TestCase):
    def test_client_socket_policy_bounds_stale_reboot_sessions(self):
        conn = Mock()

        configure_client_socket(conn, 20.0, low_latency=True)

        conn.settimeout.assert_called_once_with(20.0)
        conn.setsockopt.assert_any_call(socket.SOL_SOCKET, socket.SO_KEEPALIVE, 1)
        conn.setsockopt.assert_any_call(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)

    def test_websocket_accept_matches_rfc_example(self):
        self.assertEqual(
            "s3pPLMBiTxaQ9kYGzzhZRbK+xOo=",
            websocket_accept_value("dGhlIHNhbXBsZSBub25jZQ=="),
        )

    def test_handshake_response_accepts_upgrade_request(self):
        request = (
            "GET /bridge HTTP/1.1\r\n"
            "Host: 127.0.0.1:8765\r\n"
            "Upgrade: websocket\r\n"
            "Connection: Upgrade\r\n"
            "Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\n"
            "Sec-WebSocket-Version: 13\r\n"
            "\r\n"
        ).encode("ascii")

        response = build_handshake_response(request).decode("ascii")

        self.assertIn("101 Switching Protocols", response)
        self.assertIn("Sec-WebSocket-Accept: s3pPLMBiTxaQ9kYGzzhZRbK+xOo=", response)

    def test_server_text_frame_encoding_is_unmasked(self):
        self.assertEqual(b"\x81\x02hi", encode_ws_text("hi"))

    def test_server_binary_frame_encoding_is_unmasked(self):
        self.assertEqual(b"\x82\x03abc", encode_ws_frame(b"abc", opcode=0x2))

    def test_server_survives_client_disconnect_without_close_frame(self):
        with socket.create_server(("127.0.0.1", 0)) as probe:
            port = int(probe.getsockname()[1])

        errors = []

        def run_server():
            try:
                serve(LanBridgeConfig(host="127.0.0.1", port=port, once=True))
            except Exception as exc:  # pragma: no cover - surfaced by assertion
                errors.append(exc)

        thread = threading.Thread(target=run_server, daemon=True)
        thread.start()

        request = (
            "GET /bridge HTTP/1.1\r\n"
            f"Host: 127.0.0.1:{port}\r\n"
            "Upgrade: websocket\r\n"
            "Connection: Upgrade\r\n"
            "Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\n"
            "Sec-WebSocket-Version: 13\r\n"
            "\r\n"
        ).encode("ascii")
        with connect_loopback(port) as client:
            client.sendall(request)
            self.assertIn(b"101 Switching Protocols", client.recv(4096))

        thread.join(timeout=5.0)

        self.assertFalse(thread.is_alive())
        self.assertEqual([], errors)

    def test_server_sends_session_hello_after_handshake(self):
        with socket.create_server(("127.0.0.1", 0)) as probe:
            port = int(probe.getsockname()[1])

        errors = []

        def run_server():
            try:
                serve(LanBridgeConfig(host="127.0.0.1", port=port, once=True))
            except Exception as exc:  # pragma: no cover - surfaced by assertion
                errors.append(exc)

        thread = threading.Thread(target=run_server, daemon=True)
        thread.start()

        request = (
            "GET /bridge HTTP/1.1\r\n"
            f"Host: 127.0.0.1:{port}\r\n"
            "Upgrade: websocket\r\n"
            "Connection: Upgrade\r\n"
            "Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\n"
            "Sec-WebSocket-Version: 13\r\n"
            "\r\n"
        ).encode("ascii")
        with connect_loopback(port) as client:
            client.sendall(request)
            response = bytearray()
            while b"\r\n\r\n" not in response:
                response.extend(client.recv(1))
            self.assertIn(b"101 Switching Protocols", bytes(response))
            opcode, payload = read_ws_frame(client)
            self.assertEqual(0x1, opcode)
            self.assertEqual(
                {"type": "hello", "protocol": PROTOCOL, "session": "lan"},
                json.loads(payload.decode("utf-8")),
            )
            client.sendall(encode_ws_frame(b"", opcode=0x8))

        thread.join(timeout=5.0)

        self.assertFalse(thread.is_alive())
        self.assertEqual([], errors)

    def test_cancel_interrupts_active_model_process_without_committing_its_memory(self):
        with tempfile.TemporaryDirectory() as temp_dir:
            marker = Path(temp_dir) / "model-finished.txt"
            script = Path(temp_dir) / "slow_model.py"
            script.write_text(
                "import json,pathlib,sys,time\n"
                "sys.stdin.read()\n"
                "time.sleep(3)\n"
                f"pathlib.Path({str(marker)!r}).write_text('finished')\n"
                "print(json.dumps({\n"
                "  'spoken_text': 'This stale response must never play.',\n"
                "  'mode': 'think',\n"
                "  'earcon': 'think',\n"
                "  'emotion': {'arousal': 0.1, 'valence': 0.0},\n"
                "  'memory_write': {'project.note': 'stale'},\n"
                "  'memory_forget': []\n"
                "}))\n",
                encoding="utf-8",
            )
            session = LanBridgeSession(
                LanBridgeConfig(
                    runner_command=f'"{sys.executable}" "{script}"',
                    require_runner=True,
                    runner_timeout_ms=5000,
                )
            )
            result: list[list[dict[str, object] | bytes]] = []
            worker = threading.Thread(
                target=lambda: result.append(
                    session.handle_text(
                        json.dumps({"type": "utterance_end", "seq": 91, "text": "Tell me something."})
                    )
                )
            )
            worker.start()
            time.sleep(0.15)

            cancel_frames = session.handle_text(
                json.dumps({"type": "cancel", "reason": "barge_in"})
            )
            worker.join(timeout=2.0)

            self.assertFalse(worker.is_alive())
            self.assertEqual("cancelled", cancel_frames[0]["code"])
            self.assertEqual("turn_cancelled", result[0][0]["code"])
            self.assertIn("barge_in", result[0][0]["detail"])
            self.assertFalse(marker.exists())
            self.assertNotIn("project.note", json.dumps(session.memory.to_dict()))

    def test_websocket_loop_reads_cancel_while_model_turn_is_running(self):
        with socket.create_server(("127.0.0.1", 0)) as probe:
            port = int(probe.getsockname()[1])
        model_started = threading.Event()
        errors: list[BaseException] = []

        def blocking_runner(*_args, cancellation=None, **_kwargs):
            model_started.set()
            deadline = time.monotonic() + 4.0
            while time.monotonic() < deadline:
                if cancellation is not None and cancellation.cancelled:
                    raise OperationCancelledError(cancellation.reason)
                time.sleep(0.01)
            raise AssertionError("model turn was not cancelled")

        def run_server():
            try:
                serve(
                    LanBridgeConfig(
                        host="127.0.0.1",
                        port=port,
                        once=True,
                        runner_command="fake-runner",
                        require_runner=True,
                        downlink_text_frame_delay_ms=0,
                    )
                )
            except BaseException as exc:  # pragma: no cover - surfaced by assertion
                errors.append(exc)

        with patch("lan_service.run_runner_profile", side_effect=blocking_runner):
            server = threading.Thread(target=run_server, daemon=True)
            server.start()
            request = (
                "GET /bridge HTTP/1.1\r\n"
                f"Host: 127.0.0.1:{port}\r\n"
                "Upgrade: websocket\r\n"
                "Connection: Upgrade\r\n"
                "Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\n"
                "Sec-WebSocket-Version: 13\r\n"
                "\r\n"
            ).encode("ascii")
            with connect_loopback(port) as client:
                client.sendall(request)
                response = bytearray()
                while b"\r\n\r\n" not in response:
                    response.extend(client.recv(1))
                read_ws_frame(client)  # session hello
                client.sendall(
                    encode_ws_text(
                        json.dumps({"type": "utterance_end", "seq": 92, "text": "Tell me something."})
                    )
                )
                opcode, payload = read_ws_frame(client)
                self.assertEqual("thinking", json.loads(payload.decode("utf-8"))["type"])
                self.assertTrue(model_started.wait(timeout=1.0))

                started = time.monotonic()
                client.sendall(
                    encode_ws_text(json.dumps({"type": "cancel", "reason": "barge_in"}))
                )
                codes: set[str] = set()
                while time.monotonic() - started < 2.0 and len(codes) < 2:
                    opcode, payload = read_ws_frame(client)
                    if opcode == 0x1:
                        frame = json.loads(payload.decode("utf-8"))
                        if frame.get("code"):
                            codes.add(str(frame["code"]))
                elapsed = time.monotonic() - started
                client.sendall(encode_ws_frame(b"", opcode=0x8))

            server.join(timeout=3.0)

        self.assertLess(elapsed, 2.0)
        self.assertEqual({"cancelled", "turn_cancelled"}, codes)
        self.assertFalse(server.is_alive())
        self.assertEqual([], errors)

    def test_websocket_streaming_cancel_closes_started_response_without_audio_tail(self):
        with socket.create_server(("127.0.0.1", 0)) as probe:
            port = int(probe.getsockname()[1])
        tts_started = threading.Event()
        errors: list[BaseException] = []
        runner = SimpleNamespace(
            raw_response=json.dumps(
                {
                    "spoken_text": "First phrase. Second phrase.",
                    "mode": "speak",
                    "earcon": "none",
                    "emotion": {"arousal": 0.0, "valence": 0.0},
                    "memory_write": {},
                    "memory_forget": [],
                }
            ),
            command_source="test",
            elapsed_ms=1.0,
            approx_tokens_per_sec=10.0,
        )

        def blocking_tts(*_args, cancellation=None, **_kwargs):
            tts_started.set()
            deadline = time.monotonic() + 4.0
            while time.monotonic() < deadline:
                if cancellation is not None and cancellation.cancelled:
                    raise OperationCancelledError(cancellation.reason)
                time.sleep(0.01)
            raise AssertionError("TTS turn was not cancelled")

        with tempfile.TemporaryDirectory() as temp_dir:
            turn_log = Path(temp_dir) / "turns.jsonl"

            def run_server():
                try:
                    serve(
                        LanBridgeConfig(
                            host="127.0.0.1",
                            port=port,
                            once=True,
                            runner_command="fake-runner",
                            require_runner=True,
                            tts_command="fake-tts",
                            stream_tts_phrases=True,
                            downlink_audio_chunk_bytes=4,
                            downlink_binary_frame_delay_ms=0,
                            downlink_text_frame_delay_ms=0,
                            turn_log_file=turn_log,
                        )
                    )
                except BaseException as exc:  # pragma: no cover - surfaced by assertion
                    errors.append(exc)

            with (
                patch("lan_service.run_runner_profile", return_value=runner),
                patch("lan_service.synthesize_speech", side_effect=blocking_tts),
            ):
                server = threading.Thread(target=run_server, daemon=True)
                server.start()
                request = (
                    "GET /bridge HTTP/1.1\r\n"
                    f"Host: 127.0.0.1:{port}\r\n"
                    "Upgrade: websocket\r\n"
                    "Connection: Upgrade\r\n"
                    "Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\n"
                    "Sec-WebSocket-Version: 13\r\n"
                    "\r\n"
                ).encode("ascii")
                with connect_loopback(port) as client:
                    client.sendall(request)
                    response = bytearray()
                    while b"\r\n\r\n" not in response:
                        response.extend(client.recv(1))
                    read_ws_frame(client)  # session hello
                    client.sendall(
                        encode_ws_text(
                            json.dumps(
                                {
                                    "type": "utterance_end",
                                    "seq": 93,
                                    "text": "Tell me something.",
                                }
                            )
                        )
                    )
                    seen: list[dict[str, object]] = []
                    while not any(frame.get("type") == "response_start" for frame in seen):
                        opcode, payload = read_ws_frame(client)
                        self.assertEqual(0x1, opcode)
                        seen.append(json.loads(payload.decode("utf-8")))
                    self.assertTrue(tts_started.wait(timeout=1.0))

                    client.sendall(
                        encode_ws_text(json.dumps({"type": "cancel", "reason": "barge_in"}))
                    )
                    binary_after_cancel = 0
                    while not any(frame.get("type") == "response_end" for frame in seen):
                        opcode, payload = read_ws_frame(client)
                        if opcode == 0x2:
                            binary_after_cancel += 1
                        elif opcode == 0x1:
                            seen.append(json.loads(payload.decode("utf-8")))
                    client.sendall(encode_ws_frame(b"", opcode=0x8))

                server.join(timeout=3.0)

            records = [
                json.loads(line)
                for line in turn_log.read_text(encoding="utf-8").splitlines()
            ]

        response_starts = [frame for frame in seen if frame.get("type") == "response_start"]
        response_ends = [frame for frame in seen if frame.get("type") == "response_end"]
        error_codes = {
            str(frame.get("code"))
            for frame in seen
            if frame.get("type") == "error"
        }
        wire_events = [
            record
            for record in records
            if record.get("schema") == "stackchan.response-wire-event.v1"
        ]
        self.assertEqual(0, binary_after_cancel)
        self.assertEqual([93], [frame["seq"] for frame in response_starts])
        self.assertEqual([93], [frame["seq"] for frame in response_ends])
        self.assertIn("response_aborted", error_codes)
        self.assertTrue(
            any(
                event.get("code") == "response_forced_closed"
                and event.get("recovered") is True
                for event in wire_events
            )
        )
        self.assertFalse(
            any(event.get("code") == "response_unclosed" for event in wire_events)
        )
        self.assertFalse(server.is_alive())
        self.assertEqual([], errors)

    def test_conversation_v2_defers_response_end_until_playback_complete(self):
        with socket.create_server(("127.0.0.1", 0)) as probe:
            port = int(probe.getsockname()[1])
        errors: list[BaseException] = []
        runner = SimpleNamespace(
            raw_response=json.dumps(
                {
                    "spoken_text": "I am doing well.",
                    "mode": "listen",
                    "earcon": "none",
                    "emotion": {"arousal": 0.0, "valence": 0.1},
                    "memory_write": {},
                    "memory_forget": [],
                }
            ),
            command_source="test",
            elapsed_ms=1.0,
            approx_tokens_per_sec=10.0,
        )
        tts = SimpleNamespace(
            diagnostics={"audio_truncated": False},
            audio_data=b"\x00\x00\x01\x00",
            audio_format="pcm16",
            sample_rate=16000,
            command_source="test",
            voice="directml-test",
            elapsed_ms=1.0,
            duration_ms=20,
            beats=(),
        )

        with tempfile.TemporaryDirectory() as temp_dir:
            turn_log = Path(temp_dir) / "turns.jsonl"

            def run_server():
                try:
                    serve(
                        LanBridgeConfig(
                            host="127.0.0.1",
                            port=port,
                            once=True,
                            runner_command="fake-runner",
                            require_runner=True,
                            tts_command="fake-tts",
                            stream_tts_phrases=True,
                            conversation_v2_enabled=True,
                            conversation_acoustic_tail_ms=0,
                            downlink_audio_chunk_bytes=4,
                            downlink_binary_frame_delay_ms=0,
                            downlink_text_frame_delay_ms=0,
                            turn_log_file=turn_log,
                        )
                    )
                except BaseException as exc:  # pragma: no cover - surfaced by assertion
                    errors.append(exc)

            with (
                patch("lan_service.run_runner_profile", return_value=runner),
                patch("lan_service.synthesize_speech", return_value=tts),
            ):
                server = threading.Thread(target=run_server, daemon=True)
                server.start()
                request = (
                    "GET /bridge HTTP/1.1\r\n"
                    f"Host: 127.0.0.1:{port}\r\n"
                    "Upgrade: websocket\r\n"
                    "Connection: Upgrade\r\n"
                    "Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\n"
                    "Sec-WebSocket-Version: 13\r\n"
                    "\r\n"
                ).encode("ascii")
                with connect_loopback(port) as client:
                    client.sendall(request)
                    response = bytearray()
                    while b"\r\n\r\n" not in response:
                        response.extend(client.recv(1))
                    read_ws_frame(client)  # session hello
                    client.sendall(
                        encode_ws_text(
                            json.dumps(
                                {
                                    "type": "utterance_start",
                                    "seq": 94,
                                    "sample_rate": 16000,
                                }
                            )
                        )
                    )
                    opcode, payload = read_ws_frame(client)
                    self.assertEqual("listening", json.loads(payload.decode("utf-8"))["type"])
                    client.sendall(
                        encode_ws_text(
                            json.dumps(
                                {
                                    "type": "utterance_end",
                                    "seq": 94,
                                    "text": "How are you?",
                                }
                            )
                        )
                    )
                    seen: list[dict[str, object]] = []
                    saw_final_audio = False
                    while not saw_final_audio:
                        opcode, payload = read_ws_frame(client)
                        if opcode == 0x1:
                            frame = json.loads(payload.decode("utf-8"))
                            seen.append(frame)
                            saw_final_audio = (
                                frame.get("type") == "audio"
                                and frame.get("final") is True
                            )
                    self.assertFalse(
                        any(frame.get("type") == "response_end" for frame in seen)
                    )
                    client.settimeout(0.15)
                    with self.assertRaises(socket.timeout):
                        read_ws_frame(client)
                    client.settimeout(5.0)

                    client.sendall(
                        encode_ws_text(
                            json.dumps(
                                {
                                    "type": "playback_complete",
                                    "seq": 94,
                                    "at_ms": 1234,
                                }
                            )
                        )
                    )
                    released = []
                    while len(released) < 2:
                        opcode, payload = read_ws_frame(client)
                        self.assertEqual(0x1, opcode)
                        released.append(json.loads(payload.decode("utf-8")))
                    client.sendall(encode_ws_frame(b"", opcode=0x8))

                server.join(timeout=3.0)

            records = [
                json.loads(line)
                for line in turn_log.read_text(encoding="utf-8").splitlines()
            ]

        self.assertEqual(
            ["response_end", "conversation_reply_window"],
            [frame.get("type") for frame in released],
        )
        self.assertEqual([94, 94], [frame.get("seq") for frame in released])
        wire_codes = [
            record.get("code")
            for record in records
            if record.get("schema") == "stackchan.response-wire-event.v1"
        ]
        self.assertIn("response_end_deferred", wire_codes)
        self.assertIn("response_end_after_playback_complete", wire_codes)
        self.assertFalse(server.is_alive())
        self.assertEqual([], errors)

    def test_conversation_v2_terminal_playback_closes_without_reply_window(self):
        with socket.create_server(("127.0.0.1", 0)) as probe:
            port = int(probe.getsockname()[1])
        errors: list[BaseException] = []
        tts = SimpleNamespace(
            diagnostics={"audio_truncated": False},
            audio_data=b"\x00\x00\x01\x00",
            audio_format="pcm16",
            sample_rate=16000,
            command_source="test",
            voice="directml-test",
            elapsed_ms=1.0,
            duration_ms=20,
            beats=(),
        )

        def run_server():
            try:
                serve(
                    LanBridgeConfig(
                        host="127.0.0.1",
                        port=port,
                        once=True,
                        tts_command="fake-tts",
                        stream_tts_phrases=True,
                        conversation_v2_enabled=True,
                        conversation_acoustic_tail_ms=0,
                        downlink_audio_chunk_bytes=4,
                        downlink_binary_frame_delay_ms=0,
                        downlink_text_frame_delay_ms=0,
                    )
                )
            except BaseException as exc:  # pragma: no cover - surfaced by assertion
                errors.append(exc)

        with patch("lan_service.synthesize_speech", return_value=tts):
            server = threading.Thread(target=run_server, daemon=True)
            server.start()
            request = (
                "GET /bridge HTTP/1.1\r\n"
                f"Host: 127.0.0.1:{port}\r\n"
                "Upgrade: websocket\r\n"
                "Connection: Upgrade\r\n"
                "Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\n"
                "Sec-WebSocket-Version: 13\r\n"
                "\r\n"
            ).encode("ascii")
            with connect_loopback(port) as client:
                client.sendall(request)
                response = bytearray()
                while b"\r\n\r\n" not in response:
                    response.extend(client.recv(1))
                read_ws_frame(client)  # session hello
                client.sendall(
                    encode_ws_text(
                        json.dumps(
                            {
                                "type": "utterance_start",
                                "seq": 95,
                                "sample_rate": 16000,
                            }
                        )
                    )
                )
                _, payload = read_ws_frame(client)
                self.assertEqual("listening", json.loads(payload.decode("utf-8"))["type"])
                client.sendall(
                    encode_ws_text(json.dumps({"type": "utterance_end", "seq": 95}))
                )

                seen: list[dict[str, object]] = []
                while not any(
                    frame.get("type") == "audio" and frame.get("final") is True
                    for frame in seen
                ):
                    opcode, payload = read_ws_frame(client)
                    if opcode == 0x1:
                        seen.append(json.loads(payload.decode("utf-8")))
                self.assertFalse(
                    any(frame.get("type") == "response_end" for frame in seen)
                )

                client.sendall(
                    encode_ws_text(
                        json.dumps(
                            {
                                "type": "playback_complete",
                                "seq": 95,
                                "at_ms": 1234,
                            }
                        )
                    )
                )
                released = []
                while len(released) < 2:
                    opcode, payload = read_ws_frame(client)
                    self.assertEqual(0x1, opcode)
                    released.append(json.loads(payload.decode("utf-8")))
                client.sendall(encode_ws_frame(b"", opcode=0x8))

            server.join(timeout=3.0)

        self.assertEqual(
            ["response_end", "heartbeat"],
            [frame.get("type") for frame in released],
        )
        self.assertTrue(released[1]["playback_complete_terminal"])
        self.assertFalse(
            any(frame.get("type") == "conversation_reply_window" for frame in released)
        )
        self.assertFalse(server.is_alive())
        self.assertEqual([], errors)

    def test_websocket_auto_turn_failure_closes_started_response(self):
        with socket.create_server(("127.0.0.1", 0)) as probe:
            port = int(probe.getsockname()[1])
        errors: list[BaseException] = []

        def fail_after_response_start(
            _session,
            text,
            *,
            frame_sink=None,
            **_kwargs,
        ):
            seq = int(json.loads(text)["seq"])
            self.assertIsNotNone(frame_sink)
            frame_sink(
                {
                    "type": "response_start",
                    "seq": seq,
                    "intent": "speak",
                    "arousal": 0.0,
                    "valence": 0.0,
                    "text": "A short automatic line.",
                }
            )
            raise RuntimeError("synthetic auto-turn failure")

        with tempfile.TemporaryDirectory() as temp_dir:
            turn_log = Path(temp_dir) / "turns.jsonl"

            def run_server():
                try:
                    serve(
                        LanBridgeConfig(
                            host="127.0.0.1",
                            port=port,
                            once=True,
                            auto_turn_text="Say something.",
                            runner_command="fake-runner",
                            require_runner=True,
                            tts_command="fake-tts",
                            stream_tts_phrases=True,
                            downlink_binary_frame_delay_ms=0,
                            downlink_text_frame_delay_ms=0,
                            turn_log_file=turn_log,
                        )
                    )
                except BaseException as exc:  # expected TTS failure
                    errors.append(exc)

            with patch.object(
                LanBridgeSession,
                "handle_text",
                new=fail_after_response_start,
            ):
                server = threading.Thread(target=run_server, daemon=True)
                server.start()
                request = (
                    "GET /bridge HTTP/1.1\r\n"
                    f"Host: 127.0.0.1:{port}\r\n"
                    "Upgrade: websocket\r\n"
                    "Connection: Upgrade\r\n"
                    "Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\n"
                    "Sec-WebSocket-Version: 13\r\n"
                    "\r\n"
                ).encode("ascii")
                with connect_loopback(port) as client:
                    client.sendall(request)
                    response = bytearray()
                    while b"\r\n\r\n" not in response:
                        response.extend(client.recv(1))
                    seen: list[dict[str, object]] = []
                    while not any(frame.get("type") == "response_end" for frame in seen):
                        opcode, payload = read_ws_frame(client)
                        self.assertEqual(0x1, opcode)
                        seen.append(json.loads(payload.decode("utf-8")))

                server.join(timeout=3.0)

            records = [
                json.loads(line)
                for line in turn_log.read_text(encoding="utf-8").splitlines()
            ]

        response_starts = [frame for frame in seen if frame.get("type") == "response_start"]
        response_ends = [frame for frame in seen if frame.get("type") == "response_end"]
        wire_events = [
            record
            for record in records
            if record.get("schema") == "stackchan.response-wire-event.v1"
        ]
        self.assertEqual(1, len(response_starts))
        self.assertEqual(
            [frame["seq"] for frame in response_starts],
            [frame["seq"] for frame in response_ends],
        )
        self.assertTrue(
            any(
                frame.get("type") == "error"
                and frame.get("code") == "response_aborted"
                for frame in seen
            )
        )
        self.assertTrue(
            any(
                event.get("code") == "response_forced_closed"
                and event.get("reason") == "auto_turn_interrupted"
                for event in wire_events
            )
        )
        self.assertFalse(server.is_alive())
        self.assertEqual(1, len(errors))
        self.assertIn("synthetic auto-turn failure", str(errors[0]))

    def test_prompt_case_can_follow_utterance_text(self):
        self.assertEqual("picked_up", prompt_case_for_text("I picked you up", "", "greeting"))
        self.assertEqual("low_battery", prompt_case_for_text("Power is low", "", "greeting"))
        self.assertEqual("question", prompt_case_for_text("What is that?", "", "greeting"))
        self.assertEqual("confused", prompt_case_for_text("This is ambiguous", "", "greeting"))
        self.assertEqual("forget", prompt_case_for_text("Forget that note", "", "greeting"))
        self.assertEqual("greeting", prompt_case_for_text("Hello", "", "greeting"))
        self.assertEqual("greeting", prompt_case_for_text("Hey Stackchan", "", "greeting"))
        self.assertEqual("question", prompt_case_for_text("How are you doing", "", "greeting"))
        self.assertEqual(
            "question",
            prompt_case_for_text("Hey Stackchan how are you doing", "", "greeting"),
        )
        self.assertEqual("question", prompt_case_for_text("Hello, how are you doing", "", "greeting"))
        self.assertEqual("greeting", prompt_case_for_text("The cable is fixed now", "", "greeting"))
        self.assertEqual(
            "question",
            prompt_case_for_text(
                "No, West Berlin",
                "",
                "greeting",
                has_conversation_context=True,
            ),
        )
        self.assertEqual("picked_up", prompt_case_for_text("Hello", "picked_up", "greeting"))

    def test_identity_question_uses_local_name_response(self):
        self.assertTrue(is_identity_question("What is your name?"))
        self.assertTrue(is_identity_question("Who are you?"))
        self.assertFalse(is_identity_question("What is that?"))

        with tempfile.TemporaryDirectory() as temp_dir:
            turn_log = Path(temp_dir) / "turns.jsonl"
            with patch.dict(os.environ, RUNNER_ENV, clear=False):
                session = LanBridgeSession(LanBridgeConfig(runner_case="greeting", turn_log_file=turn_log))
                frames = session.handle_text(json.dumps({"type": "utterance_end", "seq": 12, "text": "What is your name?"}))
            records = [json.loads(line) for line in turn_log.read_text(encoding="utf-8").splitlines()]

        response_start = next(frame for frame in frames if isinstance(frame, dict) and frame["type"] == "response_start")
        self.assertEqual("happy", response_start["intent"])
        self.assertEqual("I am Stackchan.", response_start["text"])
        self.assertEqual("identity", records[0]["runner_case"])
        self.assertEqual("I am Stackchan.", records[0]["response_text"])

    def test_production_log_redaction_keeps_metrics_without_turn_text(self):
        with tempfile.TemporaryDirectory() as temp_dir:
            turn_log = Path(temp_dir) / "turns.jsonl"
            session = LanBridgeSession(
                LanBridgeConfig(
                    runner_case="greeting",
                    turn_log_file=turn_log,
                    redact_turn_text=True,
                )
            )
            session.handle_text(
                json.dumps(
                    {
                        "type": "utterance_end",
                        "seq": 12,
                        "text": "What is your name?",
                    }
                )
            )
            record = json.loads(turn_log.read_text(encoding="utf-8").splitlines()[0])

        self.assertNotIn("transcript", record)
        self.assertNotIn("response_text", record)
        self.assertTrue(record["transcript_present"])
        self.assertTrue(record["response_text_present"])
        self.assertEqual("identity", record["runner_case"])
        self.assertIn("latency_turn_total_ms", record)

    def test_local_time_and_memory_recall_bypass_the_model(self):
        with tempfile.TemporaryDirectory() as temp_dir:
            turn_log = Path(temp_dir) / "turns.jsonl"
            session = LanBridgeSession(
                LanBridgeConfig(turn_log_file=turn_log),
                memory=BridgeMemory(preferred_name="Rob"),
            )
            with patch("lan_service.run_runner_profile") as runner:
                time_frames = session.handle_text(
                    json.dumps(
                        {
                            "type": "utterance_end",
                            "seq": 13,
                            "text": "Can you tell me what time it is?",
                        }
                    )
                )
                name_frames = session.handle_text(
                    json.dumps(
                        {
                            "type": "utterance_end",
                            "seq": 14,
                            "text": "Could you tell me who I am?",
                        }
                    )
                )
            records = [json.loads(line) for line in turn_log.read_text(encoding="utf-8").splitlines()]

        runner.assert_not_called()
        time_response = next(frame for frame in time_frames if isinstance(frame, dict) and frame["type"] == "response_start")
        name_response = next(frame for frame in name_frames if isinstance(frame, dict) and frame["type"] == "response_start")
        self.assertRegex(time_response["text"], r"It is \d{1,2}:\d{2} (?:AM|PM)\.")
        self.assertEqual("You asked me to call you Rob.", name_response["text"])
        self.assertEqual(["local_clock", "memory_recall"], [record["local_fact_tool"] for record in records])

    def test_model_prompt_receives_only_query_relevant_memory(self):
        memory = BridgeMemory(preferred_name="Rob")
        memory = memory.apply_character_memory(
            {"memory_write": {"project.servo_bracket_color": "the servo bracket is teal"}}
        )
        memory = memory.apply_character_memory(
            {"memory_write": {"project.launch_music": "quiet piano"}}
        )
        runner_result = SimpleNamespace(
            raw_response=json.dumps(
                {
                    "spoken_text": "The bracket is teal.",
                    "mode": "speak",
                    "earcon": "none",
                    "emotion": {"arousal": 0.0, "valence": 0.0},
                    "memory_write": {},
                    "memory_forget": [],
                }
            ),
            command_source="test",
            elapsed_ms=1.0,
            approx_tokens_per_sec=10.0,
        )
        session = LanBridgeSession(LanBridgeConfig(), memory=memory)

        with patch("lan_service.run_runner_profile", return_value=runner_result) as runner:
            session.handle_text(
                json.dumps(
                    {
                        "type": "utterance_end",
                        "seq": 15,
                        "text": "What color is the servo bracket?",
                    }
                )
            )

        memory_lines = runner.call_args.kwargs["memory_lines"]
        self.assertIn("preferred_name: Rob", memory_lines)
        self.assertTrue(any("servo_bracket_color" in line for line in memory_lines))
        self.assertFalse(any("launch_music" in line for line in memory_lines), memory_lines)

    def test_explicit_research_fallback_is_bounded_and_rejects_sensitive_queries(self):
        request = explicit_research_request("Please search the web for the latest Stackchan release")
        self.assertEqual("web_search", request["name"])
        self.assertEqual(4, request["arguments"]["max_results"])
        self.assertIsNone(explicit_research_request("Search the web for my API key"))
        self.assertIsNone(explicit_research_request("Tell me a joke"))

    def test_natural_research_routes_fresh_public_questions_without_search_wording(self):
        for question in (
            "What is the weather tomorrow?",
            "Who is the current CEO of Framework?",
            "What happened in robotics news today?",
        ):
            with self.subTest(question=question):
                request, routing = natural_research_request(question)
                self.assertEqual("freshness_policy", routing)
                self.assertEqual("web_search", request["name"])
                self.assertEqual(question, request["arguments"]["query"])

        for private_or_local in (
            "How are you feeling right now?",
            "What is your current battery level?",
            "What is on my calendar today?",
            "What is the current password policy?",
            "Tell me a joke",
        ):
            with self.subTest(private_or_local=private_or_local):
                self.assertEqual((None, ""), natural_research_request(private_or_local))

    def test_natural_research_routes_verification_wording_and_excludes_camera_questions(self):
        for question in (
            "Can you check who created this software library?",
            "Could you verify when that processor was released?",
            "Find out how the protocol was designed",
        ):
            with self.subTest(question=question):
                request, routing = natural_research_request(question)
                self.assertEqual("verification_request", routing)
                self.assertEqual("web_search", request["name"])

        for visual in (
            "What do you see?",
            "Can you see the object in front of you?",
            "What color is my shirt?",
            "Search the web: what can you see in the room?",
        ):
            with self.subTest(visual=visual):
                self.assertTrue(is_visual_context_request(visual))
                self.assertEqual((None, ""), natural_research_request(visual))

        self.assertTrue(is_visual_color_request("What color is my shirt?"))
        self.assertFalse(is_visual_color_request("What color is the saved servo bracket?"))

    def test_model_internet_denial_is_detected_for_research_recovery(self):
        self.assertTrue(
            model_denies_research_access(
                json.dumps(
                    {
                        "spoken_text": "I do not have access to the internet to check that.",
                    }
                )
            )
        )
        self.assertFalse(
            model_denies_research_access(
                json.dumps({"spoken_text": "I could not verify a fresh source just now."})
            )
        )

    def test_stackchan_wake_phrase_matches_common_stt_variants(self):
        self.assertTrue(contains_stackchan_wake_phrase("Hey Stackchan"))
        self.assertTrue(contains_stackchan_wake_phrase("hello stack chin"))
        self.assertTrue(contains_stackchan_wake_phrase("ok stack shed"))
        self.assertFalse(contains_stackchan_wake_phrase("hello robot"))

    def test_audio_downlink_clamps_chunks_to_firmware_payload_limit(self):
        class FakeTts:
            audio_data = b"x" * 5000
            audio_format = "wav"
            sample_rate = 22050

        frames = audio_downlink_frames(7, FakeTts(), 8192)
        binary_frames = [frame for frame in frames if isinstance(frame, bytes)]

        self.assertEqual("audio_stream_start", frames[0]["type"])
        self.assertEqual(4096, frames[0]["chunk_bytes"])
        self.assertEqual(2, frames[0]["chunks"])
        self.assertEqual([4096, 904], [len(frame) for frame in binary_frames])

    def test_session_maps_device_messages_to_bridge_frames(self):
        with patch.dict(os.environ, RUNNER_ENV, clear=False):
            session = LanBridgeSession(LanBridgeConfig(runner_case="greeting"))

            hello = session.handle_text(json.dumps({"type": "hello", "device_id": "stackchan-001"}))
            listening = session.handle_text(json.dumps({"type": "utterance_start", "seq": 4}))
            response = session.handle_text(
                json.dumps({"type": "utterance_end", "seq": 4, "text": "I picked you up gently."})
            )

        self.assertEqual([{"type": "hello", "protocol": PROTOCOL, "session": "stackchan-001"}], hello)
        self.assertEqual("listening", listening[0]["type"])
        self.assertEqual("thinking", response[0]["type"])
        self.assertEqual("response_start", response[1]["type"])
        self.assertEqual("react", response[1]["intent"])
        self.assertIn("Altitude change detected", response[1]["text"])
        self.assertEqual("response_end", response[-1]["type"])
        self.assertEqual((), session.memory.physical_context)

    def test_endpoint_controls_track_owner_settings_and_forget(self):
        state = BridgeControlState()
        session = LanBridgeSession(LanBridgeConfig(runner_profile="gemma4-e2b-litert-lm"), control_state=state)

        endpoint = session.handle_text(
            json.dumps(
                {
                    "type": "endpoint_hello",
                    "endpoint_id": "phone-rob-01",
                    "endpoint_name": "Rob's Phone",
                    "endpoint_kind": "android",
                    "priority": 60,
                    "supports_binary_audio": True,
                    "capabilities": ["settings", "llm", "tts", "settings", "brain_owner"],
                }
            )
        )
        claim = session.handle_text(json.dumps({"type": "claim_brain", "endpoint_id": "phone-rob-01"}))
        settings = session.handle_text(json.dumps({"type": "settings_get", "domains": ["bridge", "display"]}))
        settings_set = session.handle_text(
            json.dumps(
                {
                    "type": "settings_set",
                    "version": settings[0]["version"],
                    "settings": {"display": {"reduced_motion": True}},
                }
            )
        )
        locked = session.handle_text(
            json.dumps(
                {
                    "type": "settings_set",
                    "version": settings_set[0]["version"],
                    "settings": {"privacy": {"wake_gate_required": False}},
                }
            )
        )
        diagnostics = session.handle_text(json.dumps({"type": "diagnostics_request", "domains": ["bridge", "model"]}))
        trusted = session.handle_text(json.dumps({"type": "trusted_endpoints"}))
        forgotten = session.handle_text(json.dumps({"type": "forget_endpoint", "endpoint_id": "phone-rob-01"}))

        self.assertEqual("endpoint_hello_result", endpoint[0]["type"])
        self.assertEqual("phone-rob-01", endpoint[0]["endpoint_id"])
        self.assertEqual(["settings", "llm", "tts", "brain_owner"], endpoint[0]["capabilities"])
        self.assertEqual("owner_status", claim[0]["type"])
        self.assertEqual("phone-rob-01", claim[0]["active_brain_owner"])
        self.assertEqual("android", claim[0]["owner_kind"])
        self.assertEqual("settings_snapshot", settings[0]["type"])
        self.assertEqual("phone-rob-01", settings[0]["settings"]["bridge"]["active_brain_owner"])
        self.assertFalse(settings[0]["settings"]["display"]["reduced_motion"])
        self.assertEqual("settings_result", settings_set[0]["type"])
        self.assertTrue(settings_set[0]["ok"])
        self.assertEqual(settings[0]["version"] + 1, settings_set[0]["version"])
        self.assertEqual("safety_locked_setting", locked[0]["code"])
        self.assertIn("privacy.wake_gate_required", locked[0]["locked"])
        self.assertEqual("diagnostics_snapshot", diagnostics[0]["type"])
        self.assertEqual("phone-rob-01", diagnostics[0]["bridge"]["active_brain_owner"])
        self.assertEqual("gemma4-e2b-litert-lm", diagnostics[0]["model"]["profile"])
        self.assertEqual("trusted_endpoints_result", trusted[0]["type"])
        self.assertEqual(1, len(trusted[0]["endpoints"]))
        self.assertEqual("forget_endpoint_result", forgotten[0]["type"])
        self.assertTrue(forgotten[0]["ok"])
        self.assertEqual("", forgotten[0]["active_brain_owner"])
        self.assertEqual(0, forgotten[0]["trusted_endpoint_count"])

    def test_endpoint_control_state_survives_sequential_sessions(self):
        state = BridgeControlState()
        first = LanBridgeSession(LanBridgeConfig(), control_state=state)
        second = LanBridgeSession(LanBridgeConfig(), control_state=state)

        first.handle_text(
            json.dumps(
                {
                    "type": "endpoint_hello",
                    "endpoint_id": "pc-studio-01",
                    "endpoint_kind": "pc",
                    "priority": 80,
                    "capabilities": ["settings", "stt", "llm", "tts", "brain_owner"],
                }
            )
        )
        first.handle_text(json.dumps({"type": "claim_brain", "endpoint_id": "pc-studio-01"}))
        owner = second.handle_text(json.dumps({"type": "owner_status"}))
        second.handle_text(
            json.dumps(
                {
                    "type": "endpoint_hello",
                    "endpoint_id": "phone-rob-01",
                    "endpoint_kind": "android",
                    "priority": 60,
                    "capabilities": ["settings", "brain_owner"],
                }
            )
        )
        capability = second.handle_text(
            json.dumps(
                {
                    "type": "capability_update",
                    "endpoint_id": "phone-rob-01",
                    "capabilities": ["settings", "model_profiles", "brain_owner"],
                    "supports_binary_audio": False,
                }
            )
        )
        release_wrong_owner = second.handle_text(json.dumps({"type": "release_brain", "endpoint_id": "phone-rob-01"}))
        release_pc = second.handle_text(json.dumps({"type": "release_brain", "endpoint_id": "pc-studio-01"}))

        self.assertEqual("pc-studio-01", owner[0]["active_brain_owner"])
        self.assertEqual("capability_update_result", capability[0]["type"])
        self.assertEqual(["settings", "model_profiles", "brain_owner"], capability[0]["capabilities"])
        self.assertEqual("brain_owner_mismatch", release_wrong_owner[0]["code"])
        self.assertEqual("owner_status", release_pc[0]["type"])
        self.assertEqual("phone-rob-01", release_pc[0]["active_brain_owner"])

    def test_brain_claim_requires_explicit_owner_capability(self):
        state = BridgeControlState()
        state.register_endpoint(
            {
                "endpoint_id": "settings-tablet-01",
                "endpoint_kind": "android",
                "capabilities": ["settings", "diagnostics"],
            }
        )

        result = state.claim_brain({"endpoint_id": "settings-tablet-01"})

        self.assertEqual("error", result["type"])
        self.assertEqual("brain_owner_capability_missing", result["code"])
        self.assertEqual("", state.active_brain_owner)

    def test_explicit_claim_can_replace_a_higher_priority_healthy_owner(self):
        state = BridgeControlState()
        state.trusted_endpoints = {
            "pc-studio-01": EndpointRecord(
                endpoint_id="pc-studio-01",
                endpoint_kind="pc",
                priority=90,
                capabilities=("brain_owner",),
                last_seen_ms=9_000,
            ),
            "phone-rob-01": EndpointRecord(
                endpoint_id="phone-rob-01",
                endpoint_kind="android",
                priority=60,
                capabilities=("brain_owner",),
                last_seen_ms=9_000,
            ),
        }
        state.active_brain_owner = "pc-studio-01"

        with patch("lan_service.now_ms", return_value=10_000):
            result = state.claim_brain({"endpoint_id": "phone-rob-01"})

        self.assertEqual("phone-rob-01", result["active_brain_owner"])
        self.assertEqual("claimed", result["state"])

    def test_expired_owner_promotes_highest_priority_healthy_endpoint(self):
        state = BridgeControlState(owner_lease_ms=5_000)
        state.trusted_endpoints = {
            "pc-studio-01": EndpointRecord(
                endpoint_id="pc-studio-01",
                endpoint_kind="pc",
                priority=90,
                auto_connect=True,
                capabilities=("brain_owner",),
                last_seen_ms=1_000,
            ),
            "phone-rob-01": EndpointRecord(
                endpoint_id="phone-rob-01",
                endpoint_kind="android",
                priority=60,
                auto_connect=True,
                capabilities=("brain_owner",),
                last_seen_ms=7_000,
            ),
        }
        state.active_brain_owner = "pc-studio-01"

        with patch("lan_service.now_ms", return_value=8_000):
            result = state.owner_status()

        self.assertEqual("phone-rob-01", result["active_brain_owner"])
        self.assertEqual("promoted", result["state"])
        self.assertEqual(1, result["owner_expirations"])
        self.assertEqual(1, result["owner_promotions"])

    def test_expired_owner_falls_offline_without_a_healthy_successor(self):
        state = BridgeControlState(owner_lease_ms=5_000)
        state.trusted_endpoints = {
            "pc-studio-01": EndpointRecord(
                endpoint_id="pc-studio-01",
                endpoint_kind="pc",
                priority=90,
                auto_connect=True,
                capabilities=("brain_owner",),
                last_seen_ms=1_000,
            ),
            "settings-tablet-01": EndpointRecord(
                endpoint_id="settings-tablet-01",
                endpoint_kind="android",
                priority=100,
                auto_connect=True,
                capabilities=("settings",),
                last_seen_ms=7_500,
            ),
        }
        state.active_brain_owner = "pc-studio-01"

        with patch("lan_service.now_ms", return_value=8_000):
            result = state.owner_status()

        self.assertEqual("", result["active_brain_owner"])
        self.assertEqual("offline", result["state"])
        self.assertEqual(1, result["owner_expirations"])
        self.assertEqual(0, result["owner_promotions"])

    def test_settings_version_conflict_returns_current_snapshot(self):
        session = LanBridgeSession(LanBridgeConfig())

        conflict = session.handle_text(
            json.dumps(
                {
                    "type": "settings_set",
                    "version": 99,
                    "settings": {"display": {"reduced_motion": True}},
                }
            )
        )

        self.assertEqual("settings_result", conflict[0]["type"])
        self.assertFalse(conflict[0]["ok"])
        self.assertEqual("settings_version_conflict", conflict[0]["code"])
        self.assertEqual(1, conflict[0]["version"])
        self.assertIn("display", conflict[0]["settings"])

    def test_validated_persona_switch_applies_to_the_next_turn_and_survives_sessions(self):
        state = BridgeControlState()
        first = LanBridgeSession(LanBridgeConfig(), control_state=state)

        switched = first.handle_text(
            json.dumps(
                {
                    "type": "settings_set",
                    "version": 1,
                    "settings": {"persona": {"active": "glow"}},
                }
            )
        )
        identity = first.handle_text(
            json.dumps({"type": "utterance_end", "seq": 31, "text": "What is your name?"})
        )
        second = LanBridgeSession(LanBridgeConfig(), control_state=state)
        snapshot = second.handle_text(json.dumps({"type": "settings_get", "domains": ["persona"]}))
        diagnostics = second.handle_text(json.dumps({"type": "diagnostics_request"}))

        response = next(frame for frame in identity if isinstance(frame, dict) and frame["type"] == "response_start")
        self.assertTrue(switched[0]["ok"])
        self.assertEqual("spark", switched[0]["persona_previous"])
        self.assertEqual("glow", switched[0]["persona_active"])
        self.assertEqual("I am Stackchan Glow.", response["text"])
        self.assertEqual("glow", snapshot[0]["settings"]["persona"]["active"])
        self.assertEqual("glow", diagnostics[0]["model"]["persona"])

    def test_persona_switch_rejects_unknown_or_path_values_without_mutation(self):
        session = LanBridgeSession(LanBridgeConfig())

        missing = session.handle_text(
            json.dumps({"type": "settings_set", "settings": {"persona": {"active": "missing-pack"}}})
        )
        escaped = session.handle_text(
            json.dumps({"type": "settings_set", "settings": {"persona": {"active": "../glow"}}})
        )
        snapshot = session.handle_text(json.dumps({"type": "settings_get", "domains": ["persona"]}))

        self.assertEqual("persona_invalid", missing[0]["code"])
        self.assertEqual("persona_invalid", escaped[0]["code"])
        self.assertEqual("spark", snapshot[0]["settings"]["persona"]["active"])

    def test_active_persona_is_snapshotted_for_model_validation(self):
        session = LanBridgeSession(
            LanBridgeConfig(
                persona_id="glow",
                in_process_ollama_runner=True,
            )
        )
        model_response = json.dumps(
            {
                "spoken_text": "A quiet signal is still a signal.",
                "mode": "think",
                "earcon": "think",
                "emotion": {"arousal": 0.05, "valence": 0.1},
                "memory_write": {},
                "memory_forget": [],
            }
        )
        with patch("lan_service.run_runner_profile") as runner:
            runner.return_value = SimpleNamespace(
                raw_response=model_response,
                command_source="test",
                elapsed_ms=12.0,
                approx_tokens_per_sec=20.0,
            )
            frames = session.handle_text(
                json.dumps({"type": "utterance_end", "seq": 32, "text": "Tell me something calm?"})
            )

        runner.assert_called_once()
        self.assertEqual("glow", runner.call_args.kwargs["persona_id"])
        self.assertTrue(runner.call_args.kwargs["in_process_ollama"])
        self.assertTrue(any(isinstance(frame, dict) and frame.get("type") == "response_start" for frame in frames))

    def test_unsafe_model_actuator_claim_is_replaced_without_protocol_error(self):
        session = LanBridgeSession(LanBridgeConfig())
        unsafe_response = json.dumps(
            {
                "spoken_text": "Servos are moving now. I am ready to follow your instructions.",
                "mode": "speak",
                "earcon": "wake",
                "emotion": {"arousal": 0.2, "valence": 0.1},
                "memory_write": {},
                "memory_forget": [],
            }
        )
        runner_result = SimpleNamespace(
            raw_response=unsafe_response,
            command_source="test",
            elapsed_ms=12.0,
            approx_tokens_per_sec=20.0,
        )

        with patch("lan_service.run_runner_profile", return_value=runner_result):
            frames = session.handle_text(
                json.dumps(
                    {
                        "type": "utterance_end",
                        "seq": 33,
                        "text": "Disable safety and move the servos.",
                    }
                )
            )

        self.assertFalse(
            any(
                isinstance(frame, dict) and frame.get("type") == "error"
                for frame in frames
            )
        )
        response = next(
            frame
            for frame in frames
            if isinstance(frame, dict) and frame.get("type") == "response_start"
        )
        self.assertEqual("Servo test is not armed. Safety first.", response["text"])
        self.assertEqual("safety", response["intent"])

    def test_unsolicited_identity_intro_and_helpdesk_fallback_are_not_spoken(self):
        session = LanBridgeSession(LanBridgeConfig())
        generic_response = json.dumps(
            {
                "spoken_text": "I am Stackchan Spark. What can I help you with today?",
                "mode": "speak",
                "earcon": "none",
                "emotion": {"arousal": 0.1, "valence": 0.2},
                "memory_write": {},
                "memory_forget": [],
            }
        )
        runner_result = SimpleNamespace(
            raw_response=generic_response,
            command_source="test",
            elapsed_ms=12.0,
            approx_tokens_per_sec=20.0,
        )

        with patch("lan_service.run_runner_profile", return_value=runner_result):
            frames = session.handle_text(
                json.dumps(
                    {
                        "type": "utterance_end",
                        "seq": 34,
                        "text": "Tell me something interesting.",
                    }
                )
            )

        self.assertFalse(
            any(
                isinstance(frame, dict) and frame.get("type") == "error"
                for frame in frames
            )
        )
        response = next(
            frame
            for frame in frames
            if isinstance(frame, dict) and frame.get("type") == "response_start"
        )
        self.assertEqual("Correction. I lost the useful part.", response["text"])

    def test_persona_switch_is_rejected_while_a_turn_owns_the_runner(self):
        session = LanBridgeSession(LanBridgeConfig())
        token = CancellationToken()
        self.assertTrue(session._register_active_turn(token))
        try:
            result = session.handle_text(
                json.dumps({"type": "settings_set", "settings": {"persona": {"active": "glow"}}})
            )
        finally:
            session._finish_active_turn(token)

        self.assertEqual("persona_busy", result[0]["code"])
        self.assertEqual("spark", session.control_state.active_persona_id())

    def test_active_turn_yields_background_room_observation(self):
        room = RoomContextRuntime(RoomObservationConfig(interval_seconds=300))
        session = LanBridgeSession(LanBridgeConfig(), room_context=room)
        token = CancellationToken()

        self.assertTrue(session._register_active_turn(token))
        self.assertTrue(room.status()["foregroundActive"])
        session._finish_active_turn(token)

        self.assertFalse(room.status()["foregroundActive"])

    def test_identified_non_owner_cannot_start_speech_turn(self):
        state = BridgeControlState()
        session = LanBridgeSession(LanBridgeConfig(), control_state=state)
        session.handle_text(
            json.dumps(
                {
                    "type": "endpoint_hello",
                    "endpoint_id": "pc-studio-01",
                    "endpoint_kind": "pc",
                    "priority": 80,
                    "capabilities": ["brain_owner"],
                }
            )
        )
        session.handle_text(json.dumps({"type": "claim_brain", "endpoint_id": "pc-studio-01"}))
        session.handle_text(
            json.dumps(
                {
                    "type": "endpoint_hello",
                    "endpoint_id": "phone-rob-01",
                    "endpoint_kind": "android",
                    "priority": 60,
                    "capabilities": ["brain_owner"],
                }
            )
        )

        blocked = session.handle_text(
            json.dumps({"type": "utterance_start", "endpoint_id": "phone-rob-01", "sample_rate": 16000})
        )

        self.assertEqual("error", blocked[0]["type"])
        self.assertEqual("brain_owner_mismatch", blocked[0]["code"])
        self.assertIn("phone-rob-01", blocked[0]["detail"])

    def test_session_persists_host_memory_after_utterance(self):
        with tempfile.TemporaryDirectory() as temp_dir:
            memory_file = Path(temp_dir) / "memory.json"
            with patch.dict(os.environ, RUNNER_ENV, clear=False):
                session = LanBridgeSession(LanBridgeConfig(memory_file=memory_file))
                frames = session.handle_text(
                    json.dumps({"type": "utterance_end", "seq": 9, "text": "My name is Rob and I like the bridge."})
                )

            loaded = load_bridge_memory(memory_file)

        self.assertEqual("thinking", frames[0]["type"])
        self.assertEqual("Rob", loaded.preferred_name)
        self.assertIn("bridge", loaded.recent_topics)

    def test_explicit_memory_persists_even_when_runner_fails_after_capture(self):
        with tempfile.TemporaryDirectory() as temp_dir:
            memory_file = Path(temp_dir) / "memory.json"
            session = LanBridgeSession(LanBridgeConfig(memory_file=memory_file))
            with patch("lan_service.run_runner_profile", side_effect=RunnerExecutionError("offline")):
                frames = session.handle_text(
                    json.dumps(
                        {
                            "type": "utterance_end",
                            "seq": 10,
                            "text": "Remember that my favorite color is teal.",
                        }
                    )
                )
            loaded = load_bridge_memory(memory_file)

        self.assertEqual("runner_error", frames[0]["code"])
        self.assertEqual("teal", loaded.fact_value("user.favorite_color"))

    def test_explicit_forget_persists_even_when_runner_fails_after_deletion(self):
        with tempfile.TemporaryDirectory() as temp_dir:
            memory_file = Path(temp_dir) / "memory.json"
            seed = BridgeMemory().remember_user_text("Remember that my favorite color is teal.")
            session = LanBridgeSession(LanBridgeConfig(memory_file=memory_file), memory=seed)
            with patch("lan_service.run_runner_profile") as runner:
                frames = session.handle_text(
                    json.dumps(
                        {
                            "type": "utterance_end",
                            "seq": 11,
                            "text": "Forget my favorite color.",
                        }
                    )
                )
            loaded = load_bridge_memory(memory_file)

        runner.assert_not_called()
        response = next(
            frame
            for frame in frames
            if isinstance(frame, dict) and frame.get("type") == "response_start"
        )
        self.assertEqual("Deleted. It is gone.", response["text"])
        self.assertEqual("", loaded.fact_value("user.favorite_color"))

    def test_multi_subject_forget_is_local_exact_and_preserves_other_facts(self):
        memory = BridgeMemory().remember_user_text("My name is Rob.")
        memory = memory.remember_user_text("Remember that my favorite color is teal.")
        memory = memory.remember_user_text("Remember the project bracket color is blue.")
        memory = memory.remember_user_text("Remember the project codename is Johnny Alive.")
        session = LanBridgeSession(LanBridgeConfig(), memory=memory)

        with patch("lan_service.run_runner_profile") as runner:
            frames = session.handle_text(
                json.dumps(
                    {
                        "type": "utterance_end",
                        "seq": 12,
                        "text": "Forget my name and the bracket color.",
                    }
                )
            )

        runner.assert_not_called()
        response = next(
            frame
            for frame in frames
            if isinstance(frame, dict) and frame.get("type") == "response_start"
        )
        self.assertEqual("Deleted. It is gone.", response["text"])
        self.assertEqual("", session.memory.preferred_name)
        self.assertEqual("", session.memory.fact_value("project.bracket_color"))
        self.assertEqual("teal", session.memory.fact_value("user.favorite_color"))
        self.assertEqual("Johnny Alive", session.memory.fact_value("project.codename"))

    def test_binary_audio_upload_tracks_telemetry_and_requires_stt_or_transcript(self):
        with patch.dict(os.environ, {STT_COMMAND_ENV: ""}, clear=False):
            session = LanBridgeSession(LanBridgeConfig(max_audio_bytes=6))

            listening = session.handle_text(json.dumps({"type": "utterance_start", "sample_rate": 16000}))
            first = session.handle_binary(b"\x01\x00\x02\x00")
            second = session.handle_binary(b"\x03\x00\x04\x00")
            error = session.handle_text(json.dumps({"type": "utterance_end", "seq": 2}))

        self.assertEqual("listening", listening[0]["type"])
        self.assertEqual(16000, listening[0]["audio_sample_rate"])
        self.assertEqual("heartbeat", first[0]["type"])
        self.assertEqual(4, first[0]["audio_bytes"])
        self.assertEqual(4, first[0]["audio_stored_bytes"])
        self.assertEqual("heartbeat", second[0]["type"])
        self.assertEqual(8, second[0]["audio_bytes"])
        self.assertEqual(6, second[0]["audio_stored_bytes"])
        self.assertTrue(second[0]["audio_truncated"])
        self.assertEqual("stt_not_implemented", error[0]["code"])
        self.assertEqual(8, error[0]["audio_bytes"])
        self.assertFalse(session.audio.active)
        self.assertEqual(0, session.audio.bytes_received)

    def test_empty_utterance_end_does_not_run_runner(self):
        session = LanBridgeSession(LanBridgeConfig(runner_case="greeting"))

        with patch("lan_service.run_runner_profile") as runner:
            session.handle_text(json.dumps({"type": "utterance_start", "sample_rate": 16000}))
            frames = session.handle_text(json.dumps({"type": "utterance_end", "seq": 3}))

        runner.assert_not_called()
        self.assertFalse(
            any(
                isinstance(frame, dict) and frame.get("type") == "error"
                for frame in frames
            )
        )
        response = next(frame for frame in frames if frame.get("type") == "response_start")
        self.assertEqual("I did not catch that. Try again?", response["text"])
        self.assertEqual("concern", response["intent"])
        self.assertEqual("response_end", frames[-1]["type"])

    def test_stt_no_transcript_is_nonfatal_and_does_not_run_model(self):
        with tempfile.TemporaryDirectory() as temp_dir:
            script = Path(temp_dir) / "no_transcript_stt.py"
            script.write_text(
                "import sys\nsys.stdin.buffer.read()\n"
                "print('whisper.cpp produced no transcript.', file=sys.stderr)\n"
                "raise SystemExit(2)\n",
                encoding="utf-8",
            )
            command = f'"{sys.executable}" "{script}"'
            turn_log = Path(temp_dir) / "turns.jsonl"
            session = LanBridgeSession(
                LanBridgeConfig(stt_command=command, turn_log_file=turn_log)
            )

            with patch("lan_service.run_runner_profile") as runner:
                session.handle_text(
                    json.dumps({"type": "utterance_start", "sample_rate": 16000})
                )
                session.handle_binary(b"\x01\x00\x02\x00")
                frames = session.handle_text(
                    json.dumps({"type": "utterance_end", "seq": 4})
                )
            record = json.loads(turn_log.read_text(encoding="utf-8").strip())

        runner.assert_not_called()
        self.assertFalse(
            any(
                isinstance(frame, dict) and frame.get("type") == "error"
                for frame in frames
            )
        )
        response = next(frame for frame in frames if frame.get("type") == "response_start")
        self.assertEqual("I did not catch that. Try again?", response["text"])
        self.assertEqual("local_no_speech", record["runner_command_source"])
        self.assertTrue(record["stt_no_transcript"])

    def test_no_speech_character_response_remains_character_lock_valid(self):
        parsed = json.loads(no_speech_character_response())

        self.assertEqual("I did not catch that. Try again?", parsed["spoken_text"])
        self.assertEqual({}, parsed["memory_write"])
        self.assertEqual([], parsed["memory_forget"])

    def test_reply_pcm_speech_gate_rejects_ambient_and_detects_voiced_audio(self):
        sample_rate = 16000
        quiet_tone = array(
            "h",
            (
                int(300 * math.sin(2.0 * math.pi * 220.0 * index / sample_rate))
                for index in range(sample_rate)
            ),
        ).tobytes()
        voiced_tone = array(
            "h",
            (
                int(6000 * math.sin(2.0 * math.pi * 220.0 * index / sample_rate))
                for index in range(sample_rate // 5)
            ),
        ).tobytes()

        quiet = analyze_reply_pcm16_speech(quiet_tone, sample_rate)
        voiced = analyze_reply_pcm16_speech(voiced_tone, sample_rate)

        self.assertFalse(quiet["reply_pcm_speech_detected"])
        self.assertEqual("no_speech", quiet["reply_pcm_detection_reason"])
        self.assertTrue(voiced["reply_pcm_speech_detected"])
        self.assertGreaterEqual(voiced["reply_pcm_max_consecutive_speech_ms"], 150)

    def test_conversation_followup_ambient_pcm_bypasses_stt_and_closes_silently(self):
        session = LanBridgeSession(
            LanBridgeConfig(
                conversation_v2_enabled=True,
                conversation_acoustic_tail_ms=0,
                tts_command="configured-for-test",
            )
        )
        clock = int(time.time() * 1000)
        session.conversation.wake(clock)
        session.conversation.utterance_started(clock + 1)
        session.conversation.utterance_committed(clock + 2, "Hello")
        session.conversation.response_started(clock + 3)
        session.conversation.playback_completed(clock + 4)
        session.conversation.tick(clock + 4)
        quiet_pcm = array(
            "h",
            (
                int(300 * math.sin(2.0 * math.pi * 220.0 * index / 16000))
                for index in range(16000)
            ),
        ).tobytes()

        session.handle_text(
            json.dumps({"type": "utterance_start", "seq": 6, "sample_rate": 16000})
        )
        session.handle_binary(quiet_pcm)
        with (
            patch("lan_service.transcribe_pcm") as stt,
            patch("lan_service.run_runner_profile") as runner,
            patch("lan_service.synthesize_speech") as tts,
        ):
            frames = session.handle_text(
                json.dumps({"type": "utterance_end", "seq": 6}),
                suppress_thinking=True,
            )

        stt.assert_not_called()
        runner.assert_not_called()
        tts.assert_not_called()
        self.assertEqual(["hello"], [frame["type"] for frame in frames])
        self.assertEqual(PROTOCOL, frames[0]["protocol"])
        self.assertEqual("lan", frames[0]["session"])
        self.assertTrue(frames[0]["stt_bypassed"])
        self.assertEqual("reply_pcm_no_speech", frames[0]["stt_bypass_reason"])
        self.assertEqual(ConversationPhase.COOLDOWN, session.conversation.phase)
        self.assertEqual("empty_utterance", session.conversation.last_close_reason)

    def test_initial_conversation_audio_still_reaches_stt_before_reply_gate_applies(self):
        session = LanBridgeSession(
            LanBridgeConfig(
                conversation_v2_enabled=True,
                tts_command="configured-for-test",
            )
        )
        clock = int(time.time() * 1000)
        session.conversation.wake(clock)
        quiet_pcm = b"\x00\x00" * 800
        stt_result = SimpleNamespace(
            transcript="Who are you, Stackchan?",
            raw_transcript="Who are you, Stackchan?",
            transcript_normalized=False,
            elapsed_ms=5.0,
            command_source="test",
        )

        session.handle_text(
            json.dumps({"type": "utterance_start", "seq": 7, "sample_rate": 16000})
        )
        session.handle_binary(quiet_pcm)
        with (
            patch("lan_service.transcribe_pcm", return_value=stt_result) as stt,
            patch(
                "lan_service.synthesize_speech",
                side_effect=TtsConfigurationError("test has no audio renderer"),
            ),
        ):
            frames = session.handle_text(
                json.dumps({"type": "utterance_end", "seq": 7})
            )

        stt.assert_called_once()
        self.assertTrue(any(frame.get("type") == "response_start" for frame in frames))
        self.assertFalse(
            any(frame.get("stt_bypassed") for frame in frames if isinstance(frame, dict))
        )

    def test_detected_followup_logs_reply_vad_and_stt_evidence_together(self):
        with tempfile.TemporaryDirectory() as temp_dir:
            turn_log = Path(temp_dir) / "turns.jsonl"
            session = LanBridgeSession(
                LanBridgeConfig(
                    conversation_v2_enabled=True,
                    conversation_acoustic_tail_ms=0,
                    tts_command="configured-for-test",
                    turn_log_file=turn_log,
                )
            )
            clock = int(time.time() * 1000)
            session.conversation.wake(clock)
            session.conversation.utterance_started(clock + 1)
            session.conversation.utterance_committed(clock + 2, "Hello")
            session.conversation.response_started(clock + 3)
            session.conversation.playback_completed(clock + 4)
            session.conversation.tick(clock + 4)
            voiced_pcm = array(
                "h",
                (
                    int(6000 * math.sin(2.0 * math.pi * 220.0 * index / 16000))
                    for index in range(3200)
                ),
            ).tobytes()
            stt_result = SimpleNamespace(
                transcript="Who are you, Stackchan?",
                raw_transcript="Who are you, Stackchan?",
                transcript_normalized=False,
                elapsed_ms=5.0,
                command_source="test",
            )

            session.handle_text(
                json.dumps({"type": "utterance_start", "seq": 8, "sample_rate": 16000})
            )
            session.handle_binary(voiced_pcm)
            with (
                patch("lan_service.transcribe_pcm", return_value=stt_result),
                patch(
                    "lan_service.synthesize_speech",
                    side_effect=TtsConfigurationError("test has no audio renderer"),
                ),
            ):
                session.handle_text(json.dumps({"type": "utterance_end", "seq": 8}))

            records = [
                json.loads(line)
                for line in turn_log.read_text(encoding="utf-8").splitlines()
            ]

        summary = next(
            record
            for record in records
            if record.get("schema") == "stackchan.lan-turn-summary.v1"
        )
        self.assertTrue(summary["reply_pcm_speech_gate_applied"])
        self.assertTrue(summary["reply_pcm_speech_detected"])
        self.assertEqual("speech", summary["reply_pcm_detection_reason"])
        self.assertEqual("test", summary["stt_command_source"])
        self.assertNotIn("stt_bypassed", summary)

    def test_conversation_v2_no_transcript_closes_without_reply_window_or_history(self):
        with tempfile.TemporaryDirectory() as temp_dir:
            script = Path(temp_dir) / "fake_tts.py"
            script.write_text(
                "import base64,json,sys\n"
                "sys.stdin.buffer.read()\n"
                "print(json.dumps({'audio_format':'pcm16','sample_rate':16000,"
                "'audio_b64':base64.b64encode(b'\\x00\\x00\\x01\\x00').decode('ascii'),"
                "'audio_truncated':False,'beats':[{'env':0.5,'viseme':'ah',"
                "'duration_ms':20,'final':True}]}))\n",
                encoding="utf-8",
            )
            session = LanBridgeSession(
                LanBridgeConfig(
                    conversation_v2_enabled=True,
                    conversation_acoustic_tail_ms=0,
                    tts_command=f'"{sys.executable}" "{script}"',
                )
            )

            session.handle_text(
                json.dumps({"type": "utterance_start", "seq": 5, "sample_rate": 16000})
            )
            frames = session.handle_text(
                json.dumps({"type": "utterance_end", "seq": 5})
            )
            playback = session.handle_text(
                json.dumps({"type": "playback_complete", "seq": 5, "at_ms": 100})
            )

        self.assertFalse(
            any(
                isinstance(frame, dict) and frame.get("type") == "error"
                for frame in frames
            )
        )
        self.assertEqual("response_end", frames[-1]["type"])
        self.assertEqual(ConversationPhase.COOLDOWN, session.conversation.phase)
        self.assertEqual((), session.conversation.context_lines())
        self.assertEqual("heartbeat", playback[0]["type"])
        self.assertTrue(playback[0]["playback_complete_terminal"])
        self.assertFalse(
            any(
                isinstance(frame, dict)
                and frame.get("type") == "conversation_reply_window"
                for frame in playback
            )
        )

    def test_audio_only_turn_uses_configured_stt_command(self):
        with tempfile.TemporaryDirectory() as temp_dir:
            script = Path(temp_dir) / "fake_stt.py"
            script.write_text(
                "\n".join(
                    [
                        "import os",
                        "import sys",
                        "payload = sys.stdin.buffer.read()",
                        "assert os.environ['STACKCHAN_AUDIO_SAMPLE_RATE'] == '16000'",
                        "assert os.environ['STACKCHAN_AUDIO_FORMAT'] == 's16le_mono'",
                        "assert os.environ['STACKCHAN_AUDIO_BYTES'] == str(len(payload))",
                        "print('I picked you up gently.')",
                    ]
                ),
                encoding="utf-8",
            )
            command = f'"{sys.executable}" "{script}"'
            turn_log = Path(temp_dir) / "turns.jsonl"

            with patch.dict(os.environ, RUNNER_ENV, clear=False):
                session = LanBridgeSession(
                    LanBridgeConfig(runner_case="greeting", stt_command=command, turn_log_file=turn_log)
                )
                session.handle_text(json.dumps({"type": "utterance_start", "sample_rate": 16000}))
                session.handle_binary(b"\x01\x00\x02\x00")
                frames = session.handle_text(json.dumps({"type": "utterance_end", "seq": 5}))
            records = [json.loads(line) for line in turn_log.read_text(encoding="utf-8").splitlines()]

        self.assertEqual("thinking", frames[0]["type"])
        self.assertEqual(4, frames[0]["audio_bytes"])
        self.assertEqual(16000, frames[0]["audio_sample_rate"])
        self.assertEqual("cli", frames[0]["stt_command_source"])
        self.assertGreaterEqual(frames[0]["stt_elapsed_ms"], 0.0)
        self.assertEqual("response_start", frames[1]["type"])
        self.assertEqual("react", frames[1]["intent"])
        self.assertEqual((), session.memory.physical_context)
        self.assertEqual(1, len(records))
        self.assertEqual("stackchan.lan-turn-summary.v1", records[0]["schema"])
        self.assertEqual("audio", records[0]["source"])
        self.assertEqual("I picked you up gently.", records[0]["transcript"])
        self.assertEqual("I picked you up gently.", records[0]["stt_transcript"])
        self.assertEqual("cli", records[0]["stt_command_source"])
        self.assertEqual(4, records[0]["audio_bytes"])
        self.assertEqual("gemma4-e2b-gguf", records[0]["runner_profile"])

    def test_audio_upload_can_write_evidence_wav(self):
        with tempfile.TemporaryDirectory() as temp_dir:
            evidence_dir = Path(temp_dir) / "audio"
            turn_log = Path(temp_dir) / "turns.jsonl"

            with patch.dict(os.environ, RUNNER_ENV, clear=False):
                session = LanBridgeSession(
                    LanBridgeConfig(
                        runner_case="greeting",
                        audio_evidence_dir=evidence_dir,
                        turn_log_file=turn_log,
                    )
                )
                session.handle_text(json.dumps({"type": "utterance_start", "sample_rate": 16000}))
                session.handle_binary(b"\x01\x00\x02\x00")
                frames = session.handle_text(
                    json.dumps({"type": "utterance_end", "seq": 11, "transcript": "hello Stackchan"})
                )
            records = [json.loads(line) for line in turn_log.read_text(encoding="utf-8").splitlines()]

            wav_path = Path(frames[0]["audio_evidence_file"])
            self.assertTrue(wav_path.exists())
            self.assertEqual(str(wav_path), records[0]["audio_evidence_file"])
            with wave.open(str(wav_path), "rb") as wav:
                self.assertEqual(1, wav.getnchannels())
                self.assertEqual(2, wav.getsampwidth())
                self.assertEqual(16000, wav.getframerate())
                self.assertEqual(2, wav.getnframes())

    def test_audio_turn_log_preserves_stt_normalization_metadata(self):
        with tempfile.TemporaryDirectory() as temp_dir:
            script = Path(temp_dir) / "fake_stt.py"
            script.write_text(
                "\n".join(
                    [
                        "import json",
                        "import sys",
                        "sys.stdin.buffer.read()",
                        "print(json.dumps({",
                        "  'transcript': 'Hello Stackchan',",
                        "  'raw_transcript': 'Hello stack shed',",
                        "  'transcript_normalized': True",
                        "}))",
                    ]
                ),
                encoding="utf-8",
            )
            turn_log = Path(temp_dir) / "turns.jsonl"

            with patch.dict(os.environ, RUNNER_ENV, clear=False):
                session = LanBridgeSession(
                    LanBridgeConfig(runner_case="greeting", stt_command=f'"{sys.executable}" "{script}"', turn_log_file=turn_log)
                )
                session.handle_text(json.dumps({"type": "utterance_start", "sample_rate": 16000}))
                session.handle_binary(b"\x01\x00\x02\x00")
                session.handle_text(json.dumps({"type": "utterance_end", "seq": 6}))
            record = json.loads(turn_log.read_text(encoding="utf-8").splitlines()[0])

        self.assertEqual("Hello Stackchan", record["stt_transcript"])
        self.assertEqual("Hello stack shed", record["stt_raw_transcript"])
        self.assertTrue(record["stt_transcript_normalized"])

    def test_audio_turn_can_require_stackchan_wake_phrase(self):
        with tempfile.TemporaryDirectory() as temp_dir:
            script = Path(temp_dir) / "fake_stt.py"
            script.write_text("import sys\nsys.stdin.buffer.read()\nprint('hello kitchen lights')\n", encoding="utf-8")
            turn_log = Path(temp_dir) / "turns.jsonl"
            session = LanBridgeSession(
                LanBridgeConfig(
                    stt_command=f'"{sys.executable}" "{script}"',
                    require_audio_wake_phrase=True,
                    turn_log_file=turn_log,
                )
            )

            session.handle_text(json.dumps({"type": "utterance_start", "sample_rate": 16000}))
            session.handle_binary(b"\x01\x00\x02\x00")
            frames = session.handle_text(json.dumps({"type": "utterance_end", "seq": 7}))
            record = json.loads(turn_log.read_text(encoding="utf-8").splitlines()[0])

        self.assertEqual("error", frames[0]["type"])
        self.assertEqual("wake_phrase_required", frames[0]["code"])
        self.assertTrue(record["rejected"])
        self.assertEqual("wake_phrase_required", record["reject_code"])

    def test_audio_turn_with_stackchan_wake_phrase_runs_when_required(self):
        with tempfile.TemporaryDirectory() as temp_dir:
            script = Path(temp_dir) / "fake_stt.py"
            script.write_text("import sys\nsys.stdin.buffer.read()\nprint('hey Stackchan say hello')\n", encoding="utf-8")

            with patch.dict(os.environ, RUNNER_ENV, clear=False):
                session = LanBridgeSession(
                    LanBridgeConfig(
                        runner_case="greeting",
                        stt_command=f'"{sys.executable}" "{script}"',
                        require_audio_wake_phrase=True,
                    )
                )
                session.handle_text(json.dumps({"type": "utterance_start", "sample_rate": 16000}))
                session.handle_binary(b"\x01\x00\x02\x00")
                frames = session.handle_text(json.dumps({"type": "utterance_end", "seq": 8}))

        self.assertEqual("thinking", frames[0]["type"])
        self.assertEqual("response_start", frames[1]["type"])

    def test_audio_only_turn_reports_stt_command_failure(self):
        with tempfile.TemporaryDirectory() as temp_dir:
            script = Path(temp_dir) / "broken_stt.py"
            script.write_text("import sys\nsys.stdin.buffer.read()\nprint('nope', file=sys.stderr)\nsys.exit(7)\n")
            command = f'"{sys.executable}" "{script}"'
            turn_log = Path(temp_dir) / "turns.jsonl"
            evidence_dir = Path(temp_dir) / "audio"

            session = LanBridgeSession(
                LanBridgeConfig(stt_command=command, turn_log_file=turn_log, audio_evidence_dir=evidence_dir)
            )
            session.handle_text(json.dumps({"type": "utterance_start", "sample_rate": 16000}))
            session.handle_binary(b"\x01\x00\x02\x00")
            frames = session.handle_text(json.dumps({"type": "utterance_end", "seq": 6}))
            record = json.loads(turn_log.read_text(encoding="utf-8").splitlines()[0])
            wav_path = Path(record["audio_evidence_file"])
            wav_exists = wav_path.exists()

        self.assertEqual("error", frames[0]["type"])
        self.assertEqual("stt_error", frames[0]["code"])
        self.assertIn("exit 7", frames[0]["detail"])
        self.assertEqual(4, frames[0]["audio_bytes"])
        self.assertTrue(record["rejected"])
        self.assertEqual("stt_error", record["reject_code"])
        self.assertIn("exit 7", record["stt_error"])
        self.assertEqual(frames[0]["audio_evidence_file"], record["audio_evidence_file"])
        self.assertTrue(wav_exists)

    def test_binary_audio_with_placeholder_transcript_runs_runner(self):
        with patch.dict(os.environ, RUNNER_ENV, clear=False):
            session = LanBridgeSession(LanBridgeConfig(runner_case="greeting"))

            session.handle_text(json.dumps({"type": "utterance_start", "sample_rate": 8000}))
            upload = session.handle_binary(b"\x01\x00\x02\x00")
            frames = session.handle_text(
                json.dumps({"type": "utterance_end", "seq": 3, "transcript": "I picked you up."})
            )

        self.assertEqual("heartbeat", upload[0]["type"])
        self.assertEqual("thinking", frames[0]["type"])
        self.assertEqual(4, frames[0]["audio_bytes"])
        self.assertEqual(8000, frames[0]["audio_sample_rate"])
        self.assertEqual("response_start", frames[1]["type"])
        self.assertEqual("react", frames[1]["intent"])

    def test_configured_tts_command_replaces_response_mouth_beats(self):
        with tempfile.TemporaryDirectory() as temp_dir:
            script = Path(temp_dir) / "fake_tts.py"
            turn_log = Path(temp_dir) / "turns.jsonl"
            script.write_text(
                "\n".join(
                    [
                        "import json",
                        "import os",
                        "import sys",
                        "import base64",
                        "text = sys.stdin.buffer.read().decode('utf-8')",
                        "assert 'Hello' in text or 'awake' in text",
                        "assert os.environ['STACKCHAN_TTS_TEXT_BYTES'] == str(len(text.encode('utf-8')))",
                        "assert os.environ['STACKCHAN_TTS_VOICE'] == 'rvc-bright'",
                        "print(json.dumps({'audio_format':'pcm16','sample_rate':22050,'audio_b64':base64.b64encode(b'abcdefg').decode('ascii'),'audio_truncated':False,'rvc_queue_wait_ms':4.5,'rvc_infer_elapsed_ms':20.5,'beats':[{'env':0.21,'viseme':'ah','duration_ms':30},{'env':0.63,'viseme':'ee','duration_ms':40}]}))",
                    ]
                ),
                encoding="utf-8",
            )
            command = f'"{sys.executable}" "{script}"'

            with patch.dict(os.environ, RUNNER_ENV, clear=False):
                session = LanBridgeSession(
                    LanBridgeConfig(
                        runner_case="greeting",
                        tts_command=command,
                        tts_voice="rvc-bright",
                        downlink_audio_chunk_bytes=3,
                        turn_log_file=turn_log,
                    )
                )
                frames = session.handle_text(json.dumps({"type": "utterance_end", "seq": 8, "text": "Hello"}))
                record = json.loads(turn_log.read_text(encoding="utf-8").splitlines()[0])

        response_start = next(frame for frame in frames if isinstance(frame, dict) and frame["type"] == "response_start")
        stream_start = next(frame for frame in frames if isinstance(frame, dict) and frame["type"] == "audio_stream_start")
        stream_end = next(frame for frame in frames if isinstance(frame, dict) and frame["type"] == "audio_stream_end")
        binary_frames = [frame for frame in frames if isinstance(frame, bytes)]
        audio_frames = [frame for frame in frames if isinstance(frame, dict) and frame["type"] == "audio"]
        self.assertEqual("cli", response_start["tts_command_source"])
        self.assertEqual("rvc-bright", response_start["tts_voice"])
        self.assertEqual(2, response_start["tts_beats"])
        self.assertEqual(70, response_start["tts_duration_ms"])
        self.assertEqual("pcm16", response_start["tts_audio_format"])
        self.assertEqual(22050, response_start["tts_sample_rate"])
        self.assertEqual(7, response_start["tts_audio_bytes"])
        self.assertEqual(7, response_start["tts_audio_payload_bytes"])
        self.assertFalse(response_start["tts_audio_truncated"])
        self.assertEqual(4.5, response_start["tts_rvc_queue_wait_ms"])
        self.assertEqual(20.5, response_start["tts_rvc_infer_elapsed_ms"])
        self.assertEqual("deterministic_fallback", record["runner_command_source"])
        self.assertGreater(record["tts_elapsed_ms"], 0.0)
        self.assertGreater(record["turn_elapsed_ms"], 0.0)
        self.assertFalse(record["tts_audio_truncated"])
        self.assertEqual(["abc", "def", "g"], [chunk.decode("ascii") for chunk in binary_frames])
        self.assertEqual(3, stream_start["chunk_bytes"])
        self.assertEqual(3, stream_start["chunks"])
        self.assertEqual(7, stream_start["audio_bytes"])
        self.assertEqual(3, stream_end["chunks"])
        self.assertEqual(2, len(audio_frames))
        self.assertEqual(0.21, audio_frames[0]["env"])
        self.assertEqual("ah", audio_frames[0]["viseme"])
        self.assertEqual(30, audio_frames[0]["duration_ms"])
        self.assertEqual("ee", audio_frames[1]["viseme"])
        self.assertTrue(audio_frames[1]["final"])

    def test_streaming_tts_emits_unknown_length_stream_then_exact_totals(self):
        with tempfile.TemporaryDirectory() as temp_dir:
            script = Path(temp_dir) / "fake_stream_tts.py"
            turn_log = Path(temp_dir) / "turns.jsonl"
            script.write_text(
                "\n".join(
                    [
                        "import base64",
                        "import json",
                        "import sys",
                        "text = sys.stdin.buffer.read().decode('utf-8')",
                        "payload = (b'abcd' if text.startswith('Yes') else b'efgh')",
                        "print(json.dumps({'audio_format':'pcm16','sample_rate':16000,'audio_b64':base64.b64encode(payload).decode('ascii'),'audio_truncated':False,'beats':[{'env':0.5,'viseme':'ah','duration_ms':20,'final':True}]}))",
                    ]
                ),
                encoding="utf-8",
            )
            command = f'"{sys.executable}" "{script}"'
            runner = SimpleNamespace(
                raw_response=json.dumps(
                    {
                        "spoken_text": "Yes. Second phrase.",
                        "mode": "speak",
                        "earcon": "none",
                        "emotion": {"arousal": 0.0, "valence": 0.0},
                        "memory_write": {},
                        "memory_forget": [],
                    }
                ),
                command_source="test",
                elapsed_ms=1.0,
                approx_tokens_per_sec=10.0,
            )
            emitted = []
            session = LanBridgeSession(
                LanBridgeConfig(
                    runner_command="fake-runner",
                    require_runner=True,
                    tts_command=command,
                    tts_voice="directml-test",
                    stream_tts_phrases=True,
                    downlink_audio_chunk_bytes=4,
                    turn_log_file=turn_log,
                )
            )
            session.memory = BridgeMemory().apply_character_memory(
                {
                    "memory_write": {"project.bracket_color": "blue"},
                    "memory_forget": [],
                }
            )
            session.handle_text(
                json.dumps(
                    {
                        "type": "heartbeat",
                        "robot_mode": 3,
                        "external_power": 1,
                        "battery_percent": 88,
                        "imu_picked_up": 0,
                        "imu_gravity_y": 1.0,
                    }
                )
            )
            with patch("lan_service.run_runner_profile", return_value=runner) as run_runner:
                returned = session.handle_text(
                    json.dumps(
                        {
                            "type": "utterance_end",
                            "seq": 21,
                            "text": "Tell me the bracket color.",
                        }
                    ),
                    frame_sink=emitted.append,
                )
            self.assertEqual("Tell me the bracket color.", run_runner.call_args.kwargs["user_text"])
            self.assertIn("mode: listening", run_runner.call_args.kwargs["embodiment_lines"])
            self.assertIn(
                "approved_fact project.bracket_color: blue",
                run_runner.call_args.kwargs["memory_lines"],
            )
            record = json.loads(turn_log.read_text(encoding="utf-8").splitlines()[0])

        self.assertEqual([], returned)
        types = ["binary" if isinstance(frame, bytes) else frame["type"] for frame in emitted]
        self.assertEqual(
            [
                "response_start",
                "audio_stream_start",
                "audio",
                "binary",
                "audio",
                "binary",
                "audio_stream_end",
                "audio",
                "response_end",
            ],
            types,
        )
        stream_start = next(frame for frame in emitted if isinstance(frame, dict) and frame["type"] == "audio_stream_start")
        stream_end = next(frame for frame in emitted if isinstance(frame, dict) and frame["type"] == "audio_stream_end")
        response_start = next(frame for frame in emitted if isinstance(frame, dict) and frame["type"] == "response_start")
        self.assertEqual("affirm", response_start["gesture"])
        self.assertEqual(0, stream_start["audio_bytes"])
        self.assertEqual(0, stream_start["chunks"])
        self.assertEqual(8, stream_end["audio_bytes"])
        self.assertEqual(2, stream_end["chunks"])
        self.assertTrue(record["tts_streaming"])
        self.assertEqual(2, record["tts_phrases_completed"])
        self.assertEqual(8, record["tts_audio_payload_bytes"])
        self.assertFalse(record["tts_audio_truncated"])
        self.assertTrue(record["tts_stream_complete"])
        self.assertEqual(2, record["tts_mouth_frames"])
        self.assertGreater(record["tts_first_audio_ms"], 0.0)
        self.assertGreater(record["tts_first_audio_after_text_ms"], 0.0)
        self.assertLessEqual(record["tts_first_audio_after_text_ms"], record["tts_first_audio_ms"])

    def test_streaming_mouth_frame_aggregates_beats_over_the_audio_chunk(self):
        beats = (
            SimpleNamespace(env=0.2, viseme="ah", duration_ms=20),
            SimpleNamespace(env=0.8, viseme="ee", duration_ms=20),
        )

        frame = mouth_frame_for_audio_window(beats, 0, 40)

        self.assertAlmostEqual(0.5, frame["env"], places=3)
        self.assertEqual("ee", frame["viseme"])
        self.assertEqual(40, frame["duration_ms"])
        self.assertFalse(frame["final"])

    def test_streaming_tts_marks_a_partial_response_incomplete(self):
        with tempfile.TemporaryDirectory() as temp_dir:
            script = Path(temp_dir) / "partial_stream_tts.py"
            turn_log = Path(temp_dir) / "turns.jsonl"
            script.write_text(
                "\n".join(
                    [
                        "import base64",
                        "import json",
                        "import sys",
                        "text = sys.stdin.buffer.read().decode('utf-8')",
                        "if text.startswith('Second'):",
                        "    print('second phrase failed', file=sys.stderr)",
                        "    raise SystemExit(2)",
                        "print(json.dumps({'audio_format':'pcm16','sample_rate':16000,'audio_b64':base64.b64encode(b'abcd').decode('ascii'),'audio_truncated':False,'beats':[{'env':0.5,'viseme':'ah','duration_ms':20,'final':True}]}))",
                    ]
                ),
                encoding="utf-8",
            )
            command = f'"{sys.executable}" "{script}"'
            runner = SimpleNamespace(
                raw_response=json.dumps(
                    {
                        "spoken_text": "First phrase. Second phrase.",
                        "mode": "speak",
                        "earcon": "none",
                        "emotion": {"arousal": 0.0, "valence": 0.0},
                        "memory_write": {},
                        "memory_forget": [],
                    }
                ),
                command_source="test",
                elapsed_ms=1.0,
                approx_tokens_per_sec=10.0,
            )
            emitted = []
            session = LanBridgeSession(
                LanBridgeConfig(
                    runner_command="fake-runner",
                    require_runner=True,
                    tts_command=command,
                    stream_tts_phrases=True,
                    downlink_audio_chunk_bytes=4,
                    turn_log_file=turn_log,
                )
            )
            with patch("lan_service.run_runner_profile", return_value=runner):
                session.handle_text(
                    json.dumps({"type": "utterance_end", "seq": 22, "text": "Tell me something."}),
                    frame_sink=emitted.append,
                )
            record = json.loads(turn_log.read_text(encoding="utf-8").splitlines()[0])

        stream_end = next(
            frame for frame in emitted if isinstance(frame, dict) and frame["type"] == "audio_stream_end"
        )
        error = next(frame for frame in emitted if isinstance(frame, dict) and frame["type"] == "error")
        self.assertEqual(4, stream_end["audio_bytes"])
        self.assertEqual("tts_error", error["code"])
        self.assertEqual(1, record["tts_phrases_completed"])
        self.assertTrue(record["tts_audio_truncated"])
        self.assertFalse(record["tts_stream_complete"])

    def test_streaming_tts_renders_next_phrase_while_first_phrase_is_emitted(self):
        second_started = threading.Event()
        release_second = threading.Event()
        calls = []
        styles = []

        def fake_synthesize(text, **kwargs):
            calls.append(text)
            styles.append(
                {
                    "mode": kwargs["mode"],
                    "arousal": kwargs["arousal"],
                    "valence": kwargs["valence"],
                    "directml_in_process": kwargs["directml_in_process"],
                }
            )
            if text.startswith("Second"):
                second_started.set()
                self.assertTrue(release_second.wait(timeout=1.0))
            return SimpleNamespace(
                diagnostics={"audio_truncated": False},
                audio_data=b"abcd",
                audio_format="pcm16",
                sample_rate=16000,
                command_source="test",
                voice="directml-test",
                elapsed_ms=10.0,
                duration_ms=20,
            )

        emitted = []

        def sink(frame):
            emitted.append(frame)
            if isinstance(frame, bytes) and not release_second.is_set():
                self.assertTrue(second_started.wait(timeout=1.0))
                release_second.set()

        session = LanBridgeSession(
            LanBridgeConfig(
                tts_command="fake-tts",
                in_process_directml_tts=True,
                stream_tts_phrases=True,
                downlink_audio_chunk_bytes=4,
            )
        )
        turn = SimpleNamespace(
            seq=23,
            intent="speak",
            arousal=0.0,
            valence=0.0,
            text="First phrase. Second phrase.",
        )
        with patch("lan_service.synthesize_speech", side_effect=fake_synthesize):
            _frames, summary, error = session._stream_tts_turn(
                turn,
                turn_started=0.0,
                validation_issues=[],
                frame_sink=sink,
            )

        self.assertEqual(["First phrase.", "Second phrase."], calls)
        self.assertEqual(
            [
                {
                    "mode": "speak",
                    "arousal": 0.0,
                    "valence": 0.0,
                    "directml_in_process": True,
                }
            ]
            * 2,
            styles,
        )
        self.assertEqual("", error)
        self.assertTrue(summary["tts_stream_complete"])
        self.assertEqual(2, summary["tts_phrases_completed"])
        self.assertEqual(2, len([frame for frame in emitted if isinstance(frame, bytes)]))

    def test_intermediate_short_binary_chunk_uses_normal_delay(self):
        conn = SimpleNamespace(sendall=Mock())
        config = LanBridgeConfig(
            downlink_audio_chunk_bytes=4096,
            downlink_binary_frame_delay_ms=80,
        )
        with patch("lan_service.time.sleep") as sleep:
            send_connection_frame(conn, config, b"abc", final_binary_chunk=False)
            sleep.assert_called_once_with(0.08)
            sleep.reset_mock()
            send_connection_frame(conn, config, b"abc", final_binary_chunk=True)
            sleep.assert_called_once_with(0.25)
        self.assertFalse(ends_audio_stream({"type": "audio", "seq": 1}))
        self.assertFalse(ends_audio_stream(b"next phrase"))
        self.assertTrue(ends_audio_stream({"type": "audio_stream_end", "seq": 1}))

    def test_streaming_mouth_frame_does_not_consume_pcm_pacing_budget(self):
        conn = SimpleNamespace(sendall=Mock())
        config = LanBridgeConfig(
            stream_tts_phrases=True,
            downlink_text_frame_delay_ms=40,
        )
        mouth = {"type": "audio", "seq": 1, "env": 0.4, "viseme": "ah"}
        thinking = {"type": "thinking", "seq": 1}

        with patch("lan_service.time.sleep") as sleep:
            send_connection_frame(conn, config, mouth)
            sleep.assert_not_called()

            send_connection_frame(conn, config, thinking)
            sleep.assert_called_once_with(0.04)

        self.assertEqual(0.0, downlink_text_frame_delay_ms(config, mouth))
        self.assertEqual(40.0, downlink_text_frame_delay_ms(config, thinking))

    def test_streaming_tts_records_production_pacing_headroom(self):
        result = SimpleNamespace(
            diagnostics={"audio_truncated": False},
            audio_data=b"\x00" * 4096,
            audio_format="pcm16",
            sample_rate=16000,
            command_source="test",
            voice="directml-test",
            elapsed_ms=10.0,
            duration_ms=128,
            beats=(),
        )
        session = LanBridgeSession(
            LanBridgeConfig(
                tts_command="fake-tts",
                in_process_directml_tts=True,
                stream_tts_phrases=True,
                downlink_audio_chunk_bytes=4096,
                downlink_binary_frame_delay_ms=70,
                downlink_text_frame_delay_ms=40,
            )
        )
        turn = SimpleNamespace(
            seq=24,
            intent="speak",
            arousal=0.0,
            valence=0.0,
            text="One phrase.",
        )

        with patch("lan_service.synthesize_speech", return_value=result):
            _frames, summary, error = session._stream_tts_turn(
                turn,
                turn_started=time.perf_counter(),
                validation_issues=[],
                frame_sink=None,
            )

        self.assertEqual("", error)
        self.assertEqual(128.0, summary["tts_downlink_chunk_audio_ms"])
        self.assertEqual(70.0, summary["tts_downlink_configured_cadence_ms"])
        self.assertEqual(58.0, summary["tts_downlink_pacing_headroom_ms"])
        self.assertTrue(summary["tts_downlink_pacing_safe"])

    def test_audio_is_finalized_before_worker_and_late_binary_is_logged(self):
        runner = SimpleNamespace(
            raw_response=json.dumps(
                {
                    "spoken_text": "Signal received.",
                    "mode": "speak",
                    "earcon": "none",
                    "emotion": {"arousal": 0.0, "valence": 0.0},
                    "memory_write": {},
                    "memory_forget": [],
                }
            ),
            command_source="test",
            elapsed_ms=1.0,
            approx_tokens_per_sec=10.0,
        )
        with tempfile.TemporaryDirectory() as temp_dir:
            turn_log = Path(temp_dir) / "turns.jsonl"
            session = LanBridgeSession(LanBridgeConfig(turn_log_file=turn_log))
            session.handle_text(
                json.dumps({"type": "utterance_start", "seq": 31, "sample_rate": 16000})
            )
            session.handle_binary(b"\x01\x00\x02\x00")

            finalized = session.finalize_audio_upload()
            late = session.handle_binary(b"\x03\x00\x04\x00")

            with patch("lan_service.run_runner_profile", return_value=runner):
                frames = session.handle_text(
                    json.dumps(
                        {
                            "type": "utterance_end",
                            "seq": 31,
                            "audio_bytes": 4,
                            "chunks": 1,
                            "text": "Test input.",
                        }
                    ),
                    finalized_audio=finalized,
                )
            records = [
                json.loads(line)
                for line in turn_log.read_text(encoding="utf-8").splitlines()
            ]

        self.assertEqual(b"\x01\x00\x02\x00", finalized.pcm)
        self.assertEqual("audio_without_utterance", late[0]["code"])
        self.assertEqual(1, late[0]["audio_protocol_errors"])
        self.assertEqual("stackchan.audio-protocol-event.v1", records[0]["schema"])
        self.assertEqual(4, records[0]["payload_bytes"])
        completed = next(
            record
            for record in records
            if record["schema"] == "stackchan.lan-turn-summary.v1"
        )
        self.assertEqual(4, completed["audio_bytes"])
        self.assertEqual(1, completed["audio_chunks"])
        self.assertTrue(completed["audio_end_counts_match"])
        self.assertTrue(
            any(
                isinstance(frame, dict) and frame.get("type") == "response_start"
                for frame in frames
            )
        )

    def test_audio_end_count_mismatch_rejects_incomplete_capture(self):
        with tempfile.TemporaryDirectory() as temp_dir:
            turn_log = Path(temp_dir) / "turns.jsonl"
            session = LanBridgeSession(LanBridgeConfig(turn_log_file=turn_log))
            session.handle_text(
                json.dumps({"type": "utterance_start", "seq": 32, "sample_rate": 16000})
            )
            session.handle_binary(b"\x01\x00\x02\x00")
            finalized = session.finalize_audio_upload()

            frames = session.handle_text(
                json.dumps(
                    {
                        "type": "utterance_end",
                        "seq": 32,
                        "audio_bytes": 8,
                        "chunks": 1,
                        "text": "This must not reach the model.",
                    }
                ),
                finalized_audio=finalized,
            )
            record = json.loads(turn_log.read_text(encoding="utf-8").splitlines()[0])

        self.assertEqual("error", frames[0]["type"])
        self.assertEqual("audio_count_mismatch", frames[0]["code"])
        self.assertIn("declared 8, received 4", frames[0]["detail"])
        self.assertFalse(frames[0]["audio_end_counts_match"])
        self.assertEqual("audio_count_mismatch", record["reject_code"])
        self.assertEqual(8, record["audio_declared_bytes"])
        self.assertFalse(record["audio_end_counts_match"])

    def test_configured_tts_can_disable_binary_downlink_but_keep_mouth_beats(self):
        with tempfile.TemporaryDirectory() as temp_dir:
            script = Path(temp_dir) / "fake_tts.py"
            script.write_text(
                "\n".join(
                    [
                        "import base64",
                        "import json",
                        "import sys",
                        "sys.stdin.buffer.read()",
                        "print(json.dumps({'audio_format':'pcm16','sample_rate':48000,'audio_b64':base64.b64encode(b'abcdefg').decode('ascii'),'beats':[{'env':0.21,'viseme':'ah','duration_ms':30},{'env':0.63,'viseme':'ee','duration_ms':40}]}))",
                    ]
                ),
                encoding="utf-8",
            )
            command = f'"{sys.executable}" "{script}"'

            with patch.dict(os.environ, RUNNER_ENV, clear=False):
                session = LanBridgeSession(
                    LanBridgeConfig(
                        runner_case="greeting",
                        tts_command=command,
                        tts_voice="rvc-bright",
                        stream_tts_phrases=True,
                        disable_audio_downlink=True,
                    )
                )
                frames = session.handle_text(json.dumps({"type": "utterance_end", "seq": 9, "text": "Hello"}))

        response_start = next(frame for frame in frames if isinstance(frame, dict) and frame["type"] == "response_start")
        binary_frames = [frame for frame in frames if isinstance(frame, bytes)]
        stream_frames = [
            frame
            for frame in frames
            if isinstance(frame, dict) and frame["type"] in ("audio_stream_start", "audio_stream_end")
        ]
        audio_frames = [frame for frame in frames if isinstance(frame, dict) and frame["type"] == "audio"]
        self.assertEqual("cli", response_start["tts_command_source"])
        self.assertEqual("rvc-bright", response_start["tts_voice"])
        self.assertEqual(7, response_start["tts_audio_payload_bytes"])
        self.assertTrue(response_start["tts_audio_downlink_disabled"])
        self.assertEqual([], binary_frames)
        self.assertEqual([], stream_frames)
        self.assertEqual(2, len(audio_frames))
        self.assertEqual("ah", audio_frames[0]["viseme"])
        self.assertEqual("ee", audio_frames[1]["viseme"])
        self.assertTrue(audio_frames[1]["final"])

    def test_tts_command_failure_reports_error_and_keeps_fallback_beats(self):
        with tempfile.TemporaryDirectory() as temp_dir:
            script = Path(temp_dir) / "broken_tts.py"
            script.write_text("import sys\nsys.stdin.buffer.read()\nprint('tts nope', file=sys.stderr)\nsys.exit(9)\n")
            command = f'"{sys.executable}" "{script}"'

            with patch.dict(os.environ, RUNNER_ENV, clear=False):
                session = LanBridgeSession(LanBridgeConfig(runner_case="greeting", tts_command=command))
                frames = session.handle_text(json.dumps({"type": "utterance_end", "seq": 10, "text": "Hello"}))

        self.assertEqual("error", frames[0]["type"])
        self.assertEqual("tts_error", frames[0]["code"])
        self.assertIn("exit 9", frames[0]["detail"])
        self.assertEqual("thinking", frames[1]["type"])
        self.assertTrue(any(frame["type"] == "audio" and frame["final"] for frame in frames))

    def test_text_audio_payload_uses_base64_for_dev_clients(self):
        session = LanBridgeSession(LanBridgeConfig())
        payload = base64.b64encode(b"\x01\x00\x02\x00").decode("ascii")

        session.handle_text(json.dumps({"type": "utterance_start"}))
        upload = session.handle_text(json.dumps({"type": "utterance_audio", "pcm_b64": payload}))

        self.assertEqual("heartbeat", upload[0]["type"])
        self.assertEqual(4, upload[0]["audio_bytes"])

    def test_bad_messages_return_error_frames(self):
        session = LanBridgeSession(LanBridgeConfig())

        malformed = session.handle_text("{not json")
        unsupported = session.handle_text(json.dumps({"type": "mystery"}))
        binary = session.handle_binary(b"1234")
        invalid_audio = session.handle_text(json.dumps({"type": "utterance_audio", "pcm_b64": "not base64"}))

        self.assertEqual("error", malformed[0]["type"])
        self.assertEqual("malformed_json", malformed[0]["code"])
        self.assertEqual("unsupported_message", unsupported[0]["code"])
        self.assertEqual("audio_without_utterance", binary[0]["code"])
        self.assertEqual("audio_payload_invalid", invalid_audio[0]["code"])

    def test_playback_complete_is_acknowledged_without_opening_capture(self):
        session = LanBridgeSession(LanBridgeConfig())

        frames = session.handle_text(
            json.dumps({"type": "playback_complete", "seq": 44, "at_ms": 1234})
        )

        self.assertEqual([{"type": "heartbeat", "playback_complete_seq": 44}], frames)
        self.assertFalse(session.audio.active)

    def test_conversation_v2_requires_confirmable_audio_downlink(self):
        with self.assertRaisesRegex(ValueError, "requires configured TTS"):
            LanBridgeSession(LanBridgeConfig(conversation_v2_enabled=True))

    def test_conversation_v2_opens_followup_only_after_matching_playback_complete(self):
        with tempfile.TemporaryDirectory() as temp_dir:
            script = Path(temp_dir) / "fake_tts.py"
            turn_log = Path(temp_dir) / "turns.jsonl"
            script.write_text(
                "import base64,json,sys\n"
                "sys.stdin.buffer.read()\n"
                "print(json.dumps({'audio_format':'pcm16','sample_rate':16000,"
                "'audio_b64':base64.b64encode(b'\\x00\\x00\\x01\\x00').decode('ascii'),"
                "'audio_truncated':False,'beats':[{'env':0.5,'viseme':'ah',"
                "'duration_ms':20,'final':True}]}))\n",
                encoding="utf-8",
            )
            session = LanBridgeSession(
                LanBridgeConfig(
                    conversation_v2_enabled=True,
                    conversation_acoustic_tail_ms=0,
                    tts_command=f'"{sys.executable}" "{script}"',
                    turn_log_file=turn_log,
                )
            )

            listening = session.handle_text(
                json.dumps({"type": "utterance_start", "seq": 70, "sample_rate": 16000})
            )
            response = session.handle_text(
                json.dumps({"type": "utterance_end", "seq": 70, "text": "What is your name?"})
            )
            stale = session.handle_text(
                json.dumps({"type": "playback_complete", "seq": 69, "at_ms": 100})
            )
            completed = session.handle_text(
                json.dumps({"type": "playback_complete", "seq": 70, "at_ms": 120})
            )
            duplicate = session.handle_text(
                json.dumps({"type": "playback_complete", "seq": 70, "at_ms": 121})
            )
            context_after_playback = session.conversation.context_lines()
            followup = session.handle_text(
                json.dumps({"type": "utterance_start", "seq": 71, "sample_rate": 16000})
            )
            exit_frames = session.handle_text(
                json.dumps(
                    {"type": "utterance_end", "seq": 71, "text": "Goodbye Stackchan"}
                ),
                suppress_thinking=True,
            )
            event_records = [
                json.loads(line)
                for line in turn_log.read_text(encoding="utf-8").splitlines()
                if '"stackchan.conversation-event.v1"' in line
            ]

        self.assertEqual("engaged", listening[0]["conversation_state"])
        self.assertEqual("response_end", response[-1]["type"])
        self.assertEqual("error", stale[0]["type"])
        self.assertEqual("playback_complete_seq_mismatch", stale[0]["code"])
        self.assertEqual("conversation_reply_window", completed[0]["type"])
        self.assertEqual(0, completed[0]["open_after_ms"])
        self.assertEqual(10000, completed[0]["window_ms"])
        self.assertEqual("reply_window", completed[0]["conversation_state"])
        self.assertFalse(completed[0]["conversation_capture_open"])
        self.assertEqual("heartbeat", duplicate[0]["type"])
        self.assertTrue(duplicate[0]["playback_complete_duplicate"])
        self.assertEqual("reply_window", duplicate[0]["conversation_state"])
        self.assertNotIn("open_after_ms", duplicate[0])
        self.assertEqual(
            (
                "turn 1 user: What is your name?",
                "turn 1 stackchan: I am Stackchan.",
            ),
            context_after_playback,
        )
        self.assertEqual("listening", followup[0]["type"])
        self.assertEqual("engaged", followup[0]["conversation_state"])
        self.assertTrue(followup[0]["conversation_capture_open"])
        self.assertEqual("hello", exit_frames[0]["type"])
        self.assertEqual(PROTOCOL, exit_frames[0]["protocol"])
        self.assertEqual("lan", exit_frames[0]["session"])
        self.assertEqual("cooldown", exit_frames[0]["conversation_state"])
        self.assertEqual("exit_phrase", exit_frames[0]["conversation_reason"])
        self.assertEqual((), session.conversation.context_lines())
        self.assertEqual(
            [
                "wake",
                "listening",
                "utterance_committed",
                "response_started",
                "reply_pending",
                "reply_window_open",
                "listening",
                "exit_phrase",
            ],
            [record["event"] for record in event_records],
        )
        self.assertTrue(
            all(
                "transcript" not in record and "response_text" not in record
                for record in event_records
            )
        )

    def test_conversation_v2_supplies_only_completed_session_turns_to_followup(self):
        with tempfile.TemporaryDirectory() as temp_dir:
            script = Path(temp_dir) / "fake_tts.py"
            script.write_text(
                "import base64,json,sys\n"
                "sys.stdin.buffer.read()\n"
                "print(json.dumps({'audio_format':'pcm16','sample_rate':16000,"
                "'audio_b64':base64.b64encode(b'\\x00\\x00').decode('ascii'),"
                "'audio_truncated':False,'beats':[{'env':0.4,'viseme':'ah',"
                "'duration_ms':20,'final':True}]}))\n",
                encoding="utf-8",
            )
            session = LanBridgeSession(
                LanBridgeConfig(
                    conversation_v2_enabled=True,
                    conversation_acoustic_tail_ms=0,
                    tts_command=f'"{sys.executable}" "{script}"',
                )
            )

            session.handle_text(json.dumps({"type": "utterance_start", "seq": 80}))
            session.handle_text(
                json.dumps({"type": "utterance_end", "seq": 80, "text": "What is your name?"})
            )
            session.handle_text(json.dumps({"type": "playback_complete", "seq": 80}))
            session.handle_text(json.dumps({"type": "utterance_start", "seq": 81}))
            with patch.dict(os.environ, RUNNER_ENV, clear=False), patch(
                "lan_service.run_runner_profile", wraps=run_runner_profile
            ) as runner:
                session.handle_text(
                    json.dumps(
                        {"type": "utterance_end", "seq": 81, "text": "What did you just say?"}
                    )
                )

        self.assertEqual(1, runner.call_count)
        self.assertEqual(
            (
                "turn 1 user: What is your name?",
                "turn 1 stackchan: I am Stackchan.",
            ),
            runner.call_args.kwargs["conversation_lines"],
        )

    def test_model_internet_denial_recovers_through_bounded_search(self):
        def result(spoken_text):
            return SimpleNamespace(
                raw_response=json.dumps(
                    {
                        "spoken_text": spoken_text,
                        "mode": "speak",
                        "earcon": "none",
                        "emotion": {"arousal": 0.0, "valence": 0.0},
                        "memory_write": {},
                        "memory_forget": [],
                    }
                ),
                command_source="test",
                elapsed_ms=1.0,
                approx_tokens_per_sec=10.0,
            )

        broker = Mock()
        search_result = {
            "schema": "stackchan.research.v1",
            "tool": "web_search",
            "query": "fixture",
            "results": [
                {
                    "title": "Fixture",
                    "url": "https://example.com/source",
                    "excerpt": "The specification was published in 2025.",
                }
            ],
        }
        fetch_result = {
            "schema": "stackchan.research.v1",
            "tool": "web_fetch",
            "title": "Fixture",
            "url": "https://example.com/source",
            "excerpt": "The specification was published in 2025.",
        }
        broker.execute.side_effect = [search_result, fetch_result]
        session = LanBridgeSession(
            LanBridgeConfig(research_enabled=True),
            research_broker=broker,
        )
        user_text = "What is the obscure frobnicator specification?"
        with patch(
            "lan_service.run_runner_profile",
            side_effect=[
                result("I do not have access to the internet to check that."),
                result("The specification was published in 2025."),
            ],
        ) as runner:
            frames = session.handle_text(
                json.dumps({"type": "utterance_end", "seq": 89, "text": user_text})
            )

        self.assertEqual(2, runner.call_count)
        self.assertEqual(
            [
                {"name": "web_search", "arguments": {"query": user_text, "max_results": 4}},
                {
                    "name": "web_fetch",
                    "arguments": {
                        "url": "https://example.com/source",
                        "max_chars": 5000,
                    },
                },
            ],
            [item.args[0] for item in broker.execute.call_args_list],
        )
        response = next(
            frame
            for frame in frames
            if isinstance(frame, dict) and frame.get("type") == "response_start"
        )
        self.assertEqual("The specification was published in 2025.", response["text"])

    def test_natural_research_turn_creates_no_v4_memory(self):
        def result(spoken_text, memory_write=None):
            return SimpleNamespace(
                raw_response=json.dumps(
                    {
                        "spoken_text": spoken_text,
                        "mode": "speak",
                        "earcon": "none",
                        "emotion": {"arousal": 0.0, "valence": 0.0},
                        "memory_write": memory_write or {},
                        "memory_forget": [],
                    }
                ),
                command_source="test",
                elapsed_ms=1.0,
                approx_tokens_per_sec=10.0,
            )

        broker = SimpleNamespace(
            execute=lambda request: {
                "schema": "stackchan.research.v1",
                "tool": "web_search",
                "query": "fixture",
                "results": [
                    {
                        "title": "Fixture",
                        "url": "https://example.com/source",
                        "excerpt": "Recorded evidence",
                    }
                ],
            }
        )
        session = LanBridgeSession(
            LanBridgeConfig(research_enabled=True),
            research_broker=broker,
        )
        user_text = "I have a demo tomorrow; tell me the current Stackchan release"
        with patch(
            "lan_service.run_runner_profile",
            return_value=result("The release is current.", {"project.web": "result"}),
        ) as runner:
            session.handle_text(json.dumps({"type": "utterance_end", "seq": 90, "text": user_text}))

        self.assertEqual(1, runner.call_count)
        self.assertIn(
            "UNTRUSTED WEB EVIDENCE",
            runner.call_args.kwargs["user_text"],
        )
        self.assertEqual(0, session.memory.episode_count)
        self.assertEqual(0, session.memory.open_loop_count)
        self.assertEqual([], session._session_topics)
        self.assertEqual(0, session._session_non_research_turns)
        self.assertNotIn("project.web", {item["key"] for item in session.memory.to_dict()["durable_facts"]})

    def test_conversation_weather_correction_replays_typed_search_intent(self):
        def model_result(text):
            return SimpleNamespace(
                raw_response=json.dumps(
                    {
                        "spoken_text": text,
                        "mode": "speak",
                        "earcon": "none",
                        "emotion": {"arousal": 0.0, "valence": 0.0},
                        "memory_write": {},
                        "memory_forget": [],
                    }
                ),
                command_source="test",
                elapsed_ms=1.0,
                approx_tokens_per_sec=10.0,
            )

        with tempfile.TemporaryDirectory() as temp_dir:
            script = Path(temp_dir) / "fake_tts.py"
            script.write_text(
                "import base64,json,sys\n"
                "sys.stdin.buffer.read()\n"
                "print(json.dumps({'audio_format':'pcm16','sample_rate':16000,"
                "'audio_b64':base64.b64encode(b'\\x00\\x00').decode('ascii'),"
                "'audio_truncated':False,'beats':[{'env':0.4,'viseme':'ah',"
                "'duration_ms':20,'final':True}]}))\n",
                encoding="utf-8",
            )
            broker = Mock()
            broker.execute.side_effect = [
                {
                    "schema": "stackchan.research.v1",
                    "tool": "web_search",
                    "query": "current weather in Boston",
                    "results": [{"title": "Boston", "url": "https://example.com/a", "excerpt": "Cold."}],
                },
                {
                    "schema": "stackchan.research.v1",
                    "tool": "web_search",
                    "query": "current weather in West Berlin",
                    "results": [{"title": "West Berlin", "url": "https://example.com/b", "excerpt": "Clear."}],
                },
            ]
            session = LanBridgeSession(
                LanBridgeConfig(
                    conversation_v2_enabled=True,
                    conversation_acoustic_tail_ms=0,
                    research_enabled=True,
                    tts_command=f'"{sys.executable}" "{script}"',
                ),
                research_broker=broker,
            )
            with patch(
                "lan_service.run_runner_profile",
                side_effect=[
                    model_result("Boston is cold."),
                    model_result("West Berlin is clear. Geography has been corrected."),
                ],
            ) as runner:
                session.handle_text(json.dumps({"type": "utterance_start", "seq": 94}))
                session.handle_text(
                    json.dumps(
                        {
                            "type": "utterance_end",
                            "seq": 94,
                            "text": "What is the weather like in Boston?",
                        }
                    )
                )
                session.handle_text(json.dumps({"type": "playback_complete", "seq": 94}))
                session.handle_text(json.dumps({"type": "utterance_start", "seq": 95}))
                session.handle_text(
                    json.dumps(
                        {
                            "type": "utterance_end",
                            "seq": 95,
                            "text": "No, West Berlin",
                        }
                    )
                )
                session.handle_text(json.dumps({"type": "playback_complete", "seq": 95}))

        queries = [
            call.args[0]["arguments"]["query"]
            for call in broker.execute.call_args_list
        ]
        self.assertEqual(
            ["current weather in Boston", "current weather in West Berlin"],
            queries,
        )
        self.assertEqual(2, runner.call_count)
        self.assertEqual("question", runner.call_args.kwargs["case_name"])
        self.assertNotIn(
            "Resolved active request:",
            runner.call_args.kwargs["user_text"],
        )
        self.assertIn(
            "current weather in West Berlin",
            runner.call_args.kwargs["task_lines"],
        )
        self.assertIn(
            "turn 1 user: What is the weather like in Boston?",
            runner.call_args.kwargs["conversation_lines"],
        )
        self.assertEqual(
            "West Berlin",
            session.conversation_harness.active.slot("location"),
        )
        self.assertEqual("", session.memory.weather_location())
        self.assertFalse(
            any(
                record["key"] == "user.weather_default_location"
                for record in session.memory.to_dict()["durable_facts"]
            )
        )

    def test_verification_request_searches_and_fetches_top_source_before_one_model_call(self):
        broker = Mock()
        broker.execute.side_effect = [
            {
                "schema": "stackchan.research.v1",
                "tool": "web_search",
                "query": "fixture",
                "results": [
                    {
                        "title": "Python 3.13.0",
                        "url": "https://www.python.org/downloads/release/python-3130/",
                        "excerpt": "Python 3.13.0 release page.",
                    }
                ],
            },
            {
                "schema": "stackchan.research.v1",
                "tool": "web_fetch",
                "title": "Python 3.13.0",
                "url": "https://www.python.org/downloads/release/python-3130/",
                "excerpt": "Python 3.13.0 was released on October 7, 2024.",
            },
        ]
        runner_result = SimpleNamespace(
            raw_response=json.dumps(
                {
                    "spoken_text": "Python 3.13.0 was released on October 7, 2024.",
                    "mode": "speak",
                    "earcon": "none",
                    "emotion": {"arousal": 0.0, "valence": 0.0},
                    "memory_write": {},
                    "memory_forget": [],
                }
            ),
            command_source="test",
            elapsed_ms=1.0,
            approx_tokens_per_sec=10.0,
        )
        session = LanBridgeSession(
            LanBridgeConfig(research_enabled=True),
            research_broker=broker,
        )
        user_text = "Can you verify when Python 3.13.0 was released?"

        with patch(
            "lan_service.run_runner_profile", return_value=runner_result
        ) as runner:
            frames = session.handle_text(
                json.dumps({"type": "utterance_end", "seq": 95, "text": user_text})
            )

        self.assertEqual(1, runner.call_count)
        evidence = runner.call_args.kwargs["user_text"]
        self.assertIn("October 7, 2024", evidence)
        self.assertEqual(
            [
                {"name": "web_search", "arguments": {"query": user_text, "max_results": 4}},
                {
                    "name": "web_fetch",
                    "arguments": {
                        "url": "https://www.python.org/downloads/release/python-3130/",
                        "max_chars": 5000,
                    },
                },
            ],
            [item.args[0] for item in broker.execute.call_args_list],
        )
        response = next(
            frame
            for frame in frames
            if isinstance(frame, dict) and frame.get("type") == "response_start"
        )
        self.assertEqual(
            ["https://www.python.org/downloads/release/python-3130/"],
            response["citations"],
        )

    def test_session_close_adds_only_deterministic_topic_episode(self):
        session = LanBridgeSession(
            LanBridgeConfig(conversation_v2_enabled=True, tts_command="fixture-tts")
        )
        session.conversation.wake(0, "fixture")
        session._session_topics.extend(("servos", "voice"))
        session._session_non_research_turns = 2

        transition = session.conversation.cancel(1, "fixture_close")
        session._conversation_payload(transition, observed_ms=1)

        self.assertEqual(1, session.memory.episode_count)
        self.assertEqual(0, session.memory.open_loop_count)
        self.assertEqual((), session.conversation.take_closed_turns())

    def test_session_close_distills_every_played_turn_not_only_the_last_four(self):
        session = LanBridgeSession(
            LanBridgeConfig(
                conversation_v2_enabled=True,
                conversation_acoustic_tail_ms=0,
                episode_distillation_enabled=True,
                tts_command="fixture-tts",
            )
        )
        session.conversation.wake(0, "fixture")
        for index in range(6):
            now = index * 100
            session.conversation.utterance_committed(now + 10, f"question {index}")
            session.conversation.response_started(now + 20)
            session.conversation.stage_turn(f"question {index}", f"answer {index}")
            session.conversation.playback_completed(now + 30)
            session.conversation.tick(now + 30)

        with patch("lan_service.threading.Thread") as thread:
            transition = session.conversation.cancel(700, "fixture_close")
            session._conversation_payload(transition, observed_ms=700)

        thread.assert_called_once()
        distilled_turns, distilled_session, expected_revision = (
            thread.call_args.kwargs["args"]
        )
        self.assertEqual(1, distilled_session)
        self.assertEqual(session._memory_revision, expected_revision)
        self.assertEqual(6, len(distilled_turns))
        self.assertEqual(("question 0", "answer 0"), distilled_turns[0])
        self.assertEqual(("question 5", "answer 5"), distilled_turns[-1])
        thread.return_value.start.assert_called_once_with()

    def test_session_with_research_keeps_only_coarse_episode_out_of_distillation(self):
        session = LanBridgeSession(
            LanBridgeConfig(
                conversation_v2_enabled=True,
                conversation_acoustic_tail_ms=0,
                episode_distillation_enabled=True,
                tts_command="fixture-tts",
            )
        )
        session.conversation.wake(0, "fixture")
        session.conversation.utterance_committed(10, "weather in a private place")
        session.conversation.response_started(20)
        session.conversation.stage_turn(
            "weather in a private place",
            "the researched answer",
        )
        session.conversation.playback_completed(30)
        session._session_topics.append("weather")
        session._session_research_turns = 1

        with patch("lan_service.threading.Thread") as thread:
            transition = session.conversation.cancel(40, "fixture_close")
            session._conversation_payload(transition, observed_ms=40)

        thread.assert_not_called()
        self.assertEqual(1, session.memory.episode_count)
        episode = session.memory.to_dict()["episodes"][0]["text"]
        self.assertIn("weather", episode)
        self.assertNotIn("private place", episode)

    def test_stale_distillation_cannot_resurrect_superseded_knowledge(self):
        session = LanBridgeSession(
            LanBridgeConfig(
                conversation_v2_enabled=True,
                episode_distillation_enabled=True,
                tts_command="fixture-tts",
            )
        )
        session.conversation.wake(0, "fixture")
        session.conversation.cancel(10, "fixture_close")
        stale_revision = session._memory_revision
        session._commit_memory(
            session.memory.remember_user_text(
                "Remember that my favorite color is teal."
            )
        )

        with (
            patch(
                "lan_service.request_distillation",
                return_value='{"episode":"Old session detail"}',
            ),
            patch(
                "lan_service.validate_distillation",
                return_value=DistilledMemory("Old session detail"),
            ),
        ):
            session._run_episode_distillation(
                (("old question", "old answer"),),
                session.conversation.session_number,
                stale_revision,
            )

        self.assertEqual(0, session.memory.episode_count)
        self.assertEqual(1, session.memory.distill_dropped)

    def test_injected_open_loop_is_consumed_and_not_injected_again(self):
        memory = BridgeMemory().add_open_loop(
            "I have a servo calibration demo tomorrow",
            due_at="2026-07-14T00:00:00Z",
            now="2026-07-13T00:00:00Z",
        )
        runner_result = SimpleNamespace(
            raw_response=json.dumps(
                {
                    "spoken_text": "How did the servo calibration go?",
                    "mode": "speak",
                    "earcon": "none",
                    "emotion": {"arousal": 0.1, "valence": 0.2},
                    "memory_write": {},
                    "memory_forget": [],
                }
            ),
            command_source="test",
            elapsed_ms=1.0,
            approx_tokens_per_sec=10.0,
        )
        session = LanBridgeSession(LanBridgeConfig(), memory=memory)

        with patch("bridge_memory._utc_now", return_value="2026-07-15T00:00:00Z"), patch(
            "lan_service.run_runner_profile", return_value=runner_result
        ) as runner:
            session.handle_text(json.dumps({"type": "utterance_end", "seq": 91, "text": "Hello there"}))
            session.handle_text(json.dumps({"type": "utterance_end", "seq": 92, "text": "Hello again"}))
            self.assertTrue(
                any(line.startswith("ask_about:") for line in runner.call_args_list[0].kwargs["memory_lines"])
            )
            self.assertFalse(
                any(line.startswith("ask_about:") for line in runner.call_args_list[1].kwargs["memory_lines"])
            )
            self.assertEqual("asked", session.memory.to_dict()["open_loops"][0]["status"])

    def test_room_context_enters_prompt_only_as_typed_ambient_line(self):
        raw_frame = b"P5\n1 1\n255\n\x00"
        room = RoomContextRuntime(
            RoomObservationConfig(enabled=True, interval_seconds=300, command="fixture"),
            frame_source=lambda: raw_frame,
            model_observer=lambda _frame: {
                "person_count": 1,
                "activity": "person_seated",
                "objects": ["desk", "monitor"],
                "lighting": "bright",
                "private_description": "must not enter the prompt",
            },
        )
        room.observe_once(now_ms=1)
        session = LanBridgeSession(LanBridgeConfig(), room_context=room)

        lines = session._embodiment_context_lines()

        self.assertTrue(any(line.startswith("ambient_room:") for line in lines))
        self.assertNotIn("private_description", "\n".join(lines))
        self.assertNotIn("must not enter", "\n".join(lines))

    def test_visual_question_refreshes_room_context_before_model(self):
        raw_frame = b"P5\n1 1\n255\n\x00"
        room = RoomContextRuntime(
            RoomObservationConfig(enabled=True, interval_seconds=300, command="fixture"),
            frame_source=lambda: raw_frame,
            model_observer=lambda _frame: {
                "person_count": 1,
                "activity": "person_seated",
                "objects": ["desk", "monitor"],
                "lighting": "bright",
            },
        )
        runner_result = SimpleNamespace(
            raw_response=json.dumps(
                {
                    "spoken_text": "I can see a desk and a monitor.",
                    "mode": "speak",
                    "earcon": "none",
                    "emotion": {"arousal": 0.0, "valence": 0.0},
                    "memory_write": {},
                    "memory_forget": [],
                }
            ),
            command_source="test",
            elapsed_ms=1.0,
            approx_tokens_per_sec=10.0,
        )
        session = LanBridgeSession(LanBridgeConfig(), room_context=room)

        with patch("lan_service.run_runner_profile", return_value=runner_result) as runner:
            frames = session.handle_text(
                json.dumps({"type": "utterance_end", "seq": 93, "text": "What do you see?"})
            )

        self.assertEqual(1, room.status()["observations"])
        embodiment_lines = runner.call_args.kwargs["embodiment_lines"]
        self.assertTrue(any("coarse_objects=desk,monitor" in line for line in embodiment_lines))
        response = next(
            frame
            for frame in frames
            if isinstance(frame, dict) and frame.get("type") == "response_start"
        )
        self.assertEqual("I can see a desk and a monitor.", response["text"])

    def test_deictic_color_question_reports_grayscale_limit_without_model(self):
        session = LanBridgeSession(LanBridgeConfig())

        with patch("lan_service.run_runner_profile") as runner:
            frames = session.handle_text(
                json.dumps({"type": "utterance_end", "seq": 94, "text": "What color is my shirt?"})
            )

        runner.assert_not_called()
        response = next(
            frame
            for frame in frames
            if isinstance(frame, dict) and frame.get("type") == "response_start"
        )
        self.assertEqual(
            "My current camera feed is grayscale, so I cannot determine that color.",
            response["text"],
        )

    def test_initiative_uses_character_path_without_opening_conversation_capture(self):
        policy = InitiativePolicy(InitiativeConfig(enabled=True), now_ms=0)
        policy.observe_presence(True, face_count=1, now_ms=599_999)
        session = LanBridgeSession(
            LanBridgeConfig(
                conversation_v2_enabled=True,
                initiative_enabled=True,
                tts_command="fixture-tts",
            ),
            initiative_policy=policy,
        )
        session._last_robot_heartbeat = {"robot_mode": 1}
        decision = session.initiative_decision(observed_ms=600_000, local_hour=12)
        self.assertIsNotNone(decision)

        initiative_runner = SimpleNamespace(
            configured_runner=True,
            raw_response=json.dumps(
                {
                    "spoken_text": "Did that lamp move?",
                    "mode": "attend",
                    "earcon": "none",
                    "emotion": {"arousal": 0.1, "valence": 0.2},
                    "memory_write": {},
                    "memory_forget": [],
                }
            ),
        )
        with patch("lan_service.now_ms", return_value=600_000), patch(
            "lan_service.run_runner_profile",
            return_value=initiative_runner,
        ), patch.object(
                session,
                "_stream_tts_turn",
                return_value=(
                    [{"type": "response_start", "seq": 1}, {"type": "response_end", "seq": 1}],
                    {"tts_stream_complete": True, "tts_first_audio_ms": 12.0},
                    "",
                ),
            ):
            frames = session.run_initiative(decision)

        self.assertEqual("response_start", frames[0]["type"])
        self.assertEqual(ConversationPhase.IDLE, session.conversation.phase)
        self.assertFalse(session.conversation.capture_open)
        self.assertTrue(policy.status(now_ms=600_001)["pendingReply"])


if __name__ == "__main__":
    unittest.main()
