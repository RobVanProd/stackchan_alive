#pragma once

#include "motion/SafetyLimits.hpp"

namespace stackchan {

class PositionYawController {
 public:
  float update(float targetDeg, float measuredDeg, float dt) {
    (void)measuredDeg;
    (void)dt;
    return targetDeg;
  }
};

class VelocityYawController {
 public:
  float update(float targetDeg, float measuredDeg, float measuredVelocityDeg, float dt) {
    (void)dt;
    const float error = wrapDegrees(targetDeg - measuredDeg);
    return kp_ * error - kd_ * measuredVelocityDeg;
  }

  void setGains(float kp, float kd) {
    kp_ = kp;
    kd_ = kd;
  }

 private:
  float kp_ = 0.025f;
  float kd_ = 0.004f;
};

}  // namespace stackchan
