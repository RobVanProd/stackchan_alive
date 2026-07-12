"""Deterministic host-side conversation lease for Stackchan conversation v2."""

from __future__ import annotations

from dataclasses import dataclass
from enum import Enum


class ConversationPhase(str, Enum):
    IDLE = "idle"
    ENGAGED = "engaged"
    THINKING = "thinking"
    SPEAKING = "speaking"
    REPLY_WINDOW = "reply_window"
    COOLDOWN = "cooldown"


@dataclass(frozen=True)
class ConversationConfig:
    reply_window_ms: int = 8_000
    acoustic_tail_ms: int = 250
    cooldown_ms: int = 300
    max_turns: int = 12
    barge_in_enabled: bool = True
    exit_phrases: tuple[str, ...] = (
        "goodbye stackchan",
        "stop listening",
        "end conversation",
        "that's all",
    )

    def __post_init__(self) -> None:
        if self.reply_window_ms <= 0:
            raise ValueError("reply_window_ms must be positive")
        if self.acoustic_tail_ms < 0:
            raise ValueError("acoustic_tail_ms cannot be negative")
        if self.cooldown_ms < 0:
            raise ValueError("cooldown_ms cannot be negative")
        if self.max_turns <= 0:
            raise ValueError("max_turns must be positive")


@dataclass(frozen=True)
class ConversationTransition:
    phase: ConversationPhase
    actions: tuple[str, ...] = ()
    reason: str = ""


class ConversationSession:
    """Owns a typed conversation lease without granting motion authority."""

    def __init__(self, config: ConversationConfig | None = None) -> None:
        self.config = config or ConversationConfig()
        self.phase = ConversationPhase.IDLE
        self.owner_id = ""
        self.session_number = 0
        self.turns = 0
        self.capture_open = False
        self.echo_guard = False
        self.acoustic_tail_until_ms = 0
        self.reply_window_until_ms = 0
        self.cooldown_until_ms = 0
        self.close_after_response = False
        self.last_close_reason = ""

    @staticmethod
    def _now(now_ms: int) -> int:
        now = int(now_ms)
        if now < 0:
            raise ValueError("now_ms cannot be negative")
        return now

    @staticmethod
    def _normalize_text(text: str) -> str:
        return " ".join(str(text or "").strip().lower().split()).rstrip(".!?")

    def _transition(self, *actions: str, reason: str = "") -> ConversationTransition:
        return ConversationTransition(self.phase, tuple(actions), reason)

    def _begin_cooldown(self, now_ms: int, reason: str) -> ConversationTransition:
        self.phase = ConversationPhase.COOLDOWN
        self.capture_open = False
        self.echo_guard = False
        self.acoustic_tail_until_ms = 0
        self.reply_window_until_ms = 0
        self.cooldown_until_ms = now_ms + self.config.cooldown_ms
        self.close_after_response = False
        self.last_close_reason = reason
        return self._transition("close_capture", "session_closing", reason=reason)

    def _return_idle(self, reason: str) -> ConversationTransition:
        self.phase = ConversationPhase.IDLE
        self.owner_id = ""
        self.turns = 0
        self.capture_open = False
        self.echo_guard = False
        self.acoustic_tail_until_ms = 0
        self.reply_window_until_ms = 0
        self.cooldown_until_ms = 0
        self.close_after_response = False
        self.last_close_reason = reason
        return self._transition("close_capture", "session_closed", reason=reason)

    def wake(self, now_ms: int, owner_id: str = "") -> ConversationTransition:
        now = self._now(now_ms)
        self.session_number += 1
        self.phase = ConversationPhase.ENGAGED
        self.owner_id = str(owner_id or "")[:64]
        self.turns = 0
        self.capture_open = True
        self.echo_guard = False
        self.acoustic_tail_until_ms = 0
        self.reply_window_until_ms = now + self.config.reply_window_ms
        self.cooldown_until_ms = 0
        self.close_after_response = False
        self.last_close_reason = ""
        return self._transition("session_started", "open_capture", reason="wake")

    def utterance_started(self, now_ms: int) -> ConversationTransition:
        self._now(now_ms)
        if self.phase not in (ConversationPhase.ENGAGED, ConversationPhase.REPLY_WINDOW):
            return self._transition("reject_utterance", reason="capture_not_available")
        if not self.capture_open or self.echo_guard:
            return self._transition("reject_utterance", reason="capture_not_available")
        self.phase = ConversationPhase.ENGAGED
        return self._transition("utterance_accepted", reason="listening")

    def utterance_committed(self, now_ms: int, text: str) -> ConversationTransition:
        now = self._now(now_ms)
        if self.phase != ConversationPhase.ENGAGED or not self.capture_open:
            return self._transition("reject_utterance", reason="not_listening")
        self.capture_open = False
        normalized = self._normalize_text(text)
        exit_phrases = {self._normalize_text(item) for item in self.config.exit_phrases}
        if normalized in exit_phrases:
            return self._begin_cooldown(now, "exit_phrase")
        if not normalized:
            return self._begin_cooldown(now, "empty_utterance")
        self.turns += 1
        self.close_after_response = self.turns >= self.config.max_turns
        self.phase = ConversationPhase.THINKING
        self.reply_window_until_ms = 0
        return self._transition("close_capture", "begin_generation", reason="utterance_committed")

    def response_started(self, now_ms: int) -> ConversationTransition:
        self._now(now_ms)
        if self.phase != ConversationPhase.THINKING:
            return self._transition("reject_response", reason="not_thinking")
        self.phase = ConversationPhase.SPEAKING
        self.capture_open = False
        self.echo_guard = True
        return self._transition("close_capture", "echo_guard_on", reason="response_started")

    def playback_completed(self, now_ms: int) -> ConversationTransition:
        now = self._now(now_ms)
        if self.phase != ConversationPhase.SPEAKING:
            return self._transition("reject_playback_complete", reason="not_speaking")
        if self.close_after_response:
            return self._begin_cooldown(now, "turn_limit")
        self.phase = ConversationPhase.REPLY_WINDOW
        self.capture_open = False
        self.echo_guard = True
        self.acoustic_tail_until_ms = now + self.config.acoustic_tail_ms
        self.reply_window_until_ms = self.acoustic_tail_until_ms + self.config.reply_window_ms
        return self._transition("playback_complete", "acoustic_tail", reason="reply_pending")

    def barge_in(self, now_ms: int) -> ConversationTransition:
        now = self._now(now_ms)
        if not self.config.barge_in_enabled:
            return self._transition("reject_barge_in", reason="barge_in_disabled")
        if self.phase not in (ConversationPhase.THINKING, ConversationPhase.SPEAKING):
            return self._transition("reject_barge_in", reason="not_busy")
        actions = ["cancel_generation"]
        if self.phase == ConversationPhase.SPEAKING:
            actions.append("cancel_playback")
        self.phase = ConversationPhase.ENGAGED
        self.capture_open = True
        self.echo_guard = False
        self.acoustic_tail_until_ms = 0
        self.reply_window_until_ms = now + self.config.reply_window_ms
        self.close_after_response = False
        actions.append("open_capture")
        return self._transition(*actions, reason="barge_in")

    def turn_failed(self, now_ms: int, reason: str = "turn_failed") -> ConversationTransition:
        now = self._now(now_ms)
        if self.phase not in (ConversationPhase.THINKING, ConversationPhase.SPEAKING):
            return self._transition("reject_turn_failure", reason="not_busy")
        return self._begin_cooldown(now, self._normalize_text(reason) or "turn_failed")

    def cancel(self, now_ms: int, reason: str = "cancelled") -> ConversationTransition:
        now = self._now(now_ms)
        if self.phase == ConversationPhase.IDLE:
            return self._transition("session_already_closed", reason="idle")
        return self._begin_cooldown(now, self._normalize_text(reason) or "cancelled")

    def tick(self, now_ms: int) -> ConversationTransition:
        now = self._now(now_ms)
        if self.phase == ConversationPhase.REPLY_WINDOW:
            if now >= self.reply_window_until_ms:
                return self._begin_cooldown(now, "reply_timeout")
            if not self.capture_open and now >= self.acoustic_tail_until_ms:
                self.phase = ConversationPhase.ENGAGED
                self.capture_open = True
                self.echo_guard = False
                return self._transition("echo_guard_off", "open_capture", reason="reply_window_open")
        if self.phase == ConversationPhase.ENGAGED and now >= self.reply_window_until_ms:
            return self._begin_cooldown(now, "reply_timeout")
        if self.phase == ConversationPhase.COOLDOWN and now >= self.cooldown_until_ms:
            return self._return_idle(self.last_close_reason or "cooldown_complete")
        return self._transition(reason="no_change")

    def bridge_lost(self) -> ConversationTransition:
        actions = ["close_capture"]
        if self.phase == ConversationPhase.THINKING:
            actions.append("cancel_generation")
        if self.phase == ConversationPhase.SPEAKING:
            actions.append("cancel_playback")
        self._return_idle("bridge_lost")
        actions.append("session_closed")
        return self._transition(*actions, reason="bridge_lost")

    def snapshot(self, now_ms: int) -> dict[str, object]:
        now = self._now(now_ms)
        return {
            "conversation_state": self.phase.value,
            "conversation_session": self.session_number,
            "conversation_owner": self.owner_id,
            "conversation_turns": self.turns,
            "conversation_capture_open": self.capture_open,
            "conversation_echo_guard": self.echo_guard,
            "conversation_reply_window_remaining_ms": max(0, self.reply_window_until_ms - now),
            "conversation_acoustic_tail_remaining_ms": max(0, self.acoustic_tail_until_ms - now),
            "conversation_close_reason": self.last_close_reason,
        }
