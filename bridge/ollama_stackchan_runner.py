#!/usr/bin/env python3
"""Ollama-backed Stackchan runner that emits Character Lock JSON only."""

from __future__ import annotations

import json
import os
import re
import subprocess
import sys
from pathlib import Path

from character_harness import validate_response


DEFAULT_MODEL = "gemma4:e2b-it-qat"


def default_ollama_exe() -> str:
    configured = os.environ.get("STACKCHAN_OLLAMA_EXE", "").strip()
    if configured:
        return configured
    local_app_data = os.environ.get("LOCALAPPDATA", "")
    if local_app_data:
        candidate = Path(local_app_data) / "Programs" / "Ollama" / "ollama.exe"
        if candidate.exists():
            return str(candidate)
    return "ollama"


def extract_json_object(text: str) -> str:
    cleaned = text.strip().lstrip("\ufeff")
    if cleaned.startswith("{") and cleaned.endswith("}"):
        return cleaned
    fence = re.search(r"```(?:json)?\s*(\{.*?\})\s*```", cleaned, flags=re.DOTALL | re.IGNORECASE)
    if fence:
        return fence.group(1)
    start = cleaned.find("{")
    end = cleaned.rfind("}")
    if start >= 0 and end > start:
        return cleaned[start : end + 1]
    return cleaned


def main() -> int:
    prompt = sys.stdin.read()
    model = os.environ.get("STACKCHAN_OLLAMA_MODEL", DEFAULT_MODEL).strip() or DEFAULT_MODEL
    command = [
        default_ollama_exe(),
        "run",
        model,
        "--format",
        "json",
        "--think",
        "false",
        "--hidethinking",
        "--nowordwrap",
    ]
    completed = subprocess.run(
        command,
        input=prompt,
        capture_output=True,
        text=True,
        encoding="utf-8",
        errors="replace",
        check=False,
    )
    if completed.returncode != 0:
        sys.stderr.write(completed.stderr)
        return completed.returncode

    raw_json = extract_json_object(completed.stdout)
    validation = validate_response(raw_json)
    print(json.dumps(validation.normalized, separators=(",", ":"), ensure_ascii=True))
    if validation.issues:
        sys.stderr.write("normalized Character Lock issues: " + ",".join(validation.issues) + "\n")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
