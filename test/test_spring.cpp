#include <unity.h>

#include "motion/Spring.hpp"

using namespace stackchan;

void test_spring_moves_toward_target() {
  Spring1D spring;
  spring.reset(0.0f);
  const float first = spring.step(10.0f, 0.010f);
  TEST_ASSERT_GREATER_THAN(0.0f, first);
}

void setup() {
  UNITY_BEGIN();
  RUN_TEST(test_spring_moves_toward_target);
  UNITY_END();
}

void loop() {}
