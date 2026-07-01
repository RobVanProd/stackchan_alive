#include <unity.h>

#include "persona/EmotionModel.hpp"

using namespace stackchan;

void test_wake_word_increases_arousal() {
  EmotionModel model;
  model.reset();

  RobotEvent event;
  event.type = EventType::WakeWord;
  event.strength = 1.0f;
  model.applyEvent(event);

  TEST_ASSERT_GREATER_THAN(0.20f, model.profile().arousal);
}

void setup() {
  UNITY_BEGIN();
  RUN_TEST(test_wake_word_increases_arousal);
  UNITY_END();
}

void loop() {}
