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

 private:
#if defined(ARDUINO_ARCH_ESP32)
  mutable WiFiClient client_;
#endif
};

}  // namespace stackchan
