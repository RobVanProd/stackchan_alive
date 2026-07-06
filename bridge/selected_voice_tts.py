#!/usr/bin/env python3
"""Test TTS command that streams the selected Stackchan RVC voice sample."""

from __future__ import annotations

import base64
import json
import math
import os
import shutil
import subprocess
import sys
from pathlib import Path


SAMPLE_RATE = 22050
FRAME_MS = 80
DEFAULT_MAX_AUDIO_BYTES = 2 * 1024 * 1024


def repo_root() -> Path:
    return Path(__file__).resolve().parents[1]


def selected_voice_path() -> Path:
    configured = os.environ.get("STACKCHAN_SELECTED_VOICE_SAMPLE", "").strip()
    if configured:
        return Path(configured)
    return repo_root() / "media" / "voice" / "rvc" / "stackchan_rvc_bright_robot.mp3"


def ffmpeg_exe() -> str:
    configured = os.environ.get("STACKCHAN_FFMPEG_EXE", "").strip()
    if configured:
        return configured
    found = shutil.which("ffmpeg")
    if found:
        return found
    local_app_data = os.environ.get("LOCALAPPDATA", "")
    if local_app_data:
        package_root = Path(local_app_data) / "Microsoft" / "WinGet" / "Packages"
        matches = sorted(package_root.glob("Gyan.FFmpeg*/*/bin/ffmpeg.exe"))
        if matches:
            return str(matches[-1])
    return "ffmpeg"


def max_audio_bytes() -> int:
    configured = os.environ.get("STACKCHAN_SELECTED_VOICE_MAX_AUDIO_BYTES", "").strip()
    if not configured:
        return DEFAULT_MAX_AUDIO_BYTES
    try:
        return max(2, int(configured))
    except ValueError:
        return DEFAULT_MAX_AUDIO_BYTES


def start_audio_bytes() -> int:
    configured = os.environ.get("STACKCHAN_SELECTED_VOICE_START_BYTES", "").strip()
    if not configured:
        return 0
    try:
        return max(0, int(configured))
    except ValueError:
        return 0


def audio_gain() -> float:
    configured = os.environ.get("STACKCHAN_SELECTED_VOICE_GAIN", "").strip()
    if not configured:
        return 1.0
    try:
        return max(0.05, min(4.0, float(configured)))
    except ValueError:
        return 1.0


def apply_gain(pcm: bytes, gain: float) -> bytes:
    if gain == 1.0:
        return pcm
    adjusted = bytearray(len(pcm))
    for index in range(0, len(pcm) - 1, 2):
        value = int.from_bytes(pcm[index : index + 2], "little", signed=True)
        scaled = int(round(value * gain))
        if scaled > 32767:
            scaled = 32767
        elif scaled < -32768:
            scaled = -32768
        adjusted[index : index + 2] = int(scaled).to_bytes(2, "little", signed=True)
    return bytes(adjusted)


def decode_to_pcm16(source: Path) -> bytes:
    if not source.exists():
        raise FileNotFoundError(f"missing selected voice sample: {source}")
    command = [
        ffmpeg_exe(),
        "-v",
        "error",
        "-i",
        str(source),
        "-f",
        "s16le",
        "-acodec",
        "pcm_s16le",
        "-ac",
        "1",
        "-ar",
        str(SAMPLE_RATE),
        "-",
    ]
    completed = subprocess.run(command, capture_output=True, check=False)
    if completed.returncode != 0:
        raise RuntimeError(completed.stderr.decode("utf-8", errors="replace").strip())
    start = start_audio_bytes()
    if start % 2:
        start -= 1
    pcm = completed.stdout[start : start + max_audio_bytes()]
    if len(pcm) < 2:
        raise RuntimeError("selected voice sample decoded to empty PCM")
    if len(pcm) % 2:
        pcm = pcm[:-1]
    return apply_gain(pcm, audio_gain())


def sample_at(pcm: bytes, index: int) -> int:
    return int.from_bytes(pcm[index : index + 2], "little", signed=True)


def beats_from_pcm(pcm: bytes) -> list[dict[str, object]]:
    frame_samples = max(1, int(SAMPLE_RATE * FRAME_MS / 1000))
    frame_bytes = frame_samples * 2
    peaks: list[float] = []
    for offset in range(0, len(pcm), frame_bytes):
        chunk = pcm[offset : offset + frame_bytes]
        if len(chunk) < 2:
            continue
        total = 0.0
        count = 0
        for index in range(0, len(chunk) - 1, 2):
            value = sample_at(chunk, index) / 32768.0
            total += value * value
            count += 1
        peaks.append(math.sqrt(total / max(1, count)))
    max_peak = max(peaks) if peaks else 1.0
    beats: list[dict[str, object]] = []
    visemes = ("ah", "oh", "ee", "neutral")
    for index, peak in enumerate(peaks[:800]):
        envelope = min(1.0, max(0.02, peak / max_peak))
        beats.append(
            {
                "env": round(envelope, 3),
                "viseme": visemes[index % len(visemes)] if envelope >= 0.08 else "neutral",
                "duration_ms": FRAME_MS,
                "final": False,
            }
        )
    if beats:
        beats[-1]["final"] = True
    return beats


def main() -> int:
    # The bridge passes arbitrary response text on stdin. This test adapter pins the
    # selected voice sample while still reporting the text byte count via metadata.
    text = sys.stdin.buffer.read()
    source = selected_voice_path()
    try:
        pcm = decode_to_pcm16(source)
        beats = beats_from_pcm(pcm)
    except Exception as exc:
        sys.stderr.write(str(exc) + "\n")
        return 2
    print(
        json.dumps(
            {
                "schema": "stackchan.tts-metadata.v1",
                "voice": "stackchan-rvc-bright-robot",
                "text_bytes": len(text),
                "source": str(source),
                "start_bytes": start_audio_bytes(),
                "gain": audio_gain(),
                "beats": beats,
                "audio_format": "pcm16",
                "sample_rate": SAMPLE_RATE,
                "audio_bytes": len(pcm),
                "audio_b64": base64.b64encode(pcm).decode("ascii"),
            },
            separators=(",", ":"),
            ensure_ascii=True,
        )
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
