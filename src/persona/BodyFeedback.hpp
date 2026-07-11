#pragma once

#include <Arduino.h>

#include "persona/StateMatrix.hpp"

namespace stackchan {

constexpr uint8_t kBodyRgbLedCount = 12;

struct BodyRgbColor {
  uint8_t r = 0;
  uint8_t g = 0;
  uint8_t b = 0;

  bool operator==(const BodyRgbColor& other) const {
    return r == other.r && g == other.g && b == other.b;
  }
};

struct BodyRgbFrame {
  BodyRgbColor leds[kBodyRgbLedCount];
  uint8_t peakChannel = 0;
};

enum class BodyTouchZone : uint8_t {
  None = 0,
  Front,
  Middle,
  Back,
};

class BodyFeedback {
 public:
  void begin(uint32_t nowMs = 0);
  void notifyMicActivated(uint32_t nowMs);
  void notifyTouch(BodyTouchZone zone, float strength, uint32_t nowMs);
  BodyRgbFrame render(const RobotFrame& frame,
                      float speechEnvelope,
                      uint32_t nowMs,
                      float powerScale = 1.0f,
                      bool protectedMode = false) const;

 private:
  uint32_t begunAtMs_ = 0;
  uint32_t micPulseAtMs_ = 0;
  uint32_t touchPulseAtMs_ = 0;
  BodyTouchZone touchZone_ = BodyTouchZone::None;
  float touchStrength_ = 0.0f;
};

}  // namespace stackchan
