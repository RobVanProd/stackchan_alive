#pragma once

#include "face/ExpressionMapper.hpp"
#include "persona/EmbodiedEnergy.hpp"
#include "persona/EmotionModel.hpp"
#include "persona/GazeTracker.hpp"
#include "persona/HeadGaze.hpp"
#include "persona/IdleLife.hpp"
#include "persona/SpeechPlanner.hpp"
#include "persona/StateMatrix.hpp"

// Demo mode injects a random mode change and a synthetic event every 2.5-6 s.
// That is useful on a bench when showing the face off, and actively harmful the
// rest of the time: it makes the character look random rather than responsive,
// and because every injected event counts as stimulus the robot can never
// accumulate enough drowsiness to fall asleep. The character design has him
// getting heavy-lidded at fatigue 0.45, yawning at 0.62 and asleep at 0.80 after
// roughly 8.5 idle minutes, and none of that can happen while demo mode runs.
//
// Every native test covering sleep, idle life, or character behaviour calls
// setDemoEnabled(false) first for exactly this reason, so the behaviour under
// test was never the shipped default. Boot with it off; `demo on` over serial
// still turns it on for a bench demonstration.
#ifndef STACKCHAN_DEMO_ENABLED_AT_BOOT
#define STACKCHAN_DEMO_ENABLED_AT_BOOT 0
#endif

namespace stackchan {

class IntentEngine {
 public:
  void begin();
  void applyEvent(const RobotEvent& event, CharacterMode mode);

  // Move to a mode without applying an emotional event. Used when a state change
  // is a continuation of something already accounted for, such as a reply
  // finally starting to produce audio after its response frame arrived. Refreshes
  // the event clock so the mode-decay timers do not immediately unwind it. Has no
  // effect while asleep; waking requires a rousing event.
  void setMode(CharacterMode mode, uint32_t nowMs);
  void queueSpeechCue(const SpeechCue& cue, uint32_t nowMs);
  void startResponseGesture(ResponseGesture gesture, uint32_t seed, uint32_t nowMs);
  void applyCircadian(uint8_t hourOfDay);
  void applyAmbient(float lux, uint8_t hourOfDay);
  void setEmbodiedEnergy(const EmbodiedEnergyInput& input, uint32_t nowMs) {
    energy_.updateInput(input, nowMs);
  }
  void setDemoEnabled(bool enabled, uint32_t nowMs);
  void setReducedMotion(bool enabled);
  void setMotionOutputActive(bool active, uint32_t nowMs) {
    gaze_.setMotionOutputActive(active, nowMs);
  }
  bool isDemoEnabled() const {
    return demoEnabled_;
  }
  bool isReducedMotion() const {
    return reducedMotion_;
  }
  const GazeTrackerTelemetry& gazeTelemetry() const {
    return gaze_.telemetry();
  }
  const EmbodiedEnergyTelemetry& energyTelemetry() const {
    return energy_.telemetry();
  }
  RobotFrame update(uint32_t nowMs);

  bool isAsleep() const {
    return mode_ == CharacterMode::Sleep;
  }

  // 0 wide awake .. 1 ready to drop off.
  float sleepPressure() const {
    return emotion_.sleepPressure();
  }

 private:
  EmotionModel emotion_;
  EmbodiedEnergy energy_;
  ExpressionMapper expression_;
  GazeTracker gaze_;
  IdleLife idleLife_;
  SpeechPlanner speech_;
  CharacterMode mode_ = CharacterMode::Idle;
  CharacterMode lastSpeechMode_ = CharacterMode::Idle;
  uint32_t seq_ = 0;
  uint32_t speechSeq_ = 0;
  uint32_t nextDemoEventMs_ = 0;
  uint32_t lastUpdateMs_ = 0;
  uint32_t lastSpeechCueMs_ = 0;
  uint32_t activeSpeechUntilMs_ = 0;
  uint32_t soundOrientUntilMs_ = 0;
  uint32_t lastEventAtMs_ = 0;
  bool demoEnabled_ = STACKCHAN_DEMO_ENABLED_AT_BOOT != 0;
  bool reducedMotion_ = false;
  float soundAzimuthNorm_ = 0.0f;
  float lastEventStrength_ = 0.0f;
  EventType lastEventType_ = EventType::Boot;
  SpeechIntent lastSpeechIntent_ = SpeechIntent::None;
  SpeechCue activeSpeech_;
  ResponseGesture responseGesture_ = ResponseGesture::None;
  uint32_t responseGestureStartedMs_ = 0;
  uint16_t responseGestureDurationMs_ = 0;
  float responseGestureAmplitudeDeg_ = 0.0f;
  float responseGestureCycles_ = 0.0f;
  HeadGaze headGaze_;
  uint32_t sleepEnteredAtMs_ = 0;

  void injectDemoEvents(uint32_t nowMs);
  void updateSpeechCue(uint32_t nowMs);
  void activateSpeechCue(const SpeechCue& cue, uint32_t nowMs);
  MotionTargets motionForMode(uint32_t nowMs, const EmotionalProfile& emotion);
  void applySoundOrientation(RobotFrame& frame, uint32_t nowMs) const;
  void applyResponseGesture(RobotFrame& frame, uint32_t nowMs);
  void updateSleepState(uint32_t nowMs);
};

}  // namespace stackchan
