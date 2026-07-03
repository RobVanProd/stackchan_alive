#!/usr/bin/env python3
"""Local TTS command adapter for Stackchan bridge mouth timing."""

from __future__ import annotations

import argparse
import base64
import binascii
import json
import os
import subprocess
import time
from dataclasses import dataclass
from pathlib import Path
from typing import Any

DEFAULT_TTS_TIMEOUT_MS = 45000
DEFAULT_TTS_VOICE = "stackchan-rvc-bright-robot"
TTS_COMMAND_ENV = "STACKCHAN_TTS_COMMAND"
VALID_VISEMES = {"neutral", "ah", "oh", "ee"}
MAX_TTS_BEATS = 800
MAX_TTS_AUDIO_BYTES = 2 * 1024 * 1024


class TtsConfigurationError(RuntimeError):
    """Raised when TTS is requested but no command is configured."""


class TtsExecutionError(RuntimeError):
    """Raised when the configured TTS command fails or returns invalid metadata."""


@dataclass(frozen=True)
class TtsBeat:
    env: float
    viseme: str = "neutral"
    duration_ms: int = 20
    final: bool = False

    def to_dict(self) -> dict[str, object]:
        return {
            "env": round(self.env, 3),
            "viseme": self.viseme,
            "duration_ms": self.duration_ms,
            "final": self.final,
        }


@dataclass(frozen=True)
class TtsResult:
    beats: tuple[TtsBeat, ...]
    elapsed_ms: float
    command_source: str
    text_bytes: int
    voice: str
    audio_format: str = ""
    sample_rate: int = 0
    audio_bytes: int = 0
    audio_path: str = ""
    audio_data: bytes = b""

    @property
    def duration_ms(self) -> int:
        return sum(beat.duration_ms for beat in self.beats)

    def to_dict(self) -> dict[str, object]:
        return {
            "beats": [beat.to_dict() for beat in self.beats],
            "elapsed_ms": round(self.elapsed_ms, 2),
            "command_source": self.command_source,
            "text_bytes": self.text_bytes,
            "voice": self.voice,
            "audio_format": self.audio_format,
            "sample_rate": self.sample_rate,
            "audio_bytes": self.audio_bytes,
            "audio_path": self.audio_path,
            "audio_payload_bytes": len(self.audio_data),
            "duration_ms": self.duration_ms,
        }


def resolve_tts_command(override: str = "") -> tuple[str | None, str]:
    if override.strip():
        return override.strip(), "cli"
    if os.environ.get(TTS_COMMAND_ENV, "").strip():
        return os.environ[TTS_COMMAND_ENV].strip(), f"env:{TTS_COMMAND_ENV}"
    return None, "unconfigured"


def clamp(value: object, low: float, high: float, fallback: float = 0.0) -> float:
    try:
        parsed = float(value)
    except (TypeError, ValueError):
        parsed = fallback
    return max(low, min(high, parsed))


def clean_viseme(value: object) -> str:
    viseme = str(value or "neutral").strip().lower()
    return viseme if viseme in VALID_VISEMES else "neutral"


def clean_duration(value: object, fallback: int) -> int:
    try:
        parsed = int(float(value))
    except (TypeError, ValueError):
        parsed = fallback
    return max(10, min(200, parsed))


def item_duration_ms(item: dict[str, object], fallback: int) -> int:
    for key in ("duration_ms", "durationMs", "duration"):
        if key in item:
            return clean_duration(item.get(key), fallback)
    return clean_duration(fallback, 20)


def beats_from_items(items: list[object], default_duration_ms: int) -> tuple[TtsBeat, ...]:
    beats: list[TtsBeat] = []
    for item in items[:MAX_TTS_BEATS]:
        if not isinstance(item, dict):
            continue
        envelope = item.get("env", item.get("envelope", item.get("mouthOpen", 0.0)))
        beats.append(
            TtsBeat(
                env=clamp(envelope, 0.0, 1.0),
                viseme=clean_viseme(item.get("viseme", "neutral")),
                duration_ms=item_duration_ms(item, default_duration_ms),
                final=bool(item.get("final", False)),
            )
        )
    if beats:
        beats[-1] = TtsBeat(beats[-1].env, beats[-1].viseme, beats[-1].duration_ms, True)
    return tuple(beats)


def beats_from_sidecar_frames(frames: list[object], frame_ms: int) -> tuple[TtsBeat, ...]:
    normalized: list[dict[str, object]] = []
    for index, frame in enumerate(frames[:MAX_TTS_BEATS]):
        if not isinstance(frame, dict):
            continue
        duration_ms = frame_ms
        next_frame = frames[index + 1] if index + 1 < len(frames) else None
        if isinstance(next_frame, dict) and "tMs" in frame and "tMs" in next_frame:
            try:
                duration_ms = int(float(next_frame["tMs"]) - float(frame["tMs"]))
            except (TypeError, ValueError):
                duration_ms = frame_ms
        normalized.append(
            {
                "env": frame.get("env", frame.get("envelope", 0.0)),
                "viseme": frame.get("viseme", "neutral"),
                "duration_ms": duration_ms,
                "final": frame.get("final", False),
            }
        )
    return beats_from_items(normalized, frame_ms)


def normalize_tts_output(raw_output: bytes) -> tuple[tuple[TtsBeat, ...], dict[str, object]]:
    text = raw_output.decode("utf-8", errors="replace").strip()
    if not text:
        raise TtsExecutionError("tts command produced empty output")
    try:
        parsed: Any = json.loads(text)
    except json.JSONDecodeError as exc:
        raise TtsExecutionError("tts command must print metadata JSON") from exc
    if not isinstance(parsed, dict):
        raise TtsExecutionError("tts command JSON must be an object")

    frame_ms = clean_duration(parsed.get("frameMs", parsed.get("frame_ms", 20)), 20)
    if isinstance(parsed.get("beats"), list):
        beats = beats_from_items(parsed["beats"], frame_ms)
    elif isinstance(parsed.get("frames"), list):
        beats = beats_from_sidecar_frames(parsed["frames"], frame_ms)
    else:
        raise TtsExecutionError("tts command JSON must include beats or frames")
    if not beats:
        raise TtsExecutionError("tts command produced no usable mouth beats")

    audio_data = decode_audio_payload(parsed)
    reported_audio_bytes = max(0, int(clamp(parsed.get("audio_bytes", parsed.get("audioBytes", 0)), 0, 100 * 1024 * 1024)))
    metadata = {
        "audio_format": str(parsed.get("audio_format") or parsed.get("format") or "").strip()[:32],
        "sample_rate": max(0, int(clamp(parsed.get("sample_rate", parsed.get("sampleRate", 0)), 0, 192000))),
        "audio_bytes": len(audio_data) if audio_data else reported_audio_bytes,
        "audio_path": str(parsed.get("audio_path") or parsed.get("sourceWav") or parsed.get("path") or "").strip()[:260],
        "audio_data": audio_data,
    }
    return beats, metadata


def decode_audio_payload(parsed: dict[str, object]) -> bytes:
    encoded = str(parsed.get("audio_b64") or parsed.get("audioBase64") or "").strip()
    if not encoded:
        return b""
    try:
        audio = base64.b64decode(encoded, validate=True)
    except (ValueError, binascii.Error) as exc:
        raise TtsExecutionError("tts audio_b64 is not valid base64") from exc
    if len(audio) > MAX_TTS_AUDIO_BYTES:
        raise TtsExecutionError(f"tts audio payload exceeds {MAX_TTS_AUDIO_BYTES} bytes")
    return audio


def run_tts_command(command: str, text: str, voice: str, timeout_ms: int) -> tuple[tuple[TtsBeat, ...], dict[str, object], float]:
    payload = text.encode("utf-8")
    env = os.environ.copy()
    env["STACKCHAN_TTS_TEXT_BYTES"] = str(len(payload))
    env["STACKCHAN_TTS_VOICE"] = voice
    env["STACKCHAN_TTS_OUTPUT"] = "stackchan.tts-metadata.v1"
    start = time.perf_counter()
    try:
        completed = subprocess.run(
            command,
            input=payload,
            capture_output=True,
            shell=True,
            check=False,
            timeout=max(1, timeout_ms) / 1000.0,
            env=env,
        )
    except subprocess.TimeoutExpired as exc:
        raise TtsExecutionError(f"tts command timed out after {timeout_ms} ms") from exc
    elapsed_ms = (time.perf_counter() - start) * 1000.0
    if completed.returncode != 0:
        stderr = completed.stderr.decode("utf-8", errors="replace").strip()
        raise TtsExecutionError(f"tts command failed with exit {completed.returncode}: {stderr}")
    beats, metadata = normalize_tts_output(completed.stdout)
    return beats, metadata, elapsed_ms


def synthesize_speech(
    text: str,
    *,
    command: str = "",
    voice: str = DEFAULT_TTS_VOICE,
    timeout_ms: int = DEFAULT_TTS_TIMEOUT_MS,
) -> TtsResult:
    resolved_command, command_source = resolve_tts_command(command)
    if not resolved_command:
        raise TtsConfigurationError(f"no TTS command configured; set {TTS_COMMAND_ENV} or pass --tts-command")
    clean_text = " ".join(str(text or "").split())[:2000]
    if not clean_text:
        raise TtsExecutionError("tts text is empty")
    clean_voice = " ".join(str(voice or DEFAULT_TTS_VOICE).split())[:80]
    beats, metadata, elapsed_ms = run_tts_command(resolved_command, clean_text, clean_voice, timeout_ms)
    return TtsResult(
        beats=beats,
        elapsed_ms=elapsed_ms,
        command_source=command_source,
        text_bytes=len(clean_text.encode("utf-8")),
        voice=clean_voice,
        audio_format=str(metadata["audio_format"]),
        sample_rate=int(metadata["sample_rate"]),
        audio_bytes=int(metadata["audio_bytes"]),
        audio_path=str(metadata["audio_path"]),
        audio_data=bytes(metadata["audio_data"]),
    )


def build_arg_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description="Run a local TTS command and normalize Stackchan mouth beats.")
    parser.add_argument("--text", default="", help="Text to synthesize. Defaults to stdin.")
    parser.add_argument("--text-file", type=Path)
    parser.add_argument("--voice", default=DEFAULT_TTS_VOICE)
    parser.add_argument("--tts-command", default="", help=f"Override command. Otherwise uses {TTS_COMMAND_ENV}.")
    parser.add_argument("--timeout-ms", type=int, default=DEFAULT_TTS_TIMEOUT_MS)
    parser.add_argument("--json", action="store_true", help="Print normalized metadata JSON.")
    return parser


def main() -> int:
    args = build_arg_parser().parse_args()
    if args.text_file:
        text = args.text_file.read_text(encoding="utf-8")
    elif args.text:
        text = args.text
    else:
        text = os.fdopen(0, "rb").read().decode("utf-8", errors="replace")
    try:
        result = synthesize_speech(
            text,
            command=args.tts_command,
            voice=args.voice,
            timeout_ms=args.timeout_ms,
        )
    except (TtsConfigurationError, TtsExecutionError, ValueError) as exc:
        print(str(exc))
        return 2
    if args.json:
        print(json.dumps(result.to_dict(), indent=2, sort_keys=True))
    else:
        print(f"beats={len(result.beats)} duration_ms={result.duration_ms}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
