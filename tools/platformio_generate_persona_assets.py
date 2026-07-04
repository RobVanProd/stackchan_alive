from pathlib import Path
import os
import sys

Import("env")


INTENT_ENUMS = {
    "boot": "Boot",
    "idle": "Idle",
    "attend": "Attend",
    "listen": "Listen",
    "think": "Think",
    "speak": "Speak",
    "react": "React",
    "happy": "Happy",
    "concern": "Concern",
    "sleep": "Sleep",
    "error": "Error",
    "safety": "Safety",
}

EARCON_ENUMS = {
    "none": "None",
    "wake": "Wake",
    "confirm": "Confirm",
    "think": "Think",
    "happy": "Happy",
    "concern": "Concern",
    "sleep": "Sleep",
    "error": "Error",
    "safety": "Safety",
}


def _cpp_string(value):
    text = str(value)
    return '"' + text.replace("\\", "\\\\").replace('"', '\\"') + '"'


def _persona_from_defines():
    for define in env.get("CPPDEFINES", []):
        if isinstance(define, (tuple, list)) and len(define) >= 2 and define[0] == "STACKCHAN_PERSONA":
            return str(define[1]).strip('"')
        if isinstance(define, str) and define.startswith("STACKCHAN_PERSONA="):
            return define.split("=", 1)[1].strip('"')
    return ""


def _selected_persona(project_dir):
    project_option = ""
    if hasattr(env, "GetProjectOption"):
        project_option = str(env.GetProjectOption("custom_persona", "") or "").strip()
    return (
        project_option
        or os.environ.get("STACKCHAN_PERSONA", "").strip()
        or _persona_from_defines()
        or "spark"
    )


def _entry(intent_key, line):
    intent = INTENT_ENUMS.get(intent_key)
    if intent is None:
        raise RuntimeError(f"Unknown persona speech intent: {intent_key}")
    earcon_key = str(line.get("earcon", "none")).lower()
    earcon = EARCON_ENUMS.get(earcon_key)
    if earcon is None:
        raise RuntimeError(f"Unknown persona speech earcon for {intent_key}: {earcon_key}")
    text = str(line.get("text", "")).strip()
    if not text:
        raise RuntimeError(f"Missing persona speech text for {intent_key}")
    priority = int(line.get("priority", 0))
    delay_ms = int(line.get("earcon_delay_ms", 0))
    return (
        f"    {{SpeechIntent::{intent}, {_cpp_string(text)}, "
        f"{priority}, SpeechEarcon::{earcon}, {delay_ms}}},"
    )


def _clamp_int(value, minimum, maximum, default):
    try:
        numeric = int(value)
    except (TypeError, ValueError):
        numeric = default
    return max(minimum, min(maximum, numeric))


def _clamp_float(value, minimum, maximum, default):
    try:
        numeric = float(value)
    except (TypeError, ValueError):
        numeric = default
    return max(minimum, min(maximum, numeric))


def _cpp_float(value):
    text = f"{float(value):.6f}".rstrip("0").rstrip(".")
    if text in ("", "-0"):
        text = "0"
    if "." not in text and "e" not in text.lower():
        text = f"{text}.0"
    return f"{text}f"


def _mapping(value):
    return value if isinstance(value, dict) else {}


def _expression_value(spec, key, minimum, maximum, default):
    return _clamp_float(_mapping(spec).get(key), minimum, maximum, default)


def _earcon_tones(name, spec):
    base_hz = _clamp_int(spec.get("base_hz"), 160, 2400, 660)
    chirps = _clamp_int(spec.get("chirps"), 1, 4, 1)
    duration_ms = _clamp_int(spec.get("duration_ms"), 60, 360, 160)
    gap_ms = 12 if chirps > 1 else 0
    total_gap_ms = gap_ms * (chirps - 1)
    tone_ms = max(24, (duration_ms - total_gap_ms) // chirps)
    level = 190
    if name in ("sleep", "concern"):
        level = 155
    elif name in ("error", "safety"):
        level = 175

    descending = name in ("sleep", "concern", "error")
    tones = []
    for index in range(chirps):
        step = -0.16 * index if descending else 0.18 * index
        frequency_hz = _clamp_int(round(base_hz * (1.0 + step)), 120, 2800, base_hz)
        tones.append(
            {
                "frequency_hz": frequency_hz,
                "duration_ms": tone_ms,
                "level": level,
                "gap_ms": gap_ms if index < chirps - 1 else 0,
            }
        )
    return tones


def _earcon_entry(earcon_key, spec):
    earcon = EARCON_ENUMS.get(earcon_key)
    if earcon is None or earcon == "None":
        raise RuntimeError(f"Unknown persona earcon key: {earcon_key}")
    tones = _earcon_tones(earcon_key, spec if isinstance(spec, dict) else {})
    return earcon, tones


project_dir = Path(env["PROJECT_DIR"])
sys.path.insert(0, str(project_dir / "bridge"))

from persona_pack import load_and_validate_persona_pack  # noqa: E402


persona_id = _selected_persona(project_dir)
pack = load_and_validate_persona_pack(persona_id, project_dir)

build_dir = Path(env.subst("$BUILD_DIR"))
generated_dir = build_dir / "generated"
generated_dir.mkdir(parents=True, exist_ok=True)
speech_header_path = generated_dir / "PersonaSpeechLines.hpp"
earcon_header_path = generated_dir / "PersonaEarcons.hpp"
behavior_header_path = generated_dir / "PersonaBehavior.hpp"
expressions_header_path = generated_dir / "PersonaExpressions.hpp"

ordered_intents = (
    "boot",
    "idle",
    "listen",
    "think",
    "speak",
    "react",
    "happy",
    "concern",
    "sleep",
    "error",
    "safety",
)

parts = [
    "#pragma once",
    "",
    "#include \"persona/StateMatrix.hpp\"",
    "",
    "namespace stackchan {",
    "namespace generated_persona {",
    "",
    f"static constexpr const char* kPersonaId = {_cpp_string(pack.pack_id)};",
    "",
    "struct PersonaSpeechLine {",
    "  SpeechIntent intent;",
    "  const char* text;",
    "  uint8_t priority;",
    "  SpeechEarcon earcon;",
    "  uint16_t earconDelayMs;",
    "};",
    "",
    "static constexpr PersonaSpeechLine kSpeechLines[] = {",
]

for intent_key in ordered_intents:
    parts.append(_entry(intent_key, pack.spoken_line(intent_key)))

parts.extend(
    [
        "};",
        "",
        "inline SpeechCue makeSpeechCue(SpeechIntent intent) {",
        "  for (const PersonaSpeechLine& line : kSpeechLines) {",
        "    if (line.intent == intent) {",
        "      return {line.intent, line.text, line.priority, line.earcon, line.earconDelayMs};",
        "    }",
        "  }",
        "  return {};",
        "}",
        "",
        "}  // namespace generated_persona",
        "}  // namespace stackchan",
        "",
    ]
)

new_text = "\n".join(parts)
if speech_header_path.exists() and speech_header_path.read_text(encoding="utf-8") == new_text:
    pass
else:
    speech_header_path.write_text(new_text, encoding="utf-8")

earcon_map = pack.earcons.get("earcons", {})
if not isinstance(earcon_map, dict):
    raise RuntimeError(f"Persona {pack.pack_id} earcons.yaml must contain an earcons mapping")

earcon_parts = [
    "#pragma once",
    "",
    "#include <stddef.h>",
    "#include <stdint.h>",
    "",
    "#include \"persona/StateMatrix.hpp\"",
    "",
    "namespace stackchan {",
    "namespace generated_persona {",
    "",
    f"static constexpr bool kUsePersonaEarconPatterns = {'true' if pack.pack_id != 'spark' else 'false'};",
    "",
    "struct PersonaEarconTone {",
    "  uint16_t frequencyHz;",
    "  uint16_t durationMs;",
    "  uint8_t level;",
    "  uint8_t gapMs;",
    "};",
    "",
    "struct PersonaEarconPattern {",
    "  const PersonaEarconTone* tones;",
    "  uint8_t count;",
    "};",
    "",
]

ordered_earcons = ("wake", "confirm", "think", "happy", "concern", "sleep", "error", "safety")
for earcon_key in ordered_earcons:
    _, tones = _earcon_entry(earcon_key, earcon_map.get(earcon_key, {}))
    symbol = EARCON_ENUMS[earcon_key]
    earcon_parts.append(f"static constexpr PersonaEarconTone k{symbol}EarconTones[] = {{")
    for tone in tones:
        earcon_parts.append(
            "    {"
            f"{tone['frequency_hz']}, {tone['duration_ms']}, {tone['level']}, {tone['gap_ms']}"
            "},"
        )
    earcon_parts.append("};")
    earcon_parts.append("")

earcon_parts.extend(
    [
        "template <size_t N>",
        "constexpr PersonaEarconPattern personaPatternOf(const PersonaEarconTone (&tones)[N]) {",
        "  return {tones, static_cast<uint8_t>(N)};",
        "}",
        "",
        "inline PersonaEarconPattern earconPatternFor(SpeechEarcon earcon) {",
        "  switch (earcon) {",
    ]
)

for earcon_key in ordered_earcons:
    symbol = EARCON_ENUMS[earcon_key]
    earcon_parts.extend(
        [
            f"    case SpeechEarcon::{symbol}:",
            f"      return personaPatternOf(k{symbol}EarconTones);",
        ]
    )

earcon_parts.extend(
    [
        "    case SpeechEarcon::None:",
        "      break;",
        "  }",
        "  return {nullptr, 0};",
        "}",
        "",
        "}  // namespace generated_persona",
        "}  // namespace stackchan",
        "",
    ]
)

earcon_text = "\n".join(earcon_parts)
if earcon_header_path.exists() and earcon_header_path.read_text(encoding="utf-8") == earcon_text:
    pass
else:
    earcon_header_path.write_text(earcon_text, encoding="utf-8")

behavior = _mapping(pack.behavior)
idle_life = _mapping(behavior.get("idle_life"))
circadian = _mapping(behavior.get("circadian"))
emotion_response = _mapping(behavior.get("emotion_response"))

fidget_min_ms = _clamp_int(idle_life.get("fidget_min_ms"), 1000, 120000, 10000)
fidget_max_ms = _clamp_int(idle_life.get("fidget_max_ms"), fidget_min_ms, 180000, 30000)

behavior_parts = [
    "#pragma once",
    "",
    "#include <stdint.h>",
    "",
    "namespace stackchan {",
    "namespace generated_persona {",
    "",
    f"static constexpr const char* kBehaviorPersonaId = {_cpp_string(pack.pack_id)};",
    "",
    "// Base idle breathing rate; lower values make a persona feel calmer.",
    "static constexpr float kIdleBreathingHz = "
    f"{_cpp_float(_clamp_float(idle_life.get('breathing_hz'), 0.05, 0.50, 0.20))};",
    "// Base whole-face breathing amplitude in pixels before emotion modulation.",
    "static constexpr float kIdleBreathingPx = "
    f"{_cpp_float(_clamp_float(idle_life.get('breathing_px'), 0.20, 4.00, 1.50))};",
    "// Minimum/maximum idle fidget interval; jitter prevents metronomic motion.",
    f"static constexpr uint32_t kIdleFidgetMinMs = {fidget_min_ms}UL;",
    f"static constexpr uint32_t kIdleFidgetMaxMs = {fidget_max_ms}UL;",
    "// Reduced-motion multiplier; keeps life visible while calming background motion.",
    "static constexpr float kReducedMotionScale = "
    f"{_cpp_float(_clamp_float(idle_life.get('reduced_motion_scale'), 0.05, 1.00, 0.30))};",
    "",
    "// Circadian hour windows; these bias energy without forcing a mode.",
    f"static constexpr uint8_t kEveningStartHour = {_clamp_int(circadian.get('evening_start_hour'), 0, 23, 18)};",
    f"static constexpr uint8_t kNightStartHour = {_clamp_int(circadian.get('night_start_hour'), 0, 23, 21)};",
    f"static constexpr uint8_t kMorningStartHour = {_clamp_int(circadian.get('morning_start_hour'), 0, 23, 6)};",
    f"static constexpr uint8_t kMorningEndHour = {_clamp_int(circadian.get('morning_end_hour'), 0, 24, 10)};",
    "",
    "// Persona-scale emotional response gains used by shared event logic.",
    "static constexpr float kCuriosityArousalDelta = "
    f"{_cpp_float(_clamp_float(emotion_response.get('curiosity_arousal_delta'), 0.00, 0.50, 0.10))};",
    "static constexpr float kSafetyValenceDelta = "
    f"{_cpp_float(_clamp_float(emotion_response.get('safety_valence_delta'), -1.00, 0.00, -0.30))};",
    "static constexpr float kHappyValenceDelta = "
    f"{_cpp_float(_clamp_float(emotion_response.get('happy_valence_delta'), 0.00, 0.80, 0.20))};",
    "",
    "}  // namespace generated_persona",
    "}  // namespace stackchan",
    "",
]

behavior_text = "\n".join(behavior_parts)
if behavior_header_path.exists() and behavior_header_path.read_text(encoding="utf-8") == behavior_text:
    pass
else:
    behavior_header_path.write_text(behavior_text, encoding="utf-8")

expressions = _mapping(pack.expressions)


def _expr_pose(spec, defaults=None):
    defaults = defaults or {}
    return {
        "eyeOpen": _expression_value(spec, "eye_open", 0.02, 1.20, defaults.get("eyeOpen", 0.85)),
        "eyeSmile": _expression_value(spec, "eye_smile", 0.00, 1.00, defaults.get("eyeSmile", 0.15)),
        "squint": _expression_value(spec, "squint", 0.00, 1.00, defaults.get("squint", 0.0)),
        "browTilt": _expression_value(spec, "brow_tilt", -1.00, 1.00, defaults.get("browTilt", 0.0)),
        "mouthSmile": _expression_value(spec, "mouth_smile", -1.00, 1.00, defaults.get("mouthSmile", 0.15)),
        "mouthOpen": _expression_value(spec, "mouth_open", 0.00, 1.00, defaults.get("mouthOpen", 0.0)),
        "pupilX": _expression_value(spec, "pupil_x", -1.00, 1.00, defaults.get("pupilX", 0.0)),
        "pupilY": _expression_value(spec, "pupil_y", -1.00, 1.00, defaults.get("pupilY", 0.0)),
        "pupilScale": _expression_value(spec, "pupil_scale", 0.50, 1.50, defaults.get("pupilScale", 1.0)),
        "faceX": _expression_value(spec, "face_x", -12.00, 12.00, defaults.get("faceX", 0.0)),
        "faceY": _expression_value(spec, "face_y", -12.00, 12.00, defaults.get("faceY", 0.0)),
    }


def _pose_cpp(symbol, pose):
    fields = (
        "eyeOpen",
        "eyeSmile",
        "squint",
        "browTilt",
        "mouthSmile",
        "mouthOpen",
        "pupilX",
        "pupilY",
        "pupilScale",
        "faceX",
        "faceY",
    )
    values = ", ".join(_cpp_float(pose[field]) for field in fields)
    return f"static constexpr PersonaExpressionTargets {symbol} = {{{values}}};"


neutral_pose = _expr_pose(_mapping(expressions.get("neutral")))
expression_pose_keys = (
    ("kNeutralExpression", "neutral", neutral_pose),
    ("kDrowsyExpression", "drowsy", neutral_pose),
    ("kSurpriseExpression", "surprise", neutral_pose),
    ("kPickedUpExpression", "picked_up", neutral_pose),
    ("kShakenExpression", "shaken", neutral_pose),
    ("kPutDownExpression", "put_down", neutral_pose),
    ("kTiltedExpression", "tilted", neutral_pose),
    ("kSoundDirectionExpression", "sound_direction", neutral_pose),
    ("kLoudNoiseExpression", "loud_noise", neutral_pose),
)

expression_parts = [
    "#pragma once",
    "",
    "#include <stdint.h>",
    "",
    "namespace stackchan {",
    "namespace generated_persona {",
    "",
    f"static constexpr const char* kExpressionsPersonaId = {_cpp_string(pack.pack_id)};",
    "",
    "struct PersonaExpressionTargets {",
    "  float eyeOpen;",
    "  float eyeSmile;",
    "  float squint;",
    "  float browTilt;",
    "  float mouthSmile;",
    "  float mouthOpen;",
    "  float pupilX;",
    "  float pupilY;",
    "  float pupilScale;",
    "  float faceX;",
    "  float faceY;",
    "};",
    "",
]

for symbol, section, defaults in expression_pose_keys:
    expression_parts.append(_pose_cpp(symbol, _expr_pose(_mapping(expressions.get(section)), defaults)))

listen = _mapping(expressions.get("listen"))
think = _mapping(expressions.get("think"))
yawn = _mapping(expressions.get("yawn"))
sound_direction = _mapping(expressions.get("sound_direction"))

expression_parts.extend(
    [
        "",
        "// Listen focus and pitch bias: attending posture without changing the mode vocabulary.",
        "static constexpr float kListenFocus = "
        f"{_cpp_float(_clamp_float(listen.get('focus'), 0.00, 1.00, 0.90))};",
        "static constexpr float kListenPitchBiasDeg = "
        f"{_cpp_float(_clamp_float(listen.get('pitch_bias_deg'), -20.00, 20.00, -4.00))};",
        "// Think gaze/yaw bias: eyes lead the head during computing posture.",
        "static constexpr float kThinkPupilY = "
        f"{_cpp_float(_clamp_float(think.get('pupil_y'), -1.00, 1.00, -0.20))};",
        "static constexpr float kThinkYawBiasDeg = "
        f"{_cpp_float(_clamp_float(think.get('yaw_bias_deg'), -45.00, 45.00, 18.00))};",
        "// Sound-orient yaw bias: head follow-through after eyes lead.",
        "static constexpr float kSoundDirectionYawBiasDeg = "
        f"{_cpp_float(_clamp_float(sound_direction.get('yaw_bias_deg'), -45.00, 45.00, 16.00))};",
        "// Yawn deltas: fatigue peak shape layered over the current expression.",
        f"static constexpr uint32_t kYawnDurationMs = {_clamp_int(yawn.get('duration_ms'), 200, 4000, 1200)}UL;",
        "static constexpr float kYawnEyeOpenDelta = "
        f"{_cpp_float(_clamp_float(yawn.get('eye_open_delta'), -1.00, 0.00, -0.24))};",
        "static constexpr float kYawnSquintDelta = "
        f"{_cpp_float(_clamp_float(yawn.get('squint_delta'), 0.00, 1.00, 0.22))};",
        "static constexpr float kYawnMouthOpen = "
        f"{_cpp_float(_clamp_float(yawn.get('mouth_open'), 0.00, 1.00, 0.55))};",
        "static constexpr float kYawnMouthSmileDelta = "
        f"{_cpp_float(_clamp_float(yawn.get('mouth_smile_delta'), -1.00, 0.00, -0.12))};",
        "static constexpr float kYawnPitchBiasDeg = "
        f"{_cpp_float(_clamp_float(yawn.get('pitch_bias_deg'), -10.00, 10.00, 0.45))};",
        "",
        "}  // namespace generated_persona",
        "}  // namespace stackchan",
        "",
    ]
)

expressions_text = "\n".join(expression_parts)
if expressions_header_path.exists() and expressions_header_path.read_text(encoding="utf-8") == expressions_text:
    pass
else:
    expressions_header_path.write_text(expressions_text, encoding="utf-8")

env.Append(CPPPATH=[str(generated_dir)])
