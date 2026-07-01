#include <unity.h>

#include "face/ExpressionMapper.hpp"
#include "persona/IntentEngine.hpp"

using namespace stackchan;

void test_positive_valence_smiles() {
  ExpressionMapper mapper;
  EmotionalProfile emotion;
  emotion.valence = 0.8f;

  FaceTargets face = mapper.map(emotion, CharacterMode::Idle);
  TEST_ASSERT_GREATER_THAN(0.0f, face.mouthSmile);
}

void setup() {
  UNITY_BEGIN();
  RUN_TEST(test_positive_valence_smiles);
  UNITY_END();
}

void loop() {}
