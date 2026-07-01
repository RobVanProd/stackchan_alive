#pragma once

#include <Arduino.h>

namespace stackchan {

enum class EventType : uint8_t {
  Boot,
  FaceDetected,
  UserNear,
  UserTouched,
  WakeWord,
  UserSpeaking,
  SpeechEnded,
  ThinkingStarted,
  ResponseStarted,
  ResponseEnded,
  IdleTimeout,
  Error,
};

struct RobotEvent {
  EventType type = EventType::Boot;
  uint32_t timestampMs = 0;
  float strength = 1.0f;
};

}  // namespace stackchan
