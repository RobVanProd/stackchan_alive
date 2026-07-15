#include "io/BridgeEndpointControl.hpp"

#include <cstdio>
#include <cstring>

namespace stackchan {

namespace {
constexpr const char* kBridgeProtocol = "stackchan.bridge.v1";

bool isEmpty(const char* value) {
  return value == nullptr || value[0] == '\0';
}

bool equals(const char* left, const char* right) {
  return left != nullptr && right != nullptr && std::strcmp(left, right) == 0;
}

bool isBase36(char value) {
  return (value >= '0' && value <= '9') || (value >= 'A' && value <= 'Z') ||
         (value >= 'a' && value <= 'z');
}

char uppercaseAscii(char value) {
  return value >= 'a' && value <= 'z' ? static_cast<char>(value - 'a' + 'A') : value;
}

uint8_t clampPriority(uint32_t value) {
  return value > 255u ? 255u : static_cast<uint8_t>(value);
}
}

bool BridgeEndpointControl::begin(BridgeEndpointRegistry& registry,
                                  const BridgeEndpointControlConfig& config) {
  registry_ = &registry;
  store_ = nullptr;
  wifiProfileUseHandler_ = nullptr;
  wifiProfileUseContext_ = nullptr;
  telemetry_ = BridgeEndpointControlTelemetry {};
  requiredPairingCode_[0] = '\0';
  if (!isEmpty(config.requiredPairingCode) && !setRequiredPairingCode(config.requiredPairingCode)) {
    telemetry_.ready = false;
    return false;
  }
  telemetry_.ready = registry_->telemetry().ready;
  return telemetry_.ready;
}

void BridgeEndpointControl::attachStore(BridgeEndpointStore* store) {
  store_ = store;
}

void BridgeEndpointControl::attachWiFiProfileUseHandler(
    BridgeEndpointWiFiProfileUseHandler handler,
    void* context) {
  wifiProfileUseHandler_ = handler;
  wifiProfileUseContext_ = context;
}

void BridgeEndpointControl::update(uint32_t nowMs) {
  if (registry_ == nullptr || !telemetry_.ready) {
    return;
  }
  registry_->update(nowMs);
}

bool BridgeEndpointControl::setRequiredPairingCode(const char* value) {
  char normalized[sizeof(requiredPairingCode_)] = {};
  if (!normalizePairingCode(value, normalized, sizeof(normalized))) {
    return false;
  }
  std::memcpy(requiredPairingCode_, normalized, sizeof(requiredPairingCode_));
  return true;
}

void BridgeEndpointControl::clearRequiredPairingCode() {
  requiredPairingCode_[0] = '\0';
}

BridgeEndpointControlResult BridgeEndpointControl::submitControlLine(const char* jsonLine,
                                                                      char* responseOut,
                                                                      size_t responseOutSize,
                                                                      uint32_t nowMs) {
  if (responseOut != nullptr && responseOutSize > 0) {
    responseOut[0] = '\0';
  }
  if (registry_ == nullptr || !telemetry_.ready || jsonLine == nullptr || jsonLine[0] == '\0') {
    telemetry_.rejectedMessages++;
    return BridgeEndpointControlResult::Rejected;
  }

  JsonDocument request;
  const DeserializationError error = deserializeJson(request, jsonLine);
  if (error) {
    telemetry_.rejectedMessages++;
    telemetry_.lastHandledMs = nowMs;
    return writeError("malformed_json", nullptr, responseOut, responseOutSize);
  }

  const JsonObjectConst root = request.as<JsonObjectConst>();
  if (root.isNull()) {
    telemetry_.rejectedMessages++;
    telemetry_.lastHandledMs = nowMs;
    return writeError("message_not_object", nullptr, responseOut, responseOutSize);
  }

  const char* type = root["type"] | "";
  BridgeEndpointControlResult result = BridgeEndpointControlResult::Ignored;
  if (equals(type, "endpoint_hello")) {
    result = handleEndpointHello(root, responseOut, responseOutSize, nowMs);
  } else if (equals(type, "heartbeat")) {
    const char* endpointId = root["endpoint_id"] | "";
    result = isEmpty(endpointId) ? BridgeEndpointControlResult::Ignored
                                 : handleHeartbeat(root, responseOut, responseOutSize, nowMs);
  } else if (equals(type, "claim_brain")) {
    result = handleClaimBrain(root, responseOut, responseOutSize, nowMs);
  } else if (equals(type, "release_brain")) {
    result = handleReleaseBrain(root, responseOut, responseOutSize, nowMs);
  } else if (equals(type, "owner_status")) {
    result = handleOwnerStatus(responseOut, responseOutSize, "healthy");
  } else if (equals(type, "trusted_endpoints")) {
    result = handleTrustedEndpoints(responseOut, responseOutSize);
  } else if (equals(type, "forget_endpoint")) {
    result = handleForgetEndpoint(root, responseOut, responseOutSize, nowMs);
  } else if (equals(type, "capability_update")) {
    result = handleCapabilityUpdate(root, responseOut, responseOutSize, nowMs);
  } else if (equals(type, "wifi_profile_use")) {
    result = handleWiFiProfileUse(root, responseOut, responseOutSize, nowMs);
  }

  if (result == BridgeEndpointControlResult::Ignored) {
    telemetry_.ignoredMessages++;
    return result;
  }

  telemetry_.lastHandledMs = nowMs;
  if (result == BridgeEndpointControlResult::Handled) {
    telemetry_.handledMessages++;
  } else {
    telemetry_.rejectedMessages++;
  }
  return result;
}

BridgeEndpointControlResult BridgeEndpointControl::handleEndpointHello(const JsonObjectConst& root,
                                                                       char* responseOut,
                                                                       size_t responseOutSize,
                                                                       uint32_t nowMs) {
  if (hasProtocolMismatch(root)) {
    return writeError("protocol_mismatch", nullptr, responseOut, responseOutSize);
  }

  BridgeEndpointRecord endpoint;
  copyBounded(endpoint.endpointId, sizeof(endpoint.endpointId), root["endpoint_id"] | "");
  if (isEmpty(endpoint.endpointId)) {
    return writeError("endpoint_id_required", nullptr, responseOut, responseOutSize);
  }
  if (!pairingCodeMatches(root["pairing_code"] | "")) {
    telemetry_.pairingRejects++;
    return writeError("pairing_code_mismatch", endpoint.endpointId, responseOut, responseOutSize);
  }
  copyBounded(endpoint.endpointName, sizeof(endpoint.endpointName), root["endpoint_name"] | "");
  copyBounded(endpoint.publicKeyFingerprint,
              sizeof(endpoint.publicKeyFingerprint),
              root["public_key_fingerprint"] | "");
  endpoint.kind = endpointKindFromString(root["endpoint_kind"] | "");
  endpoint.priority = clampPriority(root["priority"] | 0u);
  endpoint.autoConnect = root["auto_connect"] | true;
  endpoint.capabilities = capabilitiesFromJson(root["capabilities"]);
  if (root["supports_binary_audio"] | false) {
    endpoint.capabilities |= BridgeEndpointCapabilityAudioDownlink;
  }

  if (!registry_->upsertEndpoint(endpoint, nowMs)) {
    return writeError("endpoint_registry_full", endpoint.endpointId, responseOut, responseOutSize);
  }
  registry_->update(nowMs);
  telemetry_.endpointHellos++;
  if (!persistRegistry(nowMs)) {
    return writeError("endpoint_persist_failed", endpoint.endpointId, responseOut, responseOutSize);
  }
  const BridgeEndpointRecord* stored = registry_->findEndpoint(endpoint.endpointId);
  return stored == nullptr ? writeError("endpoint_not_trusted", endpoint.endpointId, responseOut, responseOutSize)
                           : writeEndpointHelloResult(*stored, responseOut, responseOutSize);
}

BridgeEndpointControlResult BridgeEndpointControl::handleHeartbeat(const JsonObjectConst& root,
                                                                   char* responseOut,
                                                                   size_t responseOutSize,
                                                                   uint32_t nowMs) {
  const char* endpointId = root["endpoint_id"] | "";
  if (isEmpty(endpointId)) {
    return BridgeEndpointControlResult::Ignored;
  }
  if (!registry_->markHeartbeat(endpointId, nowMs)) {
    return writeError("endpoint_not_trusted", endpointId, responseOut, responseOutSize);
  }
  registry_->update(nowMs);
  telemetry_.heartbeats++;
  return writeHeartbeatResult(endpointId, responseOut, responseOutSize);
}

BridgeEndpointControlResult BridgeEndpointControl::handleClaimBrain(const JsonObjectConst& root,
                                                                    char* responseOut,
                                                                    size_t responseOutSize,
                                                                    uint32_t nowMs) {
  const char* endpointId = root["endpoint_id"] | "";
  if (isEmpty(endpointId)) {
    return writeError("endpoint_id_required", nullptr, responseOut, responseOutSize);
  }
  if (registry_->findEndpoint(endpointId) == nullptr) {
    return writeError("endpoint_not_trusted", endpointId, responseOut, responseOutSize);
  }
  if (!registry_->claimOwner(endpointId, nowMs, true)) {
    return writeError("claim_rejected", endpointId, responseOut, responseOutSize);
  }
  telemetry_.ownerClaims++;
  return writeOwnerStatus("healthy", responseOut, responseOutSize);
}

BridgeEndpointControlResult BridgeEndpointControl::handleReleaseBrain(const JsonObjectConst& root,
                                                                      char* responseOut,
                                                                      size_t responseOutSize,
                                                                      uint32_t nowMs) {
  const char* endpointId = root["endpoint_id"] | "";
  if (isEmpty(endpointId)) {
    return writeError("endpoint_id_required", nullptr, responseOut, responseOutSize);
  }
  if (registry_->findEndpoint(endpointId) == nullptr) {
    return writeError("endpoint_not_trusted", endpointId, responseOut, responseOutSize);
  }
  if (!registry_->isActiveOwner(endpointId)) {
    return writeError("brain_owner_mismatch", endpointId, responseOut, responseOutSize);
  }
  if (!registry_->releaseOwner(endpointId, nowMs)) {
    return writeError("release_rejected", endpointId, responseOut, responseOutSize);
  }
  telemetry_.ownerReleases++;
  return writeOwnerStatus(registry_->activeOwner() == nullptr ? "released" : "healthy",
                          responseOut,
                          responseOutSize);
}

BridgeEndpointControlResult BridgeEndpointControl::handleOwnerStatus(char* responseOut,
                                                                     size_t responseOutSize,
                                                                     const char* state) {
  telemetry_.ownerStatusRequests++;
  return writeOwnerStatus(state, responseOut, responseOutSize);
}

BridgeEndpointControlResult BridgeEndpointControl::handleTrustedEndpoints(char* responseOut,
                                                                         size_t responseOutSize) {
  telemetry_.trustedEndpointRequests++;
  return writeTrustedEndpoints(responseOut, responseOutSize);
}

BridgeEndpointControlResult BridgeEndpointControl::handleForgetEndpoint(const JsonObjectConst& root,
                                                                       char* responseOut,
                                                                       size_t responseOutSize,
                                                                       uint32_t nowMs) {
  const char* endpointId = root["endpoint_id"] | "";
  if (isEmpty(endpointId)) {
    return writeError("endpoint_id_required", nullptr, responseOut, responseOutSize);
  }
  const bool removed = registry_->forgetEndpoint(endpointId, nowMs);
  if (!removed) {
    return writeForgetResult(endpointId, false, responseOut, responseOutSize);
  }
  telemetry_.forgotten++;
  if (!persistRegistry(nowMs)) {
    return writeError("endpoint_persist_failed", endpointId, responseOut, responseOutSize);
  }
  return writeForgetResult(endpointId, true, responseOut, responseOutSize);
}

BridgeEndpointControlResult BridgeEndpointControl::handleCapabilityUpdate(const JsonObjectConst& root,
                                                                          char* responseOut,
                                                                          size_t responseOutSize,
                                                                          uint32_t nowMs) {
  const char* endpointId = root["endpoint_id"] | "";
  if (isEmpty(endpointId)) {
    return writeError("endpoint_id_required", nullptr, responseOut, responseOutSize);
  }
  const uint32_t capabilities = capabilitiesFromJson(root["capabilities"]);
  if (!registry_->updateCapabilities(endpointId, capabilities, nowMs)) {
    return writeError("endpoint_not_trusted", endpointId, responseOut, responseOutSize);
  }
  const BridgeEndpointRecord* endpoint = registry_->findEndpoint(endpointId);
  if (endpoint == nullptr) {
    return writeError("endpoint_not_trusted", endpointId, responseOut, responseOutSize);
  }
  telemetry_.capabilityUpdates++;
  if (!persistRegistry(nowMs)) {
    return writeError("endpoint_persist_failed", endpointId, responseOut, responseOutSize);
  }
  return writeCapabilityResult(*endpoint, responseOut, responseOutSize);
}

BridgeEndpointControlResult BridgeEndpointControl::handleWiFiProfileUse(
    const JsonObjectConst& root,
    char* responseOut,
    size_t responseOutSize,
    uint32_t nowMs) {
  if (hasProtocolMismatch(root)) {
    return writeError("protocol_mismatch", nullptr, responseOut, responseOutSize);
  }
  const char* endpointId = root["endpoint_id"] | "";
  if (isEmpty(endpointId)) {
    return writeError("endpoint_id_required", nullptr, responseOut, responseOutSize);
  }
  if (registry_->findEndpoint(endpointId) == nullptr) {
    return writeError("endpoint_not_trusted", endpointId, responseOut, responseOutSize);
  }
  const char* profile = root["profile"] | "";
  if (!equals(profile, "home") && !equals(profile, "away")) {
    return writeError("wifi_profile_invalid", endpointId, responseOut, responseOutSize);
  }
  if (wifiProfileUseHandler_ == nullptr) {
    return writeError("wifi_profile_control_unavailable", endpointId, responseOut, responseOutSize);
  }

  telemetry_.wifiProfileUseRequests++;
  const BridgeEndpointWiFiProfileUseResult result =
      wifiProfileUseHandler_(profile, nowMs, wifiProfileUseContext_);
  if (result == BridgeEndpointWiFiProfileUseResult::ProfileNotConfigured) {
    return writeError("wifi_profile_not_configured", endpointId, responseOut, responseOutSize);
  }
  if (result == BridgeEndpointWiFiProfileUseResult::PersistenceFailed) {
    return writeError("wifi_profile_persist_failed", endpointId, responseOut, responseOutSize);
  }
  telemetry_.wifiProfileUseAccepted++;
  return writeWiFiProfileUseResult(endpointId, profile, responseOut, responseOutSize);
}

BridgeEndpointControlResult BridgeEndpointControl::writeEndpointHelloResult(
    const BridgeEndpointRecord& endpoint,
    char* responseOut,
    size_t responseOutSize) {
  JsonDocument response;
  response["type"] = "endpoint_hello_result";
  response["protocol"] = kBridgeProtocol;
  response["endpoint_id"] = endpoint.endpointId;
  response["trusted"] = true;
  const BridgeEndpointRecord* owner = registry_->activeOwner();
  response["active_brain_owner"] = owner == nullptr ? "" : owner->endpointId;
  response["trusted_endpoint_count"] = static_cast<uint32_t>(registry_->count());
  JsonArray capabilities = response["capabilities"].to<JsonArray>();
  writeCapabilities(endpoint.capabilities, capabilities);
  if (!writeJsonResponse(response, responseOut, responseOutSize)) {
    telemetry_.responsesDropped++;
    return BridgeEndpointControlResult::Rejected;
  }
  return BridgeEndpointControlResult::Handled;
}

BridgeEndpointControlResult BridgeEndpointControl::writeHeartbeatResult(const char* endpointId,
                                                                        char* responseOut,
                                                                        size_t responseOutSize) {
  JsonDocument response;
  response["type"] = "heartbeat";
  response["endpoint_id"] = endpointId;
  const BridgeEndpointRecord* owner = registry_->activeOwner();
  response["active_brain_owner"] = owner == nullptr ? "" : owner->endpointId;
  if (!writeJsonResponse(response, responseOut, responseOutSize)) {
    telemetry_.responsesDropped++;
    return BridgeEndpointControlResult::Rejected;
  }
  return BridgeEndpointControlResult::Handled;
}

BridgeEndpointControlResult BridgeEndpointControl::writeOwnerStatus(const char* state,
                                                                    char* responseOut,
                                                                    size_t responseOutSize) {
  const BridgeEndpointRecord* owner = registry_->activeOwner();
  JsonDocument response;
  response["type"] = "owner_status";
  response["active_brain_owner"] = owner == nullptr ? "" : owner->endpointId;
  response["owner_kind"] = owner == nullptr ? "" : endpointKindToString(owner->kind);
  response["state"] = owner == nullptr ? "offline" : state;
  response["trusted_endpoint_count"] = static_cast<uint32_t>(registry_->count());
  if (!writeJsonResponse(response, responseOut, responseOutSize)) {
    telemetry_.responsesDropped++;
    return BridgeEndpointControlResult::Rejected;
  }
  return BridgeEndpointControlResult::Handled;
}

BridgeEndpointControlResult BridgeEndpointControl::writeTrustedEndpoints(char* responseOut,
                                                                        size_t responseOutSize) {
  JsonDocument response;
  response["type"] = "trusted_endpoints_result";
  const BridgeEndpointRecord* owner = registry_->activeOwner();
  response["active_brain_owner"] = owner == nullptr ? "" : owner->endpointId;
  JsonArray endpoints = response["endpoints"].to<JsonArray>();
  for (size_t i = 0; i < registry_->count(); ++i) {
    const BridgeEndpointRecord* endpoint = registry_->endpointAt(i);
    if (endpoint == nullptr) {
      continue;
    }
    JsonObject item = endpoints.add<JsonObject>();
    item["endpoint_id"] = endpoint->endpointId;
    item["endpoint_name"] = endpoint->endpointName;
    item["endpoint_kind"] = endpointKindToString(endpoint->kind);
    item["public_key_fingerprint"] = endpoint->publicKeyFingerprint;
    item["priority"] = endpoint->priority;
    item["auto_connect"] = endpoint->autoConnect;
    item["last_seen_ms"] = endpoint->lastSeenMs;
    JsonArray capabilities = item["capabilities"].to<JsonArray>();
    writeCapabilities(endpoint->capabilities, capabilities);
  }
  if (!writeJsonResponse(response, responseOut, responseOutSize)) {
    telemetry_.responsesDropped++;
    return BridgeEndpointControlResult::Rejected;
  }
  return BridgeEndpointControlResult::Handled;
}

BridgeEndpointControlResult BridgeEndpointControl::writeForgetResult(const char* endpointId,
                                                                     bool ok,
                                                                     char* responseOut,
                                                                     size_t responseOutSize) {
  JsonDocument response;
  response["type"] = "forget_endpoint_result";
  response["endpoint_id"] = endpointId;
  response["ok"] = ok;
  const BridgeEndpointRecord* owner = registry_->activeOwner();
  response["active_brain_owner"] = owner == nullptr ? "" : owner->endpointId;
  response["trusted_endpoint_count"] = static_cast<uint32_t>(registry_->count());
  if (!writeJsonResponse(response, responseOut, responseOutSize)) {
    telemetry_.responsesDropped++;
    return BridgeEndpointControlResult::Rejected;
  }
  return BridgeEndpointControlResult::Handled;
}

BridgeEndpointControlResult BridgeEndpointControl::writeCapabilityResult(
    const BridgeEndpointRecord& endpoint,
    char* responseOut,
    size_t responseOutSize) {
  JsonDocument response;
  response["type"] = "capability_update_result";
  response["endpoint_id"] = endpoint.endpointId;
  JsonArray capabilities = response["capabilities"].to<JsonArray>();
  writeCapabilities(endpoint.capabilities, capabilities);
  if (!writeJsonResponse(response, responseOut, responseOutSize)) {
    telemetry_.responsesDropped++;
    return BridgeEndpointControlResult::Rejected;
  }
  return BridgeEndpointControlResult::Handled;
}

BridgeEndpointControlResult BridgeEndpointControl::writeWiFiProfileUseResult(
    const char* endpointId,
    const char* profile,
    char* responseOut,
    size_t responseOutSize) {
  JsonDocument response;
  response["type"] = "wifi_profile_use_result";
  response["endpoint_id"] = endpointId;
  response["profile"] = profile;
  response["accepted"] = true;
  response["reconnect_expected"] = true;
  if (!writeJsonResponse(response, responseOut, responseOutSize)) {
    telemetry_.responsesDropped++;
    return BridgeEndpointControlResult::Rejected;
  }
  return BridgeEndpointControlResult::Handled;
}

BridgeEndpointControlResult BridgeEndpointControl::writeError(const char* code,
                                                              const char* endpointId,
                                                              char* responseOut,
                                                              size_t responseOutSize) {
  JsonDocument response;
  response["type"] = "error";
  response["code"] = code == nullptr ? "endpoint_control_error" : code;
  if (!isEmpty(endpointId)) {
    response["endpoint_id"] = endpointId;
  }
  if (!writeJsonResponse(response, responseOut, responseOutSize)) {
    telemetry_.responsesDropped++;
  }
  return BridgeEndpointControlResult::Rejected;
}

BridgeEndpointKind BridgeEndpointControl::endpointKindFromString(const char* value) {
  if (equals(value, "pc")) return BridgeEndpointKind::Pc;
  if (equals(value, "android")) return BridgeEndpointKind::Android;
  if (equals(value, "dev")) return BridgeEndpointKind::Dev;
  return BridgeEndpointKind::Unknown;
}

const char* BridgeEndpointControl::endpointKindToString(BridgeEndpointKind kind) {
  switch (kind) {
    case BridgeEndpointKind::Pc:
      return "pc";
    case BridgeEndpointKind::Android:
      return "android";
    case BridgeEndpointKind::Dev:
      return "dev";
    case BridgeEndpointKind::Unknown:
    default:
      return "unknown";
  }
}

uint32_t BridgeEndpointControl::capabilitiesFromJson(const JsonVariantConst& value) {
  uint32_t capabilities = BridgeEndpointCapabilityNone;
  auto applyCapability = [&capabilities](const char* item) {
    if (item == nullptr) {
      return;
    }
    if (equals(item, "stt")) capabilities |= BridgeEndpointCapabilityStt;
    else if (equals(item, "llm")) capabilities |= BridgeEndpointCapabilityLlm;
    else if (equals(item, "tts")) capabilities |= BridgeEndpointCapabilityTts;
    else if (equals(item, "rvc")) capabilities |= BridgeEndpointCapabilityRvc;
    else if (equals(item, "settings")) capabilities |= BridgeEndpointCapabilitySettings;
    else if (equals(item, "audio_downlink") || equals(item, "pcm16_downlink"))
      capabilities |= BridgeEndpointCapabilityAudioDownlink;
    else if (equals(item, "persona_select"))
      capabilities |= BridgeEndpointCapabilityPersonaSelect;
    else if (equals(item, "model_profiles"))
      capabilities |= BridgeEndpointCapabilityModelProfiles;
    else if (equals(item, "diagnostics"))
      capabilities |= BridgeEndpointCapabilityDiagnostics;
    else if (equals(item, "wake_gate"))
      capabilities |= BridgeEndpointCapabilityWakeGate;
    else if (equals(item, "pcm16_upload"))
      capabilities |= BridgeEndpointCapabilityPcm16Upload;
  };

  if (value.is<JsonArrayConst>()) {
    for (JsonVariantConst item : value.as<JsonArrayConst>()) {
      applyCapability(item | "");
    }
  } else {
    applyCapability(value | "");
  }
  return capabilities;
}

void BridgeEndpointControl::writeCapabilities(uint32_t capabilities, JsonArray& out) {
  if ((capabilities & BridgeEndpointCapabilityStt) != 0) out.add("stt");
  if ((capabilities & BridgeEndpointCapabilityLlm) != 0) out.add("llm");
  if ((capabilities & BridgeEndpointCapabilityTts) != 0) out.add("tts");
  if ((capabilities & BridgeEndpointCapabilityRvc) != 0) out.add("rvc");
  if ((capabilities & BridgeEndpointCapabilitySettings) != 0) out.add("settings");
  if ((capabilities & BridgeEndpointCapabilityAudioDownlink) != 0) out.add("audio_downlink");
  if ((capabilities & BridgeEndpointCapabilityPersonaSelect) != 0) out.add("persona_select");
  if ((capabilities & BridgeEndpointCapabilityModelProfiles) != 0) out.add("model_profiles");
  if ((capabilities & BridgeEndpointCapabilityDiagnostics) != 0) out.add("diagnostics");
  if ((capabilities & BridgeEndpointCapabilityWakeGate) != 0) out.add("wake_gate");
  if ((capabilities & BridgeEndpointCapabilityPcm16Upload) != 0) out.add("pcm16_upload");
}

bool BridgeEndpointControl::hasProtocolMismatch(const JsonObjectConst& root) {
  const JsonVariantConst protocol = root["protocol"];
  if (protocol.isNull()) {
    return false;
  }
  return !equals(protocol | "", kBridgeProtocol);
}

bool BridgeEndpointControl::writeJsonResponse(const JsonDocument& doc,
                                              char* responseOut,
                                              size_t responseOutSize) {
  if (responseOut == nullptr || responseOutSize == 0) {
    return false;
  }
  responseOut[0] = '\0';
  const size_t required = measureJson(doc) + 1u;
  if (required > responseOutSize) {
    return false;
  }
  serializeJson(doc, responseOut, responseOutSize);
  return responseOut[0] != '\0';
}

void BridgeEndpointControl::copyBounded(char* out, size_t outSize, const char* value) {
  if (out == nullptr || outSize == 0) {
    return;
  }
  if (value == nullptr) {
    out[0] = '\0';
    return;
  }
  const size_t sourceLen = std::strlen(value);
  const size_t copyLen = sourceLen < (outSize - 1u) ? sourceLen : (outSize - 1u);
  std::memcpy(out, value, copyLen);
  out[copyLen] = '\0';
}

bool BridgeEndpointControl::normalizePairingCode(const char* value, char* out, size_t outSize) {
  if (out == nullptr || outSize < 7) {
    return false;
  }
  out[0] = '\0';
  if (isEmpty(value)) {
    return false;
  }
  size_t count = 0;
  for (const char* cursor = value; *cursor != '\0'; ++cursor) {
    if (*cursor == '-' || *cursor == ' ') {
      continue;
    }
    if (!isBase36(*cursor) || count >= 6) {
      out[0] = '\0';
      return false;
    }
    out[count++] = uppercaseAscii(*cursor);
  }
  if (count != 6) {
    out[0] = '\0';
    return false;
  }
  out[count] = '\0';
  return true;
}

bool BridgeEndpointControl::pairingCodeMatches(const char* value) const {
  if (requiredPairingCode_[0] == '\0') {
    return true;
  }
  char normalized[sizeof(requiredPairingCode_)] = {};
  return normalizePairingCode(value, normalized, sizeof(normalized)) &&
         std::strcmp(normalized, requiredPairingCode_) == 0;
}

bool BridgeEndpointControl::persistRegistry(uint32_t nowMs) {
  if (store_ == nullptr) {
    return true;
  }
  if (registry_ == nullptr || !store_->save(*registry_, nowMs)) {
    telemetry_.persistenceErrors++;
    return false;
  }
  telemetry_.persistenceSaves++;
  return true;
}

}  // namespace stackchan
