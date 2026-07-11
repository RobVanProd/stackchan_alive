#include "io/BridgeWiFiProvisioner.hpp"

#include <cstring>

#if defined(ARDUINO_ARCH_ESP32)
#include <WiFi.h>

namespace {

void disconnectWiFiStation() {
  WiFi.disconnect(false, false);
  delay(500);
}

}  // namespace
#endif

namespace stackchan {

bool BridgeWiFiProvisioner::begin(const BridgeWiFiProvisioningConfig& config, uint32_t nowMs) {
  config_ = config;
  telemetry_ = BridgeWiFiProvisioningTelemetry {};
  telemetry_.ready = true;
  telemetry_.configured = isConfigured();
  attemptStartMs_ = 0;
  if (!config_.enabled) {
#if defined(ARDUINO_ARCH_ESP32)
    disconnectWiFiStation();
#endif
    copyError("wifi_bridge_disabled");
    return true;
  }
  if (!telemetry_.configured) {
#if defined(ARDUINO_ARCH_ESP32)
    disconnectWiFiStation();
#endif
    copyError("wifi_bridge_not_configured");
    return false;
  }
  startAttempt(nowMs);
  return true;
}

void BridgeWiFiProvisioner::update(uint32_t nowMs) {
  if (!telemetry_.ready || !config_.enabled || !telemetry_.configured) {
    return;
  }

#if defined(ARDUINO_ARCH_ESP32)
  telemetry_.status = WiFi.status();
  if (WiFi.status() == WL_CONNECTED) {
    telemetry_.connected = true;
    telemetry_.connecting = false;
    telemetry_.lastError[0] = '\0';
    return;
  }
#else
  telemetry_.status = 0;
#endif

  telemetry_.connected = false;
  if (telemetry_.connecting && nowMs - attemptStartMs_ >= config_.connectTimeoutMs) {
    telemetry_.connectFailures++;
    scheduleRetry("wifi_connect_timeout", nowMs);
    return;
  }

  if (!telemetry_.connecting && nowMs >= telemetry_.nextAttemptMs) {
    startAttempt(nowMs);
  }
}

bool BridgeWiFiProvisioner::isConfigured() const {
  return config_.enabled && config_.ssid != nullptr && config_.ssid[0] != '\0' &&
         config_.bridgeHost != nullptr && config_.bridgeHost[0] != '\0' &&
         config_.bridgePort != 0 && config_.secWebSocketKey != nullptr &&
         config_.secWebSocketKey[0] != '\0';
}

bool BridgeWiFiProvisioner::isConnected() const {
  return telemetry_.connected;
}

BridgeNetworkSessionConfig BridgeWiFiProvisioner::networkSessionConfig() const {
  BridgeNetworkSessionConfig session;
  session.enabled = config_.enabled && telemetry_.configured;
  session.host = config_.bridgeHost;
  session.port = config_.bridgePort;
  session.path = config_.bridgePath;
  session.secWebSocketKey = config_.secWebSocketKey;
  session.bridge = config_.bridge;
  return session;
}

void BridgeWiFiProvisioner::startAttempt(uint32_t nowMs) {
  telemetry_.beginAttempts++;
  telemetry_.connecting = true;
  telemetry_.connected = false;
  telemetry_.lastAttemptMs = nowMs;
  telemetry_.nextAttemptMs = 0;
  attemptStartMs_ = nowMs;
  telemetry_.lastError[0] = '\0';

#if defined(ARDUINO_ARCH_ESP32)
  disconnectWiFiStation();
  WiFi.mode(WIFI_STA);
  WiFi.setSleep(false);
  WiFi.begin(config_.ssid, config_.password != nullptr ? config_.password : "");
  telemetry_.status = WiFi.status();
#else
  telemetry_.status = 0;
#endif
}

void BridgeWiFiProvisioner::scheduleRetry(const char* reason, uint32_t nowMs) {
  telemetry_.connecting = false;
  telemetry_.connected = false;
  telemetry_.nextAttemptMs = nowMs + config_.retryDelayMs;
  telemetry_.reconnectsScheduled++;
  copyError(reason);
#if defined(ARDUINO_ARCH_ESP32)
  disconnectWiFiStation();
#endif
}

void BridgeWiFiProvisioner::copyError(const char* reason) {
  if (reason == nullptr) {
    telemetry_.lastError[0] = '\0';
    return;
  }
  const size_t len = std::strlen(reason);
  const size_t copyLen = len < (sizeof(telemetry_.lastError) - 1u) ? len : (sizeof(telemetry_.lastError) - 1u);
  std::memcpy(telemetry_.lastError, reason, copyLen);
  telemetry_.lastError[copyLen] = '\0';
}

}  // namespace stackchan
