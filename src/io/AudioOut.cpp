#include "io/AudioOut.hpp"

#include <string.h>

namespace stackchan {
namespace {

constexpr uint32_t kFallbackEarconOnlyDurationMs = 320;
constexpr uint32_t kBargeInDuckMs = 520;

bool containsText(const char* haystack, const char* needle) {
  return haystack != nullptr && needle != nullptr && strstr(haystack, needle) != nullptr;
}

float clamp01(float value) {
  if (value < 0.0f) {
    return 0.0f;
  }
  if (value > 1.0f) {
    return 1.0f;
  }
  return value;
}

}  // namespace

bool AudioOut::begin(bool hardwareEnabled, AudioOutSpeakerSink* speakerSink) {
  telemetry_ = AudioOutTelemetry {};
  lastRequest_ = AudioOutPlaybackRequest {};
  playback_ = PlaybackState {};
  speakerSink_ = speakerSink;
  telemetry_.ready = true;
  telemetry_.hardwareEnabled = hardwareEnabled;
  telemetry_.hardwareReady = hardwareEnabled && speakerSink_ != nullptr && speakerSink_->begin() && speakerSink_->isReady();
  telemetry_.taskPinnedToCore0 = telemetry_.hardwareReady;
  return true;
}

bool AudioOut::enqueue(const AudioOutPlaybackRequest& request) {
  if (!telemetry_.ready || request.seq == 0 || (!request.hasPrompt && !request.hasEarcon)) {
    telemetry_.requestsDropped++;
    return false;
  }

  lastRequest_ = request;
  playback_ = PlaybackState {};
  playback_.seq = request.seq;
  playback_.startMs = request.queuedAtMs;
  playback_.promptStartMs = request.queuedAtMs + request.earconDelayMs;
  playback_.timing = resolveSidecar(request);
  playback_.durationMs = playback_.timing.durationMs;
  playback_.active = playback_.durationMs > 0;
  playback_.clearPending = playback_.active;

  telemetry_.requestsQueued++;
  telemetry_.lastSeq = request.seq;
  telemetry_.lastSource = request.source;
  telemetry_.lastPromptId = request.promptId;
  telemetry_.lastWavPath = request.wavPath;
  telemetry_.lastSidecarPath = request.sidecarPath;
  telemetry_.lastEarconSamples = request.earconSamples;
  telemetry_.playbackActive = playback_.active;
  telemetry_.duckActive = false;
  telemetry_.playbackSeq = playback_.seq;
  telemetry_.playbackStartedMs = playback_.promptStartMs;
  telemetry_.playbackElapsedMs = 0;
  telemetry_.playbackDurationMs = playback_.durationMs;
  telemetry_.sidecarFrameMs = playback_.timing.frameMs;
  telemetry_.sidecarFrames = playback_.timing.frames;
  startHardwarePlayback(request);
  return true;
}

bool AudioOut::pollSpeechFrame(uint32_t nowMs, AudioOutSpeechFrame* frameOut) {
  if (frameOut == nullptr || !telemetry_.ready || !playback_.active) {
    return false;
  }

  if (nowMs < playback_.promptStartMs) {
    return false;
  }

  const uint32_t elapsedMs = nowMs - playback_.promptStartMs;
  telemetry_.playbackElapsedMs = elapsedMs;
  telemetry_.duckActive = playback_.duckUntilMs > nowMs;

  if (elapsedMs >= playback_.durationMs) {
    if (!playback_.clearPending) {
      playback_.active = false;
      telemetry_.playbackActive = false;
      telemetry_.duckActive = false;
      stopHardwarePlayback();
      return false;
    }

    playback_.clearPending = false;
    playback_.active = false;
    telemetry_.playbackActive = false;
    telemetry_.duckActive = false;
    telemetry_.playbackCompleted++;
    telemetry_.lastEnvelope = 0.0f;
    telemetry_.lastViseme = AudioOutViseme::Neutral;
    *frameOut = AudioOutSpeechFrame {};
    frameOut->seq = playback_.seq;
    frameOut->timestampMs = nowMs;
    frameOut->clear = true;
    stopHardwarePlayback();
    return true;
  }

  const uint32_t frameIndex = playback_.timing.frameMs > 0 ? elapsedMs / playback_.timing.frameMs : 0;
  if (static_cast<int32_t>(frameIndex) == playback_.lastFrameIndex) {
    return false;
  }
  playback_.lastFrameIndex = static_cast<int32_t>(frameIndex);

  float envelope = envelopeForFrame(playback_.timing, frameIndex);
  const bool ducked = playback_.duckUntilMs > nowMs;
  if (ducked) {
    envelope *= 0.34f;
  }
  envelope = clamp01(envelope);
  const AudioOutViseme viseme = visemeForFrame(playback_.timing, frameIndex, envelope);

  *frameOut = AudioOutSpeechFrame {};
  frameOut->active = true;
  frameOut->seq = playback_.seq;
  frameOut->timestampMs = nowMs;
  frameOut->durationMs = playback_.timing.frameMs + 60;
  frameOut->envelope = envelope;
  frameOut->viseme = viseme;

  telemetry_.speechFramesEmitted++;
  telemetry_.lastEnvelope = envelope;
  telemetry_.lastViseme = viseme;
  submitHardwareFrame(*frameOut, ducked);
  return true;
}

bool AudioOut::duck(uint32_t nowMs) {
  if (!telemetry_.ready || !playback_.active || !lastRequest_.duckOnBargeIn) {
    return false;
  }
  playback_.duckUntilMs = nowMs + kBargeInDuckMs;
  playback_.duckActive = true;
  telemetry_.duckActive = true;
  telemetry_.duckEvents++;
  return true;
}

void AudioOut::startHardwarePlayback(const AudioOutPlaybackRequest& request) {
  telemetry_.hardwarePlaybackActive = false;
  if (!telemetry_.hardwareEnabled || !telemetry_.hardwareReady || speakerSink_ == nullptr || !playback_.active) {
    return;
  }

  if (!speakerSink_->start(request, playback_.promptStartMs, playback_.durationMs)) {
    telemetry_.hardwareFrameDrops++;
    return;
  }

  telemetry_.hardwarePlaybackActive = true;
  telemetry_.hardwareStarts++;
}

void AudioOut::submitHardwareFrame(const AudioOutSpeechFrame& frame, bool ducked) {
  if (!telemetry_.hardwarePlaybackActive || speakerSink_ == nullptr) {
    return;
  }

  AudioOutHardwareFrame hardwareFrame;
  hardwareFrame.active = frame.active;
  hardwareFrame.clear = frame.clear;
  hardwareFrame.ducked = ducked;
  hardwareFrame.envelope = frame.envelope;
  hardwareFrame.viseme = frame.viseme;
  hardwareFrame.seq = frame.seq;
  hardwareFrame.timestampMs = frame.timestampMs;
  hardwareFrame.durationMs = frame.durationMs;

  if (speakerSink_->writeFrame(hardwareFrame)) {
    telemetry_.hardwareFramesSubmitted++;
  } else {
    telemetry_.hardwareFrameDrops++;
  }
}

void AudioOut::stopHardwarePlayback() {
  if (!telemetry_.hardwarePlaybackActive) {
    return;
  }
  if (speakerSink_ != nullptr) {
    speakerSink_->stop();
  }
  telemetry_.hardwarePlaybackActive = false;
  telemetry_.hardwareStops++;
}

AudioOut::SidecarTiming AudioOut::resolveSidecar(const AudioOutPlaybackRequest& request) {
  SidecarTiming timing;

  if (request.hasPrompt) {
    if (containsText(request.sidecarPath, "stackchan_spark_greeting")) {
      timing.frames = 316;
      timing.durationMs = 6313;
      timing.voiceShape = 0;
      return timing;
    }
    if (containsText(request.sidecarPath, "stackchan_spark_thinking")) {
      timing.frames = 421;
      timing.durationMs = 8414;
      timing.voiceShape = 1;
      return timing;
    }
    if (containsText(request.sidecarPath, "stackchan_spark_safety")) {
      timing.frames = 419;
      timing.durationMs = 8362;
      timing.voiceShape = 2;
      return timing;
    }

    const uint32_t estimatedMs = 900u + static_cast<uint32_t>(request.promptChars) * 56u;
    timing.frames = static_cast<uint16_t>(estimatedMs / timing.frameMs);
    timing.durationMs = estimatedMs;
    timing.voiceShape = 1;
    return timing;
  }

  if (request.hasEarcon) {
    timing.frames = static_cast<uint16_t>(kFallbackEarconOnlyDurationMs / timing.frameMs);
    timing.durationMs = kFallbackEarconOnlyDurationMs;
    timing.voiceShape = 0;
  }
  return timing;
}

float AudioOut::envelopeForFrame(const SidecarTiming& timing, uint32_t frameIndex) {
  if (timing.frames == 0) {
    return 0.0f;
  }

  const uint32_t tailStart = timing.frames > 10 ? timing.frames - 10 : timing.frames;
  float gain = 1.0f;
  if (frameIndex < 6) {
    gain = static_cast<float>(frameIndex + 1) / 6.0f;
  } else if (frameIndex >= tailStart && timing.frames > tailStart) {
    gain = static_cast<float>(timing.frames - frameIndex) / static_cast<float>(timing.frames - tailStart);
  }

  const uint32_t phrase = (frameIndex + timing.voiceShape * 3u) % 29u;
  if (phrase >= 24u) {
    return 0.05f * gain;
  }

  const uint32_t syllable = (frameIndex * (5u + timing.voiceShape) + 3u) % 17u;
  float pulse = 0.28f + static_cast<float>(syllable % 9u) * 0.075f;
  if (syllable > 11u) {
    pulse *= 0.62f;
  }
  if ((frameIndex + timing.voiceShape) % 41u == 0u) {
    pulse = 0.86f;
  }
  return clamp01(pulse * gain);
}

AudioOutViseme AudioOut::visemeForFrame(const SidecarTiming& timing, uint32_t frameIndex, float envelope) {
  if (envelope < 0.08f) {
    return AudioOutViseme::Neutral;
  }

  const uint32_t cycle = (frameIndex + timing.voiceShape * 2u) % 18u;
  if (timing.voiceShape == 2) {
    if (cycle < 7u) {
      return AudioOutViseme::Ee;
    }
    return cycle < 12u ? AudioOutViseme::Ah : AudioOutViseme::Oh;
  }
  if (cycle < 6u) {
    return AudioOutViseme::Ah;
  }
  if (cycle < 12u) {
    return AudioOutViseme::Oh;
  }
  return AudioOutViseme::Ee;
}

}  // namespace stackchan
