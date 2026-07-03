#include "persona/SpeechPlanner.hpp"

#include "PersonaSpeechLines.hpp"

namespace stackchan {

namespace {

SpeechCue cue(SpeechIntent intent) {
  return generated_persona::makeSpeechCue(intent);
}

}  // namespace

SpeechCue SpeechPlanner::plan(CharacterMode mode, const EmotionalProfile& emotion) const {
  switch (mode) {
    case CharacterMode::Boot:
      return cue(SpeechIntent::Boot);
    case CharacterMode::Attend:
    case CharacterMode::Listen:
      return cue(SpeechIntent::Listen);
    case CharacterMode::Think:
      return cue(SpeechIntent::Think);
    case CharacterMode::Speak:
      return cue(SpeechIntent::Speak);
    case CharacterMode::Sleep:
      return cue(SpeechIntent::Sleep);
    case CharacterMode::Error:
      if (emotion.focus > 0.70f) {
        return cue(SpeechIntent::Safety);
      }
      return cue(SpeechIntent::Error);
    case CharacterMode::React:
      if (emotion.valence >= 0.35f) {
        return cue(SpeechIntent::React);
      }
      break;
    case CharacterMode::Idle:
      break;
  }

  if (emotion.valence >= 0.65f) {
    return cue(SpeechIntent::Happy);
  }

  if (emotion.valence <= -0.45f) {
    return cue(SpeechIntent::Concern);
  }

  if (mode == CharacterMode::Idle && emotion.arousal > 0.55f) {
    return cue(SpeechIntent::Idle);
  }

  return {};
}

}  // namespace stackchan
