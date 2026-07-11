#pragma once

#include <stdint.h>

#include "io/BridgeClient.hpp"

namespace stackchan {

struct BridgeAudioDownlinkTelemetry {
  bool ready = false;
  bool active = false;
  bool playbackEnabled = false;
  bool playbackReady = false;
  bool playbackActive = false;
  uint32_t streamsStarted = 0;
  uint32_t streamsCompleted = 0;
  uint32_t streamsAborted = 0;
  uint32_t chunksAccepted = 0;
  uint32_t bytesAccepted = 0;
  uint32_t errors = 0;
  uint32_t playbackStarts = 0;
  uint32_t playbackChunks = 0;
  uint32_t playbackBytes = 0;
  uint32_t playbackStops = 0;
  uint32_t playbackUnsupported = 0;
  uint32_t playbackErrors = 0;
  uint32_t checksum = 0;
  uint32_t lastSeq = 0;
  uint32_t expectedBytes = 0;
  uint32_t expectedChunks = 0;
  uint32_t receivedBytes = 0;
  uint32_t receivedChunks = 0;
  uint32_t lastPayloadBytes = 0;
  uint32_t lastErrorCode = 0;
};

class BridgeAudioDownlinkSink {
 public:
  virtual ~BridgeAudioDownlinkSink() = default;

  virtual bool begin() = 0;
  virtual bool start(const BridgeAudioStream& stream, uint32_t nowMs) = 0;
  virtual bool writeChunk(const BridgeAudioStreamChunk& chunk, uint32_t nowMs) = 0;
  virtual bool finish(uint32_t nowMs) {
    stop(nowMs);
    return true;
  }
  virtual void stop(uint32_t nowMs) = 0;
  virtual bool isReady() const = 0;
};

class BridgeAudioDownlink {
 public:
  bool begin(bool playbackEnabled = false, BridgeAudioDownlinkSink* sink = nullptr);
  bool start(const BridgeAudioStream& stream, uint32_t nowMs);
  bool submitChunk(const BridgeAudioStreamChunk& chunk, uint32_t nowMs);
  bool end(const BridgeAudioStream& stream, uint32_t nowMs);
  void abort(uint32_t nowMs, uint32_t reasonCode = 0);

  const BridgeAudioDownlinkTelemetry& telemetry() const {
    return telemetry_;
  }

 private:
  static bool isPlayablePcm16Format(const char* format);
  static uint32_t updateChecksum(uint32_t checksum, const uint8_t* payload, uint32_t length);
  bool fail(uint32_t code);
  bool startPlayback(const BridgeAudioStream& stream, uint32_t nowMs);
  void submitPlaybackChunk(const BridgeAudioStreamChunk& chunk, uint32_t nowMs);
  void finishPlayback(uint32_t nowMs);
  void stopPlayback(uint32_t nowMs);
  void clearActive();

  BridgeAudioDownlinkTelemetry telemetry_;
  BridgeAudioStream activeStream_;
  BridgeAudioDownlinkSink* sink_ = nullptr;
};

}  // namespace stackchan
