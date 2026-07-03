#!/usr/bin/env python3
"""Local STT command adapter for the P7 Stackchan bridge."""

from __future__ import annotations

import argparse
import json
import os
import subprocess
import time
from dataclasses import dataclass
from pathlib import Path
from typing import Any

DEFAULT_STT_TIMEOUT_MS = 20000
STT_COMMAND_ENV = "STACKCHAN_STT_COMMAND"


class SttConfigurationError(RuntimeError):
    """Raised when STT is requested but no command is configured."""


class SttExecutionError(RuntimeError):
    """Raised when the configured STT command fails."""


@dataclass(frozen=True)
class SttResult:
    transcript: str
    elapsed_ms: float
    command_source: str
    sample_rate: int
    audio_bytes: int

    def to_dict(self) -> dict[str, object]:
        return {
            "transcript": self.transcript,
            "elapsed_ms": round(self.elapsed_ms, 2),
            "command_source": self.command_source,
            "sample_rate": self.sample_rate,
            "audio_bytes": self.audio_bytes,
        }


def resolve_stt_command(override: str = "") -> tuple[str | None, str]:
    if override.strip():
        return override.strip(), "cli"
    if os.environ.get(STT_COMMAND_ENV, "").strip():
        return os.environ[STT_COMMAND_ENV].strip(), f"env:{STT_COMMAND_ENV}"
    return None, "unconfigured"


def normalize_transcript_output(raw_output: bytes) -> str:
    text = raw_output.decode("utf-8", errors="replace").strip()
    if not text:
        return ""
    try:
        parsed: Any = json.loads(text)
    except json.JSONDecodeError:
        return " ".join(text.split())[:500]
    if isinstance(parsed, dict):
        for key in ("transcript", "text", "spoken_text"):
            value = str(parsed.get(key, "")).strip()
            if value:
                return " ".join(value.split())[:500]
    if isinstance(parsed, str):
        return " ".join(parsed.split())[:500]
    return ""


def run_stt_command(command: str, pcm: bytes, sample_rate: int, timeout_ms: int) -> tuple[str, float]:
    env = os.environ.copy()
    env["STACKCHAN_AUDIO_SAMPLE_RATE"] = str(sample_rate)
    env["STACKCHAN_AUDIO_FORMAT"] = "s16le_mono"
    env["STACKCHAN_AUDIO_BYTES"] = str(len(pcm))
    start = time.perf_counter()
    try:
        completed = subprocess.run(
            command,
            input=pcm,
            capture_output=True,
            shell=True,
            check=False,
            timeout=max(1, timeout_ms) / 1000.0,
            env=env,
        )
    except subprocess.TimeoutExpired as exc:
        raise SttExecutionError(f"stt command timed out after {timeout_ms} ms") from exc
    elapsed_ms = (time.perf_counter() - start) * 1000.0
    if completed.returncode != 0:
        stderr = completed.stderr.decode("utf-8", errors="replace").strip()
        raise SttExecutionError(f"stt command failed with exit {completed.returncode}: {stderr}")
    return normalize_transcript_output(completed.stdout), elapsed_ms


def transcribe_pcm(
    pcm: bytes,
    sample_rate: int,
    *,
    command: str = "",
    timeout_ms: int = DEFAULT_STT_TIMEOUT_MS,
) -> SttResult:
    resolved_command, command_source = resolve_stt_command(command)
    if not resolved_command:
        raise SttConfigurationError(f"no STT command configured; set {STT_COMMAND_ENV} or pass --stt-command")
    safe_rate = max(8000, min(48000, int(sample_rate or 16000)))
    transcript, elapsed_ms = run_stt_command(resolved_command, pcm, safe_rate, timeout_ms)
    if not transcript:
        raise SttExecutionError("stt command produced an empty transcript")
    return SttResult(
        transcript=transcript,
        elapsed_ms=elapsed_ms,
        command_source=command_source,
        sample_rate=safe_rate,
        audio_bytes=len(pcm),
    )


def build_arg_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description="Run a local STT command on raw signed 16-bit mono PCM.")
    parser.add_argument("--pcm-file", type=Path, help="Raw s16le mono PCM file. Defaults to stdin.")
    parser.add_argument("--sample-rate", type=int, default=16000)
    parser.add_argument("--stt-command", default="", help=f"Override command. Otherwise uses {STT_COMMAND_ENV}.")
    parser.add_argument("--timeout-ms", type=int, default=DEFAULT_STT_TIMEOUT_MS)
    parser.add_argument("--json", action="store_true", help="Print metadata JSON instead of transcript only.")
    return parser


def main() -> int:
    args = build_arg_parser().parse_args()
    pcm = args.pcm_file.read_bytes() if args.pcm_file else os.fdopen(0, "rb").read()
    try:
        result = transcribe_pcm(
            pcm,
            args.sample_rate,
            command=args.stt_command,
            timeout_ms=args.timeout_ms,
        )
    except (SttConfigurationError, SttExecutionError, ValueError) as exc:
        print(str(exc))
        return 2
    if args.json:
        print(json.dumps(result.to_dict(), indent=2, sort_keys=True))
    else:
        print(result.transcript)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
