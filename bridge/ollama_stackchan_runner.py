#!/usr/bin/env python3
"""Ollama-backed Stackchan runner that emits Character Lock JSON only."""

from __future__ import annotations

import json
import os
import re
import subprocess
import sys
import urllib.error
import urllib.request
from pathlib import Path

from character_harness import validate_response


DEFAULT_MODEL = "gemma4:e2b-it-qat"
DEFAULT_API_URL = "http://127.0.0.1:11434/api/generate"


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


def run_api(prompt: str, model: str) -> str:
    api_url = os.environ.get("STACKCHAN_OLLAMA_API_URL", DEFAULT_API_URL).strip() or DEFAULT_API_URL
    timeout_seconds = max(1.0, float(os.environ.get("STACKCHAN_OLLAMA_TIMEOUT_SECONDS", "30")))
    payload = {
        "model": model,
        "prompt": prompt,
        "stream": False,
        "format": "json",
        "think": False,
        "keep_alive": -1,
        "options": {
            "temperature": float(os.environ.get("STACKCHAN_OLLAMA_TEMPERATURE", "0.2")),
            "num_ctx": int(os.environ.get("STACKCHAN_OLLAMA_NUM_CTX", "4096")),
            "num_predict": int(os.environ.get("STACKCHAN_OLLAMA_NUM_PREDICT", "160")),
        },
    }
    request = urllib.request.Request(
        api_url,
        data=json.dumps(payload, separators=(",", ":")).encode("utf-8"),
        headers={"Content-Type": "application/json"},
        method="POST",
    )
    with urllib.request.urlopen(request, timeout=timeout_seconds) as response:
        result = json.loads(response.read().decode("utf-8"))
    if result.get("error"):
        raise RuntimeError(str(result["error"]))
    text = str(result.get("response", "")).strip()
    if not text:
        raise RuntimeError("Ollama API returned no response text")
    return text


def run_cli(prompt: str, model: str) -> str:
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
        raise RuntimeError(completed.stderr.strip() or f"ollama exited {completed.returncode}")
    return completed.stdout


def main() -> int:
    prompt = sys.stdin.read()
    model = os.environ.get("STACKCHAN_OLLAMA_MODEL", DEFAULT_MODEL).strip() or DEFAULT_MODEL
    transport = os.environ.get("STACKCHAN_OLLAMA_TRANSPORT", "api-with-cli-fallback").strip().lower()
    try:
        if transport == "cli":
            raw_output = run_cli(prompt, model)
        else:
            try:
                raw_output = run_api(prompt, model)
            except (OSError, RuntimeError, ValueError, urllib.error.URLError) as exc:
                if transport == "api":
                    raise
                sys.stderr.write(f"Ollama API unavailable; using CLI fallback: {exc}\n")
                raw_output = run_cli(prompt, model)
    except (OSError, RuntimeError, ValueError, urllib.error.URLError) as exc:
        sys.stderr.write(f"Ollama runner failed: {exc}\n")
        return 1

    raw_json = extract_json_object(raw_output)
    validation = validate_response(raw_json)
    print(json.dumps(validation.normalized, separators=(",", ":"), ensure_ascii=True))
    if validation.issues:
        sys.stderr.write("normalized Character Lock issues: " + ",".join(validation.issues) + "\n")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
