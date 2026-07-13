#!/usr/bin/env python3
"""Conservative normalization shared by trusted transcript-owned routes."""

from __future__ import annotations

import re


_APOSTROPHE_TRANSLATION = str.maketrans(
    {
        "\u2018": "'",
        "\u2019": "'",
        "\u02bc": "'",
        "\uff07": "'",
    }
)
_LEADING_DISCOURSE_RE = re.compile(r"^(?:(?:well|so|like|um+|uh+)[,.:;!? ]+)+", re.IGNORECASE)
_STACKCHAN_ADDRESS_RE = re.compile(
    r"^(?:(?:hey|hi|hello|okay|ok|yo)\s+)?"
    r"stack\s*[- ]?\s*chan(?:\s+alive)?\b[,.:;!? -]*",
    re.IGNORECASE,
)


def normalize_user_utterance(value: object) -> str:
    """Normalize punctuation and remove only a leading Stackchan address/filler."""

    clean = " ".join(str(value or "").translate(_APOSTROPHE_TRANSLATION).strip().split())
    if not clean:
        return ""
    clean = _LEADING_DISCOURSE_RE.sub("", clean).strip()
    clean = _STACKCHAN_ADDRESS_RE.sub("", clean).strip()
    clean = _LEADING_DISCOURSE_RE.sub("", clean).strip()
    return clean
