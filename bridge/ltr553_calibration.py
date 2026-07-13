#!/usr/bin/env python3
"""Capture and analyze passive LTR-553 proximity calibration evidence."""

from __future__ import annotations

import argparse
import json
import tempfile
import time
import urllib.error
import urllib.request
from pathlib import Path
from typing import Iterable


CAPTURE_SCHEMA = "stackchan.ltr553-capture.v1"
CALIBRATION_SCHEMA = "stackchan.ltr553-calibration.v1"
DEFAULT_DEBUG_URL = "http://192.168.1.238:8789/debug"
DEFAULT_MIN_SAMPLES = 30


def _percentile(values: Iterable[int], quantile: float) -> int:
    ordered = sorted(int(value) for value in values)
    if not ordered:
        return 0
    index = round((len(ordered) - 1) * max(0.0, min(1.0, quantile)))
    return ordered[index]


def _sample_stats(samples: list[dict[str, object]]) -> dict[str, int]:
    proximity = [int(sample["proximity_raw"]) for sample in samples]
    ambient = [int(sample.get("ambient_combined_raw", 0)) for sample in samples]
    read_failures = [int(sample.get("read_failures", 0)) for sample in samples]
    return {
        "count": len(samples),
        "proximity_min": min(proximity, default=0),
        "proximity_p10": _percentile(proximity, 0.10),
        "proximity_p50": _percentile(proximity, 0.50),
        "proximity_p90": _percentile(proximity, 0.90),
        "proximity_max": max(proximity, default=0),
        "ambient_min": min(ambient, default=0),
        "ambient_p50": _percentile(ambient, 0.50),
        "ambient_max": max(ambient, default=0),
        "read_failures_min": min(read_failures, default=0),
        "read_failures_max": max(read_failures, default=0),
    }


def accepted_sample(payload: dict[str, object]) -> tuple[dict[str, object] | None, str]:
    if not bool(payload.get("compiled_enable_proximity_ambient", False)):
        return None, "adapter_not_compiled"
    if not bool(payload.get("proximity_ambient_ready", False)):
        return None, "adapter_not_ready"
    if bool(payload.get("proximity_saturated", False)):
        return None, "proximity_saturated"
    try:
        proximity = int(payload["proximity_raw"])
        ambient = int(payload.get("ambient_combined_raw", 0))
        failures = int(payload.get("proximity_ambient_read_failures", 0))
        consecutive = int(payload.get("proximity_ambient_consecutive_failures", 0))
    except (KeyError, TypeError, ValueError):
        return None, "sample_fields_invalid"
    if not 0 <= proximity <= 2047 or not 0 <= ambient <= 65535:
        return None, "sample_out_of_range"
    if consecutive != 0:
        return None, "active_read_failure"
    return {
        "captured_at_unix_ms": int(time.time() * 1000),
        "proximity_raw": proximity,
        "ambient_combined_raw": ambient,
        "read_failures": failures,
        "power_vbus_mv": int(payload.get("power_vbus_mv", 0) or 0),
        "chip_temp_c": float(payload.get("chip_temp_c", 0.0) or 0.0),
    }, ""


def analyze_samples(
    far_samples: list[dict[str, object]],
    near_samples: list[dict[str, object]],
    *,
    min_samples: int = DEFAULT_MIN_SAMPLES,
) -> dict[str, object]:
    far_stats = _sample_stats(far_samples)
    near_stats = _sample_stats(near_samples)
    issues: list[str] = []
    if len(far_samples) < min_samples:
        issues.append("far_samples_insufficient")
    if len(near_samples) < min_samples:
        issues.append("near_samples_insufficient")
    if far_stats["read_failures_max"] > far_stats["read_failures_min"]:
        issues.append("far_read_failures_increased")
    if near_stats["read_failures_max"] > near_stats["read_failures_min"]:
        issues.append("near_read_failures_increased")

    far_edge = int(far_stats["proximity_p90"])
    near_edge = int(near_stats["proximity_p10"])
    separation = near_edge - far_edge
    if separation <= 0:
        issues.append("near_far_distributions_overlap")
    elif separation < 16:
        issues.append("near_far_margin_too_small")

    suggested: dict[str, object] = {}
    if not issues:
        exit_threshold = far_edge + separation // 3
        enter_threshold = far_edge + (2 * separation) // 3
        suggested = {
            "enter_threshold": enter_threshold,
            "exit_threshold": exit_threshold,
            "enter_samples": 2,
            "exit_samples": 4,
            "platformio_defines": [
                f"STACKCHAN_LTR553_NEAR_ENTER_THRESHOLD={enter_threshold}",
                f"STACKCHAN_LTR553_NEAR_EXIT_THRESHOLD={exit_threshold}",
            ],
        }

    return {
        "schema": CALIBRATION_SCHEMA,
        "ok": not issues,
        "issues": issues,
        "minimum_samples_per_label": min_samples,
        "far": far_stats,
        "near": near_stats,
        "robust_separation": separation,
        "suggested": suggested,
        "automatic_firmware_change": False,
    }


def _write_json_atomic(path: Path, payload: dict[str, object]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    rendered = json.dumps(payload, indent=2, sort_keys=True) + "\n"
    with tempfile.NamedTemporaryFile(
        "w", encoding="utf-8", newline="\n", dir=path.parent, delete=False
    ) as handle:
        handle.write(rendered)
        temporary = Path(handle.name)
    temporary.replace(path)


def capture_samples(
    *,
    url: str,
    label: str,
    duration_seconds: float,
    poll_seconds: float,
) -> dict[str, object]:
    samples: list[dict[str, object]] = []
    rejected: dict[str, int] = {}
    started = time.monotonic()
    while time.monotonic() - started < duration_seconds:
        try:
            with urllib.request.urlopen(url, timeout=max(1.0, poll_seconds * 2.0)) as response:
                payload = json.loads(response.read().decode("utf-8"))
            if not isinstance(payload, dict):
                raise ValueError("debug response is not an object")
            sample, reason = accepted_sample(payload)
        except (OSError, ValueError, json.JSONDecodeError, urllib.error.URLError) as exc:
            sample, reason = None, f"debug_request_failed:{type(exc).__name__}"
        if sample is None:
            rejected[reason] = rejected.get(reason, 0) + 1
        else:
            samples.append(sample)
        time.sleep(max(0.05, poll_seconds))
    return {
        "schema": CAPTURE_SCHEMA,
        "label": label,
        "debug_url": url,
        "duration_seconds": round(time.monotonic() - started, 3),
        "poll_seconds": poll_seconds,
        "accepted_samples": len(samples),
        "rejected_samples": sum(rejected.values()),
        "rejected_reasons": rejected,
        "samples": samples,
    }


def _load_capture(path: Path, expected_label: str) -> list[dict[str, object]]:
    payload = json.loads(path.read_text(encoding="utf-8"))
    if not isinstance(payload, dict) or payload.get("schema") != CAPTURE_SCHEMA:
        raise ValueError(f"invalid LTR-553 capture: {path}")
    if payload.get("label") != expected_label:
        raise ValueError(f"expected {expected_label} capture: {path}")
    samples = payload.get("samples")
    if not isinstance(samples, list) or not all(isinstance(sample, dict) for sample in samples):
        raise ValueError(f"capture samples invalid: {path}")
    return samples


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    subparsers = parser.add_subparsers(dest="command", required=True)
    capture = subparsers.add_parser("capture", help="Capture one labeled passive sample set.")
    capture.add_argument("--label", choices=("far", "near"), required=True)
    capture.add_argument("--url", default=DEFAULT_DEBUG_URL)
    capture.add_argument("--duration-seconds", type=float, default=30.0)
    capture.add_argument("--poll-seconds", type=float, default=0.2)
    capture.add_argument("--output", type=Path, required=True)

    analyze = subparsers.add_parser("analyze", help="Analyze far and near capture files.")
    analyze.add_argument("--far", type=Path, required=True)
    analyze.add_argument("--near", type=Path, required=True)
    analyze.add_argument("--minimum-samples", type=int, default=DEFAULT_MIN_SAMPLES)
    analyze.add_argument("--output", type=Path)

    args = parser.parse_args()
    if args.command == "capture":
        payload = capture_samples(
            url=args.url,
            label=args.label,
            duration_seconds=max(1.0, args.duration_seconds),
            poll_seconds=max(0.05, args.poll_seconds),
        )
        _write_json_atomic(args.output.resolve(), payload)
        print(json.dumps(payload, indent=2, sort_keys=True))
        return 0 if payload["accepted_samples"] > 0 else 1

    try:
        far_samples = _load_capture(args.far.resolve(), "far")
        near_samples = _load_capture(args.near.resolve(), "near")
        payload = analyze_samples(
            far_samples,
            near_samples,
            min_samples=max(5, args.minimum_samples),
        )
    except (OSError, ValueError, json.JSONDecodeError) as exc:
        payload = {"schema": CALIBRATION_SCHEMA, "ok": False, "issues": [str(exc)]}
    if args.output:
        _write_json_atomic(args.output.resolve(), payload)
    print(json.dumps(payload, indent=2, sort_keys=True))
    return 0 if payload.get("ok") else 1


if __name__ == "__main__":
    raise SystemExit(main())
