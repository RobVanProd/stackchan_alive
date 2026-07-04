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
import sys
import tempfile
from dataclasses import dataclass, field
from pathlib import Path
from typing import Iterable

from lan_service import LanBridgeConfig, LanBridgeSession
from reference_bridge import AudioBeat, BridgeTurn, bridge_frames

SIM_SCHEMA = "stackchan.hardware-sim.v1"
DEFAULT_TIMEOUT_MS = 2000
DISPLAY_FRAME_MS = 33
MAX_AUDIO_STREAM_CHUNK_BYTES = 4096
AUDIO_DOWNLINK_TEST_BYTES = 5000
AUDIO_UPLOAD_TEST_BYTES = 6400
DOWNLINK_CHECKSUM_SEED = 2166136261
PLAYABLE_DOWNLINK_FORMATS = {"pcm16", "s16le", "raw16", "pcm_s16le"}
SERVO_PITCH_MIN_DEG = -20.0
SERVO_PITCH_MAX_DEG = 20.0
SERVO_YAW_MIN_DEG = -45.0
SERVO_YAW_MAX_DEG = 45.0
SERVO_YAW_MAX_VELOCITY = 0.65


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
    bridge_upload_audio_bytes: int = 0
    bridge_upload_audio_chunks: int = 0
    bridge_upload_sample_rate: int = 0
    bridge_stt_runs: int = 0
    bridge_stt_last_source: str = ""
    offline_fallback_prompts: int = 0
    packaged_prompt_requests: int = 0
    conversation_turns: int = 0
    conversation_first_audio_latency_ms: int = 0
    speech_frames: int = 0
    speech_final_frames: int = 0
    mouth_peak: float = 0.0
    audio_streams_started: int = 0
    audio_streams_ended: int = 0
    audio_streams_aborted: int = 0
    audio_stream_bytes_expected: int = 0
    audio_stream_bytes_received: int = 0
    audio_stream_chunk_bytes_declared: int = 0
    audio_stream_chunk_bytes_max: int = 0
    audio_stream_chunks_expected: int = 0
    audio_stream_chunks_received: int = 0
    bridge_downlink_ready: bool = False
    bridge_downlink_active: bool = False
    bridge_downlink_streams: int = 0
    bridge_downlink_completed: int = 0
    bridge_downlink_aborted: int = 0
    bridge_downlink_chunks: int = 0
    bridge_downlink_bytes: int = 0
    bridge_downlink_errors: int = 0
    bridge_downlink_checksum: int = 0
    bridge_downlink_last_seq: int = 0
    bridge_downlink_expected_bytes: int = 0
    bridge_downlink_expected_chunks: int = 0
    bridge_downlink_received_bytes: int = 0
    bridge_downlink_received_chunks: int = 0
    bridge_downlink_last_payload_bytes: int = 0
    bridge_downlink_playback_ready: bool = False
    bridge_downlink_playback_active: bool = False
    bridge_downlink_playback_starts: int = 0
    bridge_downlink_playback_chunks: int = 0
    bridge_downlink_playback_bytes: int = 0
    bridge_downlink_playback_stops: int = 0
    bridge_downlink_playback_unsupported: int = 0
    bridge_downlink_playback_errors: int = 0
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
    motion_disabled_display_frames: int = 0
    motion_disabled_mouth_frames: int = 0
    servo_ready: bool = False
    servo_attach_count: int = 0
    servo_stop_count: int = 0
    servo_commands: int = 0
    servo_angle_commands: int = 0
    servo_velocity_commands: int = 0
    servo_blocked_commands: int = 0
    servo_clipped_commands: int = 0
    servo_pitch_deg: float = 0.0
    servo_yaw_deg: float = 0.0
    servo_yaw_velocity: float = 0.0
    servo_last_source: str = ""
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
            "bridge_upload_audio_bytes": self.bridge_upload_audio_bytes,
            "bridge_upload_audio_chunks": self.bridge_upload_audio_chunks,
            "bridge_upload_sample_rate": self.bridge_upload_sample_rate,
            "bridge_stt_runs": self.bridge_stt_runs,
            "bridge_stt_last_source": self.bridge_stt_last_source,
            "offline_fallback_prompts": self.offline_fallback_prompts,
            "packaged_prompt_requests": self.packaged_prompt_requests,
            "conversation_turns": self.conversation_turns,
            "conversation_first_audio_latency_ms": self.conversation_first_audio_latency_ms,
            "speech_frames": self.speech_frames,
            "speech_final_frames": self.speech_final_frames,
            "mouth_peak": round(self.mouth_peak, 3),
            "audio_streams_started": self.audio_streams_started,
            "audio_streams_ended": self.audio_streams_ended,
            "audio_streams_aborted": self.audio_streams_aborted,
            "audio_stream_bytes_expected": self.audio_stream_bytes_expected,
            "audio_stream_bytes_received": self.audio_stream_bytes_received,
            "audio_stream_chunk_bytes_declared": self.audio_stream_chunk_bytes_declared,
            "audio_stream_chunk_bytes_max": self.audio_stream_chunk_bytes_max,
            "audio_stream_chunks_expected": self.audio_stream_chunks_expected,
            "audio_stream_chunks_received": self.audio_stream_chunks_received,
            "bridge_downlink_ready": self.bridge_downlink_ready,
            "bridge_downlink_active": self.bridge_downlink_active,
            "bridge_downlink_streams": self.bridge_downlink_streams,
            "bridge_downlink_completed": self.bridge_downlink_completed,
            "bridge_downlink_aborted": self.bridge_downlink_aborted,
            "bridge_downlink_chunks": self.bridge_downlink_chunks,
            "bridge_downlink_bytes": self.bridge_downlink_bytes,
            "bridge_downlink_errors": self.bridge_downlink_errors,
            "bridge_downlink_checksum": self.bridge_downlink_checksum,
            "bridge_downlink_last_seq": self.bridge_downlink_last_seq,
            "bridge_downlink_expected_bytes": self.bridge_downlink_expected_bytes,
            "bridge_downlink_expected_chunks": self.bridge_downlink_expected_chunks,
            "bridge_downlink_received_bytes": self.bridge_downlink_received_bytes,
            "bridge_downlink_received_chunks": self.bridge_downlink_received_chunks,
            "bridge_downlink_last_payload_bytes": self.bridge_downlink_last_payload_bytes,
            "bridge_downlink_playback_ready": self.bridge_downlink_playback_ready,
            "bridge_downlink_playback_active": self.bridge_downlink_playback_active,
            "bridge_downlink_playback_starts": self.bridge_downlink_playback_starts,
            "bridge_downlink_playback_chunks": self.bridge_downlink_playback_chunks,
            "bridge_downlink_playback_bytes": self.bridge_downlink_playback_bytes,
            "bridge_downlink_playback_stops": self.bridge_downlink_playback_stops,
            "bridge_downlink_playback_unsupported": self.bridge_downlink_playback_unsupported,
            "bridge_downlink_playback_errors": self.bridge_downlink_playback_errors,
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
            "motion_disabled_display_frames": self.motion_disabled_display_frames,
            "motion_disabled_mouth_frames": self.motion_disabled_mouth_frames,
            "servo_ready": self.servo_ready,
            "servo_attach_count": self.servo_attach_count,
            "servo_stop_count": self.servo_stop_count,
            "servo_commands": self.servo_commands,
            "servo_angle_commands": self.servo_angle_commands,
            "servo_velocity_commands": self.servo_velocity_commands,
            "servo_blocked_commands": self.servo_blocked_commands,
            "servo_clipped_commands": self.servo_clipped_commands,
            "servo_pitch_deg": round(self.servo_pitch_deg, 3),
            "servo_yaw_deg": round(self.servo_yaw_deg, 3),
            "servo_yaw_velocity": round(self.servo_yaw_velocity, 3),
            "servo_last_source": self.servo_last_source,
            "power_cycles": self.power_cycles,
            "modes_seen": list(self.modes_seen),
        }


@dataclass
class ActiveAudioStream:
    seq: int = 0
    expected_bytes: int = 0
    chunk_bytes: int = 0
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
    conversation_wait_start_ms: int | None = None

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
        self._serial_runtime_status()

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
            if not self.telemetry.bridge_downlink_playback_ready:
                self._record_issue("bridge_downlink_playback_not_ready")
            if self.telemetry.bridge_downlink_playback_active:
                self._record_issue("bridge_downlink_playback_left_active")
            if self.telemetry.bridge_downlink_playback_starts != 1:
                self._record_issue("bridge_downlink_playback_start_count_mismatch")
            if self.telemetry.bridge_downlink_playback_chunks != self.telemetry.audio_stream_chunks_expected:
                self._record_issue("bridge_downlink_playback_chunk_count_mismatch")
            if self.telemetry.bridge_downlink_playback_bytes != self.telemetry.audio_stream_bytes_expected:
                self._record_issue("bridge_downlink_playback_byte_count_mismatch")
            if self.telemetry.bridge_downlink_playback_unsupported != 0:
                self._record_issue("bridge_downlink_playback_unsupported_nonzero")
            if self.telemetry.bridge_downlink_playback_errors != 0:
                self._record_issue("bridge_downlink_playback_error_count_nonzero")
            if self.telemetry.bridge_downlink_streams != 1:
                self._record_issue("bridge_downlink_stream_count_mismatch")
            if self.telemetry.bridge_downlink_completed != 1:
                self._record_issue("bridge_downlink_completion_mismatch")
            if self.telemetry.bridge_downlink_chunks != self.telemetry.audio_stream_chunks_expected:
                self._record_issue("bridge_downlink_chunk_count_mismatch")
            if self.telemetry.bridge_downlink_bytes != self.telemetry.audio_stream_bytes_expected:
                self._record_issue("bridge_downlink_byte_count_mismatch")
            if self.telemetry.bridge_downlink_active:
                self._record_issue("bridge_downlink_left_active")
            if self.telemetry.bridge_downlink_errors != 0:
                self._record_issue("bridge_downlink_error_count_nonzero")
            if self.telemetry.mouth_display_frames <= 0:
                self._record_issue("mouth_never_rendered_during_audio")
        if scenario == "audio-downlink-unsupported":
            if self.telemetry.speaker_playback_starts != 0:
                self._record_issue("unsupported_speaker_playback_started")
            if self.telemetry.speaker_frames_submitted != 0:
                self._record_issue("unsupported_speaker_frames_submitted")
            if not self.telemetry.bridge_downlink_playback_ready:
                self._record_issue("unsupported_bridge_downlink_playback_not_ready")
            if self.telemetry.bridge_downlink_playback_active:
                self._record_issue("unsupported_bridge_downlink_playback_left_active")
            if self.telemetry.bridge_downlink_playback_starts != 0:
                self._record_issue("unsupported_bridge_downlink_playback_started")
            if self.telemetry.bridge_downlink_playback_chunks != 0:
                self._record_issue("unsupported_bridge_downlink_playback_chunks_nonzero")
            if self.telemetry.bridge_downlink_playback_bytes != 0:
                self._record_issue("unsupported_bridge_downlink_playback_bytes_nonzero")
            if self.telemetry.bridge_downlink_playback_unsupported != 1:
                self._record_issue("unsupported_bridge_downlink_playback_count_mismatch")
            if self.telemetry.bridge_downlink_playback_errors != 0:
                self._record_issue("unsupported_bridge_downlink_playback_error_count_nonzero")
            if self.telemetry.bridge_downlink_completed != 1:
                self._record_issue("unsupported_bridge_downlink_completion_mismatch")
            if self.telemetry.bridge_downlink_chunks != self.telemetry.audio_stream_chunks_expected:
                self._record_issue("unsupported_bridge_downlink_chunk_count_mismatch")
            if self.telemetry.bridge_downlink_bytes != self.telemetry.audio_stream_bytes_expected:
                self._record_issue("unsupported_bridge_downlink_byte_count_mismatch")
            if self.telemetry.bridge_downlink_errors != 0:
                self._record_issue("unsupported_bridge_downlink_error_count_nonzero")
        if scenario == "arrival-rehearsal":
            if self.telemetry.boot_count < 2:
                self._record_issue("power_cycle_reboot_not_observed")
            if self.telemetry.core_inputs < 5:
                self._record_issue("core_inputs_not_covered")
            if self.telemetry.control_events < 7:
                self._record_issue("control_events_not_covered")
            if self.telemetry.speaker_playback_starts < 1:
                self._record_issue("arrival_speaker_stream_not_exercised")
            if self.telemetry.bridge_downlink_playback_starts < 1:
                self._record_issue("arrival_bridge_downlink_playback_not_exercised")
            if self.telemetry.bridge_downlink_playback_chunks < 1:
                self._record_issue("arrival_bridge_downlink_playback_chunks_missing")
            if self.telemetry.bridge_downlink_playback_bytes < 1:
                self._record_issue("arrival_bridge_downlink_playback_bytes_missing")
            if self.telemetry.bridge_downlink_playback_unsupported != 0:
                self._record_issue("arrival_bridge_downlink_playback_unsupported_nonzero")
            if self.telemetry.bridge_downlink_playback_errors != 0:
                self._record_issue("arrival_bridge_downlink_playback_error_count_nonzero")
            if self.telemetry.bridge_downlink_streams < 1:
                self._record_issue("arrival_bridge_downlink_not_exercised")
            if self.telemetry.bridge_downlink_completed < 1:
                self._record_issue("arrival_bridge_downlink_not_completed")
            if self.telemetry.bridge_downlink_chunks < 1 or self.telemetry.bridge_downlink_bytes < 1:
                self._record_issue("arrival_bridge_downlink_payload_missing")
            if self.telemetry.bridge_downlink_errors != 0:
                self._record_issue("arrival_bridge_downlink_error_count_nonzero")
            if self.telemetry.mouth_display_frames <= 0:
                self._record_issue("arrival_mouth_display_not_exercised")
            if self.telemetry.power_cycles < 1:
                self._record_issue("power_cycle_not_exercised")
            if self.telemetry.bridge_state != "Ready":
                self._record_issue("arrival_did_not_recover_ready")
            for mode in ("listen", "think", "react", "speak", "concern", "happy", "idle"):
                if mode not in self.telemetry.modes_seen:
                    self._record_issue(f"arrival_mode_not_seen:{mode}")
        if scenario == "servo-safety-rehearsal":
            if not self.telemetry.servo_ready:
                self._record_issue("servo_not_ready")
            if self.telemetry.servo_attach_count < 1:
                self._record_issue("servo_attach_not_observed")
            if self.telemetry.servo_commands < 3:
                self._record_issue("servo_commands_not_covered")
            if self.telemetry.servo_angle_commands < 2:
                self._record_issue("servo_angle_commands_not_covered")
            if self.telemetry.servo_velocity_commands < 1:
                self._record_issue("servo_velocity_commands_not_covered")
            if self.telemetry.servo_clipped_commands < 2:
                self._record_issue("servo_clipping_not_observed")
            if self.telemetry.servo_blocked_commands < 1:
                self._record_issue("servo_blocked_command_not_observed")
            if self.telemetry.servo_stop_count < 1:
                self._record_issue("servo_stop_not_observed")
            if not self.telemetry.motion_enabled:
                self._record_issue("servo_motion_left_disabled")
            if self.telemetry.motion_disabled_display_frames <= 0:
                self._record_issue("display_not_rendered_while_motion_disabled")
            if self.telemetry.motion_disabled_mouth_frames <= 0:
                self._record_issue("mouth_not_rendered_while_motion_disabled")
            if self.telemetry.speaker_playback_starts < 1:
                self._record_issue("servo_safety_speaker_stream_not_exercised")
            if self.telemetry.bridge_state != "Ready":
                self._record_issue("servo_safety_did_not_return_ready")
            if "safety" not in self.telemetry.modes_seen:
                self._record_issue("servo_safety_mode_not_seen")
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
        if scenario == "conversation-rehearsal":
            if self.telemetry.conversation_turns != 1:
                self._record_issue("conversation_turn_not_observed")
            if self.telemetry.conversation_first_audio_latency_ms <= 0:
                self._record_issue("conversation_first_audio_latency_missing")
            if self.telemetry.conversation_first_audio_latency_ms > 2500:
                self._record_issue("conversation_first_audio_latency_over_budget")
            if self.telemetry.core_inputs < 1:
                self._record_issue("conversation_wake_input_not_observed")
            if self.telemetry.bridge_state != "Ready":
                self._record_issue("conversation_did_not_return_ready")
            if self.telemetry.mouth_display_frames <= 0:
                self._record_issue("conversation_mouth_display_not_exercised")
            for mode in ("listen", "think", "happy", "idle"):
                if mode not in self.telemetry.modes_seen:
                    self._record_issue(f"conversation_mode_not_seen:{mode}")
        if scenario == "conversation-tts-downlink":
            if self.telemetry.conversation_turns != 1:
                self._record_issue("conversation_tts_turn_not_observed")
            if self.telemetry.conversation_first_audio_latency_ms <= 0:
                self._record_issue("conversation_tts_first_audio_latency_missing")
            if self.telemetry.conversation_first_audio_latency_ms > 2500:
                self._record_issue("conversation_tts_first_audio_latency_over_budget")
            if self.telemetry.bridge_state != "Ready":
                self._record_issue("conversation_tts_did_not_return_ready")
            if self.telemetry.mouth_display_frames <= 0:
                self._record_issue("conversation_tts_mouth_display_not_exercised")
            if self.telemetry.audio_streams_started != 1:
                self._record_issue("conversation_tts_audio_stream_start_count_mismatch")
            if self.telemetry.audio_streams_ended != 1:
                self._record_issue("conversation_tts_audio_stream_end_count_mismatch")
            if self.telemetry.audio_stream_bytes_received != AUDIO_DOWNLINK_TEST_BYTES:
                self._record_issue("conversation_tts_audio_byte_count_mismatch")
            if self.telemetry.audio_stream_chunks_received != 2:
                self._record_issue("conversation_tts_audio_chunk_count_mismatch")
            if self.telemetry.speaker_playback_starts != 1:
                self._record_issue("conversation_tts_speaker_playback_not_started")
            if self.telemetry.speaker_frames_submitted != 2:
                self._record_issue("conversation_tts_speaker_frame_count_mismatch")
            if self.telemetry.bridge_downlink_streams != 1:
                self._record_issue("conversation_tts_downlink_stream_count_mismatch")
            if self.telemetry.bridge_downlink_completed != 1:
                self._record_issue("conversation_tts_downlink_completion_mismatch")
            if self.telemetry.bridge_downlink_chunks != 2:
                self._record_issue("conversation_tts_downlink_chunk_count_mismatch")
            if self.telemetry.bridge_downlink_bytes != AUDIO_DOWNLINK_TEST_BYTES:
                self._record_issue("conversation_tts_downlink_byte_count_mismatch")
            if self.telemetry.bridge_downlink_errors != 0:
                self._record_issue("conversation_tts_downlink_error_count_nonzero")
            if not self.telemetry.bridge_downlink_playback_ready:
                self._record_issue("conversation_tts_downlink_playback_not_ready")
            if self.telemetry.bridge_downlink_playback_active:
                self._record_issue("conversation_tts_downlink_playback_left_active")
            if self.telemetry.bridge_downlink_playback_starts != 1:
                self._record_issue("conversation_tts_downlink_playback_start_count_mismatch")
            if self.telemetry.bridge_downlink_playback_chunks != 2:
                self._record_issue("conversation_tts_downlink_playback_chunk_count_mismatch")
            if self.telemetry.bridge_downlink_playback_bytes != AUDIO_DOWNLINK_TEST_BYTES:
                self._record_issue("conversation_tts_downlink_playback_byte_count_mismatch")
            if self.telemetry.bridge_downlink_playback_unsupported != 0:
                self._record_issue("conversation_tts_downlink_playback_unsupported_nonzero")
            if self.telemetry.bridge_downlink_playback_errors != 0:
                self._record_issue("conversation_tts_downlink_playback_error_count_nonzero")
            for mode in ("listen", "think", "happy", "idle"):
                if mode not in self.telemetry.modes_seen:
                    self._record_issue(f"conversation_tts_mode_not_seen:{mode}")
        if scenario == "conversation-audio-loop":
            if self.telemetry.conversation_turns != 1:
                self._record_issue("conversation_audio_turn_not_observed")
            if self.telemetry.conversation_first_audio_latency_ms <= 0:
                self._record_issue("conversation_audio_first_audio_latency_missing")
            if self.telemetry.conversation_first_audio_latency_ms > 2500:
                self._record_issue("conversation_audio_first_audio_latency_over_budget")
            if self.telemetry.core_inputs < 1:
                self._record_issue("conversation_audio_wake_input_not_observed")
            if self.telemetry.bridge_state != "Ready":
                self._record_issue("conversation_audio_did_not_return_ready")
            if self.telemetry.bridge_upload_audio_bytes != AUDIO_UPLOAD_TEST_BYTES:
                self._record_issue("conversation_audio_upload_byte_count_mismatch")
            if self.telemetry.bridge_upload_audio_chunks != 2:
                self._record_issue("conversation_audio_upload_chunk_count_mismatch")
            if self.telemetry.bridge_upload_sample_rate != 16000:
                self._record_issue("conversation_audio_upload_sample_rate_mismatch")
            if self.telemetry.bridge_stt_runs != 1:
                self._record_issue("conversation_audio_stt_run_count_mismatch")
            if self.telemetry.bridge_stt_last_source != "cli":
                self._record_issue("conversation_audio_stt_source_mismatch")
            if "Altitude change" not in self.telemetry.response_text:
                self._record_issue("conversation_audio_stt_transcript_not_used")
            if self.telemetry.mouth_display_frames <= 0:
                self._record_issue("conversation_audio_mouth_display_not_exercised")
            if self.telemetry.audio_streams_started != 1:
                self._record_issue("conversation_audio_stream_start_count_mismatch")
            if self.telemetry.audio_streams_ended != 1:
                self._record_issue("conversation_audio_stream_end_count_mismatch")
            if self.telemetry.audio_stream_bytes_received != AUDIO_DOWNLINK_TEST_BYTES:
                self._record_issue("conversation_audio_downlink_byte_count_mismatch")
            if self.telemetry.audio_stream_chunks_received != 2:
                self._record_issue("conversation_audio_downlink_chunk_count_mismatch")
            if self.telemetry.speaker_playback_starts != 1:
                self._record_issue("conversation_audio_speaker_playback_not_started")
            if self.telemetry.speaker_frames_submitted != 2:
                self._record_issue("conversation_audio_speaker_frame_count_mismatch")
            if self.telemetry.bridge_downlink_completed != 1:
                self._record_issue("conversation_audio_downlink_completion_mismatch")
            if self.telemetry.bridge_downlink_bytes != AUDIO_DOWNLINK_TEST_BYTES:
                self._record_issue("conversation_audio_downlink_byte_count_mismatch")
            if self.telemetry.bridge_downlink_errors != 0:
                self._record_issue("conversation_audio_downlink_error_count_nonzero")
            if self.telemetry.bridge_downlink_playback_starts != 1:
                self._record_issue("conversation_audio_playback_start_count_mismatch")
            if self.telemetry.bridge_downlink_playback_bytes != AUDIO_DOWNLINK_TEST_BYTES:
                self._record_issue("conversation_audio_playback_byte_count_mismatch")
            if self.telemetry.bridge_downlink_playback_unsupported != 0:
                self._record_issue("conversation_audio_playback_unsupported_nonzero")
            if self.telemetry.bridge_downlink_playback_errors != 0:
                self._record_issue("conversation_audio_playback_error_count_nonzero")
            for mode in ("listen", "think", "react", "idle"):
                if mode not in self.telemetry.modes_seen:
                    self._record_issue(f"conversation_audio_mode_not_seen:{mode}")
        if scenario == "offline-command-fallback":
            if self.telemetry.bridge_ready:
                self._record_issue("offline_bridge_unexpectedly_ready")
            if self.telemetry.bridge_state != "Disconnected":
                self._record_issue("offline_bridge_state_changed")
            if self.telemetry.packaged_prompt_requests < 4:
                self._record_issue("offline_packaged_prompts_not_covered")
            if self.telemetry.speech_frames <= 0:
                self._record_issue("offline_speech_frames_missing")
            if self.telemetry.mouth_display_frames <= 0:
                self._record_issue("offline_mouth_display_not_exercised")
            for mode in ("listen", "attend", "happy", "sleep", "idle"):
                if mode not in self.telemetry.modes_seen:
                    self._record_issue(f"offline_mode_not_seen:{mode}")

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
            audio_bytes = _int(frame.get("audio_bytes"), 0)
            if audio_bytes > 0:
                self.telemetry.bridge_upload_audio_bytes += audio_bytes
                self.telemetry.bridge_upload_audio_chunks += _int(frame.get("audio_chunks"), 0)
                self.telemetry.bridge_upload_sample_rate = _int(frame.get("audio_sample_rate"), 0)
                stt_source = str(frame.get("stt_command_source") or "").strip()
                if stt_source:
                    self.telemetry.bridge_stt_runs += 1
                    self.telemetry.bridge_stt_last_source = stt_source[:48]
            self._serial(
                "[bridge] type=thinking "
                f"state=Thinking seq={self.telemetry.active_seq} "
                f"upload_audio_bytes={audio_bytes} stt_source={frame.get('stt_command_source', '')}"
            )
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
                self._abort_downlink()
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
        if frame_type == "motion_command":
            self._process_motion_command(frame)
            return
        if frame_type == "power_cycle":
            self._power_cycle()
            return
        if frame_type == "conversation_marker":
            self._process_conversation_marker(frame)
            return
        self._record_error(f"unsupported_frame:{frame_type or 'blank'}")

    def _process_binary(self, payload: bytes) -> None:
        self.telemetry.outputs_queued += 1
        self.last_activity_ms = self.now_ms
        if self.active_stream is None:
            self._record_error("binary_without_audio_stream")
            return
        if len(payload) > MAX_AUDIO_STREAM_CHUNK_BYTES:
            self.active_stream = None
            self._record_error("audio_stream_chunk_too_large")
            return
        next_bytes = self.active_stream.received_bytes + len(payload)
        next_chunks = self.active_stream.received_chunks + 1
        if self.active_stream.expected_bytes and next_bytes > self.active_stream.expected_bytes:
            self._fail_downlink()
            self.active_stream = None
            self._record_error("audio_stream_payload_bytes_overrun")
            return
        if self.active_stream.expected_chunks and next_chunks > self.active_stream.expected_chunks:
            self._fail_downlink()
            self.active_stream = None
            self._record_error("audio_stream_payload_chunks_overrun")
            return
        self.active_stream.received_bytes += len(payload)
        self.active_stream.received_chunks += 1
        self.telemetry.audio_stream_bytes_received += len(payload)
        self.telemetry.audio_stream_chunk_bytes_max = max(
            self.telemetry.audio_stream_chunk_bytes_max, len(payload)
        )
        self.telemetry.audio_stream_chunks_received += 1
        self._accept_downlink_chunk(payload)
        self._serial(
            "[bridge] type=audio_binary "
            f"state={self.telemetry.bridge_state} seq={self.active_stream.seq} bytes={len(payload)}"
        )

    def _start_audio_stream(self, frame: dict[str, object]) -> None:
        if self.active_stream is not None:
            self._record_error("nested_audio_stream")
            return
        chunk_bytes = max(0, _int(frame.get("chunk_bytes"), 0))
        if chunk_bytes > MAX_AUDIO_STREAM_CHUNK_BYTES:
            self._record_error("audio_stream_chunk_too_large")
            return
        stream = ActiveAudioStream(
            seq=_int(frame.get("seq"), self.telemetry.active_seq),
            expected_bytes=max(0, _int(frame.get("audio_bytes"), 0)),
            chunk_bytes=chunk_bytes,
            expected_chunks=max(0, _int(frame.get("chunks"), 0)),
            format=str(frame.get("format") or "binary")[:16],
            sample_rate=max(0, _int(frame.get("sample_rate"), 0)),
        )
        self.active_stream = stream
        self.telemetry.audio_streams_started += 1
        self.telemetry.audio_stream_bytes_expected += stream.expected_bytes
        self.telemetry.audio_stream_chunk_bytes_declared = max(
            self.telemetry.audio_stream_chunk_bytes_declared, stream.chunk_bytes
        )
        self.telemetry.audio_stream_chunks_expected += stream.expected_chunks
        self._start_downlink(stream)
        self.telemetry.bridge_state = "Responding"
        self._serial(
            "[bridge] type=audio_stream_start "
            f"state=Responding seq={stream.seq} format={stream.format} bytes={stream.expected_bytes} "
            f"chunk_bytes={stream.chunk_bytes} chunks={stream.expected_chunks} "
            f"sample_rate={stream.sample_rate}"
        )

    def _end_audio_stream(self, frame: dict[str, object]) -> None:
        if self.active_stream is None:
            self._record_error("audio_stream_end_without_start")
            return
        stream = self.active_stream
        end_bytes = max(0, _int(frame.get("audio_bytes"), stream.expected_bytes))
        end_chunks = max(0, _int(frame.get("chunks"), stream.expected_chunks))
        downlink_end_failed = False
        if end_bytes != stream.expected_bytes:
            self._record_error("audio_stream_end_bytes_mismatch")
            downlink_end_failed = True
        if end_chunks != stream.expected_chunks:
            self._record_error("audio_stream_end_chunks_mismatch")
            downlink_end_failed = True
        if stream.received_bytes != stream.expected_bytes:
            self._record_error("audio_stream_payload_bytes_mismatch")
            downlink_end_failed = True
        if stream.received_chunks != stream.expected_chunks:
            self._record_error("audio_stream_payload_chunks_mismatch")
            downlink_end_failed = True
        self.telemetry.audio_streams_ended += 1
        self._end_downlink(failed=downlink_end_failed)
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
        if self.conversation_wait_start_ms is not None and self.telemetry.conversation_first_audio_latency_ms == 0:
            self.telemetry.conversation_first_audio_latency_ms = max(1, self.now_ms - self.conversation_wait_start_ms)
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
        next_motion_enabled: bool | None = None
        if command == "shake":
            mode = "concern"
            event = "Shaken"
            next_motion_enabled = False
        elif command == "putdown":
            mode = "idle"
            event = "PutDown"
            next_motion_enabled = True
        elif command in {"safe_stop", "stop_moving", "motion_stop"}:
            mode = "safety"
            event = "SafetyStop"
            next_motion_enabled = False
        elif command in {"safe_resume", "motion_resume"}:
            mode = "idle"
            event = "SafetyResume"
            next_motion_enabled = True
        elif command == "look_at_me":
            mode = "attend"
            event = "ExplicitCommand"
            self._packaged_prompt("attend", "Looking right at you.")
        elif command == "how_do_you_feel":
            mode = "happy"
            event = "ExplicitCommand"
            self._packaged_prompt("happy", "I feel awake and curious.")
        elif command == "go_to_sleep":
            mode = "sleep"
            event = "ExplicitCommand"
            self._packaged_prompt("sleep", "Going quiet now.")
        elif command == "wake_up":
            mode = "idle"
            event = "WakeWord"
            self._packaged_prompt("boot", "I am awake.")
        else:
            self._record_error(f"unsupported_control_command:{command or 'blank'}")
            return
        self.telemetry.control_events += 1
        if next_motion_enabled is not None:
            self._set_motion_enabled(next_motion_enabled, command)
        self._set_face_mode(mode)
        self._serial(
            "[control] "
            f"command={command} mode={mode} event={event} strength={strength:.2f} "
            f"motion_enabled={int(self.telemetry.motion_enabled)} at_ms={self.now_ms}"
        )

    def _process_motion_command(self, frame: dict[str, object]) -> None:
        source = str(frame.get("source") or "sim").strip().lower()[:40] or "sim"
        yaw_mode = str(frame.get("yaw_mode") or frame.get("mode") or "angle").strip().lower()
        pitch_requested = _float(
            _first_value(frame, "pitch_deg", "pitch", default=self.telemetry.servo_pitch_deg),
            self.telemetry.servo_pitch_deg,
        )
        if not self.telemetry.motion_enabled:
            self.telemetry.servo_blocked_commands += 1
            self._serial(
                "[servo] blocked "
                f"source={source} pitch_request={pitch_requested:.2f} "
                f"yaw_mode={yaw_mode} motion_enabled=0"
            )
            return

        clipped = False
        pitch_cmd = _clamp_float(pitch_requested, SERVO_PITCH_MIN_DEG, SERVO_PITCH_MAX_DEG)
        clipped = clipped or pitch_cmd != pitch_requested
        self.telemetry.servo_pitch_deg = pitch_cmd
        self.telemetry.servo_last_source = source

        if yaw_mode in {"angle", "position", "pos"}:
            yaw_requested = _float(
                _first_value(frame, "yaw_deg", "yaw", default=self.telemetry.servo_yaw_deg),
                self.telemetry.servo_yaw_deg,
            )
            yaw_cmd = _clamp_float(yaw_requested, SERVO_YAW_MIN_DEG, SERVO_YAW_MAX_DEG)
            clipped = clipped or yaw_cmd != yaw_requested
            self.telemetry.servo_yaw_deg = yaw_cmd
            self.telemetry.servo_yaw_velocity = 0.0
            self.telemetry.servo_angle_commands += 1
            detail = f"yaw={yaw_cmd:.2f} yaw_request={yaw_requested:.2f}"
        elif yaw_mode in {"velocity", "vel"}:
            yaw_velocity_requested = _float(
                _first_value(frame, "yaw_velocity", "yaw_vel", "velocity", default=0.0),
                0.0,
            )
            yaw_velocity_cmd = _clamp_float(
                yaw_velocity_requested,
                -SERVO_YAW_MAX_VELOCITY,
                SERVO_YAW_MAX_VELOCITY,
            )
            clipped = clipped or yaw_velocity_cmd != yaw_velocity_requested
            self.telemetry.servo_yaw_velocity = yaw_velocity_cmd
            self.telemetry.servo_velocity_commands += 1
            detail = f"yaw_velocity={yaw_velocity_cmd:.2f} yaw_velocity_request={yaw_velocity_requested:.2f}"
        elif yaw_mode in {"disabled", "off", "none"}:
            self.telemetry.servo_yaw_velocity = 0.0
            detail = "yaw_disabled=1"
        else:
            self._record_error(f"unsupported_motion_yaw_mode:{yaw_mode or 'blank'}")
            return

        self.telemetry.servo_commands += 1
        if clipped:
            self.telemetry.servo_clipped_commands += 1
        self._serial(
            "[servo] command "
            f"source={source} pitch={pitch_cmd:.2f} pitch_request={pitch_requested:.2f} "
            f"yaw_mode={yaw_mode} {detail} clipped={int(clipped)} "
            f"motion_enabled={int(self.telemetry.motion_enabled)}"
        )

    def _set_motion_enabled(self, enabled: bool, reason: str) -> None:
        if not enabled:
            self.telemetry.servo_stop_count += 1
            self.telemetry.servo_pitch_deg = 0.0
            self.telemetry.servo_yaw_deg = 0.0
            self.telemetry.servo_yaw_velocity = 0.0
        self.telemetry.motion_enabled = enabled
        self._serial(
            "[motion] "
            f"enabled={int(enabled)} reason={reason} servo_stops={self.telemetry.servo_stop_count}"
        )

    def _packaged_prompt(self, intent: str, text: str) -> None:
        self.telemetry.packaged_prompt_requests += 1
        self.telemetry.speech_frames += 1
        self.telemetry.speech_final_frames += 1
        self.telemetry.mouth_peak = max(self.telemetry.mouth_peak, 0.58)
        self.telemetry.response_text = text[:160]
        self.mouth_env = 0.58
        self.speech_active = True
        self._serial(
            "[speech] "
            f"seq={self.telemetry.active_seq} intent={intent} earcon=confirm "
            f'text="{text}" source=packaged_prompt'
        )

    def _process_conversation_marker(self, frame: dict[str, object]) -> None:
        marker = str(frame.get("marker") or "").strip().lower()
        if marker != "utterance_end":
            self._record_error(f"unsupported_conversation_marker:{marker or 'blank'}")
            return
        self.telemetry.conversation_turns += 1
        self.conversation_wait_start_ms = self.now_ms
        self.telemetry.conversation_first_audio_latency_ms = 0
        self._serial(f"[conversation] marker=utterance_end turns={self.telemetry.conversation_turns}")

    def _boot(self) -> None:
        self.telemetry.boot_count += 1
        self.telemetry.display_ready = True
        self.telemetry.speaker_ready = True
        self.telemetry.servo_ready = True
        self.telemetry.servo_attach_count += 1
        self.telemetry.servo_pitch_deg = 0.0
        self.telemetry.servo_yaw_deg = 0.0
        self.telemetry.servo_yaw_velocity = 0.0
        self.telemetry.bridge_downlink_ready = True
        self.telemetry.bridge_downlink_active = False
        self.telemetry.bridge_downlink_playback_ready = self.telemetry.speaker_ready
        self.telemetry.bridge_downlink_playback_active = False
        self.telemetry.bridge_state = "Disconnected"
        self._set_face_mode("idle")
        self.display_next_ms = self.now_ms
        self.display_last_frame_ms = None
        self.mouth_env = 0.0
        self.speech_active = False
        self._serial("[system] boot virtual_core_s3=1 firmware=stackchan_alive")
        self._serial("[display] M5 display renderer ready canvas=double-buffered")
        self._serial("[audio_out] hw_ready=1 hw_playing=0 source=virtual_speaker")
        self._serial("[servo] virtual actuator ready pitch=0.00 yaw=0.00 motion_enabled=1")

    def _power_cycle(self) -> None:
        if self.active_stream is not None:
            self._record_issue("power_cycle_with_audio_stream_active")
            self._abort_downlink()
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
            if not self.telemetry.motion_enabled:
                self.telemetry.motion_disabled_display_frames += 1
                if self.mouth_env > 0.02:
                    self.telemetry.motion_disabled_mouth_frames += 1
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

    def _start_downlink(self, stream: ActiveAudioStream) -> None:
        if not self.telemetry.bridge_downlink_ready or self.telemetry.bridge_downlink_active:
            self._fail_downlink()
            return
        self.telemetry.bridge_downlink_active = True
        self.telemetry.bridge_downlink_streams += 1
        self.telemetry.bridge_downlink_last_seq = stream.seq
        self.telemetry.bridge_downlink_expected_bytes = stream.expected_bytes
        self.telemetry.bridge_downlink_expected_chunks = stream.expected_chunks
        self.telemetry.bridge_downlink_received_bytes = 0
        self.telemetry.bridge_downlink_received_chunks = 0
        self.telemetry.bridge_downlink_last_payload_bytes = 0
        self.telemetry.bridge_downlink_checksum = 0
        self._start_downlink_playback(stream)

    def _accept_downlink_chunk(self, payload: bytes) -> None:
        if not self.telemetry.bridge_downlink_ready or not self.telemetry.bridge_downlink_active:
            self._fail_downlink()
            return
        self.telemetry.bridge_downlink_chunks += 1
        self.telemetry.bridge_downlink_bytes += len(payload)
        self.telemetry.bridge_downlink_received_bytes += len(payload)
        self.telemetry.bridge_downlink_received_chunks += 1
        self.telemetry.bridge_downlink_last_payload_bytes = len(payload)
        self.telemetry.bridge_downlink_checksum = _update_downlink_checksum(
            self.telemetry.bridge_downlink_checksum,
            payload,
        )
        self._accept_downlink_playback_chunk(payload)

    def _end_downlink(self, failed: bool) -> None:
        if not self.telemetry.bridge_downlink_ready or not self.telemetry.bridge_downlink_active:
            self._fail_downlink()
            return
        if failed:
            self._stop_downlink_playback()
            self._fail_downlink()
        else:
            self.telemetry.bridge_downlink_completed += 1
            self._stop_downlink_playback()
        self.telemetry.bridge_downlink_active = False

    def _abort_downlink(self) -> None:
        if self.telemetry.bridge_downlink_active:
            self.telemetry.bridge_downlink_aborted += 1
        self._stop_downlink_playback()
        self.telemetry.bridge_downlink_active = False

    def _fail_downlink(self) -> None:
        self.telemetry.bridge_downlink_errors += 1

    def _start_downlink_playback(self, stream: ActiveAudioStream) -> None:
        self.telemetry.bridge_downlink_playback_active = False
        if not self.telemetry.bridge_downlink_playback_ready:
            self.telemetry.bridge_downlink_playback_errors += 1
            return
        if stream.format not in PLAYABLE_DOWNLINK_FORMATS or stream.sample_rate <= 0:
            self.telemetry.bridge_downlink_playback_unsupported += 1
            return
        self.telemetry.bridge_downlink_playback_active = True
        self.telemetry.bridge_downlink_playback_starts += 1
        self.telemetry.speaker_playback_starts += 1

    def _accept_downlink_playback_chunk(self, payload: bytes) -> None:
        if not self.telemetry.bridge_downlink_playback_active:
            return
        self.telemetry.bridge_downlink_playback_chunks += 1
        self.telemetry.bridge_downlink_playback_bytes += len(payload)
        self.telemetry.speaker_frames_submitted += 1

    def _stop_downlink_playback(self) -> None:
        if not self.telemetry.bridge_downlink_playback_active:
            return
        self.telemetry.bridge_downlink_playback_active = False
        self.telemetry.bridge_downlink_playback_stops += 1

    def _serial_runtime_status(self) -> None:
        self._serial(
            "[runtime] "
            f"bridge_ready={int(self.telemetry.bridge_ready)} "
            f"bridge_state={self.telemetry.bridge_state} "
            f"bridge_messages={self.telemetry.inbound_messages} "
            f"bridge_outputs={self.telemetry.outputs_queued} "
            f"bridge_parse_errors={self.telemetry.parse_errors} "
            f"bridge_audio_stream_bytes_received={self.telemetry.audio_stream_bytes_received} "
            f"bridge_audio_stream_chunks={self.telemetry.audio_stream_chunks_received} "
            f"bridge_audio_stream_errors={self.telemetry.audio_streams_aborted + self.telemetry.parse_errors} "
            f"bridge_downlink_ready={int(self.telemetry.bridge_downlink_ready)} "
            f"bridge_downlink_active={int(self.telemetry.bridge_downlink_active)} "
            f"bridge_downlink_streams={self.telemetry.bridge_downlink_streams} "
            f"bridge_downlink_completed={self.telemetry.bridge_downlink_completed} "
            f"bridge_downlink_chunks={self.telemetry.bridge_downlink_chunks} "
            f"bridge_downlink_bytes={self.telemetry.bridge_downlink_bytes} "
            f"bridge_downlink_errors={self.telemetry.bridge_downlink_errors} "
            f"bridge_downlink_playback_ready={int(self.telemetry.bridge_downlink_playback_ready)} "
            f"bridge_downlink_playback_active={int(self.telemetry.bridge_downlink_playback_active)} "
            f"bridge_downlink_playback_starts={self.telemetry.bridge_downlink_playback_starts} "
            f"bridge_downlink_playback_chunks={self.telemetry.bridge_downlink_playback_chunks} "
            f"bridge_downlink_playback_bytes={self.telemetry.bridge_downlink_playback_bytes} "
            f"bridge_downlink_playback_unsupported={self.telemetry.bridge_downlink_playback_unsupported} "
            f"bridge_downlink_playback_errors={self.telemetry.bridge_downlink_playback_errors} "
            f"motion_enabled={int(self.telemetry.motion_enabled)} "
            f"servo_ready={int(self.telemetry.servo_ready)} "
            f"servo_commands={self.telemetry.servo_commands} "
            f"servo_blocked_commands={self.telemetry.servo_blocked_commands} "
            f"servo_clipped_commands={self.telemetry.servo_clipped_commands} "
            f"servo_stops={self.telemetry.servo_stop_count} "
            f"bridge_timeouts={self.telemetry.timeouts}"
        )


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


def _first_value(frame: dict[str, object], *keys: str, default: object = None) -> object:
    for key in keys:
        if key in frame:
            return frame.get(key)
    return default


def _clamp_float(value: float, minimum: float, maximum: float) -> float:
    return max(minimum, min(maximum, value))


def _update_downlink_checksum(checksum: int, payload: bytes) -> int:
    result = DOWNLINK_CHECKSUM_SEED if checksum == 0 else checksum
    for value in payload:
        result ^= value
        result = (result * 16777619) & 0xFFFFFFFF
    return result


def full_audio_downlink_frames(audio_format: str = "pcm16") -> list[Frame]:
    payload = bytes(index % 251 for index in range(AUDIO_DOWNLINK_TEST_BYTES))
    chunks = [
        payload[index : index + MAX_AUDIO_STREAM_CHUNK_BYTES]
        for index in range(0, len(payload), MAX_AUDIO_STREAM_CHUNK_BYTES)
    ]
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
                        "format": audio_format,
                        "sample_rate": 22050,
                        "audio_bytes": len(payload),
                        "chunk_bytes": MAX_AUDIO_STREAM_CHUNK_BYTES,
                        "chunks": len(chunks),
                    },
                    *chunks,
                    {
                        "type": "audio_stream_end",
                        "seq": turn.seq,
                        "audio_bytes": len(payload),
                        "chunks": len(chunks),
                    },
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


def servo_safety_rehearsal_frames() -> list[Frame]:
    frames: list[Frame] = [
        {"type": "hello", "protocol": "stackchan.bridge.v1", "session": "servo-safety"},
        {"type": "motion_command", "source": "self_test", "pitch_deg": 8.0, "yaw_deg": 16.0},
        {"type": "motion_command", "source": "clip_probe", "pitch_deg": 36.0, "yaw_deg": 72.0},
        {"type": "control_command", "command": "safe_stop"},
        {"type": "motion_command", "source": "blocked_probe", "pitch_deg": -10.0, "yaw_deg": -24.0},
    ]
    frames.extend(full_audio_downlink_frames()[1:])
    frames.extend(
        [
            {"type": "control_command", "command": "safe_resume"},
            {"type": "motion_command", "source": "resume_probe", "pitch_deg": -7.0, "yaw_deg": -18.0},
            {
                "type": "motion_command",
                "source": "velocity_probe",
                "pitch_deg": 2.0,
                "yaw_mode": "velocity",
                "yaw_velocity": 1.25,
            },
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


def conversation_rehearsal_frames() -> list[Frame]:
    frames: list[Frame] = [
        {"type": "control_input", "input": "btn_a"},
        {"type": "conversation_marker", "marker": "utterance_end"},
    ]
    frames.extend(lan_text_frames())
    return frames


def conversation_tts_downlink_frames() -> list[Frame]:
    frames: list[Frame] = [
        {"type": "control_input", "input": "btn_a"},
        {"type": "conversation_marker", "marker": "utterance_end"},
    ]
    frames.extend(lan_tts_downlink_frames())
    return frames


def conversation_audio_loop_frames() -> list[Frame]:
    frames: list[Frame] = [
        {"type": "control_input", "input": "btn_a"},
        {"type": "conversation_marker", "marker": "utterance_end"},
    ]
    frames.extend(lan_audio_loop_frames())
    return frames


def offline_command_fallback_frames() -> list[Frame]:
    return [
        {"type": "control_input", "input": "btn_a"},
        {"type": "control_command", "command": "look_at_me"},
        {"type": "control_command", "command": "how_do_you_feel"},
        {"type": "control_command", "command": "go_to_sleep"},
        {"type": "control_command", "command": "wake_up"},
    ]


def reference_frames() -> list[Frame]:
    return list(bridge_frames(BridgeTurn(session="sim", seq=7)))


def bridge_command_env() -> dict[str, str | None]:
    return {
        key: os.environ.get(key)
        for key in (
            "STACKCHAN_GEMMA4_E2B_GGUF_COMMAND",
            "STACKCHAN_GEMMA4_E2B_LITERT_COMMAND",
            "STACKCHAN_GEMMA4_E4B_GGUF_COMMAND",
            "STACKCHAN_MODEL_COMMAND",
            "STACKCHAN_STT_COMMAND",
            "STACKCHAN_TTS_COMMAND",
        )
    }


def restore_bridge_command_env(old_env: dict[str, str | None]) -> None:
    for key, value in old_env.items():
        if value is None:
            os.environ.pop(key, None)
        else:
            os.environ[key] = value


def lan_text_frames(tts_command: str = "") -> list[Frame]:
    old_env = bridge_command_env()
    try:
        for key in old_env:
            os.environ[key] = ""
        session = LanBridgeSession(
            LanBridgeConfig(
                runner_case="greeting",
                tts_command=tts_command,
                downlink_audio_chunk_bytes=MAX_AUDIO_STREAM_CHUNK_BYTES,
            )
        )
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
        restore_bridge_command_env(old_env)


def write_fake_tts_wav_script(temp_dir: Path) -> str:
    script = temp_dir / "fake_tts_wav.py"
    script.write_text(
        "\n".join(
            [
                "import base64",
                "import io",
                "import json",
                "import sys",
                "import wave",
                "text = sys.stdin.buffer.read().decode('utf-8')",
                "samples = bytearray()",
                "for index in range(2500):",
                "    sample = ((index * 137) % 24000) - 12000",
                "    samples.extend(int(sample).to_bytes(2, 'little', signed=True))",
                "buffer = io.BytesIO()",
                "with wave.open(buffer, 'wb') as wav:",
                "    wav.setnchannels(1)",
                "    wav.setsampwidth(2)",
                "    wav.setframerate(22050)",
                "    wav.writeframes(bytes(samples))",
                "print(json.dumps({",
                "    'audio_format': 'wav',",
                "    'audio_b64': base64.b64encode(buffer.getvalue()).decode('ascii'),",
                "    'beats': [",
                "        {'env': 0.20, 'viseme': 'neutral', 'duration_ms': 40},",
                "        {'env': 0.72, 'viseme': 'ah', 'duration_ms': 70},",
                "        {'env': 0.58, 'viseme': 'ee', 'duration_ms': 60},",
                "        {'env': 0.12, 'viseme': 'neutral', 'duration_ms': 40},",
                "    ],",
                "}))",
            ]
        ),
        encoding="utf-8",
    )
    return f'"{sys.executable}" "{script}"'


def write_fake_stt_script(temp_dir: Path) -> str:
    script = temp_dir / "fake_stt.py"
    script.write_text(
        "\n".join(
            [
                "import os",
                "import sys",
                "payload = sys.stdin.buffer.read()",
                "assert os.environ['STACKCHAN_AUDIO_SAMPLE_RATE'] == '16000'",
                "assert os.environ['STACKCHAN_AUDIO_FORMAT'] == 's16le_mono'",
                "assert os.environ['STACKCHAN_AUDIO_BYTES'] == str(len(payload))",
                "print('I picked you up gently.')",
            ]
        ),
        encoding="utf-8",
    )
    return f'"{sys.executable}" "{script}"'


def lan_tts_downlink_frames() -> list[Frame]:
    with tempfile.TemporaryDirectory() as temp_dir:
        command = write_fake_tts_wav_script(Path(temp_dir))
        return lan_text_frames(tts_command=command)


def lan_audio_loop_frames() -> list[Frame]:
    old_env = bridge_command_env()
    with tempfile.TemporaryDirectory() as temp_dir:
        temp_path = Path(temp_dir)
        stt_command = write_fake_stt_script(temp_path)
        tts_command = write_fake_tts_wav_script(temp_path)
        try:
            for key in old_env:
                os.environ[key] = ""
            session = LanBridgeSession(
                LanBridgeConfig(
                    runner_case="greeting",
                    stt_command=stt_command,
                    tts_command=tts_command,
                    downlink_audio_chunk_bytes=MAX_AUDIO_STREAM_CHUNK_BYTES,
                )
            )
            payload = bytes((index * 17) % 256 for index in range(AUDIO_UPLOAD_TEST_BYTES))
            upload_chunks = [
                payload[index : index + AUDIO_UPLOAD_TEST_BYTES // 2]
                for index in range(0, len(payload), AUDIO_UPLOAD_TEST_BYTES // 2)
            ]
            frames: list[Frame] = []
            frames.extend(session.handle_text(json.dumps({"type": "hello", "device_id": "stackchan-audio-sim"})))
            frames.extend(session.handle_text(json.dumps({"type": "utterance_start", "sample_rate": 16000})))
            for chunk in upload_chunks:
                frames.extend(session.handle_binary(chunk))
            frames.extend(session.handle_text(json.dumps({"type": "utterance_end", "seq": 31})))
            return frames
        finally:
            restore_bridge_command_env(old_env)


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
    if name == "conversation-rehearsal":
        return conversation_rehearsal_frames(), None
    if name == "conversation-tts-downlink":
        return conversation_tts_downlink_frames(), None
    if name == "conversation-audio-loop":
        return conversation_audio_loop_frames(), None
    if name == "audio-downlink":
        return full_audio_downlink_frames(), None
    if name == "audio-downlink-unsupported":
        return full_audio_downlink_frames("wav"), None
    if name == "arrival-rehearsal":
        return arrival_rehearsal_frames(), None
    if name == "servo-safety-rehearsal":
        return servo_safety_rehearsal_frames(), None
    if name == "bridge-kill-recovery":
        return bridge_kill_recovery_frames(), None
    if name == "offline-command-fallback":
        return offline_command_fallback_frames(), None
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
    if frame.get("type") == "conversation_marker":
        return 20
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
                f"- Packaged prompts: {telemetry['packaged_prompt_requests']}",
                f"- Conversation turns: {telemetry['conversation_turns']}",
                f"- First audio latency: {telemetry['conversation_first_audio_latency_ms']} ms",
                f"- Display frames: {telemetry['display_frames']} (max gap {telemetry['display_frame_gap_max_ms']} ms)",
                f"- Controls: {telemetry['control_events']} total / {telemetry['core_inputs']} CoreS3 inputs",
                f"- Servo safety: ready={int(telemetry['servo_ready'])} "
                f"commands={telemetry['servo_commands']} "
                f"blocked={telemetry['servo_blocked_commands']} "
                f"clipped={telemetry['servo_clipped_commands']} "
                f"stops={telemetry['servo_stop_count']} "
                f"motion_disabled_display_frames={telemetry['motion_disabled_display_frames']} "
                f"motion_disabled_mouth_frames={telemetry['motion_disabled_mouth_frames']}",
                f"- Audio streams: {telemetry['audio_streams_started']} started / {telemetry['audio_streams_ended']} ended",
                f"- Audio bytes: {telemetry['audio_stream_bytes_received']} received",
                f"- Bridge downlink: {telemetry['bridge_downlink_streams']} streams / "
                f"{telemetry['bridge_downlink_completed']} completed / "
                f"{telemetry['bridge_downlink_chunks']} chunks / "
                f"{telemetry['bridge_downlink_bytes']} bytes / "
                f"{telemetry['bridge_downlink_errors']} errors",
                f"- Downlink playback: {telemetry['bridge_downlink_playback_starts']} starts / "
                f"{telemetry['bridge_downlink_playback_chunks']} chunks / "
                f"{telemetry['bridge_downlink_playback_bytes']} bytes / "
                f"{telemetry['bridge_downlink_playback_unsupported']} unsupported / "
                f"{telemetry['bridge_downlink_playback_errors']} errors",
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
        choices=(
            "reference",
            "lan-text",
            "conversation-rehearsal",
            "conversation-tts-downlink",
            "conversation-audio-loop",
            "audio-downlink",
            "audio-downlink-unsupported",
            "arrival-rehearsal",
            "servo-safety-rehearsal",
            "bridge-kill-recovery",
            "offline-command-fallback",
            "timeout",
        ),
        help=(
            "Scenario to run. Defaults to reference, lan-text, conversation-rehearsal, "
            "conversation-tts-downlink, conversation-audio-loop, audio-downlink, "
            "audio-downlink-unsupported, arrival-rehearsal, "
            "servo-safety-rehearsal, bridge-kill-recovery, and offline-command-fallback."
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
        "conversation-rehearsal",
        "conversation-tts-downlink",
        "conversation-audio-loop",
        "audio-downlink",
        "audio-downlink-unsupported",
        "arrival-rehearsal",
        "servo-safety-rehearsal",
        "bridge-kill-recovery",
        "offline-command-fallback",
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
