#pragma once

#include <stdint.h>

#include "io/BridgeAudioUplink.hpp"
#include "persona/EventBus.hpp"

namespace stackchan {

#ifndef STACKCHAN_BRIDGE_WAKE_ON_SPEECH
#define STACKCHAN_BRIDGE_WAKE_ON_SPEECH 0
#endif

constexpr uint32_t kBridgeWakeGateOpenMs = 6000;
constexpr uint32_t kBridgeWakeGateMaxTurnMs = 12000;
constexpr size_t kBridgeWakeGateErrorMax = kBridgeErrorMax;

struct BridgeWakeGateConfig {
  bool enabled = true;
  bool speechStartsTurn = STACKCHAN_BRIDGE_WAKE_ON_SPEECH != 0;
  uint32_t gateOpenMs = kBridgeWakeGateOpenMs;    // Wake gate hold: lets speech start after wake.
  uint32_t maxTurnMs = kBridgeWakeGateMaxTurnMs;  // Privacy guard: never stream forever.
  uint32_t firstSeq = 1;
};

struct BridgeWakeGateTelemetry {
  bool ready = false;
  bool enabled = false;
  bool speechStartsTurn = false;
  bool gateOpen = false;
  bool turnActive = false;
  uint32_t gatesOpened = 0;
  uint32_t gatesExpired = 0;
  uint32_t turnsStarted = 0;
  uint32_t turnsCompleted = 0;
  uint32_t turnsAborted = 0;
  uint32_t beginFailures = 0;
  uint32_t endFailures = 0;
  uint32_t suppressedStarts = 0;
  uint32_t lastSeq = 0;
  uint32_t openedAtMs = 0;
  uint32_t closeAtMs = 0;
  uint32_t turnStartedAtMs = 0;
  char lastError[kBridgeWakeGateErrorMax] = {};
};

class BridgeWakeGate {
 public:
  bool begin(const BridgeWakeGateConfig& config = BridgeWakeGateConfig {},
             BridgeAudioUplink* uplink = nullptr);
  void reset();

  void applyEvent(const RobotEvent& event, uint32_t nowMs);
  void update(uint32_t nowMs);
  bool isGateOpen(uint32_t nowMs) const;

  const BridgeWakeGateTelemetry& telemetry() const {
    return telemetry_;
  }

 private:
  void openGate(uint32_t nowMs);
  void renewGate(uint32_t nowMs);
  void expireGate(uint32_t nowMs);
  void startTurnIfPossible(uint32_t nowMs);
  void completeTurn(uint32_t nowMs, const char* reason);
  bool uplinkReadyForTurn() const;
  void copyError(const char* reason);

  BridgeWakeGateConfig config_;
  BridgeWakeGateTelemetry telemetry_;
  BridgeAudioUplink* uplink_ = nullptr;
  uint32_t nextSeq_ = 1;
};

}  // namespace stackchan
