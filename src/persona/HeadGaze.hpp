#pragma once

#include <Arduino.h>

namespace stackchan {

// Where the head is idly pointed.
//
// This replaces two incommensurate sine waves on yaw and pitch. Those were
// smooth, but a Lissajous figure has no intent behind it: the head swayed
// continuously without ever looking *at* anything, which reads as aimless.
//
// The eyes already do the right thing in FaceAnimator: fixate, jump, settle.
// This gives the head the same treatment at a slower cadence, because heads
// move less often than eyes do. Excursion limits are unchanged from the sine
// version, so servo load and travel stay exactly as before.
class HeadGaze {
 public:
  void reset(uint32_t nowMs);

  // Advances the gaze. yawSpanDeg/pitchSpanDeg are the same amplitude envelopes
  // the sine version used, so the reachable range does not grow.
  void update(uint32_t nowMs, float yawSpanDeg, float pitchSpanDeg, float focus, float arousal);

  float yawDeg() const {
    return yawDeg_;
  }

  float pitchDeg() const {
    return pitchDeg_;
  }

  // True while travelling toward a new target rather than holding one.
  bool shifting() const {
    return shifting_;
  }

  uint32_t holdMs() const {
    return holdMs_;
  }

 private:
  float yawDeg_ = 0.0f;
  float pitchDeg_ = 0.0f;
  float targetYawDeg_ = 0.0f;
  float targetPitchDeg_ = 0.0f;
  uint32_t retargetAtMs_ = 0;
  uint32_t holdMs_ = 0;
  uint32_t shifts_ = 0;
  uint32_t lastMs_ = 0;
  bool hasLast_ = false;
  bool shifting_ = false;

  void chooseTarget(float yawSpanDeg, float pitchSpanDeg, float focus);
  static uint32_t hash32(uint32_t value);
  // Signed value in [-1, 1] from a hash, for deterministic jitter.
  static float signedUnit(uint32_t hash);
};

}  // namespace stackchan
