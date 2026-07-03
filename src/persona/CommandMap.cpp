#include "persona/CommandMap.hpp"

#include <stdlib.h>
#include <string.h>

namespace stackchan {

namespace {
bool tokenEquals(const char* token, const char* expected) {
  return token != nullptr && strcmp(token, expected) == 0;
}

SpeechCue ackCue(SpokenCommandId commandId) {
  switch (commandId) {
    case SpokenCommandId::GoToSleep:
      return {SpeechIntent::Sleep, "Sleep command received. Systems going quiet.", 210,
              SpeechEarcon::Sleep, 80};
    case SpokenCommandId::WakeUp:
      return {SpeechIntent::Listen, "Wake command received. I am listening.", 210,
              SpeechEarcon::Wake, 0};
    case SpokenCommandId::LookAtMe:
      return {SpeechIntent::Attend, "Looking at you now.", 190,
              SpeechEarcon::Confirm, 0};
    case SpokenCommandId::StopMoving:
      return {SpeechIntent::Safety, "Motion hold active. I will stay still.", 250,
              SpeechEarcon::Safety, 0};
    case SpokenCommandId::HowDoYouFeel:
      return {SpeechIntent::Speak, "Status check received. Feeling curious and awake.", 190,
              SpeechEarcon::Confirm, 0};
    case SpokenCommandId::Unknown:
    default:
      return {};
  }
}

CommandMapResult eventResult(SpokenCommandId commandId,
                             CharacterMode mode,
                             EventType eventType,
                             uint32_t nowMs,
                             float strength,
                             const char* command) {
  CommandMapResult result;
  result.valid = true;
  result.mode = mode;
  result.hasEvent = true;
  result.event.type = eventType;
  result.event.timestampMs = nowMs;
  result.event.strength = constrain(strength, 0.0f, 1.0f);
  result.hasSpeechCue = true;
  result.speechCue = ackCue(commandId);
  result.command = command;

  if (commandId == SpokenCommandId::LookAtMe) {
    result.event.hasPayload = true;
    result.event.x = 0.0f;
    result.event.y = 0.0f;
    result.event.z = 1.0f;
  }

  return result;
}
}  // namespace

SpokenCommandId CommandMap::fromPhraseId(uint16_t phraseId) {
  switch (phraseId) {
    case 1:
      return SpokenCommandId::GoToSleep;
    case 2:
      return SpokenCommandId::WakeUp;
    case 3:
      return SpokenCommandId::LookAtMe;
    case 4:
      return SpokenCommandId::StopMoving;
    case 5:
      return SpokenCommandId::HowDoYouFeel;
    default:
      return SpokenCommandId::Unknown;
  }
}

SpokenCommandId CommandMap::fromToken(const char* token) {
  if (token == nullptr || token[0] == '\0') {
    return SpokenCommandId::Unknown;
  }

  char* end = nullptr;
  const long phraseId = strtol(token, &end, 10);
  if (end != token && *end == '\0' && phraseId >= 0 && phraseId <= 65535) {
    return fromPhraseId(static_cast<uint16_t>(phraseId));
  }

  if (tokenEquals(token, "sleep") || tokenEquals(token, "go_to_sleep") ||
      tokenEquals(token, "go_sleep")) {
    return SpokenCommandId::GoToSleep;
  }
  if (tokenEquals(token, "wake") || tokenEquals(token, "wake_up")) {
    return SpokenCommandId::WakeUp;
  }
  if (tokenEquals(token, "look") || tokenEquals(token, "look_at_me") ||
      tokenEquals(token, "look_me")) {
    return SpokenCommandId::LookAtMe;
  }
  if (tokenEquals(token, "stop") || tokenEquals(token, "stop_moving") ||
      tokenEquals(token, "hold_still")) {
    return SpokenCommandId::StopMoving;
  }
  if (tokenEquals(token, "feel") || tokenEquals(token, "how_feel") ||
      tokenEquals(token, "how_do_you_feel")) {
    return SpokenCommandId::HowDoYouFeel;
  }

  return SpokenCommandId::Unknown;
}

CommandMapResult CommandMap::map(SpokenCommandId commandId, uint32_t nowMs) {
  switch (commandId) {
    case SpokenCommandId::GoToSleep:
      return eventResult(commandId, CharacterMode::Sleep, EventType::IdleTimeout, nowMs, 0.85f, "command_go_to_sleep");
    case SpokenCommandId::WakeUp:
      return eventResult(commandId, CharacterMode::Listen, EventType::WakeWord, nowMs, 1.0f, "command_wake_up");
    case SpokenCommandId::LookAtMe:
      return eventResult(commandId, CharacterMode::Attend, EventType::FaceDetected, nowMs, 1.0f, "command_look_at_me");
    case SpokenCommandId::StopMoving: {
      CommandMapResult result;
      result.valid = true;
      result.mode = CharacterMode::Listen;
      result.hasMotionEnable = true;
      result.motionEnabled = false;
      result.hasSpeechCue = true;
      result.speechCue = ackCue(commandId);
      result.command = "command_stop_moving";
      return result;
    }
    case SpokenCommandId::HowDoYouFeel:
      return eventResult(commandId, CharacterMode::Speak, EventType::ResponseStarted, nowMs, 0.65f, "command_how_do_you_feel");
    case SpokenCommandId::Unknown:
    default:
      return CommandMapResult {};
  }
}

CommandMapResult CommandMap::mapPhraseId(uint16_t phraseId, uint32_t nowMs) {
  return map(fromPhraseId(phraseId), nowMs);
}

}  // namespace stackchan
