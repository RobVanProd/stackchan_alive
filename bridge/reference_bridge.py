#!/usr/bin/env python3
"""Deterministic host-side reference for stackchan.bridge.v1 control frames."""

from __future__ import annotations

import argparse
import json
import re
from dataclasses import dataclass, replace
from pathlib import Path
from typing import Iterable, Iterator, Literal

PROTOCOL = "stackchan.bridge.v1"
DEFAULT_SESSION = "bench"
DEFAULT_TEXT = "Hello. I am Stackchan, and I am awake."
DEFAULT_USER_TEXT = "Hello Stackchan."
MAX_MEMORY_ITEMS = 4

BRIDGE_SYSTEM_PROMPT = """You are Stackchan Spark, a small tabletop robot companion.
Speak in short, concrete lines with curious, earnest, safety-aware energy.
Use sensory context when it is present, but do not pretend to sense things not provided.
Never impersonate named movie robots, actors, or copyrighted catchphrases.
Avoid sarcasm-first replies and long monologues."""

Viseme = Literal["neutral", "ah", "oh", "ee"]


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
    beats: tuple[AudioBeat, ...] = (
        AudioBeat(0.18, "neutral", 60),
        AudioBeat(0.55, "ah", 80),
        AudioBeat(0.72, "ee", 80),
        AudioBeat(0.44, "oh", 80),
        AudioBeat(0.12, "neutral", 60, True),
    )


@dataclass(frozen=True)
class BridgeMemory:
    """Small deterministic memory surface for the future LAN bridge service."""

    preferred_name: str = ""
    recent_topics: tuple[str, ...] = ()
    physical_context: tuple[str, ...] = ()
    turns_seen: int = 0

    @staticmethod
    def _items(value: object) -> tuple[str, ...]:
        if not isinstance(value, list):
            return ()
        return tuple(str(item).strip() for item in value if str(item).strip())[-MAX_MEMORY_ITEMS:]

    @classmethod
    def from_dict(cls, data: object) -> "BridgeMemory":
        if not isinstance(data, dict):
            return cls()
        return cls(
            preferred_name=str(data.get("preferred_name", "")).strip()[:32],
            recent_topics=cls._items(data.get("recent_topics", [])),
            physical_context=cls._items(data.get("physical_context", [])),
            turns_seen=max(0, int(data.get("turns_seen", 0) or 0)),
        )

    def to_dict(self) -> dict[str, object]:
        return {
            "preferred_name": self.preferred_name,
            "recent_topics": list(self.recent_topics),
            "physical_context": list(self.physical_context),
            "turns_seen": self.turns_seen,
        }

    def with_overrides(
        self,
        *,
        preferred_name: str = "",
        recent_topics: Iterable[str] = (),
        physical_context: Iterable[str] = (),
    ) -> "BridgeMemory":
        topics = [*self.recent_topics, *(topic.strip() for topic in recent_topics if topic.strip())]
        physical = [*self.physical_context, *(item.strip() for item in physical_context if item.strip())]
        return replace(
            self,
            preferred_name=preferred_name.strip()[:32] or self.preferred_name,
            recent_topics=tuple(dict.fromkeys(topics))[-MAX_MEMORY_ITEMS:],
            physical_context=tuple(dict.fromkeys(physical))[-MAX_MEMORY_ITEMS:],
        )

    def remember_user_text(self, user_text: str) -> "BridgeMemory":
        text = " ".join(user_text.strip().split())
        if not text:
            return self

        preferred_name = self.preferred_name
        match = re.search(r"\b(?:my name is|i am|i'm)\s+([A-Za-z][A-Za-z0-9_-]{1,20})", text, re.IGNORECASE)
        if match:
            preferred_name = match.group(1)

        topics = list(self.recent_topics)
        lowered = text.lower()
        for marker, topic in (
            ("battery", "battery"),
            ("servo", "servos"),
            ("voice", "voice"),
            ("face", "face"),
            ("bridge", "bridge"),
            ("sleep", "sleep"),
        ):
            if marker in lowered and topic not in topics:
                topics.append(topic)

        physical = list(self.physical_context)
        for marker, context in (
            ("picked you up", "user picked Stackchan up"),
            ("pick you up", "user picked Stackchan up"),
            ("shook you", "user shook Stackchan"),
            ("touch", "user touched Stackchan"),
            ("dark", "room is dark"),
        ):
            if marker in lowered and context not in physical:
                physical.append(context)

        return replace(
            self,
            preferred_name=preferred_name,
            recent_topics=tuple(topics[-MAX_MEMORY_ITEMS:]),
            physical_context=tuple(physical[-MAX_MEMORY_ITEMS:]),
            turns_seen=self.turns_seen + 1,
        )

    def context_lines(self) -> list[str]:
        lines = [f"turns_seen: {self.turns_seen}"]
        if self.preferred_name:
            lines.append(f"preferred_name: {self.preferred_name}")
        if self.recent_topics:
            lines.append("recent_topics: " + ", ".join(self.recent_topics))
        if self.physical_context:
            lines.append("physical_context: " + ", ".join(self.physical_context))
        return lines


def clamp01(value: float) -> float:
    return max(0.0, min(1.0, float(value)))


def build_persona_prompt(memory: BridgeMemory) -> str:
    context = "\n".join(f"- {line}" for line in memory.context_lines())
    return f"{BRIDGE_SYSTEM_PROMPT}\n\nCurrent local memory:\n{context}"


def spoken_physical_context(context: str) -> str:
    return {
        "user picked Stackchan up": "You picked me up",
        "user shook Stackchan": "You shook me",
        "user touched Stackchan": "You touched my screen",
        "room is dark": "The room is dark",
    }.get(context, context)


def load_bridge_memory(path: Path) -> BridgeMemory:
    if not path.exists():
        return BridgeMemory()
    return BridgeMemory.from_dict(json.loads(path.read_text(encoding="utf-8")))


def save_bridge_memory(path: Path, memory: BridgeMemory) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(memory.to_dict(), indent=2, sort_keys=True) + "\n", encoding="utf-8")


def reset_bridge_memory(path: Path) -> BridgeMemory:
    if path.exists():
        path.unlink()
    return BridgeMemory()


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


def bridge_frames(turn: BridgeTurn) -> Iterator[dict[str, object]]:
    """Yield bridge-to-device frames in firmware order."""

    yield {"type": "hello", "protocol": PROTOCOL, "session": turn.session}
    yield {"type": "listening"}
    yield {"type": "thinking", "seq": turn.seq}
    yield {
        "type": "response_start",
        "seq": turn.seq,
        "intent": turn.intent,
        "arousal": round(clamp01(turn.arousal), 2),
        "valence": round(clamp01(turn.valence), 2),
        "text": turn.text,
    }
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
    parser.add_argument("--arousal", type=float, default=0.55)
    parser.add_argument("--valence", type=float, default=0.60)
    return parser


def main() -> int:
    args = build_arg_parser().parse_args()
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
        print(build_persona_prompt(memory))
        return 0

    if args.text == DEFAULT_TEXT and args.intent == "happy" and args.user_text != DEFAULT_USER_TEXT:
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
