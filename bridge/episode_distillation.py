"""Optional, strict session-close memory distillation for the local brain."""

from __future__ import annotations

import ipaddress
import json
import os
import urllib.request
from urllib.parse import urlsplit, urlunsplit
from dataclasses import dataclass
from datetime import timedelta
from typing import Iterable

from bridge_memory import BridgeMemory, _future_timestamp, _safe_value, _utc_now


@dataclass(frozen=True)
class DistilledMemory:
    episode: str
    open_loop_text: str = ""
    days_until_due: int = 0


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
    if not isinstance(data, dict) or set(data) != {"episode", "open_loop"}:
        return None
    episode = data.get("episode")
    if (
        not isinstance(episode, str)
        or not episode.strip()
        or len(episode) > 120
        or not _safe_value("project.episode", episode)
    ):
        return None
    loop = data.get("open_loop")
    if loop is None:
        return DistilledMemory(" ".join(episode.split()))
    if not isinstance(loop, dict) or set(loop) != {"text", "days_until_due"}:
        return None
    text = loop.get("text")
    days = loop.get("days_until_due")
    if (
        not isinstance(text, str)
        or not text.strip()
        or len(text) > 96
        or not isinstance(days, int)
        or isinstance(days, bool)
        or not 1 <= days <= 14
        or not _safe_value("user.open_loop", text)
    ):
        return None
    return DistilledMemory(" ".join(episode.split()), " ".join(text.split()), days)


def apply_distillation(
    memory: BridgeMemory,
    result: DistilledMemory,
    *,
    now: str | None = None,
) -> BridgeMemory:
    timestamp = now or _utc_now()
    updated = memory.add_episode(result.episode, now=timestamp)
    if result.open_loop_text:
        updated = updated.add_open_loop(
            result.open_loop_text,
            due_at=_future_timestamp(timedelta(days=result.days_until_due), timestamp),
            now=timestamp,
        )
    return updated


def distillation_prompt(turns: Iterable[tuple[str, str]]) -> str:
    bounded = list(turns)[-4:]
    lines = [
        "Summarize this completed local conversation for bounded robot memory.",
        "Return only JSON with exactly this schema:",
        '{"episode":"<=120 chars","open_loop":{"text":"<=96 chars","days_until_due":1}|null}',
        "Do not include secrets, health, medical, relationship, contact, financial, or third-party details.",
    ]
    for index, (user, robot) in enumerate(bounded, start=1):
        lines.append(f"turn {index} user: {' '.join(str(user).split())[:320]}")
        lines.append(f"turn {index} stackchan: {' '.join(str(robot).split())[:320]}")
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
            "format": "json",
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
