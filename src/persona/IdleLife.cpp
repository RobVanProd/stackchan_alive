#include "persona/IdleLife.hpp"

#include <Arduino.h>
#include <math.h>

#include "PersonaBehavior.hpp"
#include "PersonaExpressions.hpp"

namespace stackchan {

namespace {
constexpr float kTwoPi = 6.2831853f;
constexpr uint32_t kMicroExpressionDurationMs = 240;
constexpr float kYawnFatigueThreshold = 0.62f;
}

void IdleLife::reset(uint32_t nowMs) {
  telemetry_ = IdleLifeTelemetry {};
  nextMicroExpressionMs_ = nowMs + 1800;
  nextYawnMs_ = nowMs + 4200;
  microKind_ = 0;
}

void IdleLife::apply(RobotFrame& frame, uint32_t nowMs, bool reducedMotion) {
  const float motionScale = reducedMotion ? generated_persona::kReducedMotionScale : 1.0f;
  const bool sleeping = frame.mode == CharacterMode::Sleep;
  const float arousal = clampValue(frame.emotion.arousal, 0.0f, 1.0f);
  const float fatigue = clampValue(frame.emotion.fatigue, 0.0f, 1.0f);
  const float focus = clampValue(frame.emotion.focus, 0.0f, 1.0f);

  const float breathHz = sleeping ? clampValue(generated_persona::kIdleBreathingHz * 0.60f, 0.10f, 0.20f)
                                  : clampValue(generated_persona::kIdleBreathingHz - 0.04f + arousal * 0.10f -
                                                   fatigue * 0.04f,
                                               0.10f, 0.28f);
  const float breathAmp = (sleeping ? generated_persona::kIdleBreathingPx * 0.77f
                                    : clampValue(generated_persona::kIdleBreathingPx *
                                                     (0.60f + fatigue * 0.45f - arousal * 0.20f),
                                                 0.45f, 1.80f)) *
                          motionScale;
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

  const float yawn = yawnPulse(nowMs, fatigue) * motionScale;
  if (yawn > 0.0f && frame.mode != CharacterMode::Speak) {
    frame.face.mouthOpen = clampValue(max(frame.face.mouthOpen, yawn * generated_persona::kYawnMouthOpen), 0.0f, 1.0f);
    frame.face.eyeOpen = clampValue(frame.face.eyeOpen + yawn * generated_persona::kYawnEyeOpenDelta, 0.02f, 1.12f);
    frame.face.squint = clampValue(frame.face.squint + yawn * generated_persona::kYawnSquintDelta, 0.0f, 1.0f);
    frame.face.mouthSmile = clampValue(frame.face.mouthSmile + yawn * generated_persona::kYawnMouthSmileDelta, -1.0f, 1.0f);
    frame.face.browTilt = clampValue(frame.face.browTilt - yawn * 0.08f, -1.0f, 1.0f);
    frame.face.faceY += yawn * 0.90f;
    frame.motion.pitchDeg += yawn * generated_persona::kYawnPitchBiasDeg;
  }

  telemetry_.breathY = breathY;
  telemetry_.pitchBobDeg = pitchBob;
  telemetry_.microExpression = pulse;
  telemetry_.yawn = yawn;
  telemetry_.pupilScale = frame.face.pupilScale;
}

void IdleLife::scheduleNextMicroExpression(uint32_t nowMs) {
  const uint32_t h = hash32(nowMs + 0x9e3779b9UL);
  const uint32_t minMs = generated_persona::kIdleFidgetMinMs;
  const uint32_t maxMs = max(generated_persona::kIdleFidgetMaxMs, minMs);
  const uint32_t spanMs = maxMs > minMs ? maxMs - minMs : 0;
  nextMicroExpressionMs_ = nowMs + minMs + (spanMs > 0 ? h % spanMs : 0);
  microKind_ = static_cast<uint8_t>((h >> 8) % 3);
}

void IdleLife::scheduleNextYawn(uint32_t nowMs) {
  const uint32_t h = hash32(nowMs + 0x517cc1b7UL);
  nextYawnMs_ = nowMs + 9000 + (h % 9000);
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

float IdleLife::yawnPulse(uint32_t nowMs, float fatigue) {
  if (nextYawnMs_ == 0) {
    nextYawnMs_ = nowMs + 4200;
  }
  if (fatigue < kYawnFatigueThreshold) {
    return 0.0f;
  }
  if (nowMs < nextYawnMs_) {
    return 0.0f;
  }

  const uint32_t elapsed = nowMs - nextYawnMs_;
  if (elapsed >= generated_persona::kYawnDurationMs) {
    scheduleNextYawn(nowMs);
    return 0.0f;
  }

  const float x = static_cast<float>(elapsed) / static_cast<float>(generated_persona::kYawnDurationMs);
  const float fatigueScale = clampValue((fatigue - kYawnFatigueThreshold) / (1.0f - kYawnFatigueThreshold), 0.0f, 1.0f);
  return sinf(x * 3.1415927f) * fatigueScale;
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
