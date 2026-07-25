#!/usr/bin/env python3
"""Check supervised Conversation v2, initiative, and room-awareness evidence."""

from __future__ import annotations

import argparse
from datetime import datetime
import json
from pathlib import Path

try:
    from .conversation_latency_report import summarize_latency_records
except ImportError:
    from conversation_latency_report import summarize_latency_records


OPERATOR_GATES = (
    ("oneWakeMultiTurn", "operator-one-wake-multi-turn"),
    ("echoFree", "operator-echo-free"),
    ("exitPhraseClosed", "operator-exit-phrase"),
    ("silenceClosed", "operator-silence-close"),
    ("bargeInStoppedAudio", "operator-physical-barge-in"),
    ("bridgeLossLocalRecovery", "operator-bridge-loss-recovery"),
    ("cleanCompleteAudio", "operator-clean-complete-audio"),
    ("initiativeNatural", "operator-initiative-natural"),
    ("initiativeRateFloor", "operator-initiative-rate-floor"),
    ("initiativeIgnoredBackoff", "operator-initiative-backoff"),
    ("initiativeNightSuppressed", "operator-initiative-night"),
    ("roomContextGrounded", "operator-room-grounding"),
    ("roomOffCleared", "operator-room-off-clear"),
    ("noFramePersisted", "operator-no-frame-persistence"),
)
FRAME_SUFFIXES = {".pgm", ".png", ".jpg", ".jpeg", ".webp", ".bmp"}


def _load_json(path: Path) -> dict[str, object] | None:
    if not path.is_file():
        return None
    try:
        value = json.loads(path.read_text(encoding="utf-8-sig"))
    except (OSError, UnicodeError, json.JSONDecodeError):
        return None
    return value if isinstance(value, dict) else None


def _load_jsonl(path: Path) -> list[dict[str, object]]:
    records: list[dict[str, object]] = []
    if not path.is_file():
        return records
    with path.open("r", encoding="utf-8-sig") as handle:
        for line in handle:
            try:
                value = json.loads(line)
            except json.JSONDecodeError:
                continue
            if isinstance(value, dict):
                records.append(value)
    return records


def _integer(value: object, default: int = 0) -> int:
    try:
        return int(value)
    except (TypeError, ValueError):
        return default


def _delta(before: dict[str, object], after: dict[str, object], key: str) -> int:
    return _integer(after.get(key)) - _integer(before.get(key))


def _timestamp(value: object) -> datetime | None:
    try:
        return datetime.fromisoformat(str(value).replace("Z", "+00:00"))
    except ValueError:
        return None


def _nested(root: dict[str, object] | None, *keys: str) -> object:
    value: object = root or {}
    for key in keys:
        if not isinstance(value, dict):
            return None
        value = value.get(key)
    return value


def check_evidence(evidence_root: Path) -> dict[str, object]:
    session = _load_json(evidence_root / "session.json")
    observations = _load_json(evidence_root / "operator-observations.json")
    before_debug = _load_json(evidence_root / "before-debug.json")
    after_debug = _load_json(evidence_root / "after-debug.json")
    before_dashboard = _load_json(evidence_root / "before-dashboard.json")
    after_dashboard = _load_json(evidence_root / "after-dashboard.json")
    records = _load_jsonl(evidence_root / "turns.jsonl")
    events = [
        record
        for record in records
        if record.get("schema") == "stackchan.conversation-event.v1"
    ]
    initiative = [
        record
        for record in records
        if record.get("schema") == "stackchan.initiative-turn.v1"
        and record.get("event") == "initiative_spoken"
    ]
    checks: list[dict[str, object]] = []

    def add(identifier: str, status: str, detail: str) -> None:
        checks.append({"id": identifier, "status": status, "detail": detail})

    def require_present(identifier: str, value: object, detail: str) -> None:
        add(identifier, "pass" if value is not None else "pending", detail)

    require_present("session-evidence", session, "session.json")
    require_present("before-debug", before_debug, "before-debug.json")
    require_present("after-debug", after_debug, "after-debug.json")
    require_present("before-dashboard", before_dashboard, "before-dashboard.json")
    require_present("after-dashboard", after_dashboard, "after-dashboard.json")
    require_present("operator-observations", observations, "operator-observations.json")

    if session is not None:
        add(
            "session-mode",
            "pass" if session.get("mode") == "bridge-ai-supervised" else "fail",
            f"mode={session.get('mode')}",
        )
        add(
            "source-commit",
            "pass"
            if len(str(session.get("sourceCommit", ""))) == 40
            and session.get("sourceWorktreeClean") is True
            else "fail",
            f"commit={session.get('sourceCommit', '')} clean={session.get('sourceWorktreeClean')}",
        )
        add(
            "operator-present",
            "pass" if session.get("operatorPresent") is True else "fail",
            f"operatorPresent={session.get('operatorPresent')}",
        )
        add(
            "motion-off-confirmed",
            "pass" if session.get("motionOffConfirmed") is True else "fail",
            f"motionOffConfirmed={session.get('motionOffConfirmed')}",
        )

    if before_dashboard is not None:
        add(
            "conversation-v2-enabled",
            "pass"
            if _nested(before_dashboard, "bridge", "conversationV2Enabled") is True
            else "fail",
            f"enabled={_nested(before_dashboard, 'bridge', 'conversationV2Enabled')}",
        )
        add(
            "initiative-enabled",
            "pass"
            if _nested(before_dashboard, "behavior", "initiative", "available") is True
            and _nested(before_dashboard, "behavior", "initiative", "enabled") is True
            else "fail",
            (
                f"available={_nested(before_dashboard, 'behavior', 'initiative', 'available')} "
                f"enabled={_nested(before_dashboard, 'behavior', 'initiative', 'enabled')}"
            ),
        )
        add(
            "room-observation-enabled",
            "pass"
            if _nested(before_dashboard, "behavior", "roomObservation", "available") is True
            and _nested(before_dashboard, "behavior", "roomObservation", "configured") is True
            and _nested(before_dashboard, "behavior", "roomObservation", "enabled") is True
            else "fail",
            (
                f"available={_nested(before_dashboard, 'behavior', 'roomObservation', 'available')} "
                f"configured={_nested(before_dashboard, 'behavior', 'roomObservation', 'configured')} "
                f"enabled={_nested(before_dashboard, 'behavior', 'roomObservation', 'enabled')}"
            ),
        )

    if before_debug is not None and after_debug is not None:
        firmware_before = str(before_debug.get("ota_expected_sha256", ""))
        firmware_after = str(after_debug.get("ota_expected_sha256", ""))
        add(
            "firmware-candidate-stable",
            "pass"
            if len(firmware_before) == 64 and firmware_before == firmware_after
            else "fail",
            f"before={firmware_before} after={firmware_after}",
        )
        robot_ready = all(
            snapshot.get("network_state") == "connected"
            and snapshot.get("bridge_state") == "ready"
            for snapshot in (before_debug, after_debug)
        )
        add("robot-link-ready", "pass" if robot_ready else "fail", f"ready={robot_ready}")
        motion_safe = all(
            snapshot.get("motion_enabled") is False
            and snapshot.get("servo_rail_enabled") is False
            and snapshot.get("servo_torque_enabled") is False
            for snapshot in (before_debug, after_debug)
        )
        add("robot-motion-off", "pass" if motion_safe else "fail", f"safe={motion_safe}")
        max_frame = max(
            _integer(before_debug.get("display_window_max_frame_us")),
            _integer(after_debug.get("display_window_max_frame_us")),
        )
        add(
            "display-frame-gate",
            "pass" if 0 < max_frame <= 50_000 else "fail",
            f"maxFrameUs={max_frame}",
        )
        min_reply_windows = max(1, _integer((session or {}).get("minReplyWindows"), 100))
        reply_windows = _delta(
            before_debug,
            after_debug,
            "conversation_reply_window_started",
        )
        add(
            "physical-reply-window-count",
            "pass" if reply_windows >= min_reply_windows else "fail",
            f"started={reply_windows} required={min_reply_windows}",
        )
        zero_delta_fields = (
            "bridge_uplink_errors",
            "bridge_uplink_queue_failures",
            "bridge_network_writer_text_dropped",
            "bridge_network_writer_binary_dropped",
            "bridge_reply_windows_rejected",
            "conversation_reply_window_rejected",
            "bridge_downlink_playback_errors",
            "speaker_stream_play_raw_failed",
            "speaker_stream_forced_stops",
        )
        writer_telemetry_fields = (
            "bridge_network_writer_frame_buffered",
            "bridge_network_writer_text_queued",
            "bridge_network_writer_binary_queued",
            "bridge_network_writer_text_dropped",
            "bridge_network_writer_binary_dropped",
            "bridge_network_writer_last_error",
        )
        missing_writer_telemetry = [
            key
            for key in writer_telemetry_fields
            if key not in before_debug or key not in after_debug
        ]
        add(
            "robot-writer-telemetry",
            "pass" if not missing_writer_telemetry else "fail",
            f"missing={json.dumps(missing_writer_telemetry)}",
        )
        bad_deltas = {
            key: _delta(before_debug, after_debug, key)
            for key in zero_delta_fields
            if _delta(before_debug, after_debug, key) != 0
        }
        add(
            "robot-zero-transport-errors",
            "pass" if not bad_deltas else "fail",
            f"deltas={json.dumps(bad_deltas, sort_keys=True)}",
        )
        vision_deltas = {
            key: _delta(before_debug, after_debug, key)
            for key in (
                "camera_host_frame_requests",
                "camera_host_target_updates",
                "camera_face_batches",
                "camera_faces_observed",
                "camera_events",
            )
        }
        vision_error_deltas = {
            key: _delta(before_debug, after_debug, key)
            for key in (
                "camera_host_frame_failures",
                "camera_host_auth_failures",
            )
        }
        vision_ready = (
            all(
                _integer(snapshot.get("compiled_enable_camera")) == 1
                and _integer(snapshot.get("compiled_enable_camera_host_vision")) == 1
                and snapshot.get("camera_ready") is True
                and snapshot.get("camera_active") is True
                and snapshot.get("camera_capture_ready") is True
                for snapshot in (before_debug, after_debug)
            )
            and all(delta > 0 for delta in vision_deltas.values())
            and all(delta == 0 for delta in vision_error_deltas.values())
        )
        add(
            "robot-host-vision-advancing",
            "pass" if vision_ready else "fail",
            (
                f"deltas={json.dumps(vision_deltas, sort_keys=True)} "
                f"errors={json.dumps(vision_error_deltas, sort_keys=True)}"
            ),
        )
        remote_stops = _delta(
            before_debug,
            after_debug,
            "bridge_audio_remote_stop_requests",
        )
        add(
            "robot-barge-in-stop",
            "pass" if remote_stops >= 1 else "fail",
            f"remoteStopRequests={remote_stops}",
        )
        drained = (
            after_debug.get("audio_stream_active") is False
            and after_debug.get("bridge_downlink_playback_awaiting_drain") is False
            and _integer(after_debug.get("speaker_channel_state"), 1) == 0
        )
        add("robot-audio-drained", "pass" if drained else "fail", f"drained={drained}")

    audio_protocol_events = [
        record
        for record in records
        if record.get("schema") == "stackchan.audio-protocol-event.v1"
    ]
    audio_count_mismatches = [
        record
        for record in records
        if record.get("schema") == "stackchan.lan-turn-summary.v1"
        and (
            record.get("reject_code") == "audio_count_mismatch"
            or record.get("audio_end_counts_match") is False
        )
    ]
    add(
        "host-audio-order-clean",
        "pass" if not audio_protocol_events and not audio_count_mismatches else "fail",
        (
            f"protocolEvents={len(audio_protocol_events)} "
            f"countMismatches={len(audio_count_mismatches)}"
        ),
    )

    response_wire_events = [
        record
        for record in records
        if record.get("schema") == "stackchan.response-wire-event.v1"
    ]
    response_wire_failures = [
        record
        for record in response_wire_events
        if record.get("recovered") is not True
    ]
    forced_response_closures = [
        record
        for record in response_wire_events
        if record.get("code") == "response_forced_closed"
        and record.get("recovered") is True
    ]
    add(
        "host-response-wire-clean",
        "pass" if not response_wire_failures else "fail",
        (
            f"failures={len(response_wire_failures)} "
            f"forcedClosures={len(forced_response_closures)}"
        ),
    )

    event_names = [str(record.get("event", "")) for record in events]
    max_turns = max((_integer(record.get("conversation_turns")) for record in events), default=0)
    add(
        "one-wake-multi-turn-events",
        "pass" if "wake" in event_names and max_turns >= 2 else "fail",
        f"wake={'wake' in event_names} maxTurns={max_turns}",
    )
    for event_name, identifier in (
        ("reply_pending", "playback-drain-before-reply"),
        ("reply_window_open", "reply-window-opened"),
        ("exit_phrase", "exit-phrase-close"),
        ("reply_timeout", "silence-timeout-close"),
        ("bridge_lost", "bridge-loss-close"),
    ):
        add(
            identifier,
            "pass" if event_name in event_names else "fail",
            f"event={event_name} count={event_names.count(event_name)}",
        )
    barge_events = [
        record
        for record in events
        if record.get("event") == "barge_in"
        and "cancel_playback" in record.get("actions", [])
    ]
    add(
        "host-barge-in-cancel",
        "pass" if barge_events else "fail",
        f"events={len(barge_events)}",
    )

    latency = summarize_latency_records(records)
    add(
        "warm-local-latency",
        "pass"
        if latency.get("status") == "pass" and _integer(latency.get("audio_turns")) >= 3
        else "fail",
        (
            f"status={latency.get('status')} turns={latency.get('audio_turns')} "
            f"firstAudio={json.dumps(latency.get('first_audio_ms'), sort_keys=True)}"
        ),
    )
    paced_audio_turns = [
        record
        for record in records
        if record.get("schema") == "stackchan.lan-turn-summary.v1"
        and record.get("tts_streaming") is True
    ]
    unsafe_pacing_turns = [
        record
        for record in paced_audio_turns
        if record.get("tts_downlink_pacing_safe") is not True
    ]
    add(
        "host-audio-pacing-safe",
        "pass"
        if len(paced_audio_turns) >= 3 and not unsafe_pacing_turns
        else "fail",
        (
            f"turns={len(paced_audio_turns)} "
            f"unsafe={len(unsafe_pacing_turns)} "
            "minimumHeadroomMs=25"
        ),
    )

    initiative_times = [
        timestamp
        for timestamp in (_timestamp(record.get("generated_at")) for record in initiative)
        if timestamp is not None
    ]
    initiative_gaps = [
        (later - earlier).total_seconds()
        for earlier, later in zip(initiative_times, initiative_times[1:])
    ]
    add(
        "initiative-two-openers",
        "pass" if len(initiative_times) >= 2 else "fail",
        f"spoken={len(initiative_times)}",
    )
    add(
        "initiative-hard-floor",
        "pass"
        if initiative_gaps and min(initiative_gaps) >= 600
        else "fail",
        f"minimumGapSeconds={min(initiative_gaps) if initiative_gaps else None}",
    )
    after_initiative = _nested(after_dashboard, "behavior", "initiative")
    initiative_backoff = (
        isinstance(after_initiative, dict)
        and _integer(after_initiative.get("ignoredOpeners")) >= 2
        and _integer(after_initiative.get("backoffRemainingSeconds")) > 0
    )
    add(
        "initiative-ignored-backoff",
        "pass" if initiative_backoff else "fail",
        (
            f"ignored={_nested(after_dashboard, 'behavior', 'initiative', 'ignoredOpeners')} "
            f"backoff={_nested(after_dashboard, 'behavior', 'initiative', 'backoffRemainingSeconds')}"
        ),
    )

    after_room = _nested(after_dashboard, "behavior", "roomObservation")
    room_cleared = (
        isinstance(after_room, dict)
        and _integer(after_room.get("observations")) >= 2
        and _integer(after_room.get("failures")) == 0
        and after_room.get("enabled") is False
        and after_room.get("personCount") is None
        and after_room.get("ageSeconds") is None
    )
    add(
        "room-disable-clears-summary",
        "pass" if room_cleared else "fail",
        (
            f"observations={_nested(after_dashboard, 'behavior', 'roomObservation', 'observations')} "
            f"failures={_nested(after_dashboard, 'behavior', 'roomObservation', 'failures')} "
            f"enabled={_nested(after_dashboard, 'behavior', 'roomObservation', 'enabled')}"
        ),
    )
    frame_files = [
        str(path.relative_to(evidence_root))
        for path in evidence_root.rglob("*")
        if path.is_file() and path.suffix.lower() in FRAME_SUFFIXES
    ]
    add(
        "evidence-has-no-room-frames",
        "pass" if not frame_files else "fail",
        f"frameFiles={frame_files}",
    )

    for key, identifier in OPERATOR_GATES:
        if observations is None or key not in observations:
            add(identifier, "pending", f"{key}=missing")
        else:
            add(
                identifier,
                "pass" if observations.get(key) is True else "fail",
                f"{key}={observations.get(key)}",
            )
    observed_windows = _integer((observations or {}).get("echoWindowsObserved"))
    required_windows = max(1, _integer((session or {}).get("minReplyWindows"), 100))
    add(
        "operator-echo-window-count",
        "pass" if observed_windows >= required_windows else "fail",
        f"observed={observed_windows} required={required_windows}",
    )

    failed = [check for check in checks if check["status"] == "fail"]
    pending = [check for check in checks if check["status"] == "pending"]
    status = (
        "bridge-ai-supervised-not-ready"
        if failed
        else "bridge-ai-supervised-pending"
        if pending
        else "bridge-ai-supervised-ready"
    )
    return {
        "schema": "stackchan.bridge-ai-supervised-check.v1",
        "status": status,
        "evidenceRoot": str(evidence_root),
        "passed": sum(check["status"] == "pass" for check in checks),
        "failed": len(failed),
        "pending": len(pending),
        "checks": checks,
        "latency": latency,
    }


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--evidence-root", type=Path, required=True)
    parser.add_argument("--json", action="store_true")
    parser.add_argument("--require-ready", action="store_true")
    return parser


def main() -> int:
    args = build_parser().parse_args()
    report = check_evidence(args.evidence_root.resolve())
    if args.json:
        print(json.dumps(report, indent=2, sort_keys=True))
    else:
        print(
            f"{report['status']} "
            f"({report['passed']} pass, {report['failed']} fail, {report['pending']} pending)"
        )
        for check in report["checks"]:
            print(f"{check['status']:7} {check['id']}: {check['detail']}")
    return 1 if args.require_ready and report["status"] != "bridge-ai-supervised-ready" else 0


if __name__ == "__main__":
    raise SystemExit(main())
