#pragma once

#include <Arduino.h>
#include <stddef.h>
#include <stdint.h>

namespace stackchan {

constexpr size_t kBridgeEndpointMax = 8;
constexpr size_t kBridgeEndpointIdMax = 32;
constexpr size_t kBridgeEndpointNameMax = 40;
constexpr size_t kBridgeEndpointFingerprintMax = 72;

enum class BridgeEndpointKind : uint8_t {
  Unknown,
  Pc,
  Android,
  Dev,
};

enum BridgeEndpointCapability : uint32_t {
  BridgeEndpointCapabilityNone = 0,
  BridgeEndpointCapabilityStt = 1u << 0,
  BridgeEndpointCapabilityLlm = 1u << 1,
  BridgeEndpointCapabilityTts = 1u << 2,
  BridgeEndpointCapabilityRvc = 1u << 3,
  BridgeEndpointCapabilitySettings = 1u << 4,
  BridgeEndpointCapabilityAudioDownlink = 1u << 5,
  BridgeEndpointCapabilityPersonaSelect = 1u << 6,
  BridgeEndpointCapabilityModelProfiles = 1u << 7,
  BridgeEndpointCapabilityDiagnostics = 1u << 8,
  BridgeEndpointCapabilityWakeGate = 1u << 9,
  BridgeEndpointCapabilityPcm16Upload = 1u << 10,
};

struct BridgeEndpointRecord {
  char endpointId[kBridgeEndpointIdMax] = {};
  char endpointName[kBridgeEndpointNameMax] = {};
  char publicKeyFingerprint[kBridgeEndpointFingerprintMax] = {};
  BridgeEndpointKind kind = BridgeEndpointKind::Unknown;
  uint8_t priority = 0;
  bool trusted = false;
  bool autoConnect = true;
  uint32_t capabilities = BridgeEndpointCapabilityNone;
  uint32_t lastSeenMs = 0;
  uint32_t lastHeartbeatMs = 0;
};

struct BridgeEndpointRegistryConfig {
  // Owner heartbeat timeout: releases a stale brain owner and lets another healthy endpoint take over.
  uint32_t ownerHeartbeatTimeoutMs = 7000;
};

struct BridgeEndpointRegistryTelemetry {
  bool ready = false;
  uint8_t trustedCount = 0;
  int8_t activeOwnerIndex = -1;
  uint32_t ownerChanges = 0;
  uint32_t ownerExpirations = 0;
  uint32_t explicitClaims = 0;
  uint32_t releases = 0;
  uint32_t forgotten = 0;
  uint32_t rejected = 0;
  uint32_t upserts = 0;
  uint32_t heartbeats = 0;
  uint32_t lastChangeMs = 0;
};

class BridgeEndpointRegistry {
 public:
  bool begin(const BridgeEndpointRegistryConfig& config = BridgeEndpointRegistryConfig {});

  bool upsertEndpoint(const BridgeEndpointRecord& endpoint, uint32_t nowMs);
  bool forgetEndpoint(const char* endpointId, uint32_t nowMs);
  bool markHeartbeat(const char* endpointId, uint32_t nowMs);
  bool markDisconnected(const char* endpointId, uint32_t nowMs);
  bool claimOwner(const char* endpointId, uint32_t nowMs, bool explicitSelection = true);
  bool releaseOwner(const char* endpointId, uint32_t nowMs);
  bool updateCapabilities(const char* endpointId, uint32_t capabilities, uint32_t nowMs);
  void update(uint32_t nowMs);

  size_t count() const {
    return count_;
  }

  const BridgeEndpointRecord* endpointAt(size_t index) const;
  const BridgeEndpointRecord* findEndpoint(const char* endpointId) const;
  const BridgeEndpointRecord* activeOwner() const;
  bool isActiveOwner(const char* endpointId) const;
  bool isTrusted(const char* endpointId) const;

  const BridgeEndpointRegistryTelemetry& telemetry() const {
    return telemetry_;
  }

 private:
  static bool isValidId(const char* endpointId);
  static bool idsEqual(const char* left, const char* right);
  static void copyBounded(char* out, size_t outSize, const char* value);
  bool isHealthy(const BridgeEndpointRecord& endpoint, uint32_t nowMs) const;
  int findIndex(const char* endpointId) const;
  int chooseBestHealthyOwner(uint32_t nowMs) const;
  void setOwnerIndex(int index, uint32_t nowMs);
  void releaseOwnerIndex(uint32_t nowMs);
  void refreshTelemetry();

  BridgeEndpointRegistryConfig config_;
  BridgeEndpointRegistryTelemetry telemetry_;
  BridgeEndpointRecord endpoints_[kBridgeEndpointMax] = {};
  size_t count_ = 0;
  int activeOwnerIndex_ = -1;
};

}  // namespace stackchan
