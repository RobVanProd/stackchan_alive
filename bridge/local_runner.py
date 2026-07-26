#!/usr/bin/env python3
"""Local model runner wrapper for the P7 Stackchan bridge."""

from __future__ import annotations

import argparse
import json
import os
import re
import time
from dataclasses import dataclass
from typing import Any

from cancellable_process import ProcessTimeoutError, run_cancellable_process
from cancellation import CancellationToken
from character_harness import (
    MODEL_PROFILES,
    PROMPT_SUITE,
    HarnessResult,
    build_prompt,
    trusted_visual_context_available,
    validate_response,
)
from persona_pack import DEFAULT_PERSONA_ID, PersonaPack, load_and_validate_persona_pack

DEFAULT_PROFILE = "gemma4-e2b-gguf"
RUNTIME_ACCEPTANCE_TARGETS = {
    "greeting": (
        "Respond naturally with useful substance. Do not introduce yourself unless the user asks "
        "who you are. If low-stakes, make the second sentence a brief wry situational beat."
    ),
    "picked_up": "React to the trusted physical event with brief surprise or delight and no invented danger.",
    "low_battery": "Give calm, grounded power guidance using trusted telemetry only; do not invent a percentage.",
    "question": (
        "Answer the actual user directly without introducing yourself unless asked. Never invent "
        "sensor evidence or physical state. Match the low-stakes tone examples when appropriate: "
        "give the useful answer first, then one brief playful or wry reaction about the shared "
        "situation. If context is insufficient, ask exactly one natural follow-up instead of guessing."
    ),
    "confused": "State what is unclear and ask for exactly one missing detail.",
    "remember": "Acknowledge the actual safe durable fact and write only its matching allowed memory key and value.",
    "forget": "Confirm the actual request and forget only the matching allowed memory key or namespace.",
    "callback_open_loop": "Ask once about the due callback in memory and do not copy it into memory_write.",
    "episode_recall": "Answer the explicit recall request using the relevant episode without reciting memory metadata.",
}
GENERIC_COMMAND_ENV = "STACKCHAN_MODEL_COMMAND"

RUNNER_PROFILES: dict[str, dict[str, str]] = {
    "gemma4-e2b-gguf": {
        **MODEL_PROFILES["gemma4-e2b-gguf"],
        "command_env": "STACKCHAN_GEMMA4_E2B_GGUF_COMMAND",
        "example_command": "ollama run hf.co/google/gemma-4-E2B-it-qat-q4_0-gguf:Q4_0",
        "status": "primary",
    },
    "gemma4-e2b-litert-lm": {
        **MODEL_PROFILES["gemma4-e2b-litert-lm"],
        "command_env": "STACKCHAN_GEMMA4_E2B_LITERT_COMMAND",
        "example_command": "python bridge\\litert_lm_stackchan_wrapper.py",
        "status": "mobile-low-active-memory",
    },
    "gemma4-e4b-gguf": {
        **MODEL_PROFILES["gemma4-e4b-gguf"],
        "command_env": "STACKCHAN_GEMMA4_E4B_GGUF_COMMAND",
        "example_command": "ollama run hf.co/google/gemma-4-E4B-it-qat-q4_0-gguf:Q4_0",
        "status": "fallback",
    },
}

DETERMINISTIC_RESPONSES: dict[str, dict[str, Any]] = {
    "greeting": {
        "spoken_text": "Hello. Curiosity systems are online.",
        "mode": "happy",
        "earcon": "happy",
        "emotion": {"arousal": 0.2, "valence": 0.25},
        "memory_write": {},
        "memory_forget": [],
    },
    "picked_up": {
        "spoken_text": "Whoa. Altitude change detected.",
        "mode": "react",
        "earcon": "confirm",
        "emotion": {"arousal": 0.3, "valence": 0.2},
        "memory_write": {},
        "memory_forget": [],
    },
    "low_battery": {
        "spoken_text": "Power is low. I will rest soon.",
        "mode": "safety",
        "earcon": "safety",
        "emotion": {"arousal": -0.1, "valence": -0.2},
        "memory_write": {},
        "memory_forget": [],
    },
    "question": {
        "spoken_text": "I am Stackchan Spark.",
        "mode": "speak",
        "earcon": "none",
        "emotion": {"arousal": 0.1, "valence": 0.2},
        "memory_write": {},
        "memory_forget": [],
    },
    "confused": {
        "spoken_text": "I need a little more data. Which part should I inspect?",
        "mode": "think",
        "earcon": "think",
        "emotion": {"arousal": 0.0, "valence": 0.0},
        "memory_write": {},
        "memory_forget": [],
    },
    "remember": {
        "spoken_text": "Teal. I will remember that.",
        "mode": "happy",
        "earcon": "confirm",
        "emotion": {"arousal": 0.0, "valence": 0.2},
        "memory_write": {"user.favorite_color": "teal"},
        "memory_forget": [],
    },
    "forget": {
        "spoken_text": "Deleted. It is gone.",
        "mode": "concern",
        "earcon": "confirm",
        "emotion": {"arousal": 0.0, "valence": -0.1},
        "memory_write": {},
        "memory_forget": ["project."],
    },
    "callback_open_loop": {
        "spoken_text": "How did the servo calibration go?",
        "mode": "attend",
        "earcon": "none",
        "emotion": {"arousal": 0.1, "valence": 0.15},
        "memory_write": {},
        "memory_forget": [],
    },
    "episode_recall": {
        "spoken_text": "We were talking about voice calibration.",
        "mode": "speak",
        "earcon": "none",
        "emotion": {"arousal": 0.1, "valence": 0.2},
        "memory_write": {},
        "memory_forget": [],
    },
}


class RunnerConfigurationError(RuntimeError):
    """Raised when the caller requires a real runner but none is configured."""


class RunnerExecutionError(RuntimeError):
    """Raised when a configured model command fails."""


@dataclass
class RunnerResult:
    profile: str
    persona: str
    model: str
    runtime: str
    prompt_case: str
    prompt: str
    raw_response: str
    validation: HarnessResult
    configured_runner: bool
    command_source: str
    elapsed_ms: float | None = None
    approx_tokens_per_sec: float | None = None
    response_repaired: bool = False
    repair_reason: str = ""

    def to_dict(self) -> dict[str, object]:
        payload: dict[str, object] = {
            "profile": self.profile,
            "persona": self.persona,
            "model": self.model,
            "runtime": self.runtime,
            "prompt_case": self.prompt_case,
            "configured_runner": self.configured_runner,
            "command_source": self.command_source,
            "raw_response": self.raw_response,
            "validation": self.validation.to_dict(),
        }
        if self.elapsed_ms is not None:
            payload["elapsed_ms"] = round(self.elapsed_ms, 2)
        if self.approx_tokens_per_sec is not None:
            payload["approx_tokens_per_sec"] = round(self.approx_tokens_per_sec, 2)
        if self.response_repaired:
            payload["response_repaired"] = True
            payload["repair_reason"] = self.repair_reason
        return payload


def prompt_case_by_name(case_name: str) -> dict[str, object]:
    for case in PROMPT_SUITE:
        if case["name"] == case_name:
            return case
    known = ", ".join(case["name"] for case in PROMPT_SUITE)
    raise ValueError(f"unknown prompt case '{case_name}'; expected one of: {known}")


def _with_persona_line(response: dict[str, Any], persona: PersonaPack, intent: str) -> dict[str, Any]:
    line = persona.spoken_line(intent)
    if not line:
        return dict(response)
    updated = dict(response)
    updated["spoken_text"] = str(line.get("text", updated["spoken_text"]))
    updated["earcon"] = str(line.get("earcon", updated["earcon"]))
    return updated


def deterministic_response(case_name: str, persona: PersonaPack | None = None) -> str:
    response = dict(DETERMINISTIC_RESPONSES.get(case_name, DETERMINISTIC_RESPONSES["greeting"]))
    if persona is not None and case_name == "question":
        response["spoken_text"] = f"I am {persona.display_name}."
    if persona is not None and persona.pack_id != DEFAULT_PERSONA_ID:
        intent_by_case = {
            "greeting": "boot",
            "picked_up": "react",
            "low_battery": "safety",
            "confused": "concern",
        }
        intent = intent_by_case.get(case_name)
        if intent:
            response = _with_persona_line(response, persona, intent)
        if case_name == "confused":
            response["mode"] = "concern"
    return json.dumps(response, separators=(",", ":"), ensure_ascii=True)


_CONTINUITY_STOP_WORDS = {
    "about",
    "again",
    "before",
    "have",
    "mentioned",
    "talked",
    "that",
    "the",
    "this",
    "tomorrow",
    "turns",
    "with",
}
_EMPTY_MODEL_RESPONSES = {
    "correction. i lost the useful part.",
    "i lost my train of thought.",
    "i need to say that another way.",
}
_GREETING_RE = re.compile(
    r"\b(?:hello|hi|hey|good morning|good afternoon|good evening)\b",
    re.IGNORECASE,
)


def _continuity_subject(memory_lines: tuple[str, ...]) -> tuple[str, str]:
    prefix = "ask_about: "
    line = next((item[len(prefix):] for item in memory_lines if item.startswith(prefix)), "")
    if not line:
        return "", ""
    subject = re.sub(r"\(\s*\d+\s+turns?\s*\)", "", line, flags=re.IGNORECASE)
    subject = re.sub(
        r"^(?:i\s+(?:have|am going to)|we\s+(?:have|are going to)|talked about)\s+",
        "",
        subject,
        flags=re.IGNORECASE,
    )
    subject = re.sub(
        r"\b(?:tonight|tomorrow|this weekend|next week)\b",
        "",
        subject,
        flags=re.IGNORECASE,
    )
    subject = " ".join(re.findall(r"[A-Za-z0-9][A-Za-z0-9' -]*", subject)).strip(" ,.-")
    subject = " ".join(subject.split())[:72].rstrip(" ,.-")
    return ("open_loop", subject) if subject else ("", "")


def _mentions_subject(spoken_text: str, subject: str) -> bool:
    spoken = spoken_text.lower()
    terms = [
        token
        for token in re.findall(r"[a-z0-9]+", subject.lower())
        if len(token) >= 4 and token not in _CONTINUITY_STOP_WORDS
    ]
    return bool(terms) and any(term in spoken for term in terms)


def _approved_forget_targets(
    memory_lines: tuple[str, ...],
    user_text: str,
) -> tuple[str, ...]:
    normalized_user = " ".join(re.findall(r"[a-z0-9]+", user_text.lower()))
    if not normalized_user:
        return ()
    targets: list[str] = []
    for line in memory_lines:
        match = re.match(
            r"^approved_fact ((?:user|project)\.[A-Za-z0-9_.-]+): ",
            line,
        )
        if match is None:
            continue
        key = match.group(1)
        subject = key.partition(".")[2]
        normalized_subject = " ".join(re.findall(r"[a-z0-9]+", subject.lower()))
        if normalized_subject and normalized_subject in normalized_user:
            targets.append(key)
    return tuple(dict.fromkeys(targets))


def repair_runner_response(
    case_name: str,
    raw_response: str,
    persona: PersonaPack,
    *,
    memory_lines: tuple[str, ...] = (),
    user_text: str = "",
    allow_identity: bool = False,
    allow_visual_claims: bool = False,
) -> tuple[str, str]:
    grounding_text = "\n".join((user_text, *memory_lines))
    validation = validate_response(
        raw_response,
        persona,
        allow_identity=allow_identity,
        allow_visual_claims=allow_visual_claims,
        grounding_text=grounding_text,
    )
    spoken_text = str(validation.normalized.get("spoken_text", ""))
    if (
        case_name == "greeting"
        and spoken_text.strip().lower() in _EMPTY_MODEL_RESPONSES
        and _GREETING_RE.search(user_text)
    ):
        return deterministic_response("greeting", persona), "greeting_semantics"
    if case_name == "forget":
        forget_targets = _approved_forget_targets(memory_lines, user_text)
        if forget_targets and tuple(validation.normalized.get("memory_forget", ())) != forget_targets:
            repaired = {
                "spoken_text": "Deleted. It is gone.",
                "mode": "speak",
                "earcon": "confirm",
                "emotion": {"arousal": 0.0, "valence": 0.1},
                "memory_write": {},
                "memory_forget": list(forget_targets),
            }
            repaired_raw = json.dumps(repaired, separators=(",", ":"), ensure_ascii=True)
            repaired_validation = validate_response(
                repaired_raw,
                persona,
                allow_visual_claims=allow_visual_claims,
                grounding_text=grounding_text,
            )
            if repaired_validation.ok:
                return repaired_raw, "forget_exact_key"
    if case_name == "picked_up" and not any(
        term in spoken_text.lower()
        for term in ("altitude", "height", "picked", "lifted", "up")
    ):
        return deterministic_response("picked_up", persona), "picked_up_semantics"

    continuity_kind, subject = _continuity_subject(memory_lines)
    if continuity_kind and not _mentions_subject(spoken_text, subject):
        text = f"How did {subject} go?"
        mode = "attend"
        arousal = 0.1
        repaired = {
            "spoken_text": text[:140].rstrip(),
            "mode": mode,
            "earcon": "none",
            "emotion": {"arousal": arousal, "valence": 0.2},
            "memory_write": {},
            "memory_forget": [],
        }
        repaired_raw = json.dumps(repaired, separators=(",", ":"), ensure_ascii=True)
        repaired_validation = validate_response(
            repaired_raw,
            persona,
            allow_visual_claims=allow_visual_claims,
            grounding_text=grounding_text,
        )
        if repaired_validation.ok:
            return repaired_raw, f"{continuity_kind}_continuity"
    return raw_response, ""


def resolve_command(profile_id: str, override: str = "") -> tuple[str | None, str]:
    if override.strip():
        return override.strip(), "cli"
    profile = RUNNER_PROFILES[profile_id]
    profile_env = profile["command_env"]
    if os.environ.get(profile_env, "").strip():
        return os.environ[profile_env].strip(), f"env:{profile_env}"
    if os.environ.get(GENERIC_COMMAND_ENV, "").strip():
        return os.environ[GENERIC_COMMAND_ENV].strip(), f"env:{GENERIC_COMMAND_ENV}"
    return None, "deterministic_fallback"


def run_command(
    command: str,
    prompt: str,
    timeout_ms: int,
    cancellation: CancellationToken | None = None,
) -> tuple[str, float, float]:
    try:
        completed = run_cancellable_process(
            command,
            input_data=prompt.encode("utf-8"),
            timeout_ms=timeout_ms,
            cancellation=cancellation,
        )
    except ProcessTimeoutError as exc:
        raise RunnerExecutionError(f"model command timed out after {timeout_ms} ms") from exc

    elapsed_ms = completed.elapsed_ms
    stdout = completed.stdout.decode("utf-8", errors="replace").strip()
    approx_tokens = max(1, len(stdout.split()))
    approx_tokens_per_sec = approx_tokens / max(elapsed_ms / 1000.0, 0.001)
    if completed.returncode != 0:
        stderr = completed.stderr.decode("utf-8", errors="replace").strip()
        raise RunnerExecutionError(f"model command failed with exit {completed.returncode}: {stderr}")
    return stdout, elapsed_ms, approx_tokens_per_sec


def run_in_process_ollama(
    prompt: str,
    timeout_ms: int,
    cancellation: CancellationToken | None = None,
) -> tuple[str, float, float]:
    if cancellation is not None:
        cancellation.raise_if_cancelled()
    started = time.perf_counter()
    try:
        from ollama_stackchan_runner import run_character_prompt

        output = run_character_prompt(
            prompt,
            timeout_seconds=max(1, timeout_ms) / 1000.0,
        )
    except Exception as exc:
        raise RunnerExecutionError(
            f"in-process Ollama runner failed: {type(exc).__name__}: {exc}"
        ) from exc
    if cancellation is not None:
        cancellation.raise_if_cancelled()
    elapsed_ms = (time.perf_counter() - started) * 1000.0
    approx_tokens = max(1, len(output.split()))
    return output, elapsed_ms, approx_tokens / max(elapsed_ms / 1000.0, 0.001)


def run_runner_profile(
    profile_id: str = DEFAULT_PROFILE,
    *,
    case_name: str = "greeting",
    command: str = "",
    require_runner: bool = False,
    timeout_ms: int = 60000,
    persona_id: str = DEFAULT_PERSONA_ID,
    user_text: str = "",
    research_tools_enabled: bool = False,
    embodiment_lines: tuple[str, ...] = (),
    memory_lines: tuple[str, ...] = (),
    conversation_lines: tuple[str, ...] = (),
    cancellation: CancellationToken | None = None,
    allow_identity: bool = False,
    in_process_ollama: bool = False,
) -> RunnerResult:
    if profile_id not in RUNNER_PROFILES:
        known = ", ".join(sorted(RUNNER_PROFILES))
        raise ValueError(f"unknown runner profile '{profile_id}'; expected one of: {known}")

    persona = load_and_validate_persona_pack(persona_id)
    case = dict(prompt_case_by_name(case_name))
    if user_text.strip():
        case["user"] = user_text.strip()
        case["expect"] = RUNTIME_ACCEPTANCE_TARGETS[case_name]
        for benchmark_key in (
            "requires_memory_write",
            "required_memory_write",
            "requires_memory_forget",
            "benchmark_memory_lines",
        ):
            case.pop(benchmark_key, None)
    prompt = build_prompt(
        case,
        persona,
        research_tools_enabled=research_tools_enabled,
        embodiment_lines=embodiment_lines,
        memory_lines=memory_lines,
        conversation_lines=conversation_lines,
    )
    resolved_command, command_source = resolve_command(profile_id, command)
    use_in_process_ollama = bool(
        in_process_ollama and profile_id == "gemma4-e2b-gguf"
    )
    configured_runner = resolved_command is not None or use_in_process_ollama
    elapsed_ms: float | None = None
    approx_tokens_per_sec: float | None = None

    if use_in_process_ollama:
        raw_response, elapsed_ms, approx_tokens_per_sec = run_in_process_ollama(
            prompt,
            timeout_ms,
            cancellation,
        )
        command_source = "in-process-ollama-api"
    elif resolved_command:
        raw_response, elapsed_ms, approx_tokens_per_sec = run_command(
            resolved_command, prompt, timeout_ms, cancellation
        )
    else:
        if require_runner:
            profile_env = RUNNER_PROFILES[profile_id]["command_env"]
            raise RunnerConfigurationError(
                f"no command configured for {profile_id}; set {profile_env}, {GENERIC_COMMAND_ENV}, or pass --command"
            )
        raw_response = deterministic_response(case_name, persona)

    identity_allowed = allow_identity or (case_name == "question" and not user_text.strip())
    visual_claims_allowed = trusted_visual_context_available(embodiment_lines)
    raw_response, repair_reason = repair_runner_response(
        case_name,
        raw_response,
        persona,
        memory_lines=memory_lines,
        user_text=str(case["user"]),
        allow_identity=identity_allowed,
        allow_visual_claims=visual_claims_allowed,
    )
    validation = validate_response(
        raw_response,
        persona,
        allow_identity=identity_allowed,
        allow_visual_claims=visual_claims_allowed,
        grounding_text="\n".join(
            (str(case["user"]), *memory_lines, *conversation_lines)
        ),
    )
    validation.elapsed_ms = elapsed_ms
    validation.approx_tokens_per_sec = approx_tokens_per_sec
    profile = RUNNER_PROFILES[profile_id]
    return RunnerResult(
        profile=profile_id,
        persona=persona.pack_id,
        model=profile["model"],
        runtime=profile["runtime"],
        prompt_case=case["name"],
        prompt=prompt,
        raw_response=raw_response,
        validation=validation,
        configured_runner=configured_runner,
        command_source=command_source,
        elapsed_ms=elapsed_ms,
        approx_tokens_per_sec=approx_tokens_per_sec,
        response_repaired=bool(repair_reason),
        repair_reason=repair_reason,
    )


def profile_payload() -> dict[str, dict[str, str]]:
    return {key: dict(value) for key, value in RUNNER_PROFILES.items()}


def build_arg_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description="Run or dry-run a local Stackchan P7 model profile.")
    parser.add_argument("--list", action="store_true", help="Print available runner profiles as JSON and exit.")
    parser.add_argument("--profile", choices=sorted(RUNNER_PROFILES), default=DEFAULT_PROFILE)
    parser.add_argument("--case", default="greeting", help="Prompt-suite case to run.")
    parser.add_argument("--command", default="", help="Optional local model command. Prompt is passed on stdin.")
    parser.add_argument("--require-runner", action="store_true", help="Fail instead of using deterministic fallback.")
    parser.add_argument("--timeout-ms", type=int, default=60000)
    parser.add_argument("--persona", default=DEFAULT_PERSONA_ID, help="Persona pack id or path. Defaults to spark.")
    parser.add_argument("--raw", action="store_true", help="Print only the raw Character Lock JSON response.")
    parser.add_argument("--json", action="store_true", help="Print the full runner result as JSON.")
    return parser


def main() -> int:
    args = build_arg_parser().parse_args()
    if args.list:
        print(json.dumps(profile_payload(), indent=2, sort_keys=True))
        return 0

    try:
        result = run_runner_profile(
            args.profile,
            case_name=args.case,
            command=args.command,
            require_runner=args.require_runner,
            timeout_ms=args.timeout_ms,
            persona_id=args.persona,
        )
    except (RunnerConfigurationError, RunnerExecutionError, ValueError) as exc:
        print(str(exc))
        return 2

    if args.raw:
        print(result.raw_response)
    else:
        print(json.dumps(result.to_dict(), indent=2, sort_keys=True))
    return 0 if result.validation.ok else 1


if __name__ == "__main__":
    raise SystemExit(main())
