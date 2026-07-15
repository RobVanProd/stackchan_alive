#pragma once

#include <Arduino.h>
#include <ArduinoJson.h>
#include <stddef.h>
#include <stdint.h>

#include "io/BridgeEndpointRegistry.hpp"
#include "io/BridgeEndpointStore.hpp"

namespace stackchan {

constexpr size_t kBridgeEndpointControlResponseMax = 1536;

enum class BridgeEndpointControlResult : uint8_t {
  Ignored,
  Handled,
  Rejected,
};

struct BridgeEndpointControlConfig {
  const char* requiredPairingCode = nullptr;
};

struct BridgeEndpointControlTelemetry {
  bool ready = false;
  uint32_t handledMessages = 0;
  uint32_t ignoredMessages = 0;
  uint32_t rejectedMessages = 0;
  uint32_t endpointHellos = 0;
  uint32_t heartbeats = 0;
  uint32_t ownerClaims = 0;
  uint32_t ownerReleases = 0;
  uint32_t ownerStatusRequests = 0;
  uint32_t trustedEndpointRequests = 0;
  uint32_t capabilityUpdates = 0;
  uint32_t wifiProfileUseRequests = 0;
  uint32_t wifiProfileUseAccepted = 0;
  uint32_t forgotten = 0;
  uint32_t pairingRejects = 0;
  uint32_t persistenceSaves = 0;
  uint32_t persistenceErrors = 0;
  uint32_t responsesDropped = 0;
  uint32_t lastHandledMs = 0;
};

enum class BridgeEndpointWiFiProfileUseResult : uint8_t {
  Accepted,
  ProfileNotConfigured,
  PersistenceFailed,
};

using BridgeEndpointWiFiProfileUseHandler = BridgeEndpointWiFiProfileUseResult (*)(
    const char* profile,
    uint32_t nowMs,
    void* context);

class BridgeEndpointControl {
 public:
  bool begin(BridgeEndpointRegistry& registry,
             const BridgeEndpointControlConfig& config = BridgeEndpointControlConfig {});
  void attachStore(BridgeEndpointStore* store);
  void attachWiFiProfileUseHandler(BridgeEndpointWiFiProfileUseHandler handler,
                                   void* context = nullptr);
  void update(uint32_t nowMs);
  bool setRequiredPairingCode(const char* value);
  void clearRequiredPairingCode();
  bool pairingCodeRequired() const {
    return requiredPairingCode_[0] != '\0';
  }
  const char* requiredPairingCode() const {
    return requiredPairingCode_;
  }
  bool authorizesPairedRequest(const char* value) const {
    return pairingCodeRequired() && pairingCodeMatches(value);
  }

  BridgeEndpointControlResult submitControlLine(const char* jsonLine,
                                                char* responseOut,
                                                size_t responseOutSize,
                                                uint32_t nowMs);

  const BridgeEndpointControlTelemetry& telemetry() const {
    return telemetry_;
  }

 private:
  BridgeEndpointControlResult handleEndpointHello(const JsonObjectConst& root,
                                                  char* responseOut,
                                                  size_t responseOutSize,
                                                  uint32_t nowMs);
  BridgeEndpointControlResult handleHeartbeat(const JsonObjectConst& root,
                                              char* responseOut,
                                              size_t responseOutSize,
                                              uint32_t nowMs);
  BridgeEndpointControlResult handleClaimBrain(const JsonObjectConst& root,
                                               char* responseOut,
                                               size_t responseOutSize,
                                               uint32_t nowMs);
  BridgeEndpointControlResult handleReleaseBrain(const JsonObjectConst& root,
                                                 char* responseOut,
                                                 size_t responseOutSize,
                                                 uint32_t nowMs);
  BridgeEndpointControlResult handleOwnerStatus(char* responseOut,
                                                size_t responseOutSize,
                                                const char* state);
  BridgeEndpointControlResult handleTrustedEndpoints(char* responseOut, size_t responseOutSize);
  BridgeEndpointControlResult handleForgetEndpoint(const JsonObjectConst& root,
                                                   char* responseOut,
                                                   size_t responseOutSize,
                                                   uint32_t nowMs);
  BridgeEndpointControlResult handleCapabilityUpdate(const JsonObjectConst& root,
                                                     char* responseOut,
                                                     size_t responseOutSize,
                                                     uint32_t nowMs);
  BridgeEndpointControlResult handleWiFiProfileUse(const JsonObjectConst& root,
                                                   char* responseOut,
                                                   size_t responseOutSize,
                                                   uint32_t nowMs);

  BridgeEndpointControlResult writeEndpointHelloResult(const BridgeEndpointRecord& endpoint,
                                                       char* responseOut,
                                                       size_t responseOutSize);
  BridgeEndpointControlResult writeHeartbeatResult(const char* endpointId,
                                                   char* responseOut,
                                                   size_t responseOutSize);
  BridgeEndpointControlResult writeOwnerStatus(const char* state,
                                               char* responseOut,
                                               size_t responseOutSize);
  BridgeEndpointControlResult writeTrustedEndpoints(char* responseOut, size_t responseOutSize);
  BridgeEndpointControlResult writeForgetResult(const char* endpointId,
                                                bool ok,
                                                char* responseOut,
                                                size_t responseOutSize);
  BridgeEndpointControlResult writeCapabilityResult(const BridgeEndpointRecord& endpoint,
                                                    char* responseOut,
                                                    size_t responseOutSize);
  BridgeEndpointControlResult writeWiFiProfileUseResult(const char* endpointId,
                                                        const char* profile,
                                                        char* responseOut,
                                                        size_t responseOutSize);
  BridgeEndpointControlResult writeError(const char* code,
                                         const char* endpointId,
                                         char* responseOut,
                                         size_t responseOutSize);

  static BridgeEndpointKind endpointKindFromString(const char* value);
  static const char* endpointKindToString(BridgeEndpointKind kind);
  static uint32_t capabilitiesFromJson(const JsonVariantConst& value);
  static void writeCapabilities(uint32_t capabilities, JsonArray& out);
  static bool hasProtocolMismatch(const JsonObjectConst& root);
  static bool writeJsonResponse(const JsonDocument& doc,
                                char* responseOut,
                                size_t responseOutSize);
  static void copyBounded(char* out, size_t outSize, const char* value);
  static bool normalizePairingCode(const char* value, char* out, size_t outSize);
  bool pairingCodeMatches(const char* value) const;
  bool persistRegistry(uint32_t nowMs);

  BridgeEndpointRegistry* registry_ = nullptr;
  BridgeEndpointStore* store_ = nullptr;
  BridgeEndpointWiFiProfileUseHandler wifiProfileUseHandler_ = nullptr;
  void* wifiProfileUseContext_ = nullptr;
  BridgeEndpointControlTelemetry telemetry_;
  char requiredPairingCode_[7] = {};
};

}  // namespace stackchan
