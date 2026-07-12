#!/usr/bin/env python3
"""No-hardware contract smoke for the LiteRT-LM Stackchan runner path."""

from __future__ import annotations

import argparse
import json
import os
import sys
import tempfile
from contextlib import contextmanager
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Iterable

from litert_lm_stackchan_wrapper import COMMAND_ENV as LITERT_COMMAND_ENV
from local_runner import RUNNER_PROFILES, run_runner_profile

SCHEMA = "stackchan.litert-lm-smoke.v1"
DEFAULT_OUT_DIR = Path("output/litert-lm-smoke/latest")
PROFILE = "gemma4-e2b-litert-lm"
PROFILE_COMMAND_ENV = RUNNER_PROFILES[PROFILE]["command_env"]


def utc_timestamp() -> str:
    return datetime.now(timezone.utc).replace(microsecond=0).isoformat().replace("+00:00", "Z")


@contextmanager
def temporary_env(updates: dict[str, str]) -> Iterable[None]:
    saved = {key: os.environ.get(key) for key in updates}
    try:
        os.environ.update(updates)
        yield
    finally:
        for key, value in saved.items():
            if value is None:
                os.environ.pop(key, None)
            else:
                os.environ[key] = value


def quoted_command(*parts: Path | str) -> str:
    return " ".join(f'"{str(part)}"' for part in parts)


def write_fake_litert_command(path: Path) -> str:
    path.write_text(
        "\n".join(
            [
                "import json",
                "import sys",
                "prompt = sys.stdin.read()",
                "if 'Stackchan' not in prompt:",
                "    raise SystemExit('prompt missing Stackchan character context')",
                "print('LiteRT-LM boot log: warm cache {not json}')",
                "print(json.dumps({",
                "  'spoken_text': 'Mobile brain path online. I am thinking locally.',",
                "  'mode': 'think',",
                "  'earcon': 'think',",
                "  'emotion': {'arousal': 0.1, 'valence': 0.05},",
                "  'memory_write': {'project.brain_path': 'litert-lm contract smoke'},",
                "  'memory_forget': []",
                "}))",
            ]
        ),
        encoding="utf-8",
    )
    return quoted_command(sys.executable, path)


def build_report(out_dir: Path = DEFAULT_OUT_DIR) -> dict[str, Any]:
    del out_dir
    wrapper_path = Path(__file__).with_name("litert_lm_stackchan_wrapper.py")
    wrapper_command = quoted_command(sys.executable, wrapper_path)
    with tempfile.TemporaryDirectory() as temp_dir:
        fake_litert_command = write_fake_litert_command(Path(temp_dir) / "fake_litert_lm.py")
        with temporary_env(
            {
                PROFILE_COMMAND_ENV: wrapper_command,
                LITERT_COMMAND_ENV: fake_litert_command,
            }
        ):
            result = run_runner_profile(PROFILE, case_name="greeting", require_runner=True, timeout_ms=10000)

    validation = result.validation.to_dict()
    status = "pass" if result.configured_runner and validation.get("ok") else "fail"
    checks = {
        "profile_command_env": PROFILE_COMMAND_ENV,
        "litert_command_env": LITERT_COMMAND_ENV,
        "profile_command_source": result.command_source,
        "configured_runner": result.configured_runner,
        "validation_ok": bool(validation.get("ok")),
        "wrapper_contract": result.command_source == f"env:{PROFILE_COMMAND_ENV}",
    }
    if not checks["wrapper_contract"] or not checks["validation_ok"]:
        status = "fail"
    return {
        "schema": SCHEMA,
        "generated_at": utc_timestamp(),
        "status": status,
        "profile": PROFILE,
        "model": result.model,
        "runtime": result.runtime,
        "wrapper_command": wrapper_command,
        "fake_litert_command_source": f"env:{LITERT_COMMAND_ENV}",
        "elapsed_ms": round(result.elapsed_ms or 0.0, 2),
        "approx_tokens_per_sec": round(result.approx_tokens_per_sec or 0.0, 2),
        "checks": checks,
        "validation": validation,
        "normalized": validation.get("normalized", {}),
        "notes": [
            "This is a contract smoke, not real LiteRT-LM model speed evidence.",
            "Replace the fake command with a real LiteRT-LM command via STACKCHAN_LITERT_LM_COMMAND.",
        ],
    }


def render_markdown(report: dict[str, Any]) -> str:
    normalized = report.get("normalized", {})
    checks = report.get("checks", {})
    lines = [
        "# Stackchan LiteRT-LM Contract Smoke",
        "",
        f"Schema: `{report['schema']}`",
        f"Generated: `{report['generated_at']}`",
        f"Status: `{report['status']}`",
        f"Profile: `{report['profile']}`",
        f"Runtime: `{report['runtime']}`",
        "",
        "This smoke verifies the mobile/low-active-memory runner wiring without requiring a real LiteRT-LM model.",
        "It routes `local_runner.py` through `litert_lm_stackchan_wrapper.py`, then through a deterministic fake LiteRT command.",
        "",
        "## Checks",
        "",
        f"- Profile command env: `{checks.get('profile_command_env')}`",
        f"- LiteRT command env: `{checks.get('litert_command_env')}`",
        f"- Profile command source: `{checks.get('profile_command_source')}`",
        f"- Configured runner: `{str(checks.get('configured_runner')).lower()}`",
        f"- Character Lock validation: `{str(checks.get('validation_ok')).lower()}`",
        f"- Wrapper contract: `{str(checks.get('wrapper_contract')).lower()}`",
        f"- Elapsed ms: `{report.get('elapsed_ms')}`",
        f"- Approx tokens/sec: `{report.get('approx_tokens_per_sec')}`",
        "",
        "## Response",
        "",
        f"- Mode: `{normalized.get('mode', '')}`",
        f"- Earcon: `{normalized.get('earcon', '')}`",
        f"- Spoken text: `{normalized.get('spoken_text', '')}`",
        "",
        "## Limits",
        "",
    ]
    for note in report.get("notes", []):
        lines.append(f"- {note}")
    lines.append("")
    return "\n".join(lines)


def write_outputs(report: dict[str, Any], out_dir: Path = DEFAULT_OUT_DIR) -> tuple[Path, Path]:
    out_dir.mkdir(parents=True, exist_ok=True)
    json_path = out_dir / "litert_lm_smoke.json"
    markdown_path = out_dir / "LITERT_LM_SMOKE.md"
    json_path.write_text(json.dumps(report, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    markdown_path.write_text(render_markdown(report), encoding="utf-8")
    return json_path, markdown_path


def build_arg_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description="Run the Stackchan LiteRT-LM contract smoke.")
    parser.add_argument("--out-dir", type=Path, default=DEFAULT_OUT_DIR)
    parser.add_argument("--json", action="store_true", help="Print the smoke report JSON to stdout.")
    return parser


def main() -> int:
    args = build_arg_parser().parse_args()
    report = build_report(args.out_dir)
    json_path, markdown_path = write_outputs(report, args.out_dir)
    if args.json:
        print(json.dumps(report, indent=2, sort_keys=True))
    else:
        print(f"LiteRT-LM smoke report: {json_path}")
        print(f"LiteRT-LM smoke summary: {markdown_path}")
        print(f"Status: {report['status']}")
    return 0 if report["status"] == "pass" else 1


if __name__ == "__main__":
    raise SystemExit(main())
