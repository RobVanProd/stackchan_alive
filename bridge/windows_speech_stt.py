#!/usr/bin/env python3
"""Windows System.Speech STT adapter for Stackchan raw PCM uploads."""

from __future__ import annotations

import argparse
import json
import os
import subprocess
import sys
import tempfile
import wave
from dataclasses import dataclass
from pathlib import Path

from stt_normalization import NORMALIZE_ENV, normalize_stackchan_terms

DEFAULT_TIMEOUT_MS = 10000
DEFAULT_SAMPLE_RATE = 16000


POWERSHELL_RECOGNIZE_SCRIPT = r"""
param(
  [Parameter(Mandatory=$true)][string]$WavePath,
  [int]$TimeoutMs = 10000
)

$ErrorActionPreference = "Stop"
Add-Type -AssemblyName System.Speech
$recognizers = [System.Speech.Recognition.SpeechRecognitionEngine]::InstalledRecognizers()
if ($recognizers.Count -lt 1) {
  Write-Error "No Windows speech recognizer is installed."
  exit 2
}

$recognizerInfo = $recognizers[0]
$engine = New-Object System.Speech.Recognition.SpeechRecognitionEngine($recognizerInfo)
try {
  $grammar = New-Object System.Speech.Recognition.DictationGrammar
  $engine.LoadGrammar($grammar)
  $engine.SetInputToWaveFile($WavePath)
  $result = $engine.Recognize([TimeSpan]::FromMilliseconds([Math]::Max(1000, $TimeoutMs)))
  if ($null -eq $result -or [string]::IsNullOrWhiteSpace($result.Text)) {
    Write-Error "No speech recognized."
    exit 3
  }
  [pscustomobject]@{
    transcript = $result.Text
    confidence = $result.Confidence
    recognizer = $recognizerInfo.Name
    culture = $recognizerInfo.Culture.Name
  } | ConvertTo-Json -Compress
} finally {
  $engine.Dispose()
}
"""


@dataclass(frozen=True)
class WindowsSpeechResult:
    transcript: str
    confidence: float
    recognizer: str
    culture: str
    raw_transcript: str = ""


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


def parse_recognizer_output(raw_output: bytes) -> WindowsSpeechResult:
    text = raw_output.decode("utf-8", errors="replace").strip()
    if not text:
        raise RuntimeError("Windows speech recognizer produced no transcript.")
    try:
        payload = json.loads(text)
    except json.JSONDecodeError:
        raw_transcript = " ".join(text.split())[:500]
        return WindowsSpeechResult(normalize_stackchan_terms(raw_transcript), 0.0, "Windows Speech", "", raw_transcript)
    raw_transcript = " ".join(str(payload.get("transcript", "")).split())[:500]
    if not raw_transcript:
        raise RuntimeError("Windows speech recognizer produced no transcript.")
    transcript = normalize_stackchan_terms(raw_transcript)
    try:
        confidence = float(payload.get("confidence", 0.0))
    except (TypeError, ValueError):
        confidence = 0.0
    return WindowsSpeechResult(
        transcript=transcript,
        confidence=confidence,
        recognizer=str(payload.get("recognizer", "Windows Speech")),
        culture=str(payload.get("culture", "")),
        raw_transcript=raw_transcript,
    )


def recognize_wav(wav_path: Path, timeout_ms: int = DEFAULT_TIMEOUT_MS) -> WindowsSpeechResult:
    with tempfile.TemporaryDirectory(prefix="stackchan-stt-") as temp_dir:
        script_path = Path(temp_dir) / "recognize.ps1"
        script_path.write_text(POWERSHELL_RECOGNIZE_SCRIPT, encoding="utf-8")
        completed = subprocess.run(
            [
                "powershell.exe",
                "-NoProfile",
                "-ExecutionPolicy",
                "Bypass",
                "-File",
                str(script_path),
                "-WavePath",
                str(wav_path),
                "-TimeoutMs",
                str(max(1000, int(timeout_ms))),
            ],
            capture_output=True,
            check=False,
            text=False,
        )
    if completed.returncode != 0:
        stderr = completed.stderr.decode("utf-8", errors="replace").strip()
        stdout = completed.stdout.decode("utf-8", errors="replace").strip()
        detail = stderr or stdout or f"exit {completed.returncode}"
        raise RuntimeError(f"Windows speech recognition failed: {detail}")
    return parse_recognizer_output(completed.stdout)


def transcribe_pcm_with_windows_speech(
    pcm: bytes, sample_rate: int, timeout_ms: int = DEFAULT_TIMEOUT_MS
) -> WindowsSpeechResult:
    if not pcm:
        raise RuntimeError("No PCM audio was provided.")
    with tempfile.TemporaryDirectory(prefix="stackchan-stt-") as temp_dir:
        wav_path = Path(temp_dir) / "utterance.wav"
        write_pcm_wav(wav_path, pcm, sample_rate)
        return recognize_wav(wav_path, timeout_ms=timeout_ms)


def build_arg_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description="Transcribe raw s16le mono PCM with Windows System.Speech.")
    parser.add_argument("--pcm-file", type=Path, help="Raw PCM input. Defaults to stdin.")
    parser.add_argument("--sample-rate", type=int, default=None)
    parser.add_argument("--timeout-ms", type=int, default=DEFAULT_TIMEOUT_MS)
    parser.add_argument("--json", action="store_true", help="Print recognizer metadata JSON.")
    return parser


def main() -> int:
    args = build_arg_parser().parse_args()
    pcm = args.pcm_file.read_bytes() if args.pcm_file else os.fdopen(0, "rb").read()
    sample_rate = clamp_sample_rate(args.sample_rate or os.environ.get("STACKCHAN_AUDIO_SAMPLE_RATE"))
    try:
        result = transcribe_pcm_with_windows_speech(pcm, sample_rate, timeout_ms=args.timeout_ms)
    except Exception as exc:
        print(str(exc), file=sys.stderr)
        return 2
    payload = {
        "transcript": result.transcript,
        "confidence": result.confidence,
        "recognizer": result.recognizer,
        "culture": result.culture,
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
