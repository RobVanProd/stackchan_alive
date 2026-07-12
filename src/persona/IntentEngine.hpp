#pragma once

#include "face/ExpressionMapper.hpp"
#include "persona/EmbodiedEnergy.hpp"
#include "persona/EmotionModel.hpp"
#include "persona/GazeTracker.hpp"
#include "persona/IdleLife.hpp"
#include "persona/SpeechPlanner.hpp"
#include "persona/StateMatrix.hpp"

namespace stackchan {

class IntentEngine {
 public:
  void begin();
  void applyEvent(const RobotEvent& event, CharacterMode mode);
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
  bool demoEnabled_ = true;
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

  void injectDemoEvents(uint32_t nowMs);
  void updateSpeechCue(uint32_t nowMs);
  void activateSpeechCue(const SpeechCue& cue, uint32_t nowMs);
  MotionTargets motionForMode(uint32_t nowMs, const EmotionalProfile& emotion) const;
  void applySoundOrientation(RobotFrame& frame, uint32_t nowMs) const;
  void applyResponseGesture(RobotFrame& frame, uint32_t nowMs);
};

}  // namespace stackchan
