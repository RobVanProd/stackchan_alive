#pragma once

#include <stddef.h>
#include <stdint.h>

#include "persona/EarconSynth.hpp"
#include "persona/StateMatrix.hpp"

namespace stackchan {

constexpr size_t kSpeechAdapterEarconBufferSamples =
    (static_cast<size_t>(kEarconSampleRate) * kEarconMaxDurationMs) / 1000u;

enum class PromptSource : uint8_t {
  None,
  PackagedPrompt,
  HostBridge,
};

struct SpeechPlaybackPlan {
  uint32_t seq = 0;
  uint32_t queuedAtMs = 0;
  SpeechIntent intent = SpeechIntent::None;
  SpeechEarcon earcon = SpeechEarcon::None;
  PromptSource promptSource = PromptSource::None;
  const char* promptText = "";
  const char* promptId = "";
  uint16_t promptChars = 0;
  uint16_t earconDelayMs = 0;
  EarconRenderResult earconRender;
  bool hasPrompt = false;
  bool hasEarcon = false;
};

struct SpeechAdapterTelemetry {
  bool ready = false;
  bool hardwareEnabled = false;
  uint32_t cuesQueued = 0;
  uint32_t earconsRendered = 0;
  uint32_t lastSeq = 0;
  SpeechIntent lastIntent = SpeechIntent::None;
  SpeechEarcon lastEarcon = SpeechEarcon::None;
  uint16_t lastEarconDelayMs = 0;
  uint32_t lastEarconSamples = 0;
  uint32_t lastEarconChecksum = 2166136261u;
  int16_t lastEarconPeakAbs = 0;
  uint16_t lastPromptChars = 0;
};

class SpeechAdapter {
 public:
  bool begin(bool hardwareEnabled = false);
  bool handleCue(const SpeechCue& cue, uint32_t seq, const EmotionalProfile& emotion, uint32_t nowMs);

  const SpeechAdapterTelemetry& telemetry() const {
    return telemetry_;
  }

  const SpeechPlaybackPlan& lastPlan() const {
    return lastPlan_;
  }

 private:
  static const char* promptIdForIntent(SpeechIntent intent);
  static PromptSource sourceForIntent(SpeechIntent intent);
  static uint16_t promptLength(const char* text);
  static float earconIntensity(const EmotionalProfile& emotion, const SpeechCue& cue);

  SpeechAdapterTelemetry telemetry_;
  SpeechPlaybackPlan lastPlan_;
  int16_t earconBuffer_[kSpeechAdapterEarconBufferSamples] = {};
};

}  // namespace stackchan
