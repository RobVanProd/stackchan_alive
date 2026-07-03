from pathlib import Path

Import("env")


ASSETS = (
    (
        "stackchan_spark_greeting",
        "media/voice/stackchan_spark_greeting.wav",
        "docs/media/voice/stackchan_spark_greeting.wav",
    ),
    (
        "stackchan_spark_thinking",
        "media/voice/stackchan_spark_thinking.wav",
        "docs/media/voice/stackchan_spark_thinking.wav",
    ),
    (
        "stackchan_spark_safety",
        "media/voice/stackchan_spark_safety.wav",
        "docs/media/voice/stackchan_spark_safety.wav",
    ),
)


def _asset_symbol(name):
    return "k" + "".join(part.capitalize() for part in name.split("_")) + "Wav"


def _format_bytes(data):
    lines = []
    for offset in range(0, len(data), 16):
        chunk = data[offset : offset + 16]
        lines.append("    " + ", ".join(f"0x{value:02x}" for value in chunk) + ",")
    return "\n".join(lines)


project_dir = Path(env["PROJECT_DIR"])
build_dir = Path(env.subst("$BUILD_DIR"))
generated_dir = build_dir / "generated"
generated_dir.mkdir(parents=True, exist_ok=True)
header_path = generated_dir / "FirmwareVoiceAssets.hpp"

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
    "struct FirmwareVoiceAsset {",
    "  const char* path;",
    "  const uint8_t* data;",
    "  size_t size;",
    "};",
    "",
]

entries = []
for name, runtime_path, source_relative_path in ASSETS:
    source_path = project_dir / source_relative_path
    if not source_path.exists():
        raise RuntimeError(f"Missing firmware voice asset: {source_path}")
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
