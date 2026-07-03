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
  PickedUp,
  Shaken,
  PutDown,
  Tilted,
};

struct RobotEvent {
  EventType type = EventType::Boot;
  uint32_t timestampMs = 0;
  float strength = 1.0f;
  bool hasPayload = false;
  float x = 0.0f;
  float y = 0.0f;
  float z = 0.0f;
};

}  // namespace stackchan
