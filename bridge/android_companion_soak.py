#!/usr/bin/env python3
"""Run a screen-off soak against an Android Stackchan Companion bridge endpoint."""

from __future__ import annotations

import argparse
import json
import sys
import time
from pathlib import Path
from typing import Any, Callable

from android_companion_probe import build_report, utc_timestamp

SCHEMA = "stackchan.android-companion-soak.v1"
DEFAULT_DURATION_SECONDS = 600.0
DEFAULT_INTERVAL_SECONDS = 30.0

ProbeFn = Callable[[str, float, bool], dict[str, Any]]
SleepFn = Callable[[float], None]
MonotonicFn = Callable[[], float]


def _sample_from_probe(index: int, probe_report: dict[str, Any]) -> dict[str, Any]:
    endpoint_hello = probe_report.get("endpoint_hello")
    endpoint_id = ""
    endpoint_kind = ""
    if isinstance(endpoint_hello, dict):
        endpoint_id = str(endpoint_hello.get("endpoint_id", ""))
        endpoint_kind = str(endpoint_hello.get("endpoint_kind", ""))
    return {
        "index": index,
        "generated_at": utc_timestamp(),
        "status": probe_report.get("status", "fail"),
        "elapsed_ms": probe_report.get("elapsed_ms"),
        "endpoint_id": endpoint_id,
        "endpoint_kind": endpoint_kind,
        "issues": list(probe_report.get("issues", [])),
    }


def evaluate_samples(
    samples: list[dict[str, Any]], min_success_rate: float, max_failures: int
) -> tuple[str, list[str], int, int, float]:
    passed_count = sum(1 for sample in samples if sample.get("status") == "pass")
    failed_count = len(samples) - passed_count
    success_rate = passed_count / len(samples) if samples else 0.0
    issues: list[str] = []
    if not samples:
        issues.append("no soak samples were captured")
    if failed_count > max_failures:
        issues.append(f"failed samples {failed_count} exceeded max failures {max_failures}")
    if success_rate < min_success_rate:
        issues.append(f"success rate {success_rate:.3f} was below required {min_success_rate:.3f}")
    for sample in samples:
        if sample.get("status") != "pass":
            sample_issues = sample.get("issues", [])
            detail = "; ".join(str(issue) for issue in sample_issues) if sample_issues else "probe failed"
            issues.append(f"sample {sample.get('index')} failed: {detail}")
    return ("pass" if not issues else "fail", issues, passed_count, failed_count, success_rate)


def build_soak_report(
    url_value: str,
    duration_seconds: float,
    interval_seconds: float,
    timeout: float,
    require_android: bool,
    min_success_rate: float,
    max_failures: int,
    sleep_fn: SleepFn = time.sleep,
    monotonic_fn: MonotonicFn = time.monotonic,
    probe_fn: ProbeFn = build_report,
) -> dict[str, Any]:
    report: dict[str, Any] = {
        "schema": SCHEMA,
        "generated_at": utc_timestamp(),
        "url": url_value,
        "requested_duration_seconds": duration_seconds,
        "interval_seconds": interval_seconds,
        "timeout_seconds": timeout,
        "min_success_rate": min_success_rate,
        "max_failures": max_failures,
        "status": "fail",
        "issues": [],
        "samples": [],
    }
    config_issues = []
    if duration_seconds < 0:
        config_issues.append("duration_seconds must be >= 0")
    if interval_seconds <= 0:
        config_issues.append("interval_seconds must be > 0")
    if timeout <= 0:
        config_issues.append("timeout must be > 0")
    if min_success_rate < 0 or min_success_rate > 1:
        config_issues.append("min_success_rate must be between 0 and 1")
    if max_failures < 0:
        config_issues.append("max_failures must be >= 0")
    if config_issues:
        report["issues"] = config_issues
        return report

    started = monotonic_fn()
    deadline = started + duration_seconds
    samples: list[dict[str, Any]] = []
    index = 1
    while True:
        probe_report = probe_fn(url_value, timeout, require_android)
        samples.append(_sample_from_probe(index, probe_report))
        now = monotonic_fn()
        if now >= deadline:
            break
        sleep_for = min(interval_seconds, max(0.0, deadline - now))
        if sleep_for > 0:
            sleep_fn(sleep_for)
        index += 1

    elapsed_seconds = max(0.0, monotonic_fn() - started)
    status, issues, passed_count, failed_count, success_rate = evaluate_samples(
        samples, min_success_rate=min_success_rate, max_failures=max_failures
    )
    report.update(
        {
            "elapsed_seconds": round(elapsed_seconds, 3),
            "sample_count": len(samples),
            "passed_count": passed_count,
            "failed_count": failed_count,
            "success_rate": round(success_rate, 3),
            "status": status,
            "issues": issues,
            "samples": samples,
        }
    )
    return report


def write_outputs(report: dict[str, Any], out_dir: Path) -> tuple[Path, Path]:
    out_dir.mkdir(parents=True, exist_ok=True)
    json_path = out_dir / "android_companion_soak.json"
    md_path = out_dir / "ANDROID_COMPANION_SOAK.md"
    json_path.write_text(json.dumps(report, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    lines = [
        "# Android Companion Screen-Off Soak",
        "",
        f"- Status: `{report['status']}`",
        f"- URL: `{report.get('url', '')}`",
        f"- Generated: `{report['generated_at']}`",
        f"- Requested duration: `{report.get('requested_duration_seconds')} seconds`",
        f"- Interval: `{report.get('interval_seconds')} seconds`",
        f"- Samples: `{report.get('sample_count', 0)}`",
        f"- Passed: `{report.get('passed_count', 0)}`",
        f"- Failed: `{report.get('failed_count', 0)}`",
        f"- Success rate: `{report.get('success_rate', 0)}`",
        "",
        "Keep the phone screen off for the full soak window. If this report fails, run",
        "`RUN_ANDROID_LOGCAT_CAPTURE.cmd` immediately from the evidence packet, or",
        "`tools/capture_android_companion_logcat.cmd` from the repo, before the adb buffer rotates.",
        "",
        "## Issues",
    ]
    issues = report.get("issues", [])
    if issues:
        lines.extend(f"- {issue}" for issue in issues)
    else:
        lines.append("- None")
    lines.append("")
    lines.append("## Samples")
    for sample in report.get("samples", []):
        lines.append(
            f"- {sample.get('index')}: `{sample.get('status')}` "
            f"endpoint `{sample.get('endpoint_id')}` kind `{sample.get('endpoint_kind')}`"
        )
    if not report.get("samples"):
        lines.append("- None")
    lines.append("")
    md_path.write_text("\n".join(lines), encoding="utf-8")
    return json_path, md_path


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description="Run an Android Companion screen-off bridge soak.")
    parser.add_argument("url", help="Android dashboard URL, for example ws://192.168.1.42:8765/bridge")
    parser.add_argument("--duration-seconds", type=float, default=DEFAULT_DURATION_SECONDS)
    parser.add_argument("--interval-seconds", type=float, default=DEFAULT_INTERVAL_SECONDS)
    parser.add_argument("--timeout", type=float, default=5.0, help="Socket timeout in seconds.")
    parser.add_argument("--out-dir", default="output/android-companion-soak/latest", help="Report output directory.")
    parser.add_argument("--min-success-rate", type=float, default=1.0)
    parser.add_argument("--max-failures", type=int, default=0)
    parser.add_argument("--json", action="store_true", help="Print the JSON report to stdout.")
    parser.add_argument("--allow-non-android", action="store_true", help="Do not require endpoint_kind=android.")
    args = parser.parse_args(argv)

    report = build_soak_report(
        args.url,
        duration_seconds=args.duration_seconds,
        interval_seconds=args.interval_seconds,
        timeout=args.timeout,
        require_android=not args.allow_non_android,
        min_success_rate=args.min_success_rate,
        max_failures=args.max_failures,
    )
    json_path, md_path = write_outputs(report, Path(args.out_dir))
    if args.json:
        print(json.dumps(report, indent=2, sort_keys=True))
    else:
        print(f"Android companion screen-off soak report: {json_path}")
        print(f"Android companion screen-off soak summary: {md_path}")
        print(f"Status: {report['status']}")
    return 0 if report["status"] == "pass" else 1


if __name__ == "__main__":
    raise SystemExit(main())
