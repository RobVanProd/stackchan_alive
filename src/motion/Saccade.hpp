#pragma once

#include <Arduino.h>

#include "persona/StateMatrix.hpp"

namespace stackchan {

struct SaccadeGenerator {
  float offsetX = 0.0f;
  float offsetY = 0.0f;
  uint32_t nextMs = 0;

  void update(uint32_t nowMs, const EmotionalProfile& emotion) {
    if (nowMs < nextMs) {
      return;
    }

    const float wander = (1.0f - emotion.focus) * 0.55f + emotion.arousal * 0.15f;
    offsetX = random(-100, 101) * 0.01f * wander;
    offsetY = random(-100, 101) * 0.01f * wander * 0.55f;

    const uint32_t minHold = emotion.arousal > 0.70f ? 120 : 280;
    const uint32_t maxHold = emotion.focus > 0.70f ? 1200 : 650;
    nextMs = nowMs + random(minHold, maxHold);
  }
};

}  // namespace stackchan
