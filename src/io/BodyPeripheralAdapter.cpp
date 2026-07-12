#include "io/BodyPeripheralAdapter.hpp"

#if __has_include(<M5Unified.h>)
#include <M5Unified.h>
#define STACKCHAN_BODY_HAS_M5_I2C 1
#else
#define STACKCHAN_BODY_HAS_M5_I2C 0
#endif

#include <string.h>

namespace stackchan {

namespace {
constexpr uint8_t kPy32Address = 0x6F;
constexpr uint8_t kTouchAddress = 0x68;
constexpr uint32_t kBodyI2cFrequency = 100000;
constexpr uint8_t kPy32VersionRegister = 0x02;
constexpr uint8_t kPy32GpioModeHigh = 0x04;
constexpr uint8_t kPy32GpioPullUpHigh = 0x0A;
constexpr uint8_t kPy32GpioPullDownHigh = 0x0C;
constexpr uint8_t kPy32GpioDriveHigh = 0x14;
constexpr uint8_t kPy32LedConfig = 0x24;
constexpr uint8_t kPy32LedRam = 0x30;
constexpr uint8_t kRgbPin13Mask = 0x20;
constexpr uint8_t kRgbLedCount = 12;
constexpr uint8_t kRgbWriteAttempts = 2;
constexpr uint32_t kRgbPeriodMs = 50;
constexpr uint32_t kTouchPeriodMs = 30;
constexpr uint32_t kPeripheralRetryMs = 5000;

float touchZoneX(BodyTouchZone zone) {
  if (zone == BodyTouchZone::Front) {
    return -1.0f;
  }
  if (zone == BodyTouchZone::Back) {
    return 1.0f;
  }
  return 0.0f;
}

float touchGestureY(BodyTouchGesture gesture) {
  if (gesture == BodyTouchGesture::SwipeForward) {
    return 1.0f;
  }
  if (gesture == BodyTouchGesture::SwipeBackward) {
    return -1.0f;
  }
  if (gesture == BodyTouchGesture::Hold) {
    return 0.5f;
  }
  return 0.0f;
}
}  // namespace

bool BodyPeripheralAdapter::begin(uint32_t nowMs) {
  telemetry_ = BodyPeripheralTelemetry {};
  touchInterpreter_.reset();
  hasLastFrame_ = false;
  lastRetryMs_ = nowMs;
  ++telemetry_.beginAttempts;
  telemetry_.rgbReady = !telemetry_.rgbEnabled || initializeRgb();
  telemetry_.touchReady = !telemetry_.touchEnabled || initializeTouch();
  return telemetry_.rgbReady && telemetry_.touchReady;
}

bool BodyPeripheralAdapter::initializeRgb() {
#if STACKCHAN_BODY_HAS_M5_I2C && STACKCHAN_ENABLE_BODY_RGB
  if (!M5.In_I2C.isEnabled() || !M5.In_I2C.scanID(kPy32Address, kBodyI2cFrequency)) {
    return false;
  }
  const uint8_t version = M5.In_I2C.readRegister8(kPy32Address, kPy32VersionRegister, kBodyI2cFrequency);
  if (version == 0 || version == 0xFF) {
    return false;
  }
  bool ok = M5.In_I2C.bitOn(kPy32Address, kPy32GpioModeHigh, kRgbPin13Mask, kBodyI2cFrequency);
  ok &= M5.In_I2C.bitOff(kPy32Address, kPy32GpioPullDownHigh, kRgbPin13Mask, kBodyI2cFrequency);
  ok &= M5.In_I2C.bitOn(kPy32Address, kPy32GpioPullUpHigh, kRgbPin13Mask, kBodyI2cFrequency);
  ok &= M5.In_I2C.bitOff(kPy32Address, kPy32GpioDriveHigh, kRgbPin13Mask, kBodyI2cFrequency);
  ok &= M5.In_I2C.writeRegister8(kPy32Address, kPy32LedConfig, kRgbLedCount, kBodyI2cFrequency);
  if (!ok) {
    return false;
  }
  uint8_t off[kRgbLedCount * 2] = {};
  ok = M5.In_I2C.writeRegister(kPy32Address, kPy32LedRam, off, sizeof(off), kBodyI2cFrequency);
  ok &= M5.In_I2C.writeRegister8(
      kPy32Address, kPy32LedConfig, static_cast<uint8_t>(kRgbLedCount | 0x40), kBodyI2cFrequency);
  return ok;
#else
  return STACKCHAN_ENABLE_BODY_RGB == 0;
#endif
}

bool BodyPeripheralAdapter::initializeTouch() {
#if STACKCHAN_BODY_HAS_M5_I2C && STACKCHAN_ENABLE_BODY_TOUCH
  if (!M5.In_I2C.isEnabled() || !M5.In_I2C.scanID(kTouchAddress, kBodyI2cFrequency)) {
    return false;
  }
  bool ok = true;
  for (uint8_t reg = 0x0A; reg <= 0x0F; ++reg) {
    ok &= M5.In_I2C.writeRegister8(kTouchAddress, reg, 0x00, kBodyI2cFrequency);
  }
  ok &= M5.In_I2C.writeRegister8(kTouchAddress, 0x09, 0x0F, kBodyI2cFrequency);
  ok &= M5.In_I2C.writeRegister8(kTouchAddress, 0x09, 0x07, kBodyI2cFrequency);
  ok &= M5.In_I2C.writeRegister8(kTouchAddress, 0x08, 0x22, kBodyI2cFrequency);
  for (uint8_t reg = 0x02; reg <= 0x06; ++reg) {
    ok &= M5.In_I2C.writeRegister8(kTouchAddress, reg, 0xCC, kBodyI2cFrequency);
  }
  return ok;
#else
  return STACKCHAN_ENABLE_BODY_TOUCH == 0;
#endif
}

bool BodyPeripheralAdapter::sameRgbFrame(const BodyRgbFrame& frame) const {
  if (!hasLastFrame_) {
    return false;
  }
  for (uint8_t i = 0; i < kBodyRgbLedCount; ++i) {
    if (!(lastFrame_.leds[i] == frame.leds[i])) {
      return false;
    }
  }
  return true;
}

bool BodyPeripheralAdapter::writeRgb(const BodyRgbFrame& frame, uint32_t nowMs) {
  if (!telemetry_.rgbEnabled) {
    return true;
  }
  if (!telemetry_.rgbReady) {
    if (nowMs - lastRetryMs_ < kPeripheralRetryMs) {
      return false;
    }
    lastRetryMs_ = nowMs;
    ++telemetry_.beginAttempts;
    telemetry_.rgbReady = initializeRgb();
    if (!telemetry_.rgbReady) {
      return false;
    }
  }
  if (telemetry_.lastRgbWriteMs != 0 && nowMs - telemetry_.lastRgbWriteMs < kRgbPeriodMs) {
    return true;
  }
  if (sameRgbFrame(frame)) {
    ++telemetry_.rgbSkippedUnchanged;
    return true;
  }
#if STACKCHAN_BODY_HAS_M5_I2C && STACKCHAN_ENABLE_BODY_RGB
  uint8_t packed[kRgbLedCount * 2];
  for (uint8_t i = 0; i < kRgbLedCount; ++i) {
    const BodyRgbColor& color = frame.leds[i];
    const uint16_t rgb565 = static_cast<uint16_t>(((color.r & 0xF8) << 8) |
                                                  ((color.g & 0xFC) << 3) |
                                                  (color.b >> 3));
    packed[i * 2] = rgb565 & 0xFF;
    packed[i * 2 + 1] = rgb565 >> 8;
  }
  bool ok = false;
  for (uint8_t attempt = 0; attempt < kRgbWriteAttempts; ++attempt) {
    if (attempt > 0) {
      ++telemetry_.rgbWriteRetries;
    }
    ok = M5.In_I2C.writeRegister(
        kPy32Address, kPy32LedRam, packed, sizeof(packed), kBodyI2cFrequency);
    ok = M5.In_I2C.writeRegister8(
             kPy32Address,
             kPy32LedConfig,
             static_cast<uint8_t>(kRgbLedCount | 0x40),
             kBodyI2cFrequency) &&
         ok;
    if (ok) {
      if (attempt > 0) {
        ++telemetry_.rgbWriteRecoveries;
      }
      break;
    }
  }
  if (!ok) {
    ++telemetry_.rgbWriteFailures;
    telemetry_.rgbReady = false;
    return false;
  }
#endif
  lastFrame_ = frame;
  hasLastFrame_ = true;
  telemetry_.lastRgbWriteMs = nowMs;
  ++telemetry_.rgbFrames;
  return true;
}

bool BodyPeripheralAdapter::pollTouch(uint32_t nowMs,
                                      RobotEvent* eventOut,
                                      BodyTouchInteraction* interactionOut) {
  if (interactionOut != nullptr) {
    *interactionOut = {};
  }
  if (!telemetry_.touchEnabled || eventOut == nullptr) {
    return false;
  }
  if (!telemetry_.touchReady) {
    if (nowMs - lastRetryMs_ < kPeripheralRetryMs) {
      return false;
    }
    lastRetryMs_ = nowMs;
    ++telemetry_.beginAttempts;
    telemetry_.touchReady = initializeTouch();
    if (!telemetry_.touchReady) {
      return false;
    }
  }
  if (telemetry_.lastTouchReadMs != 0 && nowMs - telemetry_.lastTouchReadMs < kTouchPeriodMs) {
    return false;
  }
  telemetry_.lastTouchReadMs = nowMs;
#if STACKCHAN_BODY_HAS_M5_I2C && STACKCHAN_ENABLE_BODY_TOUCH
  uint8_t raw = 0;
  if (!M5.In_I2C.readRegister(kTouchAddress, 0x10, &raw, 1, kBodyI2cFrequency)) {
    ++telemetry_.touchReadFailures;
    return false;
  }
  telemetry_.lastTouchRaw = raw;
  ++telemetry_.touchSamples;
  const BodyTouchInteraction interaction = touchInterpreter_.update(decodeBodyTouchRaw(raw), nowMs);
#else
  const BodyTouchInteraction interaction;
#endif
  if (!interaction.valid()) {
    return false;
  }
  telemetry_.lastGesture = interaction.gesture;
  telemetry_.lastZone = interaction.zone;
  telemetry_.lastTouchEventMs = nowMs;
  ++telemetry_.touchEvents;
  switch (interaction.zone) {
    case BodyTouchZone::Front:
      ++telemetry_.touchFrontEvents;
      break;
    case BodyTouchZone::Middle:
      ++telemetry_.touchMiddleEvents;
      break;
    case BodyTouchZone::Back:
      ++telemetry_.touchBackEvents;
      break;
    case BodyTouchZone::None:
      break;
  }
  switch (interaction.gesture) {
    case BodyTouchGesture::Tap:
      ++telemetry_.touchTapEvents;
      break;
    case BodyTouchGesture::Hold:
      ++telemetry_.touchHoldEvents;
      break;
    case BodyTouchGesture::SwipeForward:
      ++telemetry_.touchSwipeForwardEvents;
      break;
    case BodyTouchGesture::SwipeBackward:
      ++telemetry_.touchSwipeBackwardEvents;
      break;
    case BodyTouchGesture::None:
      break;
  }
  if (interactionOut != nullptr) {
    *interactionOut = interaction;
  }
  eventOut->type = EventType::UserTouched;
  eventOut->timestampMs = nowMs;
  eventOut->strength = constrain(interaction.intensity / 3.0f, 0.2f, 1.0f);
  eventOut->hasPayload = true;
  eventOut->x = touchZoneX(interaction.zone);
  eventOut->y = touchGestureY(interaction.gesture);
  eventOut->z = interaction.intensity / 3.0f;
  return true;
}

void BodyPeripheralAdapter::allOff(uint32_t nowMs) {
  writeRgb(BodyRgbFrame {}, nowMs);
}

}  // namespace stackchan
