#pragma once

#include <stddef.h>
#include <stdint.h>

namespace stackchan {

constexpr size_t kOtaSha256HexLength = 64;

enum class OtaPreflightResult : uint8_t {
  Ready = 0,
  PowerTelemetryUnavailable,
  ExternalPowerRequired,
  SupplyVoltageLow,
  MotionRequested,
  MotionActive,
  ServoPowerActive,
  AudioActive,
  WakeTurnActive,
  HeapLow,
  CurrentAppUnconfirmed,
};

struct OtaPreflightInput {
  bool powerTelemetryValid = false;
  bool externalPowerPresent = false;
  int32_t vbusMv = -1;
  bool motionRequested = false;
  bool motionEnabled = false;
  bool servoRailEnabled = false;
  bool servoTorqueEnabled = false;
  bool audioActive = false;
  bool wakeTurnActive = false;
  uint32_t freeHeapBytes = 0;
  bool currentAppConfirmed = true;
};

struct OtaPreflightLimits {
  int32_t minimumVbusMv = 4700;
  uint32_t minimumFreeHeapBytes = 65536;
};

OtaPreflightResult evaluateOtaPreflight(
    const OtaPreflightInput& input,
    const OtaPreflightLimits& limits = OtaPreflightLimits {});
const char* otaPreflightResultName(OtaPreflightResult result);

bool isValidSha256Hex(const char* value);
bool decodeSha256Hex(const char* value, uint8_t out[32]);
bool constantTimeEqual(const uint8_t* left, const uint8_t* right, size_t length);

enum class OtaHealthDecision : uint8_t {
  Waiting = 0,
  Confirm,
  Rollback,
};

struct OtaHealthInput {
  bool runtimeReady = false;
  bool displayReady = false;
  bool tasksReady = false;
  bool wifiReady = false;
  bool powerSafe = false;
  bool heapSafe = false;
};

class OtaHealthPolicy {
 public:
  void begin(uint32_t nowMs);
  OtaHealthDecision update(
      const OtaHealthInput& input,
      uint32_t nowMs,
      uint32_t stableWindowMs,
      uint32_t timeoutMs);

  uint32_t startedAtMs() const {
    return startedAtMs_;
  }

  uint32_t healthySinceMs() const {
    return healthySinceMs_;
  }

 private:
  static bool isHealthy(const OtaHealthInput& input);

  uint32_t startedAtMs_ = 0;
  uint32_t healthySinceMs_ = 0;
  bool started_ = false;
  bool healthyWindowStarted_ = false;
};

}  // namespace stackchan
