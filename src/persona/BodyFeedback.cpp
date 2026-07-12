#include "persona/BodyFeedback.hpp"

#include <math.h>
#include <string.h>

namespace stackchan {

namespace {
constexpr float kTwoPi = 6.28318530718f;
constexpr uint8_t kNormalChannelCap = 52;
constexpr uint8_t kProtectedChannelCap = 14;
constexpr uint32_t kMicPulseDurationMs = 900;
constexpr uint32_t kTouchPulseDurationMs = 650;
constexpr float kNormalAttackSeconds = 0.24f;
constexpr float kNormalReleaseSeconds = 0.42f;
constexpr float kAccentAttackSeconds = 0.10f;
constexpr float kSafetyAttackSeconds = 0.08f;
constexpr float kBaseSettledDistance = 6.0f;

float clamp01(float value) {
  return constrain(value, 0.0f, 1.0f);
}

BodyRgbColor scaleColor(BodyRgbColor color, float scale, uint8_t cap) {
  const auto channel = [scale, cap](uint8_t value) {
    return static_cast<uint8_t>(constrain(lroundf(value * scale), 0l, static_cast<long>(cap)));
  };
  return {channel(color.r), channel(color.g), channel(color.b)};
}

BodyRgbColor blend(BodyRgbColor a, BodyRgbColor b, float amount) {
  amount = clamp01(amount);
  const float inverse = 1.0f - amount;
  return {
      static_cast<uint8_t>(lroundf(a.r * inverse + b.r * amount)),
      static_cast<uint8_t>(lroundf(a.g * inverse + b.g * amount)),
      static_cast<uint8_t>(lroundf(a.b * inverse + b.b * amount)),
  };
}

BodyRgbColor modeColor(const RobotFrame& frame) {
  switch (frame.mode) {
    case CharacterMode::Boot:
      return {14, 88, 96};
    case CharacterMode::Attend:
      return {20, 108, 92};
    case CharacterMode::Listen:
      return {10, 124, 80};
    case CharacterMode::Think:
      return {104, 70, 12};
    case CharacterMode::Speak:
      if (frame.emotion.valence > 0.30f) {
        return {90, 30, 100};
      }
      if (frame.emotion.valence < -0.25f) {
        return {110, 54, 12};
      }
      return {22, 88, 118};
    case CharacterMode::React:
      return {112, 48, 42};
    case CharacterMode::Sleep:
      return {8, 12, 34};
    case CharacterMode::Error:
      return {132, 4, 2};
    case CharacterMode::Idle:
      return frame.emotion.valence >= 0.0f ? BodyRgbColor {12, 52, 74}
                                           : BodyRgbColor {42, 28, 62};
  }
  return {0, 0, 0};
}

BodyRgbColor emotionTint(const EmotionalProfile& emotion) {
  if (emotion.fatigue > 0.72f) {
    return {16, 22, 62};
  }
  if (emotion.valence > 0.25f) {
    return {86, 42, 104};
  }
  if (emotion.valence < -0.20f) {
    return {108, 52, 14};
  }
  return {20, 82, 106};
}

bool ledMatchesTouchZone(uint8_t led, BodyTouchZone zone) {
  const uint8_t rowIndex = led % 6;
  switch (zone) {
    case BodyTouchZone::Front:
      return rowIndex <= 1;
    case BodyTouchZone::Middle:
      return rowIndex >= 2 && rowIndex <= 3;
    case BodyTouchZone::Back:
      return rowIndex >= 4;
    case BodyTouchZone::None:
      return false;
  }
  return false;
}
}  // namespace

void BodyFeedback::begin(uint32_t nowMs) {
  begunAtMs_ = nowMs;
  micPulseAtMs_ = 0;
  touchPulseAtMs_ = 0;
  touchZone_ = BodyTouchZone::None;
  touchStrength_ = 0.0f;
  memset(smoothedBaseChannels_, 0, sizeof(smoothedBaseChannels_));
  memset(smoothedChannels_, 0, sizeof(smoothedChannels_));
  smoothingReady_ = false;
  modeReady_ = false;
  telemetry_ = BodyFeedbackTelemetry {};
  telemetry_.lastRenderMs = nowMs;
}

void BodyFeedback::notifyMicActivated(uint32_t nowMs) {
  micPulseAtMs_ = nowMs == 0 ? 1 : nowMs;
}

void BodyFeedback::notifyTouch(BodyTouchZone zone, float strength, uint32_t nowMs) {
  touchZone_ = zone;
  touchStrength_ = clamp01(strength);
  touchPulseAtMs_ = nowMs == 0 ? 1 : nowMs;
}

BodyRgbFrame BodyFeedback::render(const RobotFrame& frame,
                                  float speechEnvelope,
                                  uint32_t nowMs,
                                  float powerScale,
                                  bool protectedMode) {
  BodyRgbFrame target;
  BodyRgbFrame output;
  const uint8_t cap = protectedMode ? kProtectedChannelCap : kNormalChannelCap;
  powerScale = clamp01(powerScale);
  const float t = (nowMs - begunAtMs_) * 0.001f;
  const float fatigueSlowdown = 1.0f - clamp01(frame.emotion.fatigue) * 0.38f;
  const float breathing = 0.55f + 0.20f * sinf(t * kTwoPi * 0.20f * fatigueSlowdown);
  const float energy = 0.70f + clamp01(frame.emotion.arousal) * 0.30f;
  const float speech = clamp01(speechEnvelope);
  const float moodAmount = 0.08f + fabsf(frame.emotion.valence) * 0.14f +
                           clamp01(frame.emotion.arousal) * 0.05f;
  const BodyRgbColor desiredBase = blend(
      modeColor(frame), emotionTint(frame.emotion), moodAmount);

  if (modeReady_ && frame.mode != telemetry_.currentMode) {
    ++telemetry_.modeTransitions;
  }
  telemetry_.currentMode = frame.mode;
  modeReady_ = true;

  const uint32_t elapsedMs = telemetry_.lastRenderMs == 0 ? 0 : nowMs - telemetry_.lastRenderMs;
  const float dt = constrain(elapsedMs * 0.001f, 0.0f, 0.25f);
  const uint8_t desiredBaseChannels[3] = {desiredBase.r, desiredBase.g, desiredBase.b};
  uint8_t renderedBaseChannels[3] = {};
  float maxBaseDistance = 0.0f;
  for (uint8_t channel = 0; channel < 3; ++channel) {
    const float previous = smoothedBaseChannels_[channel];
    const float desired = desiredBaseChannels[channel];
    float next = desired;
    if (smoothingReady_ && dt > 0.0f) {
      const float timeConstant = desired > previous
                                     ? kNormalAttackSeconds
                                     : kNormalReleaseSeconds;
      const float alpha = 1.0f - expf(-dt / timeConstant);
      next = previous + (desired - previous) * alpha;
    } else if (smoothingReady_) {
      next = previous;
    }
    smoothedBaseChannels_[channel] = next;
    renderedBaseChannels[channel] = static_cast<uint8_t>(
        constrain(lroundf(next), 0l, 255l));
    maxBaseDistance = fmaxf(maxBaseDistance, fabsf(desired - next));
  }
  const BodyRgbColor base = {
      renderedBaseChannels[0], renderedBaseChannels[1], renderedBaseChannels[2]};

  const bool micPulseActive = micPulseAtMs_ != 0 && nowMs - micPulseAtMs_ < kMicPulseDurationMs;
  const float micProgress = micPulseActive
                                ? clamp01(static_cast<float>(nowMs - micPulseAtMs_) /
                                          static_cast<float>(kMicPulseDurationMs))
                                : 1.0f;
  const bool touchPulseActive = touchPulseAtMs_ != 0 && nowMs - touchPulseAtMs_ < kTouchPulseDurationMs;
  const float touchFade = touchPulseActive
                              ? 1.0f - clamp01(static_cast<float>(nowMs - touchPulseAtMs_) /
                                               static_cast<float>(kTouchPulseDurationMs))
                              : 0.0f;

  for (uint8_t i = 0; i < kBodyRgbLedCount; ++i) {
    const float position = static_cast<float>(i % 6) / 5.0f;
    const float rowPhase = i >= 6 ? 0.85f : 0.0f;
    float modePulse = breathing;
    if (frame.mode == CharacterMode::Think) {
      modePulse = 0.45f + 0.40f * (0.5f + 0.5f * sinf(t * 4.2f - position * kTwoPi));
    } else if (frame.mode == CharacterMode::Speak) {
      modePulse = 0.48f + speech * 0.52f;
    } else if (frame.mode == CharacterMode::Listen || frame.mode == CharacterMode::Attend) {
      modePulse = 0.58f + 0.30f * (0.5f + 0.5f * sinf(t * 5.0f - position * 4.0f));
    } else if (frame.mode == CharacterMode::Error) {
      modePulse = 0.45f + 0.45f * (0.5f + 0.5f * sinf(t * 8.0f));
    }
    const float livingDrift = 0.92f + 0.08f *
        (0.5f + 0.5f * sinf(t * 1.35f - position * 2.8f + rowPhase));
    modePulse *= livingDrift;

    BodyRgbColor color = base;
    if (micPulseActive) {
      const float distance = fabsf(position - micProgress);
      const float sweep = clamp01(1.0f - distance * 3.4f);
      color = blend(color, {26, 180, 120}, sweep);
      modePulse = fmaxf(modePulse, 0.70f + sweep * 0.30f);
    }
    if (touchPulseActive && ledMatchesTouchZone(i, touchZone_)) {
      color = blend(color, {180, 76, 126}, touchFade * (0.45f + touchStrength_ * 0.55f));
      modePulse = fmaxf(modePulse, 0.65f + touchFade * 0.35f);
    }

    target.leds[i] = scaleColor(color, modePulse * energy * powerScale, cap);
  }

  const bool accentActive = micPulseActive || touchPulseActive;
  const float attackSeconds = frame.mode == CharacterMode::Error
                                  ? kSafetyAttackSeconds
                                  : accentActive ? kAccentAttackSeconds : kNormalAttackSeconds;
  uint8_t maxStep = 0;
  for (uint8_t i = 0; i < kBodyRgbLedCount; ++i) {
    const uint8_t targetChannels[3] = {
        target.leds[i].r, target.leds[i].g, target.leds[i].b};
    uint8_t outputChannels[3] = {};
    for (uint8_t channel = 0; channel < 3; ++channel) {
      const float previous = smoothedChannels_[i][channel];
      const float desired = targetChannels[channel];
      float next = desired;
      if (smoothingReady_ && dt > 0.0f) {
        const float timeConstant = desired > previous ? attackSeconds : kNormalReleaseSeconds;
        const float alpha = 1.0f - expf(-dt / timeConstant);
        next = previous + (desired - previous) * alpha;
      } else if (smoothingReady_) {
        next = previous;
      }
      smoothedChannels_[i][channel] = next;
      const uint8_t quantized = static_cast<uint8_t>(
          constrain(lroundf(next), 0l, static_cast<long>(cap)));
      outputChannels[channel] = quantized;
      const uint8_t previousQuantized = static_cast<uint8_t>(
          constrain(lroundf(previous), 0l, static_cast<long>(cap)));
      maxStep = max(maxStep, static_cast<uint8_t>(abs(static_cast<int>(quantized) -
                                                       static_cast<int>(previousQuantized))));
    }
    output.leds[i] = {outputChannels[0], outputChannels[1], outputChannels[2]};
    output.peakChannel = max(output.peakChannel, output.leds[i].r);
    output.peakChannel = max(output.peakChannel, output.leds[i].g);
    output.peakChannel = max(output.peakChannel, output.leds[i].b);
  }
  smoothingReady_ = true;
  telemetry_.lastChannelStep = maxStep;
  telemetry_.maxChannelStep = max(telemetry_.maxChannelStep, maxStep);
  telemetry_.transitionActive = maxBaseDistance > kBaseSettledDistance;
  telemetry_.lastRenderMs = nowMs;
  ++telemetry_.renderedFrames;
  return output;
}

}  // namespace stackchan
