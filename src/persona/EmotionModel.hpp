#pragma once

#include "persona/EventBus.hpp"
#include "persona/StateMatrix.hpp"

namespace stackchan {

class EmotionModel {
 public:
  void reset();
  void applyEvent(const RobotEvent& event);
  void applyAmbient(float lux, uint8_t hourOfDay);
  void update(float dt);

  const EmotionalProfile& profile() const {
    return emotion_;
  }

 private:
  EmotionalProfile emotion_;

  static float approach(float value, float target, float amount);
  static float clamp01(float value);
  static float clampSigned(float value);
};

}  // namespace stackchan
