#pragma once

#include <stdint.h>

namespace stackchan {

struct ServoLimits {
  float pitchMinDeg = -20.0f;
  float pitchMaxDeg = 20.0f;
  float yawMinDeg = -45.0f;
  float yawMaxDeg = 45.0f;
  float yawMaxVelocity = 0.65f;
};

struct TimingConfig {
  uint32_t motionPeriodMs = 10;
  uint32_t facePeriodMs = 33;
  uint32_t intentPeriodMs = 20;
};

struct RobotConfig {
  ServoLimits servos;
  TimingConfig timing;
};

inline RobotConfig defaultRobotConfig() {
  return RobotConfig {};
}

}  // namespace stackchan
