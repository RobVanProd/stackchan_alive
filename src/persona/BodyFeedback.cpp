#include "persona/BodyFeedback.hpp"

#include <math.h>

namespace stackchan {

namespace {
constexpr float kTwoPi = 6.28318530718f;
constexpr uint8_t kNormalChannelCap = 52;
constexpr uint8_t kProtectedChannelCap = 14;
constexpr uint32_t kMicPulseDurationMs = 900;
constexpr uint32_t kTouchPulseDurationMs = 650;

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
                                  bool protectedMode) const {
  BodyRgbFrame output;
  const uint8_t cap = protectedMode ? kProtectedChannelCap : kNormalChannelCap;
  powerScale = clamp01(powerScale);
  const float t = (nowMs - begunAtMs_) * 0.001f;
  const float breathing = 0.55f + 0.20f * sinf(t * kTwoPi * 0.20f);
  const float energy = 0.70f + clamp01(frame.emotion.arousal) * 0.30f;
  const float speech = clamp01(speechEnvelope);
  const BodyRgbColor base = modeColor(frame);

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

    output.leds[i] = scaleColor(color, modePulse * energy * powerScale, cap);
    output.peakChannel = max(output.peakChannel, output.leds[i].r);
    output.peakChannel = max(output.peakChannel, output.leds[i].g);
    output.peakChannel = max(output.peakChannel, output.leds[i].b);
  }
  return output;
}

}  // namespace stackchan
