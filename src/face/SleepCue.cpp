#include "face/SleepCue.hpp"

#include <math.h>

namespace stackchan {

namespace {
// One glyph every couple of seconds is plenty; faster reads as a cartoon.
constexpr uint32_t kEmitIntervalMs = 2100;
// How long a single Z takes to rise and fade.
constexpr float kRiseSeconds = 3.2f;
// How far it travels while rising.
constexpr float kRisePixels = 26.0f;
constexpr float kDriftPixels = 12.0f;
constexpr float kSizeStart = 4.0f;
constexpr float kSizeEnd = 8.0f;
// A stalled task must not jump the animation forward.
constexpr uint32_t kMaxStepMs = 200;
}  // namespace

void SleepCue::reset(uint32_t nowMs) {
  for (uint8_t i = 0; i < kSleepCueGlyphs; ++i) {
    progress_[i] = -1.0f;
  }
  nextEmitAtMs_ = nowMs;
  lastMs_ = nowMs;
  hasLast_ = false;
}

bool SleepCue::anyVisible() const {
  for (uint8_t i = 0; i < kSleepCueGlyphs; ++i) {
    if (progress_[i] >= 0.0f) {
      return true;
    }
  }
  return false;
}

void SleepCue::update(uint32_t nowMs, bool asleep) {
  uint32_t stepMs = hasLast_ ? (nowMs - lastMs_) : 0;
  if (stepMs > kMaxStepMs) {
    stepMs = kMaxStepMs;
  }
  lastMs_ = nowMs;
  hasLast_ = true;

  const float dt = static_cast<float>(stepMs) * 0.001f;
  for (uint8_t i = 0; i < kSleepCueGlyphs; ++i) {
    if (progress_[i] < 0.0f) {
      continue;
    }
    progress_[i] += dt / kRiseSeconds;
    if (progress_[i] >= 1.0f) {
      progress_[i] = -1.0f;
    }
  }

  if (!asleep) {
    // Stop emitting; in-flight glyphs finish on their own.
    nextEmitAtMs_ = nowMs;
    return;
  }

  if (static_cast<int32_t>(nowMs - nextEmitAtMs_) < 0) {
    return;
  }
  for (uint8_t i = 0; i < kSleepCueGlyphs; ++i) {
    if (progress_[i] < 0.0f) {
      progress_[i] = 0.0f;
      nextEmitAtMs_ = nowMs + kEmitIntervalMs;
      return;
    }
  }
  // All slots busy; try again shortly.
  nextEmitAtMs_ = nowMs + (kEmitIntervalMs / 4u);
}

SleepCueGeometry SleepCue::geometry(float anchorX, float anchorY) const {
  SleepCueGeometry out;
  for (uint8_t i = 0; i < kSleepCueGlyphs; ++i) {
    const float p = progress_[i];
    if (p < 0.0f) {
      continue;
    }
    SleepGlyph& glyph = out.glyphs[out.count++];
    // Rise, drift sideways, grow, and fade out over the last third.
    glyph.x = anchorX + sinf(p * 2.2f) * kDriftPixels;
    glyph.y = anchorY - p * kRisePixels;
    glyph.size = kSizeStart + (kSizeEnd - kSizeStart) * p;
    glyph.alpha = p < 0.15f ? (p / 0.15f) : (p > 0.65f ? (1.0f - (p - 0.65f) / 0.35f) : 1.0f);
    glyph.alpha = constrain(glyph.alpha, 0.0f, 1.0f);
  }
  out.active = out.count > 0;
  return out;
}

}  // namespace stackchan
