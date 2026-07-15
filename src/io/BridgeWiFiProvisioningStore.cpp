#include "io/BridgeWiFiProvisioningStore.hpp"

#include <cctype>
#include <cstring>

namespace stackchan {

namespace {
constexpr const char* kBridgeWiFiProvisioningStoreSchema = "stackchan.bridge-wifi.v2";
constexpr const char* kBridgeWiFiProvisioningStoreLegacySchema = "stackchan.bridge-wifi.v1";

bool isEmpty(const char* value) {
  return value == nullptr || value[0] == '\0';
}

bool equals(const char* left, const char* right) {
  return left != nullptr && right != nullptr && std::strcmp(left, right) == 0;
}
}  // namespace

const char* bridgeWiFiProfileName(BridgeWiFiProfileId profile) {
  return profile == BridgeWiFiProfileId::Away ? "away" : "home";
}

bool parseBridgeWiFiProfile(const char* value, BridgeWiFiProfileId* profileOut) {
  if (value == nullptr || profileOut == nullptr) {
    return false;
  }
  char normalized[6] = {};
  size_t index = 0;
  while (value[index] != '\0' && index + 1u < sizeof(normalized)) {
    normalized[index] = static_cast<char>(std::tolower(static_cast<unsigned char>(value[index])));
    ++index;
  }
  if (value[index] != '\0') {
    return false;
  }
  if (equals(normalized, "home")) {
    *profileOut = BridgeWiFiProfileId::Home;
    return true;
  }
  if (equals(normalized, "away")) {
    *profileOut = BridgeWiFiProfileId::Away;
    return true;
  }
  return false;
}

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
  document["active_profile"] = bridgeWiFiProfileName(record.activeProfile);
  JsonObject profiles = document["profiles"].to<JsonObject>();
  writeProfile(profiles["home"].to<JsonObject>(), record.home);
  writeProfile(profiles["away"].to<JsonObject>(), record.away);

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
  if (equals(schema, kBridgeWiFiProvisioningStoreLegacySchema)) {
    record.enabled = document["enabled"] | false;
    record.activeProfile = BridgeWiFiProfileId::Home;
    BridgeWiFiProfileRecord& home = record.home;
    copyStringField(document.as<JsonObjectConst>(), "ssid", home.ssid, sizeof(home.ssid));
    copyStringField(document.as<JsonObjectConst>(), "password", home.password, sizeof(home.password));
    copyStringField(document.as<JsonObjectConst>(), "bridge_host", home.bridgeHost, sizeof(home.bridgeHost));
    home.bridgePort = document["bridge_port"] | 0u;
    copyStringField(document.as<JsonObjectConst>(), "bridge_path", home.bridgePath, sizeof(home.bridgePath));
    if (home.bridgePath[0] == '\0') {
      copyBounded(home.bridgePath, sizeof(home.bridgePath), "/bridge");
    }
    home.configured = !isEmpty(home.ssid) && !isEmpty(home.bridgeHost) && home.bridgePort != 0;
    if (!isValidRecord(record)) {
      telemetry_.parseErrors++;
      telemetry_.lastChangeMs = nowMs;
      return false;
    }
    telemetry_.legacyMigrations++;
  } else if (equals(schema, kBridgeWiFiProvisioningStoreSchema)) {
    record.enabled = document["enabled"] | false;
    const char* activeProfile = document["active_profile"] | "home";
    if (!parseBridgeWiFiProfile(activeProfile, &record.activeProfile)) {
      telemetry_.parseErrors++;
      telemetry_.lastChangeMs = nowMs;
      return false;
    }
    const JsonObjectConst profiles = document["profiles"].as<JsonObjectConst>();
    if (profiles.isNull() || !readProfile(profiles["home"].as<JsonObjectConst>(), record.home) ||
        !readProfile(profiles["away"].as<JsonObjectConst>(), record.away)) {
      telemetry_.parseErrors++;
      telemetry_.lastChangeMs = nowMs;
      return false;
    }
    if (!isValidRecord(record)) {
      telemetry_.parseErrors++;
      telemetry_.lastChangeMs = nowMs;
      return false;
    }
  } else {
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
  if (!isValidProfile(record.home) || !isValidProfile(record.away)) {
    return false;
  }
  if (record.away.configured &&
      (!record.away.useTls || isEmpty(record.away.accessClientId) ||
       isEmpty(record.away.accessClientSecret))) {
    return false;
  }
  return !record.enabled || record.profile(record.activeProfile).configured;
}

bool BridgeWiFiProvisioningStore::isValidProfile(const BridgeWiFiProfileRecord& profile) {
  if (!profile.configured) {
    return isEmpty(profile.ssid) && isEmpty(profile.password) && isEmpty(profile.bridgeHost) &&
           isEmpty(profile.accessClientId) && isEmpty(profile.accessClientSecret);
  }
  const bool accessPairComplete = isEmpty(profile.accessClientId) == isEmpty(profile.accessClientSecret);
  const bool accessUsesTls = isEmpty(profile.accessClientId) || profile.useTls;
  return !isEmpty(profile.ssid) && !isEmpty(profile.bridgeHost) && profile.bridgePort != 0 &&
         !isEmpty(profile.bridgePath) && accessPairComplete && accessUsesTls;
}

void BridgeWiFiProvisioningStore::writeProfile(JsonObject object,
                                               const BridgeWiFiProfileRecord& profile) {
  object["configured"] = profile.configured;
  object["tls"] = profile.useTls;
  object["ssid"] = profile.ssid;
  object["password"] = profile.password;
  object["bridge_host"] = profile.bridgeHost;
  object["bridge_port"] = profile.bridgePort;
  object["bridge_path"] = profile.bridgePath;
  object["access_client_id"] = profile.accessClientId;
  object["access_client_secret"] = profile.accessClientSecret;
}

bool BridgeWiFiProvisioningStore::readProfile(const JsonObjectConst& object,
                                              BridgeWiFiProfileRecord& profile) {
  if (object.isNull()) {
    return false;
  }
  profile.configured = object["configured"] | false;
  profile.useTls = object["tls"] | false;
  copyStringField(object, "ssid", profile.ssid, sizeof(profile.ssid));
  copyStringField(object, "password", profile.password, sizeof(profile.password));
  copyStringField(object, "bridge_host", profile.bridgeHost, sizeof(profile.bridgeHost));
  profile.bridgePort = object["bridge_port"] | 0u;
  copyStringField(object, "bridge_path", profile.bridgePath, sizeof(profile.bridgePath));
  copyStringField(object, "access_client_id", profile.accessClientId, sizeof(profile.accessClientId));
  copyStringField(object,
                  "access_client_secret",
                  profile.accessClientSecret,
                  sizeof(profile.accessClientSecret));
  if (profile.bridgePath[0] == '\0') {
    copyBounded(profile.bridgePath, sizeof(profile.bridgePath), "/bridge");
  }
  return isValidProfile(profile);
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
