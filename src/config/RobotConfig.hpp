#pragma once

#include <stdint.h>

namespace stackchan {

#ifndef STACKCHAN_REDUCED_MOTION
#define STACKCHAN_REDUCED_MOTION 0
#endif

#ifndef STACKCHAN_FACE_PERIOD_MS
#define STACKCHAN_FACE_PERIOD_MS 33
#endif

struct ServoLimits {
  float pitchMinDeg = -20.0f;
  float pitchMaxDeg = 20.0f;
  float yawMinDeg = -45.0f;
  float yawMaxDeg = 45.0f;
  float yawMaxVelocity = 0.65f;
};

struct TimingConfig {
  uint32_t motionPeriodMs = 10;
  uint32_t facePeriodMs = STACKCHAN_FACE_PERIOD_MS;
  uint32_t intentPeriodMs = 20;
};

struct FaceConfig {
  // Streaming/review mode: keep the face alive, but damp autonomic motion by 70%.
  bool reducedMotion = STACKCHAN_REDUCED_MOTION != 0;
};

struct RobotConfig {
  ServoLimits servos;
  TimingConfig timing;
  FaceConfig face;
};

inline RobotConfig defaultRobotConfig() {
  return RobotConfig {};
}

}  // namespace stackchan
