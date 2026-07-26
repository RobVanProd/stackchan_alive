#!/usr/bin/env python3
"""RVC-backed TTS adapter for Stackchan bridge audio downlink."""

from __future__ import annotations

import base64
import json
import math
import os
import queue
import shutil
import subprocess
import sys
import tempfile
import threading
import time
from pathlib import Path


DEFAULT_SAMPLE_RATE = 16000
DEFAULT_MAX_AUDIO_BYTES = 2 * 1024 * 1024
FRAME_MS = 80
TTS_MODE_RATE_OFFSETS = {
    "idle": -1,
    "attend": 0,
    "listen": 0,
    "think": -1,
    "speak": 0,
    "react": 1,
    "happy": 1,
    "concern": -1,
    "sleep": -2,
    "error": -1,
    "safety": -1,
}


POWERSHELL_TTS_SCRIPT = r"""
$ErrorActionPreference = "Stop"
Add-Type -AssemblyName System.Speech

$text = Get-Content -LiteralPath $env:STACKCHAN_RVC_BASE_TTS_TEXT_FILE -Raw
$outputPath = $env:STACKCHAN_RVC_BASE_TTS_WAV_FILE
$voiceName = $env:STACKCHAN_RVC_BASE_TTS_VOICE
$rate = [int]$env:STACKCHAN_RVC_BASE_TTS_RATE
$volume = [int]$env:STACKCHAN_RVC_BASE_TTS_VOLUME
$sampleRate = [int]$env:STACKCHAN_RVC_BASE_TTS_SAMPLE_RATE

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

PERSISTENT_POWERSHELL_TTS_SCRIPT = r"""
$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"
[Console]::InputEncoding = New-Object System.Text.UTF8Encoding($false)
[Console]::OutputEncoding = New-Object System.Text.UTF8Encoding($false)
Add-Type -AssemblyName System.Speech

$synth = New-Object System.Speech.Synthesis.SpeechSynthesizer
try {
  while (($line = [Console]::In.ReadLine()) -ne $null) {
    $request = $line | ConvertFrom-Json
    $response = [ordered]@{
      id = [int]$request.id
      ok = $false
      error = ""
    }
    try {
      if ($request.voice) {
        $synth.SelectVoice([string]$request.voice)
      }
      $synth.Rate = [Math]::Max(-10, [Math]::Min(10, [int]$request.rate))
      $synth.Volume = [Math]::Max(0, [Math]::Min(100, [int]$request.volume))
      $format = New-Object System.Speech.AudioFormat.SpeechAudioFormatInfo(
        [int]$request.sample_rate,
        [System.Speech.AudioFormat.AudioBitsPerSample]::Sixteen,
        [System.Speech.AudioFormat.AudioChannel]::Mono
      )
      $synth.SetOutputToWaveFile([string]$request.wav_path, $format)
      $synth.Speak([string]$request.text)
      $synth.SetOutputToNull()
      $response.ok = $true
    }
    catch {
      $response.error = $_.Exception.Message
      try { $synth.SetOutputToNull() } catch {}
    }
    [Console]::Out.WriteLine(($response | ConvertTo-Json -Compress))
    [Console]::Out.Flush()
  }
}
finally {
  $synth.Dispose()
}
"""


class PersistentWindowsSpeechSynthesizer:
    """Keep System.Speech loaded and exchange bounded JSON lines over stdio."""

    def __init__(self, *, timeout_seconds: int = 20) -> None:
        self.timeout_seconds = max(1, min(120, int(timeout_seconds)))
        self._lock = threading.Lock()
        self._process: subprocess.Popen[str] | None = None
        self._responses: queue.Queue[str] | None = None
        self._reader: threading.Thread | None = None
        self._next_id = 1

    @staticmethod
    def _reader_loop(stream: object, responses: queue.Queue[str]) -> None:
        try:
            for line in stream:  # type: ignore[union-attr]
                clean = str(line).strip()
                if clean:
                    responses.put(clean)
        finally:
            responses.put("")

    def _start(self) -> None:
        self._stop()
        encoded_script = base64.b64encode(
            PERSISTENT_POWERSHELL_TTS_SCRIPT.encode("utf-16le")
        ).decode("ascii")
        process = subprocess.Popen(
            [
                "powershell.exe",
                "-NoProfile",
                "-ExecutionPolicy",
                "Bypass",
                "-EncodedCommand",
                encoded_script,
            ],
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL,
            text=True,
            encoding="utf-8",
            errors="replace",
            bufsize=1,
            creationflags=getattr(subprocess, "CREATE_NO_WINDOW", 0),
        )
        if process.stdin is None or process.stdout is None:
            process.kill()
            raise RuntimeError("persistent Windows TTS stdio is unavailable")
        responses: queue.Queue[str] = queue.Queue()
        reader = threading.Thread(
            target=self._reader_loop,
            args=(process.stdout, responses),
            name="stackchan-windows-tts-reader",
            daemon=True,
        )
        reader.start()
        self._process = process
        self._responses = responses
        self._reader = reader

    def _stop(self) -> None:
        process = self._process
        self._process = None
        self._responses = None
        self._reader = None
        if process is None:
            return
        try:
            if process.stdin is not None:
                process.stdin.close()
        except OSError:
            pass
        try:
            process.wait(timeout=1.0)
        except subprocess.TimeoutExpired:
            process.kill()
            try:
                process.wait(timeout=1.0)
            except subprocess.TimeoutExpired:
                pass

    def close(self) -> None:
        with self._lock:
            self._stop()

    def synthesize(
        self,
        text: str,
        wav_path: Path,
        *,
        voice: str = "",
        rate: int = 1,
        volume: int = 100,
        sample_rate: int = 48000,
    ) -> float:
        clean_text = " ".join(str(text or "").split())
        if not clean_text:
            raise ValueError("persistent Windows TTS text is empty")
        if len(clean_text) > 1000:
            raise ValueError("persistent Windows TTS text is too long")
        with self._lock:
            request = {
                "id": self._next_id,
                "text": clean_text,
                "wav_path": str(Path(wav_path).resolve()),
                "voice": str(voice or "").strip(),
                "rate": max(-10, min(10, int(rate))),
                "volume": max(0, min(100, int(volume))),
                "sample_rate": max(8000, min(48000, int(sample_rate))),
            }
            self._next_id += 1
            process = self._process
            if process is None or process.poll() is not None:
                self._start()
                process = self._process
            responses = self._responses
            if process is None or process.stdin is None or responses is None:
                raise RuntimeError("persistent Windows TTS failed to start")
            started = time.perf_counter()
            try:
                process.stdin.write(json.dumps(request, separators=(",", ":"), ensure_ascii=True) + "\n")
                process.stdin.flush()
                line = responses.get(timeout=self.timeout_seconds)
            except (BrokenPipeError, OSError, queue.Empty) as exc:
                self._stop()
                raise RuntimeError("persistent Windows TTS request failed") from exc
            if not line:
                self._stop()
                raise RuntimeError("persistent Windows TTS exited")
            try:
                response = json.loads(line)
            except json.JSONDecodeError as exc:
                self._stop()
                raise RuntimeError("persistent Windows TTS returned invalid JSON") from exc
            if int(response.get("id", -1)) != int(request["id"]):
                self._stop()
                raise RuntimeError("persistent Windows TTS response id mismatch")
            if response.get("ok") is not True:
                detail = str(response.get("error") or "synthesis failed")[:240]
                raise RuntimeError(f"persistent Windows TTS failed: {detail}")
            if not wav_path.exists() or wav_path.stat().st_size < 44:
                raise RuntimeError("persistent Windows TTS did not create a usable WAV")
            return (time.perf_counter() - started) * 1000.0


def repo_root() -> Path:
    return Path(__file__).resolve().parents[1]


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


def tts_delivery_style(
    *,
    mode: str | None = None,
    arousal: float | None = None,
    valence: float | None = None,
) -> dict[str, object]:
    mode = (
        os.environ.get("STACKCHAN_TTS_MODE", "speak")
        if mode is None
        else str(mode)
    ).strip().lower()
    if mode not in TTS_MODE_RATE_OFFSETS:
        mode = "speak"
    if arousal is None:
        arousal = float_env("STACKCHAN_TTS_AROUSAL", 0.5, 0.0, 1.0)
    else:
        arousal = max(0.0, min(1.0, float(arousal)))
    if valence is None:
        valence = float_env("STACKCHAN_TTS_VALENCE", 0.0, -1.0, 1.0)
    else:
        valence = max(-1.0, min(1.0, float(valence)))
    energy_offset = 1 if arousal >= 0.75 else -1 if arousal <= 0.20 else 0
    base_rate = int_env("STACKCHAN_RVC_BASE_TTS_RATE", 1, -10, 10)
    rate = max(-10, min(10, base_rate + TTS_MODE_RATE_OFFSETS[mode] + energy_offset))
    return {
        "mode": mode,
        "arousal": round(arousal, 3),
        "valence": round(valence, 3),
        "base_tts_rate": rate,
    }


def ffmpeg_exe() -> str:
    configured = os.environ.get("STACKCHAN_FFMPEG_EXE", "").strip()
    if configured:
        return configured
    found = shutil.which("ffmpeg")
    return found or "ffmpeg"


def rvc_python_exe() -> str:
    configured = os.environ.get("STACKCHAN_RVC_PYTHON_EXE", "").strip()
    if configured:
        return configured
    candidate = repo_root() / ".venv-rvc" / "Scripts" / "python.exe"
    return str(candidate)


def rvc_model_path() -> Path:
    configured = os.environ.get("STACKCHAN_RVC_MODEL_PATH", "").strip()
    if configured:
        return Path(configured)
    return repo_root() / "output" / "voice_sources" / "stackchan_rvc_base" / "model" / "model.pth"


def rvc_index_path() -> Path:
    configured = os.environ.get("STACKCHAN_RVC_INDEX_PATH", "").strip()
    if configured:
        return Path(configured)
    return repo_root() / "output" / "voice_sources" / "stackchan_rvc_base" / "model" / "model.index"


def synthesize_base_wav(
    text: str,
    wav_path: Path,
    *,
    mode: str | None = None,
    arousal: float | None = None,
    valence: float | None = None,
) -> None:
    with tempfile.NamedTemporaryFile("w", suffix=".txt", encoding="utf-8", delete=False) as text_file:
        text_path = Path(text_file.name)
        text_file.write(text)
    env = os.environ.copy()
    env["STACKCHAN_RVC_BASE_TTS_TEXT_FILE"] = str(text_path)
    env["STACKCHAN_RVC_BASE_TTS_WAV_FILE"] = str(wav_path)
    env["STACKCHAN_RVC_BASE_TTS_VOICE"] = os.environ.get("STACKCHAN_RVC_BASE_TTS_VOICE", "").strip()
    env["STACKCHAN_RVC_BASE_TTS_RATE"] = str(
        tts_delivery_style(mode=mode, arousal=arousal, valence=valence)["base_tts_rate"]
    )
    env["STACKCHAN_RVC_BASE_TTS_VOLUME"] = str(int_env("STACKCHAN_RVC_BASE_TTS_VOLUME", 100, 0, 100))
    env["STACKCHAN_RVC_BASE_TTS_SAMPLE_RATE"] = str(
        int_env("STACKCHAN_RVC_BASE_TTS_SAMPLE_RATE", 48000, 8000, 48000)
    )
    encoded_script = base64.b64encode(POWERSHELL_TTS_SCRIPT.encode("utf-16le")).decode("ascii")
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
            timeout=max(1, int_env("STACKCHAN_RVC_BASE_TTS_TIMEOUT_SECONDS", 20, 1, 120)),
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
        raise RuntimeError(f"base Windows TTS synthesis failed: {detail}")
    if not wav_path.exists() or wav_path.stat().st_size < 44:
        raise RuntimeError("base Windows TTS did not create a usable WAV")


def convert_with_rvc(input_wav: Path, output_wav: Path) -> float:
    model = rvc_model_path()
    index = rvc_index_path()
    python_exe = Path(rvc_python_exe())
    if not python_exe.exists():
        raise RuntimeError(f"missing RVC Python runtime: {python_exe}")
    if not model.exists():
        raise RuntimeError(f"missing RVC model: {model}")
    if not index.exists():
        raise RuntimeError(f"missing RVC index: {index}")
    command = [
        str(python_exe),
        "-m",
        "rvc_python",
        "cli",
        "-i",
        str(input_wav),
        "-o",
        str(output_wav),
        "-mp",
        str(model),
        "-ip",
        str(index),
        "-de",
        os.environ.get("STACKCHAN_RVC_DEVICE", "cpu:0").strip() or "cpu:0",
        "-me",
        os.environ.get("STACKCHAN_RVC_F0_METHOD", "harvest").strip() or "harvest",
        "-v",
        os.environ.get("STACKCHAN_RVC_VERSION", "v2").strip() or "v2",
        "-ir",
        str(float_env("STACKCHAN_RVC_INDEX_RATE", 0.62, 0.0, 1.0)),
        "-rmr",
        str(float_env("STACKCHAN_RVC_RMS_MIX_RATE", 0.72, 0.0, 1.0)),
        "-pr",
        str(float_env("STACKCHAN_RVC_PROTECT", 0.28, 0.0, 0.5)),
        "-pi",
        str(int_env("STACKCHAN_RVC_PITCH", 2, -24, 24)),
    ]
    start = time.perf_counter()
    env = os.environ.copy()
    env.setdefault("TORCH_FORCE_NO_WEIGHTS_ONLY_LOAD", "1")
    completed = subprocess.run(
        command,
        capture_output=True,
        check=False,
        env=env,
        timeout=max(1, int_env("STACKCHAN_RVC_TIMEOUT_SECONDS", 180, 1, 600)),
    )
    elapsed_ms = (time.perf_counter() - start) * 1000.0
    if completed.returncode != 0:
        stderr = completed.stderr.decode("utf-8", errors="replace").strip()
        stdout = completed.stdout.decode("utf-8", errors="replace").strip()
        detail = stderr or stdout or f"exit {completed.returncode}"
        raise RuntimeError(f"RVC conversion failed: {detail}")
    if not output_wav.exists() or output_wav.stat().st_size < 44:
        raise RuntimeError("RVC conversion did not create a usable WAV")
    return elapsed_ms


def decode_wav_to_pcm16(path: Path) -> tuple[int, bytes]:
    sample_rate = int_env("STACKCHAN_RVC_OUTPUT_SAMPLE_RATE", DEFAULT_SAMPLE_RATE, 8000, 48000)
    command = [
        ffmpeg_exe(),
        "-v",
        "error",
        "-i",
        str(path),
        "-f",
        "s16le",
        "-acodec",
        "pcm_s16le",
        "-ac",
        "1",
        "-ar",
        str(sample_rate),
        "-",
    ]
    completed = subprocess.run(command, capture_output=True, check=False)
    if completed.returncode != 0:
        detail = completed.stderr.decode("utf-8", errors="replace").strip()
        raise RuntimeError(f"ffmpeg normalization failed: {detail}")
    pcm = completed.stdout
    if len(pcm) % 2:
        pcm = pcm[:-1]
    if len(pcm) < 2:
        raise RuntimeError("RVC output decoded to empty PCM")
    return sample_rate, pcm


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
    max_bytes = int_env("STACKCHAN_RVC_MAX_AUDIO_BYTES", DEFAULT_MAX_AUDIO_BYTES, 2, 2 * 1024 * 1024)
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
    max_peak = max(max(peaks), 1e-6) if peaks else 1.0
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
        sys.stderr.write("RVC TTS text is empty\n")
        return 2
    with tempfile.TemporaryDirectory() as temp_dir:
        work = Path(temp_dir)
        base_wav = work / "base.wav"
        rvc_wav = work / "rvc.wav"
        try:
            synthesize_base_wav(text, base_wav)
            rvc_elapsed_ms = convert_with_rvc(base_wav, rvc_wav)
            sample_rate, pcm = decode_wav_to_pcm16(rvc_wav)
            pcm = apply_gain(pcm, float_env("STACKCHAN_RVC_GAIN", 1.0, 0.05, 4.0))
            pcm, truncated = trim_pcm(pcm)
            beats = beats_from_pcm(pcm, sample_rate)
        except Exception as exc:
            sys.stderr.write(str(exc) + "\n")
            return 2
    style = tts_delivery_style()
    print(
        json.dumps(
            {
                "schema": "stackchan.tts-metadata.v1",
                "voice": "stackchan-rvc-live",
                "text_bytes": len(text.encode("utf-8")),
                "source": "windows-system-speech+rvc-python",
                "rvc_model": str(rvc_model_path()),
                "rvc_index": str(rvc_index_path()),
                "rvc_elapsed_ms": round(rvc_elapsed_ms, 2),
                "rvc_device": os.environ.get("STACKCHAN_RVC_DEVICE", "cpu:0").strip() or "cpu:0",
                "rvc_f0_method": os.environ.get("STACKCHAN_RVC_F0_METHOD", "harvest").strip() or "harvest",
                "tts_mode": style["mode"],
                "tts_arousal": style["arousal"],
                "tts_valence": style["valence"],
                "base_tts_rate": style["base_tts_rate"],
                "audio_format": "pcm16",
                "sample_rate": sample_rate,
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
