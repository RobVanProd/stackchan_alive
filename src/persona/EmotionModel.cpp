#include "persona/EmotionModel.hpp"

#include <Arduino.h>

#include "PersonaBehavior.hpp"

namespace stackchan {

namespace {
// Ambient context bias: dark/night scenes should read sleepy without forcing Sleep mode.
constexpr float kNightFatigueGain = 0.12f;
// Bright daytime light makes the character feel a little more alert, not startled.
constexpr float kDayAlertnessGain = 0.08f;
}

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
    case EventType::FaceLost:
      emotion_.focus -= 0.16f * s;
      emotion_.valence -= 0.06f * s;
      break;
    case EventType::UserNear:
      emotion_.focus += 0.20f * s;
      emotion_.arousal += 0.15f * s;
      break;
    case EventType::UserTouched:
      emotion_.focus += 0.20f * s;
      emotion_.arousal += 0.10f * s;
      if (event.hasPayload && event.y < -0.45f) {
        emotion_.arousal -= 0.10f * s;
        emotion_.valence += 0.12f * s;
      } else if (event.hasPayload && event.y > 0.35f) {
        emotion_.valence += 0.16f * s;
      } else if (s > 0.80f) {
        emotion_.valence -= 0.08f * s;
        emotion_.arousal += 0.08f * s;
      } else {
        emotion_.valence += 0.06f * s;
      }
      break;
    case EventType::WakeWord:
      emotion_.arousal += 0.30f * s;
      emotion_.focus += 0.35f * s;
      break;
    case EventType::ThinkingStarted:
      emotion_.focus += 0.15f * s;
      emotion_.arousal += generated_persona::kCuriosityArousalDelta * s;
      break;
    case EventType::ResponseStarted:
      if (event.hasPayload) {
        const float targetArousal = constrain(event.x, 0.0f, 1.0f);
        const float targetValence = constrain(event.y, -1.0f, 1.0f);
        emotion_.arousal += (targetArousal - emotion_.arousal) * 0.82f * s;
        emotion_.valence += (targetValence - emotion_.valence) * 0.88f * s;
      } else {
        emotion_.valence += (generated_persona::kHappyValenceDelta * 0.50f) * s;
      }
      emotion_.focus += 0.15f * s;
      break;
    case EventType::IdleTimeout:
      emotion_.arousal -= 0.10f * s;
      emotion_.focus -= 0.20f * s;
      emotion_.fatigue += 0.05f * s;
      break;
    case EventType::Error:
      emotion_.valence += (generated_persona::kSafetyValenceDelta - 0.05f) * s;
      emotion_.arousal += 0.20f * s;
      emotion_.focus = 0.40f;
      break;
    case EventType::PickedUp:
      emotion_.arousal += 0.28f * s;
      emotion_.focus += 0.20f * s;
      emotion_.valence -= 0.08f * s;
      break;
    case EventType::Shaken:
      emotion_.arousal += 0.45f * s;
      emotion_.valence -= 0.32f * s;
      emotion_.focus = 0.35f;
      break;
    case EventType::PutDown:
      emotion_.arousal -= 0.12f * s;
      emotion_.valence += 0.10f * s;
      emotion_.focus += 0.08f * s;
      break;
    case EventType::Tilted:
      emotion_.arousal += 0.16f * s;
      emotion_.focus += 0.10f * s;
      emotion_.valence -= 0.04f * s;
      break;
    case EventType::SoundDirection:
      emotion_.arousal += 0.12f * s;
      emotion_.focus += 0.22f * s;
      emotion_.valence += 0.03f * s;
      break;
    case EventType::LoudNoise:
      emotion_.arousal += 0.34f * s;
      emotion_.focus += 0.18f * s;
      emotion_.valence -= 0.18f * s;
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

void EmotionModel::applyCircadian(uint8_t hourOfDay) {
  const uint8_t safeHour = hourOfDay > 23 ? 23 : hourOfDay;

  if (safeHour >= generated_persona::kNightStartHour || safeHour < generated_persona::kMorningStartHour) {
    emotion_.fatigue += 0.09f;
    emotion_.arousal -= 0.04f;
    emotion_.focus -= 0.02f;
  } else if (safeHour >= generated_persona::kEveningStartHour) {
    // Evening drift: sleepy enough to invite yawns without forcing Sleep mode.
    emotion_.fatigue += 0.05f;
    emotion_.arousal -= 0.02f;
  } else if (safeHour >= generated_persona::kMorningStartHour &&
             safeHour < generated_persona::kMorningEndHour) {
    // Morning lift: Stackchan wakes gently instead of snapping to high arousal.
    emotion_.fatigue -= 0.05f;
    emotion_.arousal += 0.025f;
    emotion_.valence += 0.015f;
  } else {
    emotion_.fatigue -= 0.025f;
  }

  emotion_.arousal = clamp01(emotion_.arousal);
  emotion_.valence = clampSigned(emotion_.valence);
  emotion_.focus = clamp01(emotion_.focus);
  emotion_.fatigue = clamp01(emotion_.fatigue);
}

void EmotionModel::applyAmbient(float lux, uint8_t hourOfDay) {
  const float safeLux = constrain(lux, 0.0f, 2000.0f);
  const uint8_t safeHour = hourOfDay > 23 ? 23 : hourOfDay;
  const bool night = safeHour >= generated_persona::kNightStartHour ||
                     safeHour < generated_persona::kMorningStartHour;
  const bool daytime = safeHour >= static_cast<uint8_t>(generated_persona::kMorningStartHour + 1) &&
                       safeHour < generated_persona::kEveningStartHour;

  applyCircadian(safeHour);

  const float darkness = constrain((120.0f - safeLux) / 120.0f, 0.0f, 1.0f);
  const float brightness = constrain((safeLux - 250.0f) / 750.0f, 0.0f, 1.0f);

  if (night || darkness > 0.65f) {
    const float fatigueBias = darkness * (night ? kNightFatigueGain : kNightFatigueGain * 0.50f);
    emotion_.fatigue += fatigueBias;
    emotion_.arousal -= darkness * 0.05f;
    emotion_.focus -= darkness * 0.03f;
  }

  if (daytime && brightness > 0.0f) {
    emotion_.fatigue -= brightness * kDayAlertnessGain;
    emotion_.arousal += brightness * 0.06f;
    emotion_.valence += brightness * 0.03f;
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
