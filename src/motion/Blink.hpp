#pragma once

#include <Arduino.h>

#include "persona/StateMatrix.hpp"

namespace stackchan {

class BlinkGenerator {
 public:
  float update(uint32_t nowMs, const EmotionalProfile& emotion) {
    if (nextBlinkMs_ == 0) {
      scheduleNext(nowMs, emotion);
    }

    switch (phase_) {
      case Phase::Open:
        if (nowMs >= nextBlinkMs_) {
          phase_ = Phase::Closing;
          phaseStartMs_ = nowMs;
          phaseDurationMs_ = emotion.fatigue > 0.6f ? 80 : 45;
        }
        return 1.0f;
      case Phase::Closing:
        if (elapsed(nowMs) >= phaseDurationMs_) {
          phase_ = Phase::Closed;
          phaseStartMs_ = nowMs;
          phaseDurationMs_ = 30;
          return 0.0f;
        }
        return 1.0f - progress(nowMs);
      case Phase::Closed:
        if (elapsed(nowMs) >= phaseDurationMs_) {
          phase_ = Phase::Opening;
          phaseStartMs_ = nowMs;
          phaseDurationMs_ = emotion.fatigue > 0.6f ? 120 : 70;
        }
        return 0.0f;
      case Phase::Opening:
        if (elapsed(nowMs) >= phaseDurationMs_) {
          phase_ = Phase::Open;
          scheduleNext(nowMs, emotion);
          return 1.0f;
        }
        return progress(nowMs);
    }

    return 1.0f;
  }

 private:
  enum class Phase : uint8_t {
    Open,
    Closing,
    Closed,
    Opening,
  };

  Phase phase_ = Phase::Open;
  uint32_t phaseStartMs_ = 0;
  uint32_t phaseDurationMs_ = 1;
  uint32_t nextBlinkMs_ = 0;

  uint32_t elapsed(uint32_t nowMs) const {
    return nowMs - phaseStartMs_;
  }

  float progress(uint32_t nowMs) const {
    return constrain(static_cast<float>(elapsed(nowMs)) / phaseDurationMs_, 0.0f, 1.0f);
  }

  void scheduleNext(uint32_t nowMs, const EmotionalProfile& emotion) {
    uint32_t minDelay = 2000;
    uint32_t maxDelay = 6000;

    if (emotion.arousal > 0.70f) {
      minDelay = 1000;
      maxDelay = 3000;
    }
    if (emotion.fatigue > 0.50f) {
      minDelay = 800;
      maxDelay = 2200;
    }

    nextBlinkMs_ = nowMs + random(minDelay, maxDelay);
  }
};

}  // namespace stackchan
