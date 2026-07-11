#pragma once

#include <Arduino.h>
#include <stddef.h>
#include <stdint.h>

#include "io/AudioOut.hpp"
#include "persona/EventBus.hpp"
#include "persona/StateMatrix.hpp"

namespace stackchan {

constexpr size_t kBridgeSessionIdMax = 32;
constexpr size_t kBridgeTextMax = 160;
constexpr size_t kBridgeErrorMax = 64;
constexpr size_t kBridgeAudioFormatMax = 16;
constexpr size_t kBridgeAudioStreamChunkPayloadMax = 4096;
#ifndef STACKCHAN_BRIDGE_CLIENT_OUTPUT_QUEUE_DEPTH
#define STACKCHAN_BRIDGE_CLIENT_OUTPUT_QUEUE_DEPTH 8
#endif
constexpr size_t kBridgeClientOutputQueueDepth = STACKCHAN_BRIDGE_CLIENT_OUTPUT_QUEUE_DEPTH;

enum class BridgeClientState : uint8_t {
  Offline,
  Connecting,
  Ready,
  Listening,
  Thinking,
  Responding,
  Error,
};

enum class BridgeClientOutputType : uint8_t {
  None,
  SessionReady,
  Event,
  ResponseStart,
  AudioFrame,
  AudioStreamStart,
  AudioStreamChunk,
  AudioStreamEnd,
  ResponseEnd,
  Error,
};

struct BridgeClientConfig {
  const char* deviceId = "stackchan";
  const char* protocolVersion = "stackchan.bridge.v1";
  uint16_t controlPort = 8788;
  uint16_t audioSampleRate = 16000;
  uint32_t responseTimeoutMs = 2500;
  bool wakeWordGateRequired = true;
};

struct BridgeResponseChunk {
  uint32_t seq = 0;
  SpeechIntent intent = SpeechIntent::Speak;
  float arousal = 0.45f;
  float valence = 0.45f;
  char text[kBridgeTextMax] = {};
};

struct BridgeAudioChunk {
  uint32_t seq = 0;
  float envelope = 0.0f;
  AudioOutViseme viseme = AudioOutViseme::Neutral;
  uint16_t durationMs = 20;
  bool finalChunk = false;
};

struct BridgeAudioStream {
  uint32_t seq = 0;
  uint32_t sampleRate = 0;
  uint32_t audioBytes = 0;
  uint32_t chunkBytes = 0;
  uint32_t chunks = 0;
  char format[kBridgeAudioFormatMax] = {};
};

struct BridgeAudioStreamChunk {
  uint32_t seq = 0;
  uint32_t index = 0;
  uint32_t bytes = 0;
  uint32_t payloadBytes = 0;
  uint32_t receivedBytes = 0;
  uint32_t checksum = 0;
  bool finalChunk = false;
  const uint8_t* payload = nullptr;
};

struct BridgeClientOutput {
  BridgeClientOutputType type = BridgeClientOutputType::None;
  RobotEvent event;
  BridgeResponseChunk response;
  BridgeAudioChunk audio;
  BridgeAudioStream stream;
  BridgeAudioStreamChunk streamChunk;
  char sessionId[kBridgeSessionIdMax] = {};
  char error[kBridgeErrorMax] = {};
};

struct BridgeClientTelemetry {
  bool ready = false;
  bool configured = false;
  bool taskPinnedToCore0 = false;
  BridgeClientState state = BridgeClientState::Offline;
  uint32_t inboundMessages = 0;
  uint32_t outputsQueued = 0;
  uint32_t outputsDropped = 0;
  uint32_t parseErrors = 0;
  uint32_t timeouts = 0;
  uint32_t heartbeats = 0;
  uint32_t audioStreamsStarted = 0;
  uint32_t audioStreamsEnded = 0;
  uint32_t audioStreamBytes = 0;
  uint32_t audioStreamBytesReceived = 0;
  uint32_t audioStreamChunksExpected = 0;
  uint32_t audioStreamChunksReceived = 0;
  uint32_t audioStreamErrors = 0;
  uint32_t audioStreamChecksum = 0;
  bool audioStreamActive = false;
  uint32_t lastSeq = 0;
  uint32_t lastMessageMs = 0;
};

class BridgeClient {
 public:
  bool begin(const BridgeClientConfig& config = BridgeClientConfig {});
  void markConnecting(uint32_t nowMs);
  void markDisconnected(uint32_t nowMs);

  bool update(uint32_t nowMs);
  bool submitControlLine(const char* jsonLine, uint32_t nowMs);
  bool submitBinaryFrame(const uint8_t* payload, size_t length, uint32_t nowMs);
  bool poll(BridgeClientOutput* outputOut);
  bool hasPendingOutput() const {
    return outputCount_ > 0;
  }

  const BridgeClientTelemetry& telemetry() const {
    return telemetry_;
  }

 private:
  static bool readStringField(const char* line, const char* key, char* out, size_t outSize);
  static bool readUintField(const char* line, const char* key, uint32_t* out);
  static bool readFloatField(const char* line, const char* key, float* out);
  static bool readBoolField(const char* line, const char* key, bool* out);
  static SpeechIntent intentFromString(const char* value);
  static AudioOutViseme visemeFromString(const char* value);
  static float clamp01(float value);
  static uint16_t clampDuration(uint32_t value);
  static void copyBounded(char* out, size_t outSize, const char* value);

  void queueOutput(const BridgeClientOutput& output);
  void clearAudioStream();
  bool failAudioStream(const char* reason);
  bool failParse(const char* reason);
  bool failTimeout(uint32_t nowMs);

  BridgeClientConfig config_;
  BridgeClientTelemetry telemetry_;
  BridgeClientOutput outputQueue_[kBridgeClientOutputQueueDepth] {};
  uint8_t outputPayloads_[kBridgeClientOutputQueueDepth][kBridgeAudioStreamChunkPayloadMax] {};
  BridgeAudioStream activeStream_;
  size_t outputHead_ = 0;
  size_t outputTail_ = 0;
  size_t outputCount_ = 0;
  uint32_t activeStreamBytesReceived_ = 0;
  uint32_t activeStreamChunksReceived_ = 0;
  uint32_t activeStreamChecksum_ = 0;
  bool audioStreamActive_ = false;
};

}  // namespace stackchan
