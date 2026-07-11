#!/usr/bin/env python3
"""Headless official-RVC DirectML runtime shared by the worker and benchmark."""

from __future__ import annotations

import io
import os
import re
import sys
import tempfile
import time
from contextlib import contextmanager
from pathlib import Path

import numpy as np
import soundfile as sf


TIMING_PATTERN = re.compile(
    r"npy:\s*([0-9.]+)s,\s*f0:\s*([0-9.]+)s,\s*infer:\s*([0-9.]+)s",
    flags=re.IGNORECASE,
)


@contextmanager
def working_directory(path: Path):
    previous = Path.cwd()
    os.chdir(path)
    try:
        yield
    finally:
        os.chdir(previous)


def parse_stage_timings(info: str) -> dict[str, float]:
    match = TIMING_PATTERN.search(info)
    if not match:
        return {}
    return {
        "feature_seconds": float(match.group(1)),
        "f0_seconds": float(match.group(2)),
        "synth_seconds": float(match.group(3)),
    }


class DirectMlRvcRuntime:
    def __init__(
        self,
        *,
        vendor_root: Path,
        model_path: Path,
        index_path: Path,
        f0_method: str = "pm",
        index_rate: float = 0.62,
        pitch: int = 2,
        rms_mix_rate: float = 0.72,
        protect: float = 0.28,
        warmup: bool = True,
    ) -> None:
        self.vendor_root = vendor_root.resolve()
        self.model_path = model_path.resolve()
        self.index_path = index_path.resolve()
        self.f0_method = f0_method
        self.index_rate = max(0.0, min(1.0, float(index_rate)))
        self.pitch = max(-24, min(24, int(pitch)))
        self.rms_mix_rate = max(0.0, min(1.0, float(rms_mix_rate)))
        self.protect = max(0.0, min(0.5, float(protect)))
        for path in (self.vendor_root, self.model_path, self.index_path):
            if not path.exists():
                raise FileNotFoundError(path)

        os.environ["weight_root"] = str(self.model_path.parent)
        os.environ["index_root"] = str(self.index_path.parent)
        os.environ["outside_index_root"] = str(self.index_path.parent)
        os.environ["rmvpe_root"] = str(
            Path(r"C:\stackchan_rocm_venv\Lib\site-packages\rvc_python\base_model")
        )
        if str(self.vendor_root) not in sys.path:
            sys.path.insert(0, str(self.vendor_root))

        previous_argv = sys.argv
        sys.argv = [str(self.vendor_root / "voice_v2_directml_runtime.py"), "--dml", "--noautoopen"]
        load_started = time.perf_counter()
        try:
            with working_directory(self.vendor_root):
                from configs.config import Config
                from infer.modules.vc.modules import VC

                self.config = Config()
                self.vc = VC(self.config)
                self.vc.get_vc(self.model_path.name)
        finally:
            sys.argv = previous_argv
        self.load_seconds = time.perf_counter() - load_started
        self.warmup_record: dict[str, object] = {}
        if warmup:
            self.warmup_record = self._warmup()

    @property
    def device(self) -> str:
        return str(self.config.device)

    def _warmup(self) -> dict[str, object]:
        sample_rate = 16000
        duration_seconds = 1.2
        samples = np.arange(int(sample_rate * duration_seconds), dtype=np.float32)
        audio = (0.04 * np.sin(2.0 * np.pi * 220.0 * samples / sample_rate)).astype(np.float32)
        with tempfile.TemporaryDirectory(prefix="stackchan_dml_warmup_") as temp_dir:
            input_path = Path(temp_dir) / "warmup.wav"
            sf.write(str(input_path), audio, sample_rate, subtype="PCM_16")
            _, _, record = self.convert_file(input_path)
        return record

    def convert_file(self, input_path: Path) -> tuple[int, np.ndarray, dict[str, object]]:
        started = time.perf_counter()
        with working_directory(self.vendor_root):
            info, converted = self.vc.vc_single(
                0,
                str(input_path.resolve()),
                self.pitch,
                None,
                self.f0_method,
                str(self.index_path),
                "",
                self.index_rate,
                3,
                0,
                self.rms_mix_rate,
                self.protect,
            )
        elapsed_seconds = time.perf_counter() - started
        if not isinstance(converted, tuple) or len(converted) != 2 or converted[1] is None:
            raise RuntimeError(f"DirectML RVC conversion failed: {info}")
        sample_rate, audio = converted
        record: dict[str, object] = {
            "elapsed_seconds": round(elapsed_seconds, 4),
            "sample_rate": int(sample_rate),
            "audio_samples": int(len(audio)),
            "audio_seconds": round(len(audio) / float(sample_rate), 4),
        }
        record.update(parse_stage_timings(str(info)))
        return int(sample_rate), audio, record

    def convert_wav_bytes(self, wav_bytes: bytes) -> tuple[bytes, dict[str, object]]:
        with tempfile.TemporaryDirectory(prefix="stackchan_dml_convert_") as temp_dir:
            input_path = Path(temp_dir) / "input.wav"
            input_path.write_bytes(wav_bytes)
            sample_rate, audio, record = self.convert_file(input_path)
        output = io.BytesIO()
        sf.write(output, audio, sample_rate, format="WAV", subtype="PCM_16")
        return output.getvalue(), record
