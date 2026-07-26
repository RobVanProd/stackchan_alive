#!/usr/bin/env python3
"""Persistent raw-WAV DirectML RVC worker for Stackchan voice-v2."""

from __future__ import annotations

import argparse
import io
import json
import sys
import tempfile
import threading
import time
import wave
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from typing import TYPE_CHECKING, Any

from rvc_tts import PersistentWindowsSpeechSynthesizer

if TYPE_CHECKING:
    from voice_v2_directml_runtime import DirectMlRvcRuntime


MAX_REQUEST_BYTES = 8 * 1024 * 1024
MAX_SYNTHESIS_REQUEST_BYTES = 64 * 1024
MAX_SYNTHESIS_TEXT_CHARS = 1000


def pcm16_from_worker_wav(
    wav_bytes: bytes,
    *,
    target_rate: int = 16000,
) -> tuple[bytes, str, float]:
    """Decode the worker's mono PCM WAV and downsample with an anti-alias FIR."""
    import numpy as np

    started = time.perf_counter()
    with wave.open(io.BytesIO(wav_bytes), "rb") as wav:
        channels = wav.getnchannels()
        sample_width = wav.getsampwidth()
        source_rate = wav.getframerate()
        compression = wav.getcomptype()
        pcm = wav.readframes(wav.getnframes())
    if channels != 1 or sample_width != 2 or compression != "NONE":
        raise ValueError("unsupported worker WAV format")
    if source_rate == target_rate:
        return pcm, "worker-wave-pcm", (time.perf_counter() - started) * 1000.0
    if source_rate < target_rate or source_rate % target_rate:
        raise ValueError("worker WAV rate requires general resampling")
    ratio = source_rate // target_rate
    samples = np.frombuffer(pcm, dtype="<i2").astype(np.float64)
    taps = 63
    offsets = np.arange(taps) - (taps - 1) / 2
    cutoff = 0.475 / ratio
    kernel = 2 * cutoff * np.sinc(2 * cutoff * offsets) * np.hamming(taps)
    kernel /= kernel.sum()
    filtered = np.convolve(samples, kernel, mode="same")
    downsampled = np.clip(
        np.rint(filtered[::ratio]),
        -32768,
        32767,
    ).astype("<i2")
    return (
        downsampled.tobytes(),
        f"worker-numpy-fir-{taps}",
        (time.perf_counter() - started) * 1000.0,
    )


class Worker:
    def __init__(
        self,
        runtime: "DirectMlRvcRuntime",
        *,
        base_synthesizer: PersistentWindowsSpeechSynthesizer | None = None,
        base_tts_warmup_ms: float = 0.0,
        base_tts_error: str = "",
    ) -> None:
        self.runtime = runtime
        self.base_synthesizer = base_synthesizer
        self.base_tts_warmup_ms = float(base_tts_warmup_ms)
        self.base_tts_error = str(base_tts_error)[:240]
        self.lock = threading.Lock()
        self.started_at = time.time()
        self.convert_count = 0
        self.total_convert_ms = 0.0
        self.synthesize_count = 0
        self.total_synthesize_ms = 0.0
        self.last_record: dict[str, object] = {}

    def health(self) -> dict[str, object]:
        average_ms = self.total_convert_ms / self.convert_count if self.convert_count else 0.0
        average_synthesis_ms = (
            self.total_synthesize_ms / self.synthesize_count
            if self.synthesize_count
            else 0.0
        )
        return {
            "schema": "stackchan.rvc-directml-worker.health.v1",
            "ready": True,
            "backend": "torch-directml",
            "device": self.runtime.device,
            "device_name": self.runtime.device_name,
            "device_available": self.runtime.device_available,
            "method": self.runtime.f0_method,
            "model": str(self.runtime.model_path),
            "index": str(self.runtime.index_path),
            "index_rate": self.runtime.index_rate,
            "load_ms": round(self.runtime.load_seconds * 1000.0, 2),
            "warmup": dict(self.runtime.warmup_record),
            "convert_count": self.convert_count,
            "average_convert_ms": round(average_ms, 2),
            "synthesis_ready": self.base_synthesizer is not None,
            "base_tts_backend": "persistent-system-speech",
            "base_tts_warmup_ms": round(self.base_tts_warmup_ms, 2),
            "base_tts_error": self.base_tts_error,
            "synthesize_count": self.synthesize_count,
            "average_synthesize_ms": round(average_synthesis_ms, 2),
            "last": dict(self.last_record),
            "uptime_seconds": round(time.time() - self.started_at, 2),
        }

    def convert(self, wav_bytes: bytes) -> tuple[bytes, dict[str, object]]:
        with self.lock:
            output, record = self.runtime.convert_wav_bytes(wav_bytes)
            self.convert_count += 1
            elapsed_ms = float(record.get("elapsed_seconds", 0.0)) * 1000.0
            self.total_convert_ms += elapsed_ms
            self.last_record = dict(record)
            return output, record

    def synthesize(self, request: dict[str, object]) -> tuple[bytes, dict[str, object]]:
        text = " ".join(str(request.get("text") or "").split())
        if not text:
            raise ValueError("synthesis text is empty")
        if len(text) > MAX_SYNTHESIS_TEXT_CHARS:
            raise ValueError("synthesis text is too long")
        if self.base_synthesizer is None:
            raise RuntimeError("persistent base TTS is unavailable")
        rate = max(-10, min(10, int(request.get("rate", 1))))
        volume = max(0, min(100, int(request.get("volume", 100))))
        sample_rate = max(8000, min(48000, int(request.get("sample_rate", 48000))))
        voice = str(request.get("voice") or "").strip()[:160]
        started = time.perf_counter()
        with self.lock, tempfile.TemporaryDirectory(prefix="stackchan_worker_tts_") as temp_dir:
            base_wav = Path(temp_dir) / "base.wav"
            base_elapsed_ms = self.base_synthesizer.synthesize(
                text,
                base_wav,
                voice=voice,
                rate=rate,
                volume=volume,
                sample_rate=sample_rate,
            )
            output_wav, record = self.runtime.convert_wav_bytes(base_wav.read_bytes())
            output, decode_backend, decode_elapsed_ms = pcm16_from_worker_wav(output_wav)
            self.convert_count += 1
            convert_elapsed_ms = float(record.get("elapsed_seconds", 0.0)) * 1000.0
            self.total_convert_ms += convert_elapsed_ms
            synthesis_elapsed_ms = (time.perf_counter() - started) * 1000.0
            self.synthesize_count += 1
            self.total_synthesize_ms += synthesis_elapsed_ms
            self.last_record = {
                **record,
                "base_tts_elapsed_ms": round(base_elapsed_ms, 2),
                "audio_format": "pcm16",
                "audio_sample_rate": 16000,
                "audio_decode_backend": decode_backend,
                "audio_decode_elapsed_ms": round(decode_elapsed_ms, 2),
                "synthesis_elapsed_ms": round(synthesis_elapsed_ms, 2),
            }
            return output, dict(self.last_record)

    def close(self) -> None:
        if self.base_synthesizer is not None:
            self.base_synthesizer.close()


def json_response(handler: BaseHTTPRequestHandler, status: int, payload: dict[str, object]) -> None:
    body = json.dumps(payload, separators=(",", ":"), ensure_ascii=True).encode("utf-8")
    handler.send_response(status)
    handler.send_header("Content-Type", "application/json")
    handler.send_header("Content-Length", str(len(body)))
    handler.end_headers()
    handler.wfile.write(body)


def make_handler(worker: Worker) -> type[BaseHTTPRequestHandler]:
    class Handler(BaseHTTPRequestHandler):
        server_version = "StackchanDirectMlRvc/1.0"

        def log_message(self, format: str, *args: Any) -> None:
            sys.stderr.write("%s - %s\n" % (self.log_date_time_string(), format % args))

        def do_GET(self) -> None:
            if self.path == "/health":
                json_response(self, 200, worker.health())
                return
            json_response(self, 404, {"ok": False, "error": "not_found"})

        def do_POST(self) -> None:
            if self.path not in {"/convert", "/synthesize"}:
                json_response(self, 404, {"ok": False, "error": "not_found"})
                return
            try:
                length = int(self.headers.get("Content-Length", "0"))
            except ValueError:
                length = 0
            maximum = (
                MAX_SYNTHESIS_REQUEST_BYTES
                if self.path == "/synthesize"
                else MAX_REQUEST_BYTES
            )
            if length <= 0 or length > maximum:
                json_response(self, 413, {"ok": False, "error": "request_too_large"})
                return
            try:
                payload = self.rfile.read(length)
                if self.path == "/synthesize":
                    request = json.loads(payload.decode("utf-8"))
                    if not isinstance(request, dict):
                        raise ValueError("synthesis request must be an object")
                    output, record = worker.synthesize(request)
                else:
                    output, record = worker.convert(payload)
            except (UnicodeDecodeError, json.JSONDecodeError, TypeError, ValueError) as exc:
                json_response(self, 400, {"ok": False, "error": str(exc)[:500]})
                return
            except Exception as exc:
                json_response(self, 500, {"ok": False, "error": str(exc)[:500]})
                return
            self.send_response(200)
            self.send_header(
                "Content-Type",
                "application/octet-stream"
                if self.path == "/synthesize"
                else "audio/wav",
            )
            self.send_header("Content-Length", str(len(output)))
            self.send_header("X-Stackchan-Elapsed-Ms", str(round(float(record["elapsed_seconds"]) * 1000.0, 2)))
            if "base_tts_elapsed_ms" in record:
                self.send_header(
                    "X-Stackchan-Base-Tts-Ms",
                    str(round(float(record["base_tts_elapsed_ms"]), 2)),
                )
            if "synthesis_elapsed_ms" in record:
                self.send_header(
                    "X-Stackchan-Synthesis-Ms",
                    str(round(float(record["synthesis_elapsed_ms"]), 2)),
                )
            if "audio_sample_rate" in record:
                self.send_header(
                    "X-Stackchan-Audio-Format",
                    str(record.get("audio_format", "")),
                )
                self.send_header(
                    "X-Stackchan-Sample-Rate",
                    str(int(record["audio_sample_rate"])),
                )
                self.send_header(
                    "X-Stackchan-Audio-Decode-Backend",
                    str(record.get("audio_decode_backend", "")),
                )
                self.send_header(
                    "X-Stackchan-Audio-Decode-Ms",
                    str(round(float(record.get("audio_decode_elapsed_ms", 0.0)), 2)),
                )
            for key, header in (
                ("feature_seconds", "X-Stackchan-Feature-Ms"),
                ("f0_seconds", "X-Stackchan-F0-Ms"),
                ("synth_seconds", "X-Stackchan-Synth-Ms"),
            ):
                if key in record:
                    self.send_header(header, str(round(float(record[key]) * 1000.0, 2)))
            self.end_headers()
            self.wfile.write(output)

    return Handler


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--host", default="127.0.0.1")
    parser.add_argument("--port", type=int, default=5059)
    parser.add_argument("--vendor-root", type=Path, required=True)
    parser.add_argument("--model", type=Path, required=True)
    parser.add_argument("--index", type=Path, required=True)
    parser.add_argument("--f0-method", choices=("pm", "harvest", "crepe", "rmvpe"), default="pm")
    parser.add_argument("--index-rate", type=float, default=0.62)
    parser.add_argument("--pitch", type=int, default=2)
    parser.add_argument("--no-warmup", action="store_true")
    return parser


def main() -> int:
    from voice_v2_directml_runtime import DirectMlRvcRuntime

    args = build_parser().parse_args()
    runtime = DirectMlRvcRuntime(
        vendor_root=args.vendor_root,
        model_path=args.model,
        index_path=args.index,
        f0_method=args.f0_method,
        index_rate=args.index_rate,
        pitch=args.pitch,
        warmup=not args.no_warmup,
    )
    base_synthesizer: PersistentWindowsSpeechSynthesizer | None = None
    base_tts_warmup_ms = 0.0
    base_tts_error = ""
    try:
        base_synthesizer = PersistentWindowsSpeechSynthesizer()
        with tempfile.TemporaryDirectory(prefix="stackchan_worker_tts_warmup_") as temp_dir:
            base_tts_warmup_ms = base_synthesizer.synthesize(
                "Hello.",
                Path(temp_dir) / "warmup.wav",
            )
    except Exception as exc:
        base_tts_error = f"{type(exc).__name__}: {exc}"
        if base_synthesizer is not None:
            base_synthesizer.close()
        base_synthesizer = None
    worker = Worker(
        runtime,
        base_synthesizer=base_synthesizer,
        base_tts_warmup_ms=base_tts_warmup_ms,
        base_tts_error=base_tts_error,
    )
    print(json.dumps(worker.health(), separators=(",", ":"), ensure_ascii=True), flush=True)
    server = ThreadingHTTPServer((args.host, args.port), make_handler(worker))
    print(f"Stackchan DirectML RVC listening on http://{args.host}:{args.port}", flush=True)
    try:
        server.serve_forever()
    finally:
        worker.close()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
