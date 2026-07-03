#pragma once

#include <stddef.h>
#include <stdint.h>

#include "persona/StateMatrix.hpp"

namespace stackchan {

constexpr uint16_t kEarconSampleRate = 16000;
constexpr uint16_t kEarconMaxDurationMs = 360;

struct EarconRenderConfig {
  uint16_t sampleRate = kEarconSampleRate;
  float intensity = 1.0f;
};

struct EarconRenderResult {
  uint16_t sampleRate = kEarconSampleRate;
  uint32_t samplesWritten = 0;
  uint16_t durationMs = 0;
  int16_t peakAbs = 0;
  uint32_t checksum = 2166136261u;
  bool truncated = false;
};

class EarconSynth {
 public:
  static EarconRenderResult render(SpeechEarcon earcon,
                                   int16_t* out,
                                   size_t maxSamples,
                                   const EarconRenderConfig& config = EarconRenderConfig {});
  static uint16_t expectedDurationMs(SpeechEarcon earcon);
};

}  // namespace stackchan
