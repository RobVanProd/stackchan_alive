#pragma once

#include <Arduino.h>

namespace stackchan {

constexpr uint8_t kSleepCueGlyphs = 3;

// One drifting "Z" above a sleeping face.
struct SleepGlyph {
  float x = 0.0f;
  float y = 0.0f;
  // Half-height in pixels; the glyph grows a little as it rises.
  float size = 0.0f;
  // 0 invisible .. 1 fully lit.
  float alpha = 0.0f;
};

struct SleepCueGeometry {
  bool active = false;
  uint8_t count = 0;
  SleepGlyph glyphs[kSleepCueGlyphs];
};

// Emits a slow stack of rising, fading Zs while the character is asleep, and
// fades them out when it wakes. Drawn from three lines per glyph, so there is no
// font or bitmap dependency.
class SleepCue {
 public:
  void reset(uint32_t nowMs);

  // asleep drives whether new glyphs are emitted. Existing ones always finish
  // their rise so waking does not clip them off mid-air.
  void update(uint32_t nowMs, bool asleep);

  // anchorX/anchorY is where glyphs are born, normally just above one eye.
  SleepCueGeometry geometry(float anchorX, float anchorY) const;

  bool idle() const {
    return !anyVisible();
  }

 private:
  // Normalised 0..1 progress of each in-flight glyph; negative means unused.
  float progress_[kSleepCueGlyphs];
  uint32_t nextEmitAtMs_ = 0;
  uint32_t lastMs_ = 0;
  bool hasLast_ = false;

  bool anyVisible() const;
};

}  // namespace stackchan
