import base64
import unittest

from bridge.ollama_room_vision import (
    _RejectRedirects,
    build_request_payload,
    pgm_to_png,
    validate_loopback_url,
)


class OllamaRoomVisionTests(unittest.TestCase):
    def test_pgm_is_converted_to_grayscale_png_in_memory(self) -> None:
        frame = b"P5\n2 2\n255\n\x00\x7f\x80\xff"
        png = pgm_to_png(frame)
        payload = build_request_payload(frame, "fixture-vision")

        self.assertTrue(png.startswith(b"\x89PNG\r\n\x1a\n"))
        self.assertEqual(png, base64.b64decode(payload["images"][0]))
        self.assertEqual("fixture-vision", payload["model"])
        self.assertFalse(payload["stream"])
        self.assertFalse(payload["think"])
        self.assertEqual(-1, payload["keep_alive"])

    def test_vision_transport_is_loopback_only(self) -> None:
        self.assertEqual("http://127.0.0.1:11434", validate_loopback_url("http://127.0.0.1:11434"))
        self.assertEqual("http://localhost:11434", validate_loopback_url("http://localhost:11434/"))
        with self.assertRaises(ValueError):
            validate_loopback_url("https://example.com")
        with self.assertRaises(ValueError):
            validate_loopback_url("http://192.168.1.10:11434")

    def test_invalid_pgm_is_rejected_before_model_request(self) -> None:
        with self.assertRaises(ValueError):
            pgm_to_png(b"not-an-image")
        with self.assertRaises(ValueError):
            pgm_to_png(b"P5\n2 2\n255\n\x00")

    def test_loopback_transport_does_not_follow_redirects(self) -> None:
        handler = _RejectRedirects()

        self.assertIsNone(
            handler.redirect_request(None, None, 307, "redirect", {}, "https://example.com")
        )


if __name__ == "__main__":
    unittest.main()
