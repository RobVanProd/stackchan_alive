#!/usr/bin/env python3
"""Persistent raw-WAV DirectML RVC worker for Stackchan voice-v2."""

from __future__ import annotations

import argparse
import json
import sys
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from typing import Any

from voice_v2_directml_runtime import DirectMlRvcRuntime


MAX_REQUEST_BYTES = 8 * 1024 * 1024


class Worker:
    def __init__(self, runtime: DirectMlRvcRuntime) -> None:
        self.runtime = runtime
        self.lock = threading.Lock()
        self.started_at = time.time()
        self.convert_count = 0
        self.total_convert_ms = 0.0
        self.last_record: dict[str, object] = {}

    def health(self) -> dict[str, object]:
        average_ms = self.total_convert_ms / self.convert_count if self.convert_count else 0.0
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
            if self.path != "/convert":
                json_response(self, 404, {"ok": False, "error": "not_found"})
                return
            try:
                length = int(self.headers.get("Content-Length", "0"))
            except ValueError:
                length = 0
            if length <= 0 or length > MAX_REQUEST_BYTES:
                json_response(self, 413, {"ok": False, "error": "request_too_large"})
                return
            try:
                output, record = worker.convert(self.rfile.read(length))
            except Exception as exc:
                json_response(self, 500, {"ok": False, "error": str(exc)[:500]})
                return
            self.send_response(200)
            self.send_header("Content-Type", "audio/wav")
            self.send_header("Content-Length", str(len(output)))
            self.send_header("X-Stackchan-Elapsed-Ms", str(round(float(record["elapsed_seconds"]) * 1000.0, 2)))
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
    worker = Worker(runtime)
    print(json.dumps(worker.health(), separators=(",", ":"), ensure_ascii=True), flush=True)
    server = ThreadingHTTPServer((args.host, args.port), make_handler(worker))
    print(f"Stackchan DirectML RVC listening on http://{args.host}:{args.port}", flush=True)
    server.serve_forever()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
