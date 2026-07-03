#!/usr/bin/env python3
"""Host-side virtual Stackchan for bridge protocol smoke tests.

This is not a replacement for real hardware evidence. It is a deterministic
proxy that consumes the same bridge frames the firmware consumes and checks the
state/order assumptions we can validate before the device is on the bench.
"""

from __future__ import annotations

import argparse
import json
import os
from dataclasses import dataclass, field
from pathlib import Path
from typing import Iterable

from lan_service import LanBridgeConfig, LanBridgeSession
from reference_bridge import AudioBeat, BridgeTurn, bridge_frames

SIM_SCHEMA = "stackchan.hardware-sim.v1"
DEFAULT_TIMEOUT_MS = 2000
DISPLAY_FRAME_MS = 33


Frame = dict[str, object] | bytes


@dataclass
class VirtualHardwareTelemetry:
    bridge_ready: bool = False
    bridge_state: str = "Disconnected"
    face_mode: str = "idle"
    active_seq: int = 0
    inbound_messages: int = 0
    outputs_queued: int = 0
    parse_errors: int = 0
    timeouts: int = 0
    bridge_errors: int = 0
    bridge_recoveries: int = 0
    offline_fallback_prompts: int = 0
    speech_frames: int = 0
    speech_final_frames: int = 0
    mouth_peak: float = 0.0
    audio_streams_started: int = 0
    audio_streams_ended: int = 0
    audio_streams_aborted: int = 0
    audio_stream_bytes_expected: int = 0
    audio_stream_bytes_received: int = 0
    audio_stream_chunks_expected: int = 0
    audio_stream_chunks_received: int = 0
    response_text: str = ""
    boot_count: int = 0
    display_ready: bool = False
    display_frames: int = 0
    display_frame_gap_max_ms: int = 0
    display_label_frames: int = 0
    mouth_display_frames: int = 0
    speaker_ready: bool = False
    speaker_playback_starts: int = 0
    speaker_frames_submitted: int = 0
    control_events: int = 0
    core_inputs: int = 0
    motion_enabled: bool = True
    power_cycles: int = 0
    modes_seen: list[str] = field(default_factory=lambda: ["idle"])

    def to_dict(self) -> dict[str, object]:
        return {
            "bridge_ready": self.bridge_ready,
            "bridge_state": self.bridge_state,
            "face_mode": self.face_mode,
            "active_seq": self.active_seq,
            "inbound_messages": self.inbound_messages,
            "outputs_queued": self.outputs_queued,
            "parse_errors": self.parse_errors,
            "timeouts": self.timeouts,
            "bridge_errors": self.bridge_errors,
            "bridge_recoveries": self.bridge_recoveries,
            "offline_fallback_prompts": self.offline_fallback_prompts,
            "speech_frames": self.speech_frames,
            "speech_final_frames": self.speech_final_frames,
            "mouth_peak": round(self.mouth_peak, 3),
            "audio_streams_started": self.audio_streams_started,
            "audio_streams_ended": self.audio_streams_ended,
            "audio_streams_aborted": self.audio_streams_aborted,
            "audio_stream_bytes_expected": self.audio_stream_bytes_expected,
            "audio_stream_bytes_received": self.audio_stream_bytes_received,
            "audio_stream_chunks_expected": self.audio_stream_chunks_expected,
            "audio_stream_chunks_received": self.audio_stream_chunks_received,
            "response_text": self.response_text,
            "boot_count": self.boot_count,
            "display_ready": self.display_ready,
            "display_frames": self.display_frames,
            "display_frame_gap_max_ms": self.display_frame_gap_max_ms,
            "display_label_frames": self.display_label_frames,
            "mouth_display_frames": self.mouth_display_frames,
            "speaker_ready": self.speaker_ready,
            "speaker_playback_starts": self.speaker_playback_starts,
            "speaker_frames_submitted": self.speaker_frames_submitted,
            "control_events": self.control_events,
            "core_inputs": self.core_inputs,
            "motion_enabled": self.motion_enabled,
            "power_cycles": self.power_cycles,
            "modes_seen": list(self.modes_seen),
        }


@dataclass
class ActiveAudioStream:
    seq: int = 0
    expected_bytes: int = 0
    expected_chunks: int = 0
    received_bytes: int = 0
    received_chunks: int = 0
    format: str = ""
    sample_rate: int = 0


@dataclass
class VirtualStackchanHardware:
    timeout_ms: int = DEFAULT_TIMEOUT_MS
    telemetry: VirtualHardwareTelemetry = field(default_factory=VirtualHardwareTelemetry)
    serial_lines: list[str] = field(default_factory=list)
    issues: list[str] = field(default_factory=list)
    now_ms: int = 0
    last_activity_ms: int = 0
    active_stream: ActiveAudioStream | None = None
    display_next_ms: int = 0
    display_last_frame_ms: int | None = None
    mouth_env: float = 0.0
    speech_active: bool = False

    def __post_init__(self) -> None:
        self._boot()

    def process(self, frame: Frame, at_ms: int | None = None) -> None:
        if at_ms is not None:
            self.update(at_ms)
            self.now_ms = at_ms
        if isinstance(frame, bytes):
            self._process_binary(frame)
            return
        if not isinstance(frame, dict):
            self._record_error("frame_not_object")
            return
        self._process_text(frame)

    def update(self, now_ms: int) -> None:
        if now_ms < self.now_ms:
            self._record_error("time_moved_backwards")
            return
        self._render_until(now_ms)
        active = self.telemetry.bridge_state in {"Listening", "Thinking", "Responding"}
        if active and now_ms - self.last_activity_ms >= self.timeout_ms:
            self.telemetry.timeouts += 1
            self.telemetry.bridge_state = "Error"
            self._serial(
                f"[bridge] type=error state=Error code=bridge_timeout timeout_ms={self.timeout_ms}"
            )
            self.issues.append("bridge_timeout")
        self.now_ms = now_ms

    def finish(self) -> None:
        self._render_until(self.now_ms)
        if self.active_stream is not None:
            self._record_error("audio_stream_left_open")
        if self.telemetry.bridge_state in {"Thinking", "Responding"}:
            self._record_error("response_left_active")

    def ok(self) -> bool:
        return not self.issues and self.telemetry.parse_errors == 0 and self.telemetry.timeouts == 0

    def report(self, scenario: str) -> dict[str, object]:
        return {
            "schema": SIM_SCHEMA,
            "scenario": scenario,
            "status": "pass" if self.ok() else "fail",
            "telemetry": self.telemetry.to_dict(),
            "issues": list(self.issues),
            "serial_lines": len(self.serial_lines),
        }

    def validate_scenario(self, scenario: str) -> None:
        if not self.telemetry.display_ready:
            self._record_issue("display_not_ready")
        if self.telemetry.display_frames <= 0:
            self._record_issue("display_never_rendered")
        if self.telemetry.display_label_frames != self.telemetry.display_frames:
            self._record_issue("display_label_not_persistent")
        if self.telemetry.display_frame_gap_max_ms > 40:
            self._record_issue("display_frame_gap_exceeds_30fps_budget")
        if scenario == "audio-downlink":
            if self.telemetry.speaker_playback_starts != 1:
                self._record_issue("speaker_playback_not_started")
            if self.telemetry.speaker_frames_submitted != self.telemetry.audio_stream_chunks_expected:
                self._record_issue("speaker_frame_count_mismatch")
            if self.telemetry.mouth_display_frames <= 0:
                self._record_issue("mouth_never_rendered_during_audio")
        if scenario == "arrival-rehearsal":
            if self.telemetry.boot_count < 2:
                self._record_issue("power_cycle_reboot_not_observed")
            if self.telemetry.core_inputs < 5:
                self._record_issue("core_inputs_not_covered")
            if self.telemetry.control_events < 7:
                self._record_issue("control_events_not_covered")
            if self.telemetry.speaker_playback_starts < 1:
                self._record_issue("arrival_speaker_stream_not_exercised")
            if self.telemetry.mouth_display_frames <= 0:
                self._record_issue("arrival_mouth_display_not_exercised")
            if self.telemetry.power_cycles < 1:
                self._record_issue("power_cycle_not_exercised")
            if self.telemetry.bridge_state != "Ready":
                self._record_issue("arrival_did_not_recover_ready")
            for mode in ("listen", "think", "react", "speak", "concern", "happy", "idle"):
                if mode not in self.telemetry.modes_seen:
                    self._record_issue(f"arrival_mode_not_seen:{mode}")
        if scenario == "bridge-kill-recovery":
            if self.telemetry.bridge_errors != 1:
                self._record_issue("bridge_kill_error_not_observed")
            if self.telemetry.offline_fallback_prompts != 1:
                self._record_issue("offline_fallback_prompt_not_observed")
            if self.telemetry.bridge_recoveries != 1:
                self._record_issue("bridge_recovery_not_observed")
            if self.telemetry.bridge_state != "Ready":
                self._record_issue("bridge_kill_did_not_recover_ready")
            if "error" not in self.telemetry.modes_seen:
                self._record_issue("bridge_kill_error_mode_not_seen")
            if self.telemetry.speech_frames <= 0:
                self._record_issue("bridge_kill_recovery_response_not_spoken")

    def _process_text(self, frame: dict[str, object]) -> None:
        frame_type = str(frame.get("type", "")).strip().lower()
        self.telemetry.inbound_messages += 1
        self.telemetry.outputs_queued += 1
        self.last_activity_ms = self.now_ms

        if frame_type == "hello":
            if self.telemetry.bridge_state == "Error":
                self.telemetry.bridge_recoveries += 1
            self.telemetry.bridge_ready = True
            self.telemetry.bridge_state = "Ready"
            self._set_face_mode("idle")
            self._serial(f"[bridge] type=hello state=Ready session={frame.get('session', '')}")
            return
        if frame_type == "heartbeat":
            self._serial(f"[bridge] type=heartbeat state={self.telemetry.bridge_state}")
            return
        if frame_type == "listening":
            self.telemetry.bridge_ready = True
            self.telemetry.bridge_state = "Listening"
            self._set_face_mode("listen")
            self._serial("[bridge] type=listening state=Listening")
            return
        if frame_type == "thinking":
            self.telemetry.bridge_state = "Thinking"
            self._set_face_mode("think")
            self.telemetry.active_seq = _int(frame.get("seq"), self.telemetry.active_seq)
            self._serial(f"[bridge] type=thinking state=Thinking seq={self.telemetry.active_seq}")
            return
        if frame_type == "response_start":
            self.telemetry.bridge_state = "Responding"
            self.telemetry.active_seq = _int(frame.get("seq"), self.telemetry.active_seq)
            self._set_face_mode(str(frame.get("intent") or "speak"))
            self.telemetry.response_text = str(frame.get("text") or "")[:160]
            self._serial(
                "[bridge] type=response_start "
                f"state=Responding seq={self.telemetry.active_seq} intent={self.telemetry.face_mode}"
            )
            return
        if frame_type == "audio_stream_start":
            self._start_audio_stream(frame)
            return
        if frame_type == "audio_stream_end":
            self._end_audio_stream(frame)
            return
        if frame_type == "audio":
            self._process_audio_frame(frame)
            return
        if frame_type == "response_end":
            seq = _int(frame.get("seq"), self.telemetry.active_seq)
            if self.active_stream is not None:
                self._record_error("response_end_before_audio_stream_end")
            self.telemetry.bridge_state = "Ready"
            self._set_face_mode("idle")
            self.telemetry.active_seq = seq
            self.mouth_env = 0.0
            self.speech_active = False
            self._serial(f"[bridge] type=response_end state=Ready seq={seq}")
            return
        if frame_type == "error":
            self.telemetry.bridge_state = "Error"
            self.telemetry.bridge_errors += 1
            self._set_face_mode("error")
            if self.active_stream is not None:
                self.telemetry.audio_streams_aborted += 1
                self.active_stream = None
            self.mouth_env = 0.0
            self.speech_active = False
            self._serial(f"[bridge] type=error state=Error code={frame.get('code', 'bridge_error')}")
            self._offline_fallback(str(frame.get("code") or "bridge_error"))
            return
        if frame_type == "control_input":
            self._process_control_input(frame)
            return
        if frame_type == "control_command":
            self._process_control_command(frame)
            return
        if frame_type == "power_cycle":
            self._power_cycle()
            return
        self._record_error(f"unsupported_frame:{frame_type or 'blank'}")

    def _process_binary(self, payload: bytes) -> None:
        self.telemetry.outputs_queued += 1
        self.last_activity_ms = self.now_ms
        if self.active_stream is None:
            self._record_error("binary_without_audio_stream")
            return
        self.active_stream.received_bytes += len(payload)
        self.active_stream.received_chunks += 1
        self.telemetry.audio_stream_bytes_received += len(payload)
        self.telemetry.audio_stream_chunks_received += 1
        self.telemetry.speaker_frames_submitted += 1
        self._serial(
            "[bridge] type=audio_binary "
            f"state={self.telemetry.bridge_state} seq={self.active_stream.seq} bytes={len(payload)}"
        )

    def _start_audio_stream(self, frame: dict[str, object]) -> None:
        if self.active_stream is not None:
            self._record_error("nested_audio_stream")
            return
        stream = ActiveAudioStream(
            seq=_int(frame.get("seq"), self.telemetry.active_seq),
            expected_bytes=max(0, _int(frame.get("audio_bytes"), 0)),
            expected_chunks=max(0, _int(frame.get("chunks"), 0)),
            format=str(frame.get("format") or "binary")[:16],
            sample_rate=max(0, _int(frame.get("sample_rate"), 0)),
        )
        self.active_stream = stream
        self.telemetry.audio_streams_started += 1
        self.telemetry.audio_stream_bytes_expected += stream.expected_bytes
        self.telemetry.audio_stream_chunks_expected += stream.expected_chunks
        self.telemetry.speaker_playback_starts += 1
        self.telemetry.bridge_state = "Responding"
        self._serial(
            "[bridge] type=audio_stream_start "
            f"state=Responding seq={stream.seq} format={stream.format} bytes={stream.expected_bytes} "
            f"chunks={stream.expected_chunks} sample_rate={stream.sample_rate}"
        )

    def _end_audio_stream(self, frame: dict[str, object]) -> None:
        if self.active_stream is None:
            self._record_error("audio_stream_end_without_start")
            return
        stream = self.active_stream
        end_bytes = max(0, _int(frame.get("audio_bytes"), stream.expected_bytes))
        end_chunks = max(0, _int(frame.get("chunks"), stream.expected_chunks))
        if end_bytes != stream.expected_bytes:
            self._record_error("audio_stream_end_bytes_mismatch")
        if end_chunks != stream.expected_chunks:
            self._record_error("audio_stream_end_chunks_mismatch")
        if stream.received_bytes != stream.expected_bytes:
            self._record_error("audio_stream_payload_bytes_mismatch")
        if stream.received_chunks != stream.expected_chunks:
            self._record_error("audio_stream_payload_chunks_mismatch")
        self.telemetry.audio_streams_ended += 1
        self._serial(
            "[bridge] type=audio_stream_end "
            f"state=Responding seq={stream.seq} bytes={stream.received_bytes} chunks={stream.received_chunks}"
        )
        self.active_stream = None

    def _process_audio_frame(self, frame: dict[str, object]) -> None:
        env = _float(frame.get("env", frame.get("envelope", 0.0)), 0.0)
        env = max(0.0, min(1.0, env))
        self.telemetry.speech_frames += 1
        self.telemetry.mouth_peak = max(self.telemetry.mouth_peak, env)
        self.mouth_env = env
        self.speech_active = env > 0.02
        if bool(frame.get("final", False)):
            self.telemetry.speech_final_frames += 1
            self.speech_active = False
        self._serial(
            "[bridge] type=audio "
            f"state={self.telemetry.bridge_state} seq={frame.get('seq', self.telemetry.active_seq)} "
            f"env={env:.2f} viseme={frame.get('viseme', 'neutral')} final={int(bool(frame.get('final', False)))}"
        )

    def _process_control_input(self, frame: dict[str, object]) -> None:
        raw_name = str(frame.get("input") or frame.get("button") or "").strip().lower()
        aliases = {
            "button_a": "btn_a",
            "btna": "btn_a",
            "button_b": "btn_b",
            "btnb": "btn_b",
            "button_c": "btn_c",
            "btnc": "btn_c",
            "screen_tap": "tap",
            "screen_hold": "hold",
        }
        name = aliases.get(raw_name, raw_name)
        mapping = {
            "tap": ("react", "UserTouched", "touch_click_react"),
            "hold": ("listen", "UserNear", "touch_hold_listen"),
            "btn_a": ("listen", "WakeWord", "button_a_listen"),
            "btn_b": ("think", "ThinkingStarted", "button_b_think"),
            "btn_c": ("speak", "ResponseStarted", "button_c_speak"),
        }
        if name not in mapping:
            self._record_error(f"unsupported_control_input:{raw_name or 'blank'}")
            return
        mode, event, command = mapping[name]
        strength = max(0.0, min(1.0, _float(frame.get("strength"), 1.0)))
        self.telemetry.control_events += 1
        self.telemetry.core_inputs += 1
        self._set_face_mode(mode)
        self._serial(
            "[control] "
            f"command={command} mode={mode} event={event} strength={strength:.2f} "
            f"core_input=1 motion_enabled={int(self.telemetry.motion_enabled)} at_ms={self.now_ms}"
        )

    def _process_control_command(self, frame: dict[str, object]) -> None:
        command = str(frame.get("command") or "").strip().lower()
        strength = max(0.0, min(1.0, _float(frame.get("strength"), 1.0)))
        if command == "shake":
            mode = "concern"
            event = "Shaken"
            self.telemetry.motion_enabled = False
        elif command == "putdown":
            mode = "idle"
            event = "PutDown"
            self.telemetry.motion_enabled = True
        elif command in {"safe_stop", "stop_moving", "motion_stop"}:
            mode = "safety"
            event = "SafetyStop"
            self.telemetry.motion_enabled = False
        elif command in {"safe_resume", "motion_resume"}:
            mode = "idle"
            event = "SafetyResume"
            self.telemetry.motion_enabled = True
        else:
            self._record_error(f"unsupported_control_command:{command or 'blank'}")
            return
        self.telemetry.control_events += 1
        self._set_face_mode(mode)
        self._serial(
            "[control] "
            f"command={command} mode={mode} event={event} strength={strength:.2f} "
            f"motion_enabled={int(self.telemetry.motion_enabled)} at_ms={self.now_ms}"
        )

    def _boot(self) -> None:
        self.telemetry.boot_count += 1
        self.telemetry.display_ready = True
        self.telemetry.speaker_ready = True
        self.telemetry.bridge_state = "Disconnected"
        self._set_face_mode("idle")
        self.display_next_ms = self.now_ms
        self.display_last_frame_ms = None
        self.mouth_env = 0.0
        self.speech_active = False
        self._serial("[system] boot virtual_core_s3=1 firmware=stackchan_alive")
        self._serial("[display] M5 display renderer ready canvas=double-buffered")
        self._serial("[audio_out] hw_ready=1 hw_playing=0 source=virtual_speaker")

    def _power_cycle(self) -> None:
        if self.active_stream is not None:
            self._record_issue("power_cycle_with_audio_stream_active")
            self.active_stream = None
        self.telemetry.power_cycles += 1
        self.telemetry.bridge_ready = False
        self.telemetry.bridge_state = "Disconnected"
        self.telemetry.active_seq = 0
        self.telemetry.motion_enabled = True
        self._serial("[system] power_cycle requested source=virtual_hardware")
        self._boot()

    def _offline_fallback(self, code: str) -> None:
        self.telemetry.offline_fallback_prompts += 1
        self._serial(
            "[speech] "
            f"seq={self.telemetry.active_seq} intent=error earcon=warn "
            f'text="I need a little more data." bridge_error={code}'
        )

    def _render_until(self, now_ms: int) -> None:
        while self.display_next_ms <= now_ms:
            if self.display_last_frame_ms is not None:
                gap = self.display_next_ms - self.display_last_frame_ms
                self.telemetry.display_frame_gap_max_ms = max(self.telemetry.display_frame_gap_max_ms, gap)
            self.telemetry.display_frames += 1
            if self.telemetry.display_ready:
                self.telemetry.display_label_frames += 1
            if self.mouth_env > 0.02:
                self.telemetry.mouth_display_frames += 1
            self.display_last_frame_ms = self.display_next_ms
            self.display_next_ms += DISPLAY_FRAME_MS

    def _set_face_mode(self, mode: str) -> None:
        normalized = " ".join(str(mode or "idle").strip().lower().split()) or "idle"
        self.telemetry.face_mode = normalized
        if normalized not in self.telemetry.modes_seen:
            self.telemetry.modes_seen.append(normalized)

    def _record_error(self, issue: str) -> None:
        self.telemetry.parse_errors += 1
        self.telemetry.bridge_state = "Error"
        self.issues.append(issue)
        self._serial(f"[bridge] type=error state=Error code={issue}")

    def _record_issue(self, issue: str) -> None:
        self.issues.append(issue)
        self._serial(f"[sim] status=fail issue={issue}")

    def _serial(self, line: str) -> None:
        self.serial_lines.append(f"{self.now_ms:06d} {line}")


def _int(value: object, default: int = 0) -> int:
    try:
        return int(value)
    except (TypeError, ValueError):
        return default


def _float(value: object, default: float = 0.0) -> float:
    try:
        return float(value)
    except (TypeError, ValueError):
        return default


def full_audio_downlink_frames() -> list[Frame]:
    turn = BridgeTurn(
        session="sim",
        seq=11,
        intent="happy",
        text="Hello. I am Stackchan, and I am awake.",
        beats=(
            AudioBeat(0.24, "neutral", 40),
            AudioBeat(0.66, "ah", 60),
            AudioBeat(0.84, "ee", 70),
            AudioBeat(0.12, "neutral", 50, True),
        ),
    )
    frames: list[Frame] = []
    for frame in bridge_frames(turn):
        frames.append(frame)
        if frame.get("type") == "response_start":
            frames.extend(
                [
                    {
                        "type": "audio_stream_start",
                        "seq": turn.seq,
                        "format": "wav",
                        "sample_rate": 22050,
                        "audio_bytes": 9,
                        "chunk_bytes": 3,
                        "chunks": 3,
                    },
                    b"abc",
                    b"def",
                    b"ghi",
                    {"type": "audio_stream_end", "seq": turn.seq, "audio_bytes": 9, "chunks": 3},
                ]
            )
    return frames


def arrival_rehearsal_frames() -> list[Frame]:
    frames: list[Frame] = [
        {"type": "hello", "protocol": "stackchan.bridge.v1", "session": "arrival"},
        {"type": "control_input", "input": "btn_a"},
        {"type": "control_input", "input": "btn_b"},
        {"type": "control_input", "input": "tap"},
        {"type": "control_input", "input": "hold"},
        {"type": "control_input", "input": "btn_c"},
        {"type": "control_command", "command": "shake", "strength": 0.85},
        {"type": "control_command", "command": "putdown"},
    ]
    frames.extend(full_audio_downlink_frames()[1:])
    frames.extend(
        [
            {"type": "power_cycle"},
            {"type": "hello", "protocol": "stackchan.bridge.v1", "session": "arrival-reboot"},
            {"type": "heartbeat"},
        ]
    )
    return frames


def bridge_kill_recovery_frames() -> list[Frame]:
    recovery_turn = BridgeTurn(
        session="bridge-kill-recovery",
        seq=52,
        intent="happy",
        text="I am back online. Systems steady.",
        beats=(
            AudioBeat(0.22, "neutral", 50),
            AudioBeat(0.58, "ah", 70),
            AudioBeat(0.70, "ee", 70),
            AudioBeat(0.10, "neutral", 50, True),
        ),
    )
    return [
        {"type": "hello", "protocol": "stackchan.bridge.v1", "session": "bridge-kill"},
        {"type": "listening"},
        {"type": "thinking", "seq": 51},
        {
            "type": "response_start",
            "seq": 51,
            "intent": "think",
            "arousal": 0.55,
            "valence": 0.45,
            "text": "Working on that.",
        },
        {
            "type": "audio_stream_start",
            "seq": 51,
            "format": "wav",
            "sample_rate": 22050,
            "audio_bytes": 9,
            "chunk_bytes": 3,
            "chunks": 3,
        },
        b"abc",
        {"type": "error", "seq": 51, "code": "bridge_closed"},
        {"type": "hello", "protocol": "stackchan.bridge.v1", "session": "bridge-kill-retry"},
        *list(bridge_frames(recovery_turn))[1:],
    ]


def reference_frames() -> list[Frame]:
    return list(bridge_frames(BridgeTurn(session="sim", seq=7)))


def lan_text_frames() -> list[Frame]:
    old_env = {
        key: os.environ.get(key)
        for key in (
            "STACKCHAN_GEMMA4_E2B_GGUF_COMMAND",
            "STACKCHAN_GEMMA4_E2B_LITERT_COMMAND",
            "STACKCHAN_GEMMA4_E4B_GGUF_COMMAND",
            "STACKCHAN_MODEL_COMMAND",
            "STACKCHAN_TTS_COMMAND",
        )
    }
    try:
        for key in old_env:
            os.environ[key] = ""
        session = LanBridgeSession(LanBridgeConfig(runner_case="greeting"))
        frames: list[Frame] = []
        frames.extend(session.handle_text(json.dumps({"type": "hello", "device_id": "stackchan-sim"})))
        frames.extend(session.handle_text(json.dumps({"type": "utterance_start", "sample_rate": 16000})))
        frames.extend(
            session.handle_text(
                json.dumps({"type": "utterance_end", "seq": 21, "text": "Hello Stackchan, I am here."})
            )
        )
        return frames
    finally:
        for key, value in old_env.items():
            if value is None:
                os.environ.pop(key, None)
            else:
                os.environ[key] = value


def timeout_frames() -> list[Frame]:
    return [
        {"type": "hello", "protocol": "stackchan.bridge.v1", "session": "sim"},
        {"type": "thinking", "seq": 99},
    ]


def scenario_frames(name: str) -> tuple[list[Frame], int | None]:
    if name == "reference":
        return reference_frames(), None
    if name == "lan-text":
        return lan_text_frames(), None
    if name == "audio-downlink":
        return full_audio_downlink_frames(), None
    if name == "arrival-rehearsal":
        return arrival_rehearsal_frames(), None
    if name == "bridge-kill-recovery":
        return bridge_kill_recovery_frames(), None
    if name == "timeout":
        return timeout_frames(), DEFAULT_TIMEOUT_MS + 10
    raise ValueError(f"unknown scenario: {name}")


def run_simulation(name: str) -> VirtualStackchanHardware:
    frames, final_update = scenario_frames(name)
    hardware = VirtualStackchanHardware()
    now_ms = 0
    for frame in frames:
        hardware.process(frame, at_ms=now_ms)
        now_ms += frame_duration_ms(frame)
    if final_update is not None:
        hardware.update(now_ms + final_update)
    hardware.finish()
    hardware.validate_scenario(name)
    return hardware


def frame_duration_ms(frame: Frame) -> int:
    if isinstance(frame, bytes):
        return 8
    if frame.get("type") in {"control_input", "control_command"}:
        return 120
    if frame.get("type") == "power_cycle":
        return 300
    if frame.get("type") == "audio":
        return max(10, min(250, _int(frame.get("duration_ms"), 20)))
    if frame.get("type") in {"thinking", "response_start", "response_end"}:
        return 35
    return 20


def run_many(scenarios: Iterable[str]) -> dict[str, object]:
    reports = []
    for scenario in scenarios:
        hardware = run_simulation(scenario)
        reports.append(hardware.report(scenario))
    return {
        "schema": SIM_SCHEMA,
        "status": "pass" if all(report["status"] == "pass" for report in reports) else "fail",
        "scenarios": reports,
    }


def write_outputs(output_dir: Path, scenarios: Iterable[str]) -> dict[str, object]:
    output_dir.mkdir(parents=True, exist_ok=True)
    summary = {"schema": SIM_SCHEMA, "status": "pass", "scenarios": []}
    markdown_lines = [
        "# Stackchan Hardware Simulation",
        "",
        "This is a no-hardware proxy for bridge protocol behavior. It does not replace real device evidence.",
        "",
    ]
    for scenario in scenarios:
        hardware = run_simulation(scenario)
        report = hardware.report(scenario)
        summary["scenarios"].append(report)
        if report["status"] != "pass":
            summary["status"] = "fail"
        (output_dir / f"{scenario}.serial.log").write_text("\n".join(hardware.serial_lines) + "\n", encoding="utf-8")
        (output_dir / f"{scenario}.json").write_text(json.dumps(report, indent=2, sort_keys=True) + "\n", encoding="utf-8")
        telemetry = report["telemetry"]
        markdown_lines.extend(
            [
                f"## {scenario}",
                "",
                f"- Status: {report['status']}",
                f"- Bridge state: {telemetry['bridge_state']}",
                f"- Face mode: {telemetry['face_mode']}",
                f"- Speech frames: {telemetry['speech_frames']}",
                f"- Display frames: {telemetry['display_frames']} (max gap {telemetry['display_frame_gap_max_ms']} ms)",
                f"- Controls: {telemetry['control_events']} total / {telemetry['core_inputs']} CoreS3 inputs",
                f"- Audio streams: {telemetry['audio_streams_started']} started / {telemetry['audio_streams_ended']} ended",
                f"- Audio bytes: {telemetry['audio_stream_bytes_received']} received",
                f"- Speaker frames: {telemetry['speaker_frames_submitted']}",
                f"- Boots / power cycles: {telemetry['boot_count']} / {telemetry['power_cycles']}",
                f"- Issues: {', '.join(report['issues']) if report['issues'] else 'none'}",
                "",
            ]
        )
    (output_dir / "hardware_simulation.json").write_text(json.dumps(summary, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    (output_dir / "HARDWARE_SIMULATION.md").write_text("\n".join(markdown_lines), encoding="utf-8")
    return summary


def build_arg_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description="Run the Stackchan virtual hardware bridge simulator.")
    parser.add_argument(
        "--scenario",
        action="append",
        choices=("reference", "lan-text", "audio-downlink", "arrival-rehearsal", "bridge-kill-recovery", "timeout"),
        help=(
            "Scenario to run. Defaults to reference, lan-text, audio-downlink, "
            "arrival-rehearsal, and bridge-kill-recovery."
        ),
    )
    parser.add_argument("--out-dir", type=Path, help="Optional directory for JSON and serial-like logs.")
    parser.add_argument("--json", action="store_true", help="Print summary JSON to stdout.")
    return parser


def main() -> int:
    args = build_arg_parser().parse_args()
    scenarios = args.scenario or [
        "reference",
        "lan-text",
        "audio-downlink",
        "arrival-rehearsal",
        "bridge-kill-recovery",
    ]
    if args.out_dir:
        summary = write_outputs(args.out_dir, scenarios)
    else:
        summary = run_many(scenarios)
    if args.json or not args.out_dir:
        print(json.dumps(summary, indent=2, sort_keys=True))
    return 0 if summary["status"] == "pass" else 1


if __name__ == "__main__":
    raise SystemExit(main())
