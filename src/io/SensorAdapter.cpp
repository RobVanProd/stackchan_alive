#include "io/SensorAdapter.hpp"

#include <ctype.h>
#include <stdlib.h>
#include <string.h>

namespace stackchan {

namespace {

struct ModeCommand {
  const char* name;
  CharacterMode mode;
  EventType event;
  const char* command;
};

struct EventCommand {
  const char* name;
  CharacterMode mode;
  EventType event;
  const char* command;
};

constexpr ModeCommand kModeCommands[] = {
    {"boot", CharacterMode::Boot, EventType::Boot, "mode_boot"},
    {"idle", CharacterMode::Idle, EventType::IdleTimeout, "mode_idle"},
    {"attend", CharacterMode::Attend, EventType::FaceDetected, "mode_attend"},
    {"near", CharacterMode::Attend, EventType::UserNear, "mode_attend"},
    {"listen", CharacterMode::Listen, EventType::WakeWord, "mode_listen"},
    {"think", CharacterMode::Think, EventType::ThinkingStarted, "mode_think"},
    {"thinking", CharacterMode::Think, EventType::ThinkingStarted, "mode_think"},
    {"speak", CharacterMode::Speak, EventType::ResponseStarted, "mode_speak"},
    {"talk", CharacterMode::Speak, EventType::ResponseStarted, "mode_speak"},
    {"react", CharacterMode::React, EventType::UserTouched, "mode_react"},
    {"sleep", CharacterMode::Sleep, EventType::IdleTimeout, "mode_sleep"},
    {"error", CharacterMode::Error, EventType::Error, "mode_error"},
};

constexpr EventCommand kEventCommands[] = {
    {"boot", CharacterMode::Boot, EventType::Boot, "event_boot"},
    {"face", CharacterMode::Attend, EventType::FaceDetected, "event_face"},
    {"detected", CharacterMode::Attend, EventType::FaceDetected, "event_face"},
    {"near", CharacterMode::Attend, EventType::UserNear, "event_near"},
    {"touch", CharacterMode::React, EventType::UserTouched, "event_touch"},
    {"touched", CharacterMode::React, EventType::UserTouched, "event_touch"},
    {"wake", CharacterMode::Listen, EventType::WakeWord, "event_wake"},
    {"listen", CharacterMode::Listen, EventType::WakeWord, "event_wake"},
    {"speaking", CharacterMode::Listen, EventType::UserSpeaking, "event_user_speaking"},
    {"user_speaking", CharacterMode::Listen, EventType::UserSpeaking, "event_user_speaking"},
    {"speech_end", CharacterMode::Idle, EventType::SpeechEnded, "event_speech_end"},
    {"speechended", CharacterMode::Idle, EventType::SpeechEnded, "event_speech_end"},
    {"think", CharacterMode::Think, EventType::ThinkingStarted, "event_think"},
    {"thinking", CharacterMode::Think, EventType::ThinkingStarted, "event_think"},
    {"response", CharacterMode::Speak, EventType::ResponseStarted, "event_response"},
    {"response_start", CharacterMode::Speak, EventType::ResponseStarted, "event_response"},
    {"speak", CharacterMode::Speak, EventType::ResponseStarted, "event_response"},
    {"response_end", CharacterMode::Idle, EventType::ResponseEnded, "event_response_end"},
    {"idle", CharacterMode::Idle, EventType::IdleTimeout, "event_idle"},
    {"timeout", CharacterMode::Idle, EventType::IdleTimeout, "event_idle"},
    {"error", CharacterMode::Error, EventType::Error, "event_error"},
};

bool isHelpToken(const char* token) {
  return strcmp(token, "help") == 0 || strcmp(token, "?") == 0;
}

void normalizeLine(const char* line, char* out, size_t outSize) {
  if (outSize == 0) {
    return;
  }

  size_t i = 0;
  for (; line != nullptr && line[i] != '\0' && i + 1 < outSize; ++i) {
    char ch = static_cast<char>(tolower(static_cast<unsigned char>(line[i])));
    if (ch == '=' || ch == ':' || ch == ',' || ch == '\r' || ch == '\n') {
      ch = ' ';
    } else if (ch == '-') {
      ch = '_';
    }
    out[i] = ch;
  }
  out[i] = '\0';
}

bool parseStrength(const char* token, float* strengthOut) {
  if (token == nullptr || token[0] == '\0') {
    return false;
  }

  char* end = nullptr;
  const float parsed = strtof(token, &end);
  if (end == token) {
    return false;
  }
  *strengthOut = constrain(parsed, 0.0f, 1.0f);
  return true;
}

bool fillFromMode(const char* token, uint32_t nowMs, float strength, BenchControl* controlOut) {
  for (const ModeCommand& command : kModeCommands) {
    if (strcmp(token, command.name) != 0) {
      continue;
    }

    controlOut->mode = command.mode;
    controlOut->event.type = command.event;
    controlOut->event.timestampMs = nowMs;
    controlOut->event.strength = strength;
    controlOut->command = command.command;
    return true;
  }
  return false;
}

bool fillFromEvent(const char* token, uint32_t nowMs, float strength, BenchControl* controlOut) {
  for (const EventCommand& command : kEventCommands) {
    if (strcmp(token, command.name) != 0) {
      continue;
    }

    controlOut->mode = command.mode;
    controlOut->event.type = command.event;
    controlOut->event.timestampMs = nowMs;
    controlOut->event.strength = strength;
    controlOut->command = command.command;
    return true;
  }
  return false;
}

}  // namespace

bool parseBenchControlLine(const char* line, uint32_t nowMs, BenchControl* controlOut) {
  if (line == nullptr || controlOut == nullptr) {
    return false;
  }

  char normalized[96] = {};
  normalizeLine(line, normalized, sizeof(normalized));

  char* first = strtok(normalized, " \t");
  if (first == nullptr || isHelpToken(first)) {
    return false;
  }

  char* second = strtok(nullptr, " \t");
  char* third = strtok(nullptr, " \t");

  bool forceMode = false;
  bool forceEvent = false;
  const char* token = first;
  const char* strengthToken = second;

  if (strcmp(first, "mode") == 0 || strcmp(first, "m") == 0) {
    forceMode = true;
    token = second;
    strengthToken = third;
  } else if (strcmp(first, "event") == 0 || strcmp(first, "e") == 0) {
    forceEvent = true;
    token = second;
    strengthToken = third;
  }

  if (token == nullptr || isHelpToken(token)) {
    return false;
  }

  float strength = 1.0f;
  parseStrength(strengthToken, &strength);

  BenchControl parsed;
  if (forceMode) {
    if (!fillFromMode(token, nowMs, strength, &parsed)) {
      return false;
    }
  } else if (forceEvent) {
    if (!fillFromEvent(token, nowMs, strength, &parsed)) {
      return false;
    }
  } else if (!fillFromMode(token, nowMs, strength, &parsed) &&
             !fillFromEvent(token, nowMs, strength, &parsed)) {
    return false;
  }

  *controlOut = parsed;
  return true;
}

bool SensorAdapter::begin() {
  lineLength_ = 0;
  line_[0] = '\0';
#if defined(ARDUINO_ARCH_ESP32)
  Serial.println(F("[control] serial commands: mode listen|think|speak|idle|sleep|error; event wake|touch|response|speech_end|idle|error"));
#endif
  return true;
}

bool SensorAdapter::poll(BenchControl* controlOut) {
  if (controlOut == nullptr) {
    return false;
  }

#if defined(ARDUINO_ARCH_ESP32)
  while (Serial.available() > 0) {
    const char ch = static_cast<char>(Serial.read());
    if (ch == '\r') {
      continue;
    }

    if (ch == '\n') {
      line_[lineLength_] = '\0';
      lineLength_ = 0;

      if (parseBenchControlLine(line_, millis(), controlOut)) {
        return true;
      }

      if (line_[0] != '\0') {
        Serial.print(F("[control] ignored command=\""));
        Serial.print(line_);
        Serial.println(F("\""));
      }
      line_[0] = '\0';
      continue;
    }

    if (lineLength_ + 1 < sizeof(line_)) {
      line_[lineLength_++] = ch;
    } else {
      lineLength_ = 0;
      line_[0] = '\0';
      Serial.println(F("[control] ignored overlong command"));
    }
  }
#endif

  return false;
}

}  // namespace stackchan
