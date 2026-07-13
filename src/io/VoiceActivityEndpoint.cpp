#include "io/VoiceActivityEndpoint.hpp"

#include <math.h>

namespace stackchan {
namespace {
float clamp01(float value) {
  if (value < 0.0f) {
    return 0.0f;
  }
  return value > 1.0f ? 1.0f : value;
}
}

bool VoiceActivityEndpoint::begin(const VoiceActivityEndpointConfig& config, uint32_t nowMs) {
  config_ = config;
  telemetry_.ready = config_.sampleRate > 0 && config_.minimumSpeechMs > 0 &&
                     config_.trailingSilenceMs > 0 && config_.maximumCaptureMs > 0 &&
                     config_.minimumCaptureMs <= config_.maximumCaptureMs &&
                     config_.speechZcrMin < config_.speechZcrMax;
  telemetry_.enabled = config_.enabled;
  telemetry_.active = telemetry_.ready && telemetry_.enabled;
  telemetry_.speechSeen = false;
  telemetry_.captureStartedAtMs = nowMs;
  telemetry_.lastSpeechAtMs = 0;
  telemetry_.lastLevel = 0.0f;
  telemetry_.lastZeroCrossingRate = 0.0f;
  telemetry_.noiseFloor = clamp01(config_.initialNoiseFloor);
  telemetry_.lastReason = VoiceActivityEndpointReason::None;
  consecutiveSpeechMs_ = 0;
  if (telemetry_.active) {
    ++telemetry_.capturesStarted;
  }
  return telemetry_.ready;
}

VoiceActivityEndpointReason VoiceActivityEndpoint::process(const int16_t* samples,
                                                           size_t sampleCount,
                                                           uint32_t nowMs) {
  if (!telemetry_.active || samples == nullptr || sampleCount == 0) {
    return VoiceActivityEndpointReason::None;
  }

  ++telemetry_.chunksProcessed;
  telemetry_.lastLevel = level(samples, sampleCount);
  telemetry_.lastZeroCrossingRate = zeroCrossingRate(samples, sampleCount);
  const uint32_t chunkMs = static_cast<uint32_t>(
      (sampleCount * 1000u + config_.sampleRate - 1u) / config_.sampleRate);
  const float dynamicThreshold = telemetry_.noiseFloor * config_.speechNoiseMultiplier;
  const float speechThreshold = dynamicThreshold > config_.minimumSpeechLevel
                                    ? dynamicThreshold
                                    : config_.minimumSpeechLevel;
  const bool speechBand = telemetry_.lastZeroCrossingRate >= config_.speechZcrMin &&
                          telemetry_.lastZeroCrossingRate <= config_.speechZcrMax;
  const bool speech = speechBand && telemetry_.lastLevel >= speechThreshold;

  if (speech) {
    ++telemetry_.speechChunks;
    consecutiveSpeechMs_ += chunkMs > 0 ? chunkMs : 1u;
    telemetry_.lastSpeechAtMs = nowMs;
    if (consecutiveSpeechMs_ >= config_.minimumSpeechMs) {
      telemetry_.speechSeen = true;
    }
  } else {
    consecutiveSpeechMs_ = 0;
    if (!telemetry_.speechSeen) {
      const float adapt = telemetry_.lastLevel < telemetry_.noiseFloor ? 0.04f : 0.01f;
      telemetry_.noiseFloor += (telemetry_.lastLevel - telemetry_.noiseFloor) * adapt;
      if (telemetry_.noiseFloor < 0.005f) {
        telemetry_.noiseFloor = 0.005f;
      }
    }
  }

  const uint32_t elapsedMs = nowMs - telemetry_.captureStartedAtMs;
  if (telemetry_.speechSeen && !speech && elapsedMs >= config_.minimumCaptureMs &&
      nowMs - telemetry_.lastSpeechAtMs >= config_.trailingSilenceMs) {
    return finish(VoiceActivityEndpointReason::TrailingSilence, nowMs);
  }
  if (elapsedMs >= config_.maximumCaptureMs) {
    return finish(VoiceActivityEndpointReason::MaxDuration, nowMs);
  }
  return VoiceActivityEndpointReason::None;
}

void VoiceActivityEndpoint::cancel() {
  telemetry_.active = false;
  consecutiveSpeechMs_ = 0;
}

VoiceActivityEndpointReason VoiceActivityEndpoint::forceMaximum(uint32_t nowMs) {
  return telemetry_.active ? finish(VoiceActivityEndpointReason::MaxDuration, nowMs)
                           : VoiceActivityEndpointReason::None;
}

float VoiceActivityEndpoint::level(const int16_t* samples, size_t sampleCount) {
  double squares = 0.0;
  for (size_t i = 0; i < sampleCount; ++i) {
    const double normalized = static_cast<double>(samples[i]) / 32768.0;
    squares += normalized * normalized;
  }
  return clamp01(static_cast<float>(sqrt(squares / static_cast<double>(sampleCount))));
}

float VoiceActivityEndpoint::zeroCrossingRate(const int16_t* samples, size_t sampleCount) {
  if (sampleCount < 2) {
    return 0.0f;
  }
  size_t crossings = 0;
  int16_t previous = samples[0];
  for (size_t i = 1; i < sampleCount; ++i) {
    const int16_t current = samples[i];
    if ((previous < 0 && current >= 0) || (previous >= 0 && current < 0)) {
      ++crossings;
    }
    previous = current;
  }
  return clamp01(static_cast<float>(crossings) / static_cast<float>(sampleCount - 1u));
}

VoiceActivityEndpointReason VoiceActivityEndpoint::finish(VoiceActivityEndpointReason reason,
                                                          uint32_t nowMs) {
  telemetry_.active = false;
  telemetry_.lastReason = reason;
  telemetry_.lastEndpointAtMs = nowMs;
  ++telemetry_.endpointsDetected;
  if (reason == VoiceActivityEndpointReason::MaxDuration) {
    ++telemetry_.maxDurationFallbacks;
  }
  consecutiveSpeechMs_ = 0;
  return reason;
}

const char* voiceActivityEndpointReasonName(VoiceActivityEndpointReason reason) {
  switch (reason) {
    case VoiceActivityEndpointReason::TrailingSilence:
      return "trailing_silence";
    case VoiceActivityEndpointReason::MaxDuration:
      return "max_duration";
    case VoiceActivityEndpointReason::None:
    default:
      return "none";
  }
}

}  // namespace stackchan
