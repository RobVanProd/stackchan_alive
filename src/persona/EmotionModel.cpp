#include "persona/EmotionModel.hpp"

#include <Arduino.h>

#include "PersonaBehavior.hpp"

namespace stackchan {

namespace {
// Ambient context bias: dark/night scenes should read sleepy without forcing Sleep mode.
constexpr float kNightFatigueGain = 0.12f;
// Bright daytime light makes the character feel a little more alert, not startled.
constexpr float kDayAlertnessGain = 0.08f;

// How fast a repeated stimulus stops being interesting. Each repeat closes this
// fraction of the remaining gap to the event's depth ceiling, so the drop-off is
// steep for the first few repeats and then flattens.
constexpr float kFamiliarityGain = 0.34f;
// How fast novelty comes back while a stimulus is absent, per second. Roughly a
// 90 s recovery from fully habituated back to nearly fresh.
constexpr float kFamiliarityRecoveryPerSecond = 0.011f;

// How strongly lived experience pulls the resting mood around, per second.
// Deliberately far slower than emotion decay: minutes move mood, hours move
// temperament.
constexpr float kBaselineDriftPerSecond = 0.0016f;
// Temperament may wander this far from the persona default but no further, so a
// rough afternoon colours him without turning him into a different character.
constexpr float kBaselineValenceBand = 0.30f;
constexpr float kBaselineArousalBand = 0.15f;
constexpr float kBaselineFocusBand = 0.15f;

// Sleep pressure. Nothing engaging for this long and the character starts to
// wind down; full pressure is reached over the ramp that follows. Fatigue then
// climbs toward it, so the visible order is droopy eyes, then yawns, then sleep.
constexpr float kSleepPressureOnsetSeconds = 180.0f;
constexpr float kSleepPressureRampSeconds = 420.0f;
// Each second asleep pays back this many seconds of accrued quiet time, so a
// full night of pressure clears in roughly a minute and a half of sleep.
constexpr float kRestRecoveryRate = 8.0f;
}

bool EmotionModel::isRousing(EventType type) {
  switch (type) {
    case EventType::WakeWord:
    case EventType::UserTouched:
    case EventType::UserNear:
    case EventType::UserSpeaking:
    case EventType::FaceDetected:
    case EventType::SoundDirection:
    case EventType::LoudNoise:
    case EventType::Shaken:
    case EventType::PickedUp:
    case EventType::PutDown:
    case EventType::Tilted:
    case EventType::ResponseStarted:
    case EventType::Error:
      return true;
    // Boot, idle timeouts, and the robot's own speech/thinking bookkeeping are
    // not company.
    default:
      return false;
  }
}

float EmotionModel::sleepPressure() const {
  if (quietSeconds_ <= kSleepPressureOnsetSeconds) {
    return 0.0f;
  }
  return clamp01((quietSeconds_ - kSleepPressureOnsetSeconds) / kSleepPressureRampSeconds);
}

void EmotionModel::reset() {
  emotion_ = EmotionalProfile {};
  baseline_ = EmotionalProfile {};
  // The rest state the character was tuned around. Temperament drifts from here.
  baseline_.arousal = 0.20f;
  baseline_.valence = 0.35f;
  baseline_.focus = 0.55f;
  baseline_.fatigue = 0.0f;
  for (uint8_t i = 0; i < kHabituatedEventTypes; ++i) {
    familiarity_[i] = 0.0f;
  }
  habituation_ = HabituationTelemetry {};
  quietSeconds_ = 0.0f;
  hasCircadianContext_ = false;
  hasAmbientLux_ = false;
  contextHour_ = 12;
  contextLux_ = 0.0f;
}

EmotionPersistentState EmotionModel::persistentState() const {
  EmotionPersistentState state;
  state.baseline = baseline_;
  for (uint8_t i = 0; i < kHabituatedEventTypes; ++i) {
    state.familiarity[i] = familiarity_[i];
  }
  return state;
}

void EmotionModel::restorePersistentState(const EmotionPersistentState& state) {
  // A corrupt or stale blob may carry anything; clamp back inside the same
  // bands baseline drift is allowed, so a restore can never exceed what lived
  // experience could have produced.
  baseline_.arousal = constrain(state.baseline.arousal, 0.20f - kBaselineArousalBand,
                                0.20f + kBaselineArousalBand);
  baseline_.valence = constrain(state.baseline.valence, 0.35f - kBaselineValenceBand,
                                0.35f + kBaselineValenceBand);
  baseline_.focus = constrain(state.baseline.focus, 0.55f - kBaselineFocusBand,
                              0.55f + kBaselineFocusBand);
  baseline_.fatigue = clamp01(state.baseline.fatigue);
  for (uint8_t i = 0; i < kHabituatedEventTypes; ++i) {
    familiarity_[i] = clamp01(state.familiarity[i]);
  }
}

uint8_t EmotionModel::habituationIndex(EventType type) {
  const uint8_t raw = static_cast<uint8_t>(type);
  return raw < kHabituatedEventTypes ? raw : static_cast<uint8_t>(kHabituatedEventTypes - 1);
}

float EmotionModel::habituationDepth(EventType type) {
  switch (type) {
    // He should always answer to his name.
    case EventType::WakeWord:
      return 0.15f;
    // Never tune out a fault.
    case EventType::Error:
      return 0.0f;
    // Being shaken stays alarming even when it keeps happening.
    case EventType::Shaken:
      return 0.35f;
    case EventType::PickedUp:
      return 0.45f;
    case EventType::LoudNoise:
      return 0.50f;
    case EventType::FaceDetected:
      return 0.55f;
    case EventType::UserNear:
    case EventType::Tilted:
      return 0.60f;
    case EventType::SoundDirection:
      return 0.70f;
    // The headline case: constant petting should stop reading as constant news.
    case EventType::UserTouched:
      return 0.75f;
    default:
      return 0.40f;
  }
}

float EmotionModel::habituationOf(EventType type) const {
  return familiarity_[habituationIndex(type)] * habituationDepth(type);
}

void EmotionModel::applyEvent(const RobotEvent& event) {
  const uint8_t index = habituationIndex(event.type);
  const float depth = habituationDepth(event.type);
  const float suppression = clamp01(familiarity_[index] * depth);

  habituation_.lastEvent = event.type;
  habituation_.lastSuppression = suppression;
  habituation_.lastNovelty = 1.0f - suppression;

  // Company pushes sleep back even when the stimulus itself is old news.
  if (isRousing(event.type)) {
    quietSeconds_ = 0.0f;
  }

  // A familiar stimulus still registers, it just stops being news.
  const float s = constrain(event.strength, 0.0f, 1.0f) * (1.0f - suppression);

  // Grow familiarity toward this event's ceiling. Untouched for a while, it
  // decays again in update().
  familiarity_[index] = clamp01(familiarity_[index] + kFamiliarityGain * (1.0f - familiarity_[index]));

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
  contextHour_ = hourOfDay > 23 ? 23 : hourOfDay;
  hasCircadianContext_ = true;
}

void EmotionModel::applyAmbient(float lux, uint8_t hourOfDay) {
  applyCircadian(hourOfDay);
  contextLux_ = constrain(lux, 0.0f, 2000.0f);
  hasAmbientLux_ = true;
}

// Steady-state profile shifts for the current time of day and light level.
// These are targets the profile drifts toward in update(), not impulses, so a
// context source repeating at any rate produces the same bounded result.
void EmotionModel::circadianBias(float& fatigueBias, float& arousalBias, float& valenceBias) const {
  fatigueBias = 0.0f;
  arousalBias = 0.0f;
  valenceBias = 0.0f;
  if (!hasCircadianContext_) {
    return;
  }

  const bool night = contextHour_ >= generated_persona::kNightStartHour ||
                     contextHour_ < generated_persona::kMorningStartHour;
  const bool daytime = contextHour_ >= static_cast<uint8_t>(generated_persona::kMorningStartHour + 1) &&
                       contextHour_ < generated_persona::kEveningStartHour;

  if (night) {
    fatigueBias += 0.25f;
    arousalBias -= 0.06f;
  } else if (contextHour_ >= generated_persona::kEveningStartHour) {
    // Evening drift: sleepy enough to invite yawns without forcing Sleep mode.
    fatigueBias += 0.12f;
    arousalBias -= 0.03f;
  } else if (contextHour_ >= generated_persona::kMorningStartHour &&
             contextHour_ < generated_persona::kMorningEndHour) {
    // Morning lift: Stackchan wakes gently instead of snapping to high arousal.
    fatigueBias -= 0.08f;
    arousalBias += 0.03f;
    valenceBias += 0.02f;
  }

  if (hasAmbientLux_) {
    const float darkness = constrain((120.0f - contextLux_) / 120.0f, 0.0f, 1.0f);
    const float brightness = constrain((contextLux_ - 250.0f) / 750.0f, 0.0f, 1.0f);
    if (night || darkness > 0.65f) {
      fatigueBias += darkness * (night ? kNightFatigueGain : kNightFatigueGain * 0.50f);
      arousalBias -= darkness * 0.05f;
    }
    if (daytime && brightness > 0.0f) {
      fatigueBias -= brightness * kDayAlertnessGain;
      arousalBias += brightness * 0.06f;
      valenceBias += brightness * 0.03f;
    }
  }
}

void EmotionModel::update(float dt, bool resting) {
  const float safeDt = constrain(dt, 0.001f, 0.100f);

  // Novelty returns while a stimulus stays away, so the same touch is worth
  // reacting to again once it has stopped being constant.
  const float recovery = safeDt * kFamiliarityRecoveryPerSecond;
  for (uint8_t i = 0; i < kHabituatedEventTypes; ++i) {
    if (familiarity_[i] > 0.0f) {
      familiarity_[i] = approach(familiarity_[i], 0.0f, recovery);
    }
  }

  float circadianFatigue = 0.0f;
  float circadianArousal = 0.0f;
  float circadianValence = 0.0f;
  circadianBias(circadianFatigue, circadianArousal, circadianValence);

  // Mood settles toward temperament (shifted by time-of-day context) rather
  // than toward a constant, so where he comes to rest depends on how the day
  // has gone and what time it is.
  emotion_.arousal = approach(emotion_.arousal, clamp01(baseline_.arousal + circadianArousal), safeDt * 0.08f);
  emotion_.valence = approach(emotion_.valence, clampSigned(baseline_.valence + circadianValence), safeDt * 0.04f);
  emotion_.focus = approach(emotion_.focus, baseline_.focus, safeDt * 0.06f);
  // Fatigue used to decay to a hard zero, so no amount of being left alone ever
  // made the character sleepy. It now climbs toward accumulated sleep pressure.
  // Sleeping pays that pressure back down; without this, quiet time kept
  // accruing while asleep and pinned fatigue at 1.0, so natural waking was
  // unreachable and only being disturbed could end sleep.
  if (resting) {
    quietSeconds_ = max(0.0f, quietSeconds_ - safeDt * kRestRecoveryRate);
  } else {
    quietSeconds_ += safeDt;
  }
  const float fatigueTarget = clamp01(max(baseline_.fatigue, sleepPressure()) + circadianFatigue);
  emotion_.fatigue = approach(emotion_.fatigue, fatigueTarget, safeDt * 0.02f);

  // Temperament follows lived mood far more slowly, and only within a band
  // around the persona default.
  const float drift = safeDt * kBaselineDriftPerSecond;
  baseline_.arousal = approach(baseline_.arousal, emotion_.arousal, drift);
  baseline_.valence = approach(baseline_.valence, emotion_.valence, drift);
  baseline_.focus = approach(baseline_.focus, emotion_.focus, drift);

  baseline_.arousal = constrain(baseline_.arousal, 0.20f - kBaselineArousalBand,
                                0.20f + kBaselineArousalBand);
  baseline_.valence = constrain(baseline_.valence, 0.35f - kBaselineValenceBand,
                                0.35f + kBaselineValenceBand);
  baseline_.focus = constrain(baseline_.focus, 0.55f - kBaselineFocusBand,
                              0.55f + kBaselineFocusBand);
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
