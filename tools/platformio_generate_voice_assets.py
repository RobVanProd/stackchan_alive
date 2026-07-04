from pathlib import Path
import os
import re
import sys

Import("env")


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


def _selected_persona():
    project_option = ""
    if hasattr(env, "GetProjectOption"):
        project_option = str(env.GetProjectOption("custom_persona", "") or "").strip()
    return (
        project_option
        or os.environ.get("STACKCHAN_PERSONA", "").strip()
        or _persona_from_defines()
        or "spark"
    )


def _asset_symbol(name):
    cleaned = re.sub(r"[^A-Za-z0-9]+", "_", name).strip("_")
    return "k" + "".join(part.capitalize() for part in cleaned.split("_")) + "Wav"


def _format_bytes(data):
    lines = []
    for offset in range(0, len(data), 16):
        chunk = data[offset : offset + 16]
        lines.append("    " + ", ".join(f"0x{value:02x}" for value in chunk) + ",")
    return "\n".join(lines)


project_dir = Path(env["PROJECT_DIR"])
sys.path.insert(0, str(project_dir / "bridge"))
from persona_pack import FOUNDATION_SPEECH_INTENTS, load_and_validate_persona_pack, mapping  # noqa: E402

pack = load_and_validate_persona_pack(_selected_persona(), root=project_dir)
build_dir = Path(env.subst("$BUILD_DIR"))
generated_dir = build_dir / "generated"
generated_dir.mkdir(parents=True, exist_ok=True)
header_path = generated_dir / "FirmwareVoiceAssets.hpp"

packaged_prompts = mapping(pack.voice.get("packaged_prompts"))
asset_sources = []
seen_runtime_paths = {}
for intent in FOUNDATION_SPEECH_INTENTS:
    prompt = mapping(packaged_prompts.get(intent))
    runtime_path = str(prompt.get("wav_path", "")).strip().replace("\\", "/")
    source_relative_path = str(prompt.get("source_path", "")).strip().replace("\\", "/")
    if not runtime_path or not source_relative_path:
        raise RuntimeError(f"Missing packaged prompt WAV paths for {pack.pack_id}:{intent}")
    previous_source = seen_runtime_paths.get(runtime_path)
    if previous_source is not None and previous_source != source_relative_path:
        raise RuntimeError(f"Conflicting source paths for packaged prompt WAV {runtime_path}")
    if previous_source is None:
        seen_runtime_paths[runtime_path] = source_relative_path
        asset_sources.append((Path(runtime_path).stem, runtime_path, source_relative_path))

parts = [
    "#pragma once",
    "",
    "#include <stddef.h>",
    "#include <stdint.h>",
    "#include <string.h>",
    "",
    "namespace stackchan {",
    "namespace firmware_voice {",
    "",
    f"static constexpr const char* kFirmwareVoiceAssetsPersonaId = {_cpp_string(pack.pack_id)};",
    "",
    "struct FirmwareVoiceAsset {",
    "  const char* path;",
    "  const uint8_t* data;",
    "  size_t size;",
    "};",
    "",
]

entries = []
for name, runtime_path, source_relative_path in asset_sources:
    source_path = project_dir / source_relative_path
    if not source_path.exists():
        raise RuntimeError(f"Missing firmware voice asset for {pack.pack_id}: {source_path}")
    data = source_path.read_bytes()
    symbol = _asset_symbol(name)
    parts.extend(
        [
            f"alignas(4) static const uint8_t {symbol}[] = {{",
            _format_bytes(data),
            "};",
            "",
        ]
    )
    entries.append((runtime_path.replace("\\", "/"), symbol))

parts.append("static const FirmwareVoiceAsset kAssets[] = {")
for relative_path, symbol in entries:
    parts.append(f'    {{"{relative_path}", {symbol}, sizeof({symbol})}},')
parts.extend(
    [
        "};",
        "",
        "inline const FirmwareVoiceAsset* find(const char* path) {",
        "  if (path == nullptr) {",
        "    return nullptr;",
        "  }",
        "  for (const FirmwareVoiceAsset& asset : kAssets) {",
        "    if (strcmp(path, asset.path) == 0) {",
        "      return &asset;",
        "    }",
        "  }",
        "  return nullptr;",
        "}",
        "",
        "}  // namespace firmware_voice",
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
