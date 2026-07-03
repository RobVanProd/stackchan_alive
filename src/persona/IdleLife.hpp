#pragma once

#include "persona/StateMatrix.hpp"

namespace stackchan {

struct IdleLifeTelemetry {
  float breathY = 0.0f;
  float pitchBobDeg = 0.0f;
  float microExpression = 0.0f;
  float yawn = 0.0f;
  float pupilScale = 1.0f;
};

class IdleLife {
 public:
  void reset(uint32_t nowMs = 0);
  void apply(RobotFrame& frame, uint32_t nowMs, bool reducedMotion);

  const IdleLifeTelemetry& telemetry() const {
    return telemetry_;
  }

 private:
  uint32_t nextMicroExpressionMs_ = 0;
  uint32_t nextYawnMs_ = 0;
  uint8_t microKind_ = 0;
  IdleLifeTelemetry telemetry_;

  void scheduleNextMicroExpression(uint32_t nowMs);
  void scheduleNextYawn(uint32_t nowMs);
  float microExpressionPulse(uint32_t nowMs);
  float yawnPulse(uint32_t nowMs, float fatigue);
  static uint32_t hash32(uint32_t value);
  static float clampValue(float value, float low, float high);
};

}  // namespace stackchan
