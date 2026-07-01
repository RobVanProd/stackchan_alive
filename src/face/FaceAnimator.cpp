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

float clampValue(float value, float low, float high) {
  if (value < low) {
    return low;
  }
  if (value > high) {
    return high;
  }
  return value;
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
  FaceTargets pose;

  switch (frame.mode) {
    case CharacterMode::Boot:
    case CharacterMode::Idle:
      pose.eyeOpen = 0.84f;
      pose.eyeSmile = 0.12f;
      pose.browTilt = 0.12f;
      pose.mouthSmile = 0.22f;
      pose.mouthWidthDelta = 2.0f;
      pose.leftCorners.tr = 0.04f;
      pose.rightCorners.tl = 0.07f;
      break;
    case CharacterMode::Attend:
    case CharacterMode::Listen:
      pose.eyeOpen = 0.94f;
      pose.eyeSmile = 0.06f;
      pose.browTilt = 0.20f;
      pose.pupilX = -0.03f;
      pose.pupilScale = 1.05f;
      pose.mouthSmile = 0.10f;
      pose.mouthWidthDelta = -2.0f;
      pose.leftCorners.bl = 0.04f;
      pose.rightCorners.br = 0.08f;
      break;
    case CharacterMode::Think:
      pose.eyeOpen = 0.78f;
      pose.eyeSmile = 0.03f;
      pose.squint = 0.08f;
      pose.pupilX = 0.18f;
      pose.pupilY = -0.22f;
      pose.pupilScale = 0.95f;
      pose.browTilt = 0.12f;
      pose.mouthSmile = 0.08f;
      pose.mouthWidthDelta = -8.0f;
      pose.mouthCornerL = -1.0f;
      pose.mouthCornerR = 1.0f;
      pose.leftCorners.tr = 0.30f;
      pose.rightCorners.tl = 0.04f;
      pose.rightCorners.br = 0.06f;
      pose.upperLidTilt = 0.08f;
      break;
    case CharacterMode::Speak:
      pose.eyeOpen = 0.90f;
      pose.eyeSmile = 0.08f;
      pose.pupilScale = 1.08f;
      pose.browTilt = 0.18f;
      pose.mouthSmile = 0.18f;
      pose.mouthOpen = 0.45f;
      pose.mouthWidthDelta = 4.0f;
      pose.leftCorners.bl = 0.05f;
      pose.rightCorners.br = 0.10f;
      break;
    case CharacterMode::React:
      pose.eyeOpen = 0.92f;
      pose.eyeSmile = 0.62f;
      pose.pupilScale = 1.14f;
      pose.browTilt = 0.28f;
      pose.mouthSmile = 0.80f;
      pose.mouthWidthDelta = 10.0f;
      pose.mouthCornerL = 2.0f;
      pose.mouthCornerR = 1.0f;
      pose.leftCorners.bl = 0.16f;
      pose.leftCorners.br = 0.26f;
      pose.rightCorners.bl = 0.12f;
      pose.rightCorners.br = 0.20f;
      pose.lowerLidTilt = -0.08f;
      break;
    case CharacterMode::Sleep:
      pose.eyeOpen = 0.28f;
      pose.eyeSmile = 0.08f;
      pose.pupilScale = 0.9f;
      pose.browTilt = -0.16f;
      pose.mouthSmile = -0.06f;
      pose.mouthWidthDelta = -14.0f;
      pose.mouthCornerL = -3.0f;
      pose.mouthCornerR = 3.0f;
      pose.leftCorners.tr = 0.06f;
      pose.leftCorners.bl = 0.12f;
      pose.rightCorners.tl = 0.14f;
      pose.rightCorners.br = 0.28f;
      pose.upperLidTilt = 0.06f;
      pose.lowerLidTilt = -0.04f;
      pose.faceY = 3.0f;
      break;
    case CharacterMode::Error:
      pose.eyeOpen = 0.66f;
      pose.squint = 0.40f;
      pose.eyeSmile = 0.0f;
      pose.pupilY = 0.12f;
      pose.pupilScale = 0.88f;
      pose.browTilt = -0.36f;
      pose.mouthSmile = -0.56f;
      pose.mouthWidthDelta = -4.0f;
      pose.mouthCornerL = -3.0f;
      pose.mouthCornerR = 1.0f;
      pose.leftCorners.tl = 0.35f;
      pose.rightCorners.tl = 0.50f;
      pose.leftCorners.br = 0.06f;
      pose.rightCorners.bl = 0.10f;
      pose.upperLidTilt = -0.15f;
      pose.lowerLidTilt = 0.08f;
      pose.faceY = 2.0f;
      break;
  }

  const FaceTargets& mod = frame.face;
  pose.eyeOpen = clampValue(pose.eyeOpen + (mod.eyeOpen - 0.85f) * 0.35f, 0.05f, 1.08f);
  pose.squint = clampValue(pose.squint + mod.squint * 0.15f, 0.0f, 1.0f);
  pose.eyeSmile = clampValue(pose.eyeSmile + mod.eyeSmile * 0.20f, 0.0f, 1.0f);
  pose.pupilX = clampValue(pose.pupilX + mod.pupilX * 0.25f, -1.0f, 1.0f);
  pose.pupilY = clampValue(pose.pupilY + mod.pupilY * 0.35f, -1.0f, 1.0f);
  pose.pupilScale = clampValue(pose.pupilScale * (0.85f + frame.emotion.arousal * 0.30f), 0.70f, 1.25f);
  pose.browTilt = clampValue(pose.browTilt + mod.browTilt * 0.20f, -1.0f, 1.0f);
  pose.mouthSmile = clampValue(pose.mouthSmile + mod.mouthSmile * 0.18f, -1.0f, 1.0f);
  pose.mouthOpen = clampValue(max(pose.mouthOpen, mod.mouthOpen), 0.0f, 1.0f);
  pose.mouthWidthDelta += pose.mouthSmile * 12.0f;
  return pose;
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
  current_.pupilScale = smoothChannel(current_.pupilScale, target.pupilScale, dtMs, 80.0f);
  current_.browTilt = smoothChannel(current_.browTilt, target.browTilt, dtMs, 110.0f);
  current_.mouthSmile = smoothChannel(current_.mouthSmile, target.mouthSmile, dtMs, 140.0f);
  current_.mouthOpen = smoothChannel(current_.mouthOpen, target.mouthOpen, dtMs, 140.0f);
  current_.mouthWidthDelta = smoothChannel(current_.mouthWidthDelta, target.mouthWidthDelta, dtMs, 140.0f);
  current_.mouthCornerL = smoothChannel(current_.mouthCornerL, target.mouthCornerL, dtMs, 140.0f);
  current_.mouthCornerR = smoothChannel(current_.mouthCornerR, target.mouthCornerR, dtMs, 140.0f);
  current_.upperLidTilt = smoothChannel(current_.upperLidTilt, target.upperLidTilt, dtMs, 40.0f);
  current_.lowerLidTilt = smoothChannel(current_.lowerLidTilt, target.lowerLidTilt, dtMs, 40.0f);
  current_.faceX = smoothChannel(current_.faceX, target.faceX, dtMs, 250.0f);
  current_.faceY = smoothChannel(current_.faceY, target.faceY, dtMs, 250.0f);
  current_.leftCorners.tl = smoothChannel(current_.leftCorners.tl, target.leftCorners.tl, dtMs, 60.0f);
  current_.leftCorners.tr = smoothChannel(current_.leftCorners.tr, target.leftCorners.tr, dtMs, 60.0f);
  current_.leftCorners.bl = smoothChannel(current_.leftCorners.bl, target.leftCorners.bl, dtMs, 60.0f);
  current_.leftCorners.br = smoothChannel(current_.leftCorners.br, target.leftCorners.br, dtMs, 60.0f);
  current_.rightCorners.tl = smoothChannel(current_.rightCorners.tl, target.rightCorners.tl, dtMs, 60.0f);
  current_.rightCorners.tr = smoothChannel(current_.rightCorners.tr, target.rightCorners.tr, dtMs, 60.0f);
  current_.rightCorners.bl = smoothChannel(current_.rightCorners.bl, target.rightCorners.bl, dtMs, 60.0f);
  current_.rightCorners.br = smoothChannel(current_.rightCorners.br, target.rightCorners.br, dtMs, 60.0f);
  return current_;
}

}  // namespace stackchan
