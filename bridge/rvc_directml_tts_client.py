#!/usr/bin/env python3
"""Stackchan TTS adapter for the raw-WAV DirectML voice-v2 worker."""

from __future__ import annotations

import base64
import json
import os
import sys
import tempfile
import time
import urllib.request
from pathlib import Path

from rvc_tts import (
    apply_gain,
    beats_from_pcm,
    decode_wav_to_pcm16,
    float_env,
    int_env,
    rvc_index_path,
    rvc_model_path,
    synthesize_base_wav,
    trim_pcm,
)


DEFAULT_WORKER_URL = "http://127.0.0.1:5059"


def worker_url() -> str:
    return os.environ.get("STACKCHAN_RVC_DIRECTML_WORKER_URL", DEFAULT_WORKER_URL).rstrip("/")


def header_float(headers, name: str) -> float:
    try:
        return float(headers.get(name, "0") or 0.0)
    except (TypeError, ValueError):
        return 0.0


def convert(input_wav: Path, output_wav: Path) -> dict[str, float]:
    request = urllib.request.Request(
        worker_url() + "/convert",
        data=input_wav.read_bytes(),
        headers={"Content-Type": "audio/wav"},
        method="POST",
    )
    started = time.perf_counter()
    with urllib.request.urlopen(
        request,
        timeout=max(1, int_env("STACKCHAN_RVC_DIRECTML_TIMEOUT_SECONDS", 30, 1, 180)),
    ) as response:
        output_wav.write_bytes(response.read())
        headers = response.headers
    return {
        "worker_elapsed_ms": round((time.perf_counter() - started) * 1000.0, 2),
        "infer_elapsed_ms": header_float(headers, "X-Stackchan-Elapsed-Ms"),
        "feature_elapsed_ms": header_float(headers, "X-Stackchan-Feature-Ms"),
        "f0_elapsed_ms": header_float(headers, "X-Stackchan-F0-Ms"),
        "synth_elapsed_ms": header_float(headers, "X-Stackchan-Synth-Ms"),
    }


def synthesize_directml(text: str) -> dict[str, object]:
    adapter_started = time.perf_counter()
    if not text:
        raise ValueError("DirectML RVC TTS text is empty")
    with tempfile.TemporaryDirectory(prefix="stackchan_directml_tts_") as temp_dir:
        work = Path(temp_dir)
        base_wav = work / "base.wav"
        converted_wav = work / "converted.wav"
        base_started = time.perf_counter()
        synthesize_base_wav(text, base_wav)
        base_elapsed_ms = (time.perf_counter() - base_started) * 1000.0
        timings = convert(base_wav, converted_wav)
        sample_rate, pcm = decode_wav_to_pcm16(converted_wav)
        pcm = apply_gain(pcm, float_env("STACKCHAN_RVC_GAIN", 1.0, 0.05, 4.0))
        pcm, truncated = trim_pcm(pcm)
        if truncated and os.environ.get("STACKCHAN_RVC_ALLOW_TRUNCATION", "").strip() != "1":
            raise RuntimeError("DirectML RVC output exceeded the configured audio limit; refusing truncation")
        beats = beats_from_pcm(pcm, sample_rate)
    return {
        "schema": "stackchan.tts-metadata.v1",
        "voice": "stackchan-rvc-directml-v2",
        "text_bytes": len(text.encode("utf-8")),
        "source": "windows-system-speech+rvc-directml-worker",
        "rvc_model": str(rvc_model_path()),
        "rvc_index": str(rvc_index_path()),
        "rvc_elapsed_ms": timings["infer_elapsed_ms"],
        "rvc_worker_elapsed_ms": timings["worker_elapsed_ms"],
        "rvc_infer_elapsed_ms": timings["infer_elapsed_ms"],
        "rvc_feature_elapsed_ms": timings["feature_elapsed_ms"],
        "rvc_f0_elapsed_ms": timings["f0_elapsed_ms"],
        "rvc_synth_elapsed_ms": timings["synth_elapsed_ms"],
        "base_tts_elapsed_ms": round(base_elapsed_ms, 2),
        "rvc_adapter_elapsed_ms": round((time.perf_counter() - adapter_started) * 1000.0, 2),
        "rvc_device": "privateuseone:0",
        "rvc_f0_method": "pm",
        "audio_format": "pcm16",
        "sample_rate": sample_rate,
        "audio_bytes": len(pcm),
        "audio_truncated": truncated,
        "beats": beats,
        "audio_b64": base64.b64encode(pcm).decode("ascii"),
    }


def main() -> int:
    text = " ".join(sys.stdin.buffer.read().decode("utf-8", errors="replace").split())
    try:
        result = synthesize_directml(text)
    except Exception as exc:
        sys.stderr.write(str(exc) + "\n")
        return 2
    print(json.dumps(result, separators=(",", ":"), ensure_ascii=True))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
