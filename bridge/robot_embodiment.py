#!/usr/bin/env python3
"""Bounded, prompt-safe interpretation of Stackchan's live body heartbeat."""

from __future__ import annotations

import math
import time
from dataclasses import dataclass, field


ROBOT_MODES = {
    0: "booting",
    1: "idle",
    2: "attending",
    3: "listening",
    4: "thinking",
    5: "speaking",
    6: "reacting",
    7: "sleeping",
    8: "error",
}
DEFAULT_MAX_AGE_SECONDS = 15.0


def _bounded_float(value: object, minimum: float, maximum: float) -> float | None:
    try:
        parsed = float(value)
    except (TypeError, ValueError):
        return None
    if not math.isfinite(parsed):
        return None
    return max(minimum, min(maximum, parsed))


def _bounded_int(value: object, minimum: int, maximum: int) -> int | None:
    try:
        parsed = int(value)
    except (TypeError, ValueError):
        return None
    return max(minimum, min(maximum, parsed))


def _flag(value: object) -> bool:
    return value is True or value == 1 or str(value).strip().lower() in {"1", "true"}


def _orientation(x: float | None, y: float | None, z: float | None) -> str:
    if x is None or y is None or z is None:
        return "unknown"
    axes = ((abs(x), "on its side"), (abs(y), "upright"), (abs(z), "face up or down"))
    strength, label = max(axes)
    return label if strength >= 0.65 else "tilted"


def _mood(arousal: float | None, valence: float | None, fatigue: float | None) -> str:
    if fatigue is not None and fatigue >= 0.72:
        return "tired"
    energy = "energetic" if arousal is not None and arousal >= 0.62 else "calm"
    if valence is not None and valence >= 0.30:
        return f"{energy} and positive"
    if valence is not None and valence <= -0.25:
        return f"{energy} and concerned"
    return energy


@dataclass
class RobotEmbodimentState:
    lines: tuple[str, ...] = ()
    updated_at: float = 0.0
    max_age_seconds: float = DEFAULT_MAX_AGE_SECONDS
    updates: int = 0

    def update(self, heartbeat: dict[str, object], *, observed_at: float | None = None) -> bool:
        if str(heartbeat.get("type", "")).strip().lower() != "heartbeat":
            return False

        mode_id = _bounded_int(heartbeat.get("robot_mode"), 0, 8)
        arousal = _bounded_float(heartbeat.get("emotion_arousal"), 0.0, 1.0)
        valence = _bounded_float(heartbeat.get("emotion_valence"), -1.0, 1.0)
        fatigue = _bounded_float(heartbeat.get("emotion_fatigue"), 0.0, 1.0)
        battery = _bounded_int(heartbeat.get("battery_percent"), -1, 100)
        temperature = _bounded_float(heartbeat.get("chip_temp_c"), -40.0, 125.0)
        gravity_x = _bounded_float(heartbeat.get("imu_gravity_x"), -2.0, 2.0)
        gravity_y = _bounded_float(heartbeat.get("imu_gravity_y"), -2.0, 2.0)
        gravity_z = _bounded_float(heartbeat.get("imu_gravity_z"), -2.0, 2.0)

        lines = [f"mode: {ROBOT_MODES.get(mode_id, 'unknown')}"]
        lines.append(f"mood: {_mood(arousal, valence, fatigue)}")

        power = "external power" if _flag(heartbeat.get("external_power")) else "battery power"
        if battery is not None and battery >= 0:
            power += f"; battery {battery}%"
        charging_state = _bounded_int(heartbeat.get("charging_state"), -1, 2)
        if charging_state == 1:
            power += "; charging"
        elif charging_state == 2:
            power += "; charge complete or idle"
        lines.append(f"power: {power}")

        held = _flag(heartbeat.get("imu_picked_up"))
        lines.append(
            f"physical state: being held {'yes' if held else 'no'}; "
            f"orientation {_orientation(gravity_x, gravity_y, gravity_z)}"
        )
        lines.append(
            "movement: enabled" if _flag(heartbeat.get("motion_enabled")) else "movement: resting"
        )

        camera_enabled = _flag(heartbeat.get("camera_enabled"))
        camera_active = _flag(heartbeat.get("camera_active"))
        camera_target = _flag(heartbeat.get("camera_target_fresh"))
        if camera_enabled and camera_active and camera_target:
            vision = "active; person currently detected yes"
        elif camera_enabled and camera_active:
            vision = "active; person currently detected no"
        elif camera_enabled:
            vision = "available but inactive; person currently detected unknown"
        else:
            vision = "unavailable in this firmware; person currently detected unknown"
        touch = "ready" if _flag(heartbeat.get("touch_ready")) else "unavailable"
        lines.append(f"senses: touch {touch}; vision {vision}")

        voice = "speaking" if _flag(heartbeat.get("speaker_active")) else "quiet"
        lines.append(f"voice output: {voice}")
        if temperature is not None:
            thermal = "hot" if temperature >= 68.0 else "warm" if temperature >= 62.0 else "normal"
            lines.append(f"thermal state: {thermal} ({temperature:.1f} C)")

        self.lines = tuple(lines)
        self.updated_at = time.monotonic() if observed_at is None else float(observed_at)
        self.updates += 1
        return True

    def is_fresh(self, *, now: float | None = None) -> bool:
        if not self.lines or self.updated_at <= 0.0:
            return False
        current = time.monotonic() if now is None else float(now)
        return 0.0 <= current - self.updated_at <= self.max_age_seconds

    def prompt_lines(self, *, now: float | None = None) -> tuple[str, ...]:
        return self.lines if self.is_fresh(now=now) else ()
