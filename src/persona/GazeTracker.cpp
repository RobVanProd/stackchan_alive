#include "persona/GazeTracker.hpp"

#include <math.h>

namespace stackchan {

namespace {
constexpr uint32_t kFaceHoldMs = 2200;
constexpr uint32_t kSearchEndMs = 8000;
constexpr uint32_t kSighEndMs = 9600;
constexpr uint32_t kSettleEndMs = 12000;
constexpr float kHorizontalDeadzone = 0.06f;
constexpr float kVerticalDeadzone = 0.16f;
constexpr float kYawTrackRateDegPerSec = 28.0f;
constexpr float kPitchTrackRateDegPerSec = 5.0f;
constexpr float kYawOffsetLimitDeg = 35.0f;
constexpr float kPitchOffsetLimitDeg = 8.0f;
constexpr float kYawReturnRateDegPerSec = 3.5f;
constexpr float kPitchReturnRateDegPerSec = 0.75f;
constexpr float kSearchTrackRateDegPerSec = 8.0f;
constexpr float kSearchSweepDeg = 5.5f;
constexpr float kTrackedBaseMotionScale = 0.0f;

float deadzone(float value, float threshold) {
  if (fabsf(value) < threshold) {
    return 0.0f;
  }
  return value;
}
}  // namespace

const char* personLossPhaseName(PersonLossPhase phase) {
  switch (phase) {
    case PersonLossPhase::Hold:
      return "hold";
    case PersonLossPhase::Search:
      return "search";
    case PersonLossPhase::Sigh:
      return "sigh";
    case PersonLossPhase::Settle:
      return "settle";
    case PersonLossPhase::None:
      break;
  }
  return "none";
}

void GazeTracker::reset(uint32_t nowMs) {
  telemetry_ = GazeTrackerTelemetry {};
  lastSeenMs_ = nowMs;
  lostAtMs_ = 0;
  lastApplyMs_ = nowMs;
  lostYawOffsetDeg_ = 0.0f;
  motionOutputActive_ = true;
  telemetry_.motionOutputActive = true;
  hasFixation_ = false;
}

void GazeTracker::setMotionOutputActive(bool active, uint32_t nowMs) {
  if (motionOutputActive_ == active) {
    return;
  }
  motionOutputActive_ = active;
  telemetry_.motionOutputActive = active;
  telemetry_.yawOffsetDeg = 0.0f;
  telemetry_.pitchOffsetDeg = 0.0f;
  lastApplyMs_ = nowMs;
}

void GazeTracker::applyEvent(const RobotEvent& event) {
  if (event.type == EventType::FaceDetected && event.hasPayload) {
    if (hasFixation_ && !telemetry_.tracking && lostAtMs_ != 0) {
      telemetry_.reacquisitions++;
    }
    telemetry_.targetX = constrain(event.x, -1.0f, 1.0f);
    telemetry_.targetY = constrain(event.y, -1.0f, 1.0f);
    telemetry_.faceSize = constrain(event.z, 0.0f, 1.0f);
    telemetry_.presence = max(
        telemetry_.presence,
        constrain(0.72f + telemetry_.faceSize * 0.25f, 0.0f, 1.0f));
    telemetry_.tracking = true;
    lastSeenMs_ = event.timestampMs;
    lostAtMs_ = 0;
    hasFixation_ = true;
    setLossPhase(PersonLossPhase::None, event.timestampMs);
    return;
  }

  if (event.type == EventType::FaceLost) {
    if (telemetry_.tracking) {
      lostAtMs_ = event.timestampMs;
      lostYawOffsetDeg_ = telemetry_.yawOffsetDeg;
      telemetry_.lossEvents++;
    }
    telemetry_.presence = constrain(telemetry_.presence - 0.35f * constrain(event.strength, 0.0f, 1.0f), 0.0f, 1.0f);
    telemetry_.tracking = false;
  }
}

void GazeTracker::apply(RobotFrame& frame, uint32_t nowMs, bool reducedMotion) {
  const float dt = constrain(static_cast<float>(nowMs - lastApplyMs_) * 0.001f, 0.0f, 0.10f);
  lastApplyMs_ = nowMs;
  telemetry_.lastAppliedAtMs = nowMs;
  if (!hasFixation_) {
    setLossPhase(PersonLossPhase::None, nowMs);
    return;
  }

  const uint32_t sinceSeenMs = nowMs - lastSeenMs_;
  const bool activelyTracking = telemetry_.tracking && sinceSeenMs <= kFaceHoldMs;
  if (!activelyTracking && telemetry_.tracking) {
    telemetry_.tracking = false;
    lostAtMs_ = lastSeenMs_ + kFaceHoldMs;
    lostYawOffsetDeg_ = telemetry_.yawOffsetDeg;
    telemetry_.lossEvents++;
  }
  const float motionScale = reducedMotion ? 0.30f : 1.0f;
  const float confidence = constrain(telemetry_.presence, 0.0f, 1.0f);
  const float visualConfidence = confidence * motionScale;
  const float x = deadzone(telemetry_.targetX, kHorizontalDeadzone);
  const float y = deadzone(telemetry_.targetY, kVerticalDeadzone);

  if (activelyTracking) {
    setLossPhase(PersonLossPhase::None, nowMs);
    frame.face.pupilX += x * 0.44f * visualConfidence;
    frame.face.pupilY += y * 0.28f * visualConfidence;
    frame.face.faceX += x * 3.0f * visualConfidence;
    frame.face.faceY += y * 1.2f * visualConfidence;
    if (frame.motion.yawMode == YawMode::Angle && motionOutputActive_) {
      // The camera moves with the head, so integrate image error into a bounded
      // pan/tilt setpoint instead of applying a stateless angle nudge.
      telemetry_.yawOffsetDeg = constrain(
          telemetry_.yawOffsetDeg - x * kYawTrackRateDegPerSec * dt * confidence * motionScale,
          -kYawOffsetLimitDeg,
          kYawOffsetLimitDeg);
      telemetry_.pitchOffsetDeg = constrain(
          telemetry_.pitchOffsetDeg - y * kPitchTrackRateDegPerSec * dt * confidence * motionScale,
          -kPitchOffsetLimitDeg,
          kPitchOffsetLimitDeg);
      frame.motion.yawDeg = frame.motion.yawDeg * kTrackedBaseMotionScale +
                            telemetry_.yawOffsetDeg * motionScale;
      frame.motion.pitchDeg = frame.motion.pitchDeg * kTrackedBaseMotionScale +
                              telemetry_.pitchOffsetDeg * motionScale;
      frame.emotion.focus = max(frame.emotion.focus, 0.92f * confidence);
    }
    return;
  }

  PersonLossPhase phase = PersonLossPhase::Settle;
  if (sinceSeenMs <= kFaceHoldMs) {
    phase = PersonLossPhase::Hold;
  } else if (sinceSeenMs < kSearchEndMs) {
    phase = PersonLossPhase::Search;
  } else if (sinceSeenMs < kSighEndMs) {
    phase = PersonLossPhase::Sigh;
  }
  setLossPhase(phase, nowMs);

  telemetry_.pitchOffsetDeg = approach(
      telemetry_.pitchOffsetDeg, 0.0f, kPitchReturnRateDegPerSec * dt);
  const float basePitchDeg = frame.motion.pitchDeg;
  float choreographyPitchDeg = 0.0f;
  const bool expressionAllowed =
      frame.mode == CharacterMode::Idle || frame.mode == CharacterMode::Attend;

  if (phase == PersonLossPhase::Hold) {
    const float hold = visualConfidence * 0.85f;
    frame.face.pupilX += x * 0.24f * hold;
    frame.face.faceX += x * 1.4f * hold;
    if (motionOutputActive_) {
      telemetry_.yawOffsetDeg = approach(
          telemetry_.yawOffsetDeg, lostYawOffsetDeg_, kYawReturnRateDegPerSec * dt);
    } else {
      telemetry_.yawOffsetDeg = 0.0f;
    }
    frame.emotion.focus = max(frame.emotion.focus, 0.70f * hold);
  } else if (phase == PersonLossPhase::Search) {
    const float searchProgress = static_cast<float>(sinceSeenMs - kFaceHoldMs) / 2600.0f;
    const float sweep = sinf(searchProgress * 2.0f * 3.1415927f);
    const float searchTarget = constrain(
        lostYawOffsetDeg_ + sweep * kSearchSweepDeg * confidence,
        -kYawOffsetLimitDeg,
        kYawOffsetLimitDeg);
    if (motionOutputActive_) {
      telemetry_.yawOffsetDeg = approach(
          telemetry_.yawOffsetDeg, searchTarget, kSearchTrackRateDegPerSec * dt);
    } else {
      telemetry_.yawOffsetDeg = 0.0f;
    }
    if (expressionAllowed) {
      frame.face.pupilX += constrain(x * 0.18f - sweep * 0.14f, -0.30f, 0.30f) * visualConfidence;
      frame.face.faceX += constrain(x * 1.0f - sweep * 0.8f, -2.0f, 2.0f) * visualConfidence;
      frame.face.eyeOpen = min(1.0f, frame.face.eyeOpen + 0.06f * visualConfidence);
      frame.face.browTilt -= 0.08f * visualConfidence;
      frame.emotion.focus = max(frame.emotion.focus, 0.72f * visualConfidence);
    }
  } else {
    telemetry_.yawOffsetDeg = motionOutputActive_
                                  ? approach(telemetry_.yawOffsetDeg,
                                             0.0f,
                                             kYawReturnRateDegPerSec * dt)
                                  : 0.0f;
    if (phase == PersonLossPhase::Sigh && expressionAllowed) {
      const float progress = constrain(
          static_cast<float>(sinceSeenMs - kSearchEndMs) /
              static_cast<float>(kSighEndMs - kSearchEndMs),
          0.0f,
          1.0f);
      const float sigh = sinf(progress * 3.1415927f) * motionScale;
      frame.face.eyeOpen = max(0.25f, frame.face.eyeOpen - 0.30f * sigh);
      frame.face.pupilY += 0.10f * sigh;
      frame.face.browTilt -= 0.12f * sigh;
      frame.face.mouthSmile -= 0.22f * sigh;
      frame.face.mouthOpen += 0.07f * sigh;
      frame.face.faceY += 1.0f * sigh;
      choreographyPitchDeg = 3.2f * sigh;
      frame.emotion.arousal = max(0.0f, frame.emotion.arousal - 0.12f * sigh);
      frame.emotion.focus = max(0.0f, frame.emotion.focus - 0.16f * sigh);
    }
  }

  if (frame.motion.yawMode == YawMode::Angle && motionOutputActive_) {
    frame.motion.yawDeg = frame.motion.yawDeg * kTrackedBaseMotionScale +
                          telemetry_.yawOffsetDeg * motionScale;
    frame.motion.pitchDeg = basePitchDeg + telemetry_.pitchOffsetDeg * motionScale +
                            choreographyPitchDeg;
  }

  telemetry_.presence = approach(
      telemetry_.presence, 0.0f, phase == PersonLossPhase::Settle ? 0.06f : 0.012f);
  if (sinceSeenMs >= kSettleEndMs && telemetry_.presence <= 0.02f &&
      fabsf(telemetry_.yawOffsetDeg) <= 0.20f &&
      fabsf(telemetry_.pitchOffsetDeg) <= 0.20f) {
    hasFixation_ = false;
    telemetry_.yawOffsetDeg = 0.0f;
    telemetry_.pitchOffsetDeg = 0.0f;
    lostAtMs_ = 0;
    setLossPhase(PersonLossPhase::None, nowMs);
  }
}

void GazeTracker::setLossPhase(PersonLossPhase phase, uint32_t nowMs) {
  if (telemetry_.lossPhase == phase) {
    return;
  }
  telemetry_.lossPhase = phase;
  telemetry_.lossPhaseStartedAtMs = nowMs;
  if (phase == PersonLossPhase::Search) {
    telemetry_.searchEntries++;
  } else if (phase == PersonLossPhase::Sigh) {
    telemetry_.sighEntries++;
  }
}

float GazeTracker::approach(float value, float target, float amount) {
  if (value < target) {
    return min(value + amount, target);
  }
  return max(value - amount, target);
}

}  // namespace stackchan
