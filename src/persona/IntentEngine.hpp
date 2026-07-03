#pragma once

#include "face/ExpressionMapper.hpp"
#include "persona/EmotionModel.hpp"
#include "persona/IdleLife.hpp"
#include "persona/SpeechPlanner.hpp"
#include "persona/StateMatrix.hpp"

namespace stackchan {

class IntentEngine {
 public:
  void begin();
  void applyEvent(const RobotEvent& event, CharacterMode mode);
  void queueSpeechCue(const SpeechCue& cue, uint32_t nowMs);
  void applyCircadian(uint8_t hourOfDay);
  void applyAmbient(float lux, uint8_t hourOfDay);
  void setDemoEnabled(bool enabled, uint32_t nowMs);
  void setReducedMotion(bool enabled);
  bool isDemoEnabled() const {
    return demoEnabled_;
  }
  bool isReducedMotion() const {
    return reducedMotion_;
  }
  RobotFrame update(uint32_t nowMs);

 private:
  EmotionModel emotion_;
  ExpressionMapper expression_;
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
  bool demoEnabled_ = true;
  bool reducedMotion_ = false;
  float soundAzimuthNorm_ = 0.0f;
  SpeechIntent lastSpeechIntent_ = SpeechIntent::None;
  SpeechCue activeSpeech_;

  void injectDemoEvents(uint32_t nowMs);
  void updateSpeechCue(uint32_t nowMs);
  void activateSpeechCue(const SpeechCue& cue, uint32_t nowMs);
  MotionTargets motionForMode(uint32_t nowMs) const;
  void applySoundOrientation(RobotFrame& frame, uint32_t nowMs) const;
};

}  // namespace stackchan
