#include "io/ProximityAmbient.hpp"

#include <limits.h>

namespace stackchan {

bool decodeLtr553Sample(const uint8_t* registers,
                        size_t registerCount,
                        ProximityAmbientSample* sampleOut) {
  if (registers == nullptr || sampleOut == nullptr || registerCount < kLtr553SampleRegisterCount) {
    return false;
  }

  ProximityAmbientSample sample;
  sample.ambientChannel1Raw =
      static_cast<uint16_t>((static_cast<uint16_t>(registers[1]) << 8) | registers[0]);
  sample.ambientChannel0Raw =
      static_cast<uint16_t>((static_cast<uint16_t>(registers[3]) << 8) | registers[2]);
  const uint32_t combined =
      static_cast<uint32_t>(sample.ambientChannel0Raw) + sample.ambientChannel1Raw;
  sample.ambientCombinedRaw = static_cast<uint16_t>(combined / 2U);
  sample.status = registers[4];
  sample.proximitySaturated = (registers[6] & 0x80U) != 0;
  sample.proximityRaw =
      static_cast<uint16_t>((static_cast<uint16_t>(registers[6] & 0x07U) << 8) | registers[5]);
  *sampleOut = sample;
  return true;
}

PresenceFilter::PresenceFilter(PresenceFilterConfig config) : config_(config) {
  if (config_.enterSamples == 0) {
    config_.enterSamples = 1;
  }
  if (config_.exitSamples == 0) {
    config_.exitSamples = 1;
  }
  if (config_.enterThreshold != 0 && config_.exitThreshold > config_.enterThreshold) {
    config_.exitThreshold = config_.enterThreshold;
  }
}

void PresenceFilter::reset() {
  near_ = false;
  enterCount_ = 0;
  exitCount_ = 0;
}

PresenceTransition PresenceFilter::update(uint16_t proximityRaw) {
  if (config_.enterThreshold == 0) {
    reset();
    return PresenceTransition::None;
  }

  if (!near_) {
    exitCount_ = 0;
    if (proximityRaw < config_.enterThreshold) {
      enterCount_ = 0;
      return PresenceTransition::None;
    }
    if (enterCount_ < UCHAR_MAX) {
      ++enterCount_;
    }
    if (enterCount_ < config_.enterSamples) {
      return PresenceTransition::None;
    }
    near_ = true;
    enterCount_ = 0;
    return PresenceTransition::Approached;
  }

  enterCount_ = 0;
  if (proximityRaw > config_.exitThreshold) {
    exitCount_ = 0;
    return PresenceTransition::None;
  }
  if (exitCount_ < UCHAR_MAX) {
    ++exitCount_;
  }
  if (exitCount_ < config_.exitSamples) {
    return PresenceTransition::None;
  }
  near_ = false;
  exitCount_ = 0;
  return PresenceTransition::Departed;
}

}  // namespace stackchan
