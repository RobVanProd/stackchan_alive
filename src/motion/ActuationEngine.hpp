#pragma once

#include "config/RobotConfig.hpp"
#include "motion/Spring.hpp"
#include "persona/StateMatrix.hpp"

#ifndef STACKCHAN_MOTION_ENABLED_AT_BOOT
#define STACKCHAN_MOTION_ENABLED_AT_BOOT 1
#endif

#ifndef STACKCHAN_SERVO_OUTPUT_PERIOD_MS
#define STACKCHAN_SERVO_OUTPUT_PERIOD_MS 100
#endif

#ifndef STACKCHAN_SERVO_IDLE_SCALE
#define STACKCHAN_SERVO_IDLE_SCALE 1.0f
#endif

#ifndef STACKCHAN_MOTION_DUTY_ACTIVE_MS
#define STACKCHAN_MOTION_DUTY_ACTIVE_MS 0
#endif

#ifndef STACKCHAN_MOTION_DUTY_REST_MS
#define STACKCHAN_MOTION_DUTY_REST_MS 0
#endif

#ifndef STACKCHAN_MOTION_SESSION_TIMEOUT_MS
#define STACKCHAN_MOTION_SESSION_TIMEOUT_MS 30000
#endif

namespace stackchan {

class IActuator {
 public:
  virtual ~IActuator() = default;
  virtual bool begin() = 0;
  virtual void writePitchDeg(float pitchDeg) = 0;
  virtual void writeYawAngleDeg(float yawDeg) = 0;
  virtual void writeYawVelocity(float yawVel) = 0;
  virtual void stop() = 0;
};

struct ActuationTelemetry {
  bool enabled = false;
  bool actuatorReady = false;
  bool outputSuppressed = false;
  bool selfMotionActive = false;
  uint32_t enabledAtMs = 0;
  uint32_t lastUpdateMs = 0;
  uint32_t lastActuatorWriteMs = 0;
  uint32_t selfMotionUntilMs = 0;
  uint32_t enableRequests = 0;
  uint32_t disableRequests = 0;
  uint32_t enableFailures = 0;
  uint32_t sessionRefreshes = 0;
  uint32_t sessionRefreshedAtMs = 0;
  uint32_t sessionTimeouts = 0;
  uint32_t stopCalls = 0;
  uint32_t dutyCycleStartMs = 0;
  uint32_t dutyRestEntries = 0;
  uint32_t dutyRestMs = 0;
  uint32_t outputSuppressEntries = 0;
  uint32_t outputSuppressMs = 0;
  bool dutyResting = false;
  const char* lastReason = "not_started";
};

class ActuationEngine {
 public:
  explicit ActuationEngine(const RobotConfig& config);

  void begin(IActuator* actuator);
  void setEnabled(bool enabled);
  bool refreshSession();
  bool isEnabled() const {
    return enabled_;
  }
  void setOutputSuppressed(bool suppressed, const char* reason = nullptr);
  bool outputSuppressed() const {
    return outputSuppressed_;
  }
  ActuationTelemetry telemetry() const;
  void update(const RobotFrame& target, uint32_t nowUs);

 private:
  void stopActuator(const char* reason);

  RobotConfig config_;
  IActuator* actuator_ = nullptr;
  Spring1D pitch_;
  Spring1D yaw_;
  uint32_t lastUs_ = 0;
  uint32_t lastActuatorWriteMs_ = 0;
  uint32_t enabledAtMs_ = 0;
  uint32_t lastUpdateMs_ = 0;
  uint32_t dutyCycleStartMs_ = 0;
  uint32_t dutyRestStartedMs_ = 0;
  uint32_t dutyRestMs_ = 0;
  uint32_t outputSuppressStartedMs_ = 0;
  uint32_t outputSuppressMs_ = 0;
  uint32_t enableRequests_ = 0;
  uint32_t disableRequests_ = 0;
  uint32_t enableFailures_ = 0;
  uint32_t sessionRefreshes_ = 0;
  uint32_t sessionRefreshedAtMs_ = 0;
  uint32_t sessionTimeouts_ = 0;
  uint32_t dutyRestEntries_ = 0;
  uint32_t outputSuppressEntries_ = 0;
  uint32_t stopCalls_ = 0;
  uint32_t selfMotionUntilMs_ = 0;
  float lastPitchCommandDeg_ = 0.0f;
  float lastYawCommandDeg_ = 0.0f;
  bool hasLastCommand_ = false;
  const char* lastReason_ = "not_started";
  bool enabled_ = STACKCHAN_MOTION_ENABLED_AT_BOOT != 0;
  bool actuatorReady_ = false;
  bool dutyResting_ = false;
  bool outputSuppressed_ = false;
};

}  // namespace stackchan
