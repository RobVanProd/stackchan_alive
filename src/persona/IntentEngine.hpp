#pragma once

#include "face/ExpressionMapper.hpp"
#include "persona/EmotionModel.hpp"
#include "persona/StateMatrix.hpp"

namespace stackchan {

class IntentEngine {
 public:
  void begin();
  RobotFrame update(uint32_t nowMs);

 private:
  EmotionModel emotion_;
  ExpressionMapper expression_;
  CharacterMode mode_ = CharacterMode::Idle;
  uint32_t seq_ = 0;
  uint32_t nextDemoEventMs_ = 0;
  uint32_t lastUpdateMs_ = 0;

  void injectDemoEvents(uint32_t nowMs);
  MotionTargets motionForMode(uint32_t nowMs) const;
};

}  // namespace stackchan
