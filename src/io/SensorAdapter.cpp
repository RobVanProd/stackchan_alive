#include "io/SensorAdapter.hpp"

#include <ctype.h>
#include <stdlib.h>
#include <string.h>

#if defined(ARDUINO_ARCH_ESP32)
#include <M5Unified.h>
#endif

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

bool fillHelp(BenchControl* controlOut) {
  BenchControl parsed;
  parsed.wantsHelp = true;
  parsed.command = "help";
  *controlOut = parsed;
  return true;
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

bool parseDurationMs(const char* token, uint16_t* durationOut) {
  if (token == nullptr || token[0] == '\0') {
    return false;
  }

  char* end = nullptr;
  const long parsed = strtol(token, &end, 10);
  if (end == token) {
    return false;
  }
  *durationOut = static_cast<uint16_t>(constrain(parsed, 50L, 2000L));
  return true;
}

bool parseViseme(const char* token, BenchSpeechViseme* visemeOut) {
  if (token == nullptr || token[0] == '\0') {
    return false;
  }

  if (strcmp(token, "ah") == 0 || strcmp(token, "a") == 0 || strcmp(token, "open") == 0) {
    *visemeOut = BenchSpeechViseme::Ah;
    return true;
  }
  if (strcmp(token, "oh") == 0 || strcmp(token, "o") == 0 || strcmp(token, "round") == 0) {
    *visemeOut = BenchSpeechViseme::Oh;
    return true;
  }
  if (strcmp(token, "ee") == 0 || strcmp(token, "e") == 0 || strcmp(token, "wide") == 0) {
    *visemeOut = BenchSpeechViseme::Ee;
    return true;
  }
  if (strcmp(token, "neutral") == 0 || strcmp(token, "n") == 0 || strcmp(token, "rest") == 0) {
    *visemeOut = BenchSpeechViseme::Neutral;
    return true;
  }
  return false;
}

bool parseOnOff(const char* token, bool* valueOut) {
  if (token == nullptr || token[0] == '\0') {
    return false;
  }

  if (strcmp(token, "on") == 0 || strcmp(token, "1") == 0 || strcmp(token, "true") == 0 ||
      strcmp(token, "yes") == 0 || strcmp(token, "reduced") == 0) {
    *valueOut = true;
    return true;
  }
  if (strcmp(token, "off") == 0 || strcmp(token, "0") == 0 || strcmp(token, "false") == 0 ||
      strcmp(token, "no") == 0 || strcmp(token, "full") == 0 || strcmp(token, "normal") == 0) {
    *valueOut = false;
    return true;
  }
  return false;
}

bool fillReducedMotion(const char* valueToken, BenchControl* controlOut) {
  bool enabled = false;
  if (!parseOnOff(valueToken, &enabled)) {
    return false;
  }

  BenchControl parsed;
  parsed.hasReducedMotion = true;
  parsed.reducedMotion = enabled;
  parsed.command = enabled ? "reduced_motion_on" : "reduced_motion_off";
  *controlOut = parsed;
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
    controlOut->hasEvent = true;
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
    controlOut->hasEvent = true;
    controlOut->command = command.command;
    return true;
  }
  return false;
}

bool fillFromSpeech(char* envelopeToken, char* visemeToken, char* durationToken, uint32_t nowMs, BenchControl* controlOut) {
  if (envelopeToken == nullptr) {
    return false;
  }

  BenchControl parsed;
  parsed.hasSpeech = true;
  parsed.hasEvent = true;
  parsed.mode = CharacterMode::Speak;
  parsed.event.type = EventType::ResponseStarted;
  parsed.event.timestampMs = nowMs;
  parsed.event.strength = 1.0f;
  parsed.command = "speech_env";

  if (strcmp(envelopeToken, "clear") == 0 || strcmp(envelopeToken, "off") == 0 || strcmp(envelopeToken, "stop") == 0) {
    parsed.mode = CharacterMode::Idle;
    parsed.event.type = EventType::SpeechEnded;
    parsed.speech.clear = true;
    parsed.speech.envelope = 0.0f;
    parsed.speech.viseme = BenchSpeechViseme::Neutral;
    parsed.command = "speech_clear";
    *controlOut = parsed;
    return true;
  }

  float envelope = 0.0f;
  if (!parseStrength(envelopeToken, &envelope)) {
    return false;
  }

  BenchSpeechViseme viseme = BenchSpeechViseme::Ah;
  uint16_t durationMs = 600;
  if (visemeToken != nullptr && !parseViseme(visemeToken, &viseme)) {
    if (!parseDurationMs(visemeToken, &durationMs)) {
      return false;
    }
    visemeToken = nullptr;
  }
  parseDurationMs(durationToken, &durationMs);

  parsed.speech.envelope = envelope;
  parsed.speech.viseme = viseme;
  parsed.speech.durationMs = durationMs;
  *controlOut = parsed;
  return true;
}

void fillHardwareEvent(CharacterMode mode, EventType eventType, uint32_t nowMs, const char* command, BenchControl* controlOut) {
  BenchControl parsed;
  parsed.hasEvent = true;
  parsed.mode = mode;
  parsed.event.type = eventType;
  parsed.event.timestampMs = nowMs;
  parsed.event.strength = 1.0f;
  parsed.command = command;
  *controlOut = parsed;
}

}  // namespace

bool parseBenchControlLine(const char* line, uint32_t nowMs, BenchControl* controlOut) {
  if (line == nullptr || controlOut == nullptr) {
    return false;
  }

  char normalized[96] = {};
  normalizeLine(line, normalized, sizeof(normalized));

  char* first = strtok(normalized, " \t");
  if (first == nullptr) {
    return false;
  }
  if (isHelpToken(first)) {
    return fillHelp(controlOut);
  }

  char* second = strtok(nullptr, " \t");
  char* third = strtok(nullptr, " \t");

  bool forceMode = false;
  bool forceEvent = false;
  bool forceSpeech = false;
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
  } else if (strcmp(first, "speech") == 0 || strcmp(first, "mouth") == 0 || strcmp(first, "env") == 0) {
    forceSpeech = true;
  }

  if (forceSpeech) {
    return fillFromSpeech(second, third, strtok(nullptr, " \t"), nowMs, controlOut);
  }

  if (strcmp(first, "reduced") == 0 || strcmp(first, "reduced_motion") == 0 ||
      strcmp(first, "reducedmotion") == 0 || strcmp(first, "calm") == 0) {
    return fillReducedMotion(second, controlOut);
  }
  if (strcmp(first, "motion") == 0 && second != nullptr &&
      (strcmp(second, "reduced") == 0 || strcmp(second, "reduced_motion") == 0 ||
       strcmp(second, "reducedmotion") == 0)) {
    return fillReducedMotion(third, controlOut);
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

void SensorAdapter::printHelp() const {
#if defined(ARDUINO_ARCH_ESP32)
  Serial.println(F("[control] help: mode listen|think|speak|idle|sleep|error [strength]"));
  Serial.println(F("[control] help: event wake|touch|response|speech_end|idle|error [strength]"));
  Serial.println(F("[control] help: speech <0.0-1.0> <ah|oh|ee|neutral> [duration_ms]; speech clear"));
  Serial.println(F("[control] help: reduced on|off; motion reduced on|off"));
  Serial.println(F("[control] help: CoreS3 inputs: tap=react hold=listen BtnA=listen BtnB=think BtnC=speak"));
#endif
}

bool SensorAdapter::begin() {
  lineLength_ = 0;
  line_[0] = '\0';
#if defined(ARDUINO_ARCH_ESP32)
  printHelp();
#endif
  return true;
}

bool SensorAdapter::poll(BenchControl* controlOut) {
  if (controlOut == nullptr) {
    return false;
  }

#if defined(ARDUINO_ARCH_ESP32)
  M5.update();

  while (Serial.available() > 0) {
    const char ch = static_cast<char>(Serial.read());
    if (ch == '\r') {
      continue;
    }

    if (ch == '\n') {
      line_[lineLength_] = '\0';
      lineLength_ = 0;

      if (parseBenchControlLine(line_, millis(), controlOut)) {
        if (controlOut->wantsHelp) {
          printHelp();
          line_[0] = '\0';
          continue;
        }
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

  const uint32_t nowMs = millis();
  if (M5.BtnA.wasClicked()) {
    fillHardwareEvent(CharacterMode::Listen, EventType::WakeWord, nowMs, "button_a_listen", controlOut);
    return true;
  }
  if (M5.BtnB.wasClicked()) {
    fillHardwareEvent(CharacterMode::Think, EventType::ThinkingStarted, nowMs, "button_b_think", controlOut);
    return true;
  }
  if (M5.BtnC.wasClicked()) {
    fillHardwareEvent(CharacterMode::Speak, EventType::ResponseStarted, nowMs, "button_c_speak", controlOut);
    return true;
  }

  if (M5.Touch.isEnabled() && M5.Touch.getCount() > 0) {
    const auto detail = M5.Touch.getDetail(0);
    if (detail.wasClicked()) {
      fillHardwareEvent(CharacterMode::React, EventType::UserTouched, nowMs, "touch_click_react", controlOut);
      return true;
    }
    if (detail.wasHold()) {
      fillHardwareEvent(CharacterMode::Listen, EventType::UserNear, nowMs, "touch_hold_listen", controlOut);
      return true;
    }
  }
#endif

  return false;
}

}  // namespace stackchan
