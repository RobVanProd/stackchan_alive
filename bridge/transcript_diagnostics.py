#!/usr/bin/env python3
"""Privacy-safe metrics for a supervised, known-utterance STT check."""

from __future__ import annotations

import hashlib
import re
import unicodedata
from collections import Counter


_WORD_RE = re.compile(r"[^\W_]+(?:['\u2019][^\W_]+)?", re.UNICODE)


def normalized_tokens(text: object) -> tuple[str, ...]:
    normalized = unicodedata.normalize("NFKC", str(text or "")).casefold()
    return tuple(match.group(0).replace("\u2019", "'") for match in _WORD_RE.finditer(normalized))


def validate_expected_text(expected_text: str) -> str:
    expected_text = str(expected_text)
    if not expected_text.strip() or len(expected_text) > 500 or not normalized_tokens(expected_text):
        raise ValueError("expected diagnostic utterance must contain 1 to 500 characters and a word")
    return expected_text


def word_edit_distance(expected: tuple[str, ...], recognized: tuple[str, ...]) -> int:
    previous = list(range(len(recognized) + 1))
    for expected_index, expected_token in enumerate(expected, start=1):
        current = [expected_index]
        for recognized_index, recognized_token in enumerate(recognized, start=1):
            current.append(
                min(
                    current[-1] + 1,
                    previous[recognized_index] + 1,
                    previous[recognized_index - 1]
                    + (expected_token != recognized_token),
                )
            )
        previous = current
    return previous[-1]


def validate_critical_tokens(
    expected_text: str,
    critical_tokens: tuple[str, ...],
) -> tuple[str, ...]:
    expected = set(normalized_tokens(expected_text))
    normalized: list[str] = []
    for raw_token in critical_tokens:
        tokens = normalized_tokens(raw_token)
        if len(tokens) != 1:
            raise ValueError("each critical expected token must normalize to exactly one token")
        token = tokens[0]
        if token not in expected:
            raise ValueError("each critical expected token must occur in the expected utterance")
        if token not in normalized:
            normalized.append(token)
    return tuple(normalized)


def expected_transcript_metrics(
    expected_text: str,
    recognized_text: str,
    *,
    critical_tokens: tuple[str, ...] = (),
) -> dict[str, object]:
    """Return comparison metrics without returning either input or any token text."""

    expected_text = validate_expected_text(expected_text)
    recognized_text = str(recognized_text)
    expected = normalized_tokens(expected_text)
    recognized = normalized_tokens(recognized_text)
    critical = validate_critical_tokens(expected_text, critical_tokens)
    distance = word_edit_distance(expected, recognized)
    recognized_counts = Counter(recognized)
    critical_counts = Counter(critical)
    critical_hits = sum(
        min(count, recognized_counts[token])
        for token, count in critical_counts.items()
    )
    critical_count = len(critical)
    return {
        "stt_expected_diagnostic": True,
        "stt_expected_sha256": hashlib.sha256(expected_text.encode("utf-8")).hexdigest(),
        "stt_expected_exact_match": recognized_text == expected_text,
        "stt_expected_normalized_match": recognized == expected,
        "stt_expected_token_count": len(expected),
        "stt_recognized_token_count": len(recognized),
        "stt_word_edit_distance": distance,
        "stt_word_error_rate": round(distance / len(expected), 4),
        "stt_critical_expected_token_count": critical_count,
        "stt_critical_expected_token_hits": critical_hits,
        "stt_critical_expected_token_coverage": (
            round(critical_hits / critical_count, 4) if critical_count else None
        ),
    }
