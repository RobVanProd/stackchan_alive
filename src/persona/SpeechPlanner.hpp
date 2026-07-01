#pragma once

#include <Arduino.h>

#include "persona/IntentEngine.hpp"
#include "persona/StateMatrix.hpp"

namespace stackchan {

enum class SpeechIntent : uint8_t {
  None,
  Boot,
  Idle,
  Attend,
  Listen,
  Think,
  Speak,
  React,
  Happy,
  Concern,
  Sleep,
  Error,
  Safety,
};

struct SpeechCue {
  SpeechIntent intent = SpeechIntent::None;
  const char* text = "";
  uint8_t priority = 0;

  bool shouldSpeak() const {
    return intent != SpeechIntent::None && text[0] != '\0';
  }
};

class SpeechPlanner {
 public:
  SpeechCue plan(CharacterMode mode, const EmotionalProfile& emotion) const;
};

}  // namespace stackchan
