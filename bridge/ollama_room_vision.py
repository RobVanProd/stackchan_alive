#!/usr/bin/env python3
"""Convert a Stackchan PGM frame and request typed room context from local Ollama."""

from __future__ import annotations

import base64
import json
import os
import struct
import sys
import urllib.error
import urllib.parse
import urllib.request
import zlib


DEFAULT_OLLAMA_URL = "http://127.0.0.1:11434"
MAX_INPUT_BYTES = 32_768
SYSTEM_PROMPT = """\
Inspect this low-resolution grayscale room frame. Return JSON only with exactly these fields:
person_count: integer 0-4 or null when uncertain
activity: empty, person_seated, person_standing, people_present, or unknown
objects: zero to six values chosen only from chair, desk, door, lamp, monitor, plant, shelf, sofa, table, window
lighting: bright, dim, mixed, or unknown
Do not identify people. Do not describe faces, bodies, clothing, text, health, relationships,
demographics, valuables, addresses, or other private traits. Prefer unknown over guessing.
"""


class _RejectRedirects(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        return None


def _open_without_redirects(request: urllib.request.Request, *, timeout: float):
    return urllib.request.build_opener(_RejectRedirects()).open(request, timeout=timeout)


def validate_loopback_url(value: str) -> str:
    parsed = urllib.parse.urlparse(str(value).strip())
    if (
        parsed.scheme != "http"
        or parsed.hostname not in {"127.0.0.1", "::1", "localhost"}
        or parsed.username
        or parsed.password
        or parsed.path not in ("", "/")
        or parsed.query
        or parsed.fragment
    ):
        raise ValueError("Ollama room vision URL must be loopback-only HTTP")
    return str(value).rstrip("/")


def parse_pgm(frame: bytes) -> tuple[int, int, bytes]:
    if len(frame) > MAX_INPUT_BYTES or not frame.startswith(b"P5\n"):
        raise ValueError("invalid or oversized PGM frame")
    try:
        _, dimensions, maximum, pixels = frame.split(b"\n", 3)
        width_text, height_text = dimensions.split(b" ", 1)
        width = int(width_text)
        height = int(height_text)
        max_value = int(maximum)
    except (TypeError, ValueError) as exc:
        raise ValueError("malformed PGM frame") from exc
    if not 1 <= width <= 320 or not 1 <= height <= 240 or max_value != 255:
        raise ValueError("unsupported PGM frame")
    if len(pixels) != width * height:
        raise ValueError("PGM payload length mismatch")
    return width, height, pixels


def pgm_to_png(frame: bytes) -> bytes:
    width, height, pixels = parse_pgm(frame)

    def chunk(kind: bytes, payload: bytes) -> bytes:
        body = kind + payload
        return struct.pack(">I", len(payload)) + body + struct.pack(">I", zlib.crc32(body) & 0xFFFFFFFF)

    scanlines = b"".join(
        b"\x00" + pixels[row * width : (row + 1) * width] for row in range(height)
    )
    header = struct.pack(">IIBBBBB", width, height, 8, 0, 0, 0, 0)
    return (
        b"\x89PNG\r\n\x1a\n"
        + chunk(b"IHDR", header)
        + chunk(b"IDAT", zlib.compress(scanlines, level=6))
        + chunk(b"IEND", b"")
    )


def build_request_payload(frame: bytes, model: str) -> dict[str, object]:
    model_name = str(model).strip()
    if not model_name:
        raise ValueError("STACKCHAN_OLLAMA_VISION_MODEL is required")
    return {
        "model": model_name,
        "prompt": SYSTEM_PROMPT,
        "images": [base64.b64encode(pgm_to_png(frame)).decode("ascii")],
        "format": "json",
        "stream": False,
        "options": {"temperature": 0.1, "num_predict": 160},
    }


def query_ollama(frame: bytes, *, url: str, model: str, timeout_seconds: float = 30.0) -> dict[str, object]:
    endpoint = validate_loopback_url(url) + "/api/generate"
    request_payload = build_request_payload(frame, model)
    request = urllib.request.Request(
        endpoint,
        data=json.dumps(request_payload, separators=(",", ":")).encode("utf-8"),
        headers={"Content-Type": "application/json", "Accept": "application/json"},
        method="POST",
    )
    try:
        with _open_without_redirects(
            request,
            timeout=max(1.0, timeout_seconds),
        ) as response:
            payload = json.loads(response.read(256 * 1024).decode("utf-8"))
    except (OSError, urllib.error.URLError, UnicodeDecodeError, json.JSONDecodeError) as exc:
        raise RuntimeError(f"local Ollama vision request failed: {getattr(exc, 'reason', exc)}") from exc
    if not isinstance(payload, dict) or not isinstance(payload.get("response"), str):
        raise RuntimeError("local Ollama vision response was invalid")
    try:
        scene = json.loads(payload["response"])
    except json.JSONDecodeError as exc:
        raise RuntimeError("local Ollama vision model did not return JSON") from exc
    if not isinstance(scene, dict):
        raise RuntimeError("local Ollama vision model returned a non-object")
    return scene


def main() -> int:
    frame = sys.stdin.buffer.read(MAX_INPUT_BYTES + 1)
    try:
        scene = query_ollama(
            frame,
            url=os.environ.get("STACKCHAN_OLLAMA_URL", DEFAULT_OLLAMA_URL),
            model=os.environ.get("STACKCHAN_OLLAMA_VISION_MODEL", ""),
            timeout_seconds=float(os.environ.get("STACKCHAN_OLLAMA_VISION_TIMEOUT_SECONDS", "30")),
        )
    except (RuntimeError, ValueError) as exc:
        print(str(exc), file=sys.stderr)
        return 2
    print(json.dumps(scene, separators=(",", ":"), ensure_ascii=True))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
