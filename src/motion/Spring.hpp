#pragma once

#include <Arduino.h>

namespace stackchan {

struct Spring1D {
  float x = 0.0f;
  float v = 0.0f;
  float omega = 12.0f;
  float zeta = 0.88f;  // Intentionally slight overshoot; 1.0 is critical damping.

  void reset(float value) {
    x = value;
    v = 0.0f;
  }

  float step(float target, float dt) {
    const float safeDt = constrain(dt, 0.001f, 0.040f);
    const float accel = omega * omega * (target - x) - 2.0f * zeta * omega * v;
    v += accel * safeDt;
    x += v * safeDt;
    return x;
  }
};

}  // namespace stackchan
