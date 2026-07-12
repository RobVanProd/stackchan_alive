#pragma once

#include <Arduino.h>

#include "io/BodyTouch.hpp"
#include "persona/EventBus.hpp"
#include "persona/BodyFeedback.hpp"

#ifndef STACKCHAN_ENABLE_BODY_RGB
#define STACKCHAN_ENABLE_BODY_RGB 0
#endif

#ifndef STACKCHAN_ENABLE_BODY_TOUCH
#define STACKCHAN_ENABLE_BODY_TOUCH 0
#endif

namespace stackchan {

struct BodyPeripheralTelemetry {
  bool rgbEnabled = STACKCHAN_ENABLE_BODY_RGB != 0;
  bool touchEnabled = STACKCHAN_ENABLE_BODY_TOUCH != 0;
  bool rgbReady = false;
  bool touchReady = false;
  uint32_t beginAttempts = 0;
  uint32_t rgbFrames = 0;
  uint32_t rgbSkippedUnchanged = 0;
  uint32_t rgbWriteRetries = 0;
  uint32_t rgbWriteRecoveries = 0;
  uint32_t rgbWriteFailures = 0;
  uint32_t touchSamples = 0;
  uint32_t touchReadFailures = 0;
  uint32_t touchEvents = 0;
  uint32_t touchFrontEvents = 0;
  uint32_t touchMiddleEvents = 0;
  uint32_t touchBackEvents = 0;
  uint32_t touchTapEvents = 0;
  uint32_t touchHoldEvents = 0;
  uint32_t touchSwipeForwardEvents = 0;
  uint32_t touchSwipeBackwardEvents = 0;
  uint32_t lastRgbWriteMs = 0;
  uint32_t lastTouchReadMs = 0;
  uint32_t lastTouchEventMs = 0;
  uint8_t lastTouchRaw = 0;
  BodyTouchGesture lastGesture = BodyTouchGesture::None;
  BodyTouchZone lastZone = BodyTouchZone::None;
};

class BodyPeripheralAdapter {
 public:
  bool begin(uint32_t nowMs = 0);
  bool writeRgb(const BodyRgbFrame& frame, uint32_t nowMs);
  bool pollTouch(uint32_t nowMs, RobotEvent* eventOut, BodyTouchInteraction* interactionOut = nullptr);
  void allOff(uint32_t nowMs);

  const BodyPeripheralTelemetry& telemetry() const {
    return telemetry_;
  }

 private:
  bool initializeRgb();
  bool initializeTouch();
  bool sameRgbFrame(const BodyRgbFrame& frame) const;

  BodyPeripheralTelemetry telemetry_;
  BodyTouchInterpreter touchInterpreter_;
  BodyRgbFrame lastFrame_;
  bool hasLastFrame_ = false;
  uint32_t lastRetryMs_ = 0;
};

}  // namespace stackchan
