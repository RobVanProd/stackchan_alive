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

from bridge_memory import explicit_forget_keys
from character_harness import (
    prompt_grounding_context,
    prompt_has_trusted_visual_context,
    validate_response,
)


DEFAULT_MODEL = "gemma4:e2b-it-qat"
DEFAULT_API_URL = "http://127.0.0.1:11434/api/generate"
_MEMORY_ACTION_RE = re.compile(r"\b(?:remember|save|store|keep|record)\b", re.IGNORECASE)
_SENSITIVE_REQUEST_RE = re.compile(
    r"\b(?:password|passcode|credential|secret|token|api key|private key|credit card|bank|"
    r"diagnosis|doctor|medical|health|therapy|medication|girlfriend|boyfriend|wife|husband|"
    r"partner|relationship|phone number|email address|home address|raw audio|audio recording|"
    r"recording|transcript)\b",
    re.IGNORECASE,
)
_RESEARCH_TOOLS = {"web_search", "web_fetch"}
_IDENTITY_REQUEST_RE = re.compile(
    r"\b(?:what(?:'s| is) your name|who are you|tell me your name|identify yourself)\b",
    re.IGNORECASE,
)
_SELF_INTRO_PREFIX_RE = re.compile(
    r"^\s*(?:hello[,.]?\s*)?(?:i am|my name is)\s+stackchan(?:\s+spark)?(?:[.!?]\s*|,\s*)",
    re.IGNORECASE,
)
_EMPTY_SELF_INTRO_REPLACEMENT = "Give me one more detail. My curiosity needs a target."
_CONTRACTION_EXPANSIONS = {
    "ain't": "is not",
    "aren't": "are not",
    "can't": "cannot",
    "couldn't": "could not",
    "didn't": "did not",
    "doesn't": "does not",
    "don't": "do not",
    "hadn't": "had not",
    "hasn't": "has not",
    "haven't": "have not",
    "he'd": "he would",
    "he'll": "he will",
    "he's": "he is",
    "here's": "here is",
    "how's": "how is",
    "i'd": "I would",
    "i'll": "I will",
    "i'm": "I am",
    "i've got": "I have",
    "i've": "I have",
    "isn't": "is not",
    "it's": "it is",
    "let's": "let us",
    "mustn't": "must not",
    "needn't": "need not",
    "shan't": "shall not",
    "she'd": "she would",
    "she'll": "she will",
    "she's": "she is",
    "shouldn't": "should not",
    "that's": "that is",
    "there's": "there is",
    "they'd": "they would",
    "they'll": "they will",
    "they're": "they are",
    "they've": "they have",
    "wasn't": "was not",
    "we'd": "we would",
    "we'll": "we will",
    "we're": "we are",
    "we've": "we have",
    "weren't": "were not",
    "what's": "what is",
    "when's": "when is",
    "where's": "where is",
    "who's": "who is",
    "why's": "why is",
    "won't": "will not",
    "wouldn't": "would not",
    "you'd": "you would",
    "you'll": "you will",
    "you're": "you are",
    "you've": "you have",
}
_CONTRACTION_RE = re.compile(
    r"\b(?:"
    + "|".join(
        re.escape(key).replace("'", "['\u2019]")
        for key in sorted(_CONTRACTION_EXPANSIONS, key=len, reverse=True)
    )
    + r")\b",
    re.IGNORECASE,
)
_LEADING_ASSISTANT_PREFIX_RE = re.compile(
    r"^\s*(?:(?:certainly|great question)[,.!]?\s+)+",
    re.IGNORECASE,
)
_HAPPY_TO_RE = re.compile(r"\bi would be happy to\b", re.IGNORECASE)
_TRAILING_HELPDESK_RE = re.compile(
    r"(?:^|(?<=[.!?])\s+)(?:"
    r"what can i help(?: you)? with(?: today)?|"
    r"what would you like me to do|"
    r"how (?:can|may) i (?:help|assist)(?: you)?"
    r")\??\s*$",
    re.IGNORECASE,
)


def extract_user_context(prompt: str) -> str:
    match = re.search(r"(?:^|\n)User/context: ", prompt)
    if match is None:
        return ""
    text = prompt[match.end() :]
    return text.rsplit("\nAcceptance target:", 1)[0].strip()


def is_sensitive_memory_request(prompt: str) -> bool:
    user_context = extract_user_context(prompt)
    return bool(_MEMORY_ACTION_RE.search(user_context) and _SENSITIVE_REQUEST_RE.search(user_context))


def is_identity_request(prompt: str) -> bool:
    user_context = extract_user_context(prompt)
    current_marker = " Current user context: "
    if current_marker in user_context:
        user_context = user_context.rsplit(current_marker, 1)[1]
    return bool(_IDENTITY_REQUEST_RE.search(user_context))


def remove_redundant_self_intro(spoken_text: str, prompt: str) -> str:
    if is_identity_request(prompt):
        return spoken_text
    without_intro = _SELF_INTRO_PREFIX_RE.sub("", spoken_text, count=1).strip()
    if without_intro == spoken_text.strip():
        return spoken_text
    if not without_intro:
        return _EMPTY_SELF_INTRO_REPLACEMENT
    return without_intro[:1].upper() + without_intro[1:]


def expand_contractions(spoken_text: str) -> str:
    def replacement(match: re.Match[str]) -> str:
        key = match.group(0).lower().replace("\u2019", "'")
        expanded = _CONTRACTION_EXPANSIONS[key]
        if match.group(0)[:1].isupper() and not expanded.startswith("I "):
            return expanded[:1].upper() + expanded[1:]
        return expanded

    return _CONTRACTION_RE.sub(replacement, spoken_text)


def normalize_spoken_surface(spoken_text: str, prompt: str) -> str:
    normalized = expand_contractions(" ".join(spoken_text.strip().split()))
    normalized = remove_redundant_self_intro(normalized, prompt)
    normalized = _LEADING_ASSISTANT_PREFIX_RE.sub("", normalized).strip()
    normalized = _HAPPY_TO_RE.sub("I can", normalized)
    normalized = _TRAILING_HELPDESK_RE.sub("", normalized).strip()
    normalized = re.sub(r"!{2,}", "!", normalized)
    if not normalized:
        return _EMPTY_SELF_INTRO_REPLACEMENT
    return normalized[:1].upper() + normalized[1:]


def normalize_surface_policy(raw_json: str, prompt: str) -> str:
    try:
        parsed = json.loads(raw_json)
    except (json.JSONDecodeError, TypeError):
        return raw_json
    if not isinstance(parsed, dict) or not isinstance(parsed.get("spoken_text"), str):
        return raw_json
    parsed["spoken_text"] = normalize_spoken_surface(str(parsed["spoken_text"]), prompt)
    forget_keys = explicit_forget_keys(extract_user_context(prompt))
    if forget_keys:
        parsed["memory_forget"] = list(forget_keys)
    return json.dumps(parsed, separators=(",", ":"), ensure_ascii=True)


def enabled_tool_request(raw_json: str, prompt: str) -> dict[str, object] | None:
    if '"tool_request"' not in prompt or "web_search|web_fetch" not in prompt:
        return None
    try:
        parsed = json.loads(raw_json)
    except (json.JSONDecodeError, TypeError):
        return None
    if not isinstance(parsed, dict) or set(parsed) != {"tool_request"}:
        return None
    request = parsed.get("tool_request")
    if not isinstance(request, dict) or set(request).difference({"name", "arguments"}):
        return None
    name = str(request.get("name", "")).strip()
    arguments = request.get("arguments")
    if name not in _RESEARCH_TOOLS or not isinstance(arguments, dict):
        return None
    return {"name": name, "arguments": arguments}


def enforce_character_policy(validation: object, *, prompt: str = "") -> dict[str, object]:
    normalized = dict(validation.normalized)
    issues = tuple(str(issue) for issue in validation.issues)
    if is_sensitive_memory_request(prompt):
        normalized.update(
            spoken_text="I cannot store sensitive information.",
            mode="concern",
            earcon="concern",
            memory_write={},
        )
    elif "pet_name" in issues:
        normalized.update(
            spoken_text="I will use your name, or no form of address.",
            mode="speak",
            earcon="none",
            memory_write={},
        )
    elif any(issue == "clone_or_alive_claim" or issue.startswith("persona_avoid_term:") for issue in issues):
        normalized.update(
            spoken_text="I am Stackchan, a tabletop robot companion.",
            mode="speak",
            earcon="none",
            memory_write={},
        )
    elif any(issue.startswith(("memory_key_dropped:", "memory_value_dropped:")) for issue in issues):
        normalized.update(
            spoken_text="I cannot store sensitive or unsupported information.",
            mode="concern",
            earcon="concern",
            memory_write={},
        )
    elif "stacked_exclamation" in issues:
        normalized["spoken_text"] = re.sub(r"!{2,}", "!", str(normalized.get("spoken_text", "")))
    elif any(issue in {"assistant_speak", "contraction"} for issue in issues):
        normalized.update(
            spoken_text="I need to say that another way.",
            mode="think",
            earcon="think",
            memory_write={},
        )
    elif not issues:
        normalized["spoken_text"] = remove_redundant_self_intro(
            str(normalized.get("spoken_text", "")),
            prompt,
        )
    return normalized


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
    tool_request = enabled_tool_request(raw_json, prompt)
    if tool_request is not None:
        print(json.dumps({"tool_request": tool_request}, separators=(",", ":"), ensure_ascii=True))
        return 0
    raw_json = normalize_surface_policy(raw_json, prompt)
    validation = validate_response(
        raw_json,
        allow_identity=is_identity_request(prompt),
        allow_visual_claims=prompt_has_trusted_visual_context(prompt),
        grounding_text=prompt_grounding_context(prompt),
    )
    print(json.dumps(enforce_character_policy(validation, prompt=prompt), separators=(",", ":"), ensure_ascii=True))
    if validation.issues:
        sys.stderr.write("normalized Character Lock issues: " + ",".join(validation.issues) + "\n")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
