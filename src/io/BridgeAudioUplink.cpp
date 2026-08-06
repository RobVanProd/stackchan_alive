#include "io/BridgeAudioUplink.hpp"

#include <stdio.h>
#include <string.h>

namespace stackchan {

bool BridgeAudioUplink::begin(const BridgeAudioUplinkConfig& config,
                              BridgeNetworkSession* session) {
  config_ = config;
  session_ = session;
  telemetry_ = BridgeAudioUplinkTelemetry {};
  telemetry_.enabled = config_.enabled;
  telemetry_.wakeGateRequired = config_.wakeGateRequired;
  telemetry_.ready = true;

  if (!config_.enabled) {
    copyError("audio_uplink_disabled");
    return true;
  }
  if (session_ == nullptr) {
    telemetry_.ready = false;
    return fail("audio_uplink_session_missing");
  }
  if (config_.sampleRate == 0 || config_.maxAudioBytes == 0 ||
      config_.maxChunkBytes == 0 || config_.terminalRetryMs == 0 ||
      config_.maxChunkBytes > kBridgeAudioStreamChunkPayloadMax) {
    telemetry_.ready = false;
    return fail("audio_uplink_bad_config");
  }

  telemetry_.lastError[0] = '\0';
  pendingTerminalSeq_ = 0;
  pendingTerminalReason_[0] = '\0';
  return true;
}

void BridgeAudioUplink::reset() {
  const bool ready = config_.enabled ? session_ != nullptr : true;
  telemetry_ = BridgeAudioUplinkTelemetry {};
  telemetry_.ready = ready;
  telemetry_.enabled = config_.enabled;
  telemetry_.wakeGateRequired = config_.wakeGateRequired;
  pendingTerminalSeq_ = 0;
  pendingTerminalReason_[0] = '\0';
  if (!config_.enabled) {
    copyError("audio_uplink_disabled");
  }
}

bool BridgeAudioUplink::beginTurn(uint32_t seq, uint32_t nowMs, bool wakeGateOpen) {
  (void)nowMs;
  if (!configured()) {
    return fail("audio_uplink_not_ready");
  }
  if (!config_.enabled) {
    return fail("audio_uplink_disabled");
  }
  if (session_ == nullptr) {
    return fail("audio_uplink_session_missing");
  }
  if (telemetry_.active || telemetry_.terminalPending) {
    return fail("audio_uplink_already_active");
  }
  if (config_.wakeGateRequired && !wakeGateOpen) {
    telemetry_.gateBlocks++;
    return fail("wake_gate_closed");
  }

  char frame[kBridgeEndpointControlResponseMax] = {};
  if (!writeStartFrame(seq, frame, sizeof(frame)) || !queueText(frame)) {
    telemetry_.queueFailures++;
    return fail("utterance_start_queue_failed");
  }

  telemetry_.active = true;
  telemetry_.turnsStarted++;
  telemetry_.lastSeq = seq;
  telemetry_.activeBytes = 0;
  telemetry_.activeChunks = 0;
  telemetry_.lastTerminal = BridgeAudioTerminalKind::None;
  telemetry_.lastError[0] = '\0';
  return true;
}

bool BridgeAudioUplink::submitPcmChunk(uint32_t seq,
                                       const int16_t* samples,
                                       uint16_t sampleCount,
                                       uint32_t nowMs) {
  if (samples == nullptr || sampleCount == 0) {
    return fail("audio_uplink_bad_payload");
  }
  const size_t bytes = static_cast<size_t>(sampleCount) * sizeof(int16_t);
  return submitPcmBytes(seq, reinterpret_cast<const uint8_t*>(samples), bytes, nowMs);
}

bool BridgeAudioUplink::submitPcmBytes(uint32_t seq,
                                       const uint8_t* payload,
                                       size_t length,
                                       uint32_t nowMs) {
  (void)nowMs;
  if (!configured()) {
    return fail("audio_uplink_not_ready");
  }
  if (!config_.enabled) {
    return fail("audio_uplink_disabled");
  }
  if (!telemetry_.active) {
    return fail("audio_uplink_not_active");
  }
  if (seq != 0 && telemetry_.lastSeq != 0 && seq != telemetry_.lastSeq) {
    return fail("audio_uplink_seq_mismatch");
  }
  if (payload == nullptr || length == 0) {
    return fail("audio_uplink_bad_payload");
  }
  if (length > config_.maxChunkBytes) {
    return fail("audio_uplink_chunk_too_large");
  }
  if (length > static_cast<size_t>(config_.maxAudioBytes) ||
      telemetry_.activeBytes > config_.maxAudioBytes - static_cast<uint32_t>(length)) {
    return fail("audio_uplink_byte_limit");
  }
  if (!queueBinary(payload, length)) {
    telemetry_.queueFailures++;
    return fail("audio_chunk_queue_failed");
  }

  telemetry_.activeBytes += static_cast<uint32_t>(length);
  telemetry_.activeChunks++;
  telemetry_.chunksQueued++;
  telemetry_.bytesQueued += static_cast<uint32_t>(length);
  telemetry_.lastSeq = seq;
  telemetry_.lastError[0] = '\0';
  return true;
}

bool BridgeAudioUplink::endTurn(uint32_t seq, uint32_t nowMs) {
  if (!configured()) {
    return fail("audio_uplink_not_ready");
  }
  if (!config_.enabled) {
    return fail("audio_uplink_disabled");
  }
  if (!telemetry_.active) {
    return fail("audio_uplink_not_active");
  }
  if (seq != 0 && telemetry_.lastSeq != 0 && seq != telemetry_.lastSeq) {
    return fail("audio_uplink_seq_mismatch");
  }

  return requestTerminal(BridgeAudioTerminalKind::End, seq, nowMs, nullptr);
}

void BridgeAudioUplink::abort(uint32_t nowMs, const char* reason) {
  if (!telemetry_.active && !telemetry_.terminalPending) {
    copyError(reason != nullptr ? reason : "audio_uplink_aborted");
    return;
  }
  requestTerminal(BridgeAudioTerminalKind::Cancel,
                  telemetry_.lastSeq,
                  nowMs,
                  reason != nullptr ? reason : "audio_uplink_aborted");
}

BridgeAudioTerminalServiceResult BridgeAudioUplink::servicePendingTerminal(uint32_t nowMs) {
  if (!telemetry_.terminalPending) {
    return BridgeAudioTerminalServiceResult::Idle;
  }

  char frame[kBridgeEndpointControlResponseMax] = {};
  const bool encoded = telemetry_.pendingTerminal == BridgeAudioTerminalKind::End
                           ? writeEndFrame(pendingTerminalSeq_, frame, sizeof(frame))
                           : writeCancelFrame(pendingTerminalSeq_,
                                              pendingTerminalReason_,
                                              frame,
                                              sizeof(frame));
  telemetry_.terminalAttempts++;
  if (encoded && queueText(frame)) {
    const BridgeAudioTerminalKind delivered = telemetry_.pendingTerminal;
    telemetry_.terminalPending = false;
    telemetry_.pendingTerminal = BridgeAudioTerminalKind::None;
    telemetry_.lastTerminal = delivered;
    telemetry_.lastSeq = pendingTerminalSeq_;
    if (delivered == BridgeAudioTerminalKind::End) {
      telemetry_.turnsCompleted++;
      telemetry_.lastError[0] = '\0';
    } else {
      telemetry_.turnsAborted++;
      telemetry_.cancelFramesQueued++;
      copyError(pendingTerminalReason_);
    }
    return BridgeAudioTerminalServiceResult::Queued;
  }

  telemetry_.queueFailures++;
  telemetry_.terminalRetries++;
  if (nowMs - telemetry_.terminalRequestedAtMs < config_.terminalRetryMs) {
    copyError("utterance_terminal_queue_pending");
    return BridgeAudioTerminalServiceResult::Pending;
  }

  if (session_ != nullptr) {
    session_->stop(nowMs);
  }
  telemetry_.terminalTimeouts++;
  telemetry_.turnsAborted++;
  telemetry_.terminalPending = false;
  telemetry_.pendingTerminal = BridgeAudioTerminalKind::None;
  telemetry_.lastTerminal = BridgeAudioTerminalKind::Cancel;
  fail("utterance_terminal_delivery_timeout");
  return BridgeAudioTerminalServiceResult::FailedClosed;
}

bool BridgeAudioUplink::configured() const {
  return telemetry_.ready;
}

bool BridgeAudioUplink::queueText(const char* payload) {
  return session_ != nullptr && session_->queueTextFrame(payload);
}

bool BridgeAudioUplink::queueBinary(const uint8_t* payload, size_t length) {
  return session_ != nullptr && session_->queueBinaryFrame(payload, length);
}

bool BridgeAudioUplink::writeStartFrame(uint32_t seq, char* out, size_t outSize) const {
  if (out == nullptr || outSize == 0) {
    return false;
  }
  const int written = snprintf(out,
                               outSize,
                               "{\"type\":\"utterance_start\",\"seq\":%lu,\"format\":\"pcm16\","
                               "\"sample_rate\":%lu}",
                               static_cast<unsigned long>(seq),
                               static_cast<unsigned long>(config_.sampleRate));
  return written > 0 && static_cast<size_t>(written) < outSize;
}

bool BridgeAudioUplink::writeEndFrame(uint32_t seq, char* out, size_t outSize) const {
  if (out == nullptr || outSize == 0) {
    return false;
  }
  const int written = snprintf(out,
                               outSize,
                               "{\"type\":\"utterance_end\",\"seq\":%lu,\"audio_bytes\":%lu,"
                               "\"chunks\":%lu}",
                               static_cast<unsigned long>(seq),
                               static_cast<unsigned long>(telemetry_.activeBytes),
                               static_cast<unsigned long>(telemetry_.activeChunks));
  return written > 0 && static_cast<size_t>(written) < outSize;
}

bool BridgeAudioUplink::writeCancelFrame(uint32_t seq,
                                         const char* reason,
                                         char* out,
                                         size_t outSize) const {
  if (out == nullptr || outSize == 0 || reason == nullptr || reason[0] == '\0') {
    return false;
  }
  const int written = snprintf(out,
                               outSize,
                               "{\"type\":\"utterance_cancel\",\"seq\":%lu,"
                               "\"reason\":\"%s\",\"audio_bytes\":%lu,\"chunks\":%lu}",
                               static_cast<unsigned long>(seq),
                               reason,
                               static_cast<unsigned long>(telemetry_.activeBytes),
                               static_cast<unsigned long>(telemetry_.activeChunks));
  return written > 0 && static_cast<size_t>(written) < outSize;
}

bool BridgeAudioUplink::requestTerminal(BridgeAudioTerminalKind kind,
                                        uint32_t seq,
                                        uint32_t nowMs,
                                        const char* reason) {
  if (kind == BridgeAudioTerminalKind::None) {
    return fail("audio_uplink_bad_terminal");
  }

  const uint32_t resolvedSeq = seq != 0 ? seq : telemetry_.lastSeq;
  const bool alreadyPending = telemetry_.terminalPending;
  telemetry_.active = false;
  telemetry_.terminalPending = true;
  telemetry_.pendingTerminal = kind;
  if (!alreadyPending) {
    telemetry_.terminalRequestedAtMs = nowMs;
  }
  pendingTerminalSeq_ = resolvedSeq;
  copyTerminalReason(reason != nullptr ? reason : "audio_uplink_aborted");
  const BridgeAudioTerminalServiceResult result = servicePendingTerminal(nowMs);
  return result == BridgeAudioTerminalServiceResult::Queued ||
         result == BridgeAudioTerminalServiceResult::Pending;
}

void BridgeAudioUplink::copyTerminalReason(const char* reason) {
  if (reason == nullptr) {
    pendingTerminalReason_[0] = '\0';
    return;
  }
  size_t out = 0;
  while (reason[out] != '\0' && out < sizeof(pendingTerminalReason_) - 1u) {
    const char value = reason[out];
    const bool safe = (value >= 'a' && value <= 'z') ||
                      (value >= 'A' && value <= 'Z') ||
                      (value >= '0' && value <= '9') ||
                      value == '_' || value == '-' || value == '.' || value == ':';
    pendingTerminalReason_[out] = safe ? value : '_';
    ++out;
  }
  pendingTerminalReason_[out] = '\0';
  if (out == 0) {
    copyTerminalReason("audio_uplink_aborted");
  }
}

bool BridgeAudioUplink::fail(const char* reason) {
  telemetry_.errors++;
  copyError(reason);
  return false;
}

void BridgeAudioUplink::copyError(const char* reason) {
  if (reason == nullptr) {
    telemetry_.lastError[0] = '\0';
    return;
  }
  const size_t length = strlen(reason);
  const size_t copyLength = length < (sizeof(telemetry_.lastError) - 1u)
                                ? length
                                : (sizeof(telemetry_.lastError) - 1u);
  memcpy(telemetry_.lastError, reason, copyLength);
  telemetry_.lastError[copyLength] = '\0';
}

}  // namespace stackchan
