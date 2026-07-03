#include "persona/IntentEngine.hpp"

#include <Arduino.h>
#include <math.h>

namespace stackchan {

namespace {
constexpr uint32_t kSpeechCueHoldMs = 650;
constexpr uint32_t kIdleSpeechCooldownMs = 12000;
}

void IntentEngine::begin() {
  emotion_.reset();
  mode_ = CharacterMode::Idle;
  lastSpeechMode_ = mode_;
  seq_ = 0;
  speechSeq_ = 0;
  lastUpdateMs_ = millis();
  lastSpeechCueMs_ = 0;
  activeSpeechUntilMs_ = 0;
  soundOrientUntilMs_ = 0;
  demoEnabled_ = true;
  reducedMotion_ = false;
  soundAzimuthNorm_ = 0.0f;
  lastSpeechIntent_ = SpeechIntent::None;
  activeSpeech_ = SpeechCue {};
  idleLife_.reset(lastUpdateMs_);
  nextDemoEventMs_ = lastUpdateMs_ + 3000;
}

void IntentEngine::applyEvent(const RobotEvent& event, CharacterMode mode) {
  mode_ = mode;
  emotion_.applyEvent(event);
  if (event.type == EventType::SoundDirection && event.hasPayload) {
    soundAzimuthNorm_ = constrain(event.x, -1.0f, 1.0f);
    soundOrientUntilMs_ = event.timestampMs + 1800;
  } else if (event.type == EventType::LoudNoise) {
    soundOrientUntilMs_ = event.timestampMs + 500;
  }
  nextDemoEventMs_ = event.timestampMs + 10000;
}

void IntentEngine::queueSpeechCue(const SpeechCue& cue, uint32_t nowMs) {
  if (!cue.shouldSpeak()) {
    return;
  }

  activateSpeechCue(cue, nowMs);
  // Command acknowledgments are intentional one-shots. Mark the current mode
  // as already handled so the mode planner does not overwrite the cue
  // during the same update tick.
  lastSpeechMode_ = mode_;
  lastSpeechIntent_ = cue.intent;
}

void IntentEngine::applyCircadian(uint8_t hourOfDay) {
  emotion_.applyCircadian(hourOfDay);
}

void IntentEngine::applyAmbient(float lux, uint8_t hourOfDay) {
  emotion_.applyAmbient(lux, hourOfDay);
}

void IntentEngine::setDemoEnabled(bool enabled, uint32_t nowMs) {
  demoEnabled_ = enabled;
  if (enabled) {
    nextDemoEventMs_ = nowMs + 3000;
  }
}

void IntentEngine::setReducedMotion(bool enabled) {
  reducedMotion_ = enabled;
}

RobotFrame IntentEngine::update(uint32_t nowMs) {
  injectDemoEvents(nowMs);

  const float dt = (nowMs - lastUpdateMs_) * 0.001f;
  lastUpdateMs_ = nowMs;
  emotion_.update(dt);
  updateSpeechCue(nowMs);

  RobotFrame frame;
  frame.seq = ++seq_;
  frame.timestampMs = nowMs;
  frame.mode = mode_;
  frame.emotion = emotion_.profile();
  frame.motion = motionForMode(nowMs);
  frame.face = expression_.map(frame.emotion, mode_);
  idleLife_.apply(frame, nowMs, reducedMotion_);
  applySoundOrientation(frame, nowMs);
  if (nowMs < activeSpeechUntilMs_ && activeSpeech_.shouldSpeak()) {
    frame.speech = activeSpeech_;
    frame.speechSeq = speechSeq_;
  }
  return frame;
}

void IntentEngine::injectDemoEvents(uint32_t nowMs) {
  if (!demoEnabled_) {
    return;
  }
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

void IntentEngine::updateSpeechCue(uint32_t nowMs) {
  const EmotionalProfile& emotion = emotion_.profile();
  const SpeechCue cue = speech_.plan(mode_, emotion);
  const bool modeChanged = mode_ != lastSpeechMode_;
  const bool cueChanged = cue.intent != lastSpeechIntent_;
  const bool idleCooldownReady = lastSpeechCueMs_ == 0 || nowMs - lastSpeechCueMs_ >= kIdleSpeechCooldownMs;

  if (cue.shouldSpeak() && (modeChanged || (mode_ == CharacterMode::Idle && cueChanged && idleCooldownReady))) {
    activateSpeechCue(cue, nowMs);
  }

  lastSpeechMode_ = mode_;
  if (nowMs >= activeSpeechUntilMs_) {
    activeSpeech_ = SpeechCue {};
  }
}

void IntentEngine::activateSpeechCue(const SpeechCue& cue, uint32_t nowMs) {
  activeSpeech_ = cue;
  activeSpeechUntilMs_ = nowMs + kSpeechCueHoldMs;
  lastSpeechCueMs_ = nowMs;
  lastSpeechIntent_ = cue.intent;
  speechSeq_++;
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

void IntentEngine::applySoundOrientation(RobotFrame& frame, uint32_t nowMs) const {
  if (nowMs >= soundOrientUntilMs_) {
    return;
  }

  const float remaining = (soundOrientUntilMs_ - nowMs) / 1800.0f;
  const float gain = constrain(remaining, 0.0f, 1.0f);
  const float gaze = soundAzimuthNorm_ * gain;
  frame.face.pupilX += gaze * 0.35f;
  frame.face.faceX += gaze * 3.0f;
  if (frame.motion.yawMode == YawMode::Angle) {
    frame.motion.yawDeg += gaze * 16.0f;
  }
}

}  // namespace stackchan
