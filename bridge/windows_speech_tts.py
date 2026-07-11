#!/usr/bin/env python3
"""Windows System.Speech TTS adapter for Stackchan bridge audio downlink."""

from __future__ import annotations

import base64
import json
import math
import os
import subprocess
import sys
import tempfile
import wave
from pathlib import Path


DEFAULT_SAMPLE_RATE = 16000
DEFAULT_MAX_AUDIO_BYTES = 65536
FRAME_MS = 80


POWERSHELL_SCRIPT = r"""
$ErrorActionPreference = "Stop"
Add-Type -AssemblyName System.Speech

$text = Get-Content -LiteralPath $env:STACKCHAN_WINDOWS_TTS_TEXT_FILE -Raw
$outputPath = $env:STACKCHAN_WINDOWS_TTS_WAV_FILE
$voiceName = $env:STACKCHAN_WINDOWS_TTS_VOICE
$rate = [int]$env:STACKCHAN_WINDOWS_TTS_RATE
$volume = [int]$env:STACKCHAN_WINDOWS_TTS_VOLUME
$sampleRate = [int]$env:STACKCHAN_WINDOWS_TTS_SAMPLE_RATE

$synth = New-Object System.Speech.Synthesis.SpeechSynthesizer
try {
  if ($voiceName) {
    $matchedVoice = $synth.GetInstalledVoices() |
      Where-Object { $_.VoiceInfo.Name -eq $voiceName } |
      Select-Object -First 1
    if ($matchedVoice) {
      $synth.SelectVoice($voiceName)
    }
  }
  $synth.Rate = [Math]::Max(-10, [Math]::Min(10, $rate))
  $synth.Volume = [Math]::Max(0, [Math]::Min(100, $volume))
  $format = New-Object System.Speech.AudioFormat.SpeechAudioFormatInfo(
    $sampleRate,
    [System.Speech.AudioFormat.AudioBitsPerSample]::Sixteen,
    [System.Speech.AudioFormat.AudioChannel]::Mono
  )
  $synth.SetOutputToWaveFile($outputPath, $format)
  $synth.Speak($text)
}
finally {
  $synth.Dispose()
}
"""


def int_env(name: str, default: int, low: int, high: int) -> int:
    value = os.environ.get(name, "").strip()
    if not value:
        return default
    try:
        parsed = int(float(value))
    except ValueError:
        return default
    return max(low, min(high, parsed))


def float_env(name: str, default: float, low: float, high: float) -> float:
    value = os.environ.get(name, "").strip()
    if not value:
        return default
    try:
        parsed = float(value)
    except ValueError:
        return default
    return max(low, min(high, parsed))


def requested_voice() -> str:
    configured = os.environ.get("STACKCHAN_WINDOWS_TTS_VOICE", "").strip()
    if configured:
        return configured
    bridge_voice = os.environ.get("STACKCHAN_TTS_VOICE", "").strip()
    if bridge_voice and not bridge_voice.lower().startswith("stackchan-"):
        return bridge_voice
    return ""


def synthesize_wav(text: str, wav_path: Path) -> None:
    with tempfile.NamedTemporaryFile("w", suffix=".txt", encoding="utf-8", delete=False) as text_file:
        text_path = Path(text_file.name)
        text_file.write(text)
    env = os.environ.copy()
    env["STACKCHAN_WINDOWS_TTS_TEXT_FILE"] = str(text_path)
    env["STACKCHAN_WINDOWS_TTS_WAV_FILE"] = str(wav_path)
    env["STACKCHAN_WINDOWS_TTS_VOICE"] = requested_voice()
    env["STACKCHAN_WINDOWS_TTS_RATE"] = str(int_env("STACKCHAN_WINDOWS_TTS_RATE", 0, -10, 10))
    env["STACKCHAN_WINDOWS_TTS_VOLUME"] = str(int_env("STACKCHAN_WINDOWS_TTS_VOLUME", 100, 0, 100))
    env["STACKCHAN_WINDOWS_TTS_SAMPLE_RATE"] = str(
        int_env("STACKCHAN_WINDOWS_TTS_SAMPLE_RATE", DEFAULT_SAMPLE_RATE, 8000, 48000)
    )
    encoded_script = base64.b64encode(POWERSHELL_SCRIPT.encode("utf-16le")).decode("ascii")
    try:
        completed = subprocess.run(
            [
                "powershell.exe",
                "-NoProfile",
                "-ExecutionPolicy",
                "Bypass",
                "-EncodedCommand",
                encoded_script,
            ],
            capture_output=True,
            check=False,
            env=env,
            timeout=max(1, int_env("STACKCHAN_WINDOWS_TTS_TIMEOUT_SECONDS", 20, 1, 120)),
        )
    finally:
        try:
            text_path.unlink()
        except OSError:
            pass
    if completed.returncode != 0:
        stderr = completed.stderr.decode("utf-8", errors="replace").strip()
        stdout = completed.stdout.decode("utf-8", errors="replace").strip()
        detail = stderr or stdout or f"exit {completed.returncode}"
        raise RuntimeError(f"Windows System.Speech synthesis failed: {detail}")


def decode_sample(sample: bytes, width: int) -> int:
    if width == 1:
        return (sample[0] - 128) << 8
    if width == 2:
        return int.from_bytes(sample, "little", signed=True)
    if width == 3:
        extended = sample + (b"\xff" if sample[2] & 0x80 else b"\x00")
        return int.from_bytes(extended, "little", signed=True) >> 8
    if width == 4:
        return int.from_bytes(sample, "little", signed=True) >> 16
    raise RuntimeError(f"unsupported WAV sample width: {width}")


def read_wav_as_pcm16_mono(path: Path) -> tuple[int, bytes]:
    with wave.open(str(path), "rb") as wav:
        channels = wav.getnchannels()
        sample_width = wav.getsampwidth()
        sample_rate = wav.getframerate()
        frames = wav.readframes(wav.getnframes())
    if channels <= 0 or sample_rate <= 0:
        raise RuntimeError("Windows TTS generated invalid WAV metadata")
    frame_width = channels * sample_width
    if frame_width <= 0 or len(frames) % frame_width != 0:
        raise RuntimeError("Windows TTS generated misaligned WAV frames")
    out = bytearray((len(frames) // frame_width) * 2)
    out_index = 0
    for offset in range(0, len(frames), frame_width):
        total = 0
        for channel in range(channels):
            sample_offset = offset + channel * sample_width
            total += decode_sample(frames[sample_offset : sample_offset + sample_width], sample_width)
        mixed = max(-32768, min(32767, total // channels))
        out[out_index : out_index + 2] = int(mixed).to_bytes(2, "little", signed=True)
        out_index += 2
    return sample_rate, bytes(out)


def apply_gain(pcm: bytes, gain: float) -> bytes:
    if gain == 1.0:
        return pcm
    out = bytearray(len(pcm))
    for index in range(0, len(pcm) - 1, 2):
        value = int.from_bytes(pcm[index : index + 2], "little", signed=True)
        scaled = max(-32768, min(32767, int(round(value * gain))))
        out[index : index + 2] = int(scaled).to_bytes(2, "little", signed=True)
    return bytes(out)


def trim_pcm(pcm: bytes) -> tuple[bytes, bool]:
    max_bytes = int_env("STACKCHAN_WINDOWS_TTS_MAX_AUDIO_BYTES", DEFAULT_MAX_AUDIO_BYTES, 2, 2 * 1024 * 1024)
    if max_bytes % 2:
        max_bytes -= 1
    if len(pcm) <= max_bytes:
        return pcm, False
    return pcm[:max_bytes], True


def sample_at(pcm: bytes, index: int) -> int:
    return int.from_bytes(pcm[index : index + 2], "little", signed=True)


def beats_from_pcm(pcm: bytes, sample_rate: int) -> list[dict[str, object]]:
    frame_samples = max(1, int(sample_rate * FRAME_MS / 1000))
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
    visemes = ("ah", "oh", "ee", "neutral")
    beats: list[dict[str, object]] = []
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
    text = " ".join(sys.stdin.buffer.read().decode("utf-8", errors="replace").split())
    if not text:
        sys.stderr.write("Windows TTS text is empty\n")
        return 2
    with tempfile.TemporaryDirectory() as temp_dir:
        wav_path = Path(temp_dir) / "speech.wav"
        try:
            synthesize_wav(text, wav_path)
            sample_rate, pcm = read_wav_as_pcm16_mono(wav_path)
            pcm = apply_gain(pcm, float_env("STACKCHAN_WINDOWS_TTS_GAIN", 1.0, 0.05, 4.0))
            pcm, truncated = trim_pcm(pcm)
            if len(pcm) < 2:
                raise RuntimeError("Windows TTS generated empty PCM")
            beats = beats_from_pcm(pcm, sample_rate)
        except Exception as exc:
            sys.stderr.write(str(exc) + "\n")
            return 2
    print(
        json.dumps(
            {
                "schema": "stackchan.tts-metadata.v1",
                "voice": requested_voice() or "windows-system-speech-default",
                "text_bytes": len(text.encode("utf-8")),
                "sample_rate": sample_rate,
                "audio_format": "pcm16",
                "audio_bytes": len(pcm),
                "audio_truncated": truncated,
                "beats": beats,
                "audio_b64": base64.b64encode(pcm).decode("ascii"),
            },
            separators=(",", ":"),
            ensure_ascii=True,
        )
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
