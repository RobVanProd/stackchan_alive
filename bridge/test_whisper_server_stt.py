import io
import json
import unittest
import wave
from unittest.mock import patch

from bridge.whisper_server_stt import (
    MAX_RESPONSE_BYTES,
    _RejectRedirects,
    WhisperServerError,
    pcm_to_wav,
    transcribe_pcm_via_server,
    validate_loopback_url,
)


class _Response:
    status = 200

    def __init__(self, payload: object) -> None:
        self.payload = json.dumps(payload).encode("utf-8")

    def __enter__(self):
        return self

    def __exit__(self, exc_type, exc, traceback):
        return False

    def read(self, maximum: int) -> bytes:
        return self.payload[:maximum]


class _Opener:
    def __init__(self, payload: object) -> None:
        self.response = _Response(payload)
        self.request = None
        self.timeout = None

    def open(self, request, *, timeout: float):
        self.request = request
        self.timeout = timeout
        return self.response


class WhisperServerSttTests(unittest.TestCase):
    def test_pcm_is_wrapped_as_mono_wav_in_memory(self) -> None:
        wav_data = pcm_to_wav(b"\x01\x00\x02\x00", 16_000)

        with wave.open(io.BytesIO(wav_data), "rb") as wav:
            self.assertEqual(1, wav.getnchannels())
            self.assertEqual(2, wav.getsampwidth())
            self.assertEqual(16_000, wav.getframerate())
            self.assertEqual(b"\x01\x00\x02\x00", wav.readframes(2))

    def test_server_transport_is_loopback_only_and_rejects_redirects(self) -> None:
        self.assertEqual(
            "http://127.0.0.1:5061",
            validate_loopback_url("http://127.0.0.1:5061/"),
        )
        for url in (
            "https://127.0.0.1:5061",
            "http://192.168.1.2:5061",
            "http://example.com",
            "http://localhost:5061",
            "http://127.0.0.1:5061/inference",
            "http://user@127.0.0.1:5061",
        ):
            with self.subTest(url=url), self.assertRaises(ValueError):
                validate_loopback_url(url)

        self.assertIsNone(
            _RejectRedirects().redirect_request(
                None,
                None,
                307,
                "redirect",
                {},
                "https://example.com",
            )
        )

    def test_transcription_uses_json_response_and_normalizes_stackchan(self) -> None:
        opener = _Opener({"text": " Hey stack shed. "})
        with patch(
            "bridge.whisper_server_stt.urllib.request.build_opener",
            return_value=opener,
        ):
            result = transcribe_pcm_via_server(
                b"\x01\x00\x02\x00",
                16_000,
                server_url="http://127.0.0.1:5061",
                timeout_ms=2_000,
            )

        self.assertEqual("Hey Stackchan.", result.transcript)
        self.assertEqual("Hey stack shed.", result.raw_transcript)
        self.assertEqual("http://127.0.0.1:5061/inference", opener.request.full_url)
        self.assertEqual(2.0, opener.timeout)
        self.assertIn(b"RIFF", opener.request.data)
        self.assertIn(b'name="response_format"', opener.request.data)

    def test_oversized_server_response_is_rejected(self) -> None:
        opener = _Opener({"text": "x" * (MAX_RESPONSE_BYTES + 1)})
        with patch(
            "bridge.whisper_server_stt.urllib.request.build_opener",
            return_value=opener,
        ), self.assertRaisesRegex(WhisperServerError, "size limit"):
            transcribe_pcm_via_server(
                b"\x01\x00\x02\x00",
                16_000,
                server_url="http://127.0.0.1:5061",
            )


if __name__ == "__main__":
    unittest.main()
