#include "io/BodyTouch.hpp"

namespace stackchan {

namespace {
constexpr uint32_t kHoldMs = 700;
constexpr uint32_t kMinSwipeIntervalMs = 30;
constexpr uint32_t kMaxSwipeIntervalMs = 400;

uint8_t valueForZone(const BodyTouchReading& reading, uint8_t zone) {
  if (zone == 0) {
    return reading.front;
  }
  if (zone == 1) {
    return reading.middle;
  }
  return reading.back;
}

BodyTouchZone zoneFromIndex(uint8_t zone) {
  return zone == 0 ? BodyTouchZone::Front
                   : (zone == 1 ? BodyTouchZone::Middle : BodyTouchZone::Back);
}
}  // namespace

BodyTouchReading decodeBodyTouchRaw(uint8_t raw) {
  BodyTouchReading reading;
  // Si12T reports back/middle/front in ascending bit pairs. Expose physical order.
  reading.back = raw & 0x03;
  reading.middle = (raw >> 2) & 0x03;
  reading.front = (raw >> 4) & 0x03;
  return reading;
}

void BodyTouchInterpreter::reset() {
  firstTouchMs_ = 0;
  interactionEmitted_ = false;
  for (uint8_t i = 0; i < 3; ++i) {
    zoneStartMs_[i] = 0;
    maxIntensity_[i] = 0;
    zoneSeen_[i] = false;
  }
}

BodyTouchInteraction BodyTouchInterpreter::update(const BodyTouchReading& reading, uint32_t nowMs) {
  if (!reading.any()) {
    BodyTouchInteraction released;
    if (firstTouchMs_ != 0 && !interactionEmitted_) {
      uint8_t dominant = 0;
      for (uint8_t i = 1; i < 3; ++i) {
        if (maxIntensity_[i] > maxIntensity_[dominant]) {
          dominant = i;
        }
      }
      released.gesture = BodyTouchGesture::Tap;
      released.zone = zoneFromIndex(dominant);
      released.intensity = maxIntensity_[dominant];
    }
    reset();
    return released;
  }

  if (firstTouchMs_ == 0) {
    firstTouchMs_ = nowMs == 0 ? 1 : nowMs;
  }
  for (uint8_t i = 0; i < 3; ++i) {
    const uint8_t intensity = valueForZone(reading, i);
    maxIntensity_[i] = max(maxIntensity_[i], intensity);
    if (intensity != 0 && !zoneSeen_[i]) {
      zoneSeen_[i] = true;
      zoneStartMs_[i] = nowMs;
    }
  }

  if (!interactionEmitted_ && zoneSeen_[0] && zoneSeen_[1] && zoneSeen_[2]) {
    const uint32_t frontToMiddle = zoneStartMs_[1] - zoneStartMs_[0];
    const uint32_t middleToBack = zoneStartMs_[2] - zoneStartMs_[1];
    const uint32_t backToMiddle = zoneStartMs_[1] - zoneStartMs_[2];
    const uint32_t middleToFront = zoneStartMs_[0] - zoneStartMs_[1];
    const bool forward = frontToMiddle > kMinSwipeIntervalMs && middleToBack > kMinSwipeIntervalMs &&
                         frontToMiddle < kMaxSwipeIntervalMs && middleToBack < kMaxSwipeIntervalMs;
    const bool backward = backToMiddle > kMinSwipeIntervalMs && middleToFront > kMinSwipeIntervalMs &&
                          backToMiddle < kMaxSwipeIntervalMs && middleToFront < kMaxSwipeIntervalMs;
    if (forward || backward) {
      interactionEmitted_ = true;
      return {forward ? BodyTouchGesture::SwipeForward : BodyTouchGesture::SwipeBackward,
              forward ? BodyTouchZone::Back : BodyTouchZone::Front,
              3};
    }
  }

  if (!interactionEmitted_ && nowMs - firstTouchMs_ >= kHoldMs) {
    uint8_t dominant = 0;
    for (uint8_t i = 1; i < 3; ++i) {
      if (maxIntensity_[i] > maxIntensity_[dominant]) {
        dominant = i;
      }
    }
    interactionEmitted_ = true;
    return {BodyTouchGesture::Hold, zoneFromIndex(dominant), maxIntensity_[dominant]};
  }
  return {};
}

}  // namespace stackchan
