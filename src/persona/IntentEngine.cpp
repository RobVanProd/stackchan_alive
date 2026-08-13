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

// Defined with the rest of the sleep policy further down.
bool rousesFromSleep(EventType type);
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
  demoEnabled_ = STACKCHAN_DEMO_ENABLED_AT_BOOT != 0;
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
  headGaze_.reset(lastUpdateMs_);
  sleepEnteredAtMs_ = 0;
}

void IntentEngine::setMode(CharacterMode mode, uint32_t nowMs) {
  if (mode_ == CharacterMode::Sleep) {
    return;
  }
  mode_ = mode;
  lastEventAtMs_ = nowMs;
}

void IntentEngine::applyEvent(const RobotEvent& event, CharacterMode mode) {
  // Being asleep is a state you have to be roused out of. Touch, a wake phrase,
  // being picked up, or a loud noise wakes him; his own bookkeeping does not.
  if (mode_ == CharacterMode::Sleep && !rousesFromSleep(event.type)) {
    lastEventType_ = event.type;
    lastEventAtMs_ = event.timestampMs;
    emotion_.applyEvent(event);
    return;
  }
  if (mode_ == CharacterMode::Sleep) {
    headGaze_.release(event.timestampMs);
    sleepEnteredAtMs_ = 0;
  }
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

void IntentEngine::seedEntropy(uint32_t seed) {
  // Distinct derived streams per module so one shared seed cannot phase-lock
  // the generators to each other.
  idleLife_.seedEntropy(seed * 0x9e3779b9UL + 0x7f4a7c15UL);
  headGaze_.seedEntropy(seed * 0x27d4eb2fUL + 0x165667b1UL);
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
  emotion_.update(dt, mode_ == CharacterMode::Sleep);
  updateSleepState(nowMs);
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
  // Demo events set mode_ directly rather than going through applyEvent, so
  // record them as events too. Without this the mode-decay timers see a stale
  // timestamp and unwind the state demo just set.
  lastEventType_ = event.type;
  lastEventAtMs_ = nowMs;
  lastEventStrength_ = constrain(event.strength, 0.0f, 1.0f);
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

namespace {
// Fatigue at which he gives up and drops off. Deliberately above the drowsy
// blend (0.45) and the yawn threshold (0.62) so the run-up is visible: heavy
// lids first, then yawns, then sleep.
constexpr float kSleepEnterFatigue = 0.80f;
// He must have been left alone at least this long, independent of fatigue, so a
// tired-but-busy character does not nod off mid-conversation.
constexpr uint32_t kSleepQuietMs = 45000;
// Minimum time asleep before an idle timeout could bounce him awake, so the
// transition cannot flicker.
constexpr uint32_t kSleepMinDurationMs = 4000;

// How long attention lingers after the thing that caused it.
//
// Attend and React are "something just happened" states, but nothing ever
// brought him out of them. bridgeModeForEvent maps ResponseEnded to Attend, and
// the only Attend->Idle path was a FaceLost event from host vision, which is not
// running. So after his last conversation he parked in Attend indefinitely, and
// demo mode's random IdleTimeout was the only thing that ever rescued him.
// Attention now decays on its own, which is also what lets sleep be reached.
//
constexpr uint32_t kAttentionDecayMs = 25000;

// Backstop for the bridge-driven conversation modes.
//
// Listen, Think, and Speak are entered by the host and normally closed by it.
// If the closing frame never arrives they latch forever: the reference robot was
// observed sitting in Speak for 152 consecutive samples with speech_active=0 and
// no audio ever played, because a ResponseStarted was never followed by a
// ResponseEnded. The socket was fine; only the conversation state was stranded.
//
// This window is deliberately far longer than any real reply so it cannot cut
// one short. It exists to recover from a lost end frame, not to pace speech.
constexpr uint32_t kConversationStallMs = 90000;

bool isBridgeDrivenMode(CharacterMode mode) {
  return mode == CharacterMode::Listen || mode == CharacterMode::Think ||
         mode == CharacterMode::Speak;
}

// Which events are loud enough to wake him.
bool rousesFromSleep(EventType type) {
  switch (type) {
    case EventType::WakeWord:
    case EventType::UserTouched:
    case EventType::PickedUp:
    case EventType::Shaken:
    case EventType::Tilted:
    case EventType::LoudNoise:
    case EventType::UserNear:
    case EventType::FaceDetected:
    case EventType::UserSpeaking:
    case EventType::Error:
      return true;
    default:
      return false;
  }
}
}  // namespace

void IntentEngine::updateSleepState(uint32_t nowMs) {
  const float fatigue = emotion_.profile().fatigue;

  if (mode_ == CharacterMode::Sleep) {
    // Stay down until something rouses him; applyEvent handles waking. Keep the
    // head parked at centre while he is out.
    headGaze_.holdHome();
    // If he has genuinely rested, let fatigue fall enough to wake naturally.
    if (nowMs - sleepEnteredAtMs_ > kSleepMinDurationMs && fatigue < 0.35f) {
      mode_ = CharacterMode::Idle;
      headGaze_.release(nowMs);
      sleepEnteredAtMs_ = 0;
    }
    return;
  }

  // Let lingering attention fade back to idle so he can settle at all.
  if ((mode_ == CharacterMode::Attend || mode_ == CharacterMode::React) &&
      nowMs - lastEventAtMs_ >= kAttentionDecayMs) {
    mode_ = CharacterMode::Idle;
  }

  // Recover from a conversation whose closing frame never arrived.
  if (isBridgeDrivenMode(mode_) && nowMs - lastEventAtMs_ >= kConversationStallMs) {
    mode_ = CharacterMode::Idle;
  }

  // Only drift off from a genuinely quiet idle. Any working mode keeps him up.
  if (mode_ != CharacterMode::Idle) {
    return;
  }
  if (fatigue < kSleepEnterFatigue) {
    return;
  }
  if (nowMs - lastEventAtMs_ < kSleepQuietMs) {
    return;
  }

  mode_ = CharacterMode::Sleep;
  sleepEnteredAtMs_ = nowMs;
  headGaze_.holdHome();
}

MotionTargets IntentEngine::motionForMode(uint32_t nowMs, const EmotionalProfile& emotion) {
  MotionTargets motion;
  const float t = nowMs * 0.001f;
  const float motionScale = reducedMotion_ ? generated_persona::kReducedMotionScale : 1.0f;
  const float energy = constrain(emotion.arousal, 0.0f, 1.0f);
  const float focus = constrain(emotion.focus, 0.0f, 1.0f);

  motion.yawMode = YawMode::Angle;
  // Idle head pose comes from a look-and-hold gaze rather than two sine waves.
  // The amplitude envelope is unchanged, so servo travel and load are the same;
  // only the path through it differs. Sines swayed continuously without ever
  // looking at anything, which is what read as aimless.
  const float yawSpanDeg = 3.0f + (1.0f - focus) * 5.0f;
  const float pitchSpanDeg = 0.8f + energy * 1.2f;
  headGaze_.update(nowMs, yawSpanDeg, pitchSpanDeg, focus, energy);
  motion.yawDeg = headGaze_.yawDeg() * motionScale;
  motion.pitchDeg = headGaze_.pitchDeg() * motionScale;

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
    // Head down, and come back to centre rather than freezing wherever he
    // happened to be looking. Disabled yaw only stops the servo, so hold Angle
    // until he has actually arrived home, then release to save holding torque.
    motion.pitchDeg += 10.0f;
    motion.yawDeg = headGaze_.yawDeg() * motionScale;
    motion.yawMode = fabsf(motion.yawDeg) > 0.5f ? YawMode::Angle : YawMode::Disabled;
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
