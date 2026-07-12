#pragma once

#include <Arduino.h>
#include <stdint.h>

#include "io/BridgeClient.hpp"
#include "io/BridgeNetworkSession.hpp"

namespace stackchan {

#ifndef STACKCHAN_ENABLE_WIFI_BRIDGE
#define STACKCHAN_ENABLE_WIFI_BRIDGE 0
#endif

#ifndef STACKCHAN_WIFI_SSID
#define STACKCHAN_WIFI_SSID ""
#endif

#ifndef STACKCHAN_WIFI_PASSWORD
#define STACKCHAN_WIFI_PASSWORD ""
#endif

#ifndef STACKCHAN_BRIDGE_HOST
#define STACKCHAN_BRIDGE_HOST ""
#endif

#ifndef STACKCHAN_BRIDGE_PORT
#define STACKCHAN_BRIDGE_PORT 8765
#endif

#ifndef STACKCHAN_BRIDGE_PATH
#define STACKCHAN_BRIDGE_PATH "/bridge"
#endif

#ifndef STACKCHAN_BRIDGE_WS_KEY
#define STACKCHAN_BRIDGE_WS_KEY "c3RhY2tjaGFuLWZpcm13YXJlLWtleQ=="
#endif

constexpr size_t kBridgeWiFiErrorMax = kBridgeErrorMax;

struct BridgeWiFiProvisioningConfig {
  bool enabled = STACKCHAN_ENABLE_WIFI_BRIDGE != 0;
  const char* ssid = STACKCHAN_WIFI_SSID;
  const char* password = STACKCHAN_WIFI_PASSWORD;
  const char* bridgeHost = STACKCHAN_BRIDGE_HOST;
  uint16_t bridgePort = STACKCHAN_BRIDGE_PORT;
  const char* bridgePath = STACKCHAN_BRIDGE_PATH;
  const char* secWebSocketKey = STACKCHAN_BRIDGE_WS_KEY;
  uint32_t connectTimeoutMs = 15000;
  uint32_t retryDelayMs = 10000;
  BridgeClientConfig bridge;
};

struct BridgeWiFiProvisioningTelemetry {
  bool ready = false;
  bool configured = false;
  bool connecting = false;
  bool connected = false;
  uint32_t beginAttempts = 0;
  uint32_t connectFailures = 0;
  uint32_t reconnectsScheduled = 0;
  uint32_t lastAttemptMs = 0;
  uint32_t nextAttemptMs = 0;
  int status = 0;
  char lastError[kBridgeWiFiErrorMax] = {};
};

class BridgeWiFiProvisioner {
 public:
  bool begin(const BridgeWiFiProvisioningConfig& config = BridgeWiFiProvisioningConfig {},
             uint32_t nowMs = 0);
  void update(uint32_t nowMs);

  bool isConfigured() const;
  bool isConnected() const;

  BridgeNetworkSessionConfig networkSessionConfig() const;

  const BridgeWiFiProvisioningTelemetry& telemetry() const {
    return telemetry_;
  }

 private:
  void startAttempt(uint32_t nowMs);
  void scheduleRetry(const char* reason, uint32_t nowMs);
  void copyError(const char* reason);

  BridgeWiFiProvisioningConfig config_;
  BridgeWiFiProvisioningTelemetry telemetry_;
  uint32_t attemptStartMs_ = 0;
};

}  // namespace stackchan
