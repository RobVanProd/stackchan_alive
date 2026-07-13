import json
import os
import base64
import socket
import sys
import tempfile
import threading
import time
import unittest
import wave
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
    build_handshake_response,
    contains_stackchan_wake_phrase,
    configure_client_socket,
    encode_ws_frame,
    encode_ws_text,
    is_identity_question,
    explicit_research_request,
    mouth_frame_for_audio_window,
    prompt_case_for_text,
    read_ws_frame,
    send_connection_frame,
    serve,
    websocket_accept_value,
)
from cancellation import CancellationToken, OperationCancelledError
from bridge_memory import BridgeMemory
from local_runner import RunnerExecutionError, run_runner_profile
from reference_bridge import PROTOCOL, load_bridge_memory
from stt_adapter import STT_COMMAND_ENV
from tts_adapter import TTS_COMMAND_ENV

RUNNER_ENV = {
    "STACKCHAN_GEMMA4_E2B_GGUF_COMMAND": "",
    "STACKCHAN_GEMMA4_E2B_LITERT_COMMAND": "",
    "STACKCHAN_GEMMA4_E4B_GGUF_COMMAND": "",
    "STACKCHAN_MODEL_COMMAND": "",
    TTS_COMMAND_ENV: "",
}


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
        with socket.create_connection(("127.0.0.1", port), timeout=5.0) as client:
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
        with socket.create_connection(("127.0.0.1", port), timeout=5.0) as client:
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
            with socket.create_connection(("127.0.0.1", port), timeout=5.0) as client:
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

    def test_prompt_case_can_follow_utterance_text(self):
        self.assertEqual("picked_up", prompt_case_for_text("I picked you up", "", "greeting"))
        self.assertEqual("low_battery", prompt_case_for_text("Power is low", "", "greeting"))
        self.assertEqual("question", prompt_case_for_text("What is that?", "", "greeting"))
        self.assertEqual("confused", prompt_case_for_text("This is ambiguous", "", "greeting"))
        self.assertEqual("forget", prompt_case_for_text("Forget that note", "", "greeting"))
        self.assertEqual("greeting", prompt_case_for_text("Hello", "", "greeting"))
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
        session = LanBridgeSession(LanBridgeConfig(persona_id="glow"))
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
        self.assertTrue(any(isinstance(frame, dict) and frame.get("type") == "response_start" for frame in frames))

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
            with patch("lan_service.run_runner_profile", side_effect=RunnerExecutionError("offline")):
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

        self.assertEqual("runner_error", frames[0]["code"])
        self.assertEqual("", loaded.fact_value("user.favorite_color"))

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

        session.handle_text(json.dumps({"type": "utterance_start", "sample_rate": 16000}))
        frames = session.handle_text(json.dumps({"type": "utterance_end", "seq": 3}))

        self.assertEqual("error", frames[0]["type"])
        self.assertEqual("empty_utterance", frames[0]["code"])
        self.assertEqual(0, frames[0]["audio_bytes"])

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

        def fake_synthesize(text, **_kwargs):
            calls.append(text)
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
            context_after_playback = session.conversation.context_lines()
            followup = session.handle_text(
                json.dumps({"type": "utterance_start", "seq": 71, "sample_rate": 16000})
            )
            exit_frames = session.handle_text(
                json.dumps(
                    {"type": "utterance_end", "seq": 71, "text": "Goodbye Stackchan"}
                )
            )

        self.assertEqual("engaged", listening[0]["conversation_state"])
        self.assertEqual("response_end", response[-1]["type"])
        self.assertEqual("error", stale[0]["type"])
        self.assertEqual("playback_complete_seq_mismatch", stale[0]["code"])
        self.assertEqual("conversation_reply_window", completed[0]["type"])
        self.assertEqual(0, completed[0]["open_after_ms"])
        self.assertEqual(8000, completed[0]["window_ms"])
        self.assertEqual("reply_window", completed[0]["conversation_state"])
        self.assertFalse(completed[0]["conversation_capture_open"])
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
        self.assertEqual("heartbeat", exit_frames[0]["type"])
        self.assertEqual("cooldown", exit_frames[0]["conversation_state"])
        self.assertEqual("exit_phrase", exit_frames[0]["conversation_reason"])
        self.assertEqual((), session.conversation.context_lines())

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


if __name__ == "__main__":
    unittest.main()
