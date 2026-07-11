#!/usr/bin/env python3
"""Measure DirectML phrase streaming through the real paced WebSocket bridge."""

from __future__ import annotations

import argparse
import json
import os
import sys
import tempfile
import time
from pathlib import Path
from typing import Any

from lan_service import LanBridgeConfig
from lan_smoke import SmokeClient, SmokeServer


DEFAULT_TEXT = "I am Stackchan. My systems are online, and I am ready to talk with you."


def write_runner(path: Path, response_text: str) -> str:
    response = {
        "spoken_text": response_text,
        "mode": "speak",
        "earcon": "none",
        "emotion": {"arousal": 0.1, "valence": 0.25},
        "memory_write": {},
        "memory_forget": [],
    }
    path.write_text(
        "\n".join(
            (
                "import json",
                "import sys",
                "sys.stdin.buffer.read()",
                f"print(json.dumps({response!r}, separators=(',', ':'))) ",
            )
        ),
        encoding="utf-8",
    )
    return f'"{sys.executable}" "{path}"'


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output-dir", type=Path, required=True)
    parser.add_argument("--text", default=DEFAULT_TEXT)
    parser.add_argument("--tts-command", default="")
    parser.add_argument("--chunk-bytes", type=int, default=4096)
    parser.add_argument("--binary-delay-ms", type=int, default=80)
    parser.add_argument("--text-delay-ms", type=int, default=40)
    parser.add_argument("--phrase-max-chars", type=int, default=96)
    parser.add_argument("--max-first-audio-seconds", type=float, default=3.0)
    parser.add_argument("--max-wire-realtime-factor", type=float, default=1.0)
    parser.add_argument("--json", action="store_true")
    return parser


def run(args: argparse.Namespace) -> dict[str, object]:
    output_dir = args.output_dir.expanduser().resolve()
    output_dir.mkdir(parents=True, exist_ok=True)
    tts_command = args.tts_command.strip() or (
        f'"{sys.executable}" "{Path(__file__).with_name("rvc_directml_tts_client.py")}"'
    )
    with tempfile.TemporaryDirectory(prefix="stackchan_voice_v2_wire_") as temp_dir:
        runner_command = write_runner(Path(temp_dir) / "fixed_runner.py", args.text)
        config = LanBridgeConfig(
            host="127.0.0.1",
            runner_command=runner_command,
            require_runner=True,
            tts_command=tts_command,
            tts_voice="stackchan-rvc-directml-v2",
            stream_tts_phrases=True,
            tts_phrase_max_chars=args.phrase_max_chars,
            downlink_audio_chunk_bytes=args.chunk_bytes,
            downlink_binary_frame_delay_ms=args.binary_delay_ms,
            downlink_text_frame_delay_ms=args.text_delay_ms,
            client_idle_timeout_s=30.0,
        )
        text_frames: list[dict[str, Any]] = []
        binary_chunks: list[bytes] = []
        frame_timings: list[dict[str, object]] = []
        first_binary_ms = 0.0
        stream_end_ms = 0.0
        response_end_ms = 0.0
        server_errors: list[str] = []
        with SmokeServer(config) as server:
            with SmokeClient("127.0.0.1", server.port()) as client:
                hello = client.read()
                if not hello.is_text or hello.text_payload().get("type") != "hello":
                    raise RuntimeError("bridge did not send its session hello")
                client.send_text({"type": "utterance_start", "seq": 41, "sample_rate": 16000})
                listening = client.read()
                if not listening.is_text or listening.text_payload().get("type") != "listening":
                    raise RuntimeError("bridge did not accept utterance_start")
                client.started = time.perf_counter()
                client.send_text({"type": "utterance_end", "seq": 41, "text": "Give me a status update."})
                for _ in range(512):
                    received = client.read()
                    elapsed_ms = received.elapsed_ms
                    if received.is_binary:
                        if first_binary_ms == 0.0:
                            first_binary_ms = elapsed_ms
                        binary_chunks.append(received.payload)
                        frame_timings.append(
                            {"type": "binary", "elapsed_ms": round(elapsed_ms, 2), "bytes": len(received.payload)}
                        )
                        continue
                    if not received.is_text:
                        raise RuntimeError(f"unexpected WebSocket opcode {received.opcode}")
                    frame = received.text_payload()
                    text_frames.append(frame)
                    frame_type = str(frame.get("type", ""))
                    frame_timings.append({"type": frame_type, "elapsed_ms": round(elapsed_ms, 2)})
                    if frame_type == "audio_stream_end":
                        stream_end_ms = elapsed_ms
                    if frame_type == "response_end":
                        response_end_ms = elapsed_ms
                        break
                else:
                    raise RuntimeError("bridge did not finish within 512 frames")
            server_errors.extend(server.errors)

    stream_start = next((frame for frame in text_frames if frame.get("type") == "audio_stream_start"), {})
    stream_end = next((frame for frame in text_frames if frame.get("type") == "audio_stream_end"), {})
    errors = [frame for frame in text_frames if frame.get("type") == "error"]
    audio_bytes = sum(len(chunk) for chunk in binary_chunks)
    audio_chunks = len(binary_chunks)
    sample_rate = int(stream_start.get("sample_rate", 0) or 0)
    audio_seconds = audio_bytes / float(max(1, sample_rate) * 2)
    wire_rtf = (stream_end_ms / 1000.0) / max(audio_seconds, 0.001)
    checks = {
        "server_clean": not server_errors,
        "protocol_clean": not errors,
        "unknown_start_totals": int(stream_start.get("audio_bytes", -1)) == 0
        and int(stream_start.get("chunks", -1)) == 0,
        "exact_end_bytes": int(stream_end.get("audio_bytes", -1)) == audio_bytes,
        "exact_end_chunks": int(stream_end.get("chunks", -1)) == audio_chunks,
        "first_audio_under_gate": 0.0 < first_binary_ms <= args.max_first_audio_seconds * 1000.0,
        "wire_faster_than_realtime": wire_rtf <= args.max_wire_realtime_factor,
        "response_completed": response_end_ms >= stream_end_ms > 0.0,
    }
    report: dict[str, object] = {
        "schema": "stackchan.voice-v2-wire-benchmark.v1",
        "status": "pass" if all(checks.values()) else "fail",
        "response_text": args.text,
        "tts_command": tts_command,
        "chunk_bytes": args.chunk_bytes,
        "binary_delay_ms": args.binary_delay_ms,
        "text_delay_ms": args.text_delay_ms,
        "audio_bytes": audio_bytes,
        "audio_chunks": audio_chunks,
        "sample_rate": sample_rate,
        "audio_seconds": round(audio_seconds, 4),
        "first_binary_ms": round(first_binary_ms, 2),
        "stream_end_ms": round(stream_end_ms, 2),
        "response_end_ms": round(response_end_ms, 2),
        "wire_realtime_factor": round(wire_rtf, 4),
        "stream_start": stream_start,
        "stream_end": stream_end,
        "errors": errors,
        "server_errors": server_errors,
        "checks": checks,
        "frame_timings": frame_timings,
    }
    (output_dir / "wire-benchmark.json").write_text(
        json.dumps(report, indent=2, sort_keys=True) + "\n", encoding="utf-8"
    )
    return report


def main() -> int:
    args = build_parser().parse_args()
    report = run(args)
    if args.json:
        print(json.dumps(report, separators=(",", ":"), ensure_ascii=True))
    else:
        print(
            f"status={report['status']} first_binary_ms={report['first_binary_ms']} "
            f"stream_end_ms={report['stream_end_ms']} wire_rtf={report['wire_realtime_factor']}"
        )
    return 0 if report["status"] == "pass" else 3


if __name__ == "__main__":
    raise SystemExit(main())
