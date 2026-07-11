#!/usr/bin/env python3
"""Benchmark the official RVC DirectML path with Stackchan's owned voice assets."""

from __future__ import annotations

import argparse
import json
import os
import re
import statistics
import sys
import tempfile
import time
from contextlib import contextmanager
from pathlib import Path

import soundfile as sf

from rvc_tts import synthesize_base_wav


CORPUS = (
    ("hello", "Hello."),
    ("identity", "I am Stackchan."),
    ("status", "My systems are online and ready."),
    (
        "normal",
        "I am Stackchan. My systems are online, and I am happy to explore this with you.",
    ),
)
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


def absolute(path: Path) -> Path:
    return path.expanduser().resolve()


def configure_official_rvc(vendor_root: Path, model: Path, index: Path):
    os.environ["weight_root"] = str(model.parent)
    os.environ["index_root"] = str(index.parent)
    os.environ["outside_index_root"] = str(index.parent)
    os.environ["rmvpe_root"] = str(
        Path(r"C:\stackchan_rocm_venv\Lib\site-packages\rvc_python\base_model")
    )
    sys.path.insert(0, str(vendor_root))
    previous_argv = sys.argv
    sys.argv = [str(vendor_root / "voice_v2_directml_benchmark.py"), "--dml", "--noautoopen"]
    try:
        from configs.config import Config
        from infer.modules.vc.modules import VC

        config = Config()
        vc = VC(config)
        vc.get_vc(model.name)
        return config, vc
    finally:
        sys.argv = previous_argv


def parse_stage_timings(info: str) -> dict[str, float]:
    match = TIMING_PATTERN.search(info)
    if not match:
        return {}
    return {
        "feature_seconds": float(match.group(1)),
        "f0_seconds": float(match.group(2)),
        "synth_seconds": float(match.group(3)),
    }


def render_case(
    vc,
    *,
    case_id: str,
    text: str,
    index: Path,
    output_dir: Path,
    f0_method: str,
    index_rate: float,
    pitch: int,
) -> dict[str, object]:
    with tempfile.TemporaryDirectory(prefix="stackchan_dml_bench_") as temp_dir:
        input_wav = Path(temp_dir) / "base.wav"
        synthesize_base_wav(text, input_wav)
        started = time.perf_counter()
        info, converted = vc.vc_single(
            0,
            str(input_wav),
            pitch,
            None,
            f0_method,
            str(index),
            "",
            index_rate,
            3,
            0,
            0.72,
            0.28,
        )
        elapsed_seconds = time.perf_counter() - started
    if not isinstance(converted, tuple) or len(converted) != 2 or converted[1] is None:
        raise RuntimeError(f"DirectML conversion failed for {case_id}: {info}")
    sample_rate, audio = converted
    output_wav = output_dir / f"{case_id}.wav"
    sf.write(str(output_wav), audio, int(sample_rate), subtype="PCM_16")
    audio_seconds = len(audio) / float(sample_rate)
    record: dict[str, object] = {
        "case": case_id,
        "text": text,
        "elapsed_seconds": round(elapsed_seconds, 4),
        "audio_seconds": round(audio_seconds, 4),
        "realtime_factor": round(elapsed_seconds / max(audio_seconds, 0.001), 4),
        "sample_rate": int(sample_rate),
        "audio_samples": int(len(audio)),
        "audio_truncated": False,
        "output_wav": str(output_wav),
    }
    record.update(parse_stage_timings(str(info)))
    return record


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--vendor-root", type=Path, required=True)
    parser.add_argument("--model", type=Path, required=True)
    parser.add_argument("--index", type=Path, required=True)
    parser.add_argument("--output-dir", type=Path, required=True)
    parser.add_argument("--f0-method", choices=("pm", "harvest", "crepe", "rmvpe"), default="rmvpe")
    parser.add_argument("--index-rate", type=float, default=0.62)
    parser.add_argument("--pitch", type=int, default=2)
    parser.add_argument("--max-first-audio-seconds", type=float, default=3.0)
    parser.add_argument("--max-median-realtime-factor", type=float, default=1.0)
    parser.add_argument("--json", action="store_true")
    return parser


def main() -> int:
    args = build_parser().parse_args()
    repo_root = Path(__file__).resolve().parents[1]
    vendor_root = absolute(args.vendor_root)
    model = absolute(args.model)
    index = absolute(args.index)
    output_dir = absolute(args.output_dir)
    for path in (vendor_root, model, index):
        if not path.exists():
            raise FileNotFoundError(path)
    output_dir.mkdir(parents=True, exist_ok=True)

    started = time.perf_counter()
    with working_directory(vendor_root):
        config, vc = configure_official_rvc(vendor_root, model, index)
        load_seconds = time.perf_counter() - started
        warmup = render_case(
            vc,
            case_id="warmup",
            text="Hello.",
            index=index,
            output_dir=output_dir,
            f0_method=args.f0_method,
            index_rate=max(0.0, min(1.0, args.index_rate)),
            pitch=args.pitch,
        )
        records = [
            render_case(
                vc,
                case_id=case_id,
                text=text,
                index=index,
                output_dir=output_dir,
                f0_method=args.f0_method,
                index_rate=max(0.0, min(1.0, args.index_rate)),
                pitch=args.pitch,
            )
            for case_id, text in CORPUS
        ]

    median_rtf = statistics.median(float(item["realtime_factor"]) for item in records)
    first_audio_seconds = float(records[0]["elapsed_seconds"])
    checks = {
        "first_audio_under_gate": first_audio_seconds <= args.max_first_audio_seconds,
        "median_faster_than_realtime": median_rtf <= args.max_median_realtime_factor,
        "zero_truncation": not any(bool(item["audio_truncated"]) for item in records),
    }
    report = {
        "schema": "stackchan.voice-v2-directml-benchmark.v1",
        "status": "pass" if all(checks.values()) else "fail",
        "backend": "torch-directml",
        "device": str(config.device),
        "torch_half": bool(config.is_half),
        "model": str(model),
        "index": str(index),
        "f0_method": args.f0_method,
        "index_rate": max(0.0, min(1.0, args.index_rate)),
        "load_seconds": round(load_seconds, 4),
        "warmup": warmup,
        "records": records,
        "first_audio_seconds": round(first_audio_seconds, 4),
        "median_realtime_factor": round(median_rtf, 4),
        "gates": {
            "max_first_audio_seconds": args.max_first_audio_seconds,
            "max_median_realtime_factor": args.max_median_realtime_factor,
        },
        "checks": checks,
        "repo_root": str(repo_root),
    }
    report_path = output_dir / "benchmark.json"
    report_path.write_text(json.dumps(report, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    if args.json:
        print(json.dumps(report, separators=(",", ":")))
    else:
        print(f"status={report['status']} first_audio={first_audio_seconds:.3f}s median_rtf={median_rtf:.3f}")
    return 0 if report["status"] == "pass" else 3


if __name__ == "__main__":
    raise SystemExit(main())
