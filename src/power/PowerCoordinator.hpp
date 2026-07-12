#pragma once

#include <stdint.h>

namespace stackchan {

enum class PowerOperatingMode : uint8_t {
  Boot = 0,
  Idle,
  AudioPriority,
  Motion,
  Protected,
};

struct PowerCoordinatorInput {
  bool motionRequested = false;
  bool audioBusy = false;
  bool thermalBlocked = false;
  bool supplyBlocked = false;
};

struct MotionAudioActivity {
  bool microphoneCaptureActive = false;
  bool wakeTurnActive = false;
  bool bridgeConversationBusy = false;
  bool pendingBridgeOutput = false;
  bool downlinkActive = false;
  bool downlinkPlaybackActive = false;
  bool bridgeAudioStreamActive = false;
  bool audioOutputPlaybackActive = false;
  bool speakerPowerActive = false;
  bool speakerRunning = false;
};

class MotionAudioPreemptionGate {
 public:
  void reset();
  bool update(const MotionAudioActivity& activity, uint32_t nowMs, uint32_t cooldownMs);

  bool audioLoadActive() const {
    return audioLoadActive_;
  }

  bool cooldownTailActive() const {
    return cooldownTailActive_;
  }

  uint32_t microphoneCooldownClears() const {
    return microphoneCooldownClears_;
  }

 private:
  bool audioLoadActive_ = false;
  bool preemptActive_ = false;
  bool cooldownTailActive_ = false;
  bool hasRecentAudioLoad_ = false;
  uint32_t lastAudioLoadMs_ = 0;
  uint32_t microphoneCooldownClears_ = 0;
};

struct PowerCoordinatorDecision {
  PowerOperatingMode mode = PowerOperatingMode::Boot;
  bool motionAllowed = false;
  bool servoRailAllowed = false;
  bool wifiSleepAllowed = false;
  uint16_t chargeCurrentMa = 0;
  bool chargeDerated = false;
  bool chargeDerateHoldActive = false;
  uint32_t chargeDerateHoldRemainingMs = 0;
  const char* chargeDerateReason = "none";
  const char* reason = "boot";
};

struct PowerCoordinatorTelemetry {
  PowerOperatingMode mode = PowerOperatingMode::Boot;
  bool baseInputMode = false;
  uint16_t chargeCurrentMa = 0;
  uint16_t maxChargeCurrentMa = 0;
  uint16_t deratedChargeCurrentMa = 0;
  bool chargeDerated = false;
  bool chargeDerateHoldActive = false;
  uint32_t chargeDerateHoldMs = 0;
  uint32_t chargeDerateHoldRemainingMs = 0;
  uint32_t chargeDerateLastLoadMs = 0;
  const char* chargeDerateReason = "none";
  bool motionRequested = false;
  bool motionAllowed = false;
  bool servoRailAllowed = false;
  bool wifiSleepAllowed = false;
  uint32_t transitions = 0;
  uint32_t chargeDerateEntries = 0;
  uint32_t motionGrantEntries = 0;
  uint32_t motionBlockEntries = 0;
  uint32_t lastTransitionMs = 0;
  const char* reason = "not_started";
};

struct PowerFloorSample {
  bool vbusValid = false;
  int16_t vbusMv = -1;
  bool confirmVbusValid = false;
  int16_t confirmVbusMv = -1;
  bool batteryValid = false;
  int16_t batteryMv = -1;
  bool confirmBatteryValid = false;
  int16_t confirmBatteryMv = -1;
  bool bodyPowerValid = false;
  float bodyBusV = 0.0f;
  float bodyCurrentMa = 0.0f;
  bool motionRequested = false;
  bool servoRailEnabled = false;
  bool servoTorqueEnabled = false;
  bool speakerPowerActive = false;
};

struct PowerFloorTelemetry {
  uint16_t hardFloorMv = 0;
  uint32_t validSamples = 0;
  int16_t minVbusMv = -1;
  uint32_t hardFloorSamples = 0;
  uint32_t hardFloorConfirmedSamples = 0;
  uint32_t hardFloorUnconfirmedSamples = 0;
  uint32_t hardFloorEntries = 0;
  uint32_t consecutiveHardFloorSamples = 0;
  uint32_t maxConsecutiveHardFloorSamples = 0;
  uint32_t lastHardFloorAtMs = 0;
  int16_t lastHardFloorVbusMv = -1;
  int16_t lastHardFloorConfirmVbusMv = -1;
  int16_t lastHardFloorBatteryMv = -1;
  int16_t lastHardFloorConfirmBatteryMv = -1;
  bool lastHardFloorBodyPowerValid = false;
  float lastHardFloorBodyBusV = 0.0f;
  float lastHardFloorBodyCurrentMa = 0.0f;
  bool lastHardFloorMotionRequested = false;
  bool lastHardFloorServoRailEnabled = false;
  bool lastHardFloorServoTorqueEnabled = false;
  bool lastHardFloorSpeakerPowerActive = false;
};

class PowerFloorTracker {
 public:
  void begin(uint16_t hardFloorMv);
  bool update(const PowerFloorSample& sample, uint32_t nowMs);

  PowerFloorTelemetry telemetry() const {
    return telemetry_;
  }

 private:
  PowerFloorTelemetry telemetry_;
};

class PowerCoordinator {
 public:
  void begin(bool baseInputMode,
             uint16_t maxChargeCurrentMa,
             uint32_t nowMs = 0,
             uint16_t deratedChargeCurrentMa = 0,
             uint32_t chargeDerateHoldMs = 30000);
  PowerCoordinatorDecision update(const PowerCoordinatorInput& input, uint32_t nowMs);

  PowerCoordinatorDecision decision() const {
    return decision_;
  }

  PowerCoordinatorTelemetry telemetry() const;

 private:
  void applyDecision(const PowerCoordinatorDecision& next, bool motionRequested, uint32_t nowMs);

  PowerCoordinatorDecision decision_;
  bool begun_ = false;
  bool baseInputMode_ = false;
  uint16_t maxChargeCurrentMa_ = 0;
  uint16_t deratedChargeCurrentMa_ = 0;
  uint32_t chargeDerateHoldMs_ = 30000;
  uint32_t chargeDerateLastLoadMs_ = 0;
  bool chargeDerateHoldActive_ = false;
  bool motionRequested_ = false;
  uint32_t transitions_ = 0;
  uint32_t chargeDerateEntries_ = 0;
  uint32_t motionGrantEntries_ = 0;
  uint32_t motionBlockEntries_ = 0;
  uint32_t lastTransitionMs_ = 0;
};

const char* powerOperatingModeName(PowerOperatingMode mode);
bool shouldPreemptMotionForAudio(const MotionAudioActivity& activity);

}  // namespace stackchan
