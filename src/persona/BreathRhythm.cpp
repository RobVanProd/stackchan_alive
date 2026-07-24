#include "persona/BreathRhythm.hpp"

#include <math.h>

#include "PersonaBehavior.hpp"

namespace stackchan {

namespace {
// Every tunable below comes from the persona pack's behavior.yaml, so a calm
// persona and a bright one can breathe differently without touching firmware.
constexpr float kPeriodJitter = generated_persona::kBreathPeriodJitter;
constexpr float kDepthJitter = generated_persona::kBreathDepthJitter;
constexpr uint32_t kSighMinCycles = generated_persona::kSighMinCycles;
constexpr uint32_t kSighCycleSpan = generated_persona::kSighCycleSpan;
constexpr float kSighDepth = generated_persona::kSighDepth;
constexpr float kExhaleFraction = generated_persona::kBreathExhaleFraction;
constexpr float kHoldFraction = generated_persona::kBreathHoldFraction;
// A stalled or resumed task must not teleport the breath forward.
constexpr uint32_t kMaxStepMs = 200;
constexpr float kPi = 3.1415927f;
}  // namespace

void BreathRhythm::reset(uint32_t nowMs) {
  phase_ = 0.0f;
  periodMs_ = 0;
  depth_ = 1.0f;
  cycle_ = 0;
  cyclesUntilSigh_ = kSighMinCycles + (hash32(nowMs + 0x2545f491UL) % kSighCycleSpan);
  lastMs_ = nowMs;
  hasLast_ = false;
  sighing_ = false;
}

// Phase 0 is the top of the inhale, so a freshly reset rhythm starts at full
// extension and breathes out from there.
float BreathRhythm::shape(float phase) {
  const float p = phase - floorf(phase);
  if (p < kExhaleFraction) {
    return cosf((p / kExhaleFraction) * kPi);
  }
  if (p < kExhaleFraction + kHoldFraction) {
    return -1.0f;
  }
  const float inhaleSpan = 1.0f - kExhaleFraction - kHoldFraction;
  const float x = (p - kExhaleFraction - kHoldFraction) / inhaleSpan;
  return -cosf(x * kPi);
}

void BreathRhythm::startCycle(float breathHz, bool sleeping) {
  const float safeHz = breathHz > 0.01f ? breathHz : 0.01f;
  const float nominalMs = 1000.0f / safeHz;

  // The first breath after a reset is deliberately plain, so boot-time face
  // geometry is predictable. Variation starts from the second breath.
  if (cycle_ == 0) {
    periodMs_ = static_cast<uint32_t>(nominalMs);
    depth_ = 1.0f;
    sighing_ = false;
    ++cycle_;
    return;
  }

  const uint32_t h = hash32(cycle_ * 0x9e3779b9UL + 0x85ebca6bUL);
  const float jitter = (static_cast<float>((h >> 8) & 0xFFFFu) / 32767.5f) - 1.0f;
  const float depthJitter = (static_cast<float>(h & 0xFFFFu) / 32767.5f) - 1.0f;

  float period = nominalMs * (1.0f + jitter * kPeriodJitter);
  float depth = 1.0f + depthJitter * kDepthJitter;

  const bool sigh = !sleeping && cyclesUntilSigh_ == 0;
  if (sigh) {
    depth = kSighDepth;
    period *= 1.35f;
    cyclesUntilSigh_ = kSighMinCycles + (hash32(cycle_ + 0x27d4eb2fUL) % kSighCycleSpan);
  } else if (cyclesUntilSigh_ > 0) {
    --cyclesUntilSigh_;
  }

  periodMs_ = static_cast<uint32_t>(period < 200.0f ? 200.0f : period);
  depth_ = depth;
  sighing_ = sigh;
  ++cycle_;
}

float BreathRhythm::update(uint32_t nowMs, float breathHz, bool sleeping) {
  if (periodMs_ == 0) {
    startCycle(breathHz, sleeping);
  }

  // Unsigned subtraction stays correct across the millis() wrap.
  uint32_t stepMs = hasLast_ ? (nowMs - lastMs_) : 0;
  if (stepMs > kMaxStepMs) {
    stepMs = kMaxStepMs;
  }
  lastMs_ = nowMs;
  hasLast_ = true;

  phase_ += static_cast<float>(stepMs) / static_cast<float>(periodMs_);
  while (phase_ >= 1.0f) {
    phase_ -= 1.0f;
    startCycle(breathHz, sleeping);
  }

  return shape(phase_) * depth_;
}

uint32_t BreathRhythm::hash32(uint32_t value) {
  value ^= value >> 16;
  value *= 0x7feb352dUL;
  value ^= value >> 15;
  value *= 0x846ca68bUL;
  value ^= value >> 16;
  return value;
}

}  // namespace stackchan
