#pragma once

#include <Arduino.h>
#include <stddef.h>
#include <stdint.h>

#include "io/BridgeClient.hpp"
#include "io/BridgeEndpointControl.hpp"
#include "io/BridgeSocketWriter.hpp"
#include "io/BridgeWebSocketTransport.hpp"

namespace stackchan {

constexpr size_t kBridgeNetworkHandshakeResponseMax = 768;
constexpr size_t kBridgeNetworkReadChunkMax = 256;
constexpr size_t kBridgeNetworkErrorMax = kBridgeErrorMax;

enum class BridgeNetworkSessionState : uint8_t {
  Idle,
  Connecting,
  Handshaking,
  Connected,
  Backoff,
  Error,
};

struct BridgeNetworkSessionConfig {
  bool enabled = false;
  const char* host = nullptr;
  uint16_t port = 8788;
  const char* path = "/bridge";
  const char* secWebSocketKey = "c3RhY2tjaGFuLWZpcm13YXJlLWtleQ==";
  uint32_t handshakeTimeoutMs = 3000;
  uint32_t reconnectDelayMs = 3000;
  uint16_t readBudgetBytes = 1024;
  uint32_t maskSeed = 0x51ac5eedu;
  BridgeClientConfig bridge;
};

struct BridgeNetworkSessionTelemetry {
  bool ready = false;
  BridgeNetworkSessionState state = BridgeNetworkSessionState::Idle;
  uint32_t connectAttempts = 0;
  uint32_t connectFailures = 0;
  uint32_t handshakesSent = 0;
  uint32_t handshakesAccepted = 0;
  uint32_t handshakesFailed = 0;
  uint32_t reconnectsScheduled = 0;
  uint32_t socketDisconnects = 0;
  uint32_t bytesRead = 0;
  uint32_t bytesWritten = 0;
  uint32_t writerFrames = 0;
  uint32_t lastStateMs = 0;
  char lastError[kBridgeNetworkErrorMax] = {};
};

class BridgeNetworkSocket : public BridgeSocketWriterSink {
 public:
  virtual ~BridgeNetworkSocket() = default;

  virtual bool connect(const char* host, uint16_t port) = 0;
  virtual int available() = 0;
  virtual int read(uint8_t* out, size_t outSize) = 0;
  virtual void stop() = 0;
};

class BridgeNetworkSession {
 public:
  bool begin(BridgeClient& bridge,
             BridgeNetworkSocket& socket,
             const BridgeNetworkSessionConfig& config,
             uint32_t nowMs = 0);
  void attachEndpointControl(BridgeEndpointControl* endpointControl);
  bool start(uint32_t nowMs);
  void update(uint32_t nowMs);
  void stop(uint32_t nowMs);

  const BridgeNetworkSessionTelemetry& telemetry() const {
    return telemetry_;
  }

  const BridgeWebSocketTransport& transport() const {
    return transport_;
  }

  const BridgeSocketWriter& writer() const {
    return writer_;
  }

 private:
  bool isConfigured() const;
  bool openSocket(uint32_t nowMs);
  bool sendHandshake(uint32_t nowMs);
  void readHandshake(uint32_t nowMs);
  void readConnected(uint32_t nowMs);
  void drainWriter(uint32_t nowMs);
  void scheduleReconnect(const char* reason, uint32_t nowMs);
  void setState(BridgeNetworkSessionState state, uint32_t nowMs);
  void copyError(const char* reason);
  bool handshakeComplete() const;

  BridgeClient* bridge_ = nullptr;
  BridgeNetworkSocket* socket_ = nullptr;
  BridgeEndpointControl* endpointControl_ = nullptr;
  BridgeNetworkSessionConfig config_;
  BridgeNetworkSessionTelemetry telemetry_;
  BridgeWebSocketTransport transport_;
  BridgeSocketWriter writer_;
  char handshakeResponse_[kBridgeNetworkHandshakeResponseMax] = {};
  size_t handshakeBytes_ = 0;
  uint32_t stateStartMs_ = 0;
  uint32_t nextReconnectMs_ = 0;
  uint8_t readChunk_[kBridgeNetworkReadChunkMax] = {};
};

}  // namespace stackchan
