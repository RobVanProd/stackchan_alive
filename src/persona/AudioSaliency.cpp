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

}  // namespace stackchan
