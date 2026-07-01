#include "persona/EmotionModel.hpp"

#include <Arduino.h>

namespace stackchan {

void EmotionModel::reset() {
  emotion_ = EmotionalProfile {};
}

void EmotionModel::applyEvent(const RobotEvent& event) {
  const float s = constrain(event.strength, 0.0f, 1.0f);

  switch (event.type) {
    case EventType::FaceDetected:
      emotion_.focus += 0.25f * s;
      emotion_.valence += 0.10f * s;
      break;
    case EventType::UserNear:
    case EventType::UserTouched:
      emotion_.focus += 0.20f * s;
      emotion_.arousal += 0.15f * s;
      break;
    case EventType::WakeWord:
      emotion_.arousal += 0.30f * s;
      emotion_.focus += 0.35f * s;
      break;
    case EventType::ThinkingStarted:
      emotion_.focus += 0.15f * s;
      emotion_.arousal += 0.10f * s;
      break;
    case EventType::ResponseStarted:
      emotion_.valence += 0.10f * s;
      emotion_.focus += 0.15f * s;
      break;
    case EventType::IdleTimeout:
      emotion_.arousal -= 0.10f * s;
      emotion_.focus -= 0.20f * s;
      emotion_.fatigue += 0.05f * s;
      break;
    case EventType::Error:
      emotion_.valence -= 0.35f * s;
      emotion_.arousal += 0.20f * s;
      emotion_.focus = 0.40f;
      break;
    case EventType::Boot:
    case EventType::UserSpeaking:
    case EventType::SpeechEnded:
    case EventType::ResponseEnded:
      break;
  }

  emotion_.arousal = clamp01(emotion_.arousal);
  emotion_.valence = clampSigned(emotion_.valence);
  emotion_.focus = clamp01(emotion_.focus);
  emotion_.fatigue = clamp01(emotion_.fatigue);
}

void EmotionModel::update(float dt) {
  const float safeDt = constrain(dt, 0.001f, 0.100f);
  emotion_.arousal = approach(emotion_.arousal, 0.20f, safeDt * 0.08f);
  emotion_.valence = approach(emotion_.valence, 0.35f, safeDt * 0.04f);
  emotion_.focus = approach(emotion_.focus, 0.55f, safeDt * 0.06f);
  emotion_.fatigue = approach(emotion_.fatigue, 0.0f, safeDt * 0.02f);
}

float EmotionModel::approach(float value, float target, float amount) {
  if (value < target) {
    return min(value + amount, target);
  }
  return max(value - amount, target);
}

float EmotionModel::clamp01(float value) {
  return constrain(value, 0.0f, 1.0f);
}

float EmotionModel::clampSigned(float value) {
  return constrain(value, -1.0f, 1.0f);
}

}  // namespace stackchan
