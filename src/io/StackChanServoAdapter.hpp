#pragma once

#include "motion/ActuationEngine.hpp"

#ifndef STACKCHAN_ENABLE_SERVOS
#define STACKCHAN_ENABLE_SERVOS 0
#endif

#ifndef STACKCHAN_SERVO_HARDWARE_ENABLE
#define STACKCHAN_SERVO_HARDWARE_ENABLE STACKCHAN_ENABLE_SERVOS
#endif

#ifndef STACKCHAN_SERVO_RX_PIN
#define STACKCHAN_SERVO_RX_PIN 7
#endif

#ifndef STACKCHAN_SERVO_TX_PIN
#define STACKCHAN_SERVO_TX_PIN 6
#endif

#ifndef STACKCHAN_SERVO_YAW_CENTER_DEG
#define STACKCHAN_SERVO_YAW_CENTER_DEG 150
#endif

#ifndef STACKCHAN_SERVO_PITCH_CENTER_DEG
#define STACKCHAN_SERVO_PITCH_CENTER_DEG 90
#endif

#ifndef STACKCHAN_SERVO_RELEASE_ON_STOP
#define STACKCHAN_SERVO_RELEASE_ON_STOP 0
#endif

#ifndef STACKCHAN_SERVO_POWER_GATE_ON_STOP
#define STACKCHAN_SERVO_POWER_GATE_ON_STOP 1
#endif

#ifndef STACKCHAN_SERVO_POWER_ON_SETTLE_MS
#define STACKCHAN_SERVO_POWER_ON_SETTLE_MS 700
#endif

#ifndef STACKCHAN_SERVO_PING_ATTEMPTS
#define STACKCHAN_SERVO_PING_ATTEMPTS 5
#endif

#ifndef STACKCHAN_SERVO_PING_TIMEOUT_MS
#define STACKCHAN_SERVO_PING_TIMEOUT_MS 20
#endif

#ifndef STACKCHAN_SERVO_PING_RETRY_DELAY_MS
#define STACKCHAN_SERVO_PING_RETRY_DELAY_MS 100
#endif

#if STACKCHAN_SERVO_HARDWARE_ENABLE && __has_include(<SCServo.h>) && __has_include(<M5Unified.h>)
#define STACKCHAN_HAS_SERVO_LIBRARY 1
#include <SCServo.h>
#else
#define STACKCHAN_HAS_SERVO_LIBRARY 0
#endif

namespace stackchan {

struct ServoPowerTelemetry {
  bool powerAllowed = false;
  bool railEnabled = false;
  bool torqueEnabled = false;
  uint32_t railEnableEntries = 0;
  uint32_t railDisableEntries = 0;
  uint32_t railWriteFailures = 0;
  uint32_t powerDeniedWrites = 0;
  uint32_t attachAttempts = 0;
  uint32_t attachFailures = 0;
  uint32_t pingAttempts = 0;
  uint32_t pingFailures = 0;
  int lastPingYaw = -1;
  int lastPingPitch = -1;
  const char* lastError = "not_started";
};

class StackChanServoAdapter final : public IActuator {
 public:
  bool begin() override;
  void writePitchDeg(float pitchDeg) override;
  void writeYawAngleDeg(float yawDeg) override;
  void writeYawVelocity(float yawVel) override;
  void stop() override;
  void setPowerAllowed(bool allowed);

  ServoPowerTelemetry powerTelemetry() const;

  float lastPitchDeg() const {
    return lastPitchDeg_;
  }

  float lastYawDeg() const {
    return lastYawDeg_;
  }

 private:
#if STACKCHAN_HAS_SERVO_LIBRARY
  static long scsPositionFromDegrees(float degree);
  bool attachM5Scs();
  bool pingServos();
  bool setPowerEnabled(bool enabled);
  bool ensurePowerEnabled();
  bool setTorqueEnabled(bool enabled);
  bool ensureTorqueEnabled();
  SCSCL servo_;
#endif
  bool enabled_ = false;
  bool attached_ = false;
  bool powerAllowed_ = false;
  bool powerEnabled_ = false;
  bool torqueEnabled_ = false;
  uint32_t railEnableEntries_ = 0;
  uint32_t railDisableEntries_ = 0;
  uint32_t railWriteFailures_ = 0;
  uint32_t powerDeniedWrites_ = 0;
  uint32_t attachAttempts_ = 0;
  uint32_t attachFailures_ = 0;
  uint32_t pingAttempts_ = 0;
  uint32_t pingFailures_ = 0;
  int lastPingYaw_ = -1;
  int lastPingPitch_ = -1;
  const char* lastError_ = "not_started";
  float lastPitchDeg_ = 0.0f;
  float lastYawDeg_ = 0.0f;
  float lastYawVel_ = 0.0f;
};

}  // namespace stackchan
