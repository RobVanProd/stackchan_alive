#pragma once

#include <stdint.h>

#include "persona/StateMatrix.hpp"

namespace stackchan {

enum class Ease : uint8_t {
  Linear,
  InOutCubic,
  OutQuad,
  InQuad,
  OutBack,
};

float applyEase(Ease ease, float x);

class FaceAnimator {
 public:
  FaceTargets composeFrame(const RobotFrame& frame, uint32_t nowMs);
  void reset(const FaceTargets& face, uint32_t nowMs);

 private:
  bool initialized_ = false;
  uint32_t lastMs_ = 0;
  FaceTargets current_;

  FaceTargets samplePose(const RobotFrame& frame, uint32_t nowMs) const;
  void applyAutonomic(FaceTargets& face, const RobotFrame& frame, uint32_t nowMs) const;
  void applyGesture(FaceTargets& face, const RobotFrame& frame, uint32_t nowMs) const;
  void applyReactive(FaceTargets& face, const RobotFrame& frame, uint32_t nowMs) const;
  FaceTargets smoothToward(const FaceTargets& target, uint32_t nowMs);
};

}  // namespace stackchan
