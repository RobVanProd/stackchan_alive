#include "io/BridgeWebSocketTransport.hpp"

#include <cstdio>
#include <cstring>

namespace stackchan {

namespace {
constexpr const char* kBridgeDefaultPath = "/bridge";
constexpr const char* kUpgradeHeader = "upgrade: websocket";
constexpr const char* kConnectionHeader = "connection: upgrade";
constexpr const char* kAcceptHeader = "sec-websocket-accept:";
}

bool BridgeWebSocketTransport::begin(BridgeClient& bridge, uint32_t nowMs) {
  bridge_ = &bridge;
  telemetry_ = BridgeWebSocketTransportTelemetry {};
  hasPendingTextResponse_ = false;
  pendingTextResponse_[0] = '\0';
  endpointResponse_[0] = '\0';
  resetDecoder();
  if (!bridge_->telemetry().ready) {
    return fail("bridge_client_not_ready");
  }
  telemetry_.state = BridgeWebSocketTransportState::Handshaking;
  bridge_->markConnecting(nowMs);
  return true;
}

void BridgeWebSocketTransport::reset() {
  BridgeClient* bridge = bridge_;
  BridgeEndpointControl* endpointControl = endpointControl_;
  telemetry_ = BridgeWebSocketTransportTelemetry {};
  bridge_ = bridge;
  endpointControl_ = endpointControl;
  hasPendingTextResponse_ = false;
  pendingTextResponse_[0] = '\0';
  endpointResponse_[0] = '\0';
  resetDecoder();
}

void BridgeWebSocketTransport::attachEndpointControl(BridgeEndpointControl* endpointControl) {
  endpointControl_ = endpointControl;
}

bool BridgeWebSocketTransport::acceptHandshakeResponse(const char* response,
                                                       uint32_t nowMs,
                                                       const char* expectedAccept) {
  if (response == nullptr || response[0] == '\0') {
    return rejectHandshake("empty_handshake_response");
  }
  if (std::strncmp(response, "HTTP/1.1 101", 12) != 0 &&
      std::strncmp(response, "HTTP/1.0 101", 12) != 0) {
    return rejectHandshake("websocket_handshake_not_101");
  }
  if (!containsIgnoreCase(response, kUpgradeHeader) ||
      !containsIgnoreCase(response, kConnectionHeader) ||
      !containsIgnoreCase(response, kAcceptHeader)) {
    return rejectHandshake("missing_websocket_upgrade_headers");
  }
  if (expectedAccept != nullptr && expectedAccept[0] != '\0' &&
      !containsIgnoreCase(response, expectedAccept)) {
    return rejectHandshake("websocket_accept_mismatch");
  }

  telemetry_.state = BridgeWebSocketTransportState::Connected;
  telemetry_.handshakeAccepted = true;
  telemetry_.handshakesAccepted++;
  telemetry_.lastFrameMs = nowMs;
  telemetry_.lastError[0] = '\0';
  return true;
}

bool BridgeWebSocketTransport::submitBytes(const uint8_t* data, size_t length, uint32_t nowMs) {
  if (telemetry_.state != BridgeWebSocketTransportState::Connected) {
    return fail("websocket_not_connected");
  }
  if (data == nullptr && length > 0) {
    return fail("invalid_websocket_bytes");
  }

  for (size_t i = 0; i < length; ++i) {
    const uint8_t value = data[i];
    telemetry_.bytesDecoded++;

    switch (decodeStage_) {
      case DecodeStage::Header0:
        opcode_ = value & 0x0f;
        if ((value & 0x80) == 0) {
          return fail("fragmented_websocket_frame");
        }
        if (!isSupportedServerOpcode(opcode_)) {
          return fail("unsupported_websocket_opcode");
        }
        decodeStage_ = DecodeStage::Header1;
        break;

      case DecodeStage::Header1: {
        if ((value & 0x80) != 0) {
          return fail("masked_server_websocket_frame");
        }
        const uint8_t shortLength = value & 0x7f;
        if (shortLength < 126) {
          if (!startPayload(shortLength, nowMs)) {
            return false;
          }
        } else if (shortLength == 126) {
          decodeStage_ = DecodeStage::Length16High;
        } else {
          return fail("websocket_frame_64bit_length");
        }
        break;
      }

      case DecodeStage::Length16High:
        length16High_ = value;
        decodeStage_ = DecodeStage::Length16Low;
        break;

      case DecodeStage::Length16Low: {
        const uint32_t longLength = (static_cast<uint32_t>(length16High_) << 8) |
                                    static_cast<uint32_t>(value);
        if (!startPayload(longLength, nowMs)) {
          return false;
        }
        break;
      }

      case DecodeStage::Payload:
        payload_[payloadReceived_] = value;
        payloadReceived_++;
        if (payloadReceived_ >= payloadLength_) {
          if (!dispatchFrame(nowMs)) {
            return false;
          }
          resetDecoder();
          if (telemetry_.state == BridgeWebSocketTransportState::Closed) {
            return true;
          }
        }
        break;
    }
  }

  return true;
}

bool BridgeWebSocketTransport::hasPendingTextResponse() const {
  return hasPendingTextResponse_;
}

bool BridgeWebSocketTransport::popPendingTextResponse(char* out, size_t outSize) {
  if (!hasPendingTextResponse_ || out == nullptr || outSize == 0) {
    return false;
  }
  copyBounded(out, outSize, pendingTextResponse_);
  hasPendingTextResponse_ = false;
  pendingTextResponse_[0] = '\0';
  return out[0] != '\0';
}

size_t BridgeWebSocketTransport::encodePendingTextResponseFrame(const uint8_t maskKey[4],
                                                               uint8_t* out,
                                                               size_t outSize) {
  if (!hasPendingTextResponse_) {
    return 0;
  }
  const size_t bytes = encodeClientTextFrame(pendingTextResponse_, maskKey, out, outSize);
  if (bytes == 0) {
    return 0;
  }
  hasPendingTextResponse_ = false;
  pendingTextResponse_[0] = '\0';
  telemetry_.outgoingTextFramesEncoded++;
  return bytes;
}

size_t BridgeWebSocketTransport::buildHandshakeRequest(char* out,
                                                       size_t outSize,
                                                       const char* host,
                                                       uint16_t port,
                                                       const char* path,
                                                       const char* secWebSocketKey,
                                                       const BridgeClientConfig& config) {
  if (out == nullptr || outSize == 0 || host == nullptr || host[0] == '\0' ||
      secWebSocketKey == nullptr || secWebSocketKey[0] == '\0') {
    return 0;
  }

  const char* requestPath = (path != nullptr && path[0] != '\0') ? path : kBridgeDefaultPath;
  const char* protocol = config.protocolVersion != nullptr ? config.protocolVersion : "";
  const char* deviceId = config.deviceId != nullptr ? config.deviceId : "";
  const int written = std::snprintf(
      out,
      outSize,
      "GET %s HTTP/1.1\r\n"
      "Host: %s:%u\r\n"
      "Upgrade: websocket\r\n"
      "Connection: Upgrade\r\n"
      "Sec-WebSocket-Key: %s\r\n"
      "Sec-WebSocket-Version: 13\r\n"
      "X-Stackchan-Protocol: %s\r\n"
      "X-Stackchan-Device: %s\r\n"
      "\r\n",
      requestPath,
      host,
      static_cast<unsigned>(port),
      secWebSocketKey,
      protocol,
      deviceId);

  if (written <= 0 || static_cast<size_t>(written) >= outSize) {
    if (outSize > 0) {
      out[0] = '\0';
    }
    return 0;
  }
  return static_cast<size_t>(written);
}

size_t BridgeWebSocketTransport::encodeClientTextFrame(const char* payload,
                                                       const uint8_t maskKey[4],
                                                       uint8_t* out,
                                                       size_t outSize) {
  if (payload == nullptr) {
    return 0;
  }
  return encodeClientFrame(static_cast<uint8_t>(BridgeWebSocketOpcode::Text),
                           reinterpret_cast<const uint8_t*>(payload),
                           std::strlen(payload),
                           maskKey,
                           out,
                           outSize);
}

size_t BridgeWebSocketTransport::encodeClientBinaryFrame(const uint8_t* payload,
                                                         size_t length,
                                                         const uint8_t maskKey[4],
                                                         uint8_t* out,
                                                         size_t outSize) {
  return encodeClientFrame(static_cast<uint8_t>(BridgeWebSocketOpcode::Binary),
                           payload,
                           length,
                           maskKey,
                           out,
                           outSize);
}

bool BridgeWebSocketTransport::containsIgnoreCase(const char* haystack, const char* needle) {
  if (haystack == nullptr || needle == nullptr) {
    return false;
  }
  const size_t needleLen = std::strlen(needle);
  if (needleLen == 0) {
    return true;
  }
  for (const char* cursor = haystack; *cursor != '\0'; ++cursor) {
    size_t i = 0;
    while (i < needleLen && cursor[i] != '\0') {
      char left = cursor[i];
      char right = needle[i];
      if (left >= 'A' && left <= 'Z') {
        left = static_cast<char>(left - 'A' + 'a');
      }
      if (right >= 'A' && right <= 'Z') {
        right = static_cast<char>(right - 'A' + 'a');
      }
      if (left != right) {
        break;
      }
      ++i;
    }
    if (i == needleLen) {
      return true;
    }
  }
  return false;
}

bool BridgeWebSocketTransport::isSupportedServerOpcode(uint8_t opcode) {
  return opcode == static_cast<uint8_t>(BridgeWebSocketOpcode::Text) ||
         opcode == static_cast<uint8_t>(BridgeWebSocketOpcode::Binary) ||
         opcode == static_cast<uint8_t>(BridgeWebSocketOpcode::Close) ||
         opcode == static_cast<uint8_t>(BridgeWebSocketOpcode::Ping) ||
         opcode == static_cast<uint8_t>(BridgeWebSocketOpcode::Pong);
}

bool BridgeWebSocketTransport::isControlOpcode(uint8_t opcode) {
  return opcode == static_cast<uint8_t>(BridgeWebSocketOpcode::Close) ||
         opcode == static_cast<uint8_t>(BridgeWebSocketOpcode::Ping) ||
         opcode == static_cast<uint8_t>(BridgeWebSocketOpcode::Pong);
}

void BridgeWebSocketTransport::copyBounded(char* out, size_t outSize, const char* value) {
  if (out == nullptr || outSize == 0) {
    return;
  }
  if (value == nullptr) {
    out[0] = '\0';
    return;
  }
  const size_t sourceLen = std::strlen(value);
  const size_t copyLen = sourceLen < (outSize - 1) ? sourceLen : (outSize - 1);
  std::memcpy(out, value, copyLen);
  out[copyLen] = '\0';
}

size_t BridgeWebSocketTransport::encodeClientFrame(uint8_t opcode,
                                                   const uint8_t* payload,
                                                   size_t length,
                                                   const uint8_t maskKey[4],
                                                   uint8_t* out,
                                                   size_t outSize) {
  if ((payload == nullptr && length > 0) || maskKey == nullptr || out == nullptr ||
      !isSupportedServerOpcode(opcode) || opcode == static_cast<uint8_t>(BridgeWebSocketOpcode::Close) ||
      opcode == static_cast<uint8_t>(BridgeWebSocketOpcode::Ping) ||
      opcode == static_cast<uint8_t>(BridgeWebSocketOpcode::Pong)) {
    return 0;
  }
  if (length > 0xffffu) {
    return 0;
  }

  const size_t headerBytes = length < 126 ? 2u : 4u;
  const size_t totalBytes = headerBytes + 4u + length;
  if (outSize < totalBytes) {
    return 0;
  }

  out[0] = static_cast<uint8_t>(0x80 | (opcode & 0x0f));
  if (length < 126) {
    out[1] = static_cast<uint8_t>(0x80 | length);
  } else {
    out[1] = 0x80 | 126;
    out[2] = static_cast<uint8_t>((length >> 8) & 0xff);
    out[3] = static_cast<uint8_t>(length & 0xff);
  }

  const size_t maskOffset = headerBytes;
  out[maskOffset + 0] = maskKey[0];
  out[maskOffset + 1] = maskKey[1];
  out[maskOffset + 2] = maskKey[2];
  out[maskOffset + 3] = maskKey[3];
  for (size_t i = 0; i < length; ++i) {
    out[maskOffset + 4u + i] = payload[i] ^ maskKey[i % 4u];
  }

  return totalBytes;
}

void BridgeWebSocketTransport::resetDecoder() {
  decodeStage_ = DecodeStage::Header0;
  opcode_ = 0;
  payloadLength_ = 0;
  payloadReceived_ = 0;
  length16High_ = 0;
}

bool BridgeWebSocketTransport::startPayload(uint32_t length, uint32_t nowMs) {
  if (isControlOpcode(opcode_) && length > 125u) {
    return fail("websocket_control_frame_too_large");
  }
  if (length > kBridgeWebSocketFramePayloadMax) {
    return fail("websocket_payload_too_large");
  }

  payloadLength_ = length;
  payloadReceived_ = 0;
  if (payloadLength_ == 0) {
    if (!dispatchFrame(nowMs)) {
      return false;
    }
    resetDecoder();
  } else {
    decodeStage_ = DecodeStage::Payload;
  }
  return true;
}

bool BridgeWebSocketTransport::dispatchFrame(uint32_t nowMs) {
  telemetry_.lastOpcode = opcode_;
  telemetry_.lastFrameMs = nowMs;
  if (payloadLength_ > telemetry_.maxPayloadBytes) {
    telemetry_.maxPayloadBytes = payloadLength_;
  }

  if (opcode_ == static_cast<uint8_t>(BridgeWebSocketOpcode::Text)) {
    telemetry_.textFramesDecoded++;
    payload_[payloadLength_] = '\0';
    return routeTextFrame(nowMs);
  }

  if (opcode_ == static_cast<uint8_t>(BridgeWebSocketOpcode::Binary)) {
    telemetry_.binaryFramesDecoded++;
    if (bridge_ != nullptr && !bridge_->submitBinaryFrame(payload_, payloadLength_, nowMs)) {
      telemetry_.bridgeSubmitsRejected++;
    }
    return true;
  }

  if (opcode_ == static_cast<uint8_t>(BridgeWebSocketOpcode::Close)) {
    telemetry_.closeFramesDecoded++;
    telemetry_.state = BridgeWebSocketTransportState::Closed;
    if (bridge_ != nullptr) {
      bridge_->markDisconnected(nowMs);
    }
    return true;
  }

  if (opcode_ == static_cast<uint8_t>(BridgeWebSocketOpcode::Ping)) {
    telemetry_.pingFramesDecoded++;
    return true;
  }

  if (opcode_ == static_cast<uint8_t>(BridgeWebSocketOpcode::Pong)) {
    telemetry_.pongFramesDecoded++;
    return true;
  }

  return fail("unsupported_websocket_opcode");
}

bool BridgeWebSocketTransport::routeTextFrame(uint32_t nowMs) {
  const char* text = reinterpret_cast<const char*>(payload_);
  if (endpointControl_ != nullptr) {
    endpointResponse_[0] = '\0';
    const BridgeEndpointControlResult result = endpointControl_->submitControlLine(
        text, endpointResponse_, sizeof(endpointResponse_), nowMs);
    if (result != BridgeEndpointControlResult::Ignored) {
      telemetry_.endpointControlFrames++;
      if (endpointResponse_[0] != '\0') {
        queuePendingTextResponse(endpointResponse_);
      }
      return true;
    }
  }

  if (bridge_ != nullptr && !bridge_->submitControlLine(text, nowMs)) {
    telemetry_.bridgeSubmitsRejected++;
  }
  return true;
}

void BridgeWebSocketTransport::queuePendingTextResponse(const char* response) {
  if (response == nullptr || response[0] == '\0') {
    return;
  }
  if (hasPendingTextResponse_) {
    telemetry_.endpointControlResponsesDropped++;
    return;
  }
  copyBounded(pendingTextResponse_, sizeof(pendingTextResponse_), response);
  if (pendingTextResponse_[0] == '\0') {
    telemetry_.endpointControlResponsesDropped++;
    return;
  }
  hasPendingTextResponse_ = true;
  telemetry_.endpointControlResponsesQueued++;
}

bool BridgeWebSocketTransport::fail(const char* reason) {
  telemetry_.state = BridgeWebSocketTransportState::Error;
  telemetry_.frameErrors++;
  copyBounded(telemetry_.lastError, sizeof(telemetry_.lastError), reason);
  resetDecoder();
  return false;
}

bool BridgeWebSocketTransport::rejectHandshake(const char* reason) {
  telemetry_.handshakesRejected++;
  return fail(reason);
}

}  // namespace stackchan
