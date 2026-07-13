"""Normalized per-turn latency evidence for Stackchan's local conversation path."""

from __future__ import annotations

from typing import Mapping


def _number(values: Mapping[str, object], key: str) -> float | None:
    try:
        value = float(values[key])
    except (KeyError, TypeError, ValueError):
        return None
    return max(0.0, value)


def build_conversation_latency_record(
    *,
    audio_summary: Mapping[str, object],
    stt_summary: Mapping[str, object],
    brain_summary: Mapping[str, object],
    tts_summary: Mapping[str, object],
    response_text_ready_ms: float,
    turn_total_ms: float,
    host_reaction_ms: float | None = None,
) -> dict[str, object]:
    """Return flat, JSON-safe stage timings and acceptance outcomes."""

    result: dict[str, object] = {"latency_schema": "stackchan.conversation-latency.v1"}
    capture_ms = _number(audio_summary, "audio_capture_elapsed_ms")
    stt_ms = _number(stt_summary, "stt_elapsed_ms")
    runner_ms = _number(brain_summary, "runner_elapsed_ms") or 0.0
    research_runner_ms = _number(brain_summary, "research_runner_elapsed_ms") or 0.0
    first_audio_ms = _number(tts_summary, "tts_first_audio_ms")
    render_ms = _number(tts_summary, "tts_elapsed_ms")
    audio_duration_ms = _number(tts_summary, "tts_duration_ms")
    payload_bytes = _number(tts_summary, "tts_audio_payload_bytes") or 0.0

    if capture_ms is not None:
        result["latency_capture_ms"] = round(capture_ms, 2)
    if stt_ms is not None:
        result["latency_stt_ms"] = round(stt_ms, 2)
    result["latency_brain_ms"] = round(runner_ms + research_runner_ms, 2)
    result["latency_text_ready_ms"] = round(max(0.0, response_text_ready_ms), 2)
    result["latency_turn_total_ms"] = round(max(0.0, turn_total_ms), 2)
    if host_reaction_ms is not None:
        reaction_ms = max(0.0, float(host_reaction_ms))
        result["latency_host_reaction_ms"] = round(reaction_ms, 2)
        result["latency_gate_host_reaction_under_300"] = reaction_ms < 300.0

    if first_audio_ms is not None and payload_bytes > 0:
        result["latency_first_audio_ms"] = round(first_audio_ms, 2)
        result["latency_gate_first_audio_under_3000"] = first_audio_ms < 3000.0
    if render_ms is not None:
        result["latency_tts_render_ms"] = round(render_ms, 2)
    if audio_duration_ms is not None:
        result["latency_tts_audio_duration_ms"] = round(audio_duration_ms, 2)
    if render_ms is not None and audio_duration_ms is not None and audio_duration_ms > 0:
        real_time_factor = render_ms / audio_duration_ms
        result["latency_tts_render_rtf"] = round(real_time_factor, 4)
        result["latency_gate_render_faster_than_realtime"] = real_time_factor < 1.0

    if payload_bytes > 0:
        truncated = bool(tts_summary.get("tts_audio_truncated", False))
        stream_complete = bool(tts_summary.get("tts_stream_complete", True))
        result["latency_gate_zero_truncation"] = not truncated and stream_complete
    return result
