#!/usr/bin/env python3
"""Summarize Stackchan conversation latency records from a bridge turn log."""

from __future__ import annotations

import argparse
import json
import math
from pathlib import Path
from typing import Iterable


LATENCY_SCHEMA = "stackchan.conversation-latency.v1"
GATES = (
    "latency_gate_host_reaction_under_300",
    "latency_gate_first_audio_under_3000",
    "latency_gate_render_faster_than_realtime",
    "latency_gate_zero_truncation",
)


def _percentile(values: list[float], percentile: float) -> float | None:
    if not values:
        return None
    ordered = sorted(values)
    rank = max(0, math.ceil((percentile / 100.0) * len(ordered)) - 1)
    return round(ordered[rank], 4)


def _numbers(records: list[dict[str, object]], key: str) -> list[float]:
    values: list[float] = []
    for record in records:
        try:
            value = float(record[key])
        except (KeyError, TypeError, ValueError):
            continue
        if math.isfinite(value) and value >= 0.0:
            values.append(value)
    return values


def _distribution(values: list[float]) -> dict[str, object]:
    if not values:
        return {"samples": 0}
    return {
        "samples": len(values),
        "p50": _percentile(values, 50),
        "p95": _percentile(values, 95),
        "max": round(max(values), 4),
    }


def summarize_latency_records(records: Iterable[dict[str, object]]) -> dict[str, object]:
    measured = [record for record in records if record.get("latency_schema") == LATENCY_SCHEMA]
    audio_turns = [record for record in measured if "latency_first_audio_ms" in record]
    gate_summary: dict[str, dict[str, int]] = {}
    for gate in GATES:
        eligible = [record for record in audio_turns if gate in record]
        passed = sum(record.get(gate) is True for record in eligible)
        gate_summary[gate] = {
            "eligible": len(eligible),
            "passed": passed,
            "failed": len(eligible) - passed,
            "missing": len(audio_turns) - len(eligible),
        }

    ready = bool(audio_turns) and all(
        values["failed"] == 0 and values["missing"] == 0 for values in gate_summary.values()
    )
    return {
        "schema": "stackchan.conversation-latency-report.v1",
        "status": "pass" if ready else "not_ready",
        "measured_turns": len(measured),
        "audio_turns": len(audio_turns),
        "host_reaction_ms": _distribution(_numbers(audio_turns, "latency_host_reaction_ms")),
        "first_audio_ms": _distribution(_numbers(audio_turns, "latency_first_audio_ms")),
        "text_ready_ms": _distribution(_numbers(measured, "latency_text_ready_ms")),
        "turn_total_ms": _distribution(_numbers(measured, "latency_turn_total_ms")),
        "tts_render_rtf": _distribution(_numbers(audio_turns, "latency_tts_render_rtf")),
        "gates": gate_summary,
    }


def load_turn_log(path: Path) -> list[dict[str, object]]:
    records: list[dict[str, object]] = []
    with path.open("r", encoding="utf-8") as handle:
        for line_number, line in enumerate(handle, start=1):
            text = line.strip()
            if not text:
                continue
            try:
                record = json.loads(text)
            except json.JSONDecodeError as exc:
                raise ValueError(f"invalid JSON on line {line_number}: {exc.msg}") from exc
            if isinstance(record, dict):
                records.append(record)
    return records


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--turn-log", type=Path, required=True)
    parser.add_argument("--json", action="store_true")
    parser.add_argument("--require-ready", action="store_true")
    return parser


def main() -> int:
    args = build_parser().parse_args()
    report = summarize_latency_records(load_turn_log(args.turn_log))
    if args.json:
        print(json.dumps(report, indent=2, sort_keys=True))
    else:
        print(
            f"status={report['status']} measured_turns={report['measured_turns']} "
            f"audio_turns={report['audio_turns']}"
        )
        for metric in ("host_reaction_ms", "first_audio_ms", "text_ready_ms", "turn_total_ms", "tts_render_rtf"):
            print(f"{metric}={json.dumps(report[metric], separators=(',', ':'))}")
        print(f"gates={json.dumps(report['gates'], separators=(',', ':'))}")
    return 1 if args.require_ready and report["status"] != "pass" else 0


if __name__ == "__main__":
    raise SystemExit(main())
