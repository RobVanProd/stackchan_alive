#include "motion/ActuationEngine.hpp"

#include <Arduino.h>
#include <math.h>

#include "motion/SafetyLimits.hpp"

namespace stackchan {

ActuationEngine::ActuationEngine(const RobotConfig& config) : config_(config) {}

void ActuationEngine::begin(IActuator* actuator) {
  actuator_ = actuator;
  pitch_.reset(0.0f);
  yaw_.reset(0.0f);
  lastUs_ = micros();

  if (actuator_ != nullptr) {
    actuator_->begin();
  }
}

void ActuationEngine::update(const RobotFrame& target, uint32_t nowUs) {
  if (actuator_ == nullptr) {
    return;
  }

  float dt = (nowUs - lastUs_) * 0.000001f;
  lastUs_ = nowUs;
  dt = constrain(dt, 0.001f, 0.040f);

  float pitchTarget = target.motion.pitchDeg;
  float yawTarget = target.motion.yawDeg;

  const float t = millis() * 0.001f;
  const float idleAmp = (1.0f - target.emotion.focus) * 3.5f + target.emotion.arousal * 1.0f;
  pitchTarget += sinf(t * 1.7f) * idleAmp * 0.20f;
  yawTarget += sinf(t * 1.1f) * idleAmp;

  const float pitchCmd = clampPitch(pitch_.step(pitchTarget, dt), config_.servos);
  actuator_->writePitchDeg(pitchCmd);

  if (target.motion.yawMode == YawMode::Angle) {
    const float yawCmd = clampYawAngle(yaw_.step(yawTarget, dt), config_.servos);
    actuator_->writeYawAngleDeg(yawCmd);
  } else if (target.motion.yawMode == YawMode::Velocity) {
    actuator_->writeYawVelocity(clampYawVelocity(target.motion.yawVel, config_.servos));
  } else {
    actuator_->writeYawVelocity(0.0f);
  }
}

}  // namespace stackchan
