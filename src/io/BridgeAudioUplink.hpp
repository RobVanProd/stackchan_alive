#pragma once

#include <stddef.h>
#include <stdint.h>

#include "io/BridgeClient.hpp"
#include "io/BridgeNetworkSession.hpp"

namespace stackchan {

#ifndef STACKCHAN_ENABLE_BRIDGE_AUDIO_UPLINK
#define STACKCHAN_ENABLE_BRIDGE_AUDIO_UPLINK 0
#endif

constexpr uint32_t kBridgeAudioUplinkSampleRate = 16000;
constexpr uint32_t kBridgeAudioUplinkMaxBytes = 512u * 1024u;
constexpr size_t kBridgeAudioUplinkErrorMax = kBridgeErrorMax;

struct BridgeAudioUplinkConfig {
  bool enabled = STACKCHAN_ENABLE_BRIDGE_AUDIO_UPLINK != 0;
  bool wakeGateRequired = true;  // privacy gate: audio may leave only after wake/explicit activation.
  uint32_t sampleRate = kBridgeAudioUplinkSampleRate;
  uint32_t maxAudioBytes = kBridgeAudioUplinkMaxBytes;
  uint16_t maxChunkBytes = kBridgeAudioStreamChunkPayloadMax;
};

struct BridgeAudioUplinkTelemetry {
  bool ready = false;
  bool enabled = false;
  bool active = false;
  bool wakeGateRequired = true;
  uint32_t turnsStarted = 0;
  uint32_t turnsCompleted = 0;
  uint32_t turnsAborted = 0;
  uint32_t chunksQueued = 0;
  uint32_t bytesQueued = 0;
  uint32_t queueFailures = 0;
  uint32_t gateBlocks = 0;
  uint32_t errors = 0;
  uint32_t lastSeq = 0;
  uint32_t activeBytes = 0;
  uint32_t activeChunks = 0;
  char lastError[kBridgeAudioUplinkErrorMax] = {};
};

class BridgeAudioUplink {
 public:
  bool begin(const BridgeAudioUplinkConfig& config = BridgeAudioUplinkConfig {},
             BridgeNetworkSession* session = nullptr);
  void reset();

  bool beginTurn(uint32_t seq, uint32_t nowMs, bool wakeGateOpen);
  bool submitPcmChunk(uint32_t seq, const int16_t* samples, uint16_t sampleCount, uint32_t nowMs);
  bool submitPcmBytes(uint32_t seq, const uint8_t* payload, size_t length, uint32_t nowMs);
  bool endTurn(uint32_t seq, uint32_t nowMs);
  void abort(uint32_t nowMs, const char* reason = nullptr);

  const BridgeAudioUplinkTelemetry& telemetry() const {
    return telemetry_;
  }

 private:
  bool configured() const;
  bool queueText(const char* payload);
  bool queueBinary(const uint8_t* payload, size_t length);
  bool writeStartFrame(uint32_t seq, char* out, size_t outSize) const;
  bool writeEndFrame(uint32_t seq, char* out, size_t outSize) const;
  bool fail(const char* reason);
  void copyError(const char* reason);

  BridgeAudioUplinkConfig config_;
  BridgeAudioUplinkTelemetry telemetry_;
  BridgeNetworkSession* session_ = nullptr;
};

}  // namespace stackchan
