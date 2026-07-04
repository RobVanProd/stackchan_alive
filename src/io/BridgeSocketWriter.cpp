#include "io/BridgeSocketWriter.hpp"

#include <cstring>

namespace stackchan {

bool BridgeSocketWriter::begin(BridgeWebSocketTransport& transport,
                               BridgeSocketWriterSink& sink,
                               uint32_t maskSeed) {
  transport_ = &transport;
  sink_ = &sink;
  telemetry_ = BridgeSocketWriterTelemetry {};
  maskState_ = maskSeed != 0 ? maskSeed : 0x51ac5eedu;
  clearFrame();
  telemetry_.ready = true;
  return true;
}

void BridgeSocketWriter::reset() {
  telemetry_ = BridgeSocketWriterTelemetry {};
  clearFrame();
  telemetry_.ready = transport_ != nullptr && sink_ != nullptr;
}

BridgeSocketWriterDrainResult BridgeSocketWriter::drainPendingTextResponse(uint32_t nowMs) {
  telemetry_.drainAttempts++;
  if (!telemetry_.ready || transport_ == nullptr || sink_ == nullptr) {
    return fail(BridgeSocketWriterDrainResult::NotReady, "socket_writer_not_ready");
  }
  if (!sink_->isConnected()) {
    return fail(BridgeSocketWriterDrainResult::NotConnected, "socket_not_connected");
  }

  if (frameBytes_ == 0) {
    if (!transport_->hasPendingTextResponse()) {
      telemetry_.lastError[0] = '\0';
      return BridgeSocketWriterDrainResult::NoPending;
    }
    uint8_t maskKey[4] = {};
    makeMask(maskKey);
    frameBytes_ = transport_->encodePendingTextResponseFrame(maskKey, frame_, sizeof(frame_));
    frameOffset_ = 0;
    telemetry_.frameBuffered = frameBytes_ > 0;
    if (frameBytes_ == 0) {
      return fail(BridgeSocketWriterDrainResult::EncodeFailed, "socket_encode_failed");
    }
    telemetry_.framesEncoded++;
  }

  const size_t remaining = frameBytes_ - frameOffset_;
  const size_t written = sink_->write(frame_ + frameOffset_, remaining);
  if (written == 0) {
    telemetry_.writeFailures++;
    copyError("socket_write_failed");
    return BridgeSocketWriterDrainResult::WriteFailed;
  }

  const size_t accepted = written > remaining ? remaining : written;
  frameOffset_ += accepted;
  telemetry_.bytesWritten += static_cast<uint32_t>(accepted);
  telemetry_.lastWriteMs = nowMs;
  telemetry_.lastError[0] = '\0';

  if (frameOffset_ < frameBytes_) {
    telemetry_.partialWrites++;
    telemetry_.frameBuffered = true;
    return BridgeSocketWriterDrainResult::Partial;
  }

  clearFrame();
  telemetry_.framesWritten++;
  return BridgeSocketWriterDrainResult::WroteFrame;
}

uint32_t BridgeSocketWriter::nextMaskWord() {
  uint32_t x = maskState_;
  x ^= x << 13;
  x ^= x >> 17;
  x ^= x << 5;
  maskState_ = x != 0 ? x : 0x51ac5eedu;
  return maskState_;
}

void BridgeSocketWriter::makeMask(uint8_t out[4]) {
  const uint32_t value = nextMaskWord();
  out[0] = static_cast<uint8_t>((value >> 24) & 0xff);
  out[1] = static_cast<uint8_t>((value >> 16) & 0xff);
  out[2] = static_cast<uint8_t>((value >> 8) & 0xff);
  out[3] = static_cast<uint8_t>(value & 0xff);
}

BridgeSocketWriterDrainResult BridgeSocketWriter::fail(BridgeSocketWriterDrainResult result,
                                                       const char* reason) {
  copyError(reason);
  return result;
}

void BridgeSocketWriter::clearFrame() {
  frameBytes_ = 0;
  frameOffset_ = 0;
  telemetry_.frameBuffered = false;
}

void BridgeSocketWriter::copyError(const char* reason) {
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
