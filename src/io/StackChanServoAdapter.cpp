#include "io/StackChanServoAdapter.hpp"

#include <Arduino.h>

namespace stackchan {

bool StackChanServoAdapter::begin() {
#if STACKCHAN_ENABLE_SERVOS && STACKCHAN_HAS_SERVO_LIBRARY
  Serial.println(F("[servo] enabling StackchanSERVO hardware output"));
  servo_.begin(1, 90, 0, 2, 90, 0, ServoType::M5_SCS, &M5.In_I2C);
  enabled_ = true;
#else
  enabled_ = false;
  Serial.println(F("[servo] dry-run mode; set STACKCHAN_ENABLE_SERVOS=1 after calibration"));
#endif
  return true;
}

void StackChanServoAdapter::writePitchDeg(float pitchDeg) {
  lastPitchDeg_ = pitchDeg;
#if STACKCHAN_ENABLE_SERVOS && STACKCHAN_HAS_SERVO_LIBRARY
  if (enabled_) {
    servo_.moveY(static_cast<int>(90.0f + pitchDeg), 0, false);
  }
#endif
}

void StackChanServoAdapter::writeYawAngleDeg(float yawDeg) {
  lastYawDeg_ = yawDeg;
  lastYawVel_ = 0.0f;
#if STACKCHAN_ENABLE_SERVOS && STACKCHAN_HAS_SERVO_LIBRARY
  if (enabled_) {
    servo_.moveX(static_cast<int>(90.0f + yawDeg), 0);
  }
#endif
}

void StackChanServoAdapter::writeYawVelocity(float yawVel) {
  lastYawVel_ = yawVel;
  // Continuous-yaw output stays disabled until hardware feedback behavior is measured.
}

void StackChanServoAdapter::stop() {
  lastPitchDeg_ = 0.0f;
  lastYawDeg_ = 0.0f;
  lastYawVel_ = 0.0f;
#if STACKCHAN_ENABLE_SERVOS && STACKCHAN_HAS_SERVO_LIBRARY
  if (enabled_) {
    servo_.moveX(90, 0);
    servo_.moveY(90, 0, false);
  }
#endif
}

}  // namespace stackchan
