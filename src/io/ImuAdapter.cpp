#include "io/ImuAdapter.hpp"

#include <math.h>

#if STACKCHAN_ENABLE_IMU && __has_include(<M5Unified.h>)
#include <M5Unified.h>
#define STACKCHAN_IMU_HARDWARE_AVAILABLE 1
#else
#define STACKCHAN_IMU_HARDWARE_AVAILABLE 0
#endif

namespace stackchan {
namespace {

float clamp01(float value) {
  if (value < 0.0f) return 0.0f;
  if (value > 1.0f) return 1.0f;
  return value;
}

float vectorNorm(float x, float y, float z) {
  return sqrtf(x * x + y * y + z * z);
}

float normalizedDot(float ax, float ay, float az, float bx, float by, float bz) {
  const float an = vectorNorm(ax, ay, az);
  const float bn = vectorNorm(bx, by, bz);
  if (an < 0.001f || bn < 0.001f) return 1.0f;
  const float dot = (ax * bx + ay * by + az * bz) / (an * bn);
  if (dot < -1.0f) return -1.0f;
  if (dot > 1.0f) return 1.0f;
  return dot;
}

}  // namespace

void ImuGestureInterpreter::reset(uint32_t nowMs) {
  initialized_ = false;
  calibrated_ = false;
  pickedUp_ = false;
  calibrationSamples_ = 0;
  shakeHits_ = 0;
  motionSinceMs_ = 0;
  stationarySinceMs_ = nowMs;
  shakeWindowStartedMs_ = 0;
  lastShakeMs_ = 0;
  lastTiltMs_ = 0;
  lastAccelX_ = 0.0f;
  lastAccelY_ = 0.0f;
  lastAccelZ_ = 1.0f;
  gravityX_ = 0.0f;
  gravityY_ = 0.0f;
  gravityZ_ = 1.0f;
  baselineX_ = 0.0f;
  baselineY_ = 0.0f;
  baselineZ_ = 1.0f;
  lastTiltStrength_ = 0.0f;
  accelNorm_ = 1.0f;
  gyroNorm_ = 0.0f;
  jerk_ = 0.0f;
}

bool ImuGestureInterpreter::emit(
    EventType type, float strength, uint32_t nowMs, RobotEvent* eventOut) const {
  if (eventOut == nullptr) return false;
  *eventOut = RobotEvent {};
  eventOut->type = type;
  eventOut->timestampMs = nowMs;
  eventOut->strength = clamp01(strength);
  eventOut->hasPayload = true;
  eventOut->x = gravityX_;
  eventOut->y = gravityY_;
  eventOut->z = gravityZ_;
  return true;
}

bool ImuGestureInterpreter::update(
    const ImuSample& sample, bool selfMotionActive, uint32_t nowMs, RobotEvent* eventOut) {
  accelNorm_ = vectorNorm(sample.accelX, sample.accelY, sample.accelZ);
  gyroNorm_ = vectorNorm(sample.gyroX, sample.gyroY, sample.gyroZ);
  jerk_ = vectorNorm(
      sample.accelX - lastAccelX_, sample.accelY - lastAccelY_, sample.accelZ - lastAccelZ_);
  lastAccelX_ = sample.accelX;
  lastAccelY_ = sample.accelY;
  lastAccelZ_ = sample.accelZ;

  if (!initialized_) {
    gravityX_ = sample.accelX;
    gravityY_ = sample.accelY;
    gravityZ_ = sample.accelZ;
    initialized_ = true;
  } else {
    constexpr float kGravityAlpha = 0.08f;
    gravityX_ += (sample.accelX - gravityX_) * kGravityAlpha;
    gravityY_ += (sample.accelY - gravityY_) * kGravityAlpha;
    gravityZ_ += (sample.accelZ - gravityZ_) * kGravityAlpha;
  }

  const bool normStable = accelNorm_ >= 0.82f && accelNorm_ <= 1.18f;
  const bool stationary = normStable && gyroNorm_ < 12.0f && jerk_ < 0.10f;

  if (!calibrated_ && stationary && !selfMotionActive) {
    constexpr float kCalibrationAlpha = 0.10f;
    baselineX_ += (gravityX_ - baselineX_) * kCalibrationAlpha;
    baselineY_ += (gravityY_ - baselineY_) * kCalibrationAlpha;
    baselineZ_ += (gravityZ_ - baselineZ_) * kCalibrationAlpha;
    if (++calibrationSamples_ >= 32) calibrated_ = true;
  } else if (!calibrated_ && !stationary) {
    calibrationSamples_ = 0;
  }

  if (selfMotionActive) {
    motionSinceMs_ = 0;
    stationarySinceMs_ = 0;
  } else if (stationary) {
    motionSinceMs_ = 0;
    if (stationarySinceMs_ == 0) stationarySinceMs_ = nowMs;
  } else {
    stationarySinceMs_ = 0;
    if (motionSinceMs_ == 0) motionSinceMs_ = nowMs;
  }

  const bool extremeImpact = jerk_ > 1.75f || gyroNorm_ > 450.0f;
  const bool ordinaryShake = !selfMotionActive && (jerk_ > 0.65f || gyroNorm_ > 170.0f);
  if (extremeImpact || ordinaryShake) {
    if (shakeWindowStartedMs_ == 0 || nowMs - shakeWindowStartedMs_ > 500) {
      shakeWindowStartedMs_ = nowMs;
      shakeHits_ = 0;
    }
    ++shakeHits_;
    const uint8_t requiredHits = extremeImpact && !selfMotionActive ? 1 : 2;
    if (shakeHits_ >= requiredHits && (lastShakeMs_ == 0 || nowMs - lastShakeMs_ >= 2000)) {
      lastShakeMs_ = nowMs;
      shakeHits_ = 0;
      const float strength = clamp01((jerk_ + gyroNorm_ / 250.0f) * 0.55f);
      return emit(EventType::Shaken, strength, nowMs, eventOut);
    }
  }

  if (!calibrated_) return false;

  const float tiltStrength = 1.0f - normalizedDot(
      gravityX_, gravityY_, gravityZ_, baselineX_, baselineY_, baselineZ_);
  const bool meaningfulMotion =
      !selfMotionActive && (fabsf(accelNorm_ - 1.0f) > 0.16f || gyroNorm_ > 28.0f || tiltStrength > 0.08f);
  if (!pickedUp_ && meaningfulMotion && motionSinceMs_ != 0 && nowMs - motionSinceMs_ >= 320) {
    pickedUp_ = true;
    stationarySinceMs_ = 0;
    return emit(EventType::PickedUp, 0.45f + tiltStrength * 2.0f, nowMs, eventOut);
  }

  if (pickedUp_ && !selfMotionActive && stationarySinceMs_ != 0 &&
      nowMs - stationarySinceMs_ >= 1200) {
    pickedUp_ = false;
    baselineX_ = gravityX_;
    baselineY_ = gravityY_;
    baselineZ_ = gravityZ_;
    lastTiltStrength_ = 0.0f;
    return emit(EventType::PutDown, 0.75f, nowMs, eventOut);
  }

  if (!selfMotionActive && tiltStrength >= 0.07f &&
      fabsf(tiltStrength - lastTiltStrength_) >= 0.035f &&
      (lastTiltMs_ == 0 || nowMs - lastTiltMs_ >= 800)) {
    lastTiltMs_ = nowMs;
    lastTiltStrength_ = tiltStrength;
    return emit(EventType::Tilted, 0.25f + tiltStrength * 3.0f, nowMs, eventOut);
  }

  if (!pickedUp_ && stationary && !selfMotionActive) {
    constexpr float kBaselineAlpha = 0.004f;
    baselineX_ += (gravityX_ - baselineX_) * kBaselineAlpha;
    baselineY_ += (gravityY_ - baselineY_) * kBaselineAlpha;
    baselineZ_ += (gravityZ_ - baselineZ_) * kBaselineAlpha;
  }
  return false;
}

bool ImuAdapter::begin(uint32_t nowMs) {
  telemetry_ = ImuAdapterTelemetry {};
  telemetry_.enabled = STACKCHAN_ENABLE_IMU != 0;
  interpreter_.reset(nowMs);
#if STACKCHAN_IMU_HARDWARE_AVAILABLE
  telemetry_.ready = M5.Imu.isEnabled();
#else
  telemetry_.ready = !telemetry_.enabled;
#endif
  return telemetry_.ready;
}

bool ImuAdapter::poll(uint32_t nowMs, bool selfMotionActive, RobotEvent* eventOut) {
  if (!telemetry_.enabled || !telemetry_.ready || eventOut == nullptr) return false;
  if (telemetry_.lastSampleMs != 0 &&
      nowMs - telemetry_.lastSampleMs < STACKCHAN_IMU_SAMPLE_PERIOD_MS) {
    return false;
  }
  telemetry_.lastSampleMs = nowMs;

  ImuSample sample;
#if STACKCHAN_IMU_HARDWARE_AVAILABLE
  constexpr uint8_t kReadAttempts = STACKCHAN_IMU_READ_ATTEMPTS > 0
      ? STACKCHAN_IMU_READ_ATTEMPTS
      : 1;
  m5::IMU_Class::imu_data_t imuData;
  const ImuReadAttemptResult readResult = readImuSampleWithRetry(
      kReadAttempts,
      [&imuData]() {
        constexpr uint8_t kRequiredSensors =
            static_cast<uint8_t>(m5::IMU_Class::sensor_mask_accel) |
            static_cast<uint8_t>(m5::IMU_Class::sensor_mask_gyro);
        const uint8_t sensors = static_cast<uint8_t>(M5.Imu.update());
        if ((sensors & kRequiredSensors) != kRequiredSensors) return false;
        M5.Imu.getImuData(&imuData);
        return true;
      },
      [](uint8_t retryNumber) { delay(imuReadRetryBackoffMs(retryNumber)); });
  accountImuReadResult(&telemetry_, readResult);
  if (!readResult.ok) {
    return false;
  }
  sample.accelX = imuData.accel.x;
  sample.accelY = imuData.accel.y;
  sample.accelZ = imuData.accel.z;
  sample.gyroX = imuData.gyro.x;
  sample.gyroY = imuData.gyro.y;
  sample.gyroZ = imuData.gyro.z;
#else
  ImuReadAttemptResult readResult;
  readResult.attempts = 1;
  accountImuReadResult(&telemetry_, readResult, 1);
  return false;
#endif

  ++telemetry_.samples;
  telemetry_.selfMotionFiltered = selfMotionActive;
  if (selfMotionActive) ++telemetry_.selfMotionSamples;
  const bool published = interpreter_.update(sample, selfMotionActive, nowMs, eventOut);
  telemetry_.calibrated = interpreter_.calibrated();
  telemetry_.pickedUp = interpreter_.pickedUp();
  telemetry_.accelNorm = interpreter_.accelNorm();
  telemetry_.gyroNorm = interpreter_.gyroNorm();
  telemetry_.gravityX = interpreter_.gravityX();
  telemetry_.gravityY = interpreter_.gravityY();
  telemetry_.gravityZ = interpreter_.gravityZ();
  if (!published) return false;

  ++telemetry_.eventsPublished;
  if (selfMotionActive) {
    ++telemetry_.selfMotionEvents;
  } else {
    ++telemetry_.externalEvents;
  }
  telemetry_.lastEventMs = nowMs;
  telemetry_.lastEventType = static_cast<uint8_t>(eventOut->type);
  telemetry_.lastEventSelfMotion = selfMotionActive;
  telemetry_.lastEventStrength = eventOut->strength;
  telemetry_.lastEventJerk = interpreter_.jerk();
  telemetry_.lastEventAccelNorm = interpreter_.accelNorm();
  telemetry_.lastEventGyroNorm = interpreter_.gyroNorm();
  switch (eventOut->type) {
    case EventType::PickedUp: ++telemetry_.pickupEvents; break;
    case EventType::PutDown: ++telemetry_.putdownEvents; break;
    case EventType::Shaken: ++telemetry_.shakeEvents; break;
    case EventType::Tilted: ++telemetry_.tiltEvents; break;
    default: break;
  }
  return true;
}

}  // namespace stackchan
