#include "io/BridgeClient.hpp"

#include <cstdio>
#include <cstdlib>
#include <cstring>

namespace stackchan {

namespace {
constexpr const char* kBridgeProtocolMarker = "stackchan.bridge.v1";
constexpr uint32_t kAudioStreamChecksumSeed = 2166136261u;

bool isTimeoutState(BridgeClientState state) {
  return state == BridgeClientState::Connecting ||
         state == BridgeClientState::Listening ||
         state == BridgeClientState::Thinking ||
         state == BridgeClientState::Responding;
}

uint32_t updateAudioStreamChecksum(uint32_t checksum, const uint8_t* payload, size_t length) {
  uint32_t result = checksum == 0 ? kAudioStreamChecksumSeed : checksum;
  for (size_t i = 0; i < length; ++i) {
    result ^= payload[i];
    result *= 16777619u;
  }
  return result;
}

bool isFatalRemoteError(const char* code) {
  return code != nullptr && std::strcmp(code, "bridge_closed") == 0;
}
}

bool BridgeClient::begin(const BridgeClientConfig& config) {
  telemetry_ = BridgeClientTelemetry {};
  for (size_t i = 0; i < kBridgeClientOutputQueueDepth; ++i) {
    outputQueue_[i] = BridgeClientOutput {};
  }
  outputHead_ = 0;
  outputTail_ = 0;
  outputCount_ = 0;
  clearAudioStream();
  config_ = config;

  telemetry_.configured = config_.deviceId != nullptr && config_.deviceId[0] != '\0' &&
                          config_.protocolVersion != nullptr &&
                          std::strcmp(config_.protocolVersion, kBridgeProtocolMarker) == 0;
  telemetry_.ready = telemetry_.configured;
  telemetry_.taskPinnedToCore0 = true;
  telemetry_.state = telemetry_.ready ? BridgeClientState::Offline : BridgeClientState::Error;
  return telemetry_.ready;
}

void BridgeClient::markConnecting(uint32_t nowMs) {
  if (!telemetry_.ready) {
    return;
  }
  telemetry_.state = BridgeClientState::Connecting;
  telemetry_.lastMessageMs = nowMs;
}

void BridgeClient::markDisconnected(uint32_t nowMs) {
  if (!telemetry_.ready) {
    return;
  }
  telemetry_.state = BridgeClientState::Offline;
  telemetry_.lastMessageMs = nowMs;
  for (size_t i = 0; i < kBridgeClientOutputQueueDepth; ++i) {
    outputQueue_[i] = BridgeClientOutput {};
  }
  outputHead_ = 0;
  outputTail_ = 0;
  outputCount_ = 0;
  clearAudioStream();
}

bool BridgeClient::update(uint32_t nowMs) {
  if (!telemetry_.ready || config_.responseTimeoutMs == 0 || outputCount_ > 0) {
    return false;
  }
  if (!isTimeoutState(telemetry_.state)) {
    return false;
  }
  if (nowMs - telemetry_.lastMessageMs < config_.responseTimeoutMs) {
    return false;
  }
  return failTimeout(nowMs);
}

bool BridgeClient::submitControlLine(const char* jsonLine, uint32_t nowMs) {
  if (!telemetry_.ready || jsonLine == nullptr || jsonLine[0] == '\0') {
    return false;
  }

  telemetry_.inboundMessages++;
  telemetry_.lastMessageMs = nowMs;

  char type[24] = {};
  if (!readStringField(jsonLine, "type", type, sizeof(type))) {
    return failParse("missing_type");
  }

  BridgeClientOutput output;
  output.event.timestampMs = nowMs;
  output.event.strength = 1.0f;

  uint32_t seq = 0;
  readUintField(jsonLine, "seq", &seq);
  telemetry_.lastSeq = seq;

  if (std::strcmp(type, "hello") == 0) {
    telemetry_.state = BridgeClientState::Ready;
    output.type = BridgeClientOutputType::SessionReady;
    readStringField(jsonLine, "session", output.sessionId, sizeof(output.sessionId));
    queueOutput(output);
    return true;
  }

  if (std::strcmp(type, "listening") == 0) {
    telemetry_.state = BridgeClientState::Listening;
    output.type = BridgeClientOutputType::Event;
    output.event.type = EventType::UserSpeaking;
    queueOutput(output);
    return true;
  }

  if (std::strcmp(type, "thinking") == 0) {
    telemetry_.state = BridgeClientState::Thinking;
    output.type = BridgeClientOutputType::Event;
    output.event.type = EventType::ThinkingStarted;
    queueOutput(output);
    return true;
  }

  if (std::strcmp(type, "response_start") == 0) {
    telemetry_.state = BridgeClientState::Responding;
    output.type = BridgeClientOutputType::ResponseStart;
    output.event.type = EventType::ResponseStarted;
    output.response.seq = seq;
    output.response.intent = SpeechIntent::Speak;
    output.response.arousal = 0.45f;
    output.response.valence = 0.45f;
    readStringField(jsonLine, "text", output.response.text, sizeof(output.response.text));
    char intent[24] = {};
    if (readStringField(jsonLine, "intent", intent, sizeof(intent))) {
      output.response.intent = intentFromString(intent);
    }
    readFloatField(jsonLine, "arousal", &output.response.arousal);
    readFloatField(jsonLine, "valence", &output.response.valence);
    output.response.arousal = clamp01(output.response.arousal);
    output.response.valence = constrain(output.response.valence, -1.0f, 1.0f);
    queueOutput(output);
    return true;
  }

  if (std::strcmp(type, "audio") == 0) {
    output.type = BridgeClientOutputType::AudioFrame;
    output.audio.seq = seq;
    uint32_t durationMs = 20;
    output.audio.envelope = 0.0f;
    readFloatField(jsonLine, "env", &output.audio.envelope);
    output.audio.envelope = clamp01(output.audio.envelope);
    readUintField(jsonLine, "duration_ms", &durationMs);
    output.audio.durationMs = clampDuration(durationMs);
    char viseme[16] = {};
    if (readStringField(jsonLine, "viseme", viseme, sizeof(viseme))) {
      output.audio.viseme = visemeFromString(viseme);
    }
    readBoolField(jsonLine, "final", &output.audio.finalChunk);
    queueOutput(output);
    return true;
  }

  if (std::strcmp(type, "audio_stream_start") == 0) {
    if (audioStreamActive_) {
      return failAudioStream("nested_audio_stream");
    }
    telemetry_.state = BridgeClientState::Responding;
    output.type = BridgeClientOutputType::AudioStreamStart;
    output.stream.seq = seq;
    readUintField(jsonLine, "sample_rate", &output.stream.sampleRate);
    readUintField(jsonLine, "audio_bytes", &output.stream.audioBytes);
    readUintField(jsonLine, "chunk_bytes", &output.stream.chunkBytes);
    readUintField(jsonLine, "chunks", &output.stream.chunks);
    readStringField(jsonLine, "format", output.stream.format, sizeof(output.stream.format));
    if (output.stream.chunkBytes > kBridgeAudioStreamChunkPayloadMax) {
      return failAudioStream("audio_stream_chunk_too_large");
    }
    activeStream_ = output.stream;
    activeStreamBytesReceived_ = 0;
    activeStreamChunksReceived_ = 0;
    activeStreamChecksum_ = kAudioStreamChecksumSeed;
    audioStreamActive_ = true;
    telemetry_.audioStreamActive = true;
    telemetry_.audioStreamsStarted++;
    telemetry_.audioStreamBytes += output.stream.audioBytes;
    telemetry_.audioStreamChunksExpected += output.stream.chunks;
    queueOutput(output);
    return true;
  }

  if (std::strcmp(type, "audio_stream_end") == 0) {
    if (!audioStreamActive_) {
      return failAudioStream("audio_stream_end_without_start");
    }
    if (activeStream_.seq != 0 && seq != 0 && activeStream_.seq != seq) {
      return failAudioStream("audio_stream_seq_mismatch");
    }

    output.type = BridgeClientOutputType::AudioStreamEnd;
    output.stream = activeStream_;

    uint32_t endBytes = activeStream_.audioBytes;
    uint32_t endChunks = activeStream_.chunks;
    const bool hasEndBytes = readUintField(jsonLine, "audio_bytes", &endBytes);
    const bool hasEndChunks = readUintField(jsonLine, "chunks", &endChunks);
    output.stream.audioBytes = endBytes;
    output.stream.chunks = endChunks;

    if (hasEndBytes && activeStream_.audioBytes != 0 && endBytes != activeStream_.audioBytes) {
      return failAudioStream("audio_stream_end_bytes_mismatch");
    }
    if (hasEndChunks && activeStream_.chunks != 0 && endChunks != activeStream_.chunks) {
      return failAudioStream("audio_stream_end_chunks_mismatch");
    }
    if (activeStream_.audioBytes != 0 && activeStreamBytesReceived_ != activeStream_.audioBytes) {
      return failAudioStream("audio_stream_payload_bytes_mismatch");
    }
    if (activeStream_.chunks != 0 && activeStreamChunksReceived_ != activeStream_.chunks) {
      return failAudioStream("audio_stream_payload_chunks_mismatch");
    }

    telemetry_.audioStreamsEnded++;
    telemetry_.audioStreamChecksum = activeStreamChecksum_;
    clearAudioStream();
    queueOutput(output);
    return true;
  }

  if (std::strcmp(type, "response_end") == 0) {
    if (audioStreamActive_) {
      return failAudioStream("response_end_before_audio_stream_end");
    }
    telemetry_.state = BridgeClientState::Ready;
    output.type = BridgeClientOutputType::ResponseEnd;
    output.event.type = EventType::ResponseEnded;
    queueOutput(output);
    return true;
  }

  if (std::strcmp(type, "heartbeat") == 0) {
    telemetry_.heartbeats++;
    if (telemetry_.state == BridgeClientState::Connecting) {
      telemetry_.state = BridgeClientState::Ready;
    }
    return true;
  }

  if (std::strcmp(type, "error") == 0) {
    clearAudioStream();
    output.type = BridgeClientOutputType::Error;
    output.event.type = EventType::Error;
    readStringField(jsonLine, "code", output.error, sizeof(output.error));
    telemetry_.state = isFatalRemoteError(output.error) ? BridgeClientState::Error : BridgeClientState::Ready;
    queueOutput(output);
    return true;
  }

  return failParse("unknown_type");
}

bool BridgeClient::submitBinaryFrame(const uint8_t* payload, size_t length, uint32_t nowMs) {
  if (!telemetry_.ready) {
    return false;
  }

  telemetry_.inboundMessages++;
  telemetry_.lastMessageMs = nowMs;
  telemetry_.lastSeq = audioStreamActive_ ? activeStream_.seq : telemetry_.lastSeq;

  if (!audioStreamActive_) {
    return failAudioStream("binary_without_audio_stream");
  }
  if (payload == nullptr || length == 0 || length > 0xffffffffu) {
    return failAudioStream("invalid_audio_stream_chunk");
  }
  if (length > kBridgeAudioStreamChunkPayloadMax) {
    return failAudioStream("audio_stream_chunk_too_large");
  }

  const uint32_t chunkBytes = static_cast<uint32_t>(length);
  const uint32_t nextBytes = activeStreamBytesReceived_ + chunkBytes;
  const uint32_t nextChunks = activeStreamChunksReceived_ + 1u;

  if (nextBytes < activeStreamBytesReceived_ ||
      (activeStream_.audioBytes != 0 && nextBytes > activeStream_.audioBytes)) {
    return failAudioStream("audio_stream_payload_bytes_overrun");
  }
  if (nextChunks < activeStreamChunksReceived_ ||
      (activeStream_.chunks != 0 && nextChunks > activeStream_.chunks)) {
    return failAudioStream("audio_stream_payload_chunks_overrun");
  }

  activeStreamBytesReceived_ = nextBytes;
  activeStreamChunksReceived_ = nextChunks;
  activeStreamChecksum_ = updateAudioStreamChecksum(activeStreamChecksum_, payload, length);

  telemetry_.audioStreamBytesReceived += chunkBytes;
  telemetry_.audioStreamChunksReceived++;
  telemetry_.audioStreamChecksum = activeStreamChecksum_;

  BridgeClientOutput output;
  output.type = BridgeClientOutputType::AudioStreamChunk;
  output.stream = activeStream_;
  output.streamChunk.seq = activeStream_.seq;
  output.streamChunk.index = nextChunks;
  output.streamChunk.bytes = chunkBytes;
  output.streamChunk.payloadBytes = chunkBytes;
  output.streamChunk.receivedBytes = nextBytes;
  output.streamChunk.checksum = activeStreamChecksum_;
  output.streamChunk.payload = payload;
  const bool expectedBytesDone = activeStream_.audioBytes != 0 && nextBytes >= activeStream_.audioBytes;
  const bool expectedChunksDone = activeStream_.chunks != 0 && nextChunks >= activeStream_.chunks;
  if (activeStream_.audioBytes != 0 && activeStream_.chunks != 0) {
    output.streamChunk.finalChunk = expectedBytesDone && expectedChunksDone;
  } else {
    output.streamChunk.finalChunk = expectedBytesDone || expectedChunksDone;
  }

  queueOutput(output);
  return true;
}

bool BridgeClient::poll(BridgeClientOutput* outputOut) {
  if (outputOut == nullptr || outputCount_ == 0) {
    return false;
  }
  *outputOut = outputQueue_[outputTail_];
  if (outputOut->type == BridgeClientOutputType::AudioStreamChunk &&
      outputOut->streamChunk.payloadBytes > 0) {
    outputOut->streamChunk.payload = outputPayloads_[outputTail_];
  }
  outputQueue_[outputTail_] = BridgeClientOutput {};
  outputTail_ = (outputTail_ + 1u) % kBridgeClientOutputQueueDepth;
  outputCount_--;
  return true;
}

bool BridgeClient::readStringField(const char* line, const char* key, char* out, size_t outSize) {
  if (line == nullptr || key == nullptr || out == nullptr || outSize == 0) {
    return false;
  }

  char pattern[40] = {};
  std::snprintf(pattern, sizeof(pattern), "\"%s\"", key);
  const char* keyPos = std::strstr(line, pattern);
  if (keyPos == nullptr) {
    return false;
  }
  const char* colon = std::strchr(keyPos + std::strlen(pattern), ':');
  if (colon == nullptr) {
    return false;
  }
  const char* firstQuote = std::strchr(colon + 1, '"');
  if (firstQuote == nullptr) {
    return false;
  }
  const char* secondQuote = std::strchr(firstQuote + 1, '"');
  if (secondQuote == nullptr || secondQuote == firstQuote + 1) {
    out[0] = '\0';
    return secondQuote != nullptr;
  }

  const size_t sourceLen = static_cast<size_t>(secondQuote - firstQuote - 1);
  const size_t copyLen = sourceLen < (outSize - 1) ? sourceLen : (outSize - 1);
  std::memcpy(out, firstQuote + 1, copyLen);
  out[copyLen] = '\0';
  return true;
}

bool BridgeClient::readUintField(const char* line, const char* key, uint32_t* out) {
  if (line == nullptr || key == nullptr || out == nullptr) {
    return false;
  }
  char pattern[40] = {};
  std::snprintf(pattern, sizeof(pattern), "\"%s\"", key);
  const char* keyPos = std::strstr(line, pattern);
  if (keyPos == nullptr) {
    return false;
  }
  const char* colon = std::strchr(keyPos + std::strlen(pattern), ':');
  if (colon == nullptr) {
    return false;
  }
  char* end = nullptr;
  const unsigned long value = std::strtoul(colon + 1, &end, 10);
  if (end == colon + 1) {
    return false;
  }
  *out = static_cast<uint32_t>(value);
  return true;
}

bool BridgeClient::readFloatField(const char* line, const char* key, float* out) {
  if (line == nullptr || key == nullptr || out == nullptr) {
    return false;
  }
  char pattern[40] = {};
  std::snprintf(pattern, sizeof(pattern), "\"%s\"", key);
  const char* keyPos = std::strstr(line, pattern);
  if (keyPos == nullptr) {
    return false;
  }
  const char* colon = std::strchr(keyPos + std::strlen(pattern), ':');
  if (colon == nullptr) {
    return false;
  }
  char* end = nullptr;
  const float value = std::strtof(colon + 1, &end);
  if (end == colon + 1) {
    return false;
  }
  *out = value;
  return true;
}

bool BridgeClient::readBoolField(const char* line, const char* key, bool* out) {
  if (line == nullptr || key == nullptr || out == nullptr) {
    return false;
  }
  char pattern[40] = {};
  std::snprintf(pattern, sizeof(pattern), "\"%s\"", key);
  const char* keyPos = std::strstr(line, pattern);
  if (keyPos == nullptr) {
    return false;
  }
  const char* colon = std::strchr(keyPos + std::strlen(pattern), ':');
  if (colon == nullptr) {
    return false;
  }
  const char* value = colon + 1;
  while (*value == ' ' || *value == '\t') {
    ++value;
  }
  if (std::strncmp(value, "true", 4) == 0) {
    *out = true;
    return true;
  }
  if (std::strncmp(value, "false", 5) == 0) {
    *out = false;
    return true;
  }
  return false;
}

SpeechIntent BridgeClient::intentFromString(const char* value) {
  if (value == nullptr) {
    return SpeechIntent::Speak;
  }
  if (std::strcmp(value, "boot") == 0) return SpeechIntent::Boot;
  if (std::strcmp(value, "idle") == 0) return SpeechIntent::Idle;
  if (std::strcmp(value, "attend") == 0) return SpeechIntent::Attend;
  if (std::strcmp(value, "listen") == 0) return SpeechIntent::Listen;
  if (std::strcmp(value, "think") == 0) return SpeechIntent::Think;
  if (std::strcmp(value, "speak") == 0) return SpeechIntent::Speak;
  if (std::strcmp(value, "react") == 0) return SpeechIntent::React;
  if (std::strcmp(value, "happy") == 0) return SpeechIntent::Happy;
  if (std::strcmp(value, "concern") == 0) return SpeechIntent::Concern;
  if (std::strcmp(value, "sleep") == 0) return SpeechIntent::Sleep;
  if (std::strcmp(value, "safety") == 0) return SpeechIntent::Safety;
  if (std::strcmp(value, "error") == 0) return SpeechIntent::Error;
  return SpeechIntent::Speak;
}

AudioOutViseme BridgeClient::visemeFromString(const char* value) {
  if (value == nullptr) {
    return AudioOutViseme::Neutral;
  }
  if (std::strcmp(value, "ah") == 0) return AudioOutViseme::Ah;
  if (std::strcmp(value, "oh") == 0) return AudioOutViseme::Oh;
  if (std::strcmp(value, "ee") == 0) return AudioOutViseme::Ee;
  return AudioOutViseme::Neutral;
}

float BridgeClient::clamp01(float value) {
  if (value < 0.0f) return 0.0f;
  if (value > 1.0f) return 1.0f;
  return value;
}

uint16_t BridgeClient::clampDuration(uint32_t value) {
  if (value < 10u) return 10u;
  if (value > 200u) return 200u;
  return static_cast<uint16_t>(value);
}

void BridgeClient::copyBounded(char* out, size_t outSize, const char* value) {
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

void BridgeClient::queueOutput(const BridgeClientOutput& output) {
  if (outputCount_ >= kBridgeClientOutputQueueDepth) {
    telemetry_.outputsDropped++;
    return;
  }
  BridgeClientOutput queued = output;
  if (queued.type == BridgeClientOutputType::AudioStreamChunk &&
      queued.streamChunk.payload != nullptr &&
      queued.streamChunk.payloadBytes > 0) {
    const size_t copyBytes = queued.streamChunk.payloadBytes < kBridgeAudioStreamChunkPayloadMax
                                 ? queued.streamChunk.payloadBytes
                                 : kBridgeAudioStreamChunkPayloadMax;
    std::memcpy(outputPayloads_[outputHead_], queued.streamChunk.payload, copyBytes);
    queued.streamChunk.payload = outputPayloads_[outputHead_];
    queued.streamChunk.payloadBytes = static_cast<uint32_t>(copyBytes);
    queued.streamChunk.bytes = static_cast<uint32_t>(copyBytes);
  }
  outputQueue_[outputHead_] = queued;
  outputHead_ = (outputHead_ + 1u) % kBridgeClientOutputQueueDepth;
  outputCount_++;
  telemetry_.outputsQueued++;
}

void BridgeClient::clearAudioStream() {
  activeStream_ = BridgeAudioStream {};
  activeStreamBytesReceived_ = 0;
  activeStreamChunksReceived_ = 0;
  activeStreamChecksum_ = 0;
  audioStreamActive_ = false;
  telemetry_.audioStreamActive = false;
}

bool BridgeClient::failAudioStream(const char* reason) {
  telemetry_.audioStreamErrors++;
  clearAudioStream();
  return failParse(reason);
}

bool BridgeClient::failParse(const char* reason) {
  telemetry_.parseErrors++;
  telemetry_.state = BridgeClientState::Error;
  BridgeClientOutput output;
  output.type = BridgeClientOutputType::Error;
  output.event.type = EventType::Error;
  copyBounded(output.error, sizeof(output.error), reason);
  queueOutput(output);
  return false;
}

bool BridgeClient::failTimeout(uint32_t nowMs) {
  telemetry_.timeouts++;
  telemetry_.state = BridgeClientState::Error;
  telemetry_.lastMessageMs = nowMs;
  clearAudioStream();
  BridgeClientOutput output;
  output.type = BridgeClientOutputType::Error;
  output.event.type = EventType::Error;
  output.event.timestampMs = nowMs;
  output.event.strength = 1.0f;
  copyBounded(output.error, sizeof(output.error), "bridge_timeout");
  queueOutput(output);
  return true;
}

}  // namespace stackchan
