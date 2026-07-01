#include "persona/IntentEngine.hpp"

#include <Arduino.h>
#include <math.h>

namespace stackchan {

void IntentEngine::begin() {
  emotion_.reset();
  mode_ = CharacterMode::Idle;
  seq_ = 0;
  lastUpdateMs_ = millis();
  nextDemoEventMs_ = lastUpdateMs_ + 3000;
}

RobotFrame IntentEngine::update(uint32_t nowMs) {
  injectDemoEvents(nowMs);

  const float dt = (nowMs - lastUpdateMs_) * 0.001f;
  lastUpdateMs_ = nowMs;
  emotion_.update(dt);

  RobotFrame frame;
  frame.seq = ++seq_;
  frame.timestampMs = nowMs;
  frame.mode = mode_;
  frame.emotion = emotion_.profile();
  frame.motion = motionForMode(nowMs);
  frame.face = expression_.map(frame.emotion, mode_);
  return frame;
}

void IntentEngine::injectDemoEvents(uint32_t nowMs) {
  if (nowMs < nextDemoEventMs_) {
    return;
  }

  RobotEvent event;
  event.timestampMs = nowMs;
  event.strength = 1.0f;

  const uint8_t choice = random(0, 5);
  if (choice == 0) {
    mode_ = CharacterMode::Attend;
    event.type = EventType::FaceDetected;
  } else if (choice == 1) {
    mode_ = CharacterMode::Listen;
    event.type = EventType::WakeWord;
  } else if (choice == 2) {
    mode_ = CharacterMode::Think;
    event.type = EventType::ThinkingStarted;
  } else if (choice == 3) {
    mode_ = CharacterMode::Speak;
    event.type = EventType::ResponseStarted;
  } else {
    mode_ = CharacterMode::Idle;
    event.type = EventType::IdleTimeout;
  }

  emotion_.applyEvent(event);
  nextDemoEventMs_ = nowMs + random(2500, 6000);
}

MotionTargets IntentEngine::motionForMode(uint32_t nowMs) const {
  MotionTargets motion;
  const float t = nowMs * 0.001f;

  motion.yawMode = YawMode::Angle;
  motion.yawDeg = sinf(t * 0.27f) * 12.0f;
  motion.pitchDeg = sinf(t * 0.19f) * 4.0f;

  if (mode_ == CharacterMode::Listen) {
    motion.pitchDeg += -4.0f;
  } else if (mode_ == CharacterMode::Think) {
    motion.yawDeg += 18.0f;
    motion.pitchDeg += 2.0f;
  } else if (mode_ == CharacterMode::Sleep) {
    motion.pitchDeg += 10.0f;
    motion.yawMode = YawMode::Disabled;
  }

  return motion;
}

}  // namespace stackchan
