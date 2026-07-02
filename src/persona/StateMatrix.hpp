#pragma once

#include <Arduino.h>

namespace stackchan {

enum class CharacterMode : uint8_t {
  Boot,
  Idle,
  Attend,
  Listen,
  Think,
  Speak,
  React,
  Sleep,
  Error,
};

enum class SpeechIntent : uint8_t {
  None,
  Boot,
  Idle,
  Attend,
  Listen,
  Think,
  Speak,
  React,
  Happy,
  Concern,
  Sleep,
  Error,
  Safety,
};

enum class SpeechEarcon : uint8_t {
  None,
  Wake,
  Confirm,
  Think,
  Happy,
  Concern,
  Sleep,
  Error,
  Safety,
};

struct SpeechCue {
  SpeechIntent intent = SpeechIntent::None;
  const char* text = "";
  uint8_t priority = 0;
  SpeechEarcon earcon = SpeechEarcon::None;
  uint16_t earconDelayMs = 0;

  bool shouldSpeak() const {
    return intent != SpeechIntent::None && text[0] != '\0';
  }

  bool hasEarcon() const {
    return earcon != SpeechEarcon::None;
  }
};

struct EmotionalProfile {
  float arousal = 0.20f;  // 0.0 calm/sleepy, 1.0 startled/energetic
  float valence = 0.45f;  // -1.0 negative/withdrawn, 1.0 positive/social
  float focus = 0.75f;    // 0.0 wandering, 1.0 locked-on
  float fatigue = 0.0f;   // 0.0 fresh, 1.0 tired/sleepy
};

enum class YawMode : uint8_t {
  Angle,
  Velocity,
  Disabled,
};

struct MotionTargets {
  YawMode yawMode = YawMode::Angle;
  float yawDeg = 0.0f;
  float yawVel = 0.0f;
  float pitchDeg = 0.0f;
};

struct FaceTargets {
  struct EyeCorners {
    float tl = 0.0f;
    float tr = 0.0f;
    float bl = 0.0f;
    float br = 0.0f;
  };

  float eyeOpen = 0.85f;
  float eyeWidthScale = 1.0f;
  float squint = 0.0f;
  float eyeSmile = 0.15f;
  float pupilX = 0.0f;
  float pupilY = 0.0f;
  float pupilScale = 1.0f;
  float browTilt = 0.0f;
  float mouthSmile = 0.15f;
  float mouthOpen = 0.0f;
  float mouthWidthDelta = 0.0f;
  float mouthCornerL = 0.0f;
  float mouthCornerR = 0.0f;
  float upperLidTilt = 0.0f;
  float lowerLidTilt = 0.0f;
  float faceX = 0.0f;
  float faceY = 0.0f;
  EyeCorners leftCorners;
  EyeCorners rightCorners;
};

struct RobotFrame {
  uint32_t seq = 0;
  uint32_t timestampMs = 0;
  CharacterMode mode = CharacterMode::Idle;
  EmotionalProfile emotion;
  MotionTargets motion;
  FaceTargets face;
  SpeechCue speech;
  uint32_t speechSeq = 0;
};

inline RobotFrame makeNeutralFrame() {
  RobotFrame frame;
  frame.timestampMs = millis();
  return frame;
}

}  // namespace stackchan
