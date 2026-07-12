#!/usr/bin/env python3
"""Silently verify deterministic trusted-fact routing against a real memory store."""

from __future__ import annotations

import argparse
import json
from datetime import datetime
from pathlib import Path
from typing import Any

from bridge_memory import BridgeMemory, load_bridge_memory
from local_facts import resolve_local_fact


ROUTED_CASES = (
    ("Do you have the time?", "local_clock"),
    ("Can you tell me what time it is?", "local_clock"),
    ("Could you tell me the current time?", "local_clock"),
    ("Can you check the time?", "local_clock"),
    ("Can I get the time?", "local_clock"),
    ("Give me the time please.", "local_clock"),
    ("What is today's date?", "local_clock"),
    ("Can you tell me what day it is?", "local_clock"),
    ("What time zone are we in?", "local_clock"),
    ("Could you tell me our timezone?", "local_clock"),
    ("Do you remember my name?", "memory_recall"),
    ("Could you tell me who I am?", "memory_recall"),
    ("Do you remember my favorite color?", "memory_recall"),
    ("What did I tell you about the project codename?", "memory_recall"),
)

PASSTHROUGH_CASES = (
    "What time is it in Tokyo?",
    "I have a date tomorrow.",
    "Which time zone setting should I use?",
    "The movie starts at what time?",
    "What is my plan for tomorrow?",
)


def build_report(memory: BridgeMemory, *, now: datetime | None = None) -> dict[str, Any]:
    issues: list[str] = []
    routes: dict[str, int] = {}

    for index, (question, expected_tool) in enumerate(ROUTED_CASES, start=1):
        result = resolve_local_fact(question, memory, now=now)
        if result is None:
            issues.append(f"routed_case_unresolved:{index}")
            continue
        routes[result.tool] = routes.get(result.tool, 0) + 1
        if result.tool != expected_tool:
            issues.append(f"routed_case_wrong_tool:{index}:{result.tool}")
        response = json.loads(result.character_response())
        if not str(response.get("spoken_text", "")).strip():
            issues.append(f"routed_case_empty_response:{index}")
        if response.get("memory_write") != {} or response.get("memory_forget") != []:
            issues.append(f"routed_case_mutates_memory:{index}")

    for index, question in enumerate(PASSTHROUGH_CASES, start=1):
        if resolve_local_fact(question, memory, now=now) is not None:
            issues.append(f"passthrough_case_intercepted:{index}")

    return {
        "schema": "stackchan.trusted-facts-smoke.v1",
        "ready": not issues,
        "modelInvocations": 0,
        "audioPlayed": False,
        "routedCases": len(ROUTED_CASES),
        "passthroughCases": len(PASSTHROUGH_CASES),
        "routes": routes,
        "preferredNamePresent": bool(memory.preferred_name),
        "memorySchema": "stackchan.bridge-memory.v3",
        "issues": issues,
    }


def build_arg_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description="Silently verify Stackchan trusted local facts.")
    parser.add_argument(
        "--memory-file",
        type=Path,
        default=Path("output/pc-brain/latest/memory.json"),
        help="Production bridge memory file to load.",
    )
    parser.add_argument("--json", action="store_true", help="Print the complete JSON report.")
    return parser


def main() -> int:
    args = build_arg_parser().parse_args()
    memory = load_bridge_memory(args.memory_file) if args.memory_file.exists() else BridgeMemory()
    report = build_report(memory)
    if args.json:
        print(json.dumps(report, indent=2, sort_keys=True))
    else:
        status = "ready" if report["ready"] else "failed"
        print(f"Trusted facts: {status}; routed={report['routedCases']} passthrough={report['passthroughCases']}")
    return 0 if report["ready"] else 1


if __name__ == "__main__":
    raise SystemExit(main())
