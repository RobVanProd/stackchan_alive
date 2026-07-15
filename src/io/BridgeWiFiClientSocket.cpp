#include "io/BridgeWiFiClientSocket.hpp"

#include <cerrno>

namespace stackchan {

namespace {
constexpr int32_t kBridgeTcpConnectTimeoutMs = 5000;
constexpr uint32_t kBridgeTcpIoTimeoutMs = 1000;
}

#if defined(ARDUINO_ARCH_ESP32)
extern const uint8_t stackchanRootCaBundleStart[]
    asm("_binary_data_cert_x509_crt_bundle_bin_start");
extern const uint8_t stackchanRootCaBundleEnd[]
    asm("_binary_data_cert_x509_crt_bundle_bin_end");
#endif

void BridgeWiFiClientSocket::noteConnectResult(int result,
                                               int errorCode,
                                               uint32_t startedAtMs) {
  ++connectAttempts_;
  lastConnectResult_ = result;
  lastConnectErrno_ = result != 0 ? 0 : errorCode;
  lastConnectDurationMs_ = millis() - startedAtMs;
  if (lastConnectDurationMs_ > maxConnectDurationMs_) {
    maxConnectDurationMs_ = lastConnectDurationMs_;
  }
}

bool BridgeWiFiClientSocket::connect(const char* host, uint16_t port, bool useTls) {
#if defined(ARDUINO_ARCH_ESP32)
  if (host == nullptr || host[0] == '\0' || port == 0) {
    return false;
  }
  stop();
  delay(20);
  tlsActive_ = useTls;
  if (useTls) {
#if defined(ESP_ARDUINO_VERSION_MAJOR) && ESP_ARDUINO_VERSION_MAJOR >= 3
    secureClient_.setCACertBundle(
        stackchanRootCaBundleStart,
        static_cast<size_t>(stackchanRootCaBundleEnd - stackchanRootCaBundleStart));
#else
    secureClient_.setCACertBundle(stackchanRootCaBundleStart);
#endif
    secureClient_.setHandshakeTimeout(15);
    secureClient_.setTimeout(1);
    activeClient_ = &secureClient_;
  } else {
    plainClient_.setTimeout(kBridgeTcpIoTimeoutMs);
    activeClient_ = &plainClient_;
  }
  const uint32_t startedAtMs = millis();
  IPAddress address;
  if (address.fromString(host)) {
    if (useTls) {
      noteConnectResult(0, EINVAL, startedAtMs);
      return false;
    }
    Serial.print(F("[wifi-socket] connect mode=ip host="));
    Serial.print(host);
    Serial.print(F(" port="));
    Serial.println(port);
    errno = 0;
    const int result = activeClient_->connect(address, port, kBridgeTcpConnectTimeoutMs);
    const int errorCode = errno;
    const bool ok = result != 0;
    noteConnectResult(result, errorCode, startedAtMs);
    if (ok) {
      activeClient_->setNoDelay(true);
    }
    Serial.print(F("[wifi-socket] result="));
    Serial.println(ok ? F("connected") : F("failed"));
    return ok;
  }
  Serial.print(F("[wifi-socket] connect mode=host host="));
  Serial.print(host);
  Serial.print(F(" port="));
  Serial.println(port);
  errno = 0;
  const int result = activeClient_->connect(host, port, kBridgeTcpConnectTimeoutMs);
  const int errorCode = errno;
  const bool ok = result != 0;
  noteConnectResult(result, errorCode, startedAtMs);
  if (ok) {
    activeClient_->setNoDelay(true);
  }
  Serial.print(F("[wifi-socket] result="));
  Serial.println(ok ? F("connected") : F("failed"));
  return ok;
#else
  (void)host;
  (void)port;
  (void)useTls;
  return false;
#endif
}

bool BridgeWiFiClientSocket::isConnected() const {
#if defined(ARDUINO_ARCH_ESP32)
  return activeClient_ != nullptr && activeClient_->connected();
#else
  return false;
#endif
}

int BridgeWiFiClientSocket::available() {
#if defined(ARDUINO_ARCH_ESP32)
  return activeClient_ != nullptr ? activeClient_->available() : 0;
#else
  return 0;
#endif
}

int BridgeWiFiClientSocket::read(uint8_t* out, size_t outSize) {
#if defined(ARDUINO_ARCH_ESP32)
  if (out == nullptr || outSize == 0) {
    return 0;
  }
  return activeClient_ != nullptr ? activeClient_->read(out, outSize) : 0;
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
  return activeClient_ != nullptr ? activeClient_->write(data, length) : 0;
#else
  (void)data;
  (void)length;
  return 0;
#endif
}

void BridgeWiFiClientSocket::stop() {
#if defined(ARDUINO_ARCH_ESP32)
  if (activeClient_ != nullptr) {
    activeClient_->stop();
  }
  activeClient_ = nullptr;
  tlsActive_ = false;
#endif
}

}  // namespace stackchan
