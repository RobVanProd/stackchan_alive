#!/usr/bin/env python3
"""Deterministic, trusted local facts for conversational turns."""

from __future__ import annotations

import json
import re
from dataclasses import dataclass
from datetime import datetime
from typing import TYPE_CHECKING

if TYPE_CHECKING:
    from bridge_memory import BridgeMemory


_TIME_QUERY = re.compile(
    r"\b(?:"
    r"what(?:'s| is) (?:the )?(?:current |local )?time(?: right now)?|"
    r"what time (?:is it|do you have)|"
    r"do you (?:know what time it is|have (?:the )?time)|"
    r"(?:can|could|would|will) you (?:please )?tell me "
    r"(?:what time it is|(?:the |current |local )?time)|"
    r"tell me (?:what time it is|(?:the |current |local )?time)|"
    r"(?:the )?(?:current|local) time(?: right now)?(?: please)?|"
    r"time right now"
    r")\b",
    re.IGNORECASE,
)
_DATE_QUERY = re.compile(
    r"\b(?:"
    r"what(?:'s| is) (?:today(?:'s)? date|the date|today)|"
    r"what (?:day|date) is it|what day is today|"
    r"(?:can|could|would|will) you (?:please )?tell me "
    r"(?:what (?:day|date) it is|(?:today(?:'s)? |the )?(?:day|date))|"
    r"tell me (?:what (?:day|date) it is|(?:today(?:'s)? |the )?(?:day|date))|"
    r"(?:today(?:'s)?|current) (?:day|date)(?: please)?"
    r")\b",
    re.IGNORECASE,
)
_TIMEZONE_QUERY = re.compile(
    r"\b(?:"
    r"what(?:'s| is) (?:the |our |this )?(?:local )?time ?zone|"
    r"(?:what|which) time ?zone is (?:this|it)|"
    r"(?:what|which) time ?zone (?:are we|am i) in|"
    r"(?:can|could|would|will) you (?:please )?tell me (?:the |our |this )?time ?zone|"
    r"tell me (?:the |our |this )?time ?zone|"
    r"(?:the |our |this |local )time ?zone(?: please)?"
    r")\b",
    re.IGNORECASE,
)
_REMOTE_TIME = re.compile(r"\btime\s+(?:is\s+it\s+)?in\s+(?!here\b|our\b|this\b|the\b)", re.IGNORECASE)
_NAME_QUERY = re.compile(
    r"\b(?:"
    r"what(?:'s| is) my name|what do you call me|who am i|"
    r"do you remember (?:my name|who i am)|"
    r"(?:can|could|would|will) you (?:please )?remember (?:my name|who i am)|"
    r"(?:can|could|would|will) you (?:please )?tell me (?:my name|who i am)|"
    r"tell me (?:my name|who i am)"
    r")\b",
    re.IGNORECASE,
)


@dataclass(frozen=True)
class LocalFactResult:
    tool: str
    spoken_text: str
    mode: str = "speak"
    arousal: float = 0.0
    valence: float = 0.08

    def character_response(self) -> str:
        return json.dumps(
            {
                "spoken_text": self.spoken_text,
                "mode": self.mode,
                "earcon": "none",
                "emotion": {"arousal": self.arousal, "valence": self.valence},
                "memory_write": {},
                "memory_forget": [],
            },
            separators=(",", ":"),
            ensure_ascii=True,
        )


def _clock_text(now: datetime) -> str:
    hour = now.hour % 12 or 12
    return f"{hour}:{now.minute:02d} {'AM' if now.hour < 12 else 'PM'}"


def _timezone_text(now: datetime) -> str:
    name = " ".join(str(now.tzname() or "local time").split())
    return name if name else "local time"


def resolve_local_fact(
    user_text: str,
    memory: "BridgeMemory",
    *,
    now: datetime | None = None,
) -> LocalFactResult | None:
    """Resolve facts owned by the host instead of asking the language model to guess."""

    text = " ".join(str(user_text or "").split())
    if not text:
        return None

    if now is None:
        local_now = datetime.now().astimezone()
    else:
        local_now = now if now.tzinfo is not None else now.astimezone()
    asks_time = bool(_TIME_QUERY.search(text)) and not _REMOTE_TIME.search(text)
    asks_date = bool(_DATE_QUERY.search(text))
    asks_timezone = bool(_TIMEZONE_QUERY.search(text))
    if asks_time or asks_date or asks_timezone:
        parts: list[str] = []
        if asks_time:
            parts.append(f"It is {_clock_text(local_now)}")
        if asks_date:
            date_text = f"{local_now:%A, %B} {local_now.day}, {local_now.year}"
            parts.append(f"Today is {date_text}")
        if asks_timezone:
            parts.append(f"The local time zone is {_timezone_text(local_now)}")
        return LocalFactResult(tool="local_clock", spoken_text=". ".join(parts) + ".")

    if _NAME_QUERY.search(text):
        if memory.preferred_name:
            return LocalFactResult(
                tool="memory_recall",
                spoken_text=f"You asked me to call you {memory.preferred_name}.",
                mode="happy",
                valence=0.18,
            )
        return LocalFactResult(
            tool="memory_recall",
            spoken_text="I do not know what you want me to call you yet.",
            mode="concern",
            valence=-0.08,
        )

    return None
