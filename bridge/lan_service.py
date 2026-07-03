#!/usr/bin/env python3
"""Minimal LAN WebSocket bridge service for stackchan.bridge.v1."""

from __future__ import annotations

import argparse
import base64
import hashlib
import json
import socket
from dataclasses import dataclass, field, replace
from pathlib import Path
from typing import Any

from local_runner import RUNNER_PROFILES, RunnerConfigurationError, RunnerExecutionError, run_runner_profile
from reference_bridge import (
    AudioBeat,
    PROTOCOL,
    BridgeMemory,
    bridge_frames,
    load_bridge_memory,
    save_bridge_memory,
    turn_from_character_response,
)
from stt_adapter import DEFAULT_STT_TIMEOUT_MS, SttConfigurationError, SttExecutionError, transcribe_pcm
from tts_adapter import DEFAULT_TTS_TIMEOUT_MS, DEFAULT_TTS_VOICE, TtsConfigurationError, TtsExecutionError, synthesize_speech

WEBSOCKET_GUID = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"
MAX_TEXT_BYTES = 65535
DEFAULT_SAMPLE_RATE = 16000
DEFAULT_MAX_AUDIO_BYTES = 512 * 1024
DEFAULT_DOWNLINK_AUDIO_CHUNK_BYTES = 4096
MAX_DOWNLINK_AUDIO_CHUNK_BYTES = 4096


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
    stt_command: str = ""
    stt_timeout_ms: int = DEFAULT_STT_TIMEOUT_MS
    tts_command: str = ""
    tts_voice: str = DEFAULT_TTS_VOICE
    tts_timeout_ms: int = DEFAULT_TTS_TIMEOUT_MS
    downlink_audio_chunk_bytes: int = DEFAULT_DOWNLINK_AUDIO_CHUNK_BYTES
    max_audio_bytes: int = DEFAULT_MAX_AUDIO_BYTES
    memory_file: Path | None = None
    once: bool = False


@dataclass
class AudioUpload:
    sample_rate: int = DEFAULT_SAMPLE_RATE
    active: bool = False
    bytes_received: int = 0
    chunks: int = 0
    truncated: bool = False
    buffer: bytearray = field(default_factory=bytearray)

    def start(self, sample_rate: object = DEFAULT_SAMPLE_RATE) -> None:
        self.clear()
        try:
            parsed_rate = int(sample_rate)
        except (TypeError, ValueError):
            parsed_rate = DEFAULT_SAMPLE_RATE
        self.sample_rate = max(8000, min(48000, parsed_rate))
        self.active = True

    def clear(self) -> None:
        self.active = False
        self.bytes_received = 0
        self.chunks = 0
        self.truncated = False
        self.buffer.clear()

    def append(self, payload: bytes, max_bytes: int) -> None:
        if not self.active:
            raise WebSocketProtocolError("audio received before utterance_start")
        self.chunks += 1
        allowed = max(0, int(max_bytes) - self.bytes_received)
        self.bytes_received += len(payload)
        if len(payload) > allowed:
            self.truncated = True
        if allowed > 0:
            self.buffer.extend(payload[:allowed])

    @property
    def stored_bytes(self) -> int:
        return len(self.buffer)

    @property
    def duration_ms(self) -> int:
        if self.sample_rate <= 0:
            return 0
        return int((self.bytes_received / 2) / self.sample_rate * 1000)

    def summary(self) -> dict[str, object]:
        return {
            "audio_bytes": self.bytes_received,
            "audio_stored_bytes": self.stored_bytes,
            "audio_chunks": self.chunks,
            "audio_sample_rate": self.sample_rate,
            "audio_duration_ms": self.duration_ms,
            "audio_truncated": self.truncated,
        }

    def finish_and_clear(self) -> dict[str, object]:
        summary = self.summary()
        self.clear()
        return summary


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


def audio_downlink_frames(seq: int, tts, chunk_bytes: int) -> list[dict[str, object] | bytes]:
    audio = getattr(tts, "audio_data", b"")
    if not audio:
        return []
    safe_chunk_bytes = max(1, min(MAX_DOWNLINK_AUDIO_CHUNK_BYTES, int(chunk_bytes or DEFAULT_DOWNLINK_AUDIO_CHUNK_BYTES)))
    chunks = [audio[index : index + safe_chunk_bytes] for index in range(0, len(audio), safe_chunk_bytes)]
    frames: list[dict[str, object] | bytes] = [
        {
            "type": "audio_stream_start",
            "seq": seq,
            "format": tts.audio_format or "binary",
            "sample_rate": tts.sample_rate,
            "audio_bytes": len(audio),
            "chunk_bytes": safe_chunk_bytes,
            "chunks": len(chunks),
        }
    ]
    frames.extend(chunks)
    frames.append({"type": "audio_stream_end", "seq": seq, "audio_bytes": len(audio), "chunks": len(chunks)})
    return frames


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
        self.audio = AudioUpload()

    def _save_memory(self) -> None:
        if self.config.memory_file:
            save_bridge_memory(self.config.memory_file, self.memory)

    def handle_text(self, text: str, *, suppress_thinking: bool = False) -> list[dict[str, object] | bytes]:
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
            self.audio.start(message.get("sample_rate", DEFAULT_SAMPLE_RATE))
            return [{"type": "listening", **self.audio.summary()}]
        if message_type == "cancel":
            self.audio.clear()
            return [error_frame("cancelled")]
        if message_type == "utterance_audio":
            return self._handle_text_audio(message)
        if message_type == "utterance_end":
            return self._handle_utterance_end(message, suppress_thinking=suppress_thinking)
        return [error_frame("unsupported_message", message_type)]

    def early_thinking_frame(self, text: str) -> dict[str, object] | None:
        try:
            message = json.loads(text)
        except json.JSONDecodeError:
            return None
        if not isinstance(message, dict):
            return None
        if str(message.get("type", "")).strip().lower() != "utterance_end":
            return None
        try:
            seq = int(message.get("seq") or self.next_seq)
        except (TypeError, ValueError):
            seq = self.next_seq
        frame: dict[str, object] = {"type": "thinking", "seq": seq}
        if self.audio.bytes_received > 0 or self.audio.active:
            frame.update(self.audio.summary())
        return frame

    def handle_binary(self, payload: bytes) -> list[dict[str, object]]:
        try:
            self.audio.append(payload, self.config.max_audio_bytes)
        except WebSocketProtocolError as exc:
            return [error_frame("audio_without_utterance", str(exc))]
        return [{"type": "heartbeat", **self.audio.summary()}]

    def _handle_text_audio(self, message: dict[str, Any]) -> list[dict[str, object]]:
        encoded = str(message.get("pcm_b64") or message.get("audio_b64") or "").strip()
        if not encoded:
            return [error_frame("audio_payload_missing", "send binary WebSocket PCM or pcm_b64")]
        try:
            payload = base64.b64decode(encoded, validate=True)
        except (ValueError, base64.binascii.Error):
            return [error_frame("audio_payload_invalid", "pcm_b64 is not valid base64")]
        return self.handle_binary(payload)

    def _handle_utterance_end(
        self, message: dict[str, Any], *, suppress_thinking: bool = False
    ) -> list[dict[str, object] | bytes]:
        seq = int(message.get("seq") or self.next_seq)
        self.next_seq = max(self.next_seq, seq + 1)
        user_text = " ".join(str(message.get("text") or message.get("transcript") or "").split())
        pcm = bytes(self.audio.buffer)
        audio_summary = self.audio.finish_and_clear()
        has_audio = int(audio_summary["audio_bytes"]) > 0
        if has_audio and not user_text:
            try:
                stt = transcribe_pcm(
                    pcm,
                    int(audio_summary["audio_sample_rate"]),
                    command=self.config.stt_command,
                    timeout_ms=self.config.stt_timeout_ms,
                )
            except SttConfigurationError:
                return [
                    error_frame(
                        "stt_not_implemented",
                        f"received {audio_summary['audio_bytes']} PCM bytes; configure STT or provide transcript",
                    )
                    | audio_summary
                ]
            except (SttExecutionError, ValueError) as exc:
                return [error_frame("stt_error", str(exc)) | audio_summary]
            user_text = stt.transcript
            audio_summary["stt_elapsed_ms"] = round(stt.elapsed_ms, 2)
            audio_summary["stt_command_source"] = stt.command_source
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
        tts_summary: dict[str, object] = {}
        downlink_frames: list[dict[str, object] | bytes] = []
        tts_error = ""
        try:
            tts = synthesize_speech(
                turn.text,
                command=self.config.tts_command,
                voice=self.config.tts_voice,
                timeout_ms=self.config.tts_timeout_ms,
            )
            turn = replace(
                turn,
                beats=tuple(
                    AudioBeat(beat.env, beat.viseme, beat.duration_ms, beat.final) for beat in tts.beats
                ),
            )
            tts_summary = {
                "tts_elapsed_ms": round(tts.elapsed_ms, 2),
                "tts_command_source": tts.command_source,
                "tts_voice": tts.voice,
                "tts_beats": len(tts.beats),
                "tts_duration_ms": tts.duration_ms,
            }
            if tts.audio_format:
                tts_summary["tts_audio_format"] = tts.audio_format
            if tts.sample_rate:
                tts_summary["tts_sample_rate"] = tts.sample_rate
            if tts.audio_bytes:
                tts_summary["tts_audio_bytes"] = tts.audio_bytes
            if tts.audio_data:
                tts_summary["tts_audio_payload_bytes"] = len(tts.audio_data)
                downlink_frames = audio_downlink_frames(seq, tts, self.config.downlink_audio_chunk_bytes)
        except TtsConfigurationError:
            pass
        except (TtsExecutionError, ValueError) as exc:
            tts_error = str(exc)
        self._save_memory()
        frames = [frame for frame in bridge_frames(turn) if frame.get("type") not in ("hello", "listening")]
        if suppress_thinking:
            frames = [frame for frame in frames if frame.get("type") != "thinking"]
        if has_audio:
            audio_frame_type = "response_start" if suppress_thinking else "thinking"
            for frame in frames:
                if frame.get("type") == audio_frame_type:
                    frame.update(audio_summary)
                    break
        if tts_summary:
            for frame in frames:
                if frame.get("type") == "response_start":
                    frame.update(tts_summary)
                    if downlink_frames:
                        index = frames.index(frame)
                        frames[index + 1:index + 1] = downlink_frames
                    break
        prefix_errors: list[dict[str, object]] = []
        if validation.issues:
            prefix_errors.append(error_frame("character_validation", ",".join(validation.issues)))
        if tts_error:
            prefix_errors.append(error_frame("tts_error", tts_error))
        return prefix_errors + frames


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
            text = payload.decode("utf-8")
            early_frame = session.early_thinking_frame(text)
            if early_frame is not None:
                conn.sendall(encode_ws_text(frame_to_text(early_frame)))
            frames = session.handle_text(text, suppress_thinking=early_frame is not None)
        elif opcode == 0x2:
            frames = session.handle_binary(payload)
        else:
            frames = [error_frame("unsupported_websocket_opcode", str(opcode))]
        for frame in frames:
            if isinstance(frame, bytes):
                conn.sendall(encode_ws_frame(frame, opcode=0x2))
            else:
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
    parser.add_argument("--stt-command", default="")
    parser.add_argument("--stt-timeout-ms", type=int, default=DEFAULT_STT_TIMEOUT_MS)
    parser.add_argument("--tts-command", default="")
    parser.add_argument("--tts-voice", default=DEFAULT_TTS_VOICE)
    parser.add_argument("--tts-timeout-ms", type=int, default=DEFAULT_TTS_TIMEOUT_MS)
    parser.add_argument("--downlink-audio-chunk-bytes", type=int, default=DEFAULT_DOWNLINK_AUDIO_CHUNK_BYTES)
    parser.add_argument("--max-audio-bytes", type=int, default=DEFAULT_MAX_AUDIO_BYTES)
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
        stt_command=args.stt_command,
        stt_timeout_ms=args.stt_timeout_ms,
        tts_command=args.tts_command,
        tts_voice=args.tts_voice,
        tts_timeout_ms=args.tts_timeout_ms,
        downlink_audio_chunk_bytes=args.downlink_audio_chunk_bytes,
        max_audio_bytes=args.max_audio_bytes,
        memory_file=args.memory_file,
    )
    serve(config)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
