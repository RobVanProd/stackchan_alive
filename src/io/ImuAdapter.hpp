#pragma once

#include <Arduino.h>

#include "persona/EventBus.hpp"

#ifndef STACKCHAN_ENABLE_IMU
#define STACKCHAN_ENABLE_IMU 0
#endif

#ifndef STACKCHAN_IMU_SAMPLE_PERIOD_MS
#define STACKCHAN_IMU_SAMPLE_PERIOD_MS 40
#endif

#ifndef STACKCHAN_IMU_READ_ATTEMPTS
#define STACKCHAN_IMU_READ_ATTEMPTS 3
#endif

namespace stackchan {

struct ImuSample {
  float accelX = 0.0f;
  float accelY = 0.0f;
  float accelZ = 1.0f;
  float gyroX = 0.0f;
  float gyroY = 0.0f;
  float gyroZ = 0.0f;
};

struct ImuAdapterTelemetry {
  bool enabled = false;
  bool ready = false;
  bool calibrated = false;
  bool pickedUp = false;
  bool selfMotionFiltered = false;
  uint32_t samples = 0;
  uint32_t readRetries = 0;
  uint32_t readRecoveries = 0;
  uint32_t readFailures = 0;
  uint32_t eventsPublished = 0;
  uint32_t selfMotionSamples = 0;
  uint32_t pickupEvents = 0;
  uint32_t putdownEvents = 0;
  uint32_t shakeEvents = 0;
  uint32_t tiltEvents = 0;
  uint32_t lastSampleMs = 0;
  uint32_t lastEventMs = 0;
  uint8_t lastEventType = 0;
  bool lastEventSelfMotion = false;
  float lastEventStrength = 0.0f;
  float lastEventJerk = 0.0f;
  float lastEventAccelNorm = 1.0f;
  float lastEventGyroNorm = 0.0f;
  float accelNorm = 1.0f;
  float gyroNorm = 0.0f;
  float gravityX = 0.0f;
  float gravityY = 0.0f;
  float gravityZ = 1.0f;
};

class ImuGestureInterpreter {
 public:
  void reset(uint32_t nowMs = 0);
  bool update(const ImuSample& sample, bool selfMotionActive, uint32_t nowMs, RobotEvent* eventOut);

  bool calibrated() const { return calibrated_; }
  bool pickedUp() const { return pickedUp_; }
  float accelNorm() const { return accelNorm_; }
  float gyroNorm() const { return gyroNorm_; }
  float jerk() const { return jerk_; }
  float gravityX() const { return gravityX_; }
  float gravityY() const { return gravityY_; }
  float gravityZ() const { return gravityZ_; }

 private:
  bool emit(EventType type, float strength, uint32_t nowMs, RobotEvent* eventOut) const;

  bool initialized_ = false;
  bool calibrated_ = false;
  bool pickedUp_ = false;
  uint16_t calibrationSamples_ = 0;
  uint8_t shakeHits_ = 0;
  uint32_t motionSinceMs_ = 0;
  uint32_t stationarySinceMs_ = 0;
  uint32_t shakeWindowStartedMs_ = 0;
  uint32_t lastShakeMs_ = 0;
  uint32_t lastTiltMs_ = 0;
  float lastAccelX_ = 0.0f;
  float lastAccelY_ = 0.0f;
  float lastAccelZ_ = 1.0f;
  float gravityX_ = 0.0f;
  float gravityY_ = 0.0f;
  float gravityZ_ = 1.0f;
  float baselineX_ = 0.0f;
  float baselineY_ = 0.0f;
  float baselineZ_ = 1.0f;
  float lastTiltStrength_ = 0.0f;
  float accelNorm_ = 1.0f;
  float gyroNorm_ = 0.0f;
  float jerk_ = 0.0f;
};

class ImuAdapter {
 public:
  bool begin(uint32_t nowMs);
  bool poll(uint32_t nowMs, bool selfMotionActive, RobotEvent* eventOut);

  const ImuAdapterTelemetry& telemetry() const { return telemetry_; }

 private:
  ImuAdapterTelemetry telemetry_;
  ImuGestureInterpreter interpreter_;
};

}  // namespace stackchan
