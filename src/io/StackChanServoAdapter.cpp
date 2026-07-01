#include "io/StackChanServoAdapter.hpp"

#include <Arduino.h>

namespace stackchan {

bool StackChanServoAdapter::begin() {
  Serial.println(F("[servo] adapter ready; hardware mapping pending calibration"));
  return true;
}

void StackChanServoAdapter::writePitchDeg(float pitchDeg) {
  lastPitchDeg_ = pitchDeg;
  // TODO: after hardware truth test, map this to the selected non-blocking pitch write.
}

void StackChanServoAdapter::writeYawAngleDeg(float yawDeg) {
  lastYawDeg_ = yawDeg;
  lastYawVel_ = 0.0f;
  // TODO: only enable absolute yaw after confirming feedback position behavior.
}

void StackChanServoAdapter::writeYawVelocity(float yawVel) {
  lastYawVel_ = yawVel;
  // TODO: use this path for continuous-rotation yaw hardware.
}

void StackChanServoAdapter::stop() {
  lastYawVel_ = 0.0f;
}

}  // namespace stackchan
