#include "wake/WakeCueSequence.hpp"

namespace stackchan {

const char* wakeCueSequencePhaseName(WakeCueSequencePhase phase) {
  switch (phase) {
    case WakeCueSequencePhase::Idle: return "idle";
    case WakeCueSequencePhase::AwaitingRgbCommit: return "awaiting_rgb";
    case WakeCueSequencePhase::AwaitingAudioPause: return "awaiting_audio_pause";
    case WakeCueSequencePhase::AwaitingCueStart: return "awaiting_cue";
    case WakeCueSequencePhase::CuePlaying: return "cue_playing";
    case WakeCueSequencePhase::CueFailed: return "cue_failed";
    case WakeCueSequencePhase::ReadyForCapture: return "ready_for_capture";
    case WakeCueSequencePhase::Capturing: return "capturing";
  }
  return "unknown";
}

bool WakeCueSequence::begin(uint32_t detectedAtMs) {
  if (telemetry_.phase != WakeCueSequencePhase::Idle) {
    ++telemetry_.rejectedDetections;
    return false;
  }
  ++telemetry_.detections;
  telemetry_.lastDetectionMs = detectedAtMs;
  telemetry_.lastRgbCommitMs = 0;
  telemetry_.lastAudioPausedMs = 0;
  telemetry_.lastCueStartMs = 0;
  telemetry_.lastCueEndMs = 0;
  telemetry_.lastCaptureStartMs = 0;
  telemetry_.lastCaptureEndMs = 0;
  telemetry_.lastPostCuePreRollSamples = 0;
  telemetry_.lastCueDurationMs = 0;
  telemetry_.phase = WakeCueSequencePhase::AwaitingRgbCommit;
  cueDeadlineMs_ = 0;
  cueObservedPlaying_ = false;
  return true;
}

bool WakeCueSequence::noteRgbCommitted(uint32_t nowMs) {
  if (!requirePhase(WakeCueSequencePhase::AwaitingRgbCommit)) return false;
  ++telemetry_.rgbCommits;
  telemetry_.lastRgbCommitMs = nowMs;
  telemetry_.phase = WakeCueSequencePhase::AwaitingAudioPause;
  return true;
}

bool WakeCueSequence::noteAudioPaused(uint32_t nowMs) {
  if (!requirePhase(WakeCueSequencePhase::AwaitingAudioPause)) return false;
  telemetry_.lastAudioPausedMs = nowMs;
  telemetry_.phase = WakeCueSequencePhase::AwaitingCueStart;
  return true;
}

bool WakeCueSequence::noteCueStarted(uint32_t nowMs,
                                     uint32_t expectedDurationMs,
                                     uint32_t completionTimeoutMs,
                                     bool accepted) {
  if (!requirePhase(WakeCueSequencePhase::AwaitingCueStart)) return false;
  ++telemetry_.cueAttempts;
  telemetry_.lastCueDurationMs = expectedDurationMs;
  telemetry_.lastCueStartMs = nowMs;
  cueObservedPlaying_ = false;
  if (!accepted) {
    ++telemetry_.cueFailures;
    telemetry_.lastCueEndMs = nowMs;
    telemetry_.phase = WakeCueSequencePhase::CueFailed;
    return true;
  }
  ++telemetry_.cueStarts;
  cueDeadlineMs_ = nowMs + expectedDurationMs + completionTimeoutMs;
  telemetry_.phase = WakeCueSequencePhase::CuePlaying;
  return true;
}

bool WakeCueSequence::updateCue(uint32_t nowMs, bool speakerPlaying) {
  if (telemetry_.phase != WakeCueSequencePhase::CuePlaying) return false;
  cueObservedPlaying_ = cueObservedPlaying_ || speakerPlaying;
  if (cueObservedPlaying_ && !speakerPlaying) {
    completeCue(nowMs, false);
    return true;
  }
  if (static_cast<int32_t>(nowMs - cueDeadlineMs_) >= 0) {
    completeCue(nowMs, true);
    return true;
  }
  return false;
}

bool WakeCueSequence::noteAudioPauseHandoff(uint32_t nowMs) {
  (void)nowMs;
  if (!requirePhase(WakeCueSequencePhase::ReadyForCapture)) return false;
  ++telemetry_.audioPauseHandoffs;
  return true;
}

bool WakeCueSequence::noteCaptureStarted(uint32_t nowMs, uint32_t postCuePreRollSamples) {
  if (!requirePhase(WakeCueSequencePhase::ReadyForCapture)) return false;
  if (telemetry_.lastCueEndMs == 0 ||
      static_cast<int32_t>(nowMs - telemetry_.lastCueEndMs) < 0) {
    ++telemetry_.orderingViolations;
    return false;
  }
  ++telemetry_.capturesStarted;
  telemetry_.lastCaptureStartMs = nowMs;
  telemetry_.lastPostCuePreRollSamples = postCuePreRollSamples;
  telemetry_.phase = WakeCueSequencePhase::Capturing;
  return true;
}

void WakeCueSequence::finishCapture(uint32_t nowMs, bool succeeded) {
  if (!requirePhase(WakeCueSequencePhase::Capturing)) return;
  telemetry_.lastCaptureEndMs = nowMs;
  if (succeeded) ++telemetry_.capturesCompleted;
  else ++telemetry_.capturesFailed;
  telemetry_.phase = WakeCueSequencePhase::Idle;
}

void WakeCueSequence::abort(uint32_t nowMs) {
  ++telemetry_.aborts;
  telemetry_.lastCaptureEndMs = nowMs;
  telemetry_.phase = WakeCueSequencePhase::Idle;
  cueDeadlineMs_ = 0;
  cueObservedPlaying_ = false;
}

bool WakeCueSequence::requirePhase(WakeCueSequencePhase expected) {
  if (telemetry_.phase == expected) return true;
  ++telemetry_.orderingViolations;
  return false;
}

void WakeCueSequence::completeCue(uint32_t nowMs, bool timedOut) {
  ++telemetry_.cueCompletions;
  telemetry_.lastCueEndMs = nowMs;
  if (timedOut) ++telemetry_.cueTimeouts;
  telemetry_.phase = WakeCueSequencePhase::ReadyForCapture;
}

}  // namespace stackchan
