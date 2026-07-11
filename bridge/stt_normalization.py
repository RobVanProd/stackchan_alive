#!/usr/bin/env python3
"""Shared transcript cleanup helpers for Stackchan STT adapters."""

from __future__ import annotations

import os
import re

NORMALIZE_ENV = "STACKCHAN_STT_NORMALIZE"

STACKCHAN_NAME_VARIANTS = re.compile(
    r"\bstack[\s-]*(?:chan|chin|chain|can|chad|shan|shen|shed)\b",
    flags=re.IGNORECASE,
)


def normalize_stackchan_terms(transcript: str) -> str:
    text = " ".join(str(transcript).split())[:500]
    if not text:
        return ""
    if os.environ.get(NORMALIZE_ENV, "1").strip().lower() in {"0", "false", "off", "no"}:
        return text
    return STACKCHAN_NAME_VARIANTS.sub("Stackchan", text)
