#pragma once

#include "persona/StateMatrix.hpp"

namespace stackchan {

enum class CharacterMode : uint8_t;

class ExpressionMapper {
 public:
  FaceTargets map(const EmotionalProfile& emotion, CharacterMode mode) const;
};

}  // namespace stackchan
