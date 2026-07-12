#pragma once

#include <Arduino.h>

namespace stackchan {

struct StereoDirectionEstimate {
  bool valid = false;
  float azimuthNorm = 0.0f;
  float confidence = 0.0f;
  float level = 0.0f;
  float correlation = 0.0f;
  int8_t lagSamples = 0;
  uint8_t maxLagSamples = 0;
};

// Estimates inter-microphone delay from interleaved signed PCM. Positive lag
// means channel 1 trails channel 0. Physical left/right sign is applied by the
// caller because codec channel ordering depends on board orientation.
StereoDirectionEstimate estimateStereoDirection(const int16_t* interleaved,
                                                  size_t frameCount,
                                                  uint32_t sampleRate,
                                                  uint8_t maxLagSamples = 0);

}  // namespace stackchan
