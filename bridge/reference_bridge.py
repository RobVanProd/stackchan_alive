#!/usr/bin/env python3
"""Deterministic host-side reference for stackchan.bridge.v1 control frames."""

from __future__ import annotations

import argparse
import json
from dataclasses import dataclass
from typing import Iterable, Iterator, Literal

PROTOCOL = "stackchan.bridge.v1"
DEFAULT_SESSION = "bench"
DEFAULT_TEXT = "Hello. I am Stackchan, and I am awake."

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


def clamp01(value: float) -> float:
    return max(0.0, min(1.0, float(value)))


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
    parser.add_argument("--format", choices=("jsonl", "bench"), default="jsonl")
    parser.add_argument("--session", default=DEFAULT_SESSION)
    parser.add_argument("--seq", type=int, default=7)
    parser.add_argument("--intent", default="happy")
    parser.add_argument("--text", default=DEFAULT_TEXT)
    parser.add_argument("--arousal", type=float, default=0.55)
    parser.add_argument("--valence", type=float, default=0.60)
    return parser


def main() -> int:
    args = build_arg_parser().parse_args()
    turn = BridgeTurn(
        session=args.session,
        seq=max(1, int(args.seq)),
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
