#pragma once

#include <stdint.h>

#include "io/BridgeClient.hpp"

namespace stackchan {

struct BridgeAudioDownlinkTelemetry {
  bool ready = false;
  bool active = false;
  uint32_t streamsStarted = 0;
  uint32_t streamsCompleted = 0;
  uint32_t streamsAborted = 0;
  uint32_t chunksAccepted = 0;
  uint32_t bytesAccepted = 0;
  uint32_t errors = 0;
  uint32_t checksum = 0;
  uint32_t lastSeq = 0;
  uint32_t expectedBytes = 0;
  uint32_t expectedChunks = 0;
  uint32_t receivedBytes = 0;
  uint32_t receivedChunks = 0;
  uint32_t lastPayloadBytes = 0;
  uint32_t lastErrorCode = 0;
};

class BridgeAudioDownlink {
 public:
  bool begin();
  bool start(const BridgeAudioStream& stream, uint32_t nowMs);
  bool submitChunk(const BridgeAudioStreamChunk& chunk, uint32_t nowMs);
  bool end(const BridgeAudioStream& stream, uint32_t nowMs);
  void abort(uint32_t nowMs, uint32_t reasonCode = 0);

  const BridgeAudioDownlinkTelemetry& telemetry() const {
    return telemetry_;
  }

 private:
  static uint32_t updateChecksum(uint32_t checksum, const uint8_t* payload, uint32_t length);
  bool fail(uint32_t code);
  void clearActive();

  BridgeAudioDownlinkTelemetry telemetry_;
  BridgeAudioStream activeStream_;
};

}  // namespace stackchan
