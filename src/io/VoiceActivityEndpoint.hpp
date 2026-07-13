#pragma once

#include <stddef.h>
#include <stdint.h>

namespace stackchan {

#ifndef STACKCHAN_CONVERSATION_REPLY_VAD
#define STACKCHAN_CONVERSATION_REPLY_VAD 0
#endif

enum class VoiceActivityEndpointReason : uint8_t {
  None = 0,
  TrailingSilence,
  MaxDuration,
};

struct VoiceActivityEndpointConfig {
  bool enabled = STACKCHAN_CONVERSATION_REPLY_VAD != 0;
  uint32_t sampleRate = 16000;
  uint32_t minimumCaptureMs = 600;
  uint32_t minimumSpeechMs = 150;
  uint32_t trailingSilenceMs = 550;
  uint32_t maximumCaptureMs = 4800;
  float initialNoiseFloor = 0.015f;
  float minimumSpeechLevel = 0.040f;
  float speechNoiseMultiplier = 2.6f;
  float speechZcrMin = 0.025f;
  float speechZcrMax = 0.35f;
};

struct VoiceActivityEndpointTelemetry {
  bool ready = false;
  bool enabled = false;
  bool active = false;
  bool speechSeen = false;
  uint32_t capturesStarted = 0;
  uint32_t chunksProcessed = 0;
  uint32_t speechChunks = 0;
  uint32_t endpointsDetected = 0;
  uint32_t maxDurationFallbacks = 0;
  uint32_t captureStartedAtMs = 0;
  uint32_t lastSpeechAtMs = 0;
  uint32_t lastEndpointAtMs = 0;
  float lastLevel = 0.0f;
  float lastZeroCrossingRate = 0.0f;
  float noiseFloor = 0.015f;
  VoiceActivityEndpointReason lastReason = VoiceActivityEndpointReason::None;
};

class VoiceActivityEndpoint {
 public:
  bool begin(const VoiceActivityEndpointConfig& config, uint32_t nowMs);
  VoiceActivityEndpointReason process(const int16_t* samples, size_t sampleCount, uint32_t nowMs);
  VoiceActivityEndpointReason forceMaximum(uint32_t nowMs);
  void cancel();

  const VoiceActivityEndpointTelemetry& telemetry() const { return telemetry_; }

 private:
  static float level(const int16_t* samples, size_t sampleCount);
  static float zeroCrossingRate(const int16_t* samples, size_t sampleCount);
  VoiceActivityEndpointReason finish(VoiceActivityEndpointReason reason, uint32_t nowMs);

  VoiceActivityEndpointConfig config_;
  VoiceActivityEndpointTelemetry telemetry_;
  uint32_t consecutiveSpeechMs_ = 0;
};

const char* voiceActivityEndpointReasonName(VoiceActivityEndpointReason reason);

}  // namespace stackchan
