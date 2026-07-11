#!/usr/bin/env python3
"""whisper.cpp STT adapter for Stackchan raw PCM uploads."""

from __future__ import annotations

import argparse
import json
import os
import re
import shlex
import shutil
import subprocess
import sys
import tempfile
import wave
from dataclasses import dataclass
from pathlib import Path

try:
    from stt_normalization import normalize_stackchan_terms
except ModuleNotFoundError:  # pragma: no cover - package-style import fallback
    from bridge.stt_normalization import normalize_stackchan_terms

DEFAULT_TIMEOUT_MS = 20000
DEFAULT_SAMPLE_RATE = 16000
DEFAULT_LANGUAGE = "en"

WHISPER_EXE_ENV = "STACKCHAN_WHISPER_CPP_EXE"
WHISPER_MODEL_ENV = "STACKCHAN_WHISPER_MODEL"
WHISPER_LANGUAGE_ENV = "STACKCHAN_WHISPER_LANGUAGE"
WHISPER_THREADS_ENV = "STACKCHAN_WHISPER_THREADS"


@dataclass(frozen=True)
class WhisperCppResult:
    transcript: str
    whisper_exe: str
    model: str
    language: str
    raw_transcript: str = ""


def repo_root() -> Path:
    return Path(__file__).resolve().parent.parent


def clamp_sample_rate(value: object) -> int:
    try:
        parsed = int(value)
    except (TypeError, ValueError):
        parsed = DEFAULT_SAMPLE_RATE
    return max(8000, min(48000, parsed))


def write_pcm_wav(path: Path, pcm: bytes, sample_rate: int) -> None:
    with wave.open(str(path), "wb") as wav:
        wav.setnchannels(1)
        wav.setsampwidth(2)
        wav.setframerate(clamp_sample_rate(sample_rate))
        wav.writeframes(pcm)


def local_whisper_candidates() -> list[Path]:
    root = repo_root()
    return [
        root / "output" / "local-tools" / "whisper.cpp" / "whisper-cli.exe",
        root / "output" / "local-tools" / "whisper.cpp" / "bin" / "whisper-cli.exe",
        root / "output" / "local-tools" / "whisper.cpp" / "Release" / "whisper-cli.exe",
        root / "output" / "local-tools" / "whisper.cpp" / "build" / "bin" / "Release" / "whisper-cli.exe",
        root / "tools" / "local" / "whisper.cpp" / "whisper-cli.exe",
        root / "tools" / "local" / "whisper.cpp" / "Release" / "whisper-cli.exe",
    ]


def resolve_whisper_exe(override: str = "") -> str:
    value = override.strip() or os.environ.get(WHISPER_EXE_ENV, "").strip()
    if value:
        return value
    for name in ("whisper-cli", "whisper-cli.exe"):
        found = shutil.which(name)
        if found:
            return found
    for candidate in local_whisper_candidates():
        if candidate.is_file():
            return str(candidate)
    found_main = shutil.which("main.exe")
    if found_main and Path(found_main).suffix.lower() == ".exe":
        return found_main
    raise RuntimeError(
        f"whisper.cpp executable not found. Run tools\\setup_whisper_cpp.cmd or set {WHISPER_EXE_ENV}."
    )


def resolve_model_path(override: str = "") -> str:
    value = override.strip() or os.environ.get(WHISPER_MODEL_ENV, "").strip()
    if value:
        return value
    candidate = repo_root() / "output" / "local-tools" / "whisper.cpp" / "models" / "ggml-base.en.bin"
    if candidate.is_file():
        return str(candidate)
    raise RuntimeError(f"whisper.cpp model not found. Run tools\\setup_whisper_cpp.cmd or set {WHISPER_MODEL_ENV}.")


def split_command(value: str) -> list[str]:
    return shlex.split(value, posix=os.name != "nt")


def parse_threads(value: str = "") -> int:
    try:
        parsed = int(value or os.environ.get(WHISPER_THREADS_ENV, "") or "0")
    except ValueError:
        parsed = 0
    return max(0, min(32, parsed))


def clean_whisper_text(text: str) -> str:
    lines: list[str] = []
    timestamp = re.compile(r"^\s*\[[^\]]+\]\s*")
    for raw_line in str(text or "").splitlines():
        line = timestamp.sub("", raw_line).strip()
        if not line:
            continue
        if line.startswith("whisper_") or line.startswith("ggml_") or line.startswith("system_info:"):
            continue
        if "fallback" in line and "failed" in line:
            continue
        lines.append(line)
    return " ".join(" ".join(lines).split())[:500]


def read_whisper_transcript(output_prefix: Path, stdout: bytes) -> str:
    txt_path = output_prefix.with_suffix(".txt")
    if txt_path.is_file():
        transcript = clean_whisper_text(txt_path.read_text(encoding="utf-8", errors="replace"))
        if transcript:
            return transcript
    return clean_whisper_text(stdout.decode("utf-8", errors="replace"))


def transcribe_pcm_with_whisper_cpp(
    pcm: bytes,
    sample_rate: int,
    *,
    whisper_exe: str = "",
    model: str = "",
    language: str = "",
    timeout_ms: int = DEFAULT_TIMEOUT_MS,
) -> WhisperCppResult:
    if not pcm:
        raise RuntimeError("No PCM audio was provided.")
    resolved_exe = resolve_whisper_exe(whisper_exe)
    resolved_model = resolve_model_path(model)
    resolved_language = (language or os.environ.get(WHISPER_LANGUAGE_ENV, "") or DEFAULT_LANGUAGE).strip()
    threads = parse_threads()

    with tempfile.TemporaryDirectory(prefix="stackchan-whisper-") as temp_dir:
        temp_path = Path(temp_dir)
        wav_path = temp_path / "utterance.wav"
        output_prefix = temp_path / "utterance"
        write_pcm_wav(wav_path, pcm, sample_rate)

        command = split_command(resolved_exe)
        if not command:
            raise RuntimeError("whisper.cpp executable command is empty.")
        command += [
            "-m",
            resolved_model,
            "-f",
            str(wav_path),
            "-l",
            resolved_language,
            "-nt",
            "-otxt",
            "-of",
            str(output_prefix),
        ]
        if threads > 0:
            command += ["-t", str(threads)]
        try:
            completed = subprocess.run(
                command,
                capture_output=True,
                check=False,
                timeout=max(1, int(timeout_ms)) / 1000.0,
            )
        except subprocess.TimeoutExpired as exc:
            raise RuntimeError(f"whisper.cpp timed out after {timeout_ms} ms") from exc

        if completed.returncode != 0:
            stderr = completed.stderr.decode("utf-8", errors="replace").strip()
            stdout = completed.stdout.decode("utf-8", errors="replace").strip()
            detail = stderr or stdout or f"exit {completed.returncode}"
            raise RuntimeError(f"whisper.cpp failed: {detail}")

        raw_transcript = read_whisper_transcript(output_prefix, completed.stdout)
        if not raw_transcript:
            raise RuntimeError("whisper.cpp produced no transcript.")
        transcript = normalize_stackchan_terms(raw_transcript)
        return WhisperCppResult(
            transcript=transcript,
            raw_transcript=raw_transcript,
            whisper_exe=resolved_exe,
            model=resolved_model,
            language=resolved_language,
        )


def build_arg_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description="Transcribe raw s16le mono PCM with whisper.cpp.")
    parser.add_argument("--pcm-file", type=Path, help="Raw PCM input. Defaults to stdin.")
    parser.add_argument("--sample-rate", type=int, default=None)
    parser.add_argument("--timeout-ms", type=int, default=DEFAULT_TIMEOUT_MS)
    parser.add_argument("--whisper-exe", default="", help=f"Override whisper.cpp executable; otherwise {WHISPER_EXE_ENV}.")
    parser.add_argument("--model", default="", help=f"Override ggml model path; otherwise {WHISPER_MODEL_ENV}.")
    parser.add_argument("--language", default="", help=f"Language code; otherwise {WHISPER_LANGUAGE_ENV} or en.")
    parser.add_argument("--json", action="store_true", help="Print recognizer metadata JSON.")
    return parser


def main() -> int:
    args = build_arg_parser().parse_args()
    pcm = args.pcm_file.read_bytes() if args.pcm_file else os.fdopen(0, "rb").read()
    sample_rate = clamp_sample_rate(args.sample_rate or os.environ.get("STACKCHAN_AUDIO_SAMPLE_RATE"))
    try:
        result = transcribe_pcm_with_whisper_cpp(
            pcm,
            sample_rate,
            whisper_exe=args.whisper_exe,
            model=args.model,
            language=args.language,
            timeout_ms=args.timeout_ms,
        )
    except Exception as exc:
        print(str(exc), file=sys.stderr)
        return 2
    payload = {
        "transcript": result.transcript,
        "engine": "whisper.cpp",
        "whisper_exe": result.whisper_exe,
        "model": result.model,
        "language": result.language,
    }
    if result.raw_transcript and result.raw_transcript != result.transcript:
        payload["raw_transcript"] = result.raw_transcript
        payload["transcript_normalized"] = True
    if args.json:
        print(json.dumps(payload, indent=2, sort_keys=True))
    else:
        print(json.dumps(payload, separators=(",", ":")))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
