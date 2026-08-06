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
  // Preserve natural clause pauses. Physical qualification proved that a
  // 1200 ms tail still endpointed a deliberate mid-sentence pause after
  // "wait until I finish". Two seconds keeps normal hesitation inside the
  // same turn while retaining the 12 second hard capture ceiling.
  uint32_t trailingSilenceMs = 2000;
  // Ceiling, not the normal path. Capture ends on trailing silence as soon as
  // the speaker stops; this only catches the case where silence is never
  // detected. It used to be 4800 ms, which truncated any sentence longer than
  // about five seconds mid-word. Bounded by the 512 KB uplink limit: 12 s of
  // 16 kHz mono PCM is 384 KB.
  uint32_t maximumCaptureMs = 12000;
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
  // Semantic endpoint timing is based only on PCM that was actually captured.
  // Wall time above remains diagnostic and must not turn a transport/microphone
  // stall into apparent silence.
  uint32_t capturedAudioMs = 0;
  uint32_t lastSpeechAudioMs = 0;
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
  uint64_t capturedSamples_ = 0;
  uint64_t consecutiveSpeechSamples_ = 0;
  uint64_t lastSpeechEndSample_ = 0;
};

const char* voiceActivityEndpointReasonName(VoiceActivityEndpointReason reason);

}  // namespace stackchan
