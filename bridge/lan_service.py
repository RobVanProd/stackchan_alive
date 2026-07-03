#!/usr/bin/env python3
"""Minimal LAN WebSocket bridge service for stackchan.bridge.v1."""

from __future__ import annotations

import argparse
import base64
import hashlib
import json
import socket
from dataclasses import dataclass
from pathlib import Path
from typing import Any

from local_runner import RUNNER_PROFILES, RunnerConfigurationError, RunnerExecutionError, run_runner_profile
from reference_bridge import (
    PROTOCOL,
    BridgeMemory,
    bridge_frames,
    load_bridge_memory,
    save_bridge_memory,
    turn_from_character_response,
)

WEBSOCKET_GUID = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"
MAX_TEXT_BYTES = 65535


class WebSocketProtocolError(RuntimeError):
    """Raised when a client sends an invalid WebSocket handshake or frame."""


@dataclass(frozen=True)
class LanBridgeConfig:
    host: str = "127.0.0.1"
    port: int = 8765
    runner_profile: str = "gemma4-e2b-gguf"
    runner_case: str = "greeting"
    runner_command: str = ""
    require_runner: bool = False
    runner_timeout_ms: int = 60000
    memory_file: Path | None = None
    once: bool = False


def websocket_accept_value(client_key: str) -> str:
    digest = hashlib.sha1((client_key.strip() + WEBSOCKET_GUID).encode("ascii")).digest()
    return base64.b64encode(digest).decode("ascii")


def parse_http_headers(request: bytes) -> dict[str, str]:
    text = request.decode("iso-8859-1")
    lines = text.split("\r\n")
    if not lines or not lines[0].startswith("GET "):
        raise WebSocketProtocolError("websocket handshake must start with GET")
    headers: dict[str, str] = {}
    for line in lines[1:]:
        if not line or ":" not in line:
            continue
        key, value = line.split(":", 1)
        headers[key.strip().lower()] = value.strip()
    return headers


def build_handshake_response(request: bytes) -> bytes:
    headers = parse_http_headers(request)
    upgrade = headers.get("upgrade", "").lower()
    connection = headers.get("connection", "").lower()
    client_key = headers.get("sec-websocket-key", "")
    if upgrade != "websocket" or "upgrade" not in connection or not client_key:
        raise WebSocketProtocolError("missing WebSocket upgrade headers")
    accept = websocket_accept_value(client_key)
    response = (
        "HTTP/1.1 101 Switching Protocols\r\n"
        "Upgrade: websocket\r\n"
        "Connection: Upgrade\r\n"
        f"Sec-WebSocket-Accept: {accept}\r\n"
        "\r\n"
    )
    return response.encode("ascii")


def recv_exact(conn: socket.socket, count: int) -> bytes:
    chunks: list[bytes] = []
    remaining = count
    while remaining > 0:
        chunk = conn.recv(remaining)
        if not chunk:
            raise WebSocketProtocolError("unexpected websocket disconnect")
        chunks.append(chunk)
        remaining -= len(chunk)
    return b"".join(chunks)


def encode_ws_frame(payload: bytes, opcode: int = 0x1) -> bytes:
    if len(payload) > MAX_TEXT_BYTES:
        raise WebSocketProtocolError("websocket payload too large")
    first = 0x80 | (opcode & 0x0F)
    if len(payload) < 126:
        header = bytes([first, len(payload)])
    else:
        header = bytes([first, 126]) + len(payload).to_bytes(2, "big")
    return header + payload


def encode_ws_text(message: str) -> bytes:
    return encode_ws_frame(message.encode("utf-8"), opcode=0x1)


def encode_ws_close() -> bytes:
    return encode_ws_frame(b"", opcode=0x8)


def read_ws_frame(conn: socket.socket) -> tuple[int, bytes]:
    header = recv_exact(conn, 2)
    first, second = header[0], header[1]
    opcode = first & 0x0F
    masked = bool(second & 0x80)
    length = second & 0x7F
    if length == 126:
        length = int.from_bytes(recv_exact(conn, 2), "big")
    elif length == 127:
        raise WebSocketProtocolError("large websocket frames are not supported")
    if length > MAX_TEXT_BYTES:
        raise WebSocketProtocolError("websocket payload too large")
    mask = recv_exact(conn, 4) if masked else b""
    payload = recv_exact(conn, length)
    if masked:
        payload = bytes(value ^ mask[index % 4] for index, value in enumerate(payload))
    return opcode, payload


def frame_to_text(frame: dict[str, object]) -> str:
    return json.dumps(frame, separators=(",", ":"), ensure_ascii=True)


def error_frame(code: str, detail: str = "") -> dict[str, object]:
    frame: dict[str, object] = {"type": "error", "code": code}
    if detail:
        frame["detail"] = detail[:160]
    return frame


def prompt_case_for_text(text: str, requested: str, default_case: str) -> str:
    if requested:
        return requested
    lowered = text.lower()
    if "forget" in lowered:
        return "forget"
    if "picked" in lowered or "pick" in lowered:
        return "picked_up"
    if "battery" in lowered or "power" in lowered:
        return "low_battery"
    if "?" in text or "confused" in lowered:
        return "confused"
    return default_case


class LanBridgeSession:
    def __init__(self, config: LanBridgeConfig, memory: BridgeMemory | None = None):
        self.config = config
        self.memory = memory if memory is not None else BridgeMemory()
        self.session = "lan"
        self.next_seq = 1

    def _save_memory(self) -> None:
        if self.config.memory_file:
            save_bridge_memory(self.config.memory_file, self.memory)

    def handle_text(self, text: str) -> list[dict[str, object]]:
        try:
            message = json.loads(text)
        except json.JSONDecodeError:
            return [error_frame("malformed_json")]
        if not isinstance(message, dict):
            return [error_frame("message_not_object")]

        message_type = str(message.get("type", "")).strip().lower()
        if message_type == "hello":
            self.session = str(message.get("session") or message.get("device_id") or self.session)[:48]
            return [{"type": "hello", "protocol": PROTOCOL, "session": self.session}]
        if message_type == "heartbeat":
            return [{"type": "heartbeat"}]
        if message_type == "utterance_start":
            return [{"type": "listening"}]
        if message_type == "cancel":
            return [error_frame("cancelled")]
        if message_type == "utterance_audio":
            return [error_frame("binary_audio_not_implemented", "text-only P7 LAN scaffold")]
        if message_type == "utterance_end":
            return self._handle_utterance_end(message)
        return [error_frame("unsupported_message", message_type)]

    def handle_binary(self, payload: bytes) -> list[dict[str, object]]:
        return [error_frame("binary_audio_not_implemented", f"{len(payload)} bytes ignored")]

    def _handle_utterance_end(self, message: dict[str, Any]) -> list[dict[str, object]]:
        seq = int(message.get("seq") or self.next_seq)
        self.next_seq = max(self.next_seq, seq + 1)
        user_text = " ".join(str(message.get("text", "")).split())
        if user_text:
            self.memory = self.memory.remember_user_text(user_text)

        requested_case = str(message.get("runner_case", "")).strip()
        runner_case = prompt_case_for_text(user_text, requested_case, self.config.runner_case)
        try:
            runner = run_runner_profile(
                self.config.runner_profile,
                case_name=runner_case,
                command=self.config.runner_command,
                require_runner=self.config.require_runner,
                timeout_ms=self.config.runner_timeout_ms,
            )
        except (RunnerConfigurationError, RunnerExecutionError, ValueError) as exc:
            return [error_frame("runner_error", str(exc))]

        turn, self.memory, validation = turn_from_character_response(
            runner.raw_response,
            self.memory,
            session=self.session,
            seq=seq,
        )
        self._save_memory()
        frames = [frame for frame in bridge_frames(turn) if frame.get("type") not in ("hello", "listening")]
        if validation.issues:
            frames.insert(0, error_frame("character_validation", ",".join(validation.issues)))
        return frames


def read_http_request(conn: socket.socket) -> bytes:
    data = bytearray()
    while b"\r\n\r\n" not in data:
        chunk = conn.recv(4096)
        if not chunk:
            raise WebSocketProtocolError("client closed before websocket handshake")
        data.extend(chunk)
        if len(data) > 8192:
            raise WebSocketProtocolError("websocket handshake too large")
    return bytes(data)


def handle_connection(conn: socket.socket, config: LanBridgeConfig, memory: BridgeMemory) -> BridgeMemory:
    session = LanBridgeSession(config, memory)
    request = read_http_request(conn)
    conn.sendall(build_handshake_response(request))
    while True:
        opcode, payload = read_ws_frame(conn)
        if opcode == 0x8:
            conn.sendall(encode_ws_close())
            break
        if opcode == 0x9:
            conn.sendall(encode_ws_frame(payload, opcode=0xA))
            continue
        if opcode == 0x1:
            frames = session.handle_text(payload.decode("utf-8"))
        elif opcode == 0x2:
            frames = session.handle_binary(payload)
        else:
            frames = [error_frame("unsupported_websocket_opcode", str(opcode))]
        for frame in frames:
            conn.sendall(encode_ws_text(frame_to_text(frame)))
    return session.memory


def serve(config: LanBridgeConfig) -> None:
    memory = load_bridge_memory(config.memory_file) if config.memory_file else BridgeMemory()
    with socket.create_server((config.host, config.port), reuse_port=False) as server:
        server.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        print(f"[bridge-lan] listening ws://{config.host}:{config.port} protocol={PROTOCOL}")
        while True:
            conn, address = server.accept()
            print(f"[bridge-lan] client={address[0]}:{address[1]}")
            with conn:
                memory = handle_connection(conn, config, memory)
            if config.once:
                break


def build_arg_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description="Run the local Stackchan P7 LAN WebSocket bridge.")
    parser.add_argument("--host", default="127.0.0.1")
    parser.add_argument("--port", type=int, default=8765)
    parser.add_argument("--once", action="store_true", help="Handle one client and exit.")
    parser.add_argument("--runner-profile", choices=sorted(RUNNER_PROFILES), default="gemma4-e2b-gguf")
    parser.add_argument("--runner-case", default="greeting")
    parser.add_argument("--runner-command", default="")
    parser.add_argument("--require-runner", action="store_true")
    parser.add_argument("--runner-timeout-ms", type=int, default=60000)
    parser.add_argument("--memory-file", type=Path)
    parser.add_argument("--reset-memory", action="store_true")
    return parser


def main() -> int:
    args = build_arg_parser().parse_args()
    if args.reset_memory and args.memory_file and args.memory_file.exists():
        args.memory_file.unlink()
    config = LanBridgeConfig(
        host=args.host,
        port=args.port,
        once=args.once,
        runner_profile=args.runner_profile,
        runner_case=args.runner_case,
        runner_command=args.runner_command,
        require_runner=args.require_runner,
        runner_timeout_ms=args.runner_timeout_ms,
        memory_file=args.memory_file,
    )
    serve(config)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
