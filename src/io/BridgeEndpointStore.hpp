#pragma once

#include <Arduino.h>
#include <ArduinoJson.h>
#include <stddef.h>
#include <stdint.h>

#if defined(ARDUINO_ARCH_ESP32)
#include <Preferences.h>
#endif

#include "io/BridgeEndpointRegistry.hpp"

namespace stackchan {

constexpr size_t kBridgeEndpointStoreJsonMax = 4096;

struct BridgeEndpointStoreTelemetry {
  bool ready = false;
  uint32_t loads = 0;
  uint32_t saves = 0;
  uint32_t clears = 0;
  uint32_t endpointsLoaded = 0;
  uint32_t endpointsSaved = 0;
  uint32_t parseErrors = 0;
  uint32_t writeErrors = 0;
  uint32_t rejected = 0;
  uint32_t lastChangeMs = 0;
};

class BridgeEndpointStoreBackend {
 public:
  virtual ~BridgeEndpointStoreBackend() = default;
  virtual bool begin() = 0;
  virtual bool read(char* out, size_t outSize, size_t* bytesOut) = 0;
  virtual bool write(const char* value) = 0;
  virtual bool clear() = 0;
};

class BridgeEndpointMemoryStore final : public BridgeEndpointStoreBackend {
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
  char value_[kBridgeEndpointStoreJsonMax] = {};
};

#if defined(ARDUINO_ARCH_ESP32)
class BridgeEndpointPreferencesStore final : public BridgeEndpointStoreBackend {
 public:
  bool begin() override;
  bool read(char* out, size_t outSize, size_t* bytesOut) override;
  bool write(const char* value) override;
  bool clear() override;

 private:
  static constexpr const char* kNamespace = "stack_bridge";
  static constexpr const char* kKey = "endpoints";
  Preferences preferences_;
  bool ready_ = false;
};
#endif

class BridgeEndpointStore {
 public:
  bool begin(BridgeEndpointStoreBackend& backend);
  bool save(const BridgeEndpointRegistry& registry, uint32_t nowMs);
  bool load(BridgeEndpointRegistry& registry, uint32_t nowMs);
  bool clear(uint32_t nowMs);

  const BridgeEndpointStoreTelemetry& telemetry() const {
    return telemetry_;
  }

 private:
  static const char* endpointKindToString(BridgeEndpointKind kind);
  static BridgeEndpointKind endpointKindFromString(const char* value);
  static bool copyStringField(const JsonObjectConst& object,
                              const char* key,
                              char* out,
                              size_t outSize);
  static void copyBounded(char* out, size_t outSize, const char* value);

  BridgeEndpointStoreBackend* backend_ = nullptr;
  BridgeEndpointStoreTelemetry telemetry_;
};

}  // namespace stackchan
