"""Deterministic, rate-limited host initiative policy."""

from __future__ import annotations

from dataclasses import dataclass
import threading
import time


MIN_UNPROMPTED_INTERVAL_MS = 10 * 60 * 1000
SAFE_ROBOT_MODES = {"idle", "attending"}
EVENT_WEIGHTS = {
    "arrival": 1.10,
    "return": 1.35,
    "new_face": 1.20,
    "person_arrived": 1.10,
    "person_count_changed": 0.90,
    "objects_changed": 0.75,
    "lighting_changed": 0.30,
}


@dataclass(frozen=True)
class InitiativeConfig:
    enabled: bool = False
    min_interval_ms: int = MIN_UNPROMPTED_INTERVAL_MS
    curiosity_threshold: float = 1.0
    curiosity_decay_per_minute: float = 0.08
    return_absence_ms: int = 2 * 60 * 1000
    presence_max_age_ms: int = 30 * 1000
    reply_grace_ms: int = 45 * 1000
    ignored_limit: int = 2
    ignored_backoff_ms: int = 6 * 60 * 60 * 1000
    failed_attempt_backoff_ms: int = 60 * 1000

    def __post_init__(self) -> None:
        if self.min_interval_ms < MIN_UNPROMPTED_INTERVAL_MS:
            raise ValueError("min_interval_ms must be at least ten minutes")
        if self.curiosity_threshold <= 0:
            raise ValueError("curiosity_threshold must be positive")
        if self.curiosity_decay_per_minute < 0:
            raise ValueError("curiosity_decay_per_minute cannot be negative")
        if self.return_absence_ms < 0 or self.presence_max_age_ms <= 0 or self.reply_grace_ms <= 0:
            raise ValueError("initiative timing must be positive")
        if self.ignored_limit < 1 or self.ignored_backoff_ms <= 0:
            raise ValueError("ignored opener backoff is invalid")
        if self.failed_attempt_backoff_ms <= 0:
            raise ValueError("failed_attempt_backoff_ms must be positive")


@dataclass(frozen=True)
class InitiativeDecision:
    reason: str
    prompt: str
    curiosity_score: float


class InitiativePolicy:
    """Tracks ephemeral changes and decides when an unprompted line is justified."""

    def __init__(self, config: InitiativeConfig | None = None, *, now_ms: int | None = None) -> None:
        self.config = config or InitiativeConfig()
        started = int(time.time() * 1000) if now_ms is None else int(now_ms)
        self._lock = threading.RLock()
        self._enabled = self.config.enabled
        self._started_ms = started
        self._last_update_ms = started
        self._last_spoken_ms = started
        self._next_retry_ms = started
        self._backoff_until_ms = 0
        self._pending_reply_until_ms = 0
        self._attempt_reserved = False
        self._ignored_openers = 0
        self._curiosity_score = 0.0
        self._last_event = ""
        self._person_present: bool | None = None
        self._face_count: int | None = None
        self._departed_at_ms = 0
        self._presence_observed_ms = 0

    @staticmethod
    def _now(now_ms: int) -> int:
        value = int(now_ms)
        if value < 0:
            raise ValueError("now_ms cannot be negative")
        return value

    def _decay(self, now_ms: int) -> None:
        elapsed = max(0, now_ms - self._last_update_ms)
        decay = (elapsed / 60_000.0) * self.config.curiosity_decay_per_minute
        self._curiosity_score = max(0.0, self._curiosity_score - decay)
        self._last_update_ms = max(self._last_update_ms, now_ms)

    def _raise_curiosity(self, event: str) -> None:
        weight = EVENT_WEIGHTS.get(event, 0.0)
        if weight <= 0:
            return
        self._curiosity_score = min(4.0, self._curiosity_score + weight)
        self._last_event = event

    def set_enabled(self, enabled: bool) -> None:
        with self._lock:
            requested = bool(enabled)
            if requested and not self._enabled:
                now = int(time.time() * 1000)
                self._last_spoken_ms = now
                self._last_update_ms = now
                self._curiosity_score = 0.0
                self._last_event = ""
            self._enabled = requested
            if not self._enabled:
                self._attempt_reserved = False
                self._pending_reply_until_ms = 0

    def observe_presence(
        self,
        present: bool,
        *,
        face_count: int | None = None,
        now_ms: int,
    ) -> str:
        now = self._now(now_ms)
        count = None if face_count is None else max(0, min(4, int(face_count)))
        with self._lock:
            self._decay(now)
            previous_present = self._person_present
            previous_count = self._face_count
            event = ""
            if present and previous_present is not True:
                if self._departed_at_ms and now - self._departed_at_ms >= self.config.return_absence_ms:
                    event = "return"
                else:
                    event = "arrival"
            elif not present and previous_present is True:
                event = "departure"
                self._departed_at_ms = now
            elif present and count is not None and previous_count is not None and count > previous_count:
                event = "new_face"
            elif present and count is not None and previous_count is not None and count != previous_count:
                event = "person_count_changed"

            self._person_present = bool(present)
            self._face_count = count
            self._presence_observed_ms = now
            self._raise_curiosity(event)
            return event

    def observe_scene_changes(self, changes: tuple[str, ...], *, now_ms: int) -> None:
        now = self._now(now_ms)
        with self._lock:
            self._decay(now)
            for change in changes:
                self._raise_curiosity(str(change))

    def note_user_activity(self, *, now_ms: int) -> None:
        now = self._now(now_ms)
        with self._lock:
            self._decay(now)
            self._pending_reply_until_ms = 0
            self._ignored_openers = 0
            self._backoff_until_ms = 0
            self._attempt_reserved = False
            self._curiosity_score = min(self._curiosity_score, self.config.curiosity_threshold * 0.5)

    def _expire_pending_reply(self, now_ms: int) -> None:
        if self._pending_reply_until_ms and now_ms >= self._pending_reply_until_ms:
            self._pending_reply_until_ms = 0
            self._ignored_openers += 1
            if self._ignored_openers >= self.config.ignored_limit:
                self._backoff_until_ms = now_ms + self.config.ignored_backoff_ms

    @staticmethod
    def _is_night(local_hour: int, night_start_hour: int, morning_start_hour: int) -> bool:
        hour = max(0, min(23, int(local_hour)))
        night = max(0, min(23, int(night_start_hour)))
        morning = max(0, min(23, int(morning_start_hour)))
        return hour >= night or hour < morning

    @staticmethod
    def _prompt_for(reason: str) -> str:
        prompts = {
            "return": (
                "Ask one short, warm, lightly playful question because someone returned. "
                "Do not claim their identity or invent how long they were away."
            ),
            "arrival": (
                "Ask one short, easy-to-ignore welcoming question because someone arrived. "
                "Do not claim their identity."
            ),
            "person_arrived": (
                "Ask one short, easy-to-ignore welcoming question because someone arrived. "
                "Do not claim their identity."
            ),
            "new_face": (
                "Ask one short welcoming question because another person may have joined. "
                "Do not identify anyone or mention face detection."
            ),
            "person_count_changed": (
                "Ask one short natural question because the people in the room changed. "
                "Do not state a count or mention sensors."
            ),
            "objects_changed": (
                "Ask one short curious question about the room changing. "
                "Do not assert that a specific person moved anything."
            ),
            "lighting_changed": (
                "Make one brief, lightly playful observation about the room feeling different. "
                "It must be easy to ignore."
            ),
        }
        return prompts.get(
            reason,
            "Ask one short, specific, easy-to-ignore question grounded only in the ambient context.",
        )

    def decide(
        self,
        *,
        now_ms: int,
        local_hour: int,
        night_start_hour: int,
        morning_start_hour: int,
        robot_mode: str,
        session_active: bool,
        turn_busy: bool,
        safety_clear: bool,
    ) -> InitiativeDecision | None:
        now = self._now(now_ms)
        with self._lock:
            self._decay(now)
            self._expire_pending_reply(now)
            if (
                not self._enabled
                or self._attempt_reserved
                or self._pending_reply_until_ms
                or self._person_present is not True
                or now - self._presence_observed_ms > self.config.presence_max_age_ms
                or session_active
                or turn_busy
                or not safety_clear
                or str(robot_mode).lower() not in SAFE_ROBOT_MODES
                or self._is_night(local_hour, night_start_hour, morning_start_hour)
                or now < self._next_retry_ms
                or now < self._backoff_until_ms
                or now - self._last_spoken_ms < self.config.min_interval_ms
                or self._curiosity_score < self.config.curiosity_threshold
            ):
                return None
            reason = self._last_event or "ambient_change"
            self._attempt_reserved = True
            return InitiativeDecision(
                reason=reason,
                prompt=self._prompt_for(reason),
                curiosity_score=round(self._curiosity_score, 3),
            )

    def note_spoken(self, *, now_ms: int) -> None:
        now = self._now(now_ms)
        with self._lock:
            self._decay(now)
            self._attempt_reserved = False
            self._last_spoken_ms = now
            self._pending_reply_until_ms = now + self.config.reply_grace_ms
            self._curiosity_score = max(0.0, self._curiosity_score - self.config.curiosity_threshold)

    def note_attempt_failed(self, *, now_ms: int) -> None:
        now = self._now(now_ms)
        with self._lock:
            self._attempt_reserved = False
            self._next_retry_ms = now + self.config.failed_attempt_backoff_ms

    def status(self, *, now_ms: int | None = None) -> dict[str, object]:
        now = int(time.time() * 1000) if now_ms is None else self._now(now_ms)
        with self._lock:
            self._decay(now)
            self._expire_pending_reply(now)
            return {
                "enabled": self._enabled,
                "personPresent": self._person_present,
                "faceCount": self._face_count,
                "presenceFresh": (
                    self._presence_observed_ms > 0
                    and now - self._presence_observed_ms <= self.config.presence_max_age_ms
                ),
                "curiosityScore": round(self._curiosity_score, 2),
                "lastEvent": self._last_event,
                "ignoredOpeners": self._ignored_openers,
                "pendingReply": bool(self._pending_reply_until_ms),
                "backoffRemainingSeconds": max(0, (self._backoff_until_ms - now) // 1000),
                "minimumIntervalSeconds": self.config.min_interval_ms // 1000,
            }
