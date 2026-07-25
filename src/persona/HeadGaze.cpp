#include "persona/HeadGaze.hpp"

#include <math.h>

namespace stackchan {

namespace {
// How long the head holds a pose before shifting. A head that never settles
// reads as nervous; one that holds for a beat reads as attending to something.
// A focused character holds longer and looks around less.
constexpr uint32_t kHoldWanderingMinMs = 1400;
constexpr uint32_t kHoldWanderingSpanMs = 2600;
constexpr uint32_t kHoldFocusedMinMs = 3200;
constexpr uint32_t kHoldFocusedSpanMs = 4800;

// Time constant for travelling to a new target. Deliberately no overshoot:
// eyes overshoot and settle, but a servo head that overshoots looks twitchy.
constexpr float kShiftSecondsCalm = 0.85f;
constexpr float kShiftSecondsAlert = 0.42f;

// Below this the head is considered to have arrived.
constexpr float kArrivedDeg = 0.15f;

// One shift in roughly this many is a wider look-away, the same 1-in-10 trick
// the eye saccades use to stop the pattern reading as uniform.
constexpr uint32_t kWideLookEvery = 7;
constexpr float kWideLookGain = 1.55f;

// A stalled task must not teleport the head.
constexpr uint32_t kMaxStepMs = 200;
}  // namespace

void HeadGaze::reset(uint32_t nowMs) {
  yawDeg_ = 0.0f;
  pitchDeg_ = 0.0f;
  targetYawDeg_ = 0.0f;
  targetPitchDeg_ = 0.0f;
  retargetAtMs_ = nowMs;
  holdMs_ = 0;
  shifts_ = 0;
  lastMs_ = nowMs;
  hasLast_ = false;
  shifting_ = false;
}

uint32_t HeadGaze::hash32(uint32_t value) {
  value ^= value >> 16;
  value *= 0x7feb352dUL;
  value ^= value >> 15;
  value *= 0x846ca68bUL;
  value ^= value >> 16;
  return value;
}

float HeadGaze::signedUnit(uint32_t hash) {
  return (static_cast<float>(hash & 0xFFFFu) / 32767.5f) - 1.0f;
}

void HeadGaze::chooseTarget(float yawSpanDeg, float pitchSpanDeg, float focus) {
  const uint32_t h = hash32(shifts_ * 0x9e3779b9UL + 0x85ebca6bUL);
  const uint32_t h2 = hash32(shifts_ * 0x27d4eb2fUL + 0x165667b1UL);

  // A focused character keeps its head near centre; an unfocused one ranges.
  const float reach = 0.35f + (1.0f - focus) * 0.65f;
  float yaw = signedUnit(h) * yawSpanDeg * reach;
  float pitch = signedUnit(h2) * pitchSpanDeg * reach;

  // Occasionally look further afield.
  if (kWideLookEvery > 0 && (shifts_ % kWideLookEvery) == (kWideLookEvery - 1)) {
    yaw *= kWideLookGain;
    pitch *= kWideLookGain;
  }

  // Never exceed the envelope the caller allows.
  targetYawDeg_ = constrain(yaw, -yawSpanDeg, yawSpanDeg);
  targetPitchDeg_ = constrain(pitch, -pitchSpanDeg, pitchSpanDeg);
  ++shifts_;
}

void HeadGaze::update(uint32_t nowMs,
                      float yawSpanDeg,
                      float pitchSpanDeg,
                      float focus,
                      float arousal) {
  const float safeFocus = constrain(focus, 0.0f, 1.0f);
  const float safeArousal = constrain(arousal, 0.0f, 1.0f);
  yawSpanDeg = fabsf(yawSpanDeg);
  pitchSpanDeg = fabsf(pitchSpanDeg);

  // Unsigned subtraction stays correct across the millis() wrap.
  uint32_t stepMs = hasLast_ ? (nowMs - lastMs_) : 0;
  if (stepMs > kMaxStepMs) {
    stepMs = kMaxStepMs;
  }
  lastMs_ = nowMs;
  hasLast_ = true;

  // Time to look somewhere else?
  if (static_cast<int32_t>(nowMs - retargetAtMs_) >= 0) {
    chooseTarget(yawSpanDeg, pitchSpanDeg, safeFocus);
    const bool wandering = safeFocus < 0.55f;
    const uint32_t minMs = wandering ? kHoldWanderingMinMs : kHoldFocusedMinMs;
    const uint32_t spanMs = wandering ? kHoldWanderingSpanMs : kHoldFocusedSpanMs;
    const uint32_t jitter = hash32(shifts_ * 0x2545f491UL) % (spanMs > 0 ? spanMs : 1);
    // An alert character shifts sooner than a calm one.
    holdMs_ = static_cast<uint32_t>((minMs + jitter) * (1.0f - safeArousal * 0.35f));
    if (holdMs_ < 350) {
      holdMs_ = 350;
    }
    retargetAtMs_ = nowMs + holdMs_;
    shifting_ = true;
  }

  // Travel toward the target. Exponential approach, so it eases in and settles
  // without overshoot.
  const float shiftSeconds = kShiftSecondsCalm +
                             (kShiftSecondsAlert - kShiftSecondsCalm) * safeArousal;
  const float dt = static_cast<float>(stepMs) * 0.001f;
  if (dt > 0.0f && shiftSeconds > 0.0f) {
    const float alpha = 1.0f - expf(-dt / shiftSeconds);
    yawDeg_ += (targetYawDeg_ - yawDeg_) * alpha;
    pitchDeg_ += (targetPitchDeg_ - pitchDeg_) * alpha;
  }

  // Keep the reported pose inside the caller's envelope even if it shrank.
  yawDeg_ = constrain(yawDeg_, -yawSpanDeg, yawSpanDeg);
  pitchDeg_ = constrain(pitchDeg_, -pitchSpanDeg, pitchSpanDeg);

  if (fabsf(targetYawDeg_ - yawDeg_) < kArrivedDeg &&
      fabsf(targetPitchDeg_ - pitchDeg_) < kArrivedDeg) {
    shifting_ = false;
  }
}

}  // namespace stackchan
