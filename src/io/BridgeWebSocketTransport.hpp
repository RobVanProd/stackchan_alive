#pragma once

#include <Arduino.h>
#include <stddef.h>
#include <stdint.h>

#include "io/BridgeClient.hpp"

namespace stackchan {

constexpr size_t kBridgeWebSocketHandshakeMax = 512;
constexpr size_t kBridgeWebSocketFramePayloadMax = kBridgeAudioStreamChunkPayloadMax;

enum class BridgeWebSocketOpcode : uint8_t {
  Continuation = 0x0,
  Text = 0x1,
  Binary = 0x2,
  Close = 0x8,
  Ping = 0x9,
  Pong = 0xA,
};

enum class BridgeWebSocketTransportState : uint8_t {
  Idle,
  Handshaking,
  Connected,
  Closed,
  Error,
};

struct BridgeWebSocketTransportTelemetry {
  BridgeWebSocketTransportState state = BridgeWebSocketTransportState::Idle;
  bool handshakeAccepted = false;
  uint32_t handshakesAccepted = 0;
  uint32_t handshakesRejected = 0;
  uint32_t textFramesDecoded = 0;
  uint32_t binaryFramesDecoded = 0;
  uint32_t closeFramesDecoded = 0;
  uint32_t pingFramesDecoded = 0;
  uint32_t pongFramesDecoded = 0;
  uint32_t frameErrors = 0;
  uint32_t bridgeSubmitsRejected = 0;
  uint32_t bytesDecoded = 0;
  uint32_t maxPayloadBytes = 0;
  uint32_t lastFrameMs = 0;
  uint8_t lastOpcode = 0;
  char lastError[kBridgeErrorMax] = {};
};

class BridgeWebSocketTransport {
 public:
  bool begin(BridgeClient& bridge, uint32_t nowMs = 0);
  void reset();

  bool acceptHandshakeResponse(const char* response,
                               uint32_t nowMs = 0,
                               const char* expectedAccept = nullptr);
  bool submitBytes(const uint8_t* data, size_t length, uint32_t nowMs);

  const BridgeWebSocketTransportTelemetry& telemetry() const {
    return telemetry_;
  }

  static size_t buildHandshakeRequest(char* out,
                                      size_t outSize,
                                      const char* host,
                                      uint16_t port,
                                      const char* path,
                                      const char* secWebSocketKey,
                                      const BridgeClientConfig& config = BridgeClientConfig {});

  static size_t encodeClientTextFrame(const char* payload,
                                      const uint8_t maskKey[4],
                                      uint8_t* out,
                                      size_t outSize);
  static size_t encodeClientBinaryFrame(const uint8_t* payload,
                                        size_t length,
                                        const uint8_t maskKey[4],
                                        uint8_t* out,
                                        size_t outSize);

 private:
  enum class DecodeStage : uint8_t {
    Header0,
    Header1,
    Length16High,
    Length16Low,
    Payload,
  };

  static bool containsIgnoreCase(const char* haystack, const char* needle);
  static bool isSupportedServerOpcode(uint8_t opcode);
  static bool isControlOpcode(uint8_t opcode);
  static void copyBounded(char* out, size_t outSize, const char* value);
  static size_t encodeClientFrame(uint8_t opcode,
                                  const uint8_t* payload,
                                  size_t length,
                                  const uint8_t maskKey[4],
                                  uint8_t* out,
                                  size_t outSize);

  void resetDecoder();
  bool startPayload(uint32_t length, uint32_t nowMs);
  bool dispatchFrame(uint32_t nowMs);
  bool fail(const char* reason);
  bool rejectHandshake(const char* reason);

  BridgeClient* bridge_ = nullptr;
  BridgeWebSocketTransportTelemetry telemetry_;
  DecodeStage decodeStage_ = DecodeStage::Header0;
  uint8_t opcode_ = 0;
  uint32_t payloadLength_ = 0;
  uint32_t payloadReceived_ = 0;
  uint8_t length16High_ = 0;
  uint8_t payload_[kBridgeWebSocketFramePayloadMax + 1] = {};
};

}  // namespace stackchan
