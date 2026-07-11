#pragma once

#include <Arduino.h>

#include "persona/BodyFeedback.hpp"

namespace stackchan {

struct BodyTouchReading {
  uint8_t front = 0;
  uint8_t middle = 0;
  uint8_t back = 0;

  bool any() const {
    return front != 0 || middle != 0 || back != 0;
  }
};

enum class BodyTouchGesture : uint8_t {
  None = 0,
  Tap,
  Hold,
  SwipeForward,
  SwipeBackward,
};

struct BodyTouchInteraction {
  BodyTouchGesture gesture = BodyTouchGesture::None;
  BodyTouchZone zone = BodyTouchZone::None;
  uint8_t intensity = 0;

  bool valid() const {
    return gesture != BodyTouchGesture::None;
  }
};

BodyTouchReading decodeBodyTouchRaw(uint8_t raw);

class BodyTouchInterpreter {
 public:
  void reset();
  BodyTouchInteraction update(const BodyTouchReading& reading, uint32_t nowMs);

 private:
  uint32_t firstTouchMs_ = 0;
  uint32_t zoneStartMs_[3] = {};
  uint8_t maxIntensity_[3] = {};
  bool zoneSeen_[3] = {};
  bool interactionEmitted_ = false;
};

}  // namespace stackchan
