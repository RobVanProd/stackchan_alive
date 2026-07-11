#!/usr/bin/env python3
"""Privacy-preserving, bounded host memory for the Stackchan bridge."""

from __future__ import annotations

import json
import os
import re
import tempfile
from dataclasses import dataclass, field, replace
from datetime import datetime, timedelta, timezone
from pathlib import Path
from typing import Iterable

MEMORY_SCHEMA = "stackchan.bridge-memory.v2"
MEMORY_SCHEMA_VERSION = 2
MAX_MEMORY_ITEMS = 4
MAX_DURABLE_FACTS = 24
MAX_RECENT_CONTEXT = 8
MAX_MEMORY_VALUE_CHARS = 96
MAX_MEMORY_KEY_CHARS = 64
MAX_TURNS_SEEN = 2_147_483_647
RECENT_TOPIC_TTL = timedelta(days=7)
PHYSICAL_CONTEXT_TTL = timedelta(hours=24)

_ALLOWED_PREFIXES = ("user.", "project.", "robot.")
_NAME_KEYS = {"user.name", "user.preferred_name", "user.greeting"}
_PREFERRED_NAME_RE = re.compile(r"^[A-Za-z][A-Za-z0-9_-]{0,20}$")
_RESERVED_NAME_WORDS = {
    "angry",
    "assistant",
    "confused",
    "cool",
    "dude",
    "friend",
    "happy",
    "helpful",
    "human",
    "person",
    "ready",
    "robot",
    "sad",
    "stackchan",
    "tired",
}
_DENIED_MEMORY_TERMS = (
    "password",
    "passcode",
    "credential",
    "secret",
    "token",
    "api key",
    "private key",
    "credit card",
    "bank account",
    "account number",
    "routing number",
    "social security",
    "financial",
    "finance",
    "salary",
    "income",
    "diagnosis",
    "doctor",
    "medical",
    "health",
    "health condition",
    "therapy",
    "medication",
    "prescription",
    "diabetes",
    "diabetic",
    "asthma",
    "cancer",
    "depression",
    "anxiety",
    "girlfriend",
    "boyfriend",
    "wife",
    "husband",
    "spouse",
    "partner",
    "relationship",
    "romantic partner",
    "divorce",
    "third party",
    "phone number",
    "email address",
    "home address",
    "raw audio",
    "audio recording",
    "transcript",
    "utterance recording",
)
_THIRD_PARTY_NAME_RE = re.compile(r"\b(?:alice|bob|charlie|david|sarah|michael)(?:'s)?\b", re.IGNORECASE)
_SECRET_VALUE_RE = re.compile(r"\b(?:sk-[a-z0-9_-]{8,}|akia[a-z0-9]{16})\b", re.IGNORECASE)
_THIRD_PARTY_POSSESSIVE_RE = re.compile(r"\b[A-Z][A-Za-z0-9_-]{1,30}'s\b")
_PRIVATE_VALUE_RE = re.compile(
    r"(?:\b[\w.+-]+@[\w.-]+\.[A-Za-z]{2,}\b|"
    r"(?<!\d)(?:\+?1[ .-]?)?(?:\(?\d{3}\)?[ .-]?)\d{3}[ .-]\d{4}(?!\d)|"
    r"(?<!\d)(?:\d[ -]*?){13,19}(?!\d))"
)


def _utc_now() -> str:
    return datetime.now(timezone.utc).replace(microsecond=0).isoformat().replace("+00:00", "Z")


def _timestamp(value: object, default: str) -> str:
    text = str(value or "").strip()
    if not text:
        return default
    try:
        parsed = datetime.fromisoformat(text.replace("Z", "+00:00"))
    except ValueError:
        return default
    if parsed.tzinfo is None:
        parsed = parsed.replace(tzinfo=timezone.utc)
    return parsed.astimezone(timezone.utc).replace(microsecond=0).isoformat().replace("+00:00", "Z")


def _as_datetime(value: str) -> datetime:
    return datetime.fromisoformat(value.replace("Z", "+00:00"))


def _future_timestamp(delta: timedelta, now: str | None = None) -> str:
    base = _as_datetime(now or _utc_now())
    return (base + delta).replace(microsecond=0).isoformat().replace("+00:00", "Z")


def _clean_item(value: object, max_len: int = MAX_MEMORY_VALUE_CHARS) -> str:
    return " ".join(str(value).strip().split())[:max_len]


def _clean_key(value: object) -> str:
    return _clean_item(value, MAX_MEMORY_KEY_CHARS).lower()


def _memory_scalar(value: object, max_len: int = MAX_MEMORY_VALUE_CHARS) -> str:
    if not isinstance(value, str):
        return ""
    clean = _clean_item(value, max_len)
    if not clean or clean.isnumeric() or clean[0] in "[{" or clean[-1:] in "]}":
        return ""
    return clean


def _preferred_name(value: object) -> str:
    clean = _memory_scalar(value, 32)
    if not _PREFERRED_NAME_RE.fullmatch(clean) or clean.lower() in _RESERVED_NAME_WORDS:
        return ""
    return clean


def _safe_value(key: str, value: str) -> bool:
    if not key.startswith(_ALLOWED_PREFIXES):
        return False
    text = re.sub(r"[_-]+", " ", f"{key} {value}".lower())
    if any(term in text for term in _DENIED_MEMORY_TERMS):
        return False
    return not (
        _THIRD_PARTY_NAME_RE.search(text)
        or _SECRET_VALUE_RE.search(value)
        or _THIRD_PARTY_POSSESSIVE_RE.search(value)
        or _PRIVATE_VALUE_RE.search(value)
    )


def _importance(value: object, default: float) -> float:
    try:
        return max(0.0, min(1.0, float(value)))
    except (TypeError, ValueError):
        return default


def _turns_seen(value: object) -> int:
    try:
        return max(0, min(MAX_TURNS_SEEN, int(value or 0)))
    except (TypeError, ValueError, OverflowError):
        return 0


@dataclass(frozen=True)
class MemoryRecord:
    key: str
    value: str
    created_at: str
    updated_at: str
    last_used_at: str
    importance: float = 0.5
    expires_at: str | None = None

    @classmethod
    def create(
        cls,
        key: object,
        value: object,
        *,
        importance: float,
        expires_at: str | None = None,
        now: str | None = None,
    ) -> "MemoryRecord | None":
        clean_key = _clean_key(key)
        clean_value = _memory_scalar(value)
        if not clean_value or not _safe_value(clean_key, clean_value):
            return None
        timestamp = now or _utc_now()
        expiry = (_timestamp(expires_at, "") or None) if expires_at else None
        return cls(clean_key, clean_value, timestamp, timestamp, timestamp, _importance(importance, 0.5), expiry)

    @classmethod
    def from_dict(cls, data: object, *, now: str) -> "MemoryRecord | None":
        if not isinstance(data, dict):
            return None
        record = cls.create(
            data.get("key", ""),
            data.get("value", ""),
            importance=_importance(data.get("importance"), 0.5),
            expires_at=str(data.get("expires_at")) if data.get("expires_at") else None,
            now=_timestamp(data.get("created_at"), now),
        )
        if record is None:
            return None
        record = replace(
            record,
            updated_at=_timestamp(data.get("updated_at"), record.created_at),
            last_used_at=_timestamp(data.get("last_used_at"), record.created_at),
        )
        if record.expires_at and _as_datetime(record.expires_at) <= _as_datetime(now):
            return None
        return record

    def to_dict(self) -> dict[str, object]:
        return {
            "key": self.key,
            "value": self.value,
            "created_at": self.created_at,
            "updated_at": self.updated_at,
            "last_used_at": self.last_used_at,
            "importance": round(self.importance, 2),
            "expires_at": self.expires_at,
        }


def _dedupe_tail(values: Iterable[object]) -> tuple[str, ...]:
    items: list[str] = []
    for value in values:
        item = _memory_scalar(value)
        if not item:
            continue
        if item in items:
            items.remove(item)
        items.append(item)
    return tuple(items[-MAX_MEMORY_ITEMS:])


def _bounded_durable(records: Iterable[MemoryRecord]) -> tuple[MemoryRecord, ...]:
    items: list[MemoryRecord] = []
    for record in records:
        items = [item for item in items if item.key != record.key]
        items.append(record)
    return tuple(items[-MAX_DURABLE_FACTS:])


def _bounded_recent(records: Iterable[MemoryRecord]) -> tuple[MemoryRecord, ...]:
    items: list[MemoryRecord] = []
    for record in records:
        items = [item for item in items if (item.key, item.value) != (record.key, record.value)]
        items.append(record)
    return tuple(items[-MAX_RECENT_CONTEXT:])


def _upsert_durable(
    records: Iterable[MemoryRecord],
    key: str,
    value: str,
    importance: float,
    *,
    now: str,
    refresh: bool = True,
) -> tuple[MemoryRecord, ...]:
    existing = next((record for record in records if record.key == key), None)
    if existing is not None and existing.value == value and not refresh:
        return _bounded_durable(records)
    created = MemoryRecord.create(key, value, importance=importance, now=now)
    if created is None:
        return _bounded_durable(records)
    if existing is not None:
        created = replace(created, created_at=existing.created_at)
    return _bounded_durable((*records, created))


def _upsert_recent(
    records: Iterable[MemoryRecord], key: str, value: str, importance: float, ttl: timedelta, *, now: str
) -> tuple[MemoryRecord, ...]:
    existing = next((record for record in records if record.key == key and record.value == value), None)
    created = MemoryRecord.create(key, value, importance=importance, expires_at=_future_timestamp(ttl, now), now=now)
    if created is None:
        return _bounded_recent(records)
    if existing is not None:
        created = replace(created, created_at=existing.created_at)
    return _bounded_recent((*records, created))


@dataclass(frozen=True)
class BridgeMemory:
    """Backward-compatible public view over versioned durable and recent memory."""

    preferred_name: str = ""
    recent_topics: tuple[str, ...] = ()
    physical_context: tuple[str, ...] = ()
    turns_seen: int = 0
    _durable_facts: tuple[MemoryRecord, ...] = field(default=(), repr=False, compare=False)
    _recent_context: tuple[MemoryRecord, ...] = field(default=(), repr=False, compare=False)

    def __post_init__(self) -> None:
        preferred_name = _preferred_name(self.preferred_name)
        if preferred_name and not _safe_value("user.preferred_name", preferred_name):
            preferred_name = ""
        object.__setattr__(self, "preferred_name", preferred_name)
        object.__setattr__(self, "recent_topics", self._safe_items(self.recent_topics, "project.topic"))
        object.__setattr__(self, "physical_context", self._safe_items(self.physical_context, "robot.physical_context"))
        object.__setattr__(self, "turns_seen", _turns_seen(self.turns_seen))

    @staticmethod
    def _clean_item(value: object, max_len: int = MAX_MEMORY_VALUE_CHARS) -> str:
        return _clean_item(value, max_len)

    @staticmethod
    def _dedupe_tail(values: Iterable[str]) -> tuple[str, ...]:
        return _dedupe_tail(values)

    @staticmethod
    def _safe_items(values: Iterable[object], key: str) -> tuple[str, ...]:
        return _dedupe_tail(
            value
            for value in values
            if _memory_scalar(value) and _safe_value(key, _memory_scalar(value))
        )

    @staticmethod
    def _items(value: object) -> tuple[str, ...]:
        if not isinstance(value, list):
            return ()
        return _dedupe_tail(value)

    def _canonical_durable(self, *, now: str) -> tuple[MemoryRecord, ...]:
        records = tuple(
            record
            for record in self._durable_facts
            if _safe_value(record.key, record.value)
            and (not record.expires_at or _as_datetime(record.expires_at) > _as_datetime(now))
            and record.key not in _NAME_KEYS
        )
        if self.preferred_name:
            records = _upsert_durable(
                records, "user.preferred_name", self.preferred_name, 0.9, now=now, refresh=False
            )
        return _bounded_durable(records)

    def _canonical_recent(
        self, durable: tuple[MemoryRecord, ...], *, now: str
    ) -> tuple[MemoryRecord, ...]:
        durable_topics = {
            record.value for record in durable if record.key.startswith("project.") or "topic" in record.key
        }
        records = tuple(
            record
            for record in self._recent_context
            if _safe_value(record.key, record.value)
            and (not record.expires_at or _as_datetime(record.expires_at) > _as_datetime(now))
            and (
                (
                    record.key.startswith("project.")
                    and record.value in self.recent_topics
                    and record.value not in durable_topics
                )
                or (record.key.startswith("robot.") and record.value in self.physical_context)
            )
        )
        for topic in self.recent_topics:
            if topic not in durable_topics and not any(
                record.key.startswith("project.") and record.value == topic for record in records
            ):
                records = _upsert_recent(records, "project.topic", topic, 0.4, RECENT_TOPIC_TTL, now=now)
        for context in self.physical_context:
            if not any(record.key.startswith("robot.") and record.value == context for record in records):
                records = _upsert_recent(
                    records, "robot.physical_context", context, 0.5, PHYSICAL_CONTEXT_TTL, now=now
                )
        return _bounded_recent(records)

    @classmethod
    def from_dict(cls, data: object) -> "BridgeMemory":
        if not isinstance(data, dict):
            return cls()
        if "schema" not in data:
            return cls(
                preferred_name=str(data.get("preferred_name", "")),
                recent_topics=cls._items(data.get("recent_topics", [])),
                physical_context=cls._items(data.get("physical_context", [])),
                turns_seen=_turns_seen(data.get("turns_seen", 0)),
            )
        if data.get("schema") != MEMORY_SCHEMA or data.get("schema_version") != MEMORY_SCHEMA_VERSION:
            return cls()

        now = _utc_now()
        durable = _bounded_durable(
            record
            for item in data.get("durable_facts", []) if isinstance(data.get("durable_facts"), list)
            if (record := MemoryRecord.from_dict(item, now=now)) is not None
        )
        recent = _bounded_recent(
            record
            for item in data.get("recent_context", []) if isinstance(data.get("recent_context"), list)
            if (record := MemoryRecord.from_dict(item, now=now)) is not None
        )
        preferred_name = next((record.value for record in reversed(durable) if record.key in _NAME_KEYS), "")
        topics = _dedupe_tail(
            record.value
            for record in (*durable, *recent)
            if record.key.startswith("project.") or (record.key.startswith("user.") and "topic" in record.key)
        )
        physical = _dedupe_tail(record.value for record in recent if record.key.startswith("robot."))
        if not durable and not recent:
            preferred_name = str(data.get("preferred_name", ""))
            topics = cls._items(data.get("recent_topics", []))
            physical = cls._items(data.get("physical_context", []))
        return cls(
            preferred_name=preferred_name,
            recent_topics=topics,
            physical_context=physical,
            turns_seen=_turns_seen(data.get("turns_seen", 0)),
            _durable_facts=durable,
            _recent_context=recent,
        )

    def to_dict(self) -> dict[str, object]:
        now = _utc_now()
        durable = self._canonical_durable(now=now)
        recent = self._canonical_recent(durable, now=now)
        return {
            "schema": MEMORY_SCHEMA,
            "schema_version": MEMORY_SCHEMA_VERSION,
            "updated_at": now,
            "durable_facts": [record.to_dict() for record in durable],
            "recent_context": [record.to_dict() for record in recent],
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
        now = _utc_now()
        durable = self._canonical_durable(now=now)
        recent = self._canonical_recent(durable, now=now)
        clean_name = _preferred_name(preferred_name)
        next_name = (
            clean_name
            if clean_name and _safe_value("user.preferred_name", clean_name)
            else self.preferred_name
        )
        if next_name:
            durable = _upsert_durable(durable, "user.preferred_name", next_name, 0.9, now=now)

        topics = list(self.recent_topics)
        for topic in self._safe_items(recent_topics, "project.topic"):
            topics.append(topic)
            recent = _upsert_recent(recent, "project.topic", topic, 0.4, RECENT_TOPIC_TTL, now=now)
        physical = list(self.physical_context)
        for context in self._safe_items(physical_context, "robot.physical_context"):
            physical.append(context)
            recent = _upsert_recent(recent, "robot.physical_context", context, 0.5, PHYSICAL_CONTEXT_TTL, now=now)
        return replace(
            self,
            preferred_name=next_name,
            recent_topics=_dedupe_tail(topics),
            physical_context=_dedupe_tail(physical),
            _durable_facts=durable,
            _recent_context=recent,
        )

    @staticmethod
    def _forget_matches(forget_key: str, namespace: str) -> bool:
        key = forget_key.strip().lower().rstrip("*").rstrip(".")
        return key in ("", "all", namespace) or key.startswith(f"{namespace}.")

    def apply_character_memory(self, normalized: dict[str, object]) -> "BridgeMemory":
        now = _utc_now()
        preferred_name = self.preferred_name
        topics = list(self.recent_topics)
        physical = list(self.physical_context)
        durable = self._canonical_durable(now=now)
        recent = self._canonical_recent(durable, now=now)
        forget_everything = False

        writes = normalized.get("memory_write", {})
        if isinstance(writes, dict):
            for raw_key, raw_value in writes.items():
                key = _clean_key(raw_key)
                value = _memory_scalar(raw_value)
                if not value or not _safe_value(key, value):
                    continue
                if key in _NAME_KEYS:
                    # Identity is transcript-owned. The model may reinforce an explicitly
                    # observed name, but it cannot invent or replace one.
                    if preferred_name and value.casefold() == preferred_name.casefold():
                        durable = _upsert_durable(
                            durable, key, preferred_name, 0.9, now=now
                        )
                elif key.startswith("project.") or (key.startswith("user.") and "topic" in key):
                    topics.append(value)
                    durable = _upsert_durable(durable, key, value, 0.75, now=now)
                elif key.startswith("user."):
                    durable = _upsert_durable(durable, key, value, 0.7, now=now)
                elif key.startswith("robot."):
                    physical.append(value)
                    recent = _upsert_recent(recent, key, value, 0.5, PHYSICAL_CONTEXT_TTL, now=now)

        forgets = normalized.get("memory_forget", [])
        if isinstance(forgets, list):
            for raw_forget in forgets:
                forget = str(raw_forget)
                normalized_forget = forget.strip().lower()
                if normalized_forget in ("", "*", "all"):
                    forget_everything = True
                if self._forget_matches(forget, "user"):
                    preferred_name = ""
                    durable = tuple(record for record in durable if not record.key.startswith("user."))
                if self._forget_matches(forget, "project"):
                    topics = []
                    durable = tuple(record for record in durable if not record.key.startswith("project."))
                    recent = tuple(record for record in recent if not record.key.startswith("project."))
                if self._forget_matches(forget, "robot"):
                    physical = []
                    durable = tuple(record for record in durable if not record.key.startswith("robot."))
                    recent = tuple(record for record in recent if not record.key.startswith("robot."))

        return replace(
            self,
            preferred_name=preferred_name,
            recent_topics=_dedupe_tail(topics),
            physical_context=_dedupe_tail(physical),
            turns_seen=0 if forget_everything else self.turns_seen,
            _durable_facts=_bounded_durable(durable),
            _recent_context=_bounded_recent(recent),
        )

    def remember_user_text(self, user_text: str) -> "BridgeMemory":
        text = " ".join(user_text.strip().split())
        if not text:
            return self
        now = _utc_now()
        preferred_name = self.preferred_name
        durable = self._canonical_durable(now=now)
        recent = self._canonical_recent(durable, now=now)
        match = re.search(
            r"\b(?:my name is|call me|you can call me|i am called|i'm called)\s+"
            r"([A-Za-z][A-Za-z0-9_-]{1,20})",
            text,
            re.IGNORECASE,
        )
        observed_name = _preferred_name(match.group(1)) if match else ""
        if observed_name and _safe_value("user.preferred_name", observed_name):
            preferred_name = observed_name
            durable = _upsert_durable(durable, "user.preferred_name", preferred_name, 0.9, now=now)

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
            if marker in lowered:
                topics.append(topic)
                recent = _upsert_recent(recent, "project.topic", topic, 0.4, RECENT_TOPIC_TTL, now=now)

        physical = list(self.physical_context)
        for marker, context in (
            ("picked you up", "user picked Stackchan up"),
            ("pick you up", "user picked Stackchan up"),
            ("shook you", "user shook Stackchan"),
            ("touch", "user touched Stackchan"),
            ("dark", "room is dark"),
        ):
            if marker in lowered:
                physical.append(context)
                recent = _upsert_recent(recent, "robot.physical_context", context, 0.5, PHYSICAL_CONTEXT_TTL, now=now)

        return replace(
            self,
            preferred_name=preferred_name,
            recent_topics=_dedupe_tail(topics),
            physical_context=_dedupe_tail(physical),
            turns_seen=min(MAX_TURNS_SEEN, self.turns_seen + 1),
            _durable_facts=durable,
            _recent_context=recent,
        )

    def context_lines(self) -> list[str]:
        lines = [f"turns_seen: {self.turns_seen}"]
        if self.preferred_name:
            lines.append(f"preferred_name: {self.preferred_name}")
        now = _utc_now()
        durable = self._canonical_durable(now=now)
        recent = self._canonical_recent(durable, now=now)
        object.__setattr__(self, "_durable_facts", tuple(replace(record, last_used_at=now) for record in durable))
        object.__setattr__(self, "_recent_context", tuple(replace(record, last_used_at=now) for record in recent))
        for record in durable:
            if record.key not in _NAME_KEYS:
                lines.append(f"approved_fact {record.key}: {record.value}")
        if self.recent_topics:
            lines.append("recent_topics: " + ", ".join(self.recent_topics))
        if self.physical_context:
            lines.append("physical_context: " + ", ".join(self.physical_context))
        return lines


def load_bridge_memory(path: Path) -> BridgeMemory:
    if not path.exists():
        return BridgeMemory()
    try:
        payload = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, UnicodeDecodeError, json.JSONDecodeError):
        return BridgeMemory()
    return BridgeMemory.from_dict(payload)


def save_bridge_memory(path: Path, memory: BridgeMemory) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    payload = json.dumps(memory.to_dict(), indent=2, sort_keys=True) + "\n"
    descriptor, temp_name = tempfile.mkstemp(prefix=f".{path.name}.", suffix=".tmp", dir=str(path.parent))
    temp_path = Path(temp_name)
    try:
        with os.fdopen(descriptor, "w", encoding="utf-8", newline="\n") as handle:
            handle.write(payload)
            handle.flush()
            os.fsync(handle.fileno())
        os.replace(temp_path, path)
    finally:
        if temp_path.exists():
            temp_path.unlink()


def reset_bridge_memory(path: Path) -> BridgeMemory:
    try:
        path.unlink()
    except FileNotFoundError:
        pass
    return BridgeMemory()
