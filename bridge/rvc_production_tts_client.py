#!/usr/bin/env python3
"""Fast DirectML Stackchan voice with a bounded clear-speech fallback."""

from __future__ import annotations

import base64
import json
import os
import sys
import tempfile
import time
from pathlib import Path

from rvc_directml_tts_client import synthesize_directml
from rvc_tts import apply_gain, beats_from_pcm, decode_wav_to_pcm16, float_env, synthesize_base_wav, trim_pcm


def synthesize_base_fallback(text: str, reason: str) -> dict[str, object]:
    started = time.perf_counter()
    with tempfile.TemporaryDirectory(prefix="stackchan_voice_fallback_") as temp_dir:
        wav_path = Path(temp_dir) / "base.wav"
        synthesize_base_wav(text, wav_path)
        sample_rate, pcm = decode_wav_to_pcm16(wav_path)
    pcm = apply_gain(pcm, float_env("STACKCHAN_RVC_GAIN", 1.0, 0.05, 4.0))
    pcm, truncated = trim_pcm(pcm)
    if truncated and os.environ.get("STACKCHAN_RVC_ALLOW_TRUNCATION", "").strip() != "1":
        raise RuntimeError("Fallback TTS exceeded the configured audio limit; refusing truncation")
    return {
        "schema": "stackchan.tts-metadata.v1",
        "voice": "stackchan-clear-local-fallback",
        "text_bytes": len(text.encode("utf-8")),
        "source": "windows-system-speech-directml-fallback",
        "voice_backend": "clear-local-fallback",
        "voice_fallback": True,
        "voice_fallback_reason": reason[:240],
        "voice_adapter_elapsed_ms": round((time.perf_counter() - started) * 1000.0, 2),
        "audio_format": "pcm16",
        "sample_rate": sample_rate,
        "audio_bytes": len(pcm),
        "audio_truncated": truncated,
        "beats": beats_from_pcm(pcm, sample_rate),
        "audio_b64": base64.b64encode(pcm).decode("ascii"),
    }


def synthesize_production(text: str) -> dict[str, object]:
    try:
        result = synthesize_directml(text)
        result["voice_backend"] = "directml"
        result["voice_fallback"] = False
        return result
    except Exception as exc:
        if os.environ.get("STACKCHAN_VOICE_REQUIRE_DIRECTML", "").strip() == "1":
            raise
        return synthesize_base_fallback(text, f"{type(exc).__name__}: {exc}")


def main() -> int:
    text = " ".join(sys.stdin.buffer.read().decode("utf-8", errors="replace").split())
    if not text:
        sys.stderr.write("Production TTS text is empty\n")
        return 2
    try:
        result = synthesize_production(text)
    except Exception as exc:
        sys.stderr.write(str(exc) + "\n")
        return 2
    print(json.dumps(result, separators=(",", ":"), ensure_ascii=True))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
