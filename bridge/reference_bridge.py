#!/usr/bin/env python3
"""Deterministic host-side reference for stackchan.bridge.v1 control frames."""

from __future__ import annotations

import argparse
import json
import re
import sys
from dataclasses import dataclass, replace
from pathlib import Path
from typing import Iterable, Iterator, Literal

from bridge_memory import MAX_MEMORY_ITEMS, BridgeMemory, load_bridge_memory, reset_bridge_memory, save_bridge_memory
from character_harness import HarnessResult, validate_response
from local_runner import RUNNER_PROFILES, RunnerConfigurationError, RunnerExecutionError, run_runner_profile
from persona_pack import DEFAULT_PERSONA_ID, PersonaPack, load_and_validate_persona_pack

PROTOCOL = "stackchan.bridge.v1"
DEFAULT_SESSION = "bench"
DEFAULT_TEXT = "Hello. I am Stackchan, and I am awake."
DEFAULT_USER_TEXT = "Hello Stackchan."
BRIDGE_INTENTS = {"boot", "idle", "attend", "listen", "think", "speak", "react", "happy", "concern", "sleep", "error", "safety"}

DEFAULT_PERSONA = load_and_validate_persona_pack(DEFAULT_PERSONA_ID)
BRIDGE_SYSTEM_PROMPT = DEFAULT_PERSONA.bridge_system_prompt()

Viseme = Literal["neutral", "ah", "oh", "ee"]
ResponseGesture = Literal["none", "affirm", "deny"]

_AFFIRM_RESPONSE = re.compile(
    r"^(?:yes|yeah|yep|correct|absolutely|certainly|definitely|of course)\b",
    re.IGNORECASE,
)
_DENY_RESPONSE = re.compile(
    r"^(?:no|nope|nah|never|not\b|i (?:cannot|can't|can not|do not|don't|will not|won't|am not)\b|(?:that|it) (?:is not|isn't)\b)",
    re.IGNORECASE,
)
_NO_PROBLEM = re.compile(r"^no (?:problem|worries|trouble)\b", re.IGNORECASE)
_MIXED_RESPONSE = re.compile(r"^(?:yes|yeah|no|nope)\s+(?:and|or)\s+(?:yes|yeah|no|nope)\b", re.IGNORECASE)
_INFORMAL_DENY = re.compile(r"^(?:(?:yes|yeah),?\s+no|(?:absolutely|certainly|definitely)\s+not)\b", re.IGNORECASE)
_UNCERTAIN_RESPONSE = re.compile(r"^(?:yes|yeah|yep|no|nope)\s*\?", re.IGNORECASE)
_QUALIFIED_RESPONSE = re.compile(r"^correct me\b", re.IGNORECASE)


@dataclass(frozen=True)
class AudioBeat:
    env: float
    viseme: Viseme
    duration_ms: int = 80
    final: bool = False


@dataclass(frozen=True)
class BridgeTurn:
    session: str = DEFAULT_SESSION
    seq: int = 1
    intent: str = "happy"
    text: str = DEFAULT_TEXT
    arousal: float = 0.55
    valence: float = 0.60
    gesture: ResponseGesture = "none"
    citations: tuple[str, ...] = ()
    beats: tuple[AudioBeat, ...] = (
        AudioBeat(0.18, "neutral", 60),
        AudioBeat(0.55, "ah", 80),
        AudioBeat(0.72, "ee", 80),
        AudioBeat(0.44, "oh", 80),
        AudioBeat(0.12, "neutral", 60, True),
    )


def clamp01(value: float) -> float:
    return max(0.0, min(1.0, float(value)))


def clamp_signed(value: float) -> float:
    return max(-1.0, min(1.0, float(value)))


def response_gesture_for_text(text: object) -> ResponseGesture:
    clean = " ".join(str(text or "").strip().split()).lstrip("\"'([{ ")
    if (
        not clean
        or _NO_PROBLEM.search(clean)
        or _MIXED_RESPONSE.search(clean)
        or _UNCERTAIN_RESPONSE.search(clean)
        or _QUALIFIED_RESPONSE.search(clean)
    ):
        return "none"
    if _INFORMAL_DENY.search(clean):
        return "deny"
    if _AFFIRM_RESPONSE.search(clean):
        return "affirm"
    if _DENY_RESPONSE.search(clean):
        return "deny"
    return "none"


def emotion_baseline_for_mode(mode: str) -> tuple[float, float]:
    return {
        "boot": (0.45, 0.15),
        "idle": (0.22, 0.20),
        "attend": (0.52, 0.12),
        "listen": (0.58, 0.12),
        "think": (0.60, 0.10),
        "speak": (0.50, 0.12),
        "react": (0.68, 0.18),
        "happy": (0.66, 0.48),
        "concern": (0.38, -0.24),
        "sleep": (0.10, 0.08),
        "error": (0.56, -0.42),
        "safety": (0.42, -0.48),
    }.get(mode, (0.50, 0.10))


def build_persona_prompt(memory: BridgeMemory, persona: PersonaPack | None = None) -> str:
    pack = persona or DEFAULT_PERSONA
    return pack.render_prompt(memory_lines=memory.context_lines())


def spoken_physical_context(context: str) -> str:
    return {
        "user picked Stackchan up": "You picked me up",
        "user shook Stackchan": "You shook me",
        "user touched Stackchan": "You touched my screen",
        "room is dark": "The room is dark",
    }.get(context, context)


def plan_turn_from_memory(memory: BridgeMemory, seq: int = 7) -> BridgeTurn:
    prefix = f"Hello {memory.preferred_name}. " if memory.preferred_name else ""
    if memory.physical_context:
        response = f"{prefix}{spoken_physical_context(memory.physical_context[-1])}. I noticed that. I am steady now."
        intent = "concern" if "shook" in memory.physical_context[-1] else "happy"
        arousal = 0.62
        valence = 0.52
    elif memory.recent_topics:
        response = f"{prefix}I remember {memory.recent_topics[-1]}. Curiosity level rising."
        intent = "think"
        arousal = 0.58
        valence = 0.55
    else:
        response = f"{prefix}{DEFAULT_TEXT}"
        intent = "happy"
        arousal = 0.55
        valence = 0.60
    return BridgeTurn(seq=seq, intent=intent, text=response, arousal=arousal, valence=valence)


def plan_turn(user_text: str, memory: BridgeMemory, seq: int = 7) -> BridgeTurn:
    return plan_turn_from_memory(memory.remember_user_text(user_text), seq=seq)


def bridge_intent_from_mode(mode: object) -> str:
    intent = str(mode).strip().lower()
    return intent if intent in BRIDGE_INTENTS else "speak"


def turn_from_character_response(
    raw_response: str,
    memory: BridgeMemory,
    *,
    session: str = DEFAULT_SESSION,
    seq: int = 7,
    persona: PersonaPack | None = None,
) -> tuple[BridgeTurn, BridgeMemory, HarnessResult]:
    result = validate_response(raw_response, persona)
    normalized = result.normalized
    updated_memory = memory.apply_character_memory(normalized)
    emotion = normalized.get("emotion", {})
    if not isinstance(emotion, dict):
        emotion = {}
    mode = bridge_intent_from_mode(normalized.get("mode", "speak"))
    base_arousal, base_valence = emotion_baseline_for_mode(mode)
    arousal = clamp01(base_arousal + float(emotion.get("arousal", 0.0)))
    valence = clamp_signed(base_valence + float(emotion.get("valence", 0.0)))
    spoken_text = str(normalized.get("spoken_text", DEFAULT_TEXT))
    turn = BridgeTurn(
        session=session,
        seq=max(1, int(seq)),
        intent=mode,
        text=spoken_text,
        arousal=arousal,
        valence=valence,
        gesture=response_gesture_for_text(spoken_text),
    )
    return turn, updated_memory, result


def bridge_frames(turn: BridgeTurn) -> Iterator[dict[str, object]]:
    """Yield bridge-to-device frames in firmware order."""

    yield {"type": "hello", "protocol": PROTOCOL, "session": turn.session}
    yield {"type": "listening"}
    yield {"type": "thinking", "seq": turn.seq}
    response_start: dict[str, object] = {
        "type": "response_start",
        "seq": turn.seq,
        "intent": turn.intent,
        "arousal": round(clamp01(turn.arousal), 2),
        "valence": round(clamp_signed(turn.valence), 2),
        "gesture": turn.gesture,
        "text": turn.text,
    }
    if turn.citations:
        response_start["citations"] = list(turn.citations[:8])
    yield response_start
    for beat in turn.beats:
        yield {
            "type": "audio",
            "seq": turn.seq,
            "env": round(clamp01(beat.env), 2),
            "viseme": beat.viseme,
            "duration_ms": max(10, min(200, int(beat.duration_ms))),
            "final": bool(beat.final),
        }
    yield {"type": "response_end", "seq": turn.seq}


def frame_to_bench_command(frame: dict[str, object]) -> str | None:
    frame_type = str(frame.get("type", ""))
    if frame_type == "hello":
        return f"bridge hello {frame.get('session', DEFAULT_SESSION)}"
    if frame_type == "listening":
        return "bridge listening"
    if frame_type == "thinking":
        return f"bridge thinking {frame.get('seq', 1)}"
    if frame_type == "response_start":
        text = str(frame.get("text", DEFAULT_TEXT)).replace("\n", " ")
        return f"bridge response {frame.get('intent', 'speak')} {frame.get('seq', 1)} {text}"
    if frame_type == "audio":
        suffix = " final" if frame.get("final") else ""
        return (
            f"bridge audio {float(frame.get('env', 0.0)):.2f} "
            f"{frame.get('viseme', 'neutral')} {frame.get('duration_ms', 20)}{suffix}"
        )
    if frame_type == "response_end":
        return f"bridge end {frame.get('seq', 1)}"
    if frame_type == "heartbeat":
        return "bridge heartbeat"
    if frame_type == "error":
        return f"bridge error {frame.get('code', 'bridge_error')}"
    return None


def render_jsonl(frames: Iterable[dict[str, object]]) -> str:
    return "\n".join(json.dumps(frame, separators=(",", ":"), ensure_ascii=True) for frame in frames)


def render_bench(frames: Iterable[dict[str, object]]) -> str:
    commands = [command for frame in frames if (command := frame_to_bench_command(frame))]
    commands.append("status")
    return "\n".join(commands)


def build_arg_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description="Render deterministic Stackchan bridge frames.")
    parser.add_argument("--format", choices=("jsonl", "bench", "prompt"), default="jsonl")
    parser.add_argument("--session", default=DEFAULT_SESSION)
    parser.add_argument("--seq", type=int, default=7)
    parser.add_argument("--intent", default="happy")
    parser.add_argument("--text", default=DEFAULT_TEXT)
    parser.add_argument("--user-text", default=DEFAULT_USER_TEXT)
    parser.add_argument("--name", default="")
    parser.add_argument("--topic", action="append", default=[])
    parser.add_argument("--physical-context", action="append", default=[])
    parser.add_argument("--memory-file", type=Path, help="Optional local JSON memory store for the host bridge.")
    parser.add_argument("--save-memory", action="store_true", help="Persist memory after applying --user-text.")
    parser.add_argument("--reset-memory", action="store_true", help="Delete the local memory store before rendering.")
    parser.add_argument("--model-response", help="Validated Character Lock JSON response to render through the bridge.")
    parser.add_argument("--model-response-file", type=Path, help="File containing one Character Lock JSON response.")
    parser.add_argument("--runner-profile", choices=sorted(RUNNER_PROFILES), help="Run or dry-run a local model profile.")
    parser.add_argument("--runner-case", default="greeting", help="Prompt-suite case for --runner-profile.")
    parser.add_argument("--runner-command", default="", help="Optional local model command for --runner-profile.")
    parser.add_argument("--require-runner", action="store_true", help="Fail if --runner-profile has no configured command.")
    parser.add_argument("--runner-timeout-ms", type=int, default=60000)
    parser.add_argument("--persona", default=DEFAULT_PERSONA_ID, help="Persona pack id or path. Defaults to spark.")
    parser.add_argument("--arousal", type=float, default=0.55)
    parser.add_argument("--valence", type=float, default=0.60)
    return parser


def main() -> int:
    args = build_arg_parser().parse_args()
    try:
        persona = load_and_validate_persona_pack(args.persona)
    except ValueError as exc:
        print(str(exc), file=sys.stderr)
        return 2
    memory = BridgeMemory()
    if args.memory_file:
        memory = reset_bridge_memory(args.memory_file) if args.reset_memory else load_bridge_memory(args.memory_file)
    memory = memory.with_overrides(
        preferred_name=args.name,
        recent_topics=args.topic[-MAX_MEMORY_ITEMS:],
        physical_context=args.physical_context[-MAX_MEMORY_ITEMS:],
    )
    seq = max(1, int(args.seq))
    if args.format == "prompt":
        memory = memory.remember_user_text(args.user_text)
        if args.memory_file and args.save_memory:
            save_bridge_memory(args.memory_file, memory)
        print(build_persona_prompt(memory, persona))
        return 0

    raw_model_response = args.model_response
    if args.model_response_file:
        raw_model_response = args.model_response_file.read_text(encoding="utf-8")
    if args.runner_profile:
        if raw_model_response is not None:
            print("--runner-profile cannot be combined with --model-response or --model-response-file", file=sys.stderr)
            return 2
        try:
            runner = run_runner_profile(
                args.runner_profile,
                case_name=args.runner_case,
                command=args.runner_command,
                require_runner=args.require_runner,
                timeout_ms=args.runner_timeout_ms,
                persona_id=args.persona,
            )
        except (RunnerConfigurationError, RunnerExecutionError, ValueError) as exc:
            print(str(exc), file=sys.stderr)
            return 2
        if not runner.configured_runner:
            print(
                f"No local runner configured for {args.runner_profile}; using deterministic bridge fallback.",
                file=sys.stderr,
            )
        elif runner.approx_tokens_per_sec is not None:
            print(
                f"Runner {args.runner_profile} produced {runner.approx_tokens_per_sec:.2f} approximate tokens/sec.",
                file=sys.stderr,
            )
        raw_model_response = runner.raw_response

    if raw_model_response is not None:
        turn, memory, validation = turn_from_character_response(raw_model_response, memory, session=args.session, seq=seq, persona=persona)
        if validation.issues:
            print("Character validation issues: " + ", ".join(validation.issues), file=sys.stderr)
        if args.memory_file and args.save_memory:
            save_bridge_memory(args.memory_file, memory)
    elif args.text == DEFAULT_TEXT and args.intent == "happy" and args.user_text != DEFAULT_USER_TEXT:
        memory = memory.remember_user_text(args.user_text)
        if args.memory_file and args.save_memory:
            save_bridge_memory(args.memory_file, memory)
        turn = plan_turn_from_memory(memory, seq=seq)
        turn = replace(turn, session=args.session)
    else:
        turn = BridgeTurn(
            session=args.session,
            seq=seq,
            intent=args.intent,
            text=args.text,
            arousal=args.arousal,
            valence=args.valence,
        )
    frames = list(bridge_frames(turn))
    if args.format == "bench":
        print(render_bench(frames))
    else:
        print(render_jsonl(frames))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
