#include "io/BridgeWiFiProvisioningStore.hpp"

#include <cstring>

namespace stackchan {

namespace {
constexpr const char* kBridgeWiFiProvisioningStoreSchema = "stackchan.bridge-wifi.v1";

bool isEmpty(const char* value) {
  return value == nullptr || value[0] == '\0';
}

bool equals(const char* left, const char* right) {
  return left != nullptr && right != nullptr && std::strcmp(left, right) == 0;
}
}  // namespace

bool BridgeWiFiProvisioningMemoryStore::begin() {
  ready_ = true;
  return ready_;
}

bool BridgeWiFiProvisioningMemoryStore::read(char* out, size_t outSize, size_t* bytesOut) {
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

bool BridgeWiFiProvisioningMemoryStore::write(const char* value) {
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

bool BridgeWiFiProvisioningMemoryStore::clear() {
  if (!ready_) {
    return false;
  }
  value_[0] = '\0';
  hasValue_ = false;
  return true;
}

#if defined(ARDUINO_ARCH_ESP32)
bool BridgeWiFiProvisioningPreferencesStore::begin() {
  ready_ = preferences_.begin(kNamespace, false);
  return ready_;
}

bool BridgeWiFiProvisioningPreferencesStore::read(char* out, size_t outSize, size_t* bytesOut) {
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

bool BridgeWiFiProvisioningPreferencesStore::write(const char* value) {
  if (!ready_ || value == nullptr) {
    return false;
  }
  return preferences_.putString(kKey, value) > 0;
}

bool BridgeWiFiProvisioningPreferencesStore::clear() {
  if (!ready_) {
    return false;
  }
  if (!preferences_.isKey(kKey)) {
    return true;
  }
  return preferences_.remove(kKey);
}
#endif

bool BridgeWiFiProvisioningStore::begin(BridgeWiFiProvisioningStoreBackend& backend) {
  backend_ = &backend;
  telemetry_ = BridgeWiFiProvisioningStoreTelemetry {};
  telemetry_.ready = backend_->begin();
  return telemetry_.ready;
}

bool BridgeWiFiProvisioningStore::save(const BridgeWiFiProvisioningRecord& record, uint32_t nowMs) {
  if (backend_ == nullptr || !telemetry_.ready) {
    telemetry_.rejected++;
    return false;
  }
  if (!isValidRecord(record)) {
    telemetry_.rejected++;
    telemetry_.lastChangeMs = nowMs;
    return false;
  }

  JsonDocument document;
  document["schema"] = kBridgeWiFiProvisioningStoreSchema;
  document["enabled"] = record.enabled;
  document["ssid"] = record.ssid;
  document["password"] = record.password;
  document["bridge_host"] = record.bridgeHost;
  document["bridge_port"] = record.bridgePort;
  document["bridge_path"] = record.bridgePath;

  char json[kBridgeWiFiProvisioningStoreJsonMax] = {};
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
  telemetry_.hasRecord = true;
  telemetry_.lastChangeMs = nowMs;
  return true;
}

bool BridgeWiFiProvisioningStore::load(BridgeWiFiProvisioningRecord& record, uint32_t nowMs) {
  if (backend_ == nullptr || !telemetry_.ready) {
    telemetry_.rejected++;
    return false;
  }
  record = BridgeWiFiProvisioningRecord {};

  char json[kBridgeWiFiProvisioningStoreJsonMax] = {};
  size_t bytes = 0;
  if (!backend_->read(json, sizeof(json), &bytes)) {
    telemetry_.parseErrors++;
    telemetry_.lastChangeMs = nowMs;
    return false;
  }
  if (bytes == 0 || json[0] == '\0') {
    telemetry_.loads++;
    telemetry_.hasRecord = false;
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
  if (!equals(schema, kBridgeWiFiProvisioningStoreSchema)) {
    telemetry_.parseErrors++;
    telemetry_.lastChangeMs = nowMs;
    return false;
  }

  record.enabled = document["enabled"] | false;
  copyStringField(document.as<JsonObjectConst>(), "ssid", record.ssid, sizeof(record.ssid));
  copyStringField(document.as<JsonObjectConst>(), "password", record.password, sizeof(record.password));
  copyStringField(document.as<JsonObjectConst>(), "bridge_host", record.bridgeHost, sizeof(record.bridgeHost));
  record.bridgePort = document["bridge_port"] | 0u;
  copyStringField(document.as<JsonObjectConst>(), "bridge_path", record.bridgePath, sizeof(record.bridgePath));
  if (record.bridgePath[0] == '\0') {
    copyBounded(record.bridgePath, sizeof(record.bridgePath), "/bridge");
  }
  if (!isValidRecord(record)) {
    telemetry_.parseErrors++;
    telemetry_.lastChangeMs = nowMs;
    return false;
  }

  telemetry_.loads++;
  telemetry_.hasRecord = true;
  telemetry_.lastChangeMs = nowMs;
  return true;
}

bool BridgeWiFiProvisioningStore::clear(uint32_t nowMs) {
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
  telemetry_.hasRecord = false;
  telemetry_.lastChangeMs = nowMs;
  return true;
}

bool BridgeWiFiProvisioningStore::isValidRecord(const BridgeWiFiProvisioningRecord& record) {
  if (!record.enabled) {
    return true;
  }
  return !isEmpty(record.ssid) && !isEmpty(record.bridgeHost) && record.bridgePort != 0 &&
         !isEmpty(record.bridgePath);
}

bool BridgeWiFiProvisioningStore::copyStringField(const JsonObjectConst& object,
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

void BridgeWiFiProvisioningStore::copyBounded(char* out, size_t outSize, const char* value) {
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
