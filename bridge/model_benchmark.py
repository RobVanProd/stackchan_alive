#!/usr/bin/env python3
"""Batch benchmark the P7 local model runner profiles."""

from __future__ import annotations

import argparse
import json
from datetime import datetime, timezone
from pathlib import Path
from statistics import median
from typing import Any

from character_harness import PROMPT_SUITE
from local_runner import (
    DEFAULT_PROFILE,
    RUNNER_PROFILES,
    RunnerConfigurationError,
    RunnerExecutionError,
    run_runner_profile,
)

SCHEMA = "stackchan.model-benchmark.v1"
DEFAULT_OUT_DIR = Path("output/model-benchmark/latest")


def utc_timestamp() -> str:
    return datetime.now(timezone.utc).replace(microsecond=0).isoformat().replace("+00:00", "Z")


def known_case_names() -> list[str]:
    return [str(case["name"]) for case in PROMPT_SUITE]


def resolve_profiles(profile_names: list[str]) -> list[str]:
    selected = profile_names or list(RUNNER_PROFILES.keys())
    unknown = [name for name in selected if name not in RUNNER_PROFILES]
    if unknown:
        known = ", ".join(sorted(RUNNER_PROFILES))
        raise ValueError(f"unknown profile(s): {', '.join(unknown)}; expected one of: {known}")
    return selected


def resolve_cases(case_names: list[str]) -> list[str]:
    known = known_case_names()
    selected = case_names or known
    unknown = [name for name in selected if name not in known]
    if unknown:
        raise ValueError(f"unknown case(s): {', '.join(unknown)}; expected one of: {', '.join(known)}")
    return selected


def benchmark_case(
    profile: str,
    case_name: str,
    *,
    command: str = "",
    require_runner: bool = False,
    timeout_ms: int = 60000,
) -> dict[str, Any]:
    profile_meta = RUNNER_PROFILES[profile]
    base: dict[str, Any] = {
        "profile": profile,
        "model": profile_meta["model"],
        "runtime": profile_meta["runtime"],
        "case": case_name,
        "configured_runner": False,
        "command_source": "not_started",
        "ok": False,
        "issues": [],
        "error": "",
    }
    try:
        result = run_runner_profile(
            profile,
            case_name=case_name,
            command=command,
            require_runner=require_runner,
            timeout_ms=timeout_ms,
        )
    except (RunnerConfigurationError, RunnerExecutionError, ValueError) as exc:
        base["error"] = str(exc)
        base["issues"] = [exc.__class__.__name__]
        return base

    payload = result.to_dict()
    validation = payload["validation"]
    base.update(
        {
            "configured_runner": result.configured_runner,
            "command_source": result.command_source,
            "ok": bool(validation["ok"]),
            "issues": list(validation["issues"]),
            "normalized": validation["normalized"],
            "raw_response": result.raw_response,
        }
    )
    if result.elapsed_ms is not None:
        base["elapsed_ms"] = round(result.elapsed_ms, 2)
    if result.approx_tokens_per_sec is not None:
        base["approx_tokens_per_sec"] = round(result.approx_tokens_per_sec, 2)
    return base


def summarize_results(results: list[dict[str, Any]]) -> dict[str, Any]:
    total = len(results)
    ok_count = sum(1 for result in results if result.get("ok"))
    configured_count = sum(1 for result in results if result.get("configured_runner"))
    error_count = sum(1 for result in results if result.get("error"))
    validation_failures = total - ok_count - error_count
    profile_summaries: dict[str, dict[str, Any]] = {}

    for profile in RUNNER_PROFILES:
      profile_results = [result for result in results if result["profile"] == profile]
      if not profile_results:
          continue
      latencies = [float(result["elapsed_ms"]) for result in profile_results if "elapsed_ms" in result]
      tokens_per_sec = [
          float(result["approx_tokens_per_sec"]) for result in profile_results if "approx_tokens_per_sec" in result
      ]
      profile_ok = sum(1 for result in profile_results if result.get("ok"))
      profile_configured = sum(1 for result in profile_results if result.get("configured_runner"))
      profile_status = "pass"
      if any(result.get("error") for result in profile_results):
          profile_status = "error"
      elif profile_ok != len(profile_results):
          profile_status = "validation-fail"
      elif profile_configured == 0:
          profile_status = "dry-run"

      profile_summaries[profile] = {
          "status": profile_status,
          "cases": len(profile_results),
          "ok": profile_ok,
          "configured_runner_cases": profile_configured,
          "pass_rate": round(profile_ok / max(len(profile_results), 1), 3),
      }
      if latencies:
          profile_summaries[profile]["median_elapsed_ms"] = round(median(latencies), 2)
      if tokens_per_sec:
          profile_summaries[profile]["median_tokens_per_sec"] = round(median(tokens_per_sec), 2)

    if error_count:
        status = "error"
    elif ok_count != total:
        status = "validation-fail"
    elif configured_count == 0:
        status = "dry-run-no-runner-configured"
    else:
        status = "pass"

    return {
        "status": status,
        "total_cases": total,
        "ok_cases": ok_count,
        "configured_runner_cases": configured_count,
        "error_cases": error_count,
        "validation_failure_cases": validation_failures,
        "pass_rate": round(ok_count / max(total, 1), 3),
        "profiles": profile_summaries,
    }


def run_benchmark(
    profiles: list[str] | None = None,
    cases: list[str] | None = None,
    *,
    command: str = "",
    require_runner: bool = False,
    timeout_ms: int = 60000,
) -> dict[str, Any]:
    selected_profiles = resolve_profiles(profiles or [])
    selected_cases = resolve_cases(cases or [])
    if command.strip() and len(selected_profiles) != 1:
        raise ValueError("--command can only be used with exactly one --profile")

    results: list[dict[str, Any]] = []
    for profile in selected_profiles:
        for case_name in selected_cases:
            results.append(
                benchmark_case(
                    profile,
                    case_name,
                    command=command,
                    require_runner=require_runner,
                    timeout_ms=timeout_ms,
                )
            )

    return {
        "schema": SCHEMA,
        "generated_at": utc_timestamp(),
        "profiles_requested": selected_profiles,
        "cases_requested": selected_cases,
        "require_runner": require_runner,
        "summary": summarize_results(results),
        "results": results,
    }


def render_markdown(report: dict[str, Any]) -> str:
    summary = report["summary"]
    lines = [
        "# Stackchan Model Benchmark",
        "",
        f"Schema: `{report['schema']}`",
        f"Generated: `{report['generated_at']}`",
        f"Status: `{summary['status']}`",
        "",
        "This report measures the P7 Character Lock prompt suite through `bridge/local_runner.py`.",
        "If every row uses `deterministic_fallback`, this is a harness dry run, not model speed evidence.",
        "",
        "## Summary",
        "",
        "| Profile | Status | Cases | OK | Runner cases | Median ms | Median tokens/sec |",
        "|---|---:|---:|---:|---:|---:|---:|",
    ]
    for profile, profile_summary in summary["profiles"].items():
        lines.append(
            "| {profile} | {status} | {cases} | {ok} | {configured} | {ms} | {tps} |".format(
                profile=profile,
                status=profile_summary["status"],
                cases=profile_summary["cases"],
                ok=profile_summary["ok"],
                configured=profile_summary["configured_runner_cases"],
                ms=profile_summary.get("median_elapsed_ms", "n/a"),
                tps=profile_summary.get("median_tokens_per_sec", "n/a"),
            )
        )

    lines.extend(["", "## Cases", ""])
    for result in report["results"]:
        issue_text = ", ".join(result.get("issues", [])) if result.get("issues") else "none"
        elapsed = result.get("elapsed_ms", "n/a")
        tps = result.get("approx_tokens_per_sec", "n/a")
        lines.extend(
            [
                f"### {result['profile']} / {result['case']}",
                "",
                f"- OK: `{str(result.get('ok')).lower()}`",
                f"- Command source: `{result.get('command_source', '')}`",
                f"- Configured runner: `{str(result.get('configured_runner')).lower()}`",
                f"- Elapsed ms: `{elapsed}`",
                f"- Approx tokens/sec: `{tps}`",
                f"- Issues: `{issue_text}`",
            ]
        )
        if result.get("error"):
            lines.append(f"- Error: `{result['error']}`")
        normalized = result.get("normalized")
        if isinstance(normalized, dict):
            lines.append(f"- Spoken text: `{normalized.get('spoken_text', '')}`")
        lines.append("")
    return "\n".join(lines).rstrip() + "\n"


def write_outputs(report: dict[str, Any], out_dir: Path = DEFAULT_OUT_DIR) -> tuple[Path, Path]:
    out_dir.mkdir(parents=True, exist_ok=True)
    json_path = out_dir / "model_benchmark.json"
    markdown_path = out_dir / "MODEL_BENCHMARK.md"
    json_path.write_text(json.dumps(report, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    markdown_path.write_text(render_markdown(report), encoding="utf-8")
    return json_path, markdown_path


def build_arg_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description="Batch benchmark Stackchan P7 local runner profiles.")
    parser.add_argument("--profile", action="append", choices=sorted(RUNNER_PROFILES), help="Profile to run. Repeatable.")
    parser.add_argument("--case", action="append", choices=known_case_names(), help="Prompt-suite case to run. Repeatable.")
    parser.add_argument("--command", default="", help="Optional command for a single selected profile.")
    parser.add_argument("--require-runner", action="store_true", help="Fail rows instead of using deterministic fallback.")
    parser.add_argument("--timeout-ms", type=int, default=60000)
    parser.add_argument("--out-dir", default=str(DEFAULT_OUT_DIR))
    parser.add_argument("--json", action="store_true", help="Print the full benchmark report as JSON.")
    return parser


def main() -> int:
    args = build_arg_parser().parse_args()
    try:
        report = run_benchmark(
            args.profile,
            args.case,
            command=args.command,
            require_runner=args.require_runner,
            timeout_ms=args.timeout_ms,
        )
    except ValueError as exc:
        print(str(exc))
        return 2

    json_path, markdown_path = write_outputs(report, Path(args.out_dir))
    if args.json:
        print(json.dumps(report, indent=2, sort_keys=True))
    else:
        print(f"Model benchmark report: {json_path}")
        print(f"Model benchmark summary: {markdown_path}")

    status = report["summary"]["status"]
    if status == "error":
        return 2
    if status == "validation-fail":
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
