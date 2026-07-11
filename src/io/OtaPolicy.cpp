#include "io/OtaPolicy.hpp"

#include <cstring>

namespace stackchan {

namespace {
int hexNibble(char value) {
  if (value >= '0' && value <= '9') {
    return value - '0';
  }
  if (value >= 'a' && value <= 'f') {
    return value - 'a' + 10;
  }
  if (value >= 'A' && value <= 'F') {
    return value - 'A' + 10;
  }
  return -1;
}
}  // namespace

OtaPreflightResult evaluateOtaPreflight(
    const OtaPreflightInput& input,
    const OtaPreflightLimits& limits) {
  if (!input.currentAppConfirmed) {
    return OtaPreflightResult::CurrentAppUnconfirmed;
  }
  if (!input.powerTelemetryValid) {
    return OtaPreflightResult::PowerTelemetryUnavailable;
  }
  if (!input.externalPowerPresent) {
    return OtaPreflightResult::ExternalPowerRequired;
  }
  if (input.vbusMv < limits.minimumVbusMv) {
    return OtaPreflightResult::SupplyVoltageLow;
  }
  if (input.motionRequested) {
    return OtaPreflightResult::MotionRequested;
  }
  if (input.motionEnabled) {
    return OtaPreflightResult::MotionActive;
  }
  if (input.servoRailEnabled || input.servoTorqueEnabled) {
    return OtaPreflightResult::ServoPowerActive;
  }
  if (input.audioActive) {
    return OtaPreflightResult::AudioActive;
  }
  if (input.wakeTurnActive) {
    return OtaPreflightResult::WakeTurnActive;
  }
  if (input.freeHeapBytes < limits.minimumFreeHeapBytes) {
    return OtaPreflightResult::HeapLow;
  }
  return OtaPreflightResult::Ready;
}

const char* otaPreflightResultName(OtaPreflightResult result) {
  switch (result) {
    case OtaPreflightResult::Ready:
      return "ready";
    case OtaPreflightResult::PowerTelemetryUnavailable:
      return "power_telemetry_unavailable";
    case OtaPreflightResult::ExternalPowerRequired:
      return "external_power_required";
    case OtaPreflightResult::SupplyVoltageLow:
      return "supply_voltage_low";
    case OtaPreflightResult::MotionRequested:
      return "motion_requested";
    case OtaPreflightResult::MotionActive:
      return "motion_active";
    case OtaPreflightResult::ServoPowerActive:
      return "servo_power_active";
    case OtaPreflightResult::AudioActive:
      return "audio_active";
    case OtaPreflightResult::WakeTurnActive:
      return "wake_turn_active";
    case OtaPreflightResult::HeapLow:
      return "heap_low";
    case OtaPreflightResult::CurrentAppUnconfirmed:
      return "current_app_unconfirmed";
  }
  return "unknown";
}

bool isValidSha256Hex(const char* value) {
  if (value == nullptr || std::strlen(value) != kOtaSha256HexLength) {
    return false;
  }
  for (size_t i = 0; i < kOtaSha256HexLength; ++i) {
    if (hexNibble(value[i]) < 0) {
      return false;
    }
  }
  return true;
}

bool decodeSha256Hex(const char* value, uint8_t out[32]) {
  if (!isValidSha256Hex(value) || out == nullptr) {
    return false;
  }
  for (size_t i = 0; i < 32; ++i) {
    const int high = hexNibble(value[i * 2]);
    const int low = hexNibble(value[i * 2 + 1]);
    out[i] = static_cast<uint8_t>((high << 4) | low);
  }
  return true;
}

bool constantTimeEqual(const uint8_t* left, const uint8_t* right, size_t length) {
  if (left == nullptr || right == nullptr) {
    return false;
  }
  uint8_t difference = 0;
  for (size_t i = 0; i < length; ++i) {
    difference |= static_cast<uint8_t>(left[i] ^ right[i]);
  }
  return difference == 0;
}

uint32_t otaHealthFailureMask(const OtaHealthInput& input) {
  uint32_t mask = OtaHealthFailureNone;
  if (!input.runtimeReady) {
    mask |= OtaHealthFailureRuntime;
  }
  if (!input.displayReady) {
    mask |= OtaHealthFailureDisplay;
  }
  if (!input.tasksReady) {
    mask |= OtaHealthFailureTasks;
  }
  if (!input.wifiReady) {
    mask |= OtaHealthFailureWifi;
  }
  if (!input.powerSafe) {
    mask |= OtaHealthFailurePower;
  }
  if (!input.heapSafe) {
    mask |= OtaHealthFailureHeap;
  }
  return mask;
}

void OtaHealthPolicy::begin(uint32_t nowMs) {
  startedAtMs_ = nowMs;
  healthySinceMs_ = 0;
  started_ = true;
  healthyWindowStarted_ = false;
}

OtaHealthDecision OtaHealthPolicy::update(
    const OtaHealthInput& input,
    uint32_t nowMs,
    uint32_t stableWindowMs,
    uint32_t timeoutMs) {
  if (!started_) {
    begin(nowMs);
  }
  if (timeoutMs > 0 && nowMs - startedAtMs_ >= timeoutMs) {
    return OtaHealthDecision::Rollback;
  }
  if (otaHealthFailureMask(input) != OtaHealthFailureNone) {
    healthySinceMs_ = 0;
    healthyWindowStarted_ = false;
    return OtaHealthDecision::Waiting;
  }
  if (!healthyWindowStarted_) {
    healthySinceMs_ = nowMs;
    healthyWindowStarted_ = true;
  }
  if (nowMs - healthySinceMs_ >= stableWindowMs) {
    return OtaHealthDecision::Confirm;
  }
  return OtaHealthDecision::Waiting;
}

}  // namespace stackchan
