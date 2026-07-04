#pragma once

#include <Arduino.h>
#include <stddef.h>
#include <stdint.h>

#include "io/BridgeWebSocketTransport.hpp"

namespace stackchan {

constexpr size_t kBridgeSocketWriterPayloadMax =
    kBridgeWebSocketFramePayloadMax > kBridgeEndpointControlResponseMax
        ? kBridgeWebSocketFramePayloadMax
        : kBridgeEndpointControlResponseMax;
constexpr size_t kBridgeSocketWriterFrameMax = kBridgeSocketWriterPayloadMax + 16u;

enum class BridgeSocketWriterDrainResult : uint8_t {
  NoPending,
  WroteFrame,
  Partial,
  NotReady,
  NotConnected,
  EncodeFailed,
  WriteFailed,
};

struct BridgeSocketWriterTelemetry {
  bool ready = false;
  bool frameBuffered = false;
  bool binaryFrameQueued = false;
  uint32_t drainAttempts = 0;
  uint32_t framesEncoded = 0;
  uint32_t framesWritten = 0;
  uint32_t binaryFramesQueued = 0;
  uint32_t binaryFramesDropped = 0;
  uint32_t binaryFramesEncoded = 0;
  uint32_t binaryFramesWritten = 0;
  uint32_t partialWrites = 0;
  uint32_t writeFailures = 0;
  uint32_t binaryBytesQueued = 0;
  uint32_t binaryBytesWritten = 0;
  uint32_t bytesWritten = 0;
  uint32_t lastWriteMs = 0;
  char lastError[kBridgeErrorMax] = {};
};

class BridgeSocketWriterSink {
 public:
  virtual ~BridgeSocketWriterSink() = default;

  virtual bool isConnected() const = 0;
  virtual size_t write(const uint8_t* data, size_t length) = 0;
};

class BridgeSocketWriter {
 public:
  bool begin(BridgeWebSocketTransport& transport, BridgeSocketWriterSink& sink, uint32_t maskSeed = 0x51ac5eedu);
  void reset();

  bool queueBinaryFrame(const uint8_t* payload, size_t length);
  BridgeSocketWriterDrainResult drainPendingFrame(uint32_t nowMs);
  BridgeSocketWriterDrainResult drainPendingTextResponse(uint32_t nowMs);

  const BridgeSocketWriterTelemetry& telemetry() const {
    return telemetry_;
  }

 private:
  enum class PendingFrameKind : uint8_t {
    None,
    TextResponse,
    BinaryUpload,
  };

  BridgeSocketWriterDrainResult drainPending(uint32_t nowMs, bool includeBinary);
  uint32_t nextMaskWord();
  void makeMask(uint8_t out[4]);
  BridgeSocketWriterDrainResult fail(BridgeSocketWriterDrainResult result, const char* reason);
  void clearFrame();
  void copyError(const char* reason);

  BridgeWebSocketTransport* transport_ = nullptr;
  BridgeSocketWriterSink* sink_ = nullptr;
  BridgeSocketWriterTelemetry telemetry_;
  uint32_t maskState_ = 0x51ac5eedu;
  uint8_t frame_[kBridgeSocketWriterFrameMax] = {};
  uint8_t binaryPayload_[kBridgeWebSocketFramePayloadMax] = {};
  size_t frameBytes_ = 0;
  size_t frameOffset_ = 0;
  size_t framePayloadBytes_ = 0;
  size_t binaryPayloadBytes_ = 0;
  PendingFrameKind frameKind_ = PendingFrameKind::None;
};

}  // namespace stackchan
