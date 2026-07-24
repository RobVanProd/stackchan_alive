#pragma once

#include <Arduino.h>

namespace stackchan {

// One breathing rhythm, shared by the persona idle layer and the face renderer
// so the body and the face rise and fall together instead of beating against
// each other.
//
// The rhythm runs on an accumulated phase rather than a sine of absolute time.
// That lets every breath pick its own length and depth, which is what stops
// resting motion from reading as machinery. Phase 0 is the top of the inhale.
class BreathRhythm {
 public:
  void reset(uint32_t nowMs);

  // Advances the rhythm and returns displacement in roughly [-1, 1]; a sigh
  // overshoots that range by its depth.
  float update(uint32_t nowMs, float breathHz, bool sleeping);

  uint32_t periodMs() const {
    return periodMs_;
  }

  float depth() const {
    return depth_;
  }

  bool sighing() const {
    return sighing_;
  }

 private:
  float phase_ = 0.0f;
  uint32_t periodMs_ = 0;
  float depth_ = 1.0f;
  uint32_t cycle_ = 0;
  uint32_t cyclesUntilSigh_ = 0;
  uint32_t lastMs_ = 0;
  bool hasLast_ = false;
  bool sighing_ = false;

  void startCycle(float breathHz, bool sleeping);
  static float shape(float phase);
  static uint32_t hash32(uint32_t value);
};

}  // namespace stackchan
