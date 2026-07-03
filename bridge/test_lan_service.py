import json
import os
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

from lan_service import (
    LanBridgeConfig,
    LanBridgeSession,
    build_handshake_response,
    encode_ws_text,
    prompt_case_for_text,
    websocket_accept_value,
)
from reference_bridge import PROTOCOL, load_bridge_memory

RUNNER_ENV = {
    "STACKCHAN_GEMMA4_E2B_GGUF_COMMAND": "",
    "STACKCHAN_GEMMA4_E2B_LITERT_COMMAND": "",
    "STACKCHAN_GEMMA4_E4B_GGUF_COMMAND": "",
    "STACKCHAN_MODEL_COMMAND": "",
}


class LanServiceTests(unittest.TestCase):
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

    def test_prompt_case_can_follow_utterance_text(self):
        self.assertEqual("picked_up", prompt_case_for_text("I picked you up", "", "greeting"))
        self.assertEqual("low_battery", prompt_case_for_text("Power is low", "", "greeting"))
        self.assertEqual("confused", prompt_case_for_text("What is that?", "", "greeting"))
        self.assertEqual("forget", prompt_case_for_text("Forget that note", "", "greeting"))
        self.assertEqual("greeting", prompt_case_for_text("Hello", "", "greeting"))
        self.assertEqual("picked_up", prompt_case_for_text("Hello", "picked_up", "greeting"))

    def test_session_maps_device_messages_to_bridge_frames(self):
        with patch.dict(os.environ, RUNNER_ENV, clear=False):
            session = LanBridgeSession(LanBridgeConfig(runner_case="greeting"))

            hello = session.handle_text(json.dumps({"type": "hello", "device_id": "stackchan-001"}))
            listening = session.handle_text(json.dumps({"type": "utterance_start", "seq": 4}))
            response = session.handle_text(
                json.dumps({"type": "utterance_end", "seq": 4, "text": "I picked you up gently."})
            )

        self.assertEqual([{"type": "hello", "protocol": PROTOCOL, "session": "stackchan-001"}], hello)
        self.assertEqual([{"type": "listening"}], listening)
        self.assertEqual("thinking", response[0]["type"])
        self.assertEqual("response_start", response[1]["type"])
        self.assertEqual("react", response[1]["intent"])
        self.assertIn("Altitude change detected", response[1]["text"])
        self.assertEqual("response_end", response[-1]["type"])
        self.assertIn("user picked Stackchan up", session.memory.physical_context)

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

    def test_bad_messages_return_error_frames(self):
        session = LanBridgeSession(LanBridgeConfig())

        malformed = session.handle_text("{not json")
        unsupported = session.handle_text(json.dumps({"type": "mystery"}))
        binary = session.handle_binary(b"1234")

        self.assertEqual("error", malformed[0]["type"])
        self.assertEqual("malformed_json", malformed[0]["code"])
        self.assertEqual("unsupported_message", unsupported[0]["code"])
        self.assertEqual("binary_audio_not_implemented", binary[0]["code"])


if __name__ == "__main__":
    unittest.main()
