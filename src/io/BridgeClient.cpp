#include "io/BridgeClient.hpp"

#include <cstdio>
#include <cstdlib>
#include <cstring>

namespace stackchan {

bool BridgeClient::begin(const BridgeClientConfig& config) {
  telemetry_ = BridgeClientTelemetry {};
  pending_ = BridgeClientOutput {};
  hasPending_ = false;
  config_ = config;

  telemetry_.configured = config_.deviceId != nullptr && config_.deviceId[0] != '\0' &&
                          config_.protocolVersion != nullptr && config_.protocolVersion[0] != '\0';
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
  hasPending_ = false;
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

  if (std::strcmp(type, "response_end") == 0) {
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
    telemetry_.state = BridgeClientState::Error;
    output.type = BridgeClientOutputType::Error;
    output.event.type = EventType::Error;
    readStringField(jsonLine, "code", output.error, sizeof(output.error));
    queueOutput(output);
    return true;
  }

  return failParse("unknown_type");
}

bool BridgeClient::poll(BridgeClientOutput* outputOut) {
  if (outputOut == nullptr || !hasPending_) {
    return false;
  }
  *outputOut = pending_;
  pending_ = BridgeClientOutput {};
  hasPending_ = false;
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
  if (std::strcmp(value, "happy") == 0) return SpeechIntent::Happy;
  if (std::strcmp(value, "concern") == 0) return SpeechIntent::Concern;
  if (std::strcmp(value, "think") == 0) return SpeechIntent::Think;
  if (std::strcmp(value, "listen") == 0) return SpeechIntent::Listen;
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
  if (hasPending_) {
    telemetry_.outputsDropped++;
  }
  pending_ = output;
  hasPending_ = true;
  telemetry_.outputsQueued++;
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

}  // namespace stackchan
