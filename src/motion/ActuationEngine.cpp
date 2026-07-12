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
  lastActuatorWriteMs_ = 0;
  enabledAtMs_ = enabled_ ? millis() : 0;
  dutyCycleStartMs_ = enabled_ ? enabledAtMs_ : 0;
  dutyRestStartedMs_ = 0;
  dutyRestMs_ = 0;
  selfMotionUntilMs_ = 0;
  hasLastCommand_ = false;
  lastUpdateMs_ = millis();
  lastReason_ = enabled_ ? "boot_enabled" : "boot_disabled";
  actuatorReady_ = false;
  dutyResting_ = false;

  if (enabled_ && actuator_ != nullptr) {
    actuatorReady_ = actuator_->begin();
    if (!actuatorReady_) {
      enabled_ = false;
      enableFailures_++;
      lastReason_ = "boot_actuator_not_ready";
      Serial.println("[motion] boot enable failed: actuator_not_ready");
    }
  }
}

void ActuationEngine::setEnabled(bool enabled) {
  lastUs_ = micros();
  const bool wasEnabled = enabled_;

  if (!enabled) {
    disableRequests_++;
    enabled_ = false;
    lastActuatorWriteMs_ = 0;
    enabledAtMs_ = 0;
    dutyCycleStartMs_ = 0;
    if (dutyResting_ && dutyRestStartedMs_ != 0) {
      dutyRestMs_ += millis() - dutyRestStartedMs_;
    }
    dutyRestStartedMs_ = 0;
    dutyResting_ = false;
    if (outputSuppressed_ && outputSuppressStartedMs_ != 0) {
      outputSuppressMs_ += millis() - outputSuppressStartedMs_;
    }
    outputSuppressStartedMs_ = 0;
    outputSuppressed_ = false;
    stopActuator("manual_stop");
    return;
  }

  enableRequests_++;
  if (actuator_ == nullptr) {
    enabled_ = false;
    enableFailures_++;
    lastReason_ = "missing_actuator";
    return;
  }

  if (!actuatorReady_) {
    actuatorReady_ = actuator_->begin();
    if (!actuatorReady_) {
      enabled_ = false;
      enableFailures_++;
      lastReason_ = "actuator_not_ready";
      Serial.println("[motion] enable failed: actuator_not_ready");
      return;
    }
  }

  enabled_ = true;
  lastActuatorWriteMs_ = 0;
  enabledAtMs_ = millis();
  if (!wasEnabled || dutyCycleStartMs_ == 0) {
    dutyCycleStartMs_ = enabledAtMs_;
  }
  lastReason_ = "enabled";
}

bool ActuationEngine::refreshSession() {
  if (!enabled_) {
    return false;
  }

  enabledAtMs_ = millis();
  sessionRefreshedAtMs_ = enabledAtMs_;
  sessionRefreshes_++;
  return true;
}

void ActuationEngine::setOutputSuppressed(bool suppressed, const char* reason) {
  if (suppressed == outputSuppressed_) {
    return;
  }

  const uint32_t nowMs = millis();
  lastUs_ = micros();
  lastActuatorWriteMs_ = 0;

  if (suppressed) {
    outputSuppressed_ = true;
    outputSuppressStartedMs_ = nowMs;
    outputSuppressEntries_++;
    stopActuator(reason != nullptr ? reason : "output_suppressed");
    Serial.println("[motion] output_suppressed=1");
    return;
  }

  if (outputSuppressStartedMs_ != 0) {
    outputSuppressMs_ += nowMs - outputSuppressStartedMs_;
  }
  outputSuppressStartedMs_ = 0;
  outputSuppressed_ = false;
  if (enabled_) {
    lastReason_ = "enabled";
  }
  Serial.println("[motion] output_suppressed=0");
}

void ActuationEngine::update(const RobotFrame& target, uint32_t nowUs) {
  const uint32_t nowMs = millis();
  lastUpdateMs_ = nowMs;
  if (actuator_ == nullptr) {
    return;
  }
  if (!enabled_) {
    return;
  }
  if (STACKCHAN_MOTION_SESSION_TIMEOUT_MS > 0 && enabledAtMs_ != 0 &&
      nowMs - enabledAtMs_ >= STACKCHAN_MOTION_SESSION_TIMEOUT_MS) {
    enabled_ = false;
    lastActuatorWriteMs_ = 0;
    enabledAtMs_ = 0;
    sessionTimeouts_++;
    stopActuator("session_timeout");
    Serial.println("[motion] enabled=0 reason=session_timeout");
    return;
  }
  if (!actuatorReady_) {
    actuatorReady_ = actuator_->begin();
    if (!actuatorReady_) {
      enabled_ = false;
      enableFailures_++;
      lastReason_ = "actuator_not_ready";
      Serial.println("[motion] disabled: actuator_not_ready");
      return;
    }
  }
  if (outputSuppressed_) {
    return;
  }

  if (STACKCHAN_MOTION_DUTY_ACTIVE_MS > 0 && STACKCHAN_MOTION_DUTY_REST_MS > 0 && dutyCycleStartMs_ != 0) {
    const uint32_t activeMs = STACKCHAN_MOTION_DUTY_ACTIVE_MS;
    const uint32_t restMs = STACKCHAN_MOTION_DUTY_REST_MS;
    const uint32_t cycleMs = activeMs + restMs;
    const uint32_t cyclePositionMs = cycleMs > 0 ? (nowMs - dutyCycleStartMs_) % cycleMs : 0;
    const bool shouldRest = cyclePositionMs >= activeMs;
    if (shouldRest) {
      if (!dutyResting_) {
        dutyResting_ = true;
        dutyRestStartedMs_ = nowMs;
        dutyRestEntries_++;
        lastActuatorWriteMs_ = 0;
        stopActuator("duty_rest");
        Serial.println("[motion] duty_rest=1");
      }
      return;
    }
    if (dutyResting_) {
      dutyResting_ = false;
      if (dutyRestStartedMs_ != 0) {
        dutyRestMs_ += nowMs - dutyRestStartedMs_;
      }
      dutyRestStartedMs_ = 0;
      lastActuatorWriteMs_ = 0;
      lastReason_ = "enabled";
      Serial.println("[motion] duty_rest=0");
    }
  }

  float dt = (nowUs - lastUs_) * 0.000001f;
  lastUs_ = nowUs;
  dt = constrain(dt, 0.001f, 0.040f);

  float pitchTarget = target.motion.pitchDeg;
  float yawTarget = target.motion.yawDeg;

  const float t = nowMs * 0.001f;
  const float idleAmp = ((1.0f - target.emotion.focus) * 3.5f + target.emotion.arousal * 1.0f) *
                        STACKCHAN_SERVO_IDLE_SCALE;
  pitchTarget += sinf(t * 1.7f) * idleAmp * 0.20f;
  yawTarget += sinf(t * 1.1f) * idleAmp;

  const float pitchCmd = clampPitch(pitch_.step(pitchTarget, dt), config_.servos);
  if (lastActuatorWriteMs_ != 0 && nowMs - lastActuatorWriteMs_ < STACKCHAN_SERVO_OUTPUT_PERIOD_MS) {
    return;
  }
  lastActuatorWriteMs_ = nowMs;

  bool commandMoved = !hasLastCommand_ || fabsf(pitchCmd - lastPitchCommandDeg_) >= 0.60f;
  actuator_->writePitchDeg(pitchCmd);
  lastPitchCommandDeg_ = pitchCmd;

  if (target.motion.yawMode == YawMode::Angle) {
    const float yawCmd = clampYawAngle(yaw_.step(yawTarget, dt), config_.servos);
    commandMoved = commandMoved || !hasLastCommand_ || fabsf(yawCmd - lastYawCommandDeg_) >= 0.60f;
    actuator_->writeYawAngleDeg(yawCmd);
    lastYawCommandDeg_ = yawCmd;
  } else if (target.motion.yawMode == YawMode::Velocity) {
    const float yawVelocity = clampYawVelocity(target.motion.yawVel, config_.servos);
    commandMoved = commandMoved || fabsf(yawVelocity) >= 0.03f;
    actuator_->writeYawVelocity(yawVelocity);
  } else {
    actuator_->writeYawVelocity(0.0f);
  }
  hasLastCommand_ = true;
  if (commandMoved) {
    selfMotionUntilMs_ = nowMs + STACKCHAN_SERVO_OUTPUT_PERIOD_MS + 250u;
  }
}

void ActuationEngine::stopActuator(const char* reason) {
  lastReason_ = reason != nullptr ? reason : "stopped";
  selfMotionUntilMs_ = 0;
  hasLastCommand_ = false;
  if (actuator_ != nullptr && actuatorReady_) {
    stopCalls_++;
    actuator_->stop();
  }
}

ActuationTelemetry ActuationEngine::telemetry() const {
  ActuationTelemetry telemetry;
  telemetry.enabled = enabled_;
  telemetry.actuatorReady = actuatorReady_;
  telemetry.outputSuppressed = outputSuppressed_;
  telemetry.selfMotionActive = selfMotionUntilMs_ != 0 &&
                               static_cast<int32_t>(selfMotionUntilMs_ - millis()) > 0;
  telemetry.enabledAtMs = enabledAtMs_;
  telemetry.lastUpdateMs = lastUpdateMs_;
  telemetry.lastActuatorWriteMs = lastActuatorWriteMs_;
  telemetry.selfMotionUntilMs = selfMotionUntilMs_;
  telemetry.enableRequests = enableRequests_;
  telemetry.disableRequests = disableRequests_;
  telemetry.enableFailures = enableFailures_;
  telemetry.sessionRefreshes = sessionRefreshes_;
  telemetry.sessionRefreshedAtMs = sessionRefreshedAtMs_;
  telemetry.sessionTimeouts = sessionTimeouts_;
  telemetry.stopCalls = stopCalls_;
  telemetry.dutyCycleStartMs = dutyCycleStartMs_;
  telemetry.dutyRestEntries = dutyRestEntries_;
  telemetry.dutyRestMs = dutyRestMs_;
  if (dutyResting_ && dutyRestStartedMs_ != 0) {
    telemetry.dutyRestMs += millis() - dutyRestStartedMs_;
  }
  telemetry.outputSuppressEntries = outputSuppressEntries_;
  telemetry.outputSuppressMs = outputSuppressMs_;
  if (outputSuppressed_ && outputSuppressStartedMs_ != 0) {
    telemetry.outputSuppressMs += millis() - outputSuppressStartedMs_;
  }
  telemetry.lastPitchCommandDeg = lastPitchCommandDeg_;
  telemetry.lastYawCommandDeg = lastYawCommandDeg_;
  telemetry.dutyResting = dutyResting_;
  telemetry.lastReason = lastReason_;
  return telemetry;
}

}  // namespace stackchan
