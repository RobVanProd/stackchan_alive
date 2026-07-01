#include "face/FaceAnimator.hpp"

#include <math.h>

namespace {

float clamp01(float value) {
  if (value < 0.0f) {
    return 0.0f;
  }
  if (value > 1.0f) {
    return 1.0f;
  }
  return value;
}

float smoothChannel(float current, float target, float dtMs, float tauMs) {
  if (tauMs <= 0.0f || dtMs <= 0.0f) {
    return target;
  }
  const float alpha = 1.0f - expf(-dtMs / tauMs);
  return current + (target - current) * alpha;
}

}  // namespace

namespace stackchan {

float applyEase(Ease ease, float x) {
  x = clamp01(x);
  switch (ease) {
    case Ease::Linear:
      return x;
    case Ease::InOutCubic:
      return x < 0.5f ? 4.0f * x * x * x : 1.0f - powf(-2.0f * x + 2.0f, 3.0f) * 0.5f;
    case Ease::OutQuad:
      return 1.0f - (1.0f - x) * (1.0f - x);
    case Ease::InQuad:
      return x * x;
    case Ease::OutBack: {
      const float c1 = 1.70158f;
      const float c3 = c1 + 1.0f;
      const float u = x - 1.0f;
      return 1.0f + c3 * u * u * u + c1 * u * u;
    }
  }
  return x;
}

void FaceAnimator::reset(const FaceTargets& face, uint32_t nowMs) {
  current_ = face;
  lastMs_ = nowMs;
  initialized_ = true;
}

FaceTargets FaceAnimator::composeFrame(const RobotFrame& frame, uint32_t nowMs) {
  FaceTargets target = samplePose(frame, nowMs);
  applyAutonomic(target, frame, nowMs);
  applyGesture(target, frame, nowMs);
  applyReactive(target, frame, nowMs);

  if (!initialized_) {
    reset(target, nowMs);
    return current_;
  }

  return smoothToward(target, nowMs);
}

FaceTargets FaceAnimator::samplePose(const RobotFrame& frame, uint32_t nowMs) const {
  (void)nowMs;
  return frame.face;
}

void FaceAnimator::applyAutonomic(FaceTargets& face, const RobotFrame& frame, uint32_t nowMs) const {
  (void)face;
  (void)frame;
  (void)nowMs;
}

void FaceAnimator::applyGesture(FaceTargets& face, const RobotFrame& frame, uint32_t nowMs) const {
  (void)face;
  (void)frame;
  (void)nowMs;
}

void FaceAnimator::applyReactive(FaceTargets& face, const RobotFrame& frame, uint32_t nowMs) const {
  (void)face;
  (void)frame;
  (void)nowMs;
}

FaceTargets FaceAnimator::smoothToward(const FaceTargets& target, uint32_t nowMs) {
  const float dtMs = static_cast<float>(nowMs - lastMs_);
  lastMs_ = nowMs;

  current_.eyeOpen = smoothChannel(current_.eyeOpen, target.eyeOpen, dtMs, 60.0f);
  current_.squint = smoothChannel(current_.squint, target.squint, dtMs, 60.0f);
  current_.eyeSmile = smoothChannel(current_.eyeSmile, target.eyeSmile, dtMs, 60.0f);
  current_.pupilX = smoothChannel(current_.pupilX, target.pupilX, dtMs, 80.0f);
  current_.pupilY = smoothChannel(current_.pupilY, target.pupilY, dtMs, 80.0f);
  current_.browTilt = smoothChannel(current_.browTilt, target.browTilt, dtMs, 110.0f);
  current_.mouthSmile = smoothChannel(current_.mouthSmile, target.mouthSmile, dtMs, 140.0f);
  current_.mouthOpen = smoothChannel(current_.mouthOpen, target.mouthOpen, dtMs, 140.0f);
  return current_;
}

}  // namespace stackchan
