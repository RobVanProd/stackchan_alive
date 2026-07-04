#pragma once

#include <Arduino.h>
#include <stdint.h>

#include "persona/AudioSaliency.hpp"

namespace stackchan {

#ifndef STACKCHAN_ENABLE_MIC_CAPTURE
#define STACKCHAN_ENABLE_MIC_CAPTURE 0
#endif

constexpr uint32_t kAudioCaptureSampleRate = 16000;
constexpr uint16_t kAudioCaptureWindowSamples = 200;
constexpr size_t kAudioCaptureErrorMax = 48;

struct AudioCaptureConfig {
  bool enabled = STACKCHAN_ENABLE_MIC_CAPTURE != 0;
  uint32_t sampleRate = kAudioCaptureSampleRate;
  uint16_t windowSamples = kAudioCaptureWindowSamples;
  uint32_t minPollIntervalMs = 10;
  float noiseFloor = 0.02f;
};

struct AudioCaptureTelemetry {
  bool ready = false;
  bool enabled = false;
  bool hardwareReady = false;
  uint32_t polls = 0;
  uint32_t windowsCaptured = 0;
  uint32_t windowsDropped = 0;
  uint32_t samplesCaptured = 0;
  uint32_t eventsPublished = 0;
  uint32_t lastWindowMs = 0;
  float lastLevel = 0.0f;
  float lastZeroCrossingRate = 0.0f;
  char lastError[kAudioCaptureErrorMax] = {};
};

class AudioCaptureSource {
 public:
  virtual ~AudioCaptureSource() = default;

  virtual bool begin(uint32_t sampleRate, uint16_t windowSamples) = 0;
  virtual bool isEnabled() const = 0;
  virtual bool record(int16_t* out, uint16_t sampleCount, uint32_t sampleRate) = 0;
  virtual void end() = 0;
};

class M5MicAudioCaptureSource final : public AudioCaptureSource {
 public:
  bool begin(uint32_t sampleRate, uint16_t windowSamples) override;
  bool isEnabled() const override;
  bool record(int16_t* out, uint16_t sampleCount, uint32_t sampleRate) override;
  void end() override;
};

class AudioCaptureAdapter {
 public:
  bool begin(const AudioCaptureConfig& config = AudioCaptureConfig {},
             AudioCaptureSource* source = nullptr);
  void stop();

  uint8_t poll(uint32_t nowMs, AudioReflexEvent* eventsOut, uint8_t maxEvents);

  const AudioCaptureTelemetry& telemetry() const {
    return telemetry_;
  }

  const int16_t* lastPcmWindow() const {
    return telemetry_.windowsCaptured > 0 ? mono_ : nullptr;
  }

  uint16_t lastPcmSampleCount() const {
    return telemetry_.windowsCaptured > 0 ? config_.windowSamples : 0;
  }

 private:
  bool configured() const;
  void copyError(const char* reason);

  AudioCaptureConfig config_;
  AudioCaptureTelemetry telemetry_;
  AudioCaptureSource* source_ = nullptr;
  AudioReflex reflex_;
  int16_t mono_[kAudioCaptureWindowSamples] = {};
  uint32_t lastPollMs_ = 0;
};

}  // namespace stackchan
