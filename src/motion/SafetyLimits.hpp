#pragma once

#include <Arduino.h>

#include "config/RobotConfig.hpp"

namespace stackchan {

inline float clampPitch(float pitchDeg, const ServoLimits& limits) {
  return constrain(pitchDeg, limits.pitchMinDeg, limits.pitchMaxDeg);
}

inline float clampYawAngle(float yawDeg, const ServoLimits& limits) {
  return constrain(yawDeg, limits.yawMinDeg, limits.yawMaxDeg);
}

inline float clampYawVelocity(float yawVel, const ServoLimits& limits) {
  return constrain(yawVel, -limits.yawMaxVelocity, limits.yawMaxVelocity);
}

inline float wrapDegrees(float deg) {
  while (deg > 180.0f) {
    deg -= 360.0f;
  }
  while (deg < -180.0f) {
    deg += 360.0f;
  }
  return deg;
}

}  // namespace stackchan
