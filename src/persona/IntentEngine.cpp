#include "persona/IntentEngine.hpp"

#include <Arduino.h>
#include <math.h>

#include "PersonaBehavior.hpp"
#include "PersonaExpressions.hpp"

namespace stackchan {

namespace {
constexpr uint32_t kSpeechCueHoldMs = 650;
constexpr uint32_t kIdleSpeechCooldownMs = 12000;
constexpr float kPi = 3.1415927f;
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
  lastEventAtMs_ = lastUpdateMs_;
  demoEnabled_ = true;
  reducedMotion_ = false;
  soundAzimuthNorm_ = 0.0f;
  lastEventStrength_ = 0.0f;
  lastEventType_ = EventType::Boot;
  lastSpeechIntent_ = SpeechIntent::None;
  activeSpeech_ = SpeechCue {};
  responseGesture_ = ResponseGesture::None;
  responseGestureStartedMs_ = 0;
  responseGestureDurationMs_ = 0;
  responseGestureAmplitudeDeg_ = 0.0f;
  responseGestureCycles_ = 0.0f;
  idleLife_.reset(lastUpdateMs_);
  gaze_.reset(lastUpdateMs_);
  energy_.reset(lastUpdateMs_);
  nextDemoEventMs_ = lastUpdateMs_ + 3000;
}

void IntentEngine::applyEvent(const RobotEvent& event, CharacterMode mode) {
  mode_ = mode;
  lastEventType_ = event.type;
  lastEventAtMs_ = event.timestampMs;
  lastEventStrength_ = constrain(event.strength, 0.0f, 1.0f);
  emotion_.applyEvent(event);
  gaze_.applyEvent(event);
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

void IntentEngine::startResponseGesture(ResponseGesture gesture, uint32_t seed, uint32_t nowMs) {
  responseGesture_ = gesture;
  responseGestureStartedMs_ = nowMs;
  const uint32_t mixed = seed * 1664525u + 1013904223u;
  const float variant = static_cast<float>((mixed >> 16) & 0xffu) / 255.0f;
  if (gesture == ResponseGesture::Affirm) {
    responseGestureDurationMs_ = static_cast<uint16_t>(620u + (mixed % 181u));
    responseGestureAmplitudeDeg_ = 2.3f + variant * 1.0f;
    responseGestureCycles_ = 1.0f + variant * 0.18f;
  } else if (gesture == ResponseGesture::Deny) {
    responseGestureDurationMs_ = static_cast<uint16_t>(780u + (mixed % 241u));
    responseGestureAmplitudeDeg_ = 3.6f + variant * 1.4f;
    responseGestureCycles_ = 1.35f + variant * 0.25f;
  } else {
    responseGestureDurationMs_ = 0;
    responseGestureAmplitudeDeg_ = 0.0f;
    responseGestureCycles_ = 0.0f;
  }
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
  frame.emotion = energy_.shape(emotion_.profile(), dt);
  frame.motion = motionForMode(nowMs, frame.emotion);
  frame.face = expression_.map(frame.emotion, mode_);
  idleLife_.apply(frame, nowMs, reducedMotion_);
  applySoundOrientation(frame, nowMs);
  gaze_.apply(frame, nowMs, reducedMotion_);
  applyResponseGesture(frame, nowMs);
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

MotionTargets IntentEngine::motionForMode(uint32_t nowMs, const EmotionalProfile& emotion) const {
  MotionTargets motion;
  const float t = nowMs * 0.001f;
  const float motionScale = reducedMotion_ ? generated_persona::kReducedMotionScale : 1.0f;
  const float energy = constrain(emotion.arousal, 0.0f, 1.0f);
  const float focus = constrain(emotion.focus, 0.0f, 1.0f);

  motion.yawMode = YawMode::Angle;
  motion.yawDeg = sinf(t * 0.44f) * (3.0f + (1.0f - focus) * 5.0f) * motionScale;
  motion.pitchDeg = sinf(t * 0.31f) * (0.8f + energy * 1.2f) * motionScale;

  if (mode_ == CharacterMode::Attend || mode_ == CharacterMode::Listen) {
    motion.yawDeg *= 0.45f;
    motion.pitchDeg += generated_persona::kListenPitchBiasDeg;
    if (lastEventType_ == EventType::WakeWord && nowMs - lastEventAtMs_ < 900) {
      const float progress = constrain((nowMs - lastEventAtMs_) / 900.0f, 0.0f, 1.0f);
      motion.pitchDeg -= sinf(progress * 3.1415927f) * (2.8f + lastEventStrength_ * 1.8f) * motionScale;
    }
  } else if (mode_ == CharacterMode::Think) {
    motion.yawDeg = (generated_persona::kThinkYawBiasDeg + sinf(t * 0.72f) * 2.5f) * motionScale;
    motion.pitchDeg += (1.4f + energy * 1.2f) * motionScale;
  } else if (mode_ == CharacterMode::Speak) {
    const float cadenceHz = 0.34f + energy * 0.24f;
    const float cadence = sinf(t * 6.2831853f * cadenceHz);
    motion.pitchDeg -= cadence * (0.8f + energy * 2.0f) * motionScale;
    motion.yawDeg += cadence * emotion.valence * 2.2f * motionScale;
  } else if (mode_ == CharacterMode::React && nowMs - lastEventAtMs_ < 1200) {
    const float progress = constrain((nowMs - lastEventAtMs_) / 1200.0f, 0.0f, 1.0f);
    const float bounce = sinf(progress * 3.1415927f * 2.0f) * (1.0f - progress);
    motion.pitchDeg -= bounce * (3.0f + lastEventStrength_ * 2.5f) * motionScale;
  } else if (mode_ == CharacterMode::Error) {
    motion.yawDeg *= 0.20f;
    motion.pitchDeg = 1.5f * motionScale;
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
    frame.motion.yawDeg += gaze * generated_persona::kSoundDirectionYawBiasDeg;
  }
}

void IntentEngine::applyResponseGesture(RobotFrame& frame, uint32_t nowMs) {
  if (responseGesture_ == ResponseGesture::None || responseGestureDurationMs_ == 0 ||
      nowMs < responseGestureStartedMs_) {
    return;
  }
  const uint32_t elapsedMs = nowMs - responseGestureStartedMs_;
  if (elapsedMs >= responseGestureDurationMs_) {
    responseGesture_ = ResponseGesture::None;
    return;
  }

  const float progress = static_cast<float>(elapsedMs) / responseGestureDurationMs_;
  const float envelope = sinf(progress * kPi);
  const float wave = sinf(progress * 2.0f * kPi * responseGestureCycles_);
  const float motionScale = reducedMotion_ ? generated_persona::kReducedMotionScale : 1.0f;
  const float offset = wave * envelope * responseGestureAmplitudeDeg_ * motionScale;
  if (responseGesture_ == ResponseGesture::Affirm) {
    frame.motion.pitchDeg -= offset;
  } else if (responseGesture_ == ResponseGesture::Deny && frame.motion.yawMode == YawMode::Angle) {
    frame.motion.yawDeg += offset;
  }
}

}  // namespace stackchan
