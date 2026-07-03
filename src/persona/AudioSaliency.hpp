#pragma once

#include <Arduino.h>

#include "persona/EventBus.hpp"
#include "persona/StateMatrix.hpp"

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

struct AudioReflexEvent {
  bool valid = false;
  CharacterMode mode = CharacterMode::Idle;
  RobotEvent event;
  const char* command = "";
};

struct AudioReflexTelemetry {
  uint32_t detectedAtMs = 0;
  float level = 0.0f;
  float azimuthDeg = 0.0f;
  float noiseFloor = 0.02f;
  float habituation = 0.0f;
  bool speechActive = false;
  bool loudNoise = false;
};

class AudioReflex {
 public:
  void reset(float noiseFloor = 0.02f);
  uint8_t process(const AudioSaliencySample& sample, AudioReflexEvent* eventsOut, uint8_t maxEvents);
  const AudioReflexTelemetry& telemetry() const {
    return telemetry_;
  }

 private:
  AudioSaliency saliency_;
  AudioReflexTelemetry telemetry_;

  static float strengthFromLevel(float level);
  static float azimuthNorm(float azimuthDeg);
};

}  // namespace stackchan
