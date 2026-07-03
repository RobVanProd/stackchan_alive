#!/usr/bin/env python3
"""Validate a Stackchan persona pack from the tools directory."""

from __future__ import annotations

import sys
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[1]
BRIDGE_DIR = REPO_ROOT / "bridge"
sys.path.insert(0, str(BRIDGE_DIR))

from persona_pack import main  # noqa: E402


if __name__ == "__main__":
    raise SystemExit(main())
