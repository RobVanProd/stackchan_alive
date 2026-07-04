#!/usr/bin/env python3
"""Probe an Android Stackchan Companion bridge endpoint.

This is an arrival-day helper for the URL shown in the Android dashboard:
`ws://<phone-lan-ip>:8765/bridge`. It performs a real WebSocket upgrade,
reads the first server text frame, and verifies that the companion reports an
Android `endpoint_hello` for `stackchan.bridge.v1`.
"""

from __future__ import annotations

import argparse
import base64
import hashlib
import json
import socket
import sys
import time
from dataclasses import dataclass
from datetime import datetime, timezone
from pathlib import Path
from typing import Any
from urllib.parse import urlparse

SCHEMA = "stackchan.android-companion-probe.v1"
PROTOCOL = "stackchan.bridge.v1"
CLIENT_MASK = b"\x51\x7a\x21\x09"


class ProbeError(RuntimeError):
    """Raised when the Android bridge probe fails."""


@dataclass(frozen=True)
class BridgeUrl:
    url: str
    host: str
    port: int
    path: str


def utc_timestamp() -> str:
    return datetime.now(timezone.utc).replace(microsecond=0).isoformat().replace("+00:00", "Z")


def parse_bridge_url(value: str) -> BridgeUrl:
    parsed = urlparse(value.strip())
    if parsed.scheme != "ws":
        raise ProbeError("Android bridge URL must start with ws://")
    if not parsed.hostname:
        raise ProbeError("Android bridge URL must include a host")
    if parsed.username or parsed.password:
        raise ProbeError("Android bridge URL must not include credentials")
    path = parsed.path or "/bridge"
    if path != "/bridge":
        raise ProbeError("Android bridge URL path must be /bridge")
    port = parsed.port or 8765
    if port < 1 or port > 65535:
        raise ProbeError("Android bridge port must be 1..65535")
    return BridgeUrl(url=value.strip(), host=parsed.hostname, port=port, path=path)


def websocket_key(url: BridgeUrl) -> str:
    digest = hashlib.sha256(f"{url.host}:{url.port}{url.path}".encode("utf-8")).digest()
    return base64.b64encode(digest[:16]).decode("ascii")


def make_handshake(url: BridgeUrl) -> bytes:
    key = websocket_key(url)
    host = f"[{url.host}]" if ":" in url.host else url.host
    return (
        f"GET {url.path} HTTP/1.1\r\n"
        f"Host: {host}:{url.port}\r\n"
        "Upgrade: websocket\r\n"
        "Connection: Upgrade\r\n"
        f"Sec-WebSocket-Key: {key}\r\n"
        "Sec-WebSocket-Version: 13\r\n"
        "\r\n"
    ).encode("ascii")


def read_handshake_response(sock: socket.socket) -> tuple[str, bytes]:
    data = bytearray()
    while b"\r\n\r\n" not in data:
        chunk = sock.recv(4096)
        if not chunk:
            raise ProbeError("server closed before WebSocket handshake response")
        data.extend(chunk)
        if len(data) > 8192:
            raise ProbeError("WebSocket handshake response too large")
    header_end = data.index(b"\r\n\r\n") + 4
    response = bytes(data[:header_end]).decode("iso-8859-1", errors="replace")
    return response, bytes(data[header_end:])


def encode_close_frame() -> bytes:
    first = 0x80 | 0x8
    return bytes([first, 0x80]) + CLIENT_MASK


def read_ws_frame(sock: socket.socket, initial: bytes = b"", max_payload: int = 65536) -> tuple[int, bytes]:
    buffered = bytearray(initial)
    first = read_exact(sock, 1, buffered)
    if not first:
        raise ProbeError("server closed before sending a WebSocket frame")
    second = read_exact(sock, 1, buffered)
    if not second:
        raise ProbeError("server closed during WebSocket frame header")
    opcode = first[0] & 0x0F
    masked = (second[0] & 0x80) != 0
    length = second[0] & 0x7F
    if length == 126:
        length = int.from_bytes(read_exact(sock, 2, buffered), "big")
    elif length == 127:
        length = int.from_bytes(read_exact(sock, 8, buffered), "big")
    if length > max_payload:
        raise ProbeError("WebSocket frame payload too large")
    mask = read_exact(sock, 4, buffered) if masked else b""
    payload = read_exact(sock, length, buffered)
    if masked:
        payload = bytes(value ^ mask[index % 4] for index, value in enumerate(payload))
    return opcode, payload


def read_exact(sock: socket.socket, size: int, buffered: bytearray | None = None) -> bytes:
    data = bytearray()
    if buffered:
        take = min(size, len(buffered))
        data.extend(buffered[:take])
        del buffered[:take]
    while len(data) < size:
        chunk = sock.recv(size - len(data))
        if not chunk:
            raise ProbeError("server closed during WebSocket frame payload")
        data.extend(chunk)
    return bytes(data)


def connect_and_read_endpoint_hello(url: BridgeUrl, timeout: float) -> tuple[str, dict[str, Any], float]:
    started = time.perf_counter()
    with socket.create_connection((url.host, url.port), timeout=timeout) as sock:
        sock.settimeout(timeout)
        sock.sendall(make_handshake(url))
        response, buffered = read_handshake_response(sock)
        if "101 Switching Protocols" not in response:
            raise ProbeError("server did not accept WebSocket handshake")
        opcode, payload = read_ws_frame(sock, initial=buffered)
        elapsed_ms = (time.perf_counter() - started) * 1000.0
        if opcode != 0x1:
            raise ProbeError(f"expected endpoint_hello text frame, got opcode {opcode}")
        try:
            frame = json.loads(payload.decode("utf-8"))
        except (UnicodeDecodeError, json.JSONDecodeError) as exc:
            raise ProbeError(f"endpoint_hello frame is not valid JSON: {exc}") from exc
        try:
            sock.sendall(encode_close_frame())
        except OSError:
            pass
    return response, frame, elapsed_ms


def validate_endpoint_hello(frame: dict[str, Any], require_android: bool) -> list[str]:
    issues: list[str] = []
    if frame.get("type") != "endpoint_hello":
        issues.append(f"expected type endpoint_hello, got {frame.get('type')!r}")
    if frame.get("protocol") != PROTOCOL:
        issues.append(f"expected protocol {PROTOCOL}, got {frame.get('protocol')!r}")
    if require_android and frame.get("endpoint_kind") != "android":
        issues.append(f"expected endpoint_kind android, got {frame.get('endpoint_kind')!r}")
    if not str(frame.get("endpoint_id", "")).strip():
        issues.append("endpoint_id is missing")
    capabilities = frame.get("capabilities")
    if not isinstance(capabilities, list):
        issues.append("capabilities must be a list")
    else:
        for required in ("settings", "diagnostics"):
            if required not in capabilities:
                issues.append(f"capabilities missing {required!r}")
    return issues


def build_report(url_value: str, timeout: float, require_android: bool) -> dict[str, Any]:
    report: dict[str, Any] = {
        "schema": SCHEMA,
        "generated_at": utc_timestamp(),
        "url": url_value,
        "status": "fail",
        "issues": [],
    }
    try:
        url = parse_bridge_url(url_value)
        response, frame, elapsed_ms = connect_and_read_endpoint_hello(url, timeout)
        issues = validate_endpoint_hello(frame, require_android)
        report.update(
            {
                "host": url.host,
                "port": url.port,
                "path": url.path,
                "handshake_status": "accepted" if "101 Switching Protocols" in response else "rejected",
                "elapsed_ms": round(elapsed_ms, 2),
                "endpoint_hello": frame,
                "issues": issues,
                "status": "pass" if not issues else "fail",
            }
        )
    except Exception as exc:
        report["issues"] = [f"{type(exc).__name__}: {exc}"]
    return report


def write_outputs(report: dict[str, Any], out_dir: Path) -> tuple[Path, Path]:
    out_dir.mkdir(parents=True, exist_ok=True)
    json_path = out_dir / "android_companion_probe.json"
    md_path = out_dir / "ANDROID_COMPANION_PROBE.md"
    json_path.write_text(json.dumps(report, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    lines = [
        "# Android Companion Probe",
        "",
        f"- Status: `{report['status']}`",
        f"- URL: `{report.get('url', '')}`",
        f"- Generated: `{report['generated_at']}`",
    ]
    if "elapsed_ms" in report:
        lines.append(f"- Elapsed: `{report['elapsed_ms']} ms`")
    endpoint_hello = report.get("endpoint_hello")
    if isinstance(endpoint_hello, dict):
        lines.extend(
            [
                f"- Endpoint ID: `{endpoint_hello.get('endpoint_id', '')}`",
                f"- Endpoint kind: `{endpoint_hello.get('endpoint_kind', '')}`",
                f"- Protocol: `{endpoint_hello.get('protocol', '')}`",
                f"- Capabilities: `{', '.join(endpoint_hello.get('capabilities', []))}`",
            ]
        )
    issues = report.get("issues", [])
    lines.append("")
    lines.append("## Issues")
    if issues:
        lines.extend(f"- {issue}" for issue in issues)
    else:
        lines.append("- None")
    lines.append("")
    md_path.write_text("\n".join(lines), encoding="utf-8")
    return json_path, md_path


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description="Probe an Android Stackchan Companion bridge URL.")
    parser.add_argument("url", help="Android dashboard URL, for example ws://192.168.1.42:8765/bridge")
    parser.add_argument("--timeout", type=float, default=5.0, help="Socket timeout in seconds.")
    parser.add_argument("--out-dir", default="output/android-companion-probe/latest", help="Report output directory.")
    parser.add_argument("--json", action="store_true", help="Print the JSON report to stdout.")
    parser.add_argument("--allow-non-android", action="store_true", help="Do not require endpoint_kind=android.")
    args = parser.parse_args(argv)

    report = build_report(args.url, timeout=args.timeout, require_android=not args.allow_non_android)
    json_path, md_path = write_outputs(report, Path(args.out_dir))
    if args.json:
        print(json.dumps(report, indent=2, sort_keys=True))
    else:
        print(f"Android companion probe report: {json_path}")
        print(f"Android companion probe summary: {md_path}")
        print(f"Status: {report['status']}")
    return 0 if report["status"] == "pass" else 1


if __name__ == "__main__":
    raise SystemExit(main())
