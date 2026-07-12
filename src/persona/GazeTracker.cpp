#include "persona/GazeTracker.hpp"

#include <math.h>

namespace stackchan {

namespace {
constexpr uint32_t kFaceHoldMs = 2200;
constexpr uint32_t kSearchGiveUpMs = 8000;
constexpr float kHorizontalDeadzone = 0.06f;
constexpr float kVerticalDeadzone = 0.16f;
constexpr float kYawTrackRateDegPerSec = 28.0f;
constexpr float kPitchTrackRateDegPerSec = 5.0f;
constexpr float kYawOffsetLimitDeg = 35.0f;
constexpr float kPitchOffsetLimitDeg = 8.0f;
constexpr float kYawReturnRateDegPerSec = 3.5f;
constexpr float kPitchReturnRateDegPerSec = 0.75f;
constexpr float kTrackedBaseMotionScale = 0.0f;

float deadzone(float value, float threshold) {
  if (fabsf(value) < threshold) {
    return 0.0f;
  }
  return value;
}
}  // namespace

void GazeTracker::reset(uint32_t nowMs) {
  telemetry_ = GazeTrackerTelemetry {};
  lastSeenMs_ = nowMs;
  lostAtMs_ = 0;
  lastApplyMs_ = nowMs;
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
    return;
  }

  if (event.type == EventType::FaceLost) {
    lostAtMs_ = event.timestampMs;
    telemetry_.presence = constrain(telemetry_.presence - 0.35f * constrain(event.strength, 0.0f, 1.0f), 0.0f, 1.0f);
    telemetry_.tracking = false;
  }
}

void GazeTracker::apply(RobotFrame& frame, uint32_t nowMs, bool reducedMotion) {
  const float dt = constrain(static_cast<float>(nowMs - lastApplyMs_) * 0.001f, 0.0f, 0.10f);
  lastApplyMs_ = nowMs;
  telemetry_.lastAppliedAtMs = nowMs;
  if (!hasFixation_) {
    return;
  }

  const uint32_t sinceSeenMs = nowMs - lastSeenMs_;
  if (sinceSeenMs > kSearchGiveUpMs) {
    telemetry_.presence = approach(telemetry_.presence, 0.0f, 0.06f);
    telemetry_.yawOffsetDeg = approach(
        telemetry_.yawOffsetDeg, 0.0f, kYawReturnRateDegPerSec * dt);
    telemetry_.pitchOffsetDeg = approach(
        telemetry_.pitchOffsetDeg, 0.0f, kPitchReturnRateDegPerSec * dt);
    if (motionOutputActive_ && frame.motion.yawMode == YawMode::Angle) {
      frame.motion.yawDeg = frame.motion.yawDeg * kTrackedBaseMotionScale + telemetry_.yawOffsetDeg;
      frame.motion.pitchDeg = frame.motion.pitchDeg * kTrackedBaseMotionScale + telemetry_.pitchOffsetDeg;
    }
    if (telemetry_.presence <= 0.02f && fabsf(telemetry_.yawOffsetDeg) <= 0.20f &&
        fabsf(telemetry_.pitchOffsetDeg) <= 0.20f) {
      hasFixation_ = false;
      telemetry_.yawOffsetDeg = 0.0f;
      telemetry_.pitchOffsetDeg = 0.0f;
    }
    return;
  }

  const bool activelyTracking = telemetry_.tracking && sinceSeenMs <= kFaceHoldMs;
  const float motionScale = reducedMotion ? 0.30f : 1.0f;
  const float confidence = constrain(telemetry_.presence, 0.0f, 1.0f);
  const float visualConfidence = confidence * motionScale;
  const float x = deadzone(telemetry_.targetX, kHorizontalDeadzone);
  const float y = deadzone(telemetry_.targetY, kVerticalDeadzone);

  if (activelyTracking) {
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
  } else {
    // Hold a short search glance toward the last seen face before giving up.
    const float search = constrain((kSearchGiveUpMs - sinceSeenMs) / 3000.0f, 0.0f, 1.0f) * visualConfidence;
    frame.face.pupilX += x * 0.24f * search;
    frame.face.faceX += x * 1.4f * search;
    if (frame.motion.yawMode == YawMode::Angle && motionOutputActive_) {
      telemetry_.yawOffsetDeg = approach(
          telemetry_.yawOffsetDeg, 0.0f, kYawReturnRateDegPerSec * dt);
      telemetry_.pitchOffsetDeg = approach(
          telemetry_.pitchOffsetDeg, 0.0f, kPitchReturnRateDegPerSec * dt);
      frame.motion.yawDeg = frame.motion.yawDeg * kTrackedBaseMotionScale +
                            telemetry_.yawOffsetDeg * motionScale;
      frame.motion.pitchDeg = frame.motion.pitchDeg * kTrackedBaseMotionScale +
                              telemetry_.pitchOffsetDeg * motionScale;
      frame.emotion.focus = max(frame.emotion.focus, 0.75f * search);
    }
    telemetry_.presence = approach(telemetry_.presence, 0.0f, 0.012f);
  }
}

float GazeTracker::approach(float value, float target, float amount) {
  if (value < target) {
    return min(value + amount, target);
  }
  return max(value - amount, target);
}

}  // namespace stackchan
