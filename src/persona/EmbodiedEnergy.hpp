#pragma once

#include "persona/StateMatrix.hpp"

namespace stackchan {

enum class EmbodiedEnergyState : uint8_t {
  Unknown,
  Ready,
  Charging,
  Low,
  Critical,
};

const char* embodiedEnergyStateName(EmbodiedEnergyState state);

struct EmbodiedEnergyInput {
  bool telemetryValid = false;
  bool batteryPercentValid = false;
  uint8_t batteryPercent = 0;
  bool charging = false;
  bool externalPower = false;
};

struct EmbodiedEnergyTelemetry {
  EmbodiedEnergyState state = EmbodiedEnergyState::Unknown;
  uint32_t stateStartedAtMs = 0;
  uint32_t transitions = 0;
  uint32_t chargingEntries = 0;
  uint32_t lowEntries = 0;
  uint32_t criticalEntries = 0;
  int16_t batteryPercent = -1;
  bool inputValid = false;
  bool charging = false;
  bool externalPower = false;
  float fatigueBias = 0.0f;
  float arousalBias = 0.0f;
  float valenceBias = 0.0f;
  float focusBias = 0.0f;
};

class EmbodiedEnergy {
 public:
  void reset(uint32_t nowMs = 0);
  void updateInput(const EmbodiedEnergyInput& input, uint32_t nowMs);
  EmotionalProfile shape(const EmotionalProfile& base, float dt);

  const EmbodiedEnergyTelemetry& telemetry() const {
    return telemetry_;
  }

 private:
  EmbodiedEnergyTelemetry telemetry_;

  EmbodiedEnergyState classify(const EmbodiedEnergyInput& input) const;
  static float approach(float value, float target, float amount);
  static float clamp01(float value);
  static float clampSigned(float value);
};

}  // namespace stackchan
