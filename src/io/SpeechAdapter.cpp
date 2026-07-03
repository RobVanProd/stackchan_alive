#include "io/SpeechAdapter.hpp"

#include <string.h>

namespace stackchan {

bool SpeechAdapter::begin(bool hardwareEnabled) {
  telemetry_ = SpeechAdapterTelemetry {};
  lastPlan_ = SpeechPlaybackPlan {};
  telemetry_.ready = true;
  telemetry_.hardwareEnabled = hardwareEnabled;
  return true;
}

bool SpeechAdapter::handleCue(const SpeechCue& cue, uint32_t seq, const EmotionalProfile& emotion, uint32_t nowMs) {
  if (!telemetry_.ready || seq == 0 || !cue.shouldSpeak()) {
    return false;
  }

  SpeechPlaybackPlan plan;
  plan.seq = seq;
  plan.queuedAtMs = nowMs;
  plan.intent = cue.intent;
  plan.earcon = cue.earcon;
  plan.promptText = cue.text;
  plan.promptId = promptIdForIntent(cue.intent);
  plan.promptSource = sourceForIntent(cue.intent);
  plan.promptChars = promptLength(cue.text);
  plan.earconDelayMs = cue.earconDelayMs;
  plan.hasPrompt = plan.promptSource != PromptSource::None && plan.promptChars > 0;
  plan.hasEarcon = cue.hasEarcon();

  if (plan.hasEarcon) {
    EarconRenderConfig config;
    config.intensity = earconIntensity(emotion, cue);
    plan.earconRender = EarconSynth::render(cue.earcon, earconBuffer_, kSpeechAdapterEarconBufferSamples, config);
    telemetry_.earconsRendered++;
  }

  lastPlan_ = plan;
  telemetry_.cuesQueued++;
  telemetry_.lastSeq = seq;
  telemetry_.lastIntent = cue.intent;
  telemetry_.lastEarcon = cue.earcon;
  telemetry_.lastEarconDelayMs = cue.earconDelayMs;
  telemetry_.lastEarconSamples = plan.earconRender.samplesWritten;
  telemetry_.lastEarconChecksum = plan.earconRender.checksum;
  telemetry_.lastEarconPeakAbs = plan.earconRender.peakAbs;
  telemetry_.lastPromptChars = plan.promptChars;
  return true;
}

const char* SpeechAdapter::promptIdForIntent(SpeechIntent intent) {
  switch (intent) {
    case SpeechIntent::Boot:
      return "boot_awake";
    case SpeechIntent::Idle:
      return "idle_curiosity";
    case SpeechIntent::Attend:
    case SpeechIntent::Listen:
      return "listen_attention";
    case SpeechIntent::Think:
      return "think_processing";
    case SpeechIntent::Speak:
      return "speak_new_information";
    case SpeechIntent::React:
      return "react_display_ready";
    case SpeechIntent::Happy:
      return "happy_signal";
    case SpeechIntent::Concern:
      return "concern_more_data";
    case SpeechIntent::Sleep:
      return "sleep_systems_quiet";
    case SpeechIntent::Error:
      return "error_small_problem";
    case SpeechIntent::Safety:
      return "safety_servo_not_armed";
    case SpeechIntent::None:
      break;
  }
  return "";
}

PromptSource SpeechAdapter::sourceForIntent(SpeechIntent intent) {
  return intent == SpeechIntent::None ? PromptSource::None : PromptSource::PackagedPrompt;
}

uint16_t SpeechAdapter::promptLength(const char* text) {
  if (text == nullptr) {
    return 0;
  }
  const size_t len = strlen(text);
  return len > 65535u ? 65535u : static_cast<uint16_t>(len);
}

float SpeechAdapter::earconIntensity(const EmotionalProfile& emotion, const SpeechCue& cue) {
  float intensity = 0.52f + emotion.arousal * 0.34f;
  if (cue.intent == SpeechIntent::Safety || cue.intent == SpeechIntent::Error) {
    intensity += 0.12f;
  }
  if (cue.intent == SpeechIntent::Sleep) {
    intensity -= 0.18f;
  }
  if (intensity < 0.25f) {
    return 0.25f;
  }
  if (intensity > 1.0f) {
    return 1.0f;
  }
  return intensity;
}

}  // namespace stackchan
