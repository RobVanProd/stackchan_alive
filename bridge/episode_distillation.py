"""Optional, strict session-close memory distillation for the local brain."""

from __future__ import annotations

import ipaddress
import json
import os
import re
import urllib.request
from urllib.parse import urlsplit, urlunsplit
from dataclasses import dataclass
from typing import Iterable

from bridge_memory import BridgeMemory, _safe_value, _utc_now

MAX_SESSION_TURNS = 24
MAX_TURN_CHARS = 160
DISTILLATION_SCHEMA = {
    "type": "object",
    "properties": {
        "episode": {
            "type": "string",
            "maxLength": 120,
        }
    },
    "required": ["episode"],
    "additionalProperties": False,
}
_PRIVATE_LOCATION_RE = re.compile(
    r"(?:\b(?:home|address|where\s+i\s+live|my\s+location|current\s+location|"
    r"coordinates?|latitude|longitude|street|road|avenue|boulevard|postal|zip)\b|"
    r"(?<!\d)-?\d{1,3}\.\d{3,}\s*[, ]\s*-?\d{1,3}\.\d{3,}(?!\d)|"
    r"\b\d{1,6}\s+[A-Za-z][A-Za-z .'-]{1,40}\s+"
    r"(?:street|st|road|rd|avenue|ave|boulevard|blvd|lane|drive|court)\b)",
    re.IGNORECASE,
)
_THIRD_PARTY_POSSESSIVE_RE = re.compile(r"\b[A-Z][A-Za-z'-]{1,30}'s\b")


@dataclass(frozen=True)
class DistilledMemory:
    episode: str


def _local_generate_url(value: str) -> str:
    parsed = urlsplit(str(value or "").strip())
    if (
        parsed.scheme != "http"
        or not parsed.hostname
        or parsed.username is not None
        or parsed.password is not None
        or parsed.query
        or parsed.fragment
    ):
        raise ValueError("distillation_endpoint_invalid")
    host = parsed.hostname
    if host != "localhost":
        try:
            address = ipaddress.ip_address(host)
        except ValueError as exc:
            raise ValueError("distillation_endpoint_not_loopback") from exc
        if not address.is_loopback:
            raise ValueError("distillation_endpoint_not_loopback")
    path = parsed.path.rstrip("/")
    if not path:
        path = "/api/generate"
    elif not path.endswith("/api/generate"):
        path += "/api/generate"
    return urlunsplit((parsed.scheme, parsed.netloc, path, "", ""))


def validate_distillation(raw: object) -> DistilledMemory | None:
    try:
        data = json.loads(raw) if isinstance(raw, str) else raw
    except (json.JSONDecodeError, TypeError):
        return None
    if not isinstance(data, dict) or set(data) != {"episode"}:
        return None
    episode = data.get("episode")
    if (
        not isinstance(episode, str)
        or not episode.strip()
        or len(episode) > 120
        or not _safe_value("project.episode", episode)
        or _PRIVATE_LOCATION_RE.search(episode)
        or _THIRD_PARTY_POSSESSIVE_RE.search(episode)
    ):
        return None
    return DistilledMemory(" ".join(episode.split()))


def distillation_turns_safe(turns: Iterable[tuple[str, str]]) -> bool:
    """Reject private or research-like session material before it reaches the model."""

    for user, robot in turns:
        for value in (user, robot):
            clean = " ".join(str(value or "").split())[:MAX_TURN_CHARS]
            if (
                not _safe_value("project.episode", clean)
                or _PRIVATE_LOCATION_RE.search(clean)
                or _THIRD_PARTY_POSSESSIVE_RE.search(clean)
                or "http://" in clean.casefold()
                or "https://" in clean.casefold()
            ):
                return False
    return True


def apply_distillation(
    memory: BridgeMemory,
    result: DistilledMemory,
    *,
    now: str | None = None,
) -> BridgeMemory:
    timestamp = now or _utc_now()
    return memory.add_episode(result.episode, now=timestamp)


def distillation_prompt(turns: Iterable[tuple[str, str]]) -> str:
    bounded = list(turns)[-MAX_SESSION_TURNS:]
    lines = [
        "Summarize this completed local conversation for bounded robot memory.",
        "Return only JSON with exactly this schema:",
        '{"episode":"<=120 chars"}',
        "Keep episode under 100 characters and describe only the main shared subject.",
        "Do not include secrets, health, medical, relationship, contact, financial, or third-party details.",
        "Do not create reminders or callbacks; deterministic bridge rules own those.",
    ]
    for index, (user, robot) in enumerate(bounded, start=1):
        lines.append(f"turn {index} user: {' '.join(str(user).split())[:MAX_TURN_CHARS]}")
        lines.append(f"turn {index} stackchan: {' '.join(str(robot).split())[:MAX_TURN_CHARS]}")
    return "\n".join(lines)


def request_distillation(
    turns: Iterable[tuple[str, str]],
    *,
    model: str | None = None,
    endpoint: str | None = None,
    timeout_seconds: float = 45.0,
) -> str:
    configured_endpoint = (
        endpoint
        or os.environ.get("STACKCHAN_OLLAMA_API_URL")
        or os.environ.get("STACKCHAN_OLLAMA_URL")
        or "http://127.0.0.1:11434/api/generate"
    )
    payload = json.dumps(
        {
            "model": model or os.environ.get("STACKCHAN_OLLAMA_MODEL", "gemma4:e2b-it-qat"),
            "prompt": distillation_prompt(turns),
            "stream": False,
            "format": DISTILLATION_SCHEMA,
            "options": {"temperature": 0, "num_predict": 128},
        },
        separators=(",", ":"),
    ).encode("utf-8")
    request = urllib.request.Request(
        _local_generate_url(configured_endpoint),
        data=payload,
        headers={"Content-Type": "application/json"},
        method="POST",
    )
    with urllib.request.urlopen(request, timeout=max(1.0, timeout_seconds)) as response:
        result = json.loads(response.read().decode("utf-8"))
    if not isinstance(result, dict) or not isinstance(result.get("response"), str):
        raise ValueError("distillation_response_missing")
    return result["response"]
