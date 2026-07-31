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
    tts_delivery_style,
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


def synthesize_and_convert(
    text: str,
    *,
    mode: str | None = None,
    arousal: float | None = None,
    valence: float | None = None,
) -> tuple[int, bytes, dict[str, object]]:
    style = tts_delivery_style(mode=mode, arousal=arousal, valence=valence)
    payload = {
        "text": text,
        "voice": os.environ.get("STACKCHAN_RVC_BASE_TTS_VOICE", "").strip(),
        "rate": int(style["base_tts_rate"]),
        "volume": int_env("STACKCHAN_RVC_BASE_TTS_VOLUME", 100, 0, 100),
        "sample_rate": int_env("STACKCHAN_RVC_BASE_TTS_SAMPLE_RATE", 48000, 8000, 48000),
    }
    request = urllib.request.Request(
        worker_url() + "/synthesize",
        data=json.dumps(payload, separators=(",", ":"), ensure_ascii=True).encode("utf-8"),
        headers={"Content-Type": "application/json"},
        method="POST",
    )
    started = time.perf_counter()
    with urllib.request.urlopen(
        request,
        timeout=max(1, int_env("STACKCHAN_RVC_DIRECTML_TIMEOUT_SECONDS", 30, 1, 180)),
    ) as response:
        pcm = response.read()
        headers = response.headers
    sample_rate = int(float(headers.get("X-Stackchan-Sample-Rate", "0") or 0))
    audio_format = str(headers.get("X-Stackchan-Audio-Format", "")).strip().lower()
    if audio_format != "pcm16" or sample_rate <= 0 or not pcm or len(pcm) % 2:
        raise RuntimeError("DirectML synthesis worker returned invalid PCM")
    timings: dict[str, object] = {
        "worker_elapsed_ms": round((time.perf_counter() - started) * 1000.0, 2),
        "base_tts_elapsed_ms": header_float(headers, "X-Stackchan-Base-Tts-Ms"),
        "synthesis_elapsed_ms": header_float(headers, "X-Stackchan-Synthesis-Ms"),
        "infer_elapsed_ms": header_float(headers, "X-Stackchan-Elapsed-Ms"),
        "feature_elapsed_ms": header_float(headers, "X-Stackchan-Feature-Ms"),
        "f0_elapsed_ms": header_float(headers, "X-Stackchan-F0-Ms"),
        "synth_elapsed_ms": header_float(headers, "X-Stackchan-Synth-Ms"),
        "audio_decode_backend": str(
            headers.get("X-Stackchan-Audio-Decode-Backend", "")
        )[:80],
        "audio_decode_elapsed_ms": header_float(
            headers,
            "X-Stackchan-Audio-Decode-Ms",
        ),
    }
    return sample_rate, pcm, timings


def synthesize_directml(
    text: str,
    *,
    mode: str | None = None,
    arousal: float | None = None,
    valence: float | None = None,
) -> dict[str, object]:
    adapter_started = time.perf_counter()
    if not text:
        raise ValueError("DirectML RVC TTS text is empty")
    with tempfile.TemporaryDirectory(prefix="stackchan_directml_tts_") as temp_dir:
        work = Path(temp_dir)
        base_wav = work / "base.wav"
        converted_wav = work / "converted.wav"
        persistent_base_tts = True
        persistent_error = ""
        try:
            sample_rate, pcm, timings = synthesize_and_convert(
                text,
                mode=mode,
                arousal=arousal,
                valence=valence,
            )
            base_elapsed_ms = float(timings["base_tts_elapsed_ms"])
            decode_backend = str(timings["audio_decode_backend"])
            decode_elapsed_ms = float(timings["audio_decode_elapsed_ms"])
        except Exception as exc:
            persistent_base_tts = False
            persistent_error = f"{type(exc).__name__}: {exc}"[:240]
            base_started = time.perf_counter()
            synthesize_base_wav(
                text,
                base_wav,
                mode=mode,
                arousal=arousal,
                valence=valence,
            )
            base_elapsed_ms = (time.perf_counter() - base_started) * 1000.0
            timings = convert(base_wav, converted_wav)
            decode_started = time.perf_counter()
            sample_rate, pcm = decode_wav_to_pcm16(converted_wav)
            decode_backend = "ffmpeg"
            decode_elapsed_ms = (time.perf_counter() - decode_started) * 1000.0
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
        "base_tts_backend": (
            "persistent-system-speech"
            if persistent_base_tts
            else "one-shot-system-speech"
        ),
        "base_tts_fallback_reason": persistent_error,
        "audio_decode_backend": decode_backend,
        "audio_decode_elapsed_ms": round(decode_elapsed_ms, 2),
        "rvc_synthesis_elapsed_ms": timings.get("synthesis_elapsed_ms", 0.0),
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
