#include "persona/ActiveSpeakerTracker.hpp"

#include <math.h>

namespace stackchan {

namespace {
constexpr uint32_t kSoundFreshMs = 1600;
constexpr uint32_t kFaceHoldMs = 2400;
constexpr uint32_t kReplyHoldMaxMs = 30000;
constexpr float kSmoothing = 0.42f;

float clampSigned(float value) {
  return constrain(value, -1.0f, 1.0f);
}

float clamp01(float value) {
  return constrain(value, 0.0f, 1.0f);
}
}  // namespace

void ActiveSpeakerTracker::reset(uint32_t nowMs) {
  target_ = ActiveSpeakerTarget {};
  soundAzimuthNorm_ = 0.0f;
  soundStrength_ = 0.0f;
  soundAtMs_ = nowMs;
  lastFaceAtMs_ = 0;
  replyStartedAtMs_ = 0;
  robotSpeaking_ = false;
}

void ActiveSpeakerTracker::updateSoundDirection(float azimuthNorm, float strength, uint32_t nowMs) {
  if (robotSpeaking_) {
    return;
  }
  soundAzimuthNorm_ = clampSigned(azimuthNorm);
  soundStrength_ = clamp01(strength);
  soundAtMs_ = nowMs;
}

ActiveSpeakerTarget ActiveSpeakerTracker::updateFaces(const FaceCandidate* faces,
                                                       uint8_t count,
                                                       uint32_t nowMs) {
  if (robotSpeaking_ && target_.valid) {
    target_.heldForReply = true;
    return target_;
  }
  if (faces == nullptr || count == 0) {
    return target(nowMs);
  }

  count = min(count, kActiveSpeakerMaxFaces);
  const bool audioFresh = soundAtMs_ != 0 && nowMs - soundAtMs_ <= kSoundFreshMs && soundStrength_ >= 0.12f;
  uint8_t best = 0;
  float bestScore = -1000.0f;
  for (uint8_t i = 0; i < count; ++i) {
    const float x = clampSigned(faces[i].x);
    const float size = clamp01(faces[i].size);
    const float confidence = clamp01(faces[i].confidence);
    float score = size * 0.85f + confidence * 0.35f - fabsf(x) * 0.12f;
    if (audioFresh) {
      score += (1.0f - clamp01(fabsf(x - soundAzimuthNorm_) * 0.5f)) * (1.15f + soundStrength_);
    }
    if (score > bestScore) {
      bestScore = score;
      best = i;
    }
  }

  const FaceCandidate& selected = faces[best];
  if (!target_.valid) {
    target_.x = clampSigned(selected.x);
    target_.y = clampSigned(selected.y);
    target_.size = clamp01(selected.size);
  } else {
    target_.x += (clampSigned(selected.x) - target_.x) * kSmoothing;
    target_.y += (clampSigned(selected.y) - target_.y) * kSmoothing;
    target_.size += (clamp01(selected.size) - target_.size) * kSmoothing;
  }
  target_.valid = true;
  target_.confidence = clamp01(selected.confidence);
  target_.audioMatched = audioFresh;
  target_.heldForReply = false;
  target_.selectedAtMs = nowMs;
  lastFaceAtMs_ = nowMs;
  return target_;
}

void ActiveSpeakerTracker::setRobotSpeaking(bool speaking, uint32_t nowMs) {
  if (speaking && !robotSpeaking_) {
    replyStartedAtMs_ = nowMs;
  }
  if (!speaking) {
    replyStartedAtMs_ = 0;
    target_.heldForReply = false;
  }
  robotSpeaking_ = speaking;
}

ActiveSpeakerTarget ActiveSpeakerTracker::target(uint32_t nowMs) const {
  ActiveSpeakerTarget result = target_;
  if (!result.valid) {
    return result;
  }
  const bool replyHold = robotSpeaking_ && replyStartedAtMs_ != 0 &&
                         nowMs - replyStartedAtMs_ <= kReplyHoldMaxMs;
  if (!replyHold && (lastFaceAtMs_ == 0 || nowMs - lastFaceAtMs_ > kFaceHoldMs)) {
    return ActiveSpeakerTarget {};
  }
  result.heldForReply = replyHold;
  return result;
}

}  // namespace stackchan
