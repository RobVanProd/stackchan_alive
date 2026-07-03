#!/usr/bin/env python3
"""Probe configured P7 model, STT, and TTS engines."""

from __future__ import annotations

import argparse
import json
import shutil
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

from local_runner import RUNNER_PROFILES, RunnerConfigurationError, RunnerExecutionError, resolve_command, run_runner_profile
from stt_adapter import DEFAULT_STT_TIMEOUT_MS, SttConfigurationError, SttExecutionError, transcribe_pcm
from tts_adapter import DEFAULT_TTS_TIMEOUT_MS, DEFAULT_TTS_VOICE, TtsConfigurationError, TtsExecutionError, synthesize_speech

SCHEMA = "stackchan.engine-probe.v1"
DEFAULT_OUT_DIR = Path("output/engine-probe/latest")
DEFAULT_STT_SAMPLE_RATE = 16000
DEFAULT_STT_PCM = b"\x00\x00" * 1600
DEFAULT_TTS_TEXT = "Hello. I am Stackchan, and I am awake."
TOOL_CANDIDATES = (
    "ollama",
    "llama-cli",
    "llama-server",
    "llama-run",
    "llamafile",
    "litert_lm",
    "python",
    "python3",
)


def utc_timestamp() -> str:
    return datetime.now(timezone.utc).replace(microsecond=0).isoformat().replace("+00:00", "Z")


def probe_tools(candidates: tuple[str, ...] = TOOL_CANDIDATES) -> dict[str, Any]:
    found: dict[str, str] = {}
    missing: list[str] = []
    for name in candidates:
        path = shutil.which(name)
        if path:
            found[name] = path
        else:
            missing.append(name)
    return {"found": found, "missing": missing}


def probe_model_profiles(
    profiles: list[str] | None = None,
    *,
    run_smoke: bool = False,
    timeout_ms: int = 60000,
) -> list[dict[str, Any]]:
    selected = profiles or list(RUNNER_PROFILES.keys())
    rows: list[dict[str, Any]] = []
    for profile in selected:
        if profile not in RUNNER_PROFILES:
            rows.append({"profile": profile, "status": "unknown-profile", "ok": False})
            continue
        command, source = resolve_command(profile)
        meta = RUNNER_PROFILES[profile]
        row: dict[str, Any] = {
            "profile": profile,
            "model": meta["model"],
            "runtime": meta["runtime"],
            "status": "configured" if command else "unconfigured",
            "ok": bool(command),
            "command_source": source,
            "command_configured": bool(command),
            "example_command": meta.get("example_command", ""),
            "smoke": None,
        }
        if run_smoke:
            try:
                result = run_runner_profile(profile, case_name="greeting", require_runner=True, timeout_ms=timeout_ms)
                row["smoke"] = {
                    "ok": result.validation.ok,
                    "elapsed_ms": round(result.elapsed_ms or 0.0, 2),
                    "approx_tokens_per_sec": round(result.approx_tokens_per_sec or 0.0, 2),
                    "issues": list(result.validation.issues),
                }
                row["ok"] = bool(result.validation.ok)
                row["status"] = "pass" if result.validation.ok else "validation-fail"
            except (RunnerConfigurationError, RunnerExecutionError, ValueError) as exc:
                row["ok"] = False
                row["status"] = "error" if command else "unconfigured"
                row["error"] = str(exc)
        rows.append(row)
    return rows


def probe_stt(command: str = "", timeout_ms: int = DEFAULT_STT_TIMEOUT_MS) -> dict[str, Any]:
    row: dict[str, Any] = {
        "status": "unconfigured",
        "ok": False,
        "command_source": "unconfigured",
        "sample_rate": DEFAULT_STT_SAMPLE_RATE,
        "audio_bytes": len(DEFAULT_STT_PCM),
    }
    try:
        result = transcribe_pcm(DEFAULT_STT_PCM, DEFAULT_STT_SAMPLE_RATE, command=command, timeout_ms=timeout_ms)
    except SttConfigurationError as exc:
        row["error"] = str(exc)
        return row
    except (SttExecutionError, ValueError) as exc:
        row["status"] = "error"
        row["error"] = str(exc)
        return row

    row.update(result.to_dict())
    row["status"] = "pass"
    row["ok"] = True
    return row


def probe_tts(
    command: str = "",
    voice: str = DEFAULT_TTS_VOICE,
    timeout_ms: int = DEFAULT_TTS_TIMEOUT_MS,
    text: str = DEFAULT_TTS_TEXT,
) -> dict[str, Any]:
    row: dict[str, Any] = {
        "status": "unconfigured",
        "ok": False,
        "command_source": "unconfigured",
        "voice": voice,
        "text_bytes": len(text.encode("utf-8")),
    }
    try:
        result = synthesize_speech(text, command=command, voice=voice, timeout_ms=timeout_ms)
    except TtsConfigurationError as exc:
        row["error"] = str(exc)
        return row
    except (TtsExecutionError, ValueError) as exc:
        row["status"] = "error"
        row["error"] = str(exc)
        return row

    row.update(result.to_dict())
    row["status"] = "pass"
    row["ok"] = True
    row["beats"] = len(result.beats)
    return row


def summarize(report: dict[str, Any]) -> dict[str, Any]:
    model_rows = list(report["model_profiles"])
    configured_models = [row for row in model_rows if row.get("command_configured")]
    passing_models = [row for row in model_rows if row.get("ok")]
    stt = report["stt"]
    tts = report["tts"]
    errors = []
    if any(row.get("status") == "error" for row in model_rows):
        errors.append("model")
    if stt.get("status") == "error":
        errors.append("stt")
    if tts.get("status") == "error":
        errors.append("tts")

    if errors:
        status = "error"
    elif configured_models and passing_models and stt.get("ok") and tts.get("ok"):
        status = "pass"
    elif configured_models or stt.get("ok") or tts.get("ok"):
        status = "partial"
    else:
        status = "unconfigured"

    return {
        "status": status,
        "configured_model_profiles": len(configured_models),
        "passing_model_profiles": len(passing_models),
        "stt_status": stt.get("status", "unknown"),
        "tts_status": tts.get("status", "unknown"),
        "found_tool_count": len(report["tool_candidates"]["found"]),
        "errors": errors,
    }


def run_probe(
    *,
    profiles: list[str] | None = None,
    run_model_smoke: bool = False,
    stt_command: str = "",
    tts_command: str = "",
    tts_voice: str = DEFAULT_TTS_VOICE,
    timeout_ms: int = 60000,
) -> dict[str, Any]:
    report: dict[str, Any] = {
        "schema": SCHEMA,
        "generated_at": utc_timestamp(),
        "run_model_smoke": run_model_smoke,
        "tool_candidates": probe_tools(),
        "model_profiles": probe_model_profiles(profiles, run_smoke=run_model_smoke, timeout_ms=timeout_ms),
        "stt": probe_stt(stt_command, timeout_ms=min(timeout_ms, DEFAULT_STT_TIMEOUT_MS)),
        "tts": probe_tts(tts_command, voice=tts_voice, timeout_ms=min(timeout_ms, DEFAULT_TTS_TIMEOUT_MS)),
    }
    report["summary"] = summarize(report)
    return report


def render_markdown(report: dict[str, Any]) -> str:
    summary = report["summary"]
    lines = [
        "# Stackchan Engine Probe",
        "",
        f"Schema: `{report['schema']}`",
        f"Generated: `{report['generated_at']}`",
        f"Status: `{summary['status']}`",
        "",
        "This is the quick P7 engine-selection probe. It reports configured local model, STT, and TTS commands.",
        "A status of `unconfigured` is expected until runner commands are installed and exported.",
        "",
        "## Model Profiles",
        "",
        "| Profile | Runtime | Status | Command source | Smoke | Example |",
        "|---|---|---:|---|---:|---|",
    ]
    for row in report["model_profiles"]:
        smoke = "not-run"
        if isinstance(row.get("smoke"), dict):
            smoke = "pass" if row["smoke"].get("ok") else "fail"
        lines.append(
            "| {profile} | {runtime} | {status} | {source} | {smoke} | `{example}` |".format(
                profile=row.get("profile", ""),
                runtime=row.get("runtime", ""),
                status=row.get("status", ""),
                source=row.get("command_source", ""),
                smoke=smoke,
                example=row.get("example_command", ""),
            )
        )
    lines.extend(
        [
            "",
            "## Speech Engines",
            "",
            f"- STT status: `{report['stt'].get('status')}`",
            f"- STT command source: `{report['stt'].get('command_source')}`",
            f"- TTS status: `{report['tts'].get('status')}`",
            f"- TTS command source: `{report['tts'].get('command_source')}`",
            f"- TTS voice: `{report['tts'].get('voice')}`",
            "",
            "## Tools On Path",
            "",
        ]
    )
    found = report["tool_candidates"]["found"]
    if found:
        for name, path in found.items():
            lines.append(f"- `{name}`: `{path}`")
    else:
        lines.append("- none")
    lines.extend(
        [
            "",
            "## Next Actions",
            "",
        ]
    )
    if summary["status"] == "pass":
        lines.append("- Run `bridge/model_benchmark.py --require-runner` for the full Character Lock model suite.")
        lines.append("- Capture STT/TTS engine output in a release evidence package once device audio is available.")
    else:
        lines.append("- Install or expose a model runner with `STACKCHAN_GEMMA4_E2B_GGUF_COMMAND` or `STACKCHAN_GEMMA4_E2B_LITERT_COMMAND`.")
        lines.append("- Expose STT with `STACKCHAN_STT_COMMAND` and TTS with `STACKCHAN_TTS_COMMAND`.")
        lines.append("- Re-run this probe with `--run-model-smoke` after commands are configured.")
    return "\n".join(lines).rstrip() + "\n"


def write_outputs(report: dict[str, Any], out_dir: Path = DEFAULT_OUT_DIR) -> tuple[Path, Path]:
    out_dir.mkdir(parents=True, exist_ok=True)
    json_path = out_dir / "engine_probe.json"
    markdown_path = out_dir / "ENGINE_PROBE.md"
    json_path.write_text(json.dumps(report, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    markdown_path.write_text(render_markdown(report), encoding="utf-8")
    return json_path, markdown_path


def build_arg_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description="Probe Stackchan P7 local model/STT/TTS engine readiness.")
    parser.add_argument("--profile", action="append", choices=sorted(RUNNER_PROFILES), help="Model profile to inspect. Repeatable.")
    parser.add_argument("--run-model-smoke", action="store_true", help="Run one real model smoke case for configured profiles.")
    parser.add_argument("--stt-command", default="", help="Override STT command for this probe.")
    parser.add_argument("--tts-command", default="", help="Override TTS command for this probe.")
    parser.add_argument("--tts-voice", default=DEFAULT_TTS_VOICE)
    parser.add_argument("--timeout-ms", type=int, default=60000)
    parser.add_argument("--out-dir", default=str(DEFAULT_OUT_DIR))
    parser.add_argument("--json", action="store_true")
    return parser


def main() -> int:
    args = build_arg_parser().parse_args()
    report = run_probe(
        profiles=args.profile,
        run_model_smoke=args.run_model_smoke,
        stt_command=args.stt_command,
        tts_command=args.tts_command,
        tts_voice=args.tts_voice,
        timeout_ms=args.timeout_ms,
    )
    json_path, markdown_path = write_outputs(report, Path(args.out_dir))
    if args.json:
        print(json.dumps(report, indent=2, sort_keys=True))
    else:
        print(f"Engine probe report: {json_path}")
        print(f"Engine probe summary: {markdown_path}")
    return 2 if report["summary"]["status"] == "error" else 0


if __name__ == "__main__":
    raise SystemExit(main())
