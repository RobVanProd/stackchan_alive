#!/usr/bin/env python3
"""Export packaged prompt WAV and sidecar metadata for a persona pack."""

from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[1]
BRIDGE_DIR = REPO_ROOT / "bridge"
sys.path.insert(0, str(BRIDGE_DIR))

from persona_pack import (  # noqa: E402
    DEFAULT_PERSONA_ID,
    PersonaPackError,
    load_and_validate_persona_pack,
    packaged_prompt_asset_manifest,
)


def build_arg_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description="Export persona packaged prompt asset metadata.")
    parser.add_argument("--persona", default=DEFAULT_PERSONA_ID, help="Pack id or path. Defaults to spark.")
    parser.add_argument("--out", default="", help="Optional JSON output path.")
    return parser


def main() -> int:
    args = build_arg_parser().parse_args()
    try:
        pack = load_and_validate_persona_pack(args.persona, root=REPO_ROOT)
        payload = packaged_prompt_asset_manifest(pack)
    except PersonaPackError as exc:
        print(json.dumps({"ok": False, "issues": [str(exc)], "persona": args.persona}, indent=2, sort_keys=True))
        return 1

    text = json.dumps(payload, indent=2, sort_keys=True)
    if args.out:
        output_path = Path(args.out)
        output_path.parent.mkdir(parents=True, exist_ok=True)
        output_path.write_text(text + "\n", encoding="utf-8")
    print(text)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
