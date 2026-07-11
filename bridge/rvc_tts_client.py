#!/usr/bin/env python3
"""TTS adapter that talks to a warm local RVC worker."""

from __future__ import annotations

import base64
import json
import os
import sys
import tempfile
import time
import urllib.error
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


DEFAULT_WORKER_URL = "http://127.0.0.1:5055"


def worker_url() -> str:
    return os.environ.get("STACKCHAN_RVC_WORKER_URL", DEFAULT_WORKER_URL).rstrip("/")


def convert_with_worker(input_wav: Path, output_wav: Path) -> tuple[float, dict[str, object]]:
    payload = json.dumps(
        {"wav_b64": base64.b64encode(input_wav.read_bytes()).decode("ascii")},
        separators=(",", ":"),
    ).encode("utf-8")
    request = urllib.request.Request(
        worker_url() + "/convert",
        data=payload,
        headers={"Content-Type": "application/json"},
        method="POST",
    )
    start = time.perf_counter()
    try:
        with urllib.request.urlopen(
            request,
            timeout=max(1, int_env("STACKCHAN_RVC_WORKER_TIMEOUT_SECONDS", 120, 1, 600)),
        ) as response:
            result = json.loads(response.read().decode("utf-8"))
    except urllib.error.HTTPError as exc:
        detail = exc.read().decode("utf-8", errors="replace")
        raise RuntimeError(f"RVC worker HTTP {exc.code}: {detail}") from exc
    elapsed_ms = (time.perf_counter() - start) * 1000.0
    if not result.get("ok"):
        raise RuntimeError(f"RVC worker failed: {result.get('error', 'unknown')}")
    output_wav.write_bytes(base64.b64decode(str(result.get("wav_b64", "")), validate=True))
    return elapsed_ms, result


def main() -> int:
    adapter_start = time.perf_counter()
    text = " ".join(sys.stdin.buffer.read().decode("utf-8", errors="replace").split())
    if not text:
        sys.stderr.write("RVC worker TTS text is empty\n")
        return 2
    with tempfile.TemporaryDirectory() as temp_dir:
        work = Path(temp_dir)
        base_wav = work / "base.wav"
        rvc_wav = work / "rvc.wav"
        try:
            base_start = time.perf_counter()
            synthesize_base_wav(text, base_wav)
            base_elapsed_ms = (time.perf_counter() - base_start) * 1000.0
            worker_elapsed_ms, worker_result = convert_with_worker(base_wav, rvc_wav)
            sample_rate, pcm = decode_wav_to_pcm16(rvc_wav)
            pcm = apply_gain(pcm, float_env("STACKCHAN_RVC_GAIN", 1.0, 0.05, 4.0))
            pcm, truncated = trim_pcm(pcm)
            beats = beats_from_pcm(pcm, sample_rate)
        except Exception as exc:
            sys.stderr.write(str(exc) + "\n")
            return 2
    print(
        json.dumps(
            {
                "schema": "stackchan.tts-metadata.v1",
                "voice": "stackchan-rvc-live",
                "text_bytes": len(text.encode("utf-8")),
                "source": "windows-system-speech+rvc-worker",
                "rvc_model": str(rvc_model_path()),
                "rvc_index": str(rvc_index_path()),
                "rvc_elapsed_ms": worker_result.get("convert_elapsed_ms", round(worker_elapsed_ms, 2)),
                "rvc_worker_elapsed_ms": round(worker_elapsed_ms, 2),
                "base_tts_elapsed_ms": round(base_elapsed_ms, 2),
                "rvc_queue_wait_ms": worker_result.get("queue_wait_ms", 0.0),
                "rvc_infer_elapsed_ms": worker_result.get("infer_elapsed_ms", 0.0),
                "rvc_adapter_elapsed_ms": round((time.perf_counter() - adapter_start) * 1000.0, 2),
                "rvc_device": worker_result.get("device", os.environ.get("STACKCHAN_RVC_DEVICE", "cuda:0")),
                "rvc_f0_method": worker_result.get("method", os.environ.get("STACKCHAN_RVC_F0_METHOD", "pm")),
                "rvc_worker_url": worker_url(),
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
