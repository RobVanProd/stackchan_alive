#include "persona/IdleLife.hpp"

#include <Arduino.h>
#include <math.h>

namespace stackchan {

namespace {
constexpr float kTwoPi = 6.2831853f;
constexpr uint32_t kMicroExpressionDurationMs = 240;
}

void IdleLife::reset(uint32_t nowMs) {
  telemetry_ = IdleLifeTelemetry {};
  nextMicroExpressionMs_ = nowMs + 1800;
  microKind_ = 0;
}

void IdleLife::apply(RobotFrame& frame, uint32_t nowMs, bool reducedMotion) {
  const float motionScale = reducedMotion ? 0.30f : 1.0f;
  const bool sleeping = frame.mode == CharacterMode::Sleep;
  const float arousal = clampValue(frame.emotion.arousal, 0.0f, 1.0f);
  const float fatigue = clampValue(frame.emotion.fatigue, 0.0f, 1.0f);
  const float focus = clampValue(frame.emotion.focus, 0.0f, 1.0f);

  const float breathHz = sleeping ? 0.12f : clampValue(0.16f + arousal * 0.10f - fatigue * 0.04f, 0.10f, 0.28f);
  const float breathAmp = (sleeping ? 1.15f : clampValue(0.90f + fatigue * 0.70f - arousal * 0.30f, 0.45f, 1.45f)) * motionScale;
  const float breath = sinf(static_cast<float>(nowMs) * 0.001f * kTwoPi * breathHz);
  const float breathY = breath * breathAmp;
  const float pitchBob = -breath * (sleeping ? 0.22f : 0.38f) * motionScale;

  frame.face.faceY += breathY;
  frame.face.eyeWidthScale = clampValue(frame.face.eyeWidthScale + breath * 0.010f * motionScale, 0.88f, 1.18f);
  frame.motion.pitchDeg += pitchBob;

  const float gazeLife = sinf(static_cast<float>(nowMs) * 0.001f * kTwoPi * 0.07f) * (1.0f - focus) * 0.07f * motionScale;
  frame.face.pupilX = clampValue(frame.face.pupilX + gazeLife, -1.0f, 1.0f);
  frame.motion.yawDeg += gazeLife * 4.0f;

  const float pupilScale = clampValue(0.92f + arousal * 0.18f - fatigue * 0.04f, 0.84f, 1.12f);
  frame.face.pupilScale = clampValue(frame.face.pupilScale * pupilScale, 0.75f, 1.20f);

  const float pulse = microExpressionPulse(nowMs) * motionScale;
  if (pulse > 0.0f && frame.mode != CharacterMode::Speak) {
    if (microKind_ == 0) {
      frame.face.mouthSmile = clampValue(frame.face.mouthSmile + pulse * 0.055f, -1.0f, 1.0f);
      frame.face.eyeSmile = clampValue(frame.face.eyeSmile + pulse * 0.045f, 0.0f, 1.0f);
    } else if (microKind_ == 1) {
      frame.face.browTilt = clampValue(frame.face.browTilt + pulse * 0.070f, -1.0f, 1.0f);
      frame.face.pupilY = clampValue(frame.face.pupilY - pulse * 0.035f, -1.0f, 1.0f);
    } else {
      frame.face.squint = clampValue(frame.face.squint + pulse * 0.045f, 0.0f, 1.0f);
      frame.face.eyeOpen = clampValue(frame.face.eyeOpen - pulse * 0.035f, 0.02f, 1.12f);
    }
  }

  telemetry_.breathY = breathY;
  telemetry_.pitchBobDeg = pitchBob;
  telemetry_.microExpression = pulse;
  telemetry_.pupilScale = frame.face.pupilScale;
}

void IdleLife::scheduleNextMicroExpression(uint32_t nowMs) {
  const uint32_t h = hash32(nowMs + 0x9e3779b9UL);
  nextMicroExpressionMs_ = nowMs + 3600 + (h % 2600);
  microKind_ = static_cast<uint8_t>((h >> 8) % 3);
}

float IdleLife::microExpressionPulse(uint32_t nowMs) {
  if (nextMicroExpressionMs_ == 0) {
    reset(nowMs);
  }
  if (nowMs < nextMicroExpressionMs_) {
    return 0.0f;
  }

  const uint32_t elapsed = nowMs - nextMicroExpressionMs_;
  if (elapsed >= kMicroExpressionDurationMs) {
    scheduleNextMicroExpression(nowMs);
    return 0.0f;
  }

  const float x = static_cast<float>(elapsed) / static_cast<float>(kMicroExpressionDurationMs);
  return sinf(x * 3.1415927f);
}

uint32_t IdleLife::hash32(uint32_t value) {
  value ^= value >> 16;
  value *= 0x7feb352dUL;
  value ^= value >> 15;
  value *= 0x846ca68bUL;
  value ^= value >> 16;
  return value;
}

float IdleLife::clampValue(float value, float low, float high) {
  return constrain(value, low, high);
}

}  // namespace stackchan
