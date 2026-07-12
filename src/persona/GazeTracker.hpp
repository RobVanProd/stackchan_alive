#pragma once

#include <Arduino.h>

#include "persona/EventBus.hpp"
#include "persona/StateMatrix.hpp"

namespace stackchan {

struct GazeTrackerTelemetry {
  float targetX = 0.0f;
  float targetY = 0.0f;
  float faceSize = 0.0f;
  float presence = 0.0f;
  float yawOffsetDeg = 0.0f;
  float pitchOffsetDeg = 0.0f;
  uint32_t lastAppliedAtMs = 0;
  bool motionOutputActive = true;
  bool tracking = false;
};

class GazeTracker {
 public:
  void reset(uint32_t nowMs = 0);
  void applyEvent(const RobotEvent& event);
  void setMotionOutputActive(bool active, uint32_t nowMs);
  void apply(RobotFrame& frame, uint32_t nowMs, bool reducedMotion);

  const GazeTrackerTelemetry& telemetry() const {
    return telemetry_;
  }

 private:
  GazeTrackerTelemetry telemetry_;
  uint32_t lastSeenMs_ = 0;
  uint32_t lostAtMs_ = 0;
  uint32_t lastApplyMs_ = 0;
  bool motionOutputActive_ = true;
  bool hasFixation_ = false;

  static float approach(float value, float target, float amount);
};

}  // namespace stackchan
