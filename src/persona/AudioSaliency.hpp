#pragma once

#include <Arduino.h>

namespace stackchan {

struct AudioSaliencySample {
  uint32_t timestampMs = 0;
  float leftEnergy = 0.0f;
  float rightEnergy = 0.0f;
  float zeroCrossingRate = 0.0f;
};

struct AudioSaliencyResult {
  bool salient = false;
  bool speechActive = false;
  bool speechStarted = false;
  bool speechEnded = false;
  bool loudNoise = false;
  float level = 0.0f;
  float azimuthDeg = 0.0f;
  float habituation = 0.0f;
  float noiseFloor = 0.02f;
};

class AudioSaliency {
 public:
  void reset(float noiseFloor = 0.02f);
  AudioSaliencyResult process(const AudioSaliencySample& sample);

 private:
  float noiseFloor_ = 0.02f;
  float lastAzimuthDeg_ = 0.0f;
  uint32_t lastSalientMs_ = 0;
  bool speechActive_ = false;

  static float clamp01(float value);
};

}  // namespace stackchan
