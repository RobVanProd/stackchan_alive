import io
import json
import threading
import unittest
import urllib.error
import urllib.request
import wave
from http.server import ThreadingHTTPServer
from pathlib import Path

from rvc_directml_worker_service import Worker, make_handler, pcm16_from_worker_wav


def wav_bytes(sample_rate: int = 48000, frames: int = 1200) -> bytes:
    output = io.BytesIO()
    with wave.open(output, "wb") as wav:
        wav.setnchannels(1)
        wav.setsampwidth(2)
        wav.setframerate(sample_rate)
        wav.writeframes(b"\x00\x00" * frames)
    return output.getvalue()


class FakeRuntime:
    device = "privateuseone:0"
    device_name = "test-device"
    device_available = True
    f0_method = "pm"
    model_path = Path("model.pth")
    index_path = Path("model.index")
    index_rate = 0.62
    load_seconds = 0.1
    warmup_record = {"elapsed_seconds": 0.2}

    def convert_wav_bytes(self, input_wav: bytes):
        if not input_wav.startswith(b"RIFF"):
            raise ValueError("expected a WAV")
        return wav_bytes(), {
            "elapsed_seconds": 0.12,
            "feature_seconds": 0.02,
            "f0_seconds": 0.01,
            "synth_seconds": 0.05,
        }


class FakeBaseSynthesizer:
    def __init__(self) -> None:
        self.closed = False

    def synthesize(
        self,
        text: str,
        wav_path: Path,
        *,
        voice: str = "",
        rate: int = 1,
        volume: int = 100,
        sample_rate: int = 48000,
    ) -> float:
        self.last = {
            "text": text,
            "voice": voice,
            "rate": rate,
            "volume": volume,
            "sample_rate": sample_rate,
        }
        with wave.open(str(wav_path), "wb") as wav:
            wav.setnchannels(1)
            wav.setsampwidth(2)
            wav.setframerate(sample_rate)
            wav.writeframes(b"\x00\x00" * 400)
        return 31.5

    def close(self) -> None:
        self.closed = True


class DirectMlWorkerTests(unittest.TestCase):
    def setUp(self) -> None:
        self.base = FakeBaseSynthesizer()
        self.worker = Worker(
            FakeRuntime(),
            base_synthesizer=self.base,
            base_tts_warmup_ms=812.5,
        )

    def test_synthesis_uses_persistent_base_voice_and_tracks_health(self) -> None:
        output, record = self.worker.synthesize(
            {
                "text": "Hello from Stackchan.",
                "voice": "Test Voice",
                "rate": 2,
                "volume": 90,
                "sample_rate": 48000,
            }
        )

        self.assertEqual(800, len(output))
        self.assertEqual(31.5, record["base_tts_elapsed_ms"])
        self.assertEqual("worker-numpy-fir-63", record["audio_decode_backend"])
        self.assertEqual("Hello from Stackchan.", self.base.last["text"])
        health = self.worker.health()
        self.assertTrue(health["synthesis_ready"])
        self.assertEqual(1, health["synthesize_count"])
        self.assertEqual(1, health["convert_count"])

    def test_http_synthesis_returns_wav_and_stage_headers(self) -> None:
        server = ThreadingHTTPServer(("127.0.0.1", 0), make_handler(self.worker))
        thread = threading.Thread(target=server.serve_forever, daemon=True)
        thread.start()
        try:
            payload = json.dumps({"text": "Hello.", "rate": 1}).encode("utf-8")
            request = urllib.request.Request(
                f"http://127.0.0.1:{server.server_port}/synthesize",
                data=payload,
                headers={"Content-Type": "application/json"},
                method="POST",
            )
            with urllib.request.urlopen(request, timeout=3) as response:
                self.assertEqual(800, len(response.read()))
                self.assertEqual("31.5", response.headers["X-Stackchan-Base-Tts-Ms"])
                self.assertEqual("120.0", response.headers["X-Stackchan-Elapsed-Ms"])
                self.assertEqual("pcm16", response.headers["X-Stackchan-Audio-Format"])
                self.assertEqual("16000", response.headers["X-Stackchan-Sample-Rate"])
        finally:
            server.shutdown()
            server.server_close()
            thread.join(timeout=3)

    def test_worker_fir_preserves_duration_at_sixteen_kilohertz(self) -> None:
        pcm, backend, elapsed_ms = pcm16_from_worker_wav(
            wav_bytes(sample_rate=48000, frames=4800)
        )

        self.assertEqual(3200, len(pcm))
        self.assertEqual("worker-numpy-fir-63", backend)
        self.assertGreaterEqual(elapsed_ms, 0.0)

    def test_http_synthesis_rejects_invalid_json(self) -> None:
        server = ThreadingHTTPServer(("127.0.0.1", 0), make_handler(self.worker))
        thread = threading.Thread(target=server.serve_forever, daemon=True)
        thread.start()
        try:
            request = urllib.request.Request(
                f"http://127.0.0.1:{server.server_port}/synthesize",
                data=b"not-json",
                headers={"Content-Type": "application/json"},
                method="POST",
            )
            with self.assertRaises(urllib.error.HTTPError) as caught:
                urllib.request.urlopen(request, timeout=3)
            self.assertEqual(400, caught.exception.code)
        finally:
            server.shutdown()
            server.server_close()
            thread.join(timeout=3)


if __name__ == "__main__":
    unittest.main()
