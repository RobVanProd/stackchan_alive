#!/usr/bin/env python3
"""Aggregate-only v3/v4 memory retrieval and relationship-card benchmark."""

from __future__ import annotations

import argparse
import json
import statistics
import time
from pathlib import Path

from bridge_memory import BridgeMemory, MAX_EPISODES, MAX_OPEN_LOOPS


DEFAULT_FIXTURE = Path(__file__).resolve().parent / "fixtures" / "memory_probe.json"


def load_fixture(path: Path = DEFAULT_FIXTURE) -> dict[str, object]:
    data = json.loads(path.read_text(encoding="utf-8"))
    if not isinstance(data, dict):
        raise ValueError("memory probe fixture must be an object")
    return data


def seeded_memory(fixture: dict[str, object]) -> BridgeMemory:
    memory = BridgeMemory(turns_seen=50)
    for item in fixture["facts"]:
        memory = memory.apply_character_memory(
            {"memory_write": {str(item["key"]): str(item["value"])}, "memory_forget": []}
        )
    for index, episode in enumerate(fixture["episodes"]):
        memory = memory.add_episode(str(episode), now=f"2026-07-{index + 1:02d}T00:00:00Z")
    return memory


def _hit(lines: list[str] | tuple[str, ...], key: str) -> bool:
    return any(line.startswith(f"approved_fact {key}:") for line in lines)


def probe_mode(memory: BridgeMemory, fixture: dict[str, object], mode: str) -> dict[str, object]:
    def lines(query: str):
        if mode == "v3_baseline":
            return memory._fact_context_lines(query)
        return memory.relationship_card(query, session_turns=3).lines

    exact_rows = fixture["exact_queries"]
    paraphrase_rows = fixture["paraphrase_queries"]
    unrelated = fixture["unrelated_queries"]
    exact_hits = sum(_hit(lines(str(row["query"])), str(row["key"])) for row in exact_rows)
    paraphrase_hits = sum(_hit(lines(str(row["query"])), str(row["key"])) for row in paraphrase_rows)
    false_hits = sum(
        any(line.startswith("approved_fact ") for line in lines(str(query))) for query in unrelated
    )
    return {
        "mode": mode,
        "exact_queries": len(exact_rows),
        "exact_hits": exact_hits,
        "exact_hit_rate": round(exact_hits / len(exact_rows), 4),
        "paraphrase_queries": len(paraphrase_rows),
        "paraphrase_hits": paraphrase_hits,
        "paraphrase_hit_rate": round(paraphrase_hits / len(paraphrase_rows), 4),
        "unrelated_queries": len(unrelated),
        "false_injections": false_hits,
        "false_injection_rate": round(false_hits / len(unrelated), 4),
    }


def relationship_card_benchmark(memory: BridgeMemory, iterations: int = 1000) -> dict[str, object]:
    full = memory
    for index in range(full.episode_count, MAX_EPISODES):
        full = full.add_episode(f"Workshop benchmarkcode{index:02d}")
    for index in range(MAX_OPEN_LOOPS):
        full = full.add_open_loop(
            f"I have benchmarktask{index:02d} tomorrow",
            due_at="2026-07-01T00:00:00Z",
            now="2026-06-30T00:00:00Z",
        )
    samples = []
    for _ in range(max(100, iterations)):
        started = time.perf_counter()
        full.relationship_card("fixture actuator bracket display", session_turns=1, now="2026-07-02T00:00:00Z")
        samples.append((time.perf_counter() - started) * 1000.0)
    ordered = sorted(samples)
    p95 = ordered[max(0, int(len(ordered) * 0.95) - 1)]
    return {
        "iterations": len(samples),
        "p50_ms": round(statistics.median(samples), 4),
        "p95_ms": round(p95, 4),
        "max_ms": round(max(samples), 4),
    }


def run_probe(fixture_path: Path = DEFAULT_FIXTURE) -> dict[str, object]:
    fixture = load_fixture(fixture_path)
    memory = seeded_memory(fixture)
    baseline = probe_mode(memory, fixture, "v3_baseline")
    current = probe_mode(memory, fixture, "v4")
    benchmark = relationship_card_benchmark(memory)
    return {
        "schema": "stackchan.memory-probe.v1",
        "seed_counts": {
            "facts": len(fixture["facts"]),
            "episodes": len(fixture["episodes"]),
        },
        "results": [baseline, current],
        "relationship_card_benchmark": benchmark,
        "gates": {
            "exact_at_least_0_95": current["exact_hit_rate"] >= 0.95,
            "false_at_most_0_10": current["false_injection_rate"] <= 0.10,
            "paraphrase_expectation_0_70": current["paraphrase_hit_rate"] >= 0.70,
            "relationship_card_p95_under_5_ms": benchmark["p95_ms"] < 5.0,
        },
    }


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--fixture", type=Path, default=DEFAULT_FIXTURE)
    parser.add_argument("--json-out", type=Path)
    args = parser.parse_args()
    report = run_probe(args.fixture)
    payload = json.dumps(report, indent=2, sort_keys=True) + "\n"
    if args.json_out:
        args.json_out.parent.mkdir(parents=True, exist_ok=True)
        args.json_out.write_text(payload, encoding="utf-8")
    print(payload, end="")
    return 0 if all(report["gates"].values()) else 1


if __name__ == "__main__":
    raise SystemExit(main())
