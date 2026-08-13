"""Bounded cross-session affect state for the host character.

This is device character state, not user memory: it stores no user data, no
facts, and no transcript content — only a slow-moving mood baseline and a
rapport scalar, both derived from turn outcomes the host already observed.
It deliberately lives outside BridgeMemory: MEMORY_CONTRACT.md gates any new
memory-schema work behind the AUDIT-03 authorization repairs, and nothing here
is a memory delta under that contract.

The design mirrors the firmware EmotionModel's persisted temperament: a
baseline that drifts inside a hard band around neutral, so a good week warms
the character without ever turning it into a different one, and a corrupt or
hand-edited file can never push it outside the band.
"""

from __future__ import annotations

import json
import os
import time
from dataclasses import dataclass, replace
from pathlib import Path

AFFECT_STATE_SCHEMA = "stackchan.host-affect-state.v1"

# Temperament may wander this far from neutral but no further.
MOOD_VALENCE_BAND = 0.30
MOOD_AROUSAL_BAND = 0.15
# How strongly one turn's emotion pulls the baseline. Dozens of turns move
# mood; one bad exchange does not.
MOOD_DRIFT_ALPHA = 0.05
# Rapport rises with completed exchanges and relaxes toward unfamiliar over
# idle days, so a robot left alone for a month greets like an acquaintance.
RAPPORT_PER_TURN = 0.02
RAPPORT_DAILY_DECAY = 0.97
SECONDS_PER_DAY = 86400.0


def _clamp(value: float, low: float, high: float) -> float:
    return max(low, min(high, value))


@dataclass(frozen=True)
class AffectState:
    mood_valence: float = 0.0
    mood_arousal: float = 0.0
    rapport: float = 0.0
    updated_at_s: float = 0.0

    def clamped(self) -> "AffectState":
        return AffectState(
            mood_valence=_clamp(float(self.mood_valence), -MOOD_VALENCE_BAND, MOOD_VALENCE_BAND),
            mood_arousal=_clamp(float(self.mood_arousal), -MOOD_AROUSAL_BAND, MOOD_AROUSAL_BAND),
            rapport=_clamp(float(self.rapport), 0.0, 1.0),
            updated_at_s=max(0.0, float(self.updated_at_s)),
        )


def load_affect_state(path: str | Path | None) -> AffectState:
    if not path:
        return AffectState()
    try:
        payload = json.loads(Path(path).read_text(encoding="utf-8"))
    except (OSError, ValueError):
        return AffectState()
    if not isinstance(payload, dict) or payload.get("schema") != AFFECT_STATE_SCHEMA:
        return AffectState()
    try:
        state = AffectState(
            mood_valence=float(payload.get("mood_valence", 0.0)),
            mood_arousal=float(payload.get("mood_arousal", 0.0)),
            rapport=float(payload.get("rapport", 0.0)),
            updated_at_s=float(payload.get("updated_at_s", 0.0)),
        )
    except (TypeError, ValueError):
        return AffectState()
    return state.clamped()


def save_affect_state(path: str | Path | None, state: AffectState) -> bool:
    if not path:
        return False
    target = Path(path)
    payload = {
        "schema": AFFECT_STATE_SCHEMA,
        "mood_valence": round(state.mood_valence, 4),
        "mood_arousal": round(state.mood_arousal, 4),
        "rapport": round(state.rapport, 4),
        "updated_at_s": round(state.updated_at_s, 3),
    }
    temp = target.with_name(target.name + ".tmp")
    try:
        target.parent.mkdir(parents=True, exist_ok=True)
        temp.write_text(json.dumps(payload, separators=(",", ":")) + "\n", encoding="utf-8")
        os.replace(temp, target)
    except OSError:
        return False
    return True


def observe_turn(
    state: AffectState,
    *,
    arousal: float,
    valence: float,
    turn_ok: bool,
    now_s: float | None = None,
) -> AffectState:
    now = time.time() if now_s is None else float(now_s)
    decayed = _decay_rapport(state, now)
    if not turn_ok:
        return replace(decayed, updated_at_s=now).clamped()
    mood_valence = decayed.mood_valence + (
        _clamp(float(valence), -1.0, 1.0) - decayed.mood_valence
    ) * MOOD_DRIFT_ALPHA
    mood_arousal = decayed.mood_arousal + (
        _clamp(float(arousal), -1.0, 1.0) - decayed.mood_arousal
    ) * MOOD_DRIFT_ALPHA
    return AffectState(
        mood_valence=mood_valence,
        mood_arousal=mood_arousal,
        rapport=decayed.rapport + RAPPORT_PER_TURN,
        updated_at_s=now,
    ).clamped()


def _decay_rapport(state: AffectState, now_s: float) -> AffectState:
    if state.updated_at_s <= 0.0 or now_s <= state.updated_at_s:
        return state
    idle_days = (now_s - state.updated_at_s) / SECONDS_PER_DAY
    if idle_days <= 0.0:
        return state
    return replace(state, rapport=state.rapport * (RAPPORT_DAILY_DECAY ** idle_days)).clamped()


def affect_prompt_lines(state: AffectState) -> tuple[str, ...]:
    """One bounded, host-derived context line, or nothing when neutral.

    The line carries coarse words rather than numbers so the model cannot
    recite fake telemetry, and it is omitted entirely near neutral so a fresh
    install has no synthetic mood."""

    descriptors: list[str] = []
    if state.mood_valence >= 0.12:
        descriptors.append("settled and warm lately")
    elif state.mood_valence <= -0.12:
        descriptors.append("a little subdued lately")
    if state.rapport >= 0.5:
        descriptors.append("long-familiar with this user")
    elif state.rapport >= 0.15:
        descriptors.append("getting familiar with this user")
    if not descriptors:
        return ()
    return (f"affect_baseline: {'; '.join(descriptors)} (host-derived, bounded)",)
