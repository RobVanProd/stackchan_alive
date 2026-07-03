#pragma once

#include <Arduino.h>

#include "persona/EventBus.hpp"
#include "persona/StateMatrix.hpp"

namespace stackchan {

enum class SpokenCommandId : uint8_t {
  Unknown = 0,
  GoToSleep = 1,
  WakeUp = 2,
  LookAtMe = 3,
  StopMoving = 4,
  HowDoYouFeel = 5,
};

struct CommandMapResult {
  bool valid = false;
  CharacterMode mode = CharacterMode::Idle;
  bool hasEvent = false;
  RobotEvent event;
  bool hasMotionEnable = false;
  bool motionEnabled = true;
  bool hasSpeechCue = false;
  SpeechCue speechCue;
  const char* command = "";
};

class CommandMap {
 public:
  static SpokenCommandId fromPhraseId(uint16_t phraseId);
  static SpokenCommandId fromToken(const char* token);
  static CommandMapResult map(SpokenCommandId commandId, uint32_t nowMs);
  static CommandMapResult mapPhraseId(uint16_t phraseId, uint32_t nowMs);
};

}  // namespace stackchan
