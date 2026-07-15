#!/usr/bin/env python3
"""Measure local Gemma prompt latency with baseline and worst-case memory cards."""

from __future__ import annotations

import argparse
import json
import statistics
from pathlib import Path

from bridge_memory import BridgeMemory
from local_runner import run_runner_profile


def worst_case_card() -> tuple[str, ...]:
    memory = BridgeMemory(preferred_name="Fixture", turns_seen=500)
    for index in range(24):
        key = f"project.prefill_fixture_{index:02d}_long_key"
        value = f"fixture calibration record {index:02d} " + ("x" * 64)
        memory = memory.apply_character_memory(
            {"memory_write": {key: value}, "memory_forget": []}
        )
    memory = memory.add_episode("Talked about fixture calibration and actuator alignment " + ("z" * 60))
    memory = memory.add_open_loop(
        "I have a fixture calibration demonstration tomorrow",
        due_at="2026-07-01T00:00:00Z",
        now="2026-06-30T00:00:00Z",
    )
    return memory.relationship_card(
        "prefill fixture calibration",
        session_turns=1,
        now="2026-07-02T00:00:00Z",
    ).lines


def run_prefill_probe(command: str, *, repeats: int = 3) -> dict[str, object]:
    samples = {"baseline": [], "worst_card": []}
    cards = {
        "baseline": ("turns_seen: 500", "preferred_name: Fixture"),
        "worst_card": worst_case_card(),
    }
    for _ in range(max(2, repeats)):
        for mode in ("baseline", "worst_card"):
            result = run_runner_profile(
                "gemma4-e2b-gguf",
                case_name="question",
                command=command,
                require_runner=True,
                timeout_ms=120000,
                user_text="Explain actuator alignment in one short sentence.",
                memory_lines=cards[mode],
            )
            if result.elapsed_ms is None:
                raise RuntimeError("runner timing missing")
            samples[mode].append(float(result.elapsed_ms))
    baseline_p50 = statistics.median(samples["baseline"])
    worst_p50 = statistics.median(samples["worst_card"])
    delta = worst_p50 - baseline_p50
    return {
        "schema": "stackchan.memory-prefill-probe.v1",
        "repeats": max(2, repeats),
        "baseline_p50_ms": round(baseline_p50, 2),
        "worst_card_p50_ms": round(worst_p50, 2),
        "p50_delta_ms": round(delta, 2),
        "worst_card_chars": len("\n".join(cards["worst_card"])),
        "gate_delta_at_most_500_ms": delta <= 500.0,
    }


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--command", default="python bridge\\ollama_stackchan_runner.py")
    parser.add_argument("--repeats", type=int, default=3)
    parser.add_argument("--json-out", type=Path)
    args = parser.parse_args()
    report = run_prefill_probe(args.command, repeats=args.repeats)
    payload = json.dumps(report, indent=2, sort_keys=True) + "\n"
    if args.json_out:
        args.json_out.parent.mkdir(parents=True, exist_ok=True)
        args.json_out.write_text(payload, encoding="utf-8")
    print(payload, end="")
    return 0 if report["gate_delta_at_most_500_ms"] else 1


if __name__ == "__main__":
    raise SystemExit(main())
