#pragma once

#include <stdint.h>

namespace stackchan {

enum class WakeCueSequencePhase : uint8_t {
  Idle,
  AwaitingRgbCommit,
  AwaitingAudioPause,
  AwaitingCueStart,
  CuePlaying,
  CueFailed,
  ReadyForCapture,
  Capturing,
};

const char* wakeCueSequencePhaseName(WakeCueSequencePhase phase);

struct WakeCueSequenceTelemetry {
  WakeCueSequencePhase phase = WakeCueSequencePhase::Idle;
  uint32_t detections = 0;
  uint32_t rejectedDetections = 0;
  uint32_t rgbCommits = 0;
  uint32_t cueAttempts = 0;
  uint32_t cueStarts = 0;
  uint32_t cueCompletions = 0;
  uint32_t cueFailures = 0;
  uint32_t cueTimeouts = 0;
  uint32_t audioPauseHandoffs = 0;
  uint32_t capturesStarted = 0;
  uint32_t capturesCompleted = 0;
  uint32_t capturesFailed = 0;
  uint32_t aborts = 0;
  uint32_t orderingViolations = 0;
  uint32_t lastDetectionMs = 0;
  uint32_t lastRgbCommitMs = 0;
  uint32_t lastAudioPausedMs = 0;
  uint32_t lastCueStartMs = 0;
  uint32_t lastCueEndMs = 0;
  uint32_t lastCaptureStartMs = 0;
  uint32_t lastCaptureEndMs = 0;
  uint32_t lastPostCuePreRollSamples = 0;
  uint32_t lastCueDurationMs = 0;
};

class WakeCueSequence {
 public:
  bool begin(uint32_t detectedAtMs);
  bool noteRgbCommitted(uint32_t nowMs);
  bool noteAudioPaused(uint32_t nowMs);
  bool noteCueStarted(uint32_t nowMs,
                      uint32_t expectedDurationMs,
                      uint32_t completionTimeoutMs,
                      bool accepted);
  bool updateCue(uint32_t nowMs, bool speakerPlaying);
  bool noteAudioPauseHandoff(uint32_t nowMs);
  bool noteCaptureStarted(uint32_t nowMs, uint32_t postCuePreRollSamples);
  void finishCapture(uint32_t nowMs, bool succeeded);
  void abort(uint32_t nowMs);

  WakeCueSequencePhase phase() const {
    return telemetry_.phase;
  }

  bool readyForCapture() const {
    return telemetry_.phase == WakeCueSequencePhase::ReadyForCapture;
  }

  const WakeCueSequenceTelemetry& telemetry() const {
    return telemetry_;
  }

 private:
  bool requirePhase(WakeCueSequencePhase expected);
  void completeCue(uint32_t nowMs, bool timedOut);

  WakeCueSequenceTelemetry telemetry_;
  uint32_t cueDeadlineMs_ = 0;
  bool cueObservedPlaying_ = false;
};

}  // namespace stackchan
