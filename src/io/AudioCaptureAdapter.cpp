#include "io/AudioCaptureAdapter.hpp"

#include <cstring>

#if defined(ARDUINO_ARCH_ESP32)
#include <M5Unified.h>
#define STACKCHAN_HAS_M5_MIC_CAPTURE 1
#else
#define STACKCHAN_HAS_M5_MIC_CAPTURE 0
#endif

namespace stackchan {

bool AudioCaptureAdapter::begin(const AudioCaptureConfig& config, AudioCaptureSource* source) {
  config_ = config;
  source_ = source;
  telemetry_ = AudioCaptureTelemetry {};
  telemetry_.ready = true;
  telemetry_.enabled = config_.enabled;
  lastPollMs_ = 0;
  reflex_.reset(config_.noiseFloor);

  if (!config_.enabled) {
    copyError("mic_capture_disabled");
    return true;
  }
  if (!configured()) {
    copyError("mic_capture_bad_config");
    return false;
  }
  if (source_ == nullptr) {
    copyError("mic_capture_source_missing");
    return false;
  }
  if (!source_->begin(config_.sampleRate, config_.windowSamples) || !source_->isEnabled()) {
    copyError("mic_begin_failed");
    return false;
  }

  telemetry_.hardwareReady = true;
  telemetry_.lastError[0] = '\0';
  return true;
}

void AudioCaptureAdapter::stop() {
  if (source_ != nullptr) {
    source_->end();
  }
  telemetry_.hardwareReady = false;
}

uint8_t AudioCaptureAdapter::poll(uint32_t nowMs, AudioReflexEvent* eventsOut, uint8_t maxEvents) {
  if (!telemetry_.ready || !config_.enabled || !telemetry_.hardwareReady || source_ == nullptr) {
    return 0;
  }
  if (config_.minPollIntervalMs != 0 && lastPollMs_ != 0 &&
      nowMs - lastPollMs_ < config_.minPollIntervalMs) {
    return 0;
  }
  lastPollMs_ = nowMs;
  telemetry_.polls++;

  if (!source_->isEnabled()) {
    telemetry_.hardwareReady = false;
    telemetry_.windowsDropped++;
    copyError("mic_not_enabled");
    return 0;
  }
  if (!source_->record(mono_, config_.windowSamples, config_.sampleRate)) {
    telemetry_.windowsDropped++;
    return 0;
  }

  const AudioSaliencySample sample = makeAudioSaliencySample(
      AudioPcmWindow {nowMs, mono_, nullptr, config_.windowSamples});
  telemetry_.windowsCaptured++;
  telemetry_.samplesCaptured += config_.windowSamples;
  telemetry_.lastWindowMs = nowMs;
  telemetry_.lastLevel = (sample.leftEnergy + sample.rightEnergy) * 0.5f;
  telemetry_.lastZeroCrossingRate = sample.zeroCrossingRate;
  const uint8_t count = reflex_.process(sample, eventsOut, maxEvents);
  telemetry_.eventsPublished += count;
  return count;
}

bool AudioCaptureAdapter::configured() const {
  return config_.sampleRate != 0 && config_.windowSamples != 0 &&
         config_.windowSamples <= kAudioCaptureWindowSamples;
}

void AudioCaptureAdapter::copyError(const char* reason) {
  if (reason == nullptr) {
    telemetry_.lastError[0] = '\0';
    return;
  }
  const size_t len = std::strlen(reason);
  const size_t copyLen = len < (sizeof(telemetry_.lastError) - 1u) ? len : (sizeof(telemetry_.lastError) - 1u);
  std::memcpy(telemetry_.lastError, reason, copyLen);
  telemetry_.lastError[copyLen] = '\0';
}

bool M5MicAudioCaptureSource::begin(uint32_t sampleRate, uint16_t windowSamples) {
  (void)sampleRate;
  (void)windowSamples;
#if STACKCHAN_HAS_M5_MIC_CAPTURE
  return M5.Mic.begin();
#else
  return false;
#endif
}

bool M5MicAudioCaptureSource::isEnabled() const {
#if STACKCHAN_HAS_M5_MIC_CAPTURE
  return M5.Mic.isEnabled();
#else
  return false;
#endif
}

bool M5MicAudioCaptureSource::record(int16_t* out, uint16_t sampleCount, uint32_t sampleRate) {
  if (out == nullptr || sampleCount == 0 || sampleRate == 0) {
    return false;
  }
#if STACKCHAN_HAS_M5_MIC_CAPTURE
  return M5.Mic.record(out, sampleCount, sampleRate);
#else
  (void)out;
  (void)sampleCount;
  (void)sampleRate;
  return false;
#endif
}

void M5MicAudioCaptureSource::end() {
#if STACKCHAN_HAS_M5_MIC_CAPTURE
  M5.Mic.end();
#endif
}

}  // namespace stackchan
