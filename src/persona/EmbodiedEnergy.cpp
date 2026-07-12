#include "persona/EmbodiedEnergy.hpp"

#include <Arduino.h>

namespace stackchan {

namespace {
constexpr uint8_t kCriticalEnterPercent = 10;
constexpr uint8_t kCriticalRecoverPercent = 15;
constexpr uint8_t kLowEnterPercent = 20;
constexpr uint8_t kLowRecoverPercent = 25;
constexpr float kBiasAttackPerSecond = 0.12f;
constexpr float kBiasReleasePerSecond = 0.06f;

struct EnergyBiasTargets {
  float fatigue = 0.0f;
  float arousal = 0.0f;
  float valence = 0.0f;
  float focus = 0.0f;
};

EnergyBiasTargets targetsFor(EmbodiedEnergyState state) {
  switch (state) {
    case EmbodiedEnergyState::Charging:
      return {-0.08f, 0.02f, 0.04f, 0.01f};
    case EmbodiedEnergyState::Low:
      return {0.34f, -0.05f, -0.01f, -0.03f};
    case EmbodiedEnergyState::Critical:
      return {0.58f, -0.10f, -0.03f, -0.08f};
    case EmbodiedEnergyState::Unknown:
    case EmbodiedEnergyState::Ready:
      break;
  }
  return {};
}
}  // namespace

const char* embodiedEnergyStateName(EmbodiedEnergyState state) {
  switch (state) {
    case EmbodiedEnergyState::Ready:
      return "ready";
    case EmbodiedEnergyState::Charging:
      return "charging";
    case EmbodiedEnergyState::Low:
      return "low";
    case EmbodiedEnergyState::Critical:
      return "critical";
    case EmbodiedEnergyState::Unknown:
      break;
  }
  return "unknown";
}

void EmbodiedEnergy::reset(uint32_t nowMs) {
  telemetry_ = EmbodiedEnergyTelemetry {};
  telemetry_.stateStartedAtMs = nowMs;
}

void EmbodiedEnergy::updateInput(const EmbodiedEnergyInput& input, uint32_t nowMs) {
  telemetry_.inputValid = input.telemetryValid && input.batteryPercentValid &&
                          input.batteryPercent <= 100;
  telemetry_.batteryPercent = telemetry_.inputValid ? input.batteryPercent : -1;
  telemetry_.charging = telemetry_.inputValid && input.charging;
  telemetry_.externalPower = input.telemetryValid && input.externalPower;

  const EmbodiedEnergyState next = classify(input);
  if (next == telemetry_.state) {
    return;
  }

  telemetry_.state = next;
  telemetry_.stateStartedAtMs = nowMs;
  telemetry_.transitions++;
  if (next == EmbodiedEnergyState::Charging) {
    telemetry_.chargingEntries++;
  } else if (next == EmbodiedEnergyState::Low) {
    telemetry_.lowEntries++;
  } else if (next == EmbodiedEnergyState::Critical) {
    telemetry_.criticalEntries++;
  }
}

EmotionalProfile EmbodiedEnergy::shape(const EmotionalProfile& base, float dt) {
  const EnergyBiasTargets targets = targetsFor(telemetry_.state);
  const bool releasing = telemetry_.state == EmbodiedEnergyState::Unknown ||
                         telemetry_.state == EmbodiedEnergyState::Ready;
  const float rate = releasing ? kBiasReleasePerSecond : kBiasAttackPerSecond;
  const float amount = constrain(dt, 0.001f, 0.100f) * rate;
  telemetry_.fatigueBias = approach(telemetry_.fatigueBias, targets.fatigue, amount);
  telemetry_.arousalBias = approach(telemetry_.arousalBias, targets.arousal, amount);
  telemetry_.valenceBias = approach(telemetry_.valenceBias, targets.valence, amount);
  telemetry_.focusBias = approach(telemetry_.focusBias, targets.focus, amount);

  EmotionalProfile shaped = base;
  shaped.fatigue = clamp01(shaped.fatigue + telemetry_.fatigueBias);
  shaped.arousal = clamp01(shaped.arousal + telemetry_.arousalBias);
  shaped.valence = clampSigned(shaped.valence + telemetry_.valenceBias);
  shaped.focus = clamp01(shaped.focus + telemetry_.focusBias);
  return shaped;
}

EmbodiedEnergyState EmbodiedEnergy::classify(const EmbodiedEnergyInput& input) const {
  if (!input.telemetryValid || !input.batteryPercentValid || input.batteryPercent > 100) {
    return EmbodiedEnergyState::Unknown;
  }
  if (input.charging && input.externalPower) {
    return EmbodiedEnergyState::Charging;
  }

  const uint8_t percent = input.batteryPercent;
  if (percent <= kCriticalEnterPercent ||
      (telemetry_.state == EmbodiedEnergyState::Critical &&
       percent < kCriticalRecoverPercent)) {
    return EmbodiedEnergyState::Critical;
  }
  if (percent <= kLowEnterPercent ||
      (telemetry_.state == EmbodiedEnergyState::Low && percent < kLowRecoverPercent)) {
    return EmbodiedEnergyState::Low;
  }
  return EmbodiedEnergyState::Ready;
}

float EmbodiedEnergy::approach(float value, float target, float amount) {
  if (value < target) {
    return min(value + amount, target);
  }
  return max(value - amount, target);
}

float EmbodiedEnergy::clamp01(float value) {
  return constrain(value, 0.0f, 1.0f);
}

float EmbodiedEnergy::clampSigned(float value) {
  return constrain(value, -1.0f, 1.0f);
}

}  // namespace stackchan
