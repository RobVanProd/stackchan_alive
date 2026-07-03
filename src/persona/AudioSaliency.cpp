#include "persona/AudioSaliency.hpp"

#include <math.h>

namespace stackchan {

void AudioSaliency::reset(float noiseFloor) {
  noiseFloor_ = clamp01(noiseFloor);
  if (noiseFloor_ < 0.005f) {
    noiseFloor_ = 0.005f;
  }
  lastAzimuthDeg_ = 0.0f;
  lastSalientMs_ = 0;
  speechActive_ = false;
}

AudioSaliencyResult AudioSaliency::process(const AudioSaliencySample& sample) {
  const float left = clamp01(sample.leftEnergy);
  const float right = clamp01(sample.rightEnergy);
  const float level = (left + right) * 0.5f;
  const float zcr = clamp01(sample.zeroCrossingRate);

  const bool speechBand = zcr >= 0.035f && zcr <= 0.32f;
  const bool speechActive = speechBand && level > noiseFloor_ * 2.6f && level > 0.045f;
  const bool loudNoise = level > max(0.70f, noiseFloor_ * 8.0f);
  const bool salient = speechActive || loudNoise;

  if (!salient) {
    const float adapt = level > noiseFloor_ ? 0.005f : 0.020f;
    noiseFloor_ = noiseFloor_ + (level - noiseFloor_) * adapt;
    if (noiseFloor_ < 0.005f) {
      noiseFloor_ = 0.005f;
    }
  }

  AudioSaliencyResult result;
  result.level = level;
  result.noiseFloor = noiseFloor_;
  result.speechActive = speechActive;
  result.speechStarted = speechActive && !speechActive_;
  result.speechEnded = !speechActive && speechActive_;
  result.loudNoise = loudNoise;
  result.salient = salient;

  const float sum = left + right;
  if (sum > 0.001f) {
    result.azimuthDeg = constrain(((right - left) / sum) * 75.0f, -75.0f, 75.0f);
  }

  if (salient) {
    const uint32_t sinceLast = sample.timestampMs - lastSalientMs_;
    const float directionDelta = fabsf(result.azimuthDeg - lastAzimuthDeg_);
    if (lastSalientMs_ != 0 && sinceLast < 1800 && directionDelta < 18.0f) {
      result.habituation = 0.55f;
      result.salient = loudNoise || level > noiseFloor_ * 5.0f;
    } else if (lastSalientMs_ != 0 && sinceLast < 2800 && directionDelta < 30.0f) {
      result.habituation = 0.25f;
    }
    if (result.salient) {
      lastSalientMs_ = sample.timestampMs;
      lastAzimuthDeg_ = result.azimuthDeg;
    }
  }

  speechActive_ = speechActive;
  return result;
}

float AudioSaliency::clamp01(float value) {
  return constrain(value, 0.0f, 1.0f);
}

void AudioReflex::reset(float noiseFloor) {
  saliency_.reset(noiseFloor);
  telemetry_ = AudioReflexTelemetry {};
  telemetry_.noiseFloor = noiseFloor;
}

uint8_t AudioReflex::process(const AudioSaliencySample& sample, AudioReflexEvent* eventsOut, uint8_t maxEvents) {
  if (eventsOut == nullptr || maxEvents == 0) {
    return 0;
  }

  const AudioSaliencyResult result = saliency_.process(sample);
  telemetry_.detectedAtMs = sample.timestampMs;
  telemetry_.level = result.level;
  telemetry_.azimuthDeg = result.azimuthDeg;
  telemetry_.noiseFloor = result.noiseFloor;
  telemetry_.habituation = result.habituation;
  telemetry_.speechActive = result.speechActive;
  telemetry_.loudNoise = result.loudNoise;

  uint8_t count = 0;
  auto emitEvent = [&](EventType type, CharacterMode mode, float strength, const char* command) {
    if (count >= maxEvents) {
      return;
    }
    AudioReflexEvent& out = eventsOut[count++];
    out.valid = true;
    out.mode = mode;
    out.command = command;
    out.event.type = type;
    out.event.timestampMs = sample.timestampMs;
    out.event.strength = constrain(strength, 0.0f, 1.0f);
    out.event.hasPayload = true;
    out.event.x = azimuthNorm(result.azimuthDeg);
    out.event.z = result.level;
  };

  if (result.loudNoise) {
    emitEvent(EventType::LoudNoise, CharacterMode::React, strengthFromLevel(result.level), "audio_loud_noise");
    return count;
  }

  if (result.speechStarted) {
    emitEvent(EventType::UserSpeaking, CharacterMode::Listen, strengthFromLevel(result.level), "audio_user_speaking");
  }
  if (result.salient && result.speechActive) {
    emitEvent(EventType::SoundDirection, CharacterMode::Attend, strengthFromLevel(result.level), "audio_sound_direction");
  }
  if (result.speechEnded) {
    emitEvent(EventType::SpeechEnded, CharacterMode::Idle, 1.0f, "audio_speech_ended");
  }

  return count;
}

float AudioReflex::strengthFromLevel(float level) {
  return constrain(level * 1.35f, 0.0f, 1.0f);
}

float AudioReflex::azimuthNorm(float azimuthDeg) {
  return constrain(azimuthDeg / 90.0f, -1.0f, 1.0f);
}

}  // namespace stackchan
