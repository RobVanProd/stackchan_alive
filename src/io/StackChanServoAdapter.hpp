#pragma once

#include "motion/ActuationEngine.hpp"

#if __has_include(<Stackchan_servo.h>)
#define STACKCHAN_HAS_SERVO_LIBRARY 1
#include <Stackchan_servo.h>
#else
#define STACKCHAN_HAS_SERVO_LIBRARY 0
#endif

namespace stackchan {

class StackChanServoAdapter final : public IActuator {
 public:
  bool begin() override;
  void writePitchDeg(float pitchDeg) override;
  void writeYawAngleDeg(float yawDeg) override;
  void writeYawVelocity(float yawVel) override;
  void stop() override;

  float lastPitchDeg() const {
    return lastPitchDeg_;
  }

  float lastYawDeg() const {
    return lastYawDeg_;
  }

 private:
  float lastPitchDeg_ = 0.0f;
  float lastYawDeg_ = 0.0f;
  float lastYawVel_ = 0.0f;
};

}  // namespace stackchan
