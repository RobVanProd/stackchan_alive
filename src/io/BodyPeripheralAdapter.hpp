#pragma once

#include <Arduino.h>

#include "io/BodyTouch.hpp"
#include "io/ProximityAmbient.hpp"
#include "persona/EventBus.hpp"
#include "persona/BodyFeedback.hpp"

#ifndef STACKCHAN_ENABLE_BODY_RGB
#define STACKCHAN_ENABLE_BODY_RGB 0
#endif

#ifndef STACKCHAN_ENABLE_BODY_TOUCH
#define STACKCHAN_ENABLE_BODY_TOUCH 0
#endif

#ifndef STACKCHAN_ENABLE_PROXIMITY_AMBIENT
#define STACKCHAN_ENABLE_PROXIMITY_AMBIENT 0
#endif

#ifndef STACKCHAN_LTR553_NEAR_ENTER_THRESHOLD
#define STACKCHAN_LTR553_NEAR_ENTER_THRESHOLD 0
#endif

#ifndef STACKCHAN_LTR553_NEAR_EXIT_THRESHOLD
#define STACKCHAN_LTR553_NEAR_EXIT_THRESHOLD 0
#endif

namespace stackchan {

struct BodyPeripheralTelemetry {
  bool rgbEnabled = STACKCHAN_ENABLE_BODY_RGB != 0;
  bool touchEnabled = STACKCHAN_ENABLE_BODY_TOUCH != 0;
  bool proximityAmbientEnabled = STACKCHAN_ENABLE_PROXIMITY_AMBIENT != 0;
  bool rgbReady = false;
  bool touchReady = false;
  bool proximityAmbientReady = false;
  bool proximityNear = false;
  bool proximitySaturated = false;
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
  uint32_t proximityAmbientSamples = 0;
  uint32_t proximityAmbientReadRetries = 0;
  uint32_t proximityAmbientReadRecoveries = 0;
  uint32_t proximityAmbientReadFailures = 0;
  uint32_t proximityAmbientConsecutiveFailures = 0;
  uint32_t proximityAmbientMaxConsecutiveFailures = 0;
  uint32_t proximityApproachEvents = 0;
  uint32_t proximityDepartureEvents = 0;
  uint32_t lastRgbWriteMs = 0;
  uint32_t lastTouchReadMs = 0;
  uint32_t lastTouchEventMs = 0;
  uint32_t lastProximityAmbientReadMs = 0;
  uint32_t lastProximityEventMs = 0;
  uint8_t lastTouchRaw = 0;
  uint16_t proximityRaw = 0;
  uint16_t ambientChannel0Raw = 0;
  uint16_t ambientChannel1Raw = 0;
  uint16_t ambientCombinedRaw = 0;
  uint8_t proximityAmbientStatus = 0;
  BodyTouchGesture lastGesture = BodyTouchGesture::None;
  BodyTouchZone lastZone = BodyTouchZone::None;
};

class BodyPeripheralAdapter {
 public:
  bool begin(uint32_t nowMs = 0);
  bool writeRgb(const BodyRgbFrame& frame, uint32_t nowMs);
  bool pollTouch(uint32_t nowMs, RobotEvent* eventOut, BodyTouchInteraction* interactionOut = nullptr);
  bool pollProximityAmbient(uint32_t nowMs, RobotEvent* eventOut = nullptr);
  void allOff(uint32_t nowMs);

  const BodyPeripheralTelemetry& telemetry() const {
    return telemetry_;
  }

 private:
  bool initializeRgb();
  bool initializeTouch();
  bool initializeProximityAmbient();
  bool sameRgbFrame(const BodyRgbFrame& frame) const;

  BodyPeripheralTelemetry telemetry_;
  BodyTouchInterpreter touchInterpreter_;
  PresenceFilter presenceFilter_ {{STACKCHAN_LTR553_NEAR_ENTER_THRESHOLD,
                                   STACKCHAN_LTR553_NEAR_EXIT_THRESHOLD,
                                   2,
                                   4}};
  BodyRgbFrame lastFrame_;
  bool hasLastFrame_ = false;
  uint32_t lastRetryMs_ = 0;
  uint32_t lastProximityAmbientRetryMs_ = 0;
};

}  // namespace stackchan
