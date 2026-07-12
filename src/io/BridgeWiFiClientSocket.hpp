#pragma once

#include <Arduino.h>
#include <stddef.h>
#include <stdint.h>

#include "io/BridgeNetworkSession.hpp"

#if defined(ARDUINO_ARCH_ESP32)
#include <WiFiClient.h>
#endif

namespace stackchan {

class BridgeWiFiClientSocket final : public BridgeNetworkSocket {
 public:
  bool connect(const char* host, uint16_t port) override;
  bool isConnected() const override;
  int available() override;
  int read(uint8_t* out, size_t outSize) override;
  size_t write(const uint8_t* data, size_t length) override;
  void stop() override;

  uint32_t connectAttempts() const { return connectAttempts_; }
  uint32_t lastConnectDurationMs() const { return lastConnectDurationMs_; }
  uint32_t maxConnectDurationMs() const { return maxConnectDurationMs_; }
  int lastConnectErrno() const { return lastConnectErrno_; }
  int lastConnectResult() const { return lastConnectResult_; }

 private:
  void noteConnectResult(int result, int errorCode, uint32_t startedAtMs);

#if defined(ARDUINO_ARCH_ESP32)
  mutable WiFiClient client_;
#endif
  uint32_t connectAttempts_ = 0;
  uint32_t lastConnectDurationMs_ = 0;
  uint32_t maxConnectDurationMs_ = 0;
  int lastConnectErrno_ = 0;
  int lastConnectResult_ = 0;
};

}  // namespace stackchan
