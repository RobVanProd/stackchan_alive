#include <unity.h>

#include "face/ExpressionMapper.hpp"
#include "motion/Spring.hpp"
#include "persona/EmotionModel.hpp"
#include "persona/IntentEngine.hpp"

using namespace stackchan;

void test_spring_moves_toward_target() {
  Spring1D spring;
  spring.reset(0.0f);
  const float first = spring.step(10.0f, 0.010f);
  TEST_ASSERT_GREATER_THAN(0.0f, first);
}

void test_wake_word_increases_arousal() {
  EmotionModel model;
  model.reset();

  RobotEvent event;
  event.type = EventType::WakeWord;
  event.strength = 1.0f;
  model.applyEvent(event);

  TEST_ASSERT_GREATER_THAN(0.20f, model.profile().arousal);
}

void test_positive_valence_smiles() {
  ExpressionMapper mapper;
  EmotionalProfile emotion;
  emotion.valence = 0.8f;

  FaceTargets face = mapper.map(emotion, CharacterMode::Idle);
  TEST_ASSERT_GREATER_THAN(0.0f, face.mouthSmile);
}

void setup() {
  UNITY_BEGIN();
  RUN_TEST(test_spring_moves_toward_target);
  RUN_TEST(test_wake_word_increases_arousal);
  RUN_TEST(test_positive_valence_smiles);
  UNITY_END();
}

void loop() {}
