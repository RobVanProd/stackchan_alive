import json
import os
import base64
import sys
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
        self.assertEqual("listening", listening[0]["type"])
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

            with patch.dict(os.environ, RUNNER_ENV, clear=False):
                session = LanBridgeSession(LanBridgeConfig(runner_case="greeting", stt_command=command))
                session.handle_text(json.dumps({"type": "utterance_start", "sample_rate": 16000}))
                session.handle_binary(b"\x01\x00\x02\x00")
                frames = session.handle_text(json.dumps({"type": "utterance_end", "seq": 5}))

        self.assertEqual("thinking", frames[0]["type"])
        self.assertEqual(4, frames[0]["audio_bytes"])
        self.assertEqual(16000, frames[0]["audio_sample_rate"])
        self.assertEqual("cli", frames[0]["stt_command_source"])
        self.assertGreaterEqual(frames[0]["stt_elapsed_ms"], 0.0)
        self.assertEqual("response_start", frames[1]["type"])
        self.assertEqual("react", frames[1]["intent"])
        self.assertIn("user picked Stackchan up", session.memory.physical_context)

    def test_audio_only_turn_reports_stt_command_failure(self):
        with tempfile.TemporaryDirectory() as temp_dir:
            script = Path(temp_dir) / "broken_stt.py"
            script.write_text("import sys\nsys.stdin.buffer.read()\nprint('nope', file=sys.stderr)\nsys.exit(7)\n")
            command = f'"{sys.executable}" "{script}"'

            session = LanBridgeSession(LanBridgeConfig(stt_command=command))
            session.handle_text(json.dumps({"type": "utterance_start", "sample_rate": 16000}))
            session.handle_binary(b"\x01\x00\x02\x00")
            frames = session.handle_text(json.dumps({"type": "utterance_end", "seq": 6}))

        self.assertEqual("error", frames[0]["type"])
        self.assertEqual("stt_error", frames[0]["code"])
        self.assertIn("exit 7", frames[0]["detail"])
        self.assertEqual(4, frames[0]["audio_bytes"])

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
            script.write_text(
                "\n".join(
                    [
                        "import json",
                        "import os",
                        "import sys",
                        "text = sys.stdin.buffer.read().decode('utf-8')",
                        "assert 'Hello' in text or 'awake' in text",
                        "assert os.environ['STACKCHAN_TTS_TEXT_BYTES'] == str(len(text.encode('utf-8')))",
                        "assert os.environ['STACKCHAN_TTS_VOICE'] == 'rvc-bright'",
                        "print(json.dumps({'audio_format':'wav','sample_rate':22050,'audio_bytes':222,'beats':[{'env':0.21,'viseme':'ah','duration_ms':30},{'env':0.63,'viseme':'ee','duration_ms':40}]}))",
                    ]
                ),
                encoding="utf-8",
            )
            command = f'"{sys.executable}" "{script}"'

            with patch.dict(os.environ, RUNNER_ENV, clear=False):
                session = LanBridgeSession(
                    LanBridgeConfig(runner_case="greeting", tts_command=command, tts_voice="rvc-bright")
                )
                frames = session.handle_text(json.dumps({"type": "utterance_end", "seq": 8, "text": "Hello"}))

        response_start = next(frame for frame in frames if frame["type"] == "response_start")
        audio_frames = [frame for frame in frames if frame["type"] == "audio"]
        self.assertEqual("cli", response_start["tts_command_source"])
        self.assertEqual("rvc-bright", response_start["tts_voice"])
        self.assertEqual(2, response_start["tts_beats"])
        self.assertEqual(70, response_start["tts_duration_ms"])
        self.assertEqual("wav", response_start["tts_audio_format"])
        self.assertEqual(22050, response_start["tts_sample_rate"])
        self.assertEqual(222, response_start["tts_audio_bytes"])
        self.assertEqual(2, len(audio_frames))
        self.assertEqual(0.21, audio_frames[0]["env"])
        self.assertEqual("ah", audio_frames[0]["viseme"])
        self.assertEqual(30, audio_frames[0]["duration_ms"])
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


if __name__ == "__main__":
    unittest.main()
