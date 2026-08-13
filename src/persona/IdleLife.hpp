#pragma once

#include "persona/BreathRhythm.hpp"
#include "persona/StateMatrix.hpp"

namespace stackchan {

struct IdleLifeTelemetry {
  float breathY = 0.0f;
  float pitchBobDeg = 0.0f;
  float microExpression = 0.0f;
  float yawn = 0.0f;
  float pupilScale = 1.0f;
  // Length of the breath currently being taken, in ms. Varies cycle to cycle.
  uint32_t breathPeriodMs = 0;
  // 1.0 for an ordinary breath, higher while a sigh is being drawn.
  float breathDepth = 1.0f;
  bool sighing = false;
};

class IdleLife {
 public:
  void reset(uint32_t nowMs = 0);
  void apply(RobotFrame& frame, uint32_t nowMs, bool reducedMotion);

  // Hardware entropy at boot so each power-on plays a different idle sequence;
  // zero (the default) keeps the deterministic streams native tests rely on.
  void seedEntropy(uint32_t seed) {
    seed_ = seed;
    breath_.seedEntropy(hash32(seed + 0x9e3779b9UL));
  }

  const IdleLifeTelemetry& telemetry() const {
    return telemetry_;
  }

 private:
  uint32_t nextMicroExpressionMs_ = 0;
  uint32_t nextYawnMs_ = 0;
  uint8_t microKind_ = 0;
  uint32_t seed_ = 0;
  // Slow inter-fixation gaze drift with a re-jittered period each cycle, so
  // idle eye life has no fixed learnable frequency.
  float driftPhase_ = 0.0f;
  uint32_t driftPeriodMs_ = 0;
  uint32_t driftCycle_ = 0;
  uint32_t lastDriftMs_ = 0;
  bool hasLastDriftMs_ = false;
  IdleLifeTelemetry telemetry_;
  BreathRhythm breath_;

  void scheduleNextMicroExpression(uint32_t nowMs);
  void scheduleNextYawn(uint32_t nowMs);
  float microExpressionPulse(uint32_t nowMs);
  float yawnPulse(uint32_t nowMs, float fatigue);
  float gazeDrift(uint32_t nowMs);
  static uint32_t hash32(uint32_t value);
  static float clampValue(float value, float low, float high);
};

}  // namespace stackchan
