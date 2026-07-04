#!/usr/bin/env python3
"""Create a new Stackchan persona pack from an existing template pack."""

from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[1]
BRIDGE_DIR = REPO_ROOT / "bridge"
sys.path.insert(0, str(BRIDGE_DIR))

from persona_pack import DEFAULT_PERSONA_ID, PersonaPackError, scaffold_persona_pack  # noqa: E402


def build_arg_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description="Create a Stackchan persona pack by copying a template pack.")
    parser.add_argument("pack_id", help="New pack id, such as nova or workshop-bot.")
    parser.add_argument("--name", default="", help="Display name. Defaults to Stackchan <Title Case Id>.")
    parser.add_argument("--author", default="", help="Author name written to pack.yaml. Defaults to TODO.")
    parser.add_argument("--from-persona", default=DEFAULT_PERSONA_ID, help="Template pack id or path. Defaults to spark.")
    parser.add_argument("--json", action="store_true", help="Emit machine-readable output.")
    return parser


def _next_steps(pack_id: str) -> list[str]:
    return [
        f"Edit personas/{pack_id}/character.yaml and personas/{pack_id}/prompt.md.",
        f"Run tools/verify_persona_pack.cmd {pack_id} --Json.",
        f"Run tools/run_character_red_team.cmd -Persona {pack_id} -Json.",
        f"Build with STACKCHAN_PERSONA={pack_id}.",
    ]


def main() -> int:
    args = build_arg_parser().parse_args()
    try:
        pack = scaffold_persona_pack(
            args.pack_id,
            display_name=args.name or None,
            author=args.author or None,
            source_persona=args.from_persona,
            root=REPO_ROOT,
        )
    except PersonaPackError as exc:
        payload = {"ok": False, "issues": [str(exc)], "requested_id": args.pack_id}
        if args.json:
            print(json.dumps(payload, indent=2, sort_keys=True))
        else:
            print(f"Persona pack creation failed: {exc}")
        return 1

    payload = {
        "ok": True,
        "persona": pack.pack_id,
        "display_name": pack.display_name,
        "path": str(pack.root),
        "next_steps": _next_steps(pack.pack_id),
    }
    if args.json:
        print(json.dumps(payload, indent=2, sort_keys=True))
    else:
        print(f"Created persona pack {pack.pack_id}: {pack.display_name}")
        print(f"Path: {pack.root}")
        print("Next steps:")
        for step in payload["next_steps"]:
            print(f"- {step}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
