#pragma once

#include "persona/StateMatrix.hpp"

namespace stackchan {

class SpeechPlanner {
 public:
  SpeechCue plan(CharacterMode mode, const EmotionalProfile& emotion) const;
};

}  // namespace stackchan
