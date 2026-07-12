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

struct BodyFeedbackTelemetry {
  uint32_t renderedFrames = 0;
  uint32_t modeTransitions = 0;
  uint32_t lastRenderMs = 0;
  uint8_t lastChannelStep = 0;
  uint8_t maxChannelStep = 0;
  bool transitionActive = false;
  CharacterMode currentMode = CharacterMode::Boot;
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
                      bool protectedMode = false);

  const BodyFeedbackTelemetry& telemetry() const {
    return telemetry_;
  }

 private:
  uint32_t begunAtMs_ = 0;
  uint32_t micPulseAtMs_ = 0;
  uint32_t touchPulseAtMs_ = 0;
  BodyTouchZone touchZone_ = BodyTouchZone::None;
  float touchStrength_ = 0.0f;
  float smoothedBaseChannels_[3] = {};
  float smoothedChannels_[kBodyRgbLedCount][3] = {};
  bool smoothingReady_ = false;
  bool modeReady_ = false;
  BodyFeedbackTelemetry telemetry_;
};

}  // namespace stackchan
