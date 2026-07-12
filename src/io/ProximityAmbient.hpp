#pragma once

#include <stddef.h>
#include <stdint.h>

namespace stackchan {

constexpr uint8_t kLtr553Address = 0x23;
constexpr uint8_t kLtr553SampleStartRegister = 0x88;
constexpr size_t kLtr553SampleRegisterCount = 7;

struct ProximityAmbientSample {
  uint16_t proximityRaw = 0;
  uint16_t ambientChannel0Raw = 0;
  uint16_t ambientChannel1Raw = 0;
  uint16_t ambientCombinedRaw = 0;
  uint8_t status = 0;
  bool proximitySaturated = false;
};

bool decodeLtr553Sample(const uint8_t* registers,
                        size_t registerCount,
                        ProximityAmbientSample* sampleOut);

enum class PresenceTransition : uint8_t {
  None,
  Approached,
  Departed,
};

struct PresenceFilterConfig {
  uint16_t enterThreshold = 0;
  uint16_t exitThreshold = 0;
  uint8_t enterSamples = 2;
  uint8_t exitSamples = 4;
};

class PresenceFilter {
 public:
  explicit PresenceFilter(PresenceFilterConfig config = {});

  void reset();
  PresenceTransition update(uint16_t proximityRaw);
  bool near() const { return near_; }

 private:
  PresenceFilterConfig config_;
  bool near_ = false;
  uint8_t enterCount_ = 0;
  uint8_t exitCount_ = 0;
};

}  // namespace stackchan
