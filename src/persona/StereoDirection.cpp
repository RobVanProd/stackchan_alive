#include "persona/StereoDirection.hpp"

#include <math.h>

namespace stackchan {

namespace {
constexpr float kMinimumLevel = 0.006f;
constexpr float kMinimumCorrelation = 0.20f;
constexpr float kSoundSpeedMetersPerSecond = 343.0f;
constexpr float kConservativeMicSpacingMeters = 0.075f;

float clamp01(float value) {
  return constrain(value, 0.0f, 1.0f);
}
}  // namespace

StereoDirectionEstimate estimateStereoDirection(const int16_t* interleaved,
                                                  size_t frameCount,
                                                  uint32_t sampleRate,
                                                  uint8_t requestedMaxLagSamples) {
  StereoDirectionEstimate result;
  if (interleaved == nullptr || frameCount < 32 || sampleRate == 0) {
    return result;
  }

  uint8_t maxLag = requestedMaxLagSamples;
  if (maxLag == 0) {
    const float physicalLag =
        (sampleRate * kConservativeMicSpacingMeters) / kSoundSpeedMetersPerSecond;
    maxLag = static_cast<uint8_t>(ceilf(physicalLag));
  }
  maxLag = constrain(maxLag, static_cast<uint8_t>(1), static_cast<uint8_t>(8));
  if (frameCount <= static_cast<size_t>(maxLag * 2u + 8u)) {
    return result;
  }
  result.maxLagSamples = maxLag;

  double leftMean = 0.0;
  double rightMean = 0.0;
  double combinedSquares = 0.0;
  for (size_t i = 0; i < frameCount; ++i) {
    const double left = interleaved[i * 2u];
    const double right = interleaved[i * 2u + 1u];
    leftMean += left;
    rightMean += right;
    combinedSquares += left * left + right * right;
  }
  leftMean /= static_cast<double>(frameCount);
  rightMean /= static_cast<double>(frameCount);
  result.level = clamp01(static_cast<float>(
      sqrt(combinedSquares / static_cast<double>(frameCount * 2u)) / 32768.0));
  if (result.level < kMinimumLevel) {
    return result;
  }

  float bestCorrelation = -1.0f;
  float secondCorrelation = -1.0f;
  int bestLag = 0;
  for (int lag = -static_cast<int>(maxLag); lag <= static_cast<int>(maxLag); ++lag) {
    const size_t leftStart = lag < 0 ? static_cast<size_t>(-lag) : 0u;
    const size_t rightStart = lag > 0 ? static_cast<size_t>(lag) : 0u;
    const size_t count = frameCount - static_cast<size_t>(abs(lag));
    double cross = 0.0;
    double leftSquares = 0.0;
    double rightSquares = 0.0;
    for (size_t i = 0; i < count; ++i) {
      const double left = interleaved[(leftStart + i) * 2u] - leftMean;
      const double right = interleaved[(rightStart + i) * 2u + 1u] - rightMean;
      cross += left * right;
      leftSquares += left * left;
      rightSquares += right * right;
    }
    const double denominator = sqrt(leftSquares * rightSquares);
    const float correlation =
        denominator > 1.0 ? static_cast<float>(cross / denominator) : -1.0f;
    if (correlation > bestCorrelation) {
      secondCorrelation = bestCorrelation;
      bestCorrelation = correlation;
      bestLag = lag;
    } else if (correlation > secondCorrelation) {
      secondCorrelation = correlation;
    }
  }

  result.correlation = bestCorrelation;
  result.lagSamples = static_cast<int8_t>(bestLag);
  if (bestCorrelation < kMinimumCorrelation) {
    return result;
  }

  const float levelConfidence = clamp01((result.level - kMinimumLevel) / 0.035f);
  const float correlationConfidence =
      clamp01((bestCorrelation - kMinimumCorrelation) / (1.0f - kMinimumCorrelation));
  const float separationConfidence =
      clamp01((bestCorrelation - secondCorrelation) / 0.18f);
  result.confidence =
      levelConfidence * correlationConfidence * (0.35f + separationConfidence * 0.65f);
  result.azimuthNorm = constrain(
      static_cast<float>(bestLag) / static_cast<float>(maxLag), -1.0f, 1.0f);
  result.valid = result.confidence >= 0.08f;
  return result;
}

}  // namespace stackchan
