#!/usr/bin/env python3
"""Pre-arrival hardware proxy readiness report.

This combines the virtual Stackchan hardware simulator with the P7 engine probe.
Simulator failures are hard failures. Unconfigured model/STT/TTS engines remain
visible as setup work, but do not invalidate the no-hardware device proxy.
"""

from __future__ import annotations

import argparse
import json
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

from engine_probe import DEFAULT_TTS_VOICE, RUNNER_PROFILES, run_probe, write_outputs as write_engine_outputs
from hardware_simulator import SIM_SCHEMA as HARDWARE_SIM_SCHEMA
from hardware_simulator import write_outputs as write_hardware_outputs

SCHEMA = "stackchan.prearrival-sim-check.v1"
DEFAULT_OUT_DIR = Path("output/prearrival-sim/latest")
DEFAULT_PROFILES = ("gemma4-e2b-gguf", "gemma4-e2b-litert-lm")
DEFAULT_SCENARIOS = (
    "reference",
    "lan-text",
    "conversation-rehearsal",
    "conversation-tts-downlink",
    "conversation-audio-loop",
    "audio-downlink",
    "audio-downlink-unsupported",
    "arrival-rehearsal",
    "bridge-kill-recovery",
    "offline-command-fallback",
)


def utc_timestamp() -> str:
    return datetime.now(timezone.utc).replace(microsecond=0).isoformat().replace("+00:00", "Z")


def scenario_by_name(summary: dict[str, Any], name: str) -> dict[str, Any] | None:
    for scenario in summary.get("scenarios", []):
        if scenario.get("scenario") == name:
            return scenario
    return None


def scenario_highlights(summary: dict[str, Any]) -> dict[str, Any]:
    arrival = scenario_by_name(summary, "arrival-rehearsal") or {}
    audio_loop = scenario_by_name(summary, "conversation-audio-loop") or {}
    recovery = scenario_by_name(summary, "bridge-kill-recovery") or {}
    arrival_telemetry = arrival.get("telemetry", {})
    audio_telemetry = audio_loop.get("telemetry", {})
    recovery_telemetry = recovery.get("telemetry", {})
    return {
        "arrival_rehearsal": {
            "status": arrival.get("status", "missing"),
            "display_frames": arrival_telemetry.get("display_frames", 0),
            "display_frame_gap_max_ms": arrival_telemetry.get("display_frame_gap_max_ms", 0),
            "speaker_frames_submitted": arrival_telemetry.get("speaker_frames_submitted", 0),
            "power_cycles": arrival_telemetry.get("power_cycles", 0),
            "modes_seen": arrival_telemetry.get("modes_seen", []),
        },
        "conversation_audio_loop": {
            "status": audio_loop.get("status", "missing"),
            "first_audio_latency_ms": audio_telemetry.get("conversation_first_audio_latency_ms", 0),
            "upload_audio_bytes": audio_telemetry.get("bridge_upload_audio_bytes", 0),
            "stt_runs": audio_telemetry.get("bridge_stt_runs", 0),
            "downlink_playback_bytes": audio_telemetry.get("bridge_downlink_playback_bytes", 0),
            "speaker_frames_submitted": audio_telemetry.get("speaker_frames_submitted", 0),
        },
        "bridge_kill_recovery": {
            "status": recovery.get("status", "missing"),
            "bridge_errors": recovery_telemetry.get("bridge_errors", 0),
            "bridge_recoveries": recovery_telemetry.get("bridge_recoveries", 0),
            "audio_streams_aborted": recovery_telemetry.get("audio_streams_aborted", 0),
            "final_bridge_state": recovery_telemetry.get("bridge_state", ""),
        },
    }


def engine_profile_rows(engine_report: dict[str, Any]) -> list[dict[str, Any]]:
    rows = []
    for row in engine_report.get("model_profiles", []):
        rows.append(
            {
                "profile": row.get("profile", ""),
                "runtime": row.get("runtime", ""),
                "status": row.get("status", ""),
                "command_configured": bool(row.get("command_configured")),
                "ok": bool(row.get("ok")),
                "command_source": row.get("command_source", ""),
            }
        )
    return rows


def classify(hardware_summary: dict[str, Any], engine_report: dict[str, Any]) -> tuple[str, str, str]:
    engine_status = engine_report.get("summary", {}).get("status", "unknown")
    if hardware_summary.get("status") != "pass":
        return (
            "fail",
            "hardware-sim-failed",
            "Inspect hardware-sim/HARDWARE_SIMULATION.md and fix the simulator regression before device arrival.",
        )
    if engine_status == "error":
        return (
            "fail",
            "engine-error",
            "Fix the configured local model, STT, or TTS command reported in engine-probe/ENGINE_PROBE.md.",
        )
    if engine_status == "pass":
        return (
            "pass",
            "proxy-pass-engines-ready",
            "Use this as pre-arrival proxy evidence, then collect real display, speech, bridge, speaker, servo, and soak evidence when the unit arrives.",
        )
    if engine_status == "partial":
        return (
            "pass",
            "proxy-pass-engines-partial",
            "Finish configuring the remaining local model/STT/TTS command, then re-run with -RunModelSmoke.",
        )
    return (
        "pass",
        "proxy-pass-engines-unconfigured",
        "Configure model/STT/TTS commands later; the no-hardware CoreS3/LAN/audio proxy itself is passing.",
    )


def build_report(
    out_dir: Path = DEFAULT_OUT_DIR,
    *,
    profiles: list[str] | None = None,
    run_model_smoke: bool = False,
    stt_command: str = "",
    tts_command: str = "",
    tts_voice: str = DEFAULT_TTS_VOICE,
) -> dict[str, Any]:
    hardware_dir = out_dir / "hardware-sim"
    engine_dir = out_dir / "engine-probe"
    selected_profiles = profiles or list(DEFAULT_PROFILES)

    hardware_summary = write_hardware_outputs(hardware_dir, DEFAULT_SCENARIOS)
    engine_report = run_probe(
        profiles=selected_profiles,
        run_model_smoke=run_model_smoke,
        stt_command=stt_command,
        tts_command=tts_command,
        tts_voice=tts_voice,
    )
    write_engine_outputs(engine_report, engine_dir)

    status, readiness_class, next_action = classify(hardware_summary, engine_report)
    engine_summary = engine_report.get("summary", {})
    report = {
        "schema": SCHEMA,
        "generated_at": utc_timestamp(),
        "status": status,
        "readiness_class": readiness_class,
        "promotion_ready": False,
        "hardware_simulation": {
            "schema": hardware_summary.get("schema", HARDWARE_SIM_SCHEMA),
            "status": hardware_summary.get("status", "unknown"),
            "scenario_count": len(hardware_summary.get("scenarios", [])),
            "report_dir": str(hardware_dir),
            "highlights": scenario_highlights(hardware_summary),
        },
        "engine_readiness": {
            "status": engine_summary.get("status", "unknown"),
            "configured_model_profiles": engine_summary.get("configured_model_profiles", 0),
            "passing_model_profiles": engine_summary.get("passing_model_profiles", 0),
            "stt_status": engine_summary.get("stt_status", "unknown"),
            "tts_status": engine_summary.get("tts_status", "unknown"),
            "profiles": engine_profile_rows(engine_report),
            "report_dir": str(engine_dir),
            "run_model_smoke": run_model_smoke,
        },
        "gates": [
            {
                "gate": "virtual-cores3-lan-audio-proxy",
                "status": "pass" if hardware_summary.get("status") == "pass" else "fail",
                "evidence": "hardware-sim/hardware_simulation.json and scenario serial-like logs",
            },
            {
                "gate": "local-engine-setup",
                "status": engine_summary.get("status", "unknown"),
                "evidence": "engine-probe/engine_probe.json",
            },
            {
                "gate": "real-device-evidence",
                "status": "pending-device",
                "evidence": "Requires physical display, speaker, servo, soak, power-cycle, and audio recordings.",
            },
        ],
        "next_action": next_action,
        "notes": [
            "This is a pre-arrival proxy only; it does not prove LCD, speaker, microphone, camera, touch, IMU, servo, heat, battery, USB power, Wi-Fi, or soak behavior.",
            "Unconfigured engines are setup work, not a simulator failure. Configured engines that error are treated as failures.",
        ],
    }
    return report


def render_markdown(report: dict[str, Any]) -> str:
    hardware = report["hardware_simulation"]
    engine = report["engine_readiness"]
    highlights = hardware["highlights"]
    lines = [
        "# Stackchan Pre-Arrival Simulation Check",
        "",
        f"Schema: `{report['schema']}`",
        f"Generated: `{report['generated_at']}`",
        f"Status: `{report['status']}`",
        f"Readiness class: `{report['readiness_class']}`",
        "",
        "This is the fastest hardware-free proxy for Stackchan: Alive before the CoreS3 unit is on the bench.",
        "It proves simulator protocol behavior only; real hardware evidence is still required.",
        "",
        "## Hardware Proxy",
        "",
        f"- Status: `{hardware['status']}`",
        f"- Scenarios: `{hardware['scenario_count']}`",
        f"- Report directory: `{hardware['report_dir']}`",
        "",
        "### Scenario Highlights",
        "",
        f"- Arrival rehearsal: `{highlights['arrival_rehearsal']['status']}`, "
        f"display frames `{highlights['arrival_rehearsal']['display_frames']}`, "
        f"max display gap `{highlights['arrival_rehearsal']['display_frame_gap_max_ms']} ms`, "
        f"power cycles `{highlights['arrival_rehearsal']['power_cycles']}`.",
        f"- Conversation audio loop: `{highlights['conversation_audio_loop']['status']}`, "
        f"first audio `{highlights['conversation_audio_loop']['first_audio_latency_ms']} ms`, "
        f"mic upload `{highlights['conversation_audio_loop']['upload_audio_bytes']} bytes`, "
        f"downlink playback `{highlights['conversation_audio_loop']['downlink_playback_bytes']} bytes`.",
        f"- Bridge kill recovery: `{highlights['bridge_kill_recovery']['status']}`, "
        f"errors `{highlights['bridge_kill_recovery']['bridge_errors']}`, "
        f"recoveries `{highlights['bridge_kill_recovery']['bridge_recoveries']}`, "
        f"final state `{highlights['bridge_kill_recovery']['final_bridge_state']}`.",
        "",
        "## Engine Readiness",
        "",
        f"- Status: `{engine['status']}`",
        f"- Configured model profiles: `{engine['configured_model_profiles']}`",
        f"- Passing model profiles: `{engine['passing_model_profiles']}`",
        f"- STT status: `{engine['stt_status']}`",
        f"- TTS status: `{engine['tts_status']}`",
        f"- Report directory: `{engine['report_dir']}`",
        "",
        "| Profile | Runtime | Status | Configured | OK |",
        "|---|---|---:|---:|---:|",
    ]
    for row in engine["profiles"]:
        lines.append(
            f"| {row['profile']} | {row['runtime']} | {row['status']} | "
            f"{str(row['command_configured']).lower()} | {str(row['ok']).lower()} |"
        )
    lines.extend(
        [
            "",
            "## Gates",
            "",
        ]
    )
    for gate in report["gates"]:
        lines.append(f"- `{gate['gate']}`: `{gate['status']}` - {gate['evidence']}")
    lines.extend(
        [
            "",
            "## Next Action",
            "",
            report["next_action"],
            "",
            "## Guardrail",
            "",
            "Do not treat this as consumer-ready evidence. It is only the best available proxy until the physical Stackchan hardware arrives.",
        ]
    )
    return "\n".join(lines).rstrip() + "\n"


def write_report(report: dict[str, Any], out_dir: Path) -> tuple[Path, Path]:
    out_dir.mkdir(parents=True, exist_ok=True)
    json_path = out_dir / "prearrival_sim_check.json"
    markdown_path = out_dir / "PREARRIVAL_SIM_CHECK.md"
    json_path.write_text(json.dumps(report, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    markdown_path.write_text(render_markdown(report), encoding="utf-8")
    return json_path, markdown_path


def build_arg_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description="Run the Stackchan pre-arrival hardware simulation check.")
    parser.add_argument("--out-dir", type=Path, default=DEFAULT_OUT_DIR)
    parser.add_argument("--profile", action="append", choices=sorted(RUNNER_PROFILES), help="Model profile to probe. Repeatable.")
    parser.add_argument("--run-model-smoke", action="store_true", help="Run one real model smoke case for configured profiles.")
    parser.add_argument("--stt-command", default="", help="Override STT command for this check.")
    parser.add_argument("--tts-command", default="", help="Override TTS command for this check.")
    parser.add_argument("--tts-voice", default=DEFAULT_TTS_VOICE)
    parser.add_argument("--json", action="store_true")
    return parser


def main() -> int:
    args = build_arg_parser().parse_args()
    report = build_report(
        args.out_dir,
        profiles=args.profile,
        run_model_smoke=args.run_model_smoke,
        stt_command=args.stt_command,
        tts_command=args.tts_command,
        tts_voice=args.tts_voice,
    )
    json_path, markdown_path = write_report(report, args.out_dir)
    if args.json:
        print(json.dumps(report, indent=2, sort_keys=True))
    else:
        print(f"Pre-arrival simulation check: {json_path}")
        print(f"Pre-arrival simulation summary: {markdown_path}")
    return 0 if report["status"] == "pass" else 1


if __name__ == "__main__":
    raise SystemExit(main())
