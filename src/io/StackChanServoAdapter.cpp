#include "io/StackChanServoAdapter.hpp"

#include <Arduino.h>
#if __has_include(<M5Unified.h>)
#include <M5Unified.h>
#endif
#include <math.h>

namespace stackchan {

#if STACKCHAN_HAS_SERVO_LIBRARY
namespace {
constexpr uint8_t kPy32Address = 0x6F;
constexpr uint32_t kPy32I2cFreq = 100000;
constexpr uint8_t kRegVersion = 0x02;
constexpr uint8_t kRegGpioModeLow = 0x03;
constexpr uint8_t kRegGpioOutputLow = 0x05;
constexpr uint8_t kRegGpioPullUpLow = 0x09;
constexpr uint8_t kRegGpioPullDownLow = 0x0B;

bool py32BitOn(uint8_t reg, uint8_t mask) {
  return M5.In_I2C.bitOn(kPy32Address, reg, mask, kPy32I2cFreq);
}

bool py32BitOff(uint8_t reg, uint8_t mask) {
  return M5.In_I2C.bitOff(kPy32Address, reg, mask, kPy32I2cFreq);
}

bool py32SetPin0Output(bool high) {
  const uint8_t pin0 = 0x01;
  const bool configured = py32BitOn(kRegGpioModeLow, pin0) && py32BitOff(kRegGpioPullDownLow, pin0) &&
                          py32BitOn(kRegGpioPullUpLow, pin0);
  if (!configured) {
    return false;
  }
  return high ? py32BitOn(kRegGpioOutputLow, pin0) : py32BitOff(kRegGpioOutputLow, pin0);
}

bool py32Begin() {
  if (!M5.In_I2C.isEnabled()) {
    return false;
  }
  if (!M5.In_I2C.scanID(kPy32Address, kPy32I2cFreq)) {
    return false;
  }
  const uint8_t version = M5.In_I2C.readRegister8(kPy32Address, kRegVersion, kPy32I2cFreq);
  return version != 0 && version != 0xFF;
}
}  // namespace

long StackChanServoAdapter::scsPositionFromDegrees(float degree) {
  const float clamped = constrain(degree, 0.0f, 300.0f);
  return lroundf((300.0f - clamped) * 1023.0f / 300.0f);
}

bool StackChanServoAdapter::attachM5Scs() {
  if (attached_) {
    return true;
  }
  ++attachAttempts_;
  lastError_ = "";
  if (!powerAllowed_) {
    ++powerDeniedWrites_;
    ++attachFailures_;
    lastError_ = "power_not_granted";
    Serial.println(F("[servo] attach denied: power_not_granted"));
    return false;
  }
  Serial.println(F("[servo] attaching M5 SCS0009 output"));
  bool expanderReady = false;
  for (uint8_t attempt = 0; attempt < 5; ++attempt) {
    if (py32Begin()) {
      expanderReady = true;
      break;
    }
    delay(50);
  }
  if (!expanderReady) {
    ++attachFailures_;
    lastError_ = "io_expander_not_ready";
    Serial.println(F("[servo] attach failed: io_expander_not_ready"));
    return false;
  }
  if (!setPowerEnabled(true)) {
    ++attachFailures_;
    lastError_ = "servo_rail_enable_failed";
    Serial.println(F("[servo] attach failed: io_expander_pin0"));
    return false;
  }
  Serial2.begin(1000000, SERIAL_8N1, STACKCHAN_SERVO_RX_PIN, STACKCHAN_SERVO_TX_PIN);
  servo_.pSerial = &Serial2;
  servo_.IOTimeOut = STACKCHAN_SERVO_PING_TIMEOUT_MS;
  const bool pingOk = pingServos();
  if (!pingOk) {
    setPowerEnabled(false);
    ++attachFailures_;
    lastError_ = "servo_ping_failed";
    Serial.println(F("[servo] attach failed: ping"));
    return false;
  }
  attached_ = true;
  lastError_ = "";
  return true;
}

bool StackChanServoAdapter::pingServos() {
  int pingX = -1;
  int pingY = -1;
  for (uint8_t attempt = 0; attempt < STACKCHAN_SERVO_PING_ATTEMPTS; ++attempt) {
    ++pingAttempts_;
    pingX = servo_.Ping(1);
    pingY = servo_.Ping(2);
    if (pingX == 1 && pingY == 2) {
      break;
    }
    delay(STACKCHAN_SERVO_PING_RETRY_DELAY_MS);
  }
  lastPingYaw_ = pingX;
  lastPingPitch_ = pingY;
  Serial.print(F("[servo] attach ok ping_x="));
  Serial.print(pingX);
  Serial.print(F(" ping_y="));
  Serial.println(pingY);
  const bool ok = pingX == 1 && pingY == 2;
  if (!ok) {
    ++pingFailures_;
  }
  return ok;
}

bool StackChanServoAdapter::setPowerEnabled(bool enabled) {
  if (enabled == powerEnabled_) {
    return true;
  }
  if (enabled && !powerAllowed_) {
    ++powerDeniedWrites_;
    return false;
  }

  if (!py32SetPin0Output(enabled)) {
    ++railWriteFailures_;
    lastError_ = "servo_rail_write_failed";
    return false;
  }
  powerEnabled_ = enabled;
  if (enabled) {
    ++railEnableEntries_;
    delay(STACKCHAN_SERVO_POWER_ON_SETTLE_MS);
    if (attached_ && !pingServos()) {
      ++railWriteFailures_;
      lastError_ = "servo_repower_ping_failed";
      py32SetPin0Output(false);
      powerEnabled_ = false;
      ++railDisableEntries_;
      return false;
    }
  } else {
    torqueEnabled_ = false;
    ++railDisableEntries_;
  }
  return true;
}

bool StackChanServoAdapter::ensurePowerEnabled() {
  return powerEnabled_ || setPowerEnabled(true);
}

bool StackChanServoAdapter::setTorqueEnabled(bool enabled) {
  if (!attached_) {
    return false;
  }
  if (enabled && !ensurePowerEnabled()) {
    return false;
  }
  if (!enabled && !powerEnabled_) {
    torqueEnabled_ = false;
    return true;
  }
  const uint8_t value = enabled ? 1 : 0;
  const int yawOk = servo_.EnableTorque(1, value);
  const int pitchOk = servo_.EnableTorque(2, value);
  const bool ok = yawOk != -1 && pitchOk != -1;
  if (ok) {
    torqueEnabled_ = enabled;
  } else {
    lastError_ = enabled ? "torque_enable_failed" : "torque_disable_failed";
    Serial.print(F("[servo] torque set failed enabled="));
    Serial.print(enabled ? 1 : 0);
    Serial.print(F(" yaw="));
    Serial.print(yawOk);
    Serial.print(F(" pitch="));
    Serial.println(pitchOk);
  }
  return ok;
}

bool StackChanServoAdapter::ensureTorqueEnabled() {
  return (powerEnabled_ && torqueEnabled_) || setTorqueEnabled(true);
}
#endif

bool StackChanServoAdapter::begin() {
#if STACKCHAN_SERVO_HARDWARE_ENABLE && STACKCHAN_HAS_SERVO_LIBRARY
  if (!powerAllowed_) {
    ++powerDeniedWrites_;
    Serial.println(F("[servo] begin denied: power_not_granted"));
    return false;
  }
  enabled_ = attachM5Scs();
  if (enabled_) {
    enabled_ = ensureTorqueEnabled();
  }
#elif STACKCHAN_SERVO_HARDWARE_ENABLE
  enabled_ = false;
  Serial.println(F("[servo] hardware requested but SCServo/M5Unified support is unavailable"));
#else
  enabled_ = true;
  torqueEnabled_ = true;
  Serial.println(F("[servo] dry-run mode; enable STACKCHAN_SERVO_HARDWARE_ENABLE after calibration"));
#endif
  return enabled_;
}

void StackChanServoAdapter::writePitchDeg(float pitchDeg) {
  lastPitchDeg_ = pitchDeg;
#if STACKCHAN_SERVO_HARDWARE_ENABLE && STACKCHAN_HAS_SERVO_LIBRARY
  if (enabled_ && ensureTorqueEnabled()) {
    servo_.WritePos(2, scsPositionFromDegrees(STACKCHAN_SERVO_PITCH_CENTER_DEG + pitchDeg), 0);
  }
#endif
}

void StackChanServoAdapter::writeYawAngleDeg(float yawDeg) {
  lastYawDeg_ = yawDeg;
  lastYawVel_ = 0.0f;
#if STACKCHAN_SERVO_HARDWARE_ENABLE && STACKCHAN_HAS_SERVO_LIBRARY
  if (enabled_ && ensureTorqueEnabled()) {
    servo_.WritePos(1, scsPositionFromDegrees(STACKCHAN_SERVO_YAW_CENTER_DEG + yawDeg), 0);
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
#if STACKCHAN_SERVO_HARDWARE_ENABLE && STACKCHAN_HAS_SERVO_LIBRARY
  if (enabled_ && powerEnabled_ && torqueEnabled_) {
    servo_.WritePos(1, scsPositionFromDegrees(STACKCHAN_SERVO_YAW_CENTER_DEG), 0);
    servo_.WritePos(2, scsPositionFromDegrees(STACKCHAN_SERVO_PITCH_CENTER_DEG), 0);
#if STACKCHAN_SERVO_RELEASE_ON_STOP
    setTorqueEnabled(false);
#endif
  }
#if STACKCHAN_SERVO_POWER_GATE_ON_STOP
  if (powerEnabled_) {
    if (torqueEnabled_) {
      setTorqueEnabled(false);
    }
    setPowerEnabled(false);
  }
#endif
#elif !STACKCHAN_SERVO_HARDWARE_ENABLE
  torqueEnabled_ = false;
#endif
}

void StackChanServoAdapter::setPowerAllowed(bool allowed) {
  if (allowed == powerAllowed_) {
    return;
  }
  powerAllowed_ = allowed;
  if (!allowed) {
    stop();
  }
}

ServoPowerTelemetry StackChanServoAdapter::powerTelemetry() const {
  ServoPowerTelemetry telemetry;
  telemetry.powerAllowed = powerAllowed_;
  telemetry.railEnabled = powerEnabled_;
  telemetry.torqueEnabled = torqueEnabled_;
  telemetry.railEnableEntries = railEnableEntries_;
  telemetry.railDisableEntries = railDisableEntries_;
  telemetry.railWriteFailures = railWriteFailures_;
  telemetry.powerDeniedWrites = powerDeniedWrites_;
  telemetry.attachAttempts = attachAttempts_;
  telemetry.attachFailures = attachFailures_;
  telemetry.pingAttempts = pingAttempts_;
  telemetry.pingFailures = pingFailures_;
  telemetry.lastPingYaw = lastPingYaw_;
  telemetry.lastPingPitch = lastPingPitch_;
  telemetry.lastError = lastError_;
  return telemetry;
}

}  // namespace stackchan
