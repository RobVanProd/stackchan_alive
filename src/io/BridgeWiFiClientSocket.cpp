#include "io/BridgeWiFiClientSocket.hpp"

namespace stackchan {

namespace {
constexpr int32_t kBridgeTcpConnectTimeoutMs = 750;
constexpr uint32_t kBridgeTcpIoTimeoutMs = 250;
}

bool BridgeWiFiClientSocket::connect(const char* host, uint16_t port) {
#if defined(ARDUINO_ARCH_ESP32)
  if (host == nullptr || host[0] == '\0' || port == 0) {
    return false;
  }
  client_.stop();
  client_.setTimeout(kBridgeTcpIoTimeoutMs);
  IPAddress address;
  if (address.fromString(host)) {
    Serial.print(F("[wifi-socket] connect mode=ip host="));
    Serial.print(host);
    Serial.print(F(" port="));
    Serial.println(port);
    const bool ok = client_.connect(address, port, kBridgeTcpConnectTimeoutMs);
    Serial.print(F("[wifi-socket] result="));
    Serial.println(ok ? F("connected") : F("failed"));
    return ok;
  }
  Serial.print(F("[wifi-socket] connect mode=host host="));
  Serial.print(host);
  Serial.print(F(" port="));
  Serial.println(port);
  const bool ok = client_.connect(host, port, kBridgeTcpConnectTimeoutMs);
  Serial.print(F("[wifi-socket] result="));
  Serial.println(ok ? F("connected") : F("failed"));
  return ok;
#else
  (void)host;
  (void)port;
  return false;
#endif
}

bool BridgeWiFiClientSocket::isConnected() const {
#if defined(ARDUINO_ARCH_ESP32)
  return client_.connected();
#else
  return false;
#endif
}

int BridgeWiFiClientSocket::available() {
#if defined(ARDUINO_ARCH_ESP32)
  return client_.available();
#else
  return 0;
#endif
}

int BridgeWiFiClientSocket::read(uint8_t* out, size_t outSize) {
#if defined(ARDUINO_ARCH_ESP32)
  if (out == nullptr || outSize == 0) {
    return 0;
  }
  return client_.read(out, outSize);
#else
  (void)out;
  (void)outSize;
  return 0;
#endif
}

size_t BridgeWiFiClientSocket::write(const uint8_t* data, size_t length) {
#if defined(ARDUINO_ARCH_ESP32)
  if (data == nullptr || length == 0) {
    return 0;
  }
  return client_.write(data, length);
#else
  (void)data;
  (void)length;
  return 0;
#endif
}

void BridgeWiFiClientSocket::stop() {
#if defined(ARDUINO_ARCH_ESP32)
  client_.stop();
#endif
}

}  // namespace stackchan
