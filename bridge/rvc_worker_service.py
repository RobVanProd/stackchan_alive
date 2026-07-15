#!/usr/bin/env python3
"""Warm RVC worker service for low-latency Stackchan voice conversion."""

from __future__ import annotations

import argparse
import base64
import json
import os
import sys
import tempfile
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from typing import Any

os.environ.setdefault("TORCH_FORCE_NO_WEIGHTS_ONLY_LOAD", "1")

from rvc_python.infer import RVCInference

from rvc_tts import float_env, int_env, rvc_index_path, rvc_model_path
from voice_device_truth import torch_device_truth


DEFAULT_HOST = "127.0.0.1"
DEFAULT_PORT = 5055
MAX_REQUEST_BYTES = 8 * 1024 * 1024


class RvcWorker:
    def __init__(
        self,
        *,
        device: str,
        method: str,
        model_path: Path,
        index_path: Path,
        version: str,
    ) -> None:
        self.device = device
        self.method = method
        self.model_path = model_path
        self.index_path = index_path
        self.version = version
        self.lock = threading.Lock()
        self.started_at = time.time()
        self.convert_count = 0
        self.total_convert_ms = 0.0
        self.total_queue_wait_ms = 0.0
        self.total_infer_ms = 0.0
        self.last_convert_ms = 0.0
        self.last_queue_wait_ms = 0.0
        self.last_infer_ms = 0.0

        load_start = time.perf_counter()
        self.rvc = RVCInference(
            device=device,
            model_path=str(model_path),
            index_path=str(index_path),
            version=version,
        )
        self.rvc.set_params(
            f0method=method,
            f0up_key=int_env("STACKCHAN_RVC_PITCH", 2, -24, 24),
            index_rate=float_env("STACKCHAN_RVC_INDEX_RATE", 0.62, 0.0, 1.0),
            filter_radius=int_env("STACKCHAN_RVC_FILTER_RADIUS", 3, 0, 7),
            resample_sr=int_env("STACKCHAN_RVC_RESAMPLE_SR", 0, 0, 48000),
            rms_mix_rate=float_env("STACKCHAN_RVC_RMS_MIX_RATE", 0.72, 0.0, 1.0),
            protect=float_env("STACKCHAN_RVC_PROTECT", 0.28, 0.0, 0.5),
        )
        self.load_elapsed_ms = (time.perf_counter() - load_start) * 1000.0

    def health(self) -> dict[str, Any]:
        avg_ms = self.total_convert_ms / self.convert_count if self.convert_count else 0.0
        avg_queue_ms = self.total_queue_wait_ms / self.convert_count if self.convert_count else 0.0
        avg_infer_ms = self.total_infer_ms / self.convert_count if self.convert_count else 0.0
        device_name, device_available = torch_device_truth(self.device)
        return {
            "schema": "stackchan.rvc-worker.health.v1",
            "ready": True,
            "device": self.device,
            "device_name": device_name,
            "device_available": device_available,
            "method": self.method,
            "model": str(self.model_path),
            "index": str(self.index_path),
            "version": self.version,
            "load_elapsed_ms": round(self.load_elapsed_ms, 2),
            "convert_count": self.convert_count,
            "average_convert_ms": round(avg_ms, 2),
            "average_queue_wait_ms": round(avg_queue_ms, 2),
            "average_infer_ms": round(avg_infer_ms, 2),
            "last_convert_ms": round(self.last_convert_ms, 2),
            "last_queue_wait_ms": round(self.last_queue_wait_ms, 2),
            "last_infer_ms": round(self.last_infer_ms, 2),
            "uptime_seconds": round(time.time() - self.started_at, 2),
        }

    def convert_wav(self, wav_bytes: bytes) -> dict[str, Any]:
        with tempfile.TemporaryDirectory(prefix="stackchan_rvc_worker_") as temp_dir:
            work = Path(temp_dir)
            input_wav = work / "input.wav"
            output_wav = work / "output.wav"
            input_wav.write_bytes(wav_bytes)
            start = time.perf_counter()
            queue_start = start
            with self.lock:
                queue_wait_ms = (time.perf_counter() - queue_start) * 1000.0
                infer_start = time.perf_counter()
                self.rvc.infer_file(str(input_wav), str(output_wav))
                infer_elapsed_ms = (time.perf_counter() - infer_start) * 1000.0
                elapsed_ms = (time.perf_counter() - start) * 1000.0
                self.convert_count += 1
                self.total_convert_ms += elapsed_ms
                self.total_queue_wait_ms += queue_wait_ms
                self.total_infer_ms += infer_elapsed_ms
                self.last_convert_ms = elapsed_ms
                self.last_queue_wait_ms = queue_wait_ms
                self.last_infer_ms = infer_elapsed_ms
            converted = output_wav.read_bytes()
        return {
            "schema": "stackchan.rvc-worker.convert.v1",
            "ok": True,
            "device": self.device,
            "method": self.method,
            "convert_elapsed_ms": round(elapsed_ms, 2),
            "queue_wait_ms": round(queue_wait_ms, 2),
            "infer_elapsed_ms": round(infer_elapsed_ms, 2),
            "wav_bytes": len(converted),
            "wav_b64": base64.b64encode(converted).decode("ascii"),
        }


def json_response(handler: BaseHTTPRequestHandler, status: int, payload: dict[str, Any]) -> None:
    body = json.dumps(payload, separators=(",", ":"), ensure_ascii=True).encode("utf-8")
    handler.send_response(status)
    handler.send_header("Content-Type", "application/json")
    handler.send_header("Content-Length", str(len(body)))
    handler.end_headers()
    handler.wfile.write(body)


def make_handler(worker: RvcWorker) -> type[BaseHTTPRequestHandler]:
    class Handler(BaseHTTPRequestHandler):
        server_version = "StackchanRvcWorker/1.0"

        def log_message(self, format: str, *args: Any) -> None:
            sys.stderr.write("%s - %s\n" % (self.log_date_time_string(), format % args))

        def do_GET(self) -> None:
            if self.path == "/health":
                json_response(self, 200, worker.health())
                return
            json_response(self, 404, {"ok": False, "error": "not_found"})

        def do_POST(self) -> None:
            if self.path != "/convert":
                json_response(self, 404, {"ok": False, "error": "not_found"})
                return
            try:
                length = int(self.headers.get("Content-Length", "0"))
            except ValueError:
                json_response(self, 400, {"ok": False, "error": "bad_content_length"})
                return
            if length <= 0 or length > MAX_REQUEST_BYTES:
                json_response(self, 413, {"ok": False, "error": "request_too_large"})
                return
            try:
                payload = json.loads(self.rfile.read(length).decode("utf-8"))
                wav_b64 = str(payload.get("wav_b64", ""))
                wav_bytes = base64.b64decode(wav_b64, validate=True)
                result = worker.convert_wav(wav_bytes)
            except Exception as exc:
                json_response(self, 500, {"ok": False, "error": str(exc)})
                return
            json_response(self, 200, result)

    return Handler


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--host", default=os.environ.get("STACKCHAN_RVC_WORKER_HOST", DEFAULT_HOST))
    parser.add_argument("--port", type=int, default=int_env("STACKCHAN_RVC_WORKER_PORT", DEFAULT_PORT, 1, 65535))
    parser.add_argument("--device", default=os.environ.get("STACKCHAN_RVC_DEVICE", "cuda:0"))
    parser.add_argument("--method", default=os.environ.get("STACKCHAN_RVC_F0_METHOD", "pm"))
    parser.add_argument("--model", default=str(rvc_model_path()))
    parser.add_argument("--index", default=str(rvc_index_path()))
    parser.add_argument("--version", default=os.environ.get("STACKCHAN_RVC_VERSION", "v2"))
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    worker = RvcWorker(
        device=args.device,
        method=args.method,
        model_path=Path(args.model),
        index_path=Path(args.index),
        version=args.version,
    )
    server = ThreadingHTTPServer((args.host, args.port), make_handler(worker))
    print(json.dumps(worker.health(), separators=(",", ":"), ensure_ascii=True), flush=True)
    print(f"Stackchan RVC worker listening on http://{args.host}:{args.port}", flush=True)
    server.serve_forever()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
