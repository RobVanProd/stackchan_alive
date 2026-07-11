#include "io/BridgeNetworkSession.hpp"

#include <cstring>

namespace stackchan {

bool BridgeNetworkSession::begin(BridgeClient& bridge,
                                 BridgeNetworkSocket& socket,
                                 const BridgeNetworkSessionConfig& config,
                                 uint32_t nowMs) {
  bridge_ = &bridge;
  socket_ = &socket;
  config_ = config;
  telemetry_ = BridgeNetworkSessionTelemetry {};
  handshakeBytes_ = 0;
  handshakeResponse_[0] = '\0';
  nextReconnectMs_ = 0;
  telemetry_.ready = bridge.telemetry().ready;
  setState(BridgeNetworkSessionState::Idle, nowMs);
  if (!telemetry_.ready) {
    copyError("bridge_client_not_ready");
    return false;
  }
  writer_.begin(transport_, socket, config_.maskSeed);
  return true;
}

void BridgeNetworkSession::attachEndpointControl(BridgeEndpointControl* endpointControl) {
  endpointControl_ = endpointControl;
  transport_.attachEndpointControl(endpointControl_);
}

bool BridgeNetworkSession::start(uint32_t nowMs) {
  if (!telemetry_.ready || bridge_ == nullptr || socket_ == nullptr) {
    copyError("network_session_not_ready");
    return false;
  }
  if (!isConfigured()) {
    copyError("network_session_not_configured");
    return false;
  }
  return openSocket(nowMs);
}

void BridgeNetworkSession::update(uint32_t nowMs) {
  if (!telemetry_.ready || !config_.enabled) {
    return;
  }

  if (telemetry_.state == BridgeNetworkSessionState::Idle) {
    if (nextReconnectMs_ == 0 || nowMs >= nextReconnectMs_) {
      openSocket(nowMs);
    }
    return;
  }

  if (telemetry_.state == BridgeNetworkSessionState::Backoff) {
    if (nowMs >= nextReconnectMs_) {
      openSocket(nowMs);
    }
    return;
  }

  if (telemetry_.state == BridgeNetworkSessionState::Handshaking) {
    readHandshake(nowMs);
    return;
  }

  if (telemetry_.state == BridgeNetworkSessionState::Connected) {
    if (socket_ == nullptr || !socket_->isConnected()) {
      telemetry_.socketDisconnects++;
      if (bridge_ != nullptr) {
        bridge_->markDisconnected(nowMs);
      }
      scheduleReconnect("socket_disconnected", nowMs);
      return;
    }
    readConnected(nowMs);
    drainWriter(nowMs);
  }
}

void BridgeNetworkSession::stop(uint32_t nowMs) {
  if (socket_ != nullptr) {
    socket_->stop();
  }
  if (bridge_ != nullptr) {
    bridge_->markDisconnected(nowMs);
  }
  setState(BridgeNetworkSessionState::Idle, nowMs);
}

bool BridgeNetworkSession::queueTextFrame(const char* payload) {
  return writer_.queueTextFrame(payload);
}

bool BridgeNetworkSession::queueBinaryFrame(const uint8_t* payload, size_t length) {
  return writer_.queueBinaryFrame(payload, length);
}

bool BridgeNetworkSession::isConfigured() const {
  return config_.enabled && config_.host != nullptr && config_.host[0] != '\0' &&
         config_.port != 0 && config_.secWebSocketKey != nullptr &&
         config_.secWebSocketKey[0] != '\0';
}

bool BridgeNetworkSession::openSocket(uint32_t nowMs) {
  if (!isConfigured() || bridge_ == nullptr || socket_ == nullptr) {
    copyError("network_session_not_configured");
    return false;
  }

  if (!transport_.begin(*bridge_, nowMs)) {
    copyError(transport_.telemetry().lastError);
    setState(BridgeNetworkSessionState::Error, nowMs);
    return false;
  }
  transport_.attachEndpointControl(endpointControl_);
  writer_.begin(transport_, *socket_, config_.maskSeed);

  telemetry_.connectAttempts++;
  setState(BridgeNetworkSessionState::Connecting, nowMs);
  if (!socket_->connect(config_.host, config_.port)) {
    telemetry_.connectFailures++;
    scheduleReconnect("tcp_connect_failed", nowMs);
    return false;
  }
  return sendHandshake(nowMs);
}

bool BridgeNetworkSession::sendHandshake(uint32_t nowMs) {
  char request[kBridgeWebSocketHandshakeMax] = {};
  const size_t requestBytes = BridgeWebSocketTransport::buildHandshakeRequest(
      request,
      sizeof(request),
      config_.host,
      config_.port,
      config_.path,
      config_.secWebSocketKey,
      config_.bridge);
  if (requestBytes == 0) {
    scheduleReconnect("handshake_request_failed", nowMs);
    return false;
  }

  const size_t written = socket_->write(reinterpret_cast<const uint8_t*>(request), requestBytes);
  if (written != requestBytes) {
    scheduleReconnect("handshake_write_failed", nowMs);
    return false;
  }

  handshakeBytes_ = 0;
  handshakeResponse_[0] = '\0';
  telemetry_.bytesWritten += static_cast<uint32_t>(written);
  telemetry_.handshakesSent++;
  setState(BridgeNetworkSessionState::Handshaking, nowMs);
  return true;
}

void BridgeNetworkSession::readHandshake(uint32_t nowMs) {
  if (socket_ == nullptr || !socket_->isConnected()) {
    scheduleReconnect("handshake_socket_disconnected", nowMs);
    return;
  }
  if (nowMs - stateStartMs_ > config_.handshakeTimeoutMs) {
    scheduleReconnect("handshake_timeout", nowMs);
    return;
  }

  while (handshakeBytes_ < sizeof(handshakeResponse_) - 1u) {
    if (socket_->available() <= 0 && handshakeBytes_ > 0) {
      break;
    }
    uint8_t value = 0;
    const int bytes = socket_->read(&value, 1);
    if (bytes <= 0) {
      break;
    }
    handshakeResponse_[handshakeBytes_++] = static_cast<char>(value);
    handshakeResponse_[handshakeBytes_] = '\0';
    telemetry_.bytesRead += static_cast<uint32_t>(bytes);
    if (handshakeComplete()) {
      if (transport_.acceptHandshakeResponse(handshakeResponse_, nowMs)) {
        telemetry_.handshakesAccepted++;
        copyError(nullptr);
        setState(BridgeNetworkSessionState::Connected, nowMs);
      } else {
        telemetry_.handshakesFailed++;
        scheduleReconnect(transport_.telemetry().lastError, nowMs);
      }
      return;
    }
  }

  if (handshakeBytes_ >= sizeof(handshakeResponse_) - 1u) {
    telemetry_.handshakesFailed++;
    scheduleReconnect("handshake_response_too_large", nowMs);
  }
}

void BridgeNetworkSession::readConnected(uint32_t nowMs) {
  if (socket_ == nullptr) {
    return;
  }
  const uint16_t budget = config_.readBudgetBytes == 0 ? kBridgeNetworkReadChunkMax : config_.readBudgetBytes;
  uint16_t consumed = 0;
  while (socket_->available() > 0 && consumed < budget &&
         (bridge_ == nullptr || !bridge_->hasPendingOutput())) {
    const size_t want = (budget - consumed) < sizeof(readChunk_) ? (budget - consumed) : sizeof(readChunk_);
    const int bytes = socket_->read(readChunk_, want);
    if (bytes <= 0) {
      break;
    }
    telemetry_.bytesRead += static_cast<uint32_t>(bytes);
    consumed += static_cast<uint16_t>(bytes);
    if (!transport_.submitBytes(readChunk_, static_cast<size_t>(bytes), nowMs)) {
      scheduleReconnect(transport_.telemetry().lastError, nowMs);
      return;
    }
    if (transport_.telemetry().state == BridgeWebSocketTransportState::Closed) {
      scheduleReconnect("websocket_closed", nowMs);
      return;
    }
  }
}

void BridgeNetworkSession::drainWriter(uint32_t nowMs) {
  for (uint8_t attempt = 0; attempt < 4; ++attempt) {
    const uint32_t beforeFrames = writer_.telemetry().framesWritten;
    const uint32_t beforeTextFrames = writer_.telemetry().textFramesWritten;
    const uint32_t beforeBinaryFrames = writer_.telemetry().binaryFramesWritten;
    const uint32_t beforeBytes = writer_.telemetry().bytesWritten;
    const BridgeSocketWriterDrainResult result = writer_.drainPendingFrame(nowMs);
    telemetry_.writerFrames += writer_.telemetry().framesWritten - beforeFrames;
    telemetry_.writerTextFrames += writer_.telemetry().textFramesWritten - beforeTextFrames;
    telemetry_.writerBinaryFrames += writer_.telemetry().binaryFramesWritten - beforeBinaryFrames;
    telemetry_.bytesWritten += writer_.telemetry().bytesWritten - beforeBytes;
    if (result == BridgeSocketWriterDrainResult::NotConnected ||
        result == BridgeSocketWriterDrainResult::WriteFailed) {
      scheduleReconnect(writer_.telemetry().lastError, nowMs);
      return;
    }
    if (result == BridgeSocketWriterDrainResult::NoPending ||
        result == BridgeSocketWriterDrainResult::NotReady ||
        result == BridgeSocketWriterDrainResult::EncodeFailed) {
      return;
    }
  }
}

void BridgeNetworkSession::scheduleReconnect(const char* reason, uint32_t nowMs) {
  if (socket_ != nullptr) {
    socket_->stop();
  }
  if (bridge_ != nullptr) {
    bridge_->markDisconnected(nowMs);
  }
  nextReconnectMs_ = nowMs + config_.reconnectDelayMs;
  telemetry_.reconnectsScheduled++;
  copyError(reason);
  setState(BridgeNetworkSessionState::Backoff, nowMs);
}

void BridgeNetworkSession::setState(BridgeNetworkSessionState state, uint32_t nowMs) {
  telemetry_.state = state;
  telemetry_.lastStateMs = nowMs;
  stateStartMs_ = nowMs;
}

void BridgeNetworkSession::copyError(const char* reason) {
  if (reason == nullptr) {
    telemetry_.lastError[0] = '\0';
    return;
  }
  const size_t len = std::strlen(reason);
  const size_t copyLen = len < (sizeof(telemetry_.lastError) - 1u) ? len : (sizeof(telemetry_.lastError) - 1u);
  std::memcpy(telemetry_.lastError, reason, copyLen);
  telemetry_.lastError[copyLen] = '\0';
}

bool BridgeNetworkSession::handshakeComplete() const {
  return std::strstr(handshakeResponse_, "\r\n\r\n") != nullptr;
}

}  // namespace stackchan
