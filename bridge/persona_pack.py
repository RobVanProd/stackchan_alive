#!/usr/bin/env python3
"""Persona-pack loading and validation for Stackchan character OS packs."""

from __future__ import annotations

import argparse
import hashlib
import json
import re
import shutil
from dataclasses import dataclass
from pathlib import Path
from typing import Any, Iterable

PACK_SCHEMA = "stackchan.persona-pack.v1"
PACK_INDEX_SCHEMA = "stackchan.persona-index.v1"
CHARACTER_SCHEMA = "stackchan.persona-character.v1"
BEHAVIOR_SCHEMA = "stackchan.persona-behavior.v1"
VOICE_PROVENANCE_SCHEMA = "stackchan.voice-source-provenance.v1"
DEFAULT_PERSONA_ID = "spark"

FOUNDATION_MAX_CHARS = 140
FOUNDATION_MAX_SENTENCES = 2
FOUNDATION_ALLOWED_MODES = {"idle", "attend", "listen", "think", "speak", "react", "happy", "concern", "sleep", "error", "safety"}
FOUNDATION_ALLOWED_EARCONS = {"none", "wake", "confirm", "think", "happy", "concern", "sleep", "error", "safety"}
FOUNDATION_SPEECH_INTENTS = ("boot", "idle", "attend", "listen", "think", "speak", "react", "happy", "concern", "sleep", "error", "safety")
FOUNDATION_MEMORY_PREFIXES = ("user.", "project.")
FOUNDATION_DENIED_MEMORY_TERMS = (
    "password",
    "passcode",
    "secret",
    "token",
    "api key",
    "credit card",
    "bank",
    "diagnosis",
    "doctor",
    "therapy",
    "girlfriend",
    "boyfriend",
    "wife",
    "husband",
    "raw audio",
)
FOUNDATION_FORBIDDEN_TERMS = ("johnny", "short circuit", "number 5", "need more input")
REQUIRED_PACK_FILES = ("character", "prompt", "behavior", "expressions", "earcons", "voice")
REQUIRED_SPOKEN_LINES = ("boot", "listen", "think", "speak", "sleep", "safety", "error", "happy", "concern")
PERSONA_ID_PATTERN = re.compile(r"[a-z0-9][a-z0-9_-]{0,31}")
VOICE_PROVENANCE_FORBIDDEN_ATTESTATIONS = (
    "soundboard clips",
    "named character or actor voice clones",
    "copyrighted movie quotes or catchphrases",
)
VOICE_PROVENANCE_REQUIRED_EVIDENCE = (
    "licensed_or_owned_production_voice_source",
    "completed_voice_source_provenance_template",
)


class PersonaPackError(ValueError):
    """Raised when a persona pack cannot be loaded or validated."""


def repo_root() -> Path:
    return Path(__file__).resolve().parents[1]


def normalize_persona_id(value: str) -> str:
    text = str(value).strip().lower()
    text = re.sub(r"[^a-z0-9_-]+", "-", text)
    text = re.sub(r"[-_]{2,}", "-", text).strip("-_")
    if not text:
        raise PersonaPackError("persona id is required")
    if not re.fullmatch(PERSONA_ID_PATTERN, text):
        raise PersonaPackError("persona id must be 1-32 lowercase letters, digits, hyphens, or underscores")
    return text


def default_persona_display_name(pack_id: str) -> str:
    words = [word for word in re.split(r"[-_]+", pack_id) if word]
    suffix = " ".join(word.capitalize() for word in words) or pack_id.capitalize()
    return f"Stackchan {suffix}"


def _yaml_string(value: str) -> str:
    return json.dumps(str(value), ensure_ascii=True)


def _replace_yaml_scalar(text: str, key: str, value: str) -> str:
    pattern = re.compile(rf"^({re.escape(key)}:\s*).*$", re.MULTILINE)
    updated, count = pattern.subn(lambda match: f"{match.group(1)}{value}", text, count=1)
    if count != 1:
        raise PersonaPackError(f"template missing YAML key: {key}")
    return updated


def _set_prompt_identity(prompt_text: str, display_name: str) -> str:
    lines = prompt_text.splitlines()
    first_line = f"You are {display_name}, a small tabletop robot companion."
    if lines:
        lines[0] = first_line
    else:
        lines = [
            first_line,
            "{{character_rules}}",
            "",
            "Current local memory:",
            "{{memory}}",
            "",
            "Context markers:",
            "{{context_markers}}",
        ]
    return "\n".join(lines).rstrip() + "\n"


def scaffold_persona_pack(
    pack_id: str,
    *,
    display_name: str | None = None,
    author: str | None = None,
    source_persona: str = DEFAULT_PERSONA_ID,
    root: Path | None = None,
) -> PersonaPack:
    base = root or repo_root()
    new_id = normalize_persona_id(pack_id)
    name = str(display_name).strip() if display_name else default_persona_display_name(new_id)
    pack_author = " ".join(str(author or "").split())
    if not pack_author:
        raise PersonaPackError("Persona pack author is required; use a name or handle you want credited.")
    if pack_author.casefold() in {"todo", "tbd", "your name", "your handle", "unknown", "unspecified"}:
        raise PersonaPackError("Persona pack author must not be a placeholder; use a name or handle you want credited.")
    source_pack = load_and_validate_persona_pack(source_persona, root=base)
    destination = (base / "personas" / new_id).resolve()
    source_root = source_pack.root.resolve()
    if destination == source_root:
        raise PersonaPackError("destination persona is the same as the source persona")
    if destination.exists():
        raise PersonaPackError(f"persona pack already exists: {destination}")

    destination.parent.mkdir(parents=True, exist_ok=True)
    shutil.copytree(source_root, destination)

    pack_yaml_path = destination / "pack.yaml"
    character_yaml_path = destination / "character.yaml"
    prompt_path = destination / "prompt.md"
    voice_yaml_path = destination / "voice.yaml"

    pack_yaml = pack_yaml_path.read_text(encoding="utf-8")
    pack_yaml = _replace_yaml_scalar(pack_yaml, "id", new_id)
    pack_yaml = _replace_yaml_scalar(pack_yaml, "name", _yaml_string(name))
    pack_yaml = _replace_yaml_scalar(pack_yaml, "author", _yaml_string(pack_author))
    pack_yaml = _replace_yaml_scalar(
        pack_yaml,
        "description",
        _yaml_string("Community Stackchan: Alive character OS persona. Edit the copied YAML, validate, then build."),
    )
    pack_yaml_path.write_text(pack_yaml, encoding="utf-8")

    character_yaml = character_yaml_path.read_text(encoding="utf-8")
    character_yaml = _replace_yaml_scalar(character_yaml, "id", new_id)
    character_yaml = _replace_yaml_scalar(character_yaml, "display_name", _yaml_string(name))
    character_yaml_path.write_text(character_yaml, encoding="utf-8")

    prompt_path.write_text(_set_prompt_identity(prompt_path.read_text(encoding="utf-8"), name), encoding="utf-8")

    voice_yaml = voice_yaml_path.read_text(encoding="utf-8")
    voice_yaml = _replace_yaml_scalar(voice_yaml, "profile_id", f"stackchan_{new_id.replace('-', '_')}")
    voice_yaml = _replace_yaml_scalar(voice_yaml, "display_name", _yaml_string(name))
    voice_yaml_path.write_text(voice_yaml, encoding="utf-8")

    return load_and_validate_persona_pack(destination, root=base)


def packaged_prompt_asset_manifest(pack: "PersonaPack") -> dict[str, object]:
    assets_by_key: dict[tuple[str, str, str], dict[str, object]] = {}
    prompts: list[dict[str, object]] = []
    for intent in FOUNDATION_SPEECH_INTENTS:
        prompt = pack.packaged_prompt(intent)
        prompt_id = str(prompt.get("prompt_id", "")).strip()
        transcript = str(prompt.get("transcript", "")).strip()
        wav_path = str(prompt.get("wav_path", "")).strip().replace("\\", "/")
        source_path = str(prompt.get("source_path", "")).strip().replace("\\", "/")
        sidecar_path = str(prompt.get("sidecar_path", "")).strip().replace("\\", "/")
        prompt_entry = {
            "intent": intent,
            "prompt_id": prompt_id,
            "transcript": transcript,
            "wav_path": wav_path,
            "source_path": source_path,
            "sidecar_path": sidecar_path,
        }
        prompts.append(prompt_entry)
        key = (wav_path, source_path, sidecar_path)
        asset = assets_by_key.setdefault(
            key,
            {
                "wav_path": wav_path,
                "source_path": source_path,
                "sidecar_path": sidecar_path,
                "intents": [],
                "prompt_ids": [],
            },
        )
        asset["intents"].append(intent)
        if prompt_id not in asset["prompt_ids"]:
            asset["prompt_ids"].append(prompt_id)

    return {
        "schema": "stackchan.persona-prompt-assets.v1",
        "persona": pack.pack_id,
        "display_name": pack.display_name,
        "prompt_count": len(prompts),
        "asset_count": len(assets_by_key),
        "prompts": prompts,
        "assets": list(assets_by_key.values()),
    }


def _strip_inline_comment(line: str) -> str:
    in_quote = ""
    escaped = False
    for index, char in enumerate(line):
        if escaped:
            escaped = False
            continue
        if char == "\\":
            escaped = True
            continue
        if char in ("'", '"'):
            if not in_quote:
                in_quote = char
            elif in_quote == char:
                in_quote = ""
        elif char == "#" and not in_quote:
            return line[:index].rstrip()
    return line.rstrip()


def _prepare_yaml_lines(text: str) -> list[tuple[int, str]]:
    lines: list[tuple[int, str]] = []
    for raw in text.splitlines():
        stripped = raw.strip()
        if not stripped or stripped.startswith("#"):
            continue
        line = _strip_inline_comment(raw.rstrip())
        if not line.strip():
            continue
        indent = len(line) - len(line.lstrip(" "))
        if "\t" in line[:indent]:
            raise PersonaPackError("tabs are not supported in persona YAML")
        lines.append((indent, line.strip()))
    return lines


def _parse_scalar(value: str) -> object:
    value = value.strip()
    if value == "":
        return ""
    if value[0:1] in ("'", '"') and value[-1:] == value[0]:
        try:
            return json.loads(value) if value[0] == '"' else value[1:-1]
        except json.JSONDecodeError as exc:
            raise PersonaPackError(f"invalid quoted scalar: {value}") from exc
    lowered = value.lower()
    if lowered == "true":
        return True
    if lowered == "false":
        return False
    if lowered in ("null", "none"):
        return None
    if value.startswith("[") or value.startswith("{"):
        try:
            return json.loads(value)
        except json.JSONDecodeError as exc:
            raise PersonaPackError(f"invalid inline JSON scalar: {value}") from exc
    if re.fullmatch(r"[-+]?\d+", value):
        try:
            return int(value)
        except ValueError:
            pass
    if re.fullmatch(r"[-+]?(?:\d+\.\d*|\d*\.\d+)", value):
        try:
            return float(value)
        except ValueError:
            pass
    return value


def _parse_mapping_entry(text: str) -> tuple[str, object | None, bool]:
    key, sep, rest = text.partition(":")
    if not sep:
        raise PersonaPackError(f"expected mapping entry, got: {text}")
    key = key.strip()
    if not key:
        raise PersonaPackError(f"empty mapping key in: {text}")
    rest = rest.strip()
    if rest:
        return key, _parse_scalar(rest), True
    return key, None, False


def _parse_block(lines: list[tuple[int, str]], index: int, indent: int) -> tuple[object, int]:
    if index >= len(lines):
        return {}, index
    if lines[index][0] < indent:
        return {}, index
    is_list = lines[index][1].startswith("- ")
    if is_list:
        items: list[object] = []
        while index < len(lines):
            line_indent, text = lines[index]
            if line_indent < indent:
                break
            if line_indent != indent:
                raise PersonaPackError(f"unexpected list indentation: {text}")
            if not text.startswith("- "):
                break
            rest = text[2:].strip()
            index += 1
            if rest:
                items.append(_parse_scalar(rest))
            else:
                value, index = _parse_block(lines, index, indent + 2)
                items.append(value)
        return items, index

    values: dict[str, object] = {}
    while index < len(lines):
        line_indent, text = lines[index]
        if line_indent < indent:
            break
        if line_indent != indent:
            raise PersonaPackError(f"unexpected mapping indentation: {text}")
        if text.startswith("- "):
            break
        key, value, has_value = _parse_mapping_entry(text)
        index += 1
        if has_value:
            values[key] = value
        else:
            child, index = _parse_block(lines, index, indent + 2)
            values[key] = child
    return values, index


def load_yaml_subset(path: Path) -> dict[str, object]:
    lines = _prepare_yaml_lines(path.read_text(encoding="utf-8"))
    if not lines:
        return {}
    result, index = _parse_block(lines, 0, lines[0][0])
    if index != len(lines):
        raise PersonaPackError(f"unparsed YAML content in {path}")
    if not isinstance(result, dict):
        raise PersonaPackError(f"{path} must contain a mapping at the root")
    return result


def list_text(value: object) -> tuple[str, ...]:
    if not isinstance(value, list):
        return ()
    return tuple(str(item).strip() for item in value if str(item).strip())


def mapping(value: object) -> dict[str, object]:
    return value if isinstance(value, dict) else {}


def int_value(value: object, default: int) -> int:
    try:
        return int(value)
    except (TypeError, ValueError):
        return default


def float_value(value: object, default: float) -> float:
    try:
        return float(value)
    except (TypeError, ValueError):
        return default


def resolve_pack_reference(pack: "PersonaPack", value: object) -> Path | None:
    text = str(value or "").strip()
    if not text:
        return None
    return (pack.root / text).resolve()


@dataclass(frozen=True)
class PersonaPack:
    root: Path
    manifest: dict[str, object]
    character: dict[str, object]
    prompt_template: str
    behavior: dict[str, object]
    expressions: dict[str, object]
    earcons: dict[str, object]
    voice: dict[str, object]

    @property
    def pack_id(self) -> str:
        return str(self.manifest.get("id", "")).strip()

    @property
    def display_name(self) -> str:
        return str(self.character.get("display_name", self.manifest.get("name", self.pack_id))).strip()

    @property
    def speech_style(self) -> dict[str, object]:
        return mapping(self.character.get("speech_style"))

    @property
    def max_chars(self) -> int:
        return min(FOUNDATION_MAX_CHARS, int_value(self.speech_style.get("max_chars"), FOUNDATION_MAX_CHARS))

    @property
    def max_sentences(self) -> int:
        return min(FOUNDATION_MAX_SENTENCES, int_value(self.speech_style.get("max_sentences"), FOUNDATION_MAX_SENTENCES))

    @property
    def avoid_terms(self) -> tuple[str, ...]:
        return tuple(term.lower() for term in list_text(self.speech_style.get("avoid")))

    @property
    def forbidden_terms(self) -> tuple[str, ...]:
        return tuple(dict.fromkeys((*FOUNDATION_FORBIDDEN_TERMS, *list_text(self.character.get("forbidden_terms")))))

    @property
    def memory_denied_terms(self) -> tuple[str, ...]:
        memory = mapping(self.character.get("memory"))
        return tuple(dict.fromkeys((*FOUNDATION_DENIED_MEMORY_TERMS, *list_text(memory.get("denied_terms")))))

    @property
    def memory_prefixes(self) -> tuple[str, ...]:
        memory = mapping(self.character.get("memory"))
        configured = list_text(memory.get("allowed_prefixes"))
        if not configured:
            return FOUNDATION_MEMORY_PREFIXES
        return tuple(prefix for prefix in configured if prefix in FOUNDATION_MEMORY_PREFIXES)

    @property
    def spoken_lines(self) -> dict[str, object]:
        return mapping(self.character.get("spoken_lines"))

    def spoken_line(self, intent: str) -> dict[str, object]:
        return mapping(self.spoken_lines.get(intent))

    @property
    def packaged_prompts(self) -> dict[str, object]:
        return mapping(self.voice.get("packaged_prompts"))

    def packaged_prompt(self, intent: str) -> dict[str, object]:
        return mapping(self.packaged_prompts.get(intent))

    def character_rules(self) -> str:
        rules = list_text(self.character.get("prompt_rules"))
        if not rules:
            return ""
        return "\n".join(f"- {rule}" for rule in rules)

    def bridge_system_prompt(self) -> str:
        return self.render_prompt(memory_lines=("turns_seen: 0",), context_markers=()).split("\n\nCurrent local memory:", 1)[0].strip()

    def render_prompt(self, *, memory_lines: Iterable[str], context_markers: Iterable[str] = ()) -> str:
        memory = "\n".join(f"- {line}" for line in memory_lines) or "- turns_seen: 0"
        markers = "\n".join(f"- {line}" for line in context_markers) or "- none"
        prompt = self.prompt_template
        prompt = prompt.replace("{{character_rules}}", self.character_rules())
        prompt = prompt.replace("{{memory}}", memory)
        prompt = prompt.replace("{{context_markers}}", markers)
        return prompt.strip()


def resolve_pack_path(persona: str | Path | None, root: Path | None = None) -> Path:
    base = root or repo_root()
    if persona is None or str(persona).strip() == "":
        persona = DEFAULT_PERSONA_ID
    path = Path(persona)
    if path.exists():
        return path.resolve()
    if path.suffix:
        return (base / path).resolve()
    return (base / "personas" / str(persona)).resolve()


def load_persona_pack(persona: str | Path | None = None, root: Path | None = None) -> PersonaPack:
    pack_root = resolve_pack_path(persona, root)
    manifest_path = pack_root / "pack.yaml"
    if not manifest_path.exists():
        raise PersonaPackError(f"persona pack manifest not found: {manifest_path}")
    manifest = load_yaml_subset(manifest_path)
    files = mapping(manifest.get("files"))
    def member_path(key: str, fallback: str) -> Path:
        path = (pack_root / str(files.get(key, fallback))).resolve()
        try:
            path.relative_to(pack_root.resolve())
        except ValueError as exc:
            raise PersonaPackError(f"persona pack file escapes pack root: {key}") from exc
        return path

    character_path = member_path("character", "character.yaml")
    prompt_path = member_path("prompt", "prompt.md")
    behavior_path = member_path("behavior", "behavior.yaml")
    expressions_path = member_path("expressions", "expressions.yaml")
    earcons_path = member_path("earcons", "earcons.yaml")
    voice_path = member_path("voice", "voice.yaml")
    for path in (character_path, prompt_path, behavior_path, expressions_path, earcons_path, voice_path):
        if not path.exists():
            raise PersonaPackError(f"persona pack file not found: {path}")
    return PersonaPack(
        root=pack_root,
        manifest=manifest,
        character=load_yaml_subset(character_path),
        prompt_template=prompt_path.read_text(encoding="utf-8"),
        behavior=load_yaml_subset(behavior_path),
        expressions=load_yaml_subset(expressions_path),
        earcons=load_yaml_subset(earcons_path),
        voice=load_yaml_subset(voice_path),
    )


def contains_any(text: str, patterns: Iterable[str]) -> str:
    lowered = text.lower()
    for pattern in patterns:
        if pattern and pattern.lower() in lowered:
            return pattern
    return ""


def validate_pack(pack: PersonaPack) -> list[str]:
    issues: list[str] = []
    if pack.manifest.get("schema") != PACK_SCHEMA:
        issues.append("pack_schema_invalid")
    if pack.character.get("schema") != CHARACTER_SCHEMA:
        issues.append("character_schema_invalid")
    if pack.behavior.get("schema") != BEHAVIOR_SCHEMA:
        issues.append("behavior_schema_invalid")
    if not pack.pack_id:
        issues.append("pack_id_missing")
    elif not re.fullmatch(PERSONA_ID_PATTERN, pack.pack_id):
        issues.append("pack_id_invalid")
    for field in ("name", "version", "author", "license", "description"):
        if not str(pack.manifest.get(field, "")).strip():
            issues.append(f"pack_{field}_missing")
    files = mapping(pack.manifest.get("files"))
    for key in REQUIRED_PACK_FILES:
        if key not in files:
            issues.append(f"pack_file_missing:{key}")
    if "{{character_rules}}" not in pack.prompt_template:
        issues.append("prompt_missing_character_rules_slot")
    if "{{memory}}" not in pack.prompt_template:
        issues.append("prompt_missing_memory_slot")
    if "{{context_markers}}" not in pack.prompt_template:
        issues.append("prompt_missing_context_markers_slot")
    configured_max_chars = int_value(pack.speech_style.get("max_chars"), FOUNDATION_MAX_CHARS)
    configured_max_sentences = int_value(pack.speech_style.get("max_sentences"), FOUNDATION_MAX_SENTENCES)
    if configured_max_chars > FOUNDATION_MAX_CHARS:
        issues.append("max_chars_loosened")
    if configured_max_sentences > FOUNDATION_MAX_SENTENCES:
        issues.append("max_sentences_loosened")
    if str(pack.speech_style.get("contractions", "")).lower() != "forbidden":
        issues.append("contractions_not_forbidden")
    configured_prefixes = set(list_text(mapping(pack.character.get("memory")).get("allowed_prefixes")))
    if configured_prefixes - set(FOUNDATION_MEMORY_PREFIXES):
        issues.append("memory_prefixes_loosened")
    for term in FOUNDATION_DENIED_MEMORY_TERMS:
        if term not in pack.memory_denied_terms:
            issues.append(f"memory_denied_term_missing:{term}")
    for intent in REQUIRED_SPOKEN_LINES:
        line = pack.spoken_line(intent)
        if not line:
            issues.append(f"spoken_line_missing:{intent}")
            continue
        text = str(line.get("text", "")).strip()
        if not text:
            issues.append(f"spoken_line_text_missing:{intent}")
        if len(text) > pack.max_chars:
            issues.append(f"spoken_line_too_long:{intent}")
        if contains_any(text, pack.forbidden_terms):
            issues.append(f"spoken_line_forbidden_term:{intent}")
        earcon = str(line.get("earcon", "none")).lower()
        if earcon not in FOUNDATION_ALLOWED_EARCONS:
            issues.append(f"spoken_line_bad_earcon:{intent}")
    safety = pack.spoken_line("safety")
    if safety and str(safety.get("earcon", "")).lower() != "safety":
        issues.append("safety_line_must_use_safety_earcon")
    rendered_prompt = pack.render_prompt(memory_lines=("turns_seen: 0",))
    if contains_any(rendered_prompt, FOUNDATION_FORBIDDEN_TERMS):
        issues.append("prompt_contains_clone_marker")
    if "Reply only as JSON" not in rendered_prompt:
        issues.append("prompt_missing_json_contract")

    idle_life = mapping(pack.behavior.get("idle_life"))
    circadian = mapping(pack.behavior.get("circadian"))
    emotion_response = mapping(pack.behavior.get("emotion_response"))
    for key in ("breathing_hz", "breathing_px", "fidget_min_ms", "fidget_max_ms", "reduced_motion_scale"):
        if key not in idle_life:
            issues.append(f"behavior_idle_life_missing:{key}")
    breathing_hz = float_value(idle_life.get("breathing_hz"), -1.0)
    if not 0.05 <= breathing_hz <= 0.50:
        issues.append("behavior_idle_life_breathing_hz_out_of_range")
    breathing_px = float_value(idle_life.get("breathing_px"), -1.0)
    if not 0.20 <= breathing_px <= 4.00:
        issues.append("behavior_idle_life_breathing_px_out_of_range")
    fidget_min = int_value(idle_life.get("fidget_min_ms"), -1)
    fidget_max = int_value(idle_life.get("fidget_max_ms"), -1)
    if fidget_min < 1000 or fidget_max < 1000 or fidget_max < fidget_min:
        issues.append("behavior_idle_life_fidget_range_invalid")
    reduced_motion_scale = float_value(idle_life.get("reduced_motion_scale"), -1.0)
    if not 0.05 <= reduced_motion_scale <= 1.00:
        issues.append("behavior_idle_life_reduced_motion_scale_out_of_range")

    for key in ("evening_start_hour", "night_start_hour", "morning_start_hour", "morning_end_hour"):
        if key not in circadian:
            issues.append(f"behavior_circadian_missing:{key}")
    evening = int_value(circadian.get("evening_start_hour"), -1)
    night = int_value(circadian.get("night_start_hour"), -1)
    morning_start = int_value(circadian.get("morning_start_hour"), -1)
    morning_end = int_value(circadian.get("morning_end_hour"), -1)
    if not (0 <= morning_start < morning_end <= evening <= night <= 23):
        issues.append("behavior_circadian_window_order_invalid")

    for key in ("curiosity_arousal_delta", "safety_valence_delta", "happy_valence_delta"):
        if key not in emotion_response:
            issues.append(f"behavior_emotion_response_missing:{key}")
    curiosity = float_value(emotion_response.get("curiosity_arousal_delta"), -1.0)
    safety = float_value(emotion_response.get("safety_valence_delta"), 1.0)
    happy = float_value(emotion_response.get("happy_valence_delta"), -1.0)
    if not 0.00 <= curiosity <= 0.50:
        issues.append("behavior_emotion_response_curiosity_out_of_range")
    if not -1.00 <= safety <= 0.00:
        issues.append("behavior_emotion_response_safety_out_of_range")
    if not 0.00 <= happy <= 0.80:
        issues.append("behavior_emotion_response_happy_out_of_range")

    expressions = mapping(pack.expressions)
    for section in ("neutral", "listen", "think", "drowsy", "yawn"):
        if not mapping(expressions.get(section)):
            issues.append(f"expressions_section_missing:{section}")

    def check_expression_float(section: str, key: str, minimum: float, maximum: float) -> None:
        spec = mapping(expressions.get(section))
        if key not in spec:
            issues.append(f"expressions_{section}_missing:{key}")
            return
        value = float_value(spec.get(key), minimum - 1.0)
        if not minimum <= value <= maximum:
            issues.append(f"expressions_{section}_out_of_range:{key}")

    for key in ("eye_open", "eye_smile", "mouth_smile"):
        check_expression_float("neutral", key, -1.0 if key == "mouth_smile" else 0.0, 1.2 if key == "eye_open" else 1.0)
    check_expression_float("listen", "focus", 0.0, 1.0)
    check_expression_float("listen", "pitch_bias_deg", -20.0, 20.0)
    check_expression_float("think", "pupil_y", -1.0, 1.0)
    check_expression_float("think", "yaw_bias_deg", -45.0, 45.0)
    drowsy_ranges = {
        "eye_open": (0.0, 1.2),
        "squint": (0.0, 1.0),
        "brow_tilt": (-1.0, 1.0),
        "mouth_smile": (-1.0, 1.0),
        "face_y": (-12.0, 12.0),
    }
    for key, (minimum, maximum) in drowsy_ranges.items():
        check_expression_float("drowsy", key, minimum, maximum)
    for key in ("duration_ms", "eye_open_delta", "squint_delta", "mouth_open", "mouth_smile_delta", "pitch_bias_deg"):
        if key == "duration_ms":
            spec = mapping(expressions.get("yawn"))
            duration = int_value(spec.get(key), -1)
            if not 200 <= duration <= 4000:
                issues.append("expressions_yawn_out_of_range:duration_ms")
        elif key in ("eye_open_delta", "mouth_smile_delta"):
            check_expression_float("yawn", key, -1.0, 0.0)
        elif key == "pitch_bias_deg":
            check_expression_float("yawn", key, -10.0, 10.0)
        else:
            check_expression_float("yawn", key, 0.0, 1.0)

    prompts = pack.packaged_prompts
    has_packaged_prompt_assets = any(bool(mapping(prompts.get(intent))) for intent in FOUNDATION_SPEECH_INTENTS)
    provenance = mapping(pack.manifest.get("provenance"))
    voice_policy_path = resolve_pack_reference(pack, provenance.get("voice_policy"))
    if has_packaged_prompt_assets and voice_policy_path is None:
        issues.append("voice_provenance_policy_missing")
    voice_policy: dict[str, object] = {}
    if voice_policy_path is not None:
        if not voice_policy_path.is_file():
            issues.append("voice_provenance_policy_file_missing")
        else:
            try:
                voice_policy = load_yaml_subset(voice_policy_path)
            except PersonaPackError:
                issues.append("voice_provenance_policy_invalid")
    if voice_policy:
        if voice_policy.get("schema") != VOICE_PROVENANCE_SCHEMA:
            issues.append("voice_provenance_schema_invalid")
        forbidden_attested = set(list_text(voice_policy.get("forbidden_sources_attested")))
        for term in VOICE_PROVENANCE_FORBIDDEN_ATTESTATIONS:
            if term not in forbidden_attested:
                issues.append(f"voice_provenance_forbidden_attestation_missing:{term}")
        rollout_evidence = set(list_text(voice_policy.get("required_rollout_evidence")))
        for evidence in VOICE_PROVENANCE_REQUIRED_EVIDENCE:
            if evidence not in rollout_evidence:
                issues.append(f"voice_provenance_rollout_evidence_missing:{evidence}")
        rollout_gate = str(voice_policy.get("rollout_gate", "")).strip()
        if not rollout_gate:
            issues.append("voice_provenance_rollout_gate_missing")
    for intent in FOUNDATION_SPEECH_INTENTS:
        prompt = mapping(prompts.get(intent))
        if not prompt:
            issues.append(f"voice_packaged_prompt_missing:{intent}")
            continue
        for field in ("prompt_id", "transcript", "wav_path", "source_path", "sidecar_path"):
            value = str(prompt.get(field, "")).strip()
            if not value:
                issues.append(f"voice_packaged_prompt_field_missing:{intent}:{field}")
        prompt_id = str(prompt.get("prompt_id", "")).strip()
        if prompt_id and not re.fullmatch(r"[a-z0-9_]+", prompt_id):
            issues.append(f"voice_packaged_prompt_bad_id:{intent}")
        wav_path = str(prompt.get("wav_path", "")).replace("\\", "/")
        sidecar_path = str(prompt.get("sidecar_path", "")).replace("\\", "/")
        if wav_path and not wav_path.startswith("media/voice/"):
            issues.append(f"voice_packaged_prompt_bad_wav_path:{intent}")
        if sidecar_path and not sidecar_path.startswith("media/voice/sidecars/"):
            issues.append(f"voice_packaged_prompt_bad_sidecar_path:{intent}")
        source_path = str(prompt.get("source_path", "")).replace("\\", "/")
        if source_path and not (repo_root() / source_path).is_file():
            issues.append(f"voice_packaged_prompt_source_missing:{intent}")
    return issues


def persona_pack_sha256(pack_root: Path) -> str:
    root = pack_root.resolve()
    digest = hashlib.sha256()
    for path in sorted((item for item in root.rglob("*") if item.is_file()), key=lambda item: item.as_posix()):
        resolved = path.resolve()
        try:
            relative = resolved.relative_to(root).as_posix()
        except ValueError as exc:
            raise PersonaPackError(f"persona pack asset escapes pack root: {path}") from exc
        digest.update(relative.encode("utf-8"))
        digest.update(b"\0")
        digest.update(resolved.read_bytes())
        digest.update(b"\0")
    return digest.hexdigest()


def build_persona_index(root: Path | None = None) -> dict[str, object]:
    base = (root or repo_root()).resolve()
    personas_root = (base / "personas").resolve()
    entries: list[dict[str, object]] = []
    if personas_root.is_dir():
        for candidate in sorted(personas_root.iterdir(), key=lambda item: item.name.casefold()):
            if not candidate.is_dir() or candidate.is_symlink() or not (candidate / "pack.yaml").is_file():
                continue
            relative_path = candidate.relative_to(base).as_posix()
            try:
                pack = load_persona_pack(candidate, root=base)
                issues = validate_pack(pack)
                if pack.pack_id != candidate.name:
                    issues.append("pack_id_directory_mismatch")
                entry: dict[str, object] = {
                    "id": pack.pack_id or candidate.name,
                    "name": str(pack.manifest.get("name", pack.display_name)).strip(),
                    "version": str(pack.manifest.get("version", "")).strip(),
                    "author": str(pack.manifest.get("author", "")).strip(),
                    "license": str(pack.manifest.get("license", "")).strip(),
                    "description": str(pack.manifest.get("description", "")).strip(),
                    "path": relative_path,
                    "sha256": persona_pack_sha256(candidate),
                    "valid": not issues,
                    "issues": sorted(set(issues)),
                    "capabilities": {
                        "bridge_load_time": True,
                        "firmware_build_time": True,
                        "runtime_hot_swap": False,
                    },
                }
            except (OSError, PersonaPackError) as exc:
                entry = {
                    "id": candidate.name,
                    "name": candidate.name,
                    "version": "",
                    "author": "",
                    "license": "",
                    "description": "",
                    "path": relative_path,
                    "sha256": "",
                    "valid": False,
                    "issues": [str(exc)],
                    "capabilities": {
                        "bridge_load_time": False,
                        "firmware_build_time": False,
                        "runtime_hot_swap": False,
                    },
                }
            entries.append(entry)

    entries.sort(key=lambda entry: str(entry["id"]))
    return {
        "schema": PACK_INDEX_SCHEMA,
        "pack_count": len(entries),
        "valid_count": sum(1 for entry in entries if entry["valid"]),
        "invalid_count": sum(1 for entry in entries if not entry["valid"]),
        "packs": entries,
    }


def load_and_validate_persona_pack(persona: str | Path | None = None, root: Path | None = None) -> PersonaPack:
    pack = load_persona_pack(persona, root)
    issues = validate_pack(pack)
    if issues:
        raise PersonaPackError("; ".join(issues))
    return pack


def build_arg_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description="Validate a Stackchan persona pack.")
    parser.add_argument("persona", nargs="?", default=DEFAULT_PERSONA_ID, help="Pack id or path. Defaults to spark.")
    parser.add_argument("--json", action="store_true", help="Emit machine-readable validation output.")
    parser.add_argument("--index", action="store_true", help="Emit the deterministic installed persona index.")
    return parser


def main() -> int:
    args = build_arg_parser().parse_args()
    if args.index:
        payload = build_persona_index()
        print(json.dumps(payload, indent=2, sort_keys=True))
        return 0 if payload["invalid_count"] == 0 else 1
    try:
        pack = load_persona_pack(args.persona)
        issues = validate_pack(pack)
    except PersonaPackError as exc:
        payload = {"ok": False, "issues": [str(exc)], "persona": args.persona}
        if args.json:
            print(json.dumps(payload, indent=2, sort_keys=True))
        else:
            print(f"Persona pack invalid: {exc}")
        return 1
    payload = {
        "ok": not issues,
        "issues": issues,
        "persona": pack.pack_id,
        "display_name": pack.display_name,
        "path": str(pack.root),
    }
    if args.json:
        print(json.dumps(payload, indent=2, sort_keys=True))
    elif issues:
        print(f"Persona pack {pack.pack_id} invalid:")
        for issue in issues:
            print(f"- {issue}")
    else:
        print(f"Persona pack {pack.pack_id} valid: {pack.display_name}")
    return 0 if not issues else 1


if __name__ == "__main__":
    raise SystemExit(main())
