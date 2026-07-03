#include "persona/GazeTracker.hpp"

#include <math.h>

namespace stackchan {

namespace {
constexpr uint32_t kFaceHoldMs = 2200;
constexpr uint32_t kSearchGiveUpMs = 5200;
constexpr float kCenterDeadzone = 0.06f;

float deadzone(float value) {
  if (fabsf(value) < kCenterDeadzone) {
    return 0.0f;
  }
  return value;
}
}  // namespace

void GazeTracker::reset(uint32_t nowMs) {
  telemetry_ = GazeTrackerTelemetry {};
  lastSeenMs_ = nowMs;
  lostAtMs_ = 0;
  hasFixation_ = false;
}

void GazeTracker::applyEvent(const RobotEvent& event) {
  if (event.type == EventType::FaceDetected && event.hasPayload) {
    telemetry_.targetX = constrain(event.x, -1.0f, 1.0f);
    telemetry_.targetY = constrain(event.y, -1.0f, 1.0f);
    telemetry_.faceSize = constrain(event.z, 0.0f, 1.0f);
    telemetry_.presence = constrain(telemetry_.presence + 0.35f + telemetry_.faceSize * 0.25f, 0.0f, 1.0f);
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
  if (!hasFixation_) {
    return;
  }

  const uint32_t sinceSeenMs = nowMs - lastSeenMs_;
  if (sinceSeenMs > kSearchGiveUpMs) {
    telemetry_.presence = approach(telemetry_.presence, 0.0f, 0.06f);
    if (telemetry_.presence <= 0.02f) {
      hasFixation_ = false;
    }
    return;
  }

  const bool activelyTracking = telemetry_.tracking && sinceSeenMs <= kFaceHoldMs;
  const float motionScale = reducedMotion ? 0.30f : 1.0f;
  const float confidence = constrain(telemetry_.presence, 0.0f, 1.0f) * motionScale;
  const float x = deadzone(telemetry_.targetX);
  const float y = deadzone(telemetry_.targetY);

  if (activelyTracking) {
    frame.face.pupilX += x * 0.44f * confidence;
    frame.face.pupilY += y * 0.28f * confidence;
    frame.face.faceX += x * 3.0f * confidence;
    frame.face.faceY += y * 1.2f * confidence;
    if (frame.motion.yawMode == YawMode::Angle) {
      frame.motion.yawDeg += x * 14.0f * confidence;
      frame.motion.pitchDeg += y * 4.0f * confidence;
    }
  } else {
    // Hold a short search glance toward the last seen face before giving up.
    const float search = constrain((kSearchGiveUpMs - sinceSeenMs) / 3000.0f, 0.0f, 1.0f) * confidence;
    frame.face.pupilX += x * 0.24f * search;
    frame.face.faceX += x * 1.4f * search;
    if (frame.motion.yawMode == YawMode::Angle) {
      frame.motion.yawDeg += x * 7.0f * search;
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
