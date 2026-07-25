#pragma once

#include "persona/EventBus.hpp"
#include "persona/StateMatrix.hpp"

namespace stackchan {

// Number of EventType values tracked for habituation. Indexing is clamped, so
// adding an EventType without growing this stays safe but stops habituating.
constexpr uint8_t kHabituatedEventTypes = 19;

// What a repeated stimulus costs and how it recovers. A creature that reacts
// identically to the first and the hundredth poke reads as a toy; the reaction
// only means something if it can wear off.
struct HabituationTelemetry {
  // Current suppression applied to the most recent event, 0 fresh .. 1 ignored.
  float lastSuppression = 0.0f;
  // Novelty of the most recent event, 1 unfamiliar .. 0 thoroughly expected.
  float lastNovelty = 1.0f;
  EventType lastEvent = EventType::Boot;
};

class EmotionModel {
 public:
  void reset();
  void applyEvent(const RobotEvent& event);
  void applyCircadian(uint8_t hourOfDay);
  void applyAmbient(float lux, uint8_t hourOfDay);
  void update(float dt);

  const EmotionalProfile& profile() const {
    return emotion_;
  }

  // The mood he settles toward when nothing is happening. Starts at the persona
  // default and drifts slowly with accumulated experience, so a robot that has
  // had a good week rests differently from one that has been knocked about.
  const EmotionalProfile& baseline() const {
    return baseline_;
  }

  const HabituationTelemetry& habituation() const {
    return habituation_;
  }

  // 0 wide awake .. 1 ready to drop off. Rises while nothing engaging happens
  // and resets when something does, so a character that has been left alone all
  // afternoon actually gets sleepy instead of staying permanently fresh.
  float sleepPressure() const;

  // Seconds since the last rousing event.
  float quietSeconds() const {
    return quietSeconds_;
  }

  // 0 fresh .. 1 fully habituated, for one event type.
  float habituationOf(EventType type) const;

 private:
  EmotionalProfile emotion_;
  EmotionalProfile baseline_;
  float familiarity_[kHabituatedEventTypes] = {};
  HabituationTelemetry habituation_;
  float quietSeconds_ = 0.0f;

  // Whether an event should count as company and push sleep back.
  static bool isRousing(EventType type);
  static uint8_t habituationIndex(EventType type);
  // Ceiling on how far a given stimulus may be tuned out. Safety-relevant
  // events keep a floor of responsiveness and never reach zero.
  static float habituationDepth(EventType type);

  static float approach(float value, float target, float amount);
  static float clamp01(float value);
  static float clampSigned(float value);
};

}  // namespace stackchan
