#include "persona/EarconSynth.hpp"

#include "PersonaEarcons.hpp"

#include <math.h>

namespace stackchan {

namespace {
constexpr float kTwoPi = 6.28318530718f;
constexpr int16_t kMaxAmplitude = 11800;

struct EarconTone {
  uint16_t frequencyHz;
  uint16_t durationMs;
  uint8_t level;
  uint8_t gapMs;
};

struct EarconPattern {
  const EarconTone* tones;
  uint8_t count;
};

constexpr EarconTone kWakeTones[] = {
    {660, 52, 205, 12},
    {990, 68, 225, 0},
};

constexpr EarconTone kConfirmTones[] = {
    {880, 42, 185, 12},
    {1175, 52, 205, 0},
};

constexpr EarconTone kThinkTones[] = {
    {523, 38, 145, 18},
    {659, 38, 150, 18},
    {784, 72, 135, 0},
};

constexpr EarconTone kHappyTones[] = {
    {784, 44, 185, 10},
    {1047, 52, 215, 10},
    {1319, 62, 220, 0},
};

constexpr EarconTone kConcernTones[] = {
    {740, 70, 150, 14},
    {622, 88, 135, 0},
};

constexpr EarconTone kSleepTones[] = {
    {660, 70, 120, 16},
    {440, 84, 105, 16},
    {330, 104, 90, 0},
};

constexpr EarconTone kErrorTones[] = {
    {220, 90, 180, 16},
    {294, 90, 170, 0},
};

constexpr EarconTone kSafetyTones[] = {
    {392, 64, 215, 12},
    {294, 96, 205, 12},
    {392, 64, 215, 0},
};

template <size_t N>
constexpr EarconPattern patternOf(const EarconTone (&tones)[N]) {
  return {tones, static_cast<uint8_t>(N)};
}

EarconPattern patternFor(SpeechEarcon earcon) {
  switch (earcon) {
    case SpeechEarcon::Wake:
      return patternOf(kWakeTones);
    case SpeechEarcon::Confirm:
      return patternOf(kConfirmTones);
    case SpeechEarcon::Think:
      return patternOf(kThinkTones);
    case SpeechEarcon::Happy:
      return patternOf(kHappyTones);
    case SpeechEarcon::Concern:
      return patternOf(kConcernTones);
    case SpeechEarcon::Sleep:
      return patternOf(kSleepTones);
    case SpeechEarcon::Error:
      return patternOf(kErrorTones);
    case SpeechEarcon::Safety:
      return patternOf(kSafetyTones);
    case SpeechEarcon::None:
      break;
  }
  return {nullptr, 0};
}

float clampFloat(float value, float minValue, float maxValue) {
  if (value < minValue) {
    return minValue;
  }
  if (value > maxValue) {
    return maxValue;
  }
  return value;
}

uint32_t samplesForMs(uint16_t sampleRate, uint16_t ms) {
  return (static_cast<uint32_t>(sampleRate) * ms) / 1000u;
}

void hashSample(EarconRenderResult& result, int16_t sample) {
  const uint16_t value = static_cast<uint16_t>(sample);
  result.checksum ^= static_cast<uint8_t>(value & 0xFFu);
  result.checksum *= 16777619u;
  result.checksum ^= static_cast<uint8_t>((value >> 8) & 0xFFu);
  result.checksum *= 16777619u;
}

void writeSample(EarconRenderResult& result, int16_t* out, size_t maxSamples, int16_t sample) {
  if (result.samplesWritten >= maxSamples) {
    result.truncated = true;
    return;
  }

  out[result.samplesWritten++] = sample;
  const int16_t absSample = sample < 0 ? static_cast<int16_t>(-sample) : sample;
  if (absSample > result.peakAbs) {
    result.peakAbs = absSample;
  }
  hashSample(result, sample);
}

float toneEnvelope(uint32_t index, uint32_t total, uint32_t fadeSamples) {
  if (total == 0 || fadeSamples == 0) {
    return 1.0f;
  }
  const uint32_t remaining = total - index;
  const uint32_t edge = index < remaining ? index : remaining;
  if (edge >= fadeSamples) {
    return 1.0f;
  }
  return static_cast<float>(edge) / static_cast<float>(fadeSamples);
}

template <typename Tone>
void renderTone(const Tone& tone,
                int16_t* out,
                size_t maxSamples,
                const EarconRenderConfig& config,
                EarconRenderResult& result) {
  const uint32_t toneSamples = samplesForMs(config.sampleRate, tone.durationMs);
  const uint32_t fadeSamples = samplesForMs(config.sampleRate, 6);
  const float gain = (static_cast<float>(tone.level) / 255.0f) * clampFloat(config.intensity, 0.0f, 1.0f);
  const float phaseStep = kTwoPi * static_cast<float>(tone.frequencyHz) / static_cast<float>(config.sampleRate);

  for (uint32_t i = 0; i < toneSamples; ++i) {
    const float phase = phaseStep * static_cast<float>(i);
    const float buzz = sinf(phase) + sinf(phase * 2.0f) * 0.18f + sinf(phase * 3.0f) * 0.07f;
    const float envelope = toneEnvelope(i, toneSamples, fadeSamples);
    const int16_t sample = static_cast<int16_t>(buzz * envelope * gain * static_cast<float>(kMaxAmplitude));
    writeSample(result, out, maxSamples, sample);
  }
}

void renderGap(uint8_t gapMs, int16_t* out, size_t maxSamples, uint16_t sampleRate, EarconRenderResult& result) {
  const uint32_t gapSamples = samplesForMs(sampleRate, gapMs);
  for (uint32_t i = 0; i < gapSamples; ++i) {
    writeSample(result, out, maxSamples, 0);
  }
}

template <typename Pattern>
void renderPattern(const Pattern& pattern,
                   int16_t* out,
                   size_t maxSamples,
                   const EarconRenderConfig& config,
                   EarconRenderResult& result) {
  for (uint8_t i = 0; i < pattern.count; ++i) {
    renderTone(pattern.tones[i], out, maxSamples, config, result);
    if (pattern.tones[i].gapMs > 0) {
      renderGap(pattern.tones[i].gapMs, out, maxSamples, result.sampleRate, result);
    }
  }
}

template <typename Pattern>
uint16_t durationForPattern(const Pattern& pattern) {
  uint16_t total = 0;
  for (uint8_t i = 0; i < pattern.count; ++i) {
    total = static_cast<uint16_t>(total + pattern.tones[i].durationMs + pattern.tones[i].gapMs);
  }
  return total;
}

}  // namespace

EarconRenderResult EarconSynth::render(SpeechEarcon earcon,
                                       int16_t* out,
                                       size_t maxSamples,
                                       const EarconRenderConfig& config) {
  EarconRenderResult result;
  result.sampleRate = config.sampleRate == 0 ? kEarconSampleRate : config.sampleRate;
  if (out == nullptr || maxSamples == 0 || earcon == SpeechEarcon::None) {
    result.truncated = earcon != SpeechEarcon::None;
    return result;
  }

  EarconRenderConfig activeConfig = config;
  activeConfig.sampleRate = result.sampleRate;
  if (generated_persona::kUsePersonaEarconPatterns) {
    const generated_persona::PersonaEarconPattern generatedPattern = generated_persona::earconPatternFor(earcon);
    if (generatedPattern.count > 0) {
      renderPattern(generatedPattern, out, maxSamples, activeConfig, result);
      result.durationMs = static_cast<uint16_t>((result.samplesWritten * 1000u) / result.sampleRate);
      return result;
    }
  }

  const EarconPattern pattern = patternFor(earcon);
  renderPattern(pattern, out, maxSamples, activeConfig, result);
  result.durationMs = static_cast<uint16_t>((result.samplesWritten * 1000u) / result.sampleRate);
  return result;
}

uint16_t EarconSynth::expectedDurationMs(SpeechEarcon earcon) {
  if (generated_persona::kUsePersonaEarconPatterns) {
    const generated_persona::PersonaEarconPattern generatedPattern = generated_persona::earconPatternFor(earcon);
    if (generatedPattern.count > 0) {
      return durationForPattern(generatedPattern);
    }
  }

  const EarconPattern pattern = patternFor(earcon);
  return durationForPattern(pattern);
}

}  // namespace stackchan
