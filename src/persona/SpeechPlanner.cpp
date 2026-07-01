#include "persona/SpeechPlanner.hpp"

namespace stackchan {

SpeechCue SpeechPlanner::plan(CharacterMode mode, const EmotionalProfile& emotion) const {
  switch (mode) {
    case CharacterMode::Boot:
      return {SpeechIntent::Boot, "Hello. I am Stackchan, and I am awake.", 220};
    case CharacterMode::Attend:
    case CharacterMode::Listen:
      return {SpeechIntent::Listen, "I am listening with maximum attention.", 160};
    case CharacterMode::Think:
      return {SpeechIntent::Think, "Input received. I am thinking now.", 150};
    case CharacterMode::Speak:
      return {SpeechIntent::Speak, "That is new information. I like new information.", 150};
    case CharacterMode::Sleep:
      return {SpeechIntent::Sleep, "Systems quiet. I will keep a small light on.", 200};
    case CharacterMode::Error:
      if (emotion.focus > 0.70f) {
        return {SpeechIntent::Safety, "Servo test is not armed. Safety first.", 250};
      }
      return {SpeechIntent::Error, "Small problem found. I can help fix it.", 240};
    case CharacterMode::React:
      if (emotion.valence >= 0.35f) {
        return {SpeechIntent::React, "Display is ready. Face systems online.", 120};
      }
      break;
    case CharacterMode::Idle:
      break;
  }

  if (emotion.valence >= 0.65f) {
    return {SpeechIntent::Happy, "Happy signal detected.", 100};
  }

  if (emotion.valence <= -0.45f) {
    return {SpeechIntent::Concern, "I need a little more data.", 100};
  }

  if (mode == CharacterMode::Idle && emotion.arousal > 0.55f) {
    return {SpeechIntent::Idle, "Curiosity level rising.", 50};
  }

  return {};
}

}  // namespace stackchan
