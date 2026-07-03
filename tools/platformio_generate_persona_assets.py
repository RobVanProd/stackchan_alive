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


project_dir = Path(env["PROJECT_DIR"])
sys.path.insert(0, str(project_dir / "bridge"))

from persona_pack import load_and_validate_persona_pack  # noqa: E402


persona_id = _selected_persona(project_dir)
pack = load_and_validate_persona_pack(persona_id, project_dir)

build_dir = Path(env.subst("$BUILD_DIR"))
generated_dir = build_dir / "generated"
generated_dir.mkdir(parents=True, exist_ok=True)
header_path = generated_dir / "PersonaSpeechLines.hpp"

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
if header_path.exists() and header_path.read_text(encoding="utf-8") == new_text:
    pass
else:
    header_path.write_text(new_text, encoding="utf-8")

env.Append(CPPPATH=[str(generated_dir)])
