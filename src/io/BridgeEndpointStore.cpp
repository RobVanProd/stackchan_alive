#include "io/BridgeEndpointStore.hpp"

#include <cstring>

namespace stackchan {

namespace {
constexpr const char* kBridgeEndpointStoreSchema = "stackchan.bridge-endpoints.v1";

bool isEmpty(const char* value) {
  return value == nullptr || value[0] == '\0';
}

bool equals(const char* left, const char* right) {
  return left != nullptr && right != nullptr && std::strcmp(left, right) == 0;
}
}

bool BridgeEndpointMemoryStore::begin() {
  ready_ = true;
  return ready_;
}

bool BridgeEndpointMemoryStore::read(char* out, size_t outSize, size_t* bytesOut) {
  if (!ready_ || out == nullptr || outSize == 0) {
    return false;
  }
  out[0] = '\0';
  if (bytesOut != nullptr) {
    *bytesOut = 0;
  }
  if (!hasValue_) {
    return true;
  }

  const size_t length = std::strlen(value_);
  if (length + 1u > outSize) {
    return false;
  }
  std::memcpy(out, value_, length + 1u);
  if (bytesOut != nullptr) {
    *bytesOut = length;
  }
  return true;
}

bool BridgeEndpointMemoryStore::write(const char* value) {
  if (!ready_ || value == nullptr) {
    return false;
  }
  const size_t length = std::strlen(value);
  if (length + 1u > sizeof(value_)) {
    return false;
  }
  std::memcpy(value_, value, length + 1u);
  hasValue_ = true;
  return true;
}

bool BridgeEndpointMemoryStore::clear() {
  if (!ready_) {
    return false;
  }
  value_[0] = '\0';
  hasValue_ = false;
  return true;
}

#if defined(ARDUINO_ARCH_ESP32)
bool BridgeEndpointPreferencesStore::begin() {
  ready_ = preferences_.begin(kNamespace, false);
  return ready_;
}

bool BridgeEndpointPreferencesStore::read(char* out, size_t outSize, size_t* bytesOut) {
  if (!ready_ || out == nullptr || outSize == 0) {
    return false;
  }
  out[0] = '\0';
  if (bytesOut != nullptr) {
    *bytesOut = 0;
  }
  const String value = preferences_.getString(kKey, "");
  if (value.length() == 0) {
    return true;
  }
  if (static_cast<size_t>(value.length()) + 1u > outSize) {
    return false;
  }
  value.toCharArray(out, outSize);
  if (bytesOut != nullptr) {
    *bytesOut = static_cast<size_t>(value.length());
  }
  return true;
}

bool BridgeEndpointPreferencesStore::write(const char* value) {
  if (!ready_ || value == nullptr) {
    return false;
  }
  return preferences_.putString(kKey, value) > 0;
}

bool BridgeEndpointPreferencesStore::clear() {
  if (!ready_) {
    return false;
  }
  if (!preferences_.isKey(kKey)) {
    return true;
  }
  return preferences_.remove(kKey);
}
#endif

bool BridgeEndpointStore::begin(BridgeEndpointStoreBackend& backend) {
  backend_ = &backend;
  telemetry_ = BridgeEndpointStoreTelemetry {};
  telemetry_.ready = backend_->begin();
  return telemetry_.ready;
}

bool BridgeEndpointStore::save(const BridgeEndpointRegistry& registry, uint32_t nowMs) {
  if (backend_ == nullptr || !telemetry_.ready) {
    telemetry_.rejected++;
    return false;
  }

  JsonDocument document;
  document["schema"] = kBridgeEndpointStoreSchema;
  document["count"] = static_cast<uint32_t>(registry.count());
  JsonArray endpoints = document["endpoints"].to<JsonArray>();

  for (size_t i = 0; i < registry.count(); ++i) {
    const BridgeEndpointRecord* endpoint = registry.endpointAt(i);
    if (endpoint == nullptr || !endpoint->trusted) {
      continue;
    }
    JsonObject item = endpoints.add<JsonObject>();
    item["endpoint_id"] = endpoint->endpointId;
    item["endpoint_name"] = endpoint->endpointName;
    item["endpoint_kind"] = endpointKindToString(endpoint->kind);
    item["public_key_fingerprint"] = endpoint->publicKeyFingerprint;
    item["priority"] = endpoint->priority;
    item["auto_connect"] = endpoint->autoConnect;
    item["capabilities"] = endpoint->capabilities;
    item["last_seen_ms"] = endpoint->lastSeenMs;
  }

  char json[kBridgeEndpointStoreJsonMax] = {};
  if (measureJson(document) + 1u > sizeof(json)) {
    telemetry_.writeErrors++;
    telemetry_.lastChangeMs = nowMs;
    return false;
  }
  serializeJson(document, json, sizeof(json));
  if (!backend_->write(json)) {
    telemetry_.writeErrors++;
    telemetry_.lastChangeMs = nowMs;
    return false;
  }

  telemetry_.saves++;
  telemetry_.endpointsSaved = static_cast<uint32_t>(registry.count());
  telemetry_.lastChangeMs = nowMs;
  return true;
}

bool BridgeEndpointStore::load(BridgeEndpointRegistry& registry, uint32_t nowMs) {
  if (backend_ == nullptr || !telemetry_.ready || !registry.telemetry().ready) {
    telemetry_.rejected++;
    return false;
  }

  char json[kBridgeEndpointStoreJsonMax] = {};
  size_t bytes = 0;
  if (!backend_->read(json, sizeof(json), &bytes)) {
    telemetry_.parseErrors++;
    telemetry_.lastChangeMs = nowMs;
    return false;
  }
  if (bytes == 0 || json[0] == '\0') {
    telemetry_.loads++;
    telemetry_.endpointsLoaded = 0;
    telemetry_.lastChangeMs = nowMs;
    return true;
  }

  JsonDocument document;
  const DeserializationError error = deserializeJson(document, json);
  if (error) {
    telemetry_.parseErrors++;
    telemetry_.lastChangeMs = nowMs;
    return false;
  }
  const char* schema = document["schema"] | "";
  if (!equals(schema, kBridgeEndpointStoreSchema)) {
    telemetry_.parseErrors++;
    telemetry_.lastChangeMs = nowMs;
    return false;
  }
  const JsonArrayConst endpoints = document["endpoints"].as<JsonArrayConst>();
  if (endpoints.isNull()) {
    telemetry_.parseErrors++;
    telemetry_.lastChangeMs = nowMs;
    return false;
  }

  uint32_t loaded = 0;
  for (JsonObjectConst item : endpoints) {
    BridgeEndpointRecord endpoint;
    copyStringField(item, "endpoint_id", endpoint.endpointId, sizeof(endpoint.endpointId));
    if (isEmpty(endpoint.endpointId)) {
      telemetry_.parseErrors++;
      telemetry_.lastChangeMs = nowMs;
      return false;
    }
    copyStringField(item, "endpoint_name", endpoint.endpointName, sizeof(endpoint.endpointName));
    copyStringField(item,
                    "public_key_fingerprint",
                    endpoint.publicKeyFingerprint,
                    sizeof(endpoint.publicKeyFingerprint));
    endpoint.kind = endpointKindFromString(item["endpoint_kind"] | "");
    endpoint.priority = item["priority"] | 0u;
    endpoint.autoConnect = item["auto_connect"] | true;
    endpoint.capabilities = item["capabilities"] | 0u;
    endpoint.lastSeenMs = item["last_seen_ms"] | nowMs;
    endpoint.lastHeartbeatMs = 0;
    if (!registry.restoreEndpoint(endpoint, nowMs)) {
      telemetry_.rejected++;
      telemetry_.lastChangeMs = nowMs;
      return false;
    }
    loaded++;
  }

  telemetry_.loads++;
  telemetry_.endpointsLoaded = loaded;
  telemetry_.lastChangeMs = nowMs;
  return true;
}

bool BridgeEndpointStore::clear(uint32_t nowMs) {
  if (backend_ == nullptr || !telemetry_.ready) {
    telemetry_.rejected++;
    return false;
  }
  if (!backend_->clear()) {
    telemetry_.writeErrors++;
    telemetry_.lastChangeMs = nowMs;
    return false;
  }
  telemetry_.clears++;
  telemetry_.lastChangeMs = nowMs;
  return true;
}

const char* BridgeEndpointStore::endpointKindToString(BridgeEndpointKind kind) {
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

BridgeEndpointKind BridgeEndpointStore::endpointKindFromString(const char* value) {
  if (equals(value, "pc")) return BridgeEndpointKind::Pc;
  if (equals(value, "android")) return BridgeEndpointKind::Android;
  if (equals(value, "dev")) return BridgeEndpointKind::Dev;
  return BridgeEndpointKind::Unknown;
}

bool BridgeEndpointStore::copyStringField(const JsonObjectConst& object,
                                          const char* key,
                                          char* out,
                                          size_t outSize) {
  const JsonVariantConst value = object[key];
  if (value.isNull()) {
    copyBounded(out, outSize, "");
    return false;
  }
  copyBounded(out, outSize, value | "");
  return true;
}

void BridgeEndpointStore::copyBounded(char* out, size_t outSize, const char* value) {
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

}  // namespace stackchan
