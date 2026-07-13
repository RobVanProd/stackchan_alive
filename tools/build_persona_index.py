#!/usr/bin/env python3
"""Build or verify the deterministic installed Stackchan persona index."""

from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(REPO_ROOT / "bridge"))

from persona_pack import build_persona_index  # noqa: E402


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--root", type=Path, default=REPO_ROOT, help="Repository root.")
    parser.add_argument(
        "--output",
        type=Path,
        default=REPO_ROOT / "data" / "persona_index.json",
        help="Index output path.",
    )
    parser.add_argument("--check", action="store_true", help="Verify output is current without writing.")
    parser.add_argument("--json", action="store_true", help="Print the generated index JSON.")
    args = parser.parse_args()

    payload = build_persona_index(args.root.resolve())
    rendered = json.dumps(payload, indent=2, sort_keys=True) + "\n"
    output = args.output.resolve()
    if args.check:
        if not output.is_file() or output.read_text(encoding="utf-8") != rendered:
            print(f"Persona index is stale or missing: {output}", file=sys.stderr)
            return 1
    else:
        output.parent.mkdir(parents=True, exist_ok=True)
        output.write_text(rendered, encoding="utf-8", newline="\n")

    if args.json:
        print(rendered, end="")
    else:
        action = "verified" if args.check else "wrote"
        print(
            f"Persona index {action}: {output} "
            f"({payload['valid_count']} valid, {payload['invalid_count']} invalid)"
        )
    return 0 if payload["invalid_count"] == 0 else 1


if __name__ == "__main__":
    raise SystemExit(main())
