#include <unity.h>

#include "face/ExpressionMapper.hpp"
#include "motion/ActuationEngine.hpp"
#include "motion/Spring.hpp"
#include "persona/EmotionModel.hpp"
#include "persona/IntentEngine.hpp"

using namespace stackchan;

extern "C" void setUp() {}
extern "C" void tearDown() {}

class FakeActuator final : public IActuator {
 public:
  bool begin() override {
    began = true;
    return true;
  }

  void writePitchDeg(float pitchDeg) override {
    lastPitchDeg = pitchDeg;
    pitchWrites++;
  }

  void writeYawAngleDeg(float yawDeg) override {
    lastYawAngleDeg = yawDeg;
    yawAngleWrites++;
  }

  void writeYawVelocity(float yawVel) override {
    lastYawVelocity = yawVel;
    yawVelocityWrites++;
  }

  void stop() override {
    stopped = true;
  }

  bool began = false;
  bool stopped = false;
  int pitchWrites = 0;
  int yawAngleWrites = 0;
  int yawVelocityWrites = 0;
  float lastPitchDeg = 0.0f;
  float lastYawAngleDeg = 0.0f;
  float lastYawVelocity = 0.0f;
};

void test_spring_converges_without_exploding() {
  Spring1D spring;
  spring.reset(0.0f);

  float value = 0.0f;
  for (int i = 0; i < 120; ++i) {
    value = spring.step(10.0f, 0.010f);
  }

  TEST_ASSERT_FLOAT_WITHIN(1.0f, 10.0f, value);
  TEST_ASSERT_LESS_THAN_FLOAT(13.0f, value);
}

void test_dt_clamp_limits_large_step() {
  Spring1D spring;
  spring.reset(0.0f);

  const float value = spring.step(100.0f, 2.0f);
  TEST_ASSERT_LESS_THAN_FLOAT(30.0f, value);
}

void test_wake_word_increases_arousal_and_focus() {
  EmotionModel model;
  model.reset();

  RobotEvent event;
  event.type = EventType::WakeWord;
  event.strength = 1.0f;
  model.applyEvent(event);

  TEST_ASSERT_GREATER_THAN_FLOAT(0.20f, model.profile().arousal);
  TEST_ASSERT_GREATER_THAN_FLOAT(0.75f, model.profile().focus);
}

void test_mood_decay_returns_toward_baseline() {
  EmotionModel model;
  model.reset();

  RobotEvent event;
  event.type = EventType::Error;
  event.strength = 1.0f;
  model.applyEvent(event);

  const float arousalAfterEvent = model.profile().arousal;
  for (int i = 0; i < 100; ++i) {
    model.update(0.1f);
  }

  TEST_ASSERT_LESS_THAN_FLOAT(arousalAfterEvent, model.profile().arousal);
  TEST_ASSERT_GREATER_OR_EQUAL_FLOAT(0.0f, model.profile().fatigue);
}

void test_positive_valence_smiles() {
  ExpressionMapper mapper;
  EmotionalProfile emotion;
  emotion.valence = 0.8f;

  FaceTargets face = mapper.map(emotion, CharacterMode::Idle);
  TEST_ASSERT_GREATER_THAN_FLOAT(0.0f, face.mouthSmile);
  TEST_ASSERT_GREATER_THAN_FLOAT(0.0f, face.eyeSmile);
}

void test_sleep_mode_closes_eyes_and_mouth() {
  ExpressionMapper mapper;
  EmotionalProfile emotion;
  emotion.arousal = 0.7f;
  emotion.valence = 0.8f;

  FaceTargets face = mapper.map(emotion, CharacterMode::Sleep);
  TEST_ASSERT_FLOAT_WITHIN(0.001f, 0.15f, face.eyeOpen);
  TEST_ASSERT_FLOAT_WITHIN(0.001f, 0.0f, face.mouthOpen);
}

void test_actuation_clamps_pitch_and_yaw_angle() {
  RobotConfig config;
  config.servos.pitchMinDeg = -12.0f;
  config.servos.pitchMaxDeg = 12.0f;
  config.servos.yawMinDeg = -30.0f;
  config.servos.yawMaxDeg = 30.0f;

  FakeActuator actuator;
  ActuationEngine engine(config);
  engine.begin(&actuator);

  RobotFrame target = makeNeutralFrame();
  target.emotion.focus = 1.0f;
  target.emotion.arousal = 0.0f;
  target.motion.pitchDeg = 200.0f;
  target.motion.yawDeg = 200.0f;
  target.motion.yawMode = YawMode::Angle;

  for (int i = 1; i <= 240; ++i) {
    engine.update(target, static_cast<uint32_t>(i * 10000));
  }

  TEST_ASSERT_TRUE(actuator.began);
  TEST_ASSERT_GREATER_THAN(0, actuator.pitchWrites);
  TEST_ASSERT_GREATER_THAN(0, actuator.yawAngleWrites);
  TEST_ASSERT_LESS_OR_EQUAL_FLOAT(12.0f, actuator.lastPitchDeg);
  TEST_ASSERT_GREATER_OR_EQUAL_FLOAT(-12.0f, actuator.lastPitchDeg);
  TEST_ASSERT_LESS_OR_EQUAL_FLOAT(30.0f, actuator.lastYawAngleDeg);
  TEST_ASSERT_GREATER_OR_EQUAL_FLOAT(-30.0f, actuator.lastYawAngleDeg);
}

void test_actuation_clamps_yaw_velocity() {
  RobotConfig config;
  config.servos.yawMaxVelocity = 0.35f;

  FakeActuator actuator;
  ActuationEngine engine(config);
  engine.begin(&actuator);

  RobotFrame target = makeNeutralFrame();
  target.motion.yawMode = YawMode::Velocity;
  target.motion.yawVel = 9.0f;

  engine.update(target, 10000);

  TEST_ASSERT_EQUAL(1, actuator.yawVelocityWrites);
  TEST_ASSERT_FLOAT_WITHIN(0.001f, 0.35f, actuator.lastYawVelocity);
}

void test_disabled_yaw_commands_zero_velocity() {
  RobotConfig config;
  FakeActuator actuator;
  ActuationEngine engine(config);
  engine.begin(&actuator);

  RobotFrame target = makeNeutralFrame();
  target.motion.yawMode = YawMode::Disabled;
  target.motion.yawVel = 0.5f;
  target.motion.yawDeg = 30.0f;

  engine.update(target, 10000);

  TEST_ASSERT_EQUAL(0, actuator.yawAngleWrites);
  TEST_ASSERT_EQUAL(1, actuator.yawVelocityWrites);
  TEST_ASSERT_FLOAT_WITHIN(0.001f, 0.0f, actuator.lastYawVelocity);
}

int main() {
  UNITY_BEGIN();
  RUN_TEST(test_spring_converges_without_exploding);
  RUN_TEST(test_dt_clamp_limits_large_step);
  RUN_TEST(test_wake_word_increases_arousal_and_focus);
  RUN_TEST(test_mood_decay_returns_toward_baseline);
  RUN_TEST(test_positive_valence_smiles);
  RUN_TEST(test_sleep_mode_closes_eyes_and_mouth);
  RUN_TEST(test_actuation_clamps_pitch_and_yaw_angle);
  RUN_TEST(test_actuation_clamps_yaw_velocity);
  RUN_TEST(test_disabled_yaw_commands_zero_velocity);
  return UNITY_END();
}
