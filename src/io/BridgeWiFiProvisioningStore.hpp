#pragma once

#include <Arduino.h>
#include <ArduinoJson.h>
#include <stddef.h>
#include <stdint.h>

#if defined(ARDUINO_ARCH_ESP32)
#include <Preferences.h>
#endif

namespace stackchan {

constexpr size_t kBridgeWiFiProvisioningStoreJsonMax = 1536;
constexpr size_t kBridgeWiFiSsidMax = 33;
constexpr size_t kBridgeWiFiPasswordMax = 65;
constexpr size_t kBridgeWiFiHostMax = 96;
constexpr size_t kBridgeWiFiPathMax = 96;
constexpr size_t kBridgeAccessCredentialMax = 97;

enum class BridgeWiFiProfileId : uint8_t {
  Home = 0,
  Away = 1,
};

const char* bridgeWiFiProfileName(BridgeWiFiProfileId profile);
bool parseBridgeWiFiProfile(const char* value, BridgeWiFiProfileId* profileOut);

struct BridgeWiFiProfileRecord {
  bool configured = false;
  bool useTls = false;
  char ssid[kBridgeWiFiSsidMax] = {};
  char password[kBridgeWiFiPasswordMax] = {};
  char bridgeHost[kBridgeWiFiHostMax] = {};
  uint16_t bridgePort = 0;
  char bridgePath[kBridgeWiFiPathMax] = "/bridge";
  char accessClientId[kBridgeAccessCredentialMax] = {};
  char accessClientSecret[kBridgeAccessCredentialMax] = {};
};

struct BridgeWiFiProvisioningRecord {
  bool enabled = false;
  BridgeWiFiProfileId activeProfile = BridgeWiFiProfileId::Home;
  BridgeWiFiProfileRecord home;
  BridgeWiFiProfileRecord away;

  BridgeWiFiProfileRecord& profile(BridgeWiFiProfileId id) {
    return id == BridgeWiFiProfileId::Away ? away : home;
  }

  const BridgeWiFiProfileRecord& profile(BridgeWiFiProfileId id) const {
    return id == BridgeWiFiProfileId::Away ? away : home;
  }
};

struct BridgeWiFiProvisioningStoreTelemetry {
  bool ready = false;
  bool hasRecord = false;
  uint32_t loads = 0;
  uint32_t saves = 0;
  uint32_t clears = 0;
  uint32_t parseErrors = 0;
  uint32_t writeErrors = 0;
  uint32_t rejected = 0;
  uint32_t legacyMigrations = 0;
  uint32_t lastChangeMs = 0;
};

class BridgeWiFiProvisioningStoreBackend {
 public:
  virtual ~BridgeWiFiProvisioningStoreBackend() = default;
  virtual bool begin() = 0;
  virtual bool read(char* out, size_t outSize, size_t* bytesOut) = 0;
  virtual bool write(const char* value) = 0;
  virtual bool clear() = 0;
};

class BridgeWiFiProvisioningMemoryStore final : public BridgeWiFiProvisioningStoreBackend {
 public:
  bool begin() override;
  bool read(char* out, size_t outSize, size_t* bytesOut) override;
  bool write(const char* value) override;
  bool clear() override;

  const char* value() const {
    return value_;
  }

 private:
  bool ready_ = false;
  bool hasValue_ = false;
  char value_[kBridgeWiFiProvisioningStoreJsonMax] = {};
};

#if defined(ARDUINO_ARCH_ESP32)
class BridgeWiFiProvisioningPreferencesStore final : public BridgeWiFiProvisioningStoreBackend {
 public:
  bool begin() override;
  bool read(char* out, size_t outSize, size_t* bytesOut) override;
  bool write(const char* value) override;
  bool clear() override;

 private:
  static constexpr const char* kNamespace = "stack_wifi";
  static constexpr const char* kKey = "provision";
  Preferences preferences_;
  bool ready_ = false;
};
#endif

class BridgeWiFiProvisioningStore {
 public:
  bool begin(BridgeWiFiProvisioningStoreBackend& backend);
  bool save(const BridgeWiFiProvisioningRecord& record, uint32_t nowMs);
  bool load(BridgeWiFiProvisioningRecord& record, uint32_t nowMs);
  bool clear(uint32_t nowMs);

  const BridgeWiFiProvisioningStoreTelemetry& telemetry() const {
    return telemetry_;
  }

 private:
  static bool isValidRecord(const BridgeWiFiProvisioningRecord& record);
  static bool isValidProfile(const BridgeWiFiProfileRecord& profile);
  static void writeProfile(JsonObject object, const BridgeWiFiProfileRecord& profile);
  static bool readProfile(const JsonObjectConst& object, BridgeWiFiProfileRecord& profile);
  static bool copyStringField(const JsonObjectConst& object,
                              const char* key,
                              char* out,
                              size_t outSize);
  static void copyBounded(char* out, size_t outSize, const char* value);

  BridgeWiFiProvisioningStoreBackend* backend_ = nullptr;
  BridgeWiFiProvisioningStoreTelemetry telemetry_;
};

}  // namespace stackchan
