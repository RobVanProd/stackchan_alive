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
  blink_ = BlinkState {};
  saccade_ = SaccadeState {};
  fidget_ = FidgetState {};
  telemetry_ = FaceAutonomicTelemetry {};
}

void FaceAnimator::setReducedMotion(bool enabled) {
  reducedMotion_ = enabled;
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
      pose.eyeWidthScale = 1.0f;
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
      pose.eyeWidthScale = 1.0f;
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
      pose.eyeWidthScale = 1.0f;
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
      pose.eyeWidthScale = 1.0f;
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
      pose.eyeWidthScale = 1.0f;
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
      pose.eyeWidthScale = 1.0f;
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
      pose.eyeWidthScale = 1.0f;
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
  pose.eyeWidthScale = clampValue(pose.eyeWidthScale * mod.eyeWidthScale, 0.85f, 1.18f);
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

void FaceAnimator::applyAutonomic(FaceTargets& face, const RobotFrame& frame, uint32_t nowMs) {
  const float motionScale = reducedMotion_ ? 0.30f : 1.0f;
  const bool sleeping = frame.mode == CharacterMode::Sleep;
  const float blinkOpen = updateBlink(frame, nowMs);
  const float blinkCompression = 1.0f - clampValue(blinkOpen, 0.0f, 1.0f);

  face.eyeOpen = clampValue(face.eyeOpen * blinkOpen, 0.02f, 1.08f);
  face.eyeWidthScale = clampValue(face.eyeWidthScale + blinkCompression * 0.15f * motionScale, 0.85f, 1.20f);

  updateSaccade(frame, nowMs);
  face.pupilX = clampValue(face.pupilX + saccade_.offsetX * motionScale, -1.0f, 1.0f);
  face.pupilY = clampValue(face.pupilY + saccade_.offsetY * motionScale, -1.0f, 1.0f);

  const float breathHz = sleeping ? 0.12f : 0.20f;
  const float breathAmp = (sleeping ? 3.0f : 1.5f) * motionScale;
  const float breathY = sinf(static_cast<float>(nowMs) * 0.001f * 6.2831853f * breathHz) * breathAmp;
  const float stageX = saccade_.offsetX * 4.0f * motionScale;
  const float stageY = saccade_.offsetY * 3.0f * motionScale;
  face.faceX += stageX;
  face.faceY += breathY + stageY;

  updateFidget(face, frame, nowMs, motionScale);

  telemetry_.blinkOpen = blinkOpen;
  telemetry_.breathY = breathY;
  telemetry_.gazeX = saccade_.offsetX;
  telemetry_.gazeY = saccade_.offsetY;
  telemetry_.blinkCount = blink_.count;
  telemetry_.saccadeCount = saccade_.count;
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
  current_.eyeWidthScale = smoothChannel(current_.eyeWidthScale, target.eyeWidthScale, dtMs, 40.0f);
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

float FaceAnimator::updateBlink(const RobotFrame& frame, uint32_t nowMs) {
  if (blink_.nextMs == 0) {
    blink_.nextMs = nowMs + 1500;
  }

  const bool sleeping = frame.mode == CharacterMode::Sleep;
  float open = 1.0f;
  switch (blink_.phase) {
    case BlinkPhase::Open:
      if (nowMs >= blink_.nextMs) {
        startBlink(frame, nowMs);
      }
      open = 1.0f;
      break;
    case BlinkPhase::Closing: {
      const float p = clampValue(static_cast<float>(nowMs - blink_.phaseStartMs) / blink_.phaseDurationMs, 0.0f, 1.0f);
      open = 1.0f - applyEase(Ease::InQuad, p);
      if (p >= 1.0f) {
        blink_.phase = BlinkPhase::Hold;
        blink_.phaseStartMs = nowMs;
        blink_.phaseDurationMs = randomRange(30, 60);
        open = sleeping ? 0.45f : 0.0f;
      }
      break;
    }
    case BlinkPhase::Hold:
      open = sleeping ? 0.45f : 0.0f;
      if (nowMs - blink_.phaseStartMs >= blink_.phaseDurationMs) {
        blink_.phase = BlinkPhase::Opening;
        blink_.phaseStartMs = nowMs;
        blink_.phaseDurationMs = sleeping ? randomRange(260, 420) : randomRange(140, 200);
      }
      break;
    case BlinkPhase::Opening: {
      const float p = clampValue(static_cast<float>(nowMs - blink_.phaseStartMs) / blink_.phaseDurationMs, 0.0f, 1.0f);
      const float opened = applyEase(Ease::OutBack, p);
      open = sleeping ? clampValue(0.45f + opened * 0.55f, 0.45f, 1.05f) : clampValue(opened, 0.0f, 1.05f);
      if (p >= 1.0f) {
        blink_.phase = BlinkPhase::Open;
        if (blink_.queuedBlinks > 0) {
          blink_.queuedBlinks--;
          scheduleBlink(frame, nowMs, 120);
        } else {
          scheduleBlink(frame, nowMs);
        }
        open = 1.0f;
      }
      break;
    }
  }

  blink_.open = open;
  return open;
}

void FaceAnimator::scheduleBlink(const RobotFrame& frame, uint32_t nowMs, uint32_t minDelayMs) {
  const bool sleeping = frame.mode == CharacterMode::Sleep;
  float u = clampValue(randomUnit(), 0.001f, 0.999f);
  uint32_t delayMs = static_cast<uint32_t>(2000.0f + (-logf(1.0f - u) * 2500.0f));
  delayMs = constrain(delayMs, sleeping ? 2400u : 1500u, sleeping ? 9000u : 8000u);

  if (frame.mode == CharacterMode::Listen || frame.mode == CharacterMode::Attend) {
    delayMs = static_cast<uint32_t>(static_cast<float>(delayMs) * 1.30f);
  } else if (frame.mode == CharacterMode::Think || frame.mode == CharacterMode::Error) {
    delayMs = static_cast<uint32_t>(static_cast<float>(delayMs) * 0.75f);
  }
  if (frame.emotion.fatigue > 0.55f) {
    delayMs = static_cast<uint32_t>(static_cast<float>(delayMs) * 0.70f);
  }
  if (minDelayMs > 0 && delayMs < minDelayMs) {
    delayMs = minDelayMs;
  }
  blink_.nextMs = nowMs + delayMs;
}

void FaceAnimator::startBlink(const RobotFrame& frame, uint32_t nowMs) {
  blink_.phase = BlinkPhase::Closing;
  blink_.phaseStartMs = nowMs;
  blink_.phaseDurationMs = frame.mode == CharacterMode::Sleep ? randomRange(180, 280) : randomRange(60, 80);
  blink_.count++;
  if (frame.mode != CharacterMode::Sleep && blink_.queuedBlinks == 0 && randomRange(0, 99) < 12) {
    blink_.queuedBlinks = 1;
  }
}

void FaceAnimator::updateSaccade(const RobotFrame& frame, uint32_t nowMs) {
  if (saccade_.nextMs == 0) {
    scheduleSaccade(frame, nowMs);
  }

  if (nowMs >= saccade_.nextMs) {
    float nextX = 0.0f;
    float nextY = 0.0f;
    chooseSaccadeTarget(frame, nextX, nextY);
    const float travelX = nextX - saccade_.offsetX;
    const float travelY = nextY - saccade_.offsetY;
    const float travel = sqrtf(travelX * travelX + travelY * travelY);
    saccade_.startX = saccade_.offsetX;
    saccade_.startY = saccade_.offsetY;
    saccade_.targetX = nextX;
    saccade_.targetY = nextY;
    saccade_.overshootX = nextX + travelX * 0.15f;
    saccade_.overshootY = nextY + travelY * 0.15f;
    saccade_.offsetX = saccade_.overshootX;
    saccade_.offsetY = saccade_.overshootY;
    saccade_.settleStartMs = nowMs;
    saccade_.settling = true;
    saccade_.count++;
    if (travel > 0.50f && randomRange(0, 99) < 40 && blink_.phase == BlinkPhase::Open) {
      blink_.nextMs = nowMs;
    }
    scheduleSaccade(frame, nowMs);
  }

  if (saccade_.settling) {
    const float p = clampValue(static_cast<float>(nowMs - saccade_.settleStartMs) / 80.0f, 0.0f, 1.0f);
    const float e = applyEase(Ease::OutBack, p);
    saccade_.offsetX = saccade_.overshootX + (saccade_.targetX - saccade_.overshootX) * e;
    saccade_.offsetY = saccade_.overshootY + (saccade_.targetY - saccade_.overshootY) * e;
    if (p >= 1.0f) {
      saccade_.offsetX = saccade_.targetX;
      saccade_.offsetY = saccade_.targetY;
      saccade_.settling = false;
    }
  }
}

void FaceAnimator::scheduleSaccade(const RobotFrame& frame, uint32_t nowMs) {
  uint32_t minHold = 500;
  uint32_t maxHold = 3000;
  if (frame.mode == CharacterMode::Listen || frame.mode == CharacterMode::Attend) {
    minHold = 900;
    maxHold = 2600;
  } else if (frame.mode == CharacterMode::Think) {
    minHold = 1000;
    maxHold = 2000;
  } else if (frame.mode == CharacterMode::Error || frame.mode == CharacterMode::Sleep) {
    minHold = 1400;
    maxHold = 3600;
  }
  saccade_.nextMs = nowMs + randomRange(minHold, maxHold);
}

void FaceAnimator::chooseSaccadeTarget(const RobotFrame& frame, float& x, float& y) {
  switch (frame.mode) {
    case CharacterMode::Listen:
    case CharacterMode::Attend:
      x = randomSigned(0.08f);
      y = randomSigned(0.05f);
      return;
    case CharacterMode::Think:
      x = randomRange(0, 1) == 0 ? -0.50f : 0.50f;
      y = -0.38f + randomSigned(0.08f);
      return;
    case CharacterMode::Error:
      x = randomSigned(0.18f);
      y = 0.25f + randomSigned(0.10f);
      return;
    case CharacterMode::Sleep:
      x = randomSigned(0.05f);
      y = 0.20f + randomSigned(0.06f);
      return;
    default:
      if (randomRange(0, 9) == 0) {
        x = randomSigned(0.65f);
        y = randomSigned(0.32f);
      } else {
        x = randomSigned(0.18f);
        y = randomSigned(0.10f);
      }
      return;
  }
}

void FaceAnimator::updateFidget(FaceTargets& face, const RobotFrame& frame, uint32_t nowMs, float motionScale) {
  const bool canFidget = frame.mode == CharacterMode::Idle || frame.mode == CharacterMode::Boot;
  if (fidget_.nextMs == 0) {
    fidget_.nextMs = nowMs + randomRange(10000, 30000);
  }
  if (!canFidget) {
    fidget_.active = false;
    return;
  }
  if (!fidget_.active && nowMs >= fidget_.nextMs) {
    fidget_.active = true;
    fidget_.startMs = nowMs;
    fidget_.durationMs = randomRange(700, 1200);
    fidget_.kind = static_cast<uint8_t>(randomRange(0, 2));
    fidget_.nextMs = nowMs + randomRange(10000, 30000);
  }
  if (!fidget_.active) {
    return;
  }

  const float p = clampValue(static_cast<float>(nowMs - fidget_.startMs) / fidget_.durationMs, 0.0f, 1.0f);
  const float pulse = sinf(p * 3.1415927f);
  if (fidget_.kind == 0) {
    face.eyeOpen = clampValue(face.eyeOpen - pulse * 0.22f * motionScale, 0.08f, 1.08f);
    face.faceY -= pulse * 2.0f * motionScale;
  } else {
    face.browTilt += pulse * 0.18f * motionScale;
  }
  if (p >= 1.0f) {
    fidget_.active = false;
  }
}

uint32_t FaceAnimator::randomRange(uint32_t low, uint32_t high) {
  if (high <= low) {
    return low;
  }
  rng_ ^= rng_ << 13;
  rng_ ^= rng_ >> 17;
  rng_ ^= rng_ << 5;
  return low + (rng_ % (high - low + 1));
}

float FaceAnimator::randomUnit() {
  return static_cast<float>(randomRange(0, 10000)) / 10000.0f;
}

float FaceAnimator::randomSigned(float amplitude) {
  return (randomUnit() * 2.0f - 1.0f) * amplitude;
}

}  // namespace stackchan
