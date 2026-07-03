#!/usr/bin/env python3
"""LiteRT-LM command adapter for Stackchan Character Lock responses.

The real LiteRT-LM executable/API is intentionally outside this repository. This
wrapper defines the stable bridge contract: read the Stackchan prompt on stdin,
run a configured LiteRT-LM command with that prompt on stdin, extract the first
JSON object from stdout, validate it as Character Lock JSON, then print only the
normalized response JSON for `bridge/local_runner.py`.
"""

from __future__ import annotations

import argparse
import json
import os
import subprocess
import sys
import time
from dataclasses import dataclass

from character_harness import validate_response

COMMAND_ENV = "STACKCHAN_LITERT_LM_COMMAND"
SCHEMA = "stackchan.litert-lm-wrapper.v1"


class LiteRtWrapperError(RuntimeError):
    """Raised when the LiteRT-LM wrapper cannot produce a valid response."""


@dataclass(frozen=True)
class LiteRtWrapperResult:
    response_json: str
    elapsed_ms: float
    command_source: str
    raw_stdout_bytes: int

    def to_dict(self) -> dict[str, object]:
        return {
            "schema": SCHEMA,
            "response": json.loads(self.response_json),
            "elapsed_ms": round(self.elapsed_ms, 2),
            "command_source": self.command_source,
            "raw_stdout_bytes": self.raw_stdout_bytes,
        }


def resolve_command(override: str = "") -> tuple[str | None, str]:
    if override.strip():
        return override.strip(), "cli"
    configured = os.environ.get(COMMAND_ENV, "").strip()
    if configured:
        return configured, f"env:{COMMAND_ENV}"
    return None, "unconfigured"


def extract_json_object_at(text: str, start: int) -> str:
    depth = 0
    in_string = False
    escaped = False
    for index in range(start, len(text)):
        char = text[index]
        if in_string:
            if escaped:
                escaped = False
            elif char == "\\":
                escaped = True
            elif char == '"':
                in_string = False
            continue

        if char == '"':
            in_string = True
        elif char == "{":
            depth += 1
        elif char == "}":
            depth -= 1
            if depth == 0:
                return text[start : index + 1]

    raise LiteRtWrapperError("LiteRT-LM output contained incomplete JSON")


def extract_first_json_object(text: str) -> str:
    start = text.find("{")
    while start >= 0:
        try:
            candidate = extract_json_object_at(text, start)
            json.loads(candidate)
            return candidate
        except json.JSONDecodeError:
            start = text.find("{", start + 1)
        except LiteRtWrapperError:
            start = text.find("{", start + 1)
    raise LiteRtWrapperError("LiteRT-LM output did not contain a valid JSON object")


def normalize_character_json(raw_output: str) -> str:
    candidate = extract_first_json_object(raw_output)
    result = validate_response(candidate)
    if not result.ok:
        issues = ", ".join(result.issues)
        raise LiteRtWrapperError(f"LiteRT-LM output failed Character Lock validation: {issues}")
    return json.dumps(result.normalized, separators=(",", ":"), ensure_ascii=True)


def run_litert_command(command: str, prompt: str, timeout_ms: int) -> tuple[str, float]:
    start = time.perf_counter()
    try:
        completed = subprocess.run(
            command,
            input=prompt,
            capture_output=True,
            text=True,
            shell=True,
            check=False,
            timeout=max(timeout_ms, 1) / 1000.0,
        )
    except subprocess.TimeoutExpired as exc:
        raise LiteRtWrapperError(f"LiteRT-LM command timed out after {timeout_ms} ms") from exc

    elapsed_ms = (time.perf_counter() - start) * 1000.0
    if completed.returncode != 0:
        stderr = completed.stderr.strip()
        raise LiteRtWrapperError(f"LiteRT-LM command failed with exit {completed.returncode}: {stderr}")
    return completed.stdout, elapsed_ms


def run_wrapper(prompt: str, *, command: str = "", timeout_ms: int = 60000) -> LiteRtWrapperResult:
    resolved_command, source = resolve_command(command)
    if not resolved_command:
        raise LiteRtWrapperError(
            f"no LiteRT-LM command configured; set {COMMAND_ENV} or pass --command"
        )
    raw_output, elapsed_ms = run_litert_command(resolved_command, prompt, timeout_ms)
    response_json = normalize_character_json(raw_output)
    return LiteRtWrapperResult(
        response_json=response_json,
        elapsed_ms=elapsed_ms,
        command_source=source,
        raw_stdout_bytes=len(raw_output.encode("utf-8")),
    )


def build_arg_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description="Adapt a LiteRT-LM command to Stackchan Character Lock JSON.")
    parser.add_argument("--command", default="", help="LiteRT-LM command. Prompt is passed on stdin.")
    parser.add_argument("--timeout-ms", type=int, default=60000)
    parser.add_argument(
        "--metadata-json",
        action="store_true",
        help="Print wrapper metadata instead of the raw Character Lock response JSON.",
    )
    return parser


def main() -> int:
    args = build_arg_parser().parse_args()
    prompt = sys.stdin.read()
    try:
        result = run_wrapper(prompt, command=args.command, timeout_ms=args.timeout_ms)
    except LiteRtWrapperError as exc:
        print(str(exc), file=sys.stderr)
        return 2

    if args.metadata_json:
        print(json.dumps(result.to_dict(), indent=2, sort_keys=True))
    else:
        print(result.response_json)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
