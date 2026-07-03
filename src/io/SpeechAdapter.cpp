#include "io/SpeechAdapter.hpp"

#include "io/AudioOut.hpp"

#include <string.h>

namespace stackchan {

bool SpeechAdapter::begin(bool hardwareEnabled) {
  return begin(hardwareEnabled, nullptr);
}

bool SpeechAdapter::begin(bool hardwareEnabled, AudioOut* audioOut) {
  telemetry_ = SpeechAdapterTelemetry {};
  lastPlan_ = SpeechPlaybackPlan {};
  audioOut_ = audioOut;
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
  const SpeechPromptAsset& prompt = SpeechPromptBank::find(cue.intent);
  plan.promptId = prompt.id;
  plan.promptSource = prompt.source;
  plan.promptWavPath = prompt.wavPath;
  plan.promptSidecarPath = prompt.sidecarPath;
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

  if (audioOut_ != nullptr) {
    AudioOutPlaybackRequest request;
    request.seq = plan.seq;
    request.queuedAtMs = nowMs;
    request.source = plan.promptSource == PromptSource::PackagedPrompt ? AudioOutSource::PackagedPrompt
                                                                       : AudioOutSource::None;
    request.promptId = plan.promptId;
    request.wavPath = plan.promptWavPath;
    request.sidecarPath = plan.promptSidecarPath;
    request.earconSamples = plan.earconRender.samplesWritten;
    request.earconDelayMs = plan.earconDelayMs;
    request.promptChars = plan.promptChars;
    request.hasPrompt = plan.hasPrompt;
    request.hasEarcon = plan.hasEarcon;
    audioOut_->enqueue(request);
  }
  return true;
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
