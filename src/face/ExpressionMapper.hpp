#pragma once

#include "persona/StateMatrix.hpp"

namespace stackchan {

class ExpressionMapper {
 public:
  FaceTargets map(const EmotionalProfile& emotion, CharacterMode mode) const;
};

}  // namespace stackchan
