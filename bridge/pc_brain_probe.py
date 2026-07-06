#!/usr/bin/env python3
"""Probe a running Stackchan PC brain WebSocket service and save evidence."""

from __future__ import annotations

import argparse
import json
import socket
import sys
import time
from datetime import datetime, timezone
from pathlib import Path
from urllib.parse import urlparse

from lan_smoke import encode_client_frame, encode_client_text, make_handshake, read_handshake_response
from lan_service import read_ws_frame

SCHEMA = "stackchan.pc-brain-probe.v1"
DEFAULT_OUT_DIR = Path("output/pc-brain/latest")


def utc_timestamp() -> str:
    return datetime.now(timezone.utc).replace(microsecond=0).isoformat().replace("+00:00", "Z")


def parse_url(url: str) -> tuple[str, int, str]:
    parsed = urlparse(url)
    if parsed.scheme != "ws":
        raise ValueError("PC brain URL must use ws://")
    if not parsed.hostname:
        raise ValueError("PC brain URL must include a host")
    return parsed.hostname, parsed.port or 80, parsed.path or "/bridge"


def make_path_handshake(host: str, port: int, path: str) -> bytes:
    request = make_handshake(host, port).decode("ascii")
    return request.replace("GET /bridge HTTP/1.1", f"GET {path} HTTP/1.1", 1).encode("ascii")


def read_until(sock: socket.socket, started: float, stop_types: set[str], max_frames: int) -> tuple[list[dict[str, object]], int, int]:
    frames: list[dict[str, object]] = []
    binary_frames = 0
    binary_bytes = 0
    for _ in range(max_frames):
        opcode, payload = read_ws_frame(sock)
        elapsed_ms = round((time.perf_counter() - started) * 1000.0, 2)
        if opcode == 0x1:
            frame = json.loads(payload.decode("utf-8"))
            frame["_elapsed_ms"] = elapsed_ms
            frames.append(frame)
            if frame.get("type") in stop_types:
                return frames, binary_frames, binary_bytes
        elif opcode == 0x2:
            binary_frames += 1
            binary_bytes += len(payload)
        elif opcode == 0x8:
            raise RuntimeError("server closed websocket")
    raise RuntimeError(f"did not receive one of {sorted(stop_types)}")


def run_probe(url: str, text: str, timeout: float) -> dict[str, object]:
    host, port, path = parse_url(url)
    frames: list[dict[str, object]] = []
    binary_frames = 0
    binary_bytes = 0
    started = time.perf_counter()

    with socket.create_connection((host, port), timeout=timeout) as sock:
        sock.settimeout(timeout)
        sock.sendall(make_path_handshake(host, port, path))
        response = read_handshake_response(sock)
        if "101 Switching Protocols" not in response:
            raise RuntimeError("websocket handshake failed")

        def send(frame: dict[str, object]) -> None:
            sock.sendall(encode_client_text(frame))

        def collect(stop_types: set[str], max_frames: int = 128) -> None:
            nonlocal binary_frames, binary_bytes
            collected, binaries, bytes_seen = read_until(sock, started, stop_types, max_frames)
            frames.extend(collected)
            binary_frames += binaries
            binary_bytes += bytes_seen

        endpoint_id = "codex-pc-brain"
        send(
            {
                "type": "endpoint_hello",
                "protocol": "stackchan.bridge.v1",
                "endpoint_id": endpoint_id,
                "endpoint_name": "Codex PC Brain",
                "endpoint_kind": "pc",
                "priority": 90,
                "auto_connect": True,
                "capabilities": ["llm", "tts", "rvc", "settings", "diagnostics", "audio_downlink"],
                "supports_binary_audio": True,
                "app_version": "pc-brain-probe",
            }
        )
        collect({"endpoint_hello_result", "error"})
        send({"type": "claim_brain", "endpoint_id": endpoint_id})
        collect({"owner_status", "error"})
        send({"type": "utterance_end", "seq": 1, "endpoint_id": endpoint_id, "text": text, "runner_case": "greeting"})
        collect({"response_end", "error"}, max_frames=256)
        try:
            sock.sendall(encode_client_frame(b"", opcode=0x8))
        except OSError:
            pass

    response_start = next((frame for frame in frames if frame.get("type") == "response_start"), {})
    errors = [frame for frame in frames if frame.get("type") == "error"]
    return {
        "schema": SCHEMA,
        "generated_at": utc_timestamp(),
        "url": url,
        "status": "pass" if frames and frames[-1].get("type") == "response_end" and not errors else "fail",
        "elapsed_ms": round((time.perf_counter() - started) * 1000.0, 2),
        "frame_types": [str(frame.get("type", "")) for frame in frames],
        "text_frames": len(frames),
        "binary_frames": binary_frames,
        "binary_bytes": binary_bytes,
        "response_text": str(response_start.get("text", "")),
        "tts_voice": str(response_start.get("tts_voice", "")),
        "tts_audio_payload_bytes": int(response_start.get("tts_audio_payload_bytes", 0) or 0),
        "errors": errors,
        "frames": frames,
    }


def write_outputs(report: dict[str, object], out_dir: Path) -> None:
    out_dir.mkdir(parents=True, exist_ok=True)
    json_path = out_dir / "PC_BRAIN_PROBE.json"
    md_path = out_dir / "PC_BRAIN_PROBE.md"
    json_path.write_text(json.dumps(report, indent=2), encoding="utf-8")
    lines = [
        "# Stackchan PC Brain Probe",
        "",
        f"- Status: `{report['status']}`",
        f"- URL: `{report['url']}`",
        f"- Elapsed: `{report['elapsed_ms']} ms`",
        f"- Text frames: `{report['text_frames']}`",
        f"- Binary audio frames: `{report['binary_frames']}`",
        f"- Binary audio bytes: `{report['binary_bytes']}`",
        f"- TTS voice: `{report['tts_voice']}`",
        f"- TTS payload bytes: `{report['tts_audio_payload_bytes']}`",
        f"- Response text: `{report['response_text']}`",
    ]
    if report.get("errors"):
        lines.append(f"- Errors: `{len(report['errors'])}`")
    md_path.write_text("\n".join(lines) + "\n", encoding="utf-8")


def main() -> int:
    parser = argparse.ArgumentParser(description="Probe a running Stackchan PC brain WebSocket bridge.")
    parser.add_argument("--url", default="ws://127.0.0.1:8765/bridge")
    parser.add_argument("--text", default="Hello Stackchan. This computer is your brain now.")
    parser.add_argument("--timeout", type=float, default=130.0)
    parser.add_argument("--out-dir", type=Path, default=DEFAULT_OUT_DIR)
    parser.add_argument("--json", action="store_true")
    args = parser.parse_args()

    report = run_probe(args.url, args.text, args.timeout)
    write_outputs(report, args.out_dir)
    if args.json:
        print(json.dumps(report, indent=2))
    else:
        print(f"[pc-brain-probe] status={report['status']} url={report['url']} audio_bytes={report['binary_bytes']}")
    return 0 if report["status"] == "pass" else 1


if __name__ == "__main__":
    raise SystemExit(main())
