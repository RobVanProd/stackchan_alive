#include "io/BridgeAudioDownlink.hpp"

namespace stackchan {
namespace {
constexpr uint32_t kChecksumSeed = 2166136261u;
constexpr uint32_t kErrorNotReady = 1;
constexpr uint32_t kErrorNestedStream = 2;
constexpr uint32_t kErrorChunkWithoutStream = 3;
constexpr uint32_t kErrorInvalidPayload = 4;
constexpr uint32_t kErrorSeqMismatch = 5;
constexpr uint32_t kErrorByteOverrun = 6;
constexpr uint32_t kErrorChunkOverrun = 7;
constexpr uint32_t kErrorEndWithoutStream = 8;
constexpr uint32_t kErrorEndMismatch = 9;
}  // namespace

bool BridgeAudioDownlink::begin() {
  telemetry_ = BridgeAudioDownlinkTelemetry {};
  activeStream_ = BridgeAudioStream {};
  telemetry_.ready = true;
  return true;
}

bool BridgeAudioDownlink::start(const BridgeAudioStream& stream, uint32_t nowMs) {
  (void)nowMs;
  if (!telemetry_.ready) {
    return fail(kErrorNotReady);
  }
  if (telemetry_.active) {
    return fail(kErrorNestedStream);
  }

  activeStream_ = stream;
  telemetry_.active = true;
  telemetry_.streamsStarted++;
  telemetry_.lastSeq = stream.seq;
  telemetry_.expectedBytes = stream.audioBytes;
  telemetry_.expectedChunks = stream.chunks;
  telemetry_.receivedBytes = 0;
  telemetry_.receivedChunks = 0;
  telemetry_.lastPayloadBytes = 0;
  telemetry_.checksum = 0;
  telemetry_.lastErrorCode = 0;
  return true;
}

bool BridgeAudioDownlink::submitChunk(const BridgeAudioStreamChunk& chunk, uint32_t nowMs) {
  (void)nowMs;
  if (!telemetry_.ready) {
    return fail(kErrorNotReady);
  }
  if (!telemetry_.active) {
    return fail(kErrorChunkWithoutStream);
  }
  if (chunk.seq != 0 && activeStream_.seq != 0 && chunk.seq != activeStream_.seq) {
    return fail(kErrorSeqMismatch);
  }
  if (chunk.payload == nullptr || chunk.payloadBytes == 0 || chunk.payloadBytes != chunk.bytes ||
      chunk.payloadBytes > kBridgeAudioStreamChunkPayloadMax) {
    return fail(kErrorInvalidPayload);
  }

  const uint32_t nextBytes = telemetry_.receivedBytes + chunk.payloadBytes;
  const uint32_t nextChunks = telemetry_.receivedChunks + 1u;
  if (nextBytes < telemetry_.receivedBytes ||
      (activeStream_.audioBytes != 0 && nextBytes > activeStream_.audioBytes)) {
    return fail(kErrorByteOverrun);
  }
  if (nextChunks < telemetry_.receivedChunks ||
      (activeStream_.chunks != 0 && nextChunks > activeStream_.chunks)) {
    return fail(kErrorChunkOverrun);
  }

  telemetry_.receivedBytes = nextBytes;
  telemetry_.receivedChunks = nextChunks;
  telemetry_.lastPayloadBytes = chunk.payloadBytes;
  telemetry_.bytesAccepted += chunk.payloadBytes;
  telemetry_.chunksAccepted++;
  telemetry_.checksum = updateChecksum(telemetry_.checksum, chunk.payload, chunk.payloadBytes);
  telemetry_.lastSeq = activeStream_.seq;
  return true;
}

bool BridgeAudioDownlink::end(const BridgeAudioStream& stream, uint32_t nowMs) {
  (void)nowMs;
  if (!telemetry_.ready) {
    return fail(kErrorNotReady);
  }
  if (!telemetry_.active) {
    return fail(kErrorEndWithoutStream);
  }
  const bool seqMatches = stream.seq == 0 || activeStream_.seq == 0 || stream.seq == activeStream_.seq;
  const bool bytesMatch = activeStream_.audioBytes == 0 || telemetry_.receivedBytes == activeStream_.audioBytes;
  const bool chunksMatch = activeStream_.chunks == 0 || telemetry_.receivedChunks == activeStream_.chunks;
  if (!seqMatches || !bytesMatch || !chunksMatch) {
    clearActive();
    return fail(kErrorEndMismatch);
  }

  telemetry_.streamsCompleted++;
  clearActive();
  return true;
}

void BridgeAudioDownlink::abort(uint32_t nowMs, uint32_t reasonCode) {
  (void)nowMs;
  if (telemetry_.active) {
    telemetry_.streamsAborted++;
  }
  clearActive();
  telemetry_.lastErrorCode = reasonCode;
}

uint32_t BridgeAudioDownlink::updateChecksum(uint32_t checksum, const uint8_t* payload, uint32_t length) {
  uint32_t result = checksum == 0 ? kChecksumSeed : checksum;
  for (uint32_t i = 0; i < length; ++i) {
    result ^= payload[i];
    result *= 16777619u;
  }
  return result;
}

bool BridgeAudioDownlink::fail(uint32_t code) {
  telemetry_.errors++;
  telemetry_.lastErrorCode = code;
  return false;
}

void BridgeAudioDownlink::clearActive() {
  activeStream_ = BridgeAudioStream {};
  telemetry_.active = false;
}

}  // namespace stackchan
