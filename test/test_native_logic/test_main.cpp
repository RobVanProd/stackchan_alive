#include <unity.h>

#include <cmath>
#include <cstring>

#include "face/ExpressionMapper.hpp"
#include "face/FaceAnimator.hpp"
#include "io/SensorAdapter.hpp"
#include "motion/ActuationEngine.hpp"
#include "motion/Spring.hpp"
#include "persona/EmotionModel.hpp"
#include "persona/IntentEngine.hpp"
#include "persona/SpeechPlanner.hpp"

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

void test_expression_mapper_sets_brow_tilt_direction() {
  ExpressionMapper mapper;
  EmotionalProfile emotion;
  emotion.valence = -0.8f;
  emotion.arousal = 0.1f;

  FaceTargets worried = mapper.map(emotion, CharacterMode::Think);
  TEST_ASSERT_LESS_THAN_FLOAT(0.0f, worried.browTilt);

  emotion.valence = 0.4f;
  emotion.arousal = 0.8f;

  FaceTargets focused = mapper.map(emotion, CharacterMode::Idle);
  TEST_ASSERT_GREATER_THAN_FLOAT(0.0f, focused.browTilt);
}

void test_face_animator_outback_overshoots_then_settles() {
  const float mid = applyEase(Ease::OutBack, 0.60f);
  const float end = applyEase(Ease::OutBack, 1.0f);

  TEST_ASSERT_GREATER_THAN_FLOAT(1.0f, mid);
  TEST_ASSERT_FLOAT_WITHIN(0.001f, 1.0f, end);
}

void test_face_animator_smooths_channels_with_independent_timing() {
  FaceAnimator animator;
  RobotFrame frame = makeNeutralFrame();
  frame.face.eyeOpen = 0.2f;
  frame.face.mouthOpen = 0.0f;
  animator.composeFrame(frame, 0);

  frame.face.eyeOpen = 1.0f;
  frame.face.mouthOpen = 1.0f;
  const FaceTargets firstStep = animator.composeFrame(frame, 40);

  TEST_ASSERT_GREATER_THAN_FLOAT(0.2f, firstStep.eyeOpen);
  TEST_ASSERT_GREATER_THAN_FLOAT(0.0f, firstStep.mouthOpen);
  TEST_ASSERT_GREATER_THAN_FLOAT(firstStep.mouthOpen, firstStep.eyeOpen - 0.2f);
}

void test_face_animator_uses_mode_authored_pose_keys() {
  FaceAnimator animator;
  RobotFrame frame = makeNeutralFrame();
  frame.mode = CharacterMode::Think;
  frame.emotion.arousal = 0.4f;
  frame.face.eyeOpen = 0.85f;

  FaceTargets think = animator.composeFrame(frame, 0);
  TEST_ASSERT_GREATER_THAN_FLOAT(0.20f, think.leftCorners.tr);
  TEST_ASSERT_LESS_THAN_FLOAT(-0.10f, think.pupilY);
  TEST_ASSERT_LESS_THAN_FLOAT(0.0f, think.mouthWidthDelta);

  frame.mode = CharacterMode::Error;
  animator.reset(frame.face, 100);
  FaceTargets concern = animator.composeFrame(frame, 100);
  TEST_ASSERT_GREATER_THAN_FLOAT(0.30f, concern.rightCorners.tl);
  TEST_ASSERT_LESS_THAN_FLOAT(0.0f, concern.browTilt);
  TEST_ASSERT_NOT_EQUAL(concern.leftCorners.tl, concern.rightCorners.tl);
}

void test_face_animator_autonomic_layer_adds_life_over_time() {
  FaceAnimator animator;
  RobotFrame frame = makeNeutralFrame();
  frame.mode = CharacterMode::Idle;
  frame.emotion.focus = 0.45f;
  frame.emotion.arousal = 0.35f;
  frame.face.eyeOpen = 0.85f;

  float minEyeOpen = 2.0f;
  float maxEyeWidthScale = 0.0f;
  float minBreathY = 100.0f;
  float maxBreathY = -100.0f;

  for (uint32_t t = 0; t <= 10000; t += 33) {
    const FaceTargets face = animator.composeFrame(frame, t);
    const FaceAutonomicTelemetry& telemetry = animator.autonomicTelemetry();
    minEyeOpen = min(minEyeOpen, face.eyeOpen);
    maxEyeWidthScale = max(maxEyeWidthScale, face.eyeWidthScale);
    minBreathY = min(minBreathY, telemetry.breathY);
    maxBreathY = max(maxBreathY, telemetry.breathY);
  }

  const FaceAutonomicTelemetry& telemetry = animator.autonomicTelemetry();
  TEST_ASSERT_GREATER_OR_EQUAL_UINT32(2, telemetry.blinkCount);
  TEST_ASSERT_GREATER_OR_EQUAL_UINT32(2, telemetry.saccadeCount);
  TEST_ASSERT_LESS_THAN_FLOAT(0.65f, minEyeOpen);
  TEST_ASSERT_GREATER_THAN_FLOAT(1.02f, maxEyeWidthScale);
  TEST_ASSERT_GREATER_THAN_FLOAT(2.0f, maxBreathY - minBreathY);
}

void test_face_animator_reduced_motion_dampens_autonomic_offsets() {
  FaceAnimator fullMotion;
  FaceAnimator reducedMotion;
  RobotFrame frame = makeNeutralFrame();
  frame.mode = CharacterMode::Idle;
  frame.emotion.focus = 0.45f;
  frame.emotion.arousal = 0.35f;
  frame.face.eyeOpen = 0.85f;
  reducedMotion.setReducedMotion(true);

  float fullMaxOffset = 0.0f;
  float reducedMaxOffset = 0.0f;
  for (uint32_t t = 0; t <= 6000; t += 33) {
    const FaceTargets fullFace = fullMotion.composeFrame(frame, t);
    const FaceTargets reducedFace = reducedMotion.composeFrame(frame, t);
    fullMaxOffset = max(fullMaxOffset, fabsf(fullFace.faceY));
    reducedMaxOffset = max(reducedMaxOffset, fabsf(reducedFace.faceY));
  }

  TEST_ASSERT_GREATER_THAN_FLOAT(reducedMaxOffset * 2.0f, fullMaxOffset);
}

void test_robot_config_exposes_face_reduced_motion_default() {
  const RobotConfig config = defaultRobotConfig();
  TEST_ASSERT_FALSE(config.face.reducedMotion);
}

void test_face_animator_starts_listen_transition_with_blink_and_pop() {
  FaceAnimator animator;
  RobotFrame frame = makeNeutralFrame();
  frame.mode = CharacterMode::Idle;
  frame.face.eyeOpen = 0.85f;
  animator.composeFrame(frame, 0);

  frame.mode = CharacterMode::Listen;
  const FaceTargets first = animator.composeFrame(frame, 100);
  const FaceGestureTelemetry& firstGesture = animator.gestureTelemetry();
  TEST_ASSERT_TRUE(firstGesture.active);
  TEST_ASSERT_EQUAL(static_cast<int>(CharacterMode::Idle), static_cast<int>(firstGesture.from));
  TEST_ASSERT_EQUAL(static_cast<int>(CharacterMode::Listen), static_cast<int>(firstGesture.to));
  TEST_ASSERT_EQUAL_UINT32(500, firstGesture.durationMs);
  TEST_ASSERT_GREATER_OR_EQUAL_UINT32(1, animator.autonomicTelemetry().blinkCount);

  const FaceTargets later = animator.composeFrame(frame, 420);
  TEST_ASSERT_GREATER_THAN_FLOAT(first.browTilt, later.browTilt);
  TEST_ASSERT_LESS_THAN_FLOAT(first.faceY, later.faceY);
}

void test_face_animator_think_to_speak_centers_gaze_before_mouth_settles() {
  FaceAnimator animator;
  RobotFrame frame = makeNeutralFrame();
  frame.mode = CharacterMode::Think;
  frame.face.eyeOpen = 0.85f;
  const FaceTargets think = animator.composeFrame(frame, 0);

  frame.mode = CharacterMode::Speak;
  const FaceTargets early = animator.composeFrame(frame, 150);
  const FaceGestureTelemetry& gesture = animator.gestureTelemetry();
  TEST_ASSERT_TRUE(gesture.active);
  TEST_ASSERT_EQUAL(static_cast<int>(CharacterMode::Think), static_cast<int>(gesture.from));
  TEST_ASSERT_EQUAL(static_cast<int>(CharacterMode::Speak), static_cast<int>(gesture.to));
  TEST_ASSERT_EQUAL_UINT32(320, gesture.durationMs);
  TEST_ASSERT_GREATER_THAN_FLOAT(0.0f, early.mouthOpen);

  const FaceTargets later = animator.composeFrame(frame, 260);
  TEST_ASSERT_LESS_THAN_FLOAT(fabsf(think.pupilX), fabsf(later.pupilX));
  TEST_ASSERT_LESS_THAN_FLOAT(fabsf(think.pupilY), fabsf(later.pupilY));
}

void test_face_animator_sleep_wake_transition_uses_longer_startle_clip() {
  FaceAnimator animator;
  RobotFrame frame = makeNeutralFrame();
  frame.mode = CharacterMode::Sleep;
  frame.face.eyeOpen = 0.85f;
  const FaceTargets sleep = animator.composeFrame(frame, 0);

  frame.mode = CharacterMode::Idle;
  const FaceTargets wake = animator.composeFrame(frame, 500);
  const FaceGestureTelemetry& gesture = animator.gestureTelemetry();
  TEST_ASSERT_TRUE(gesture.active);
  TEST_ASSERT_EQUAL(static_cast<int>(CharacterMode::Sleep), static_cast<int>(gesture.from));
  TEST_ASSERT_EQUAL(static_cast<int>(CharacterMode::Idle), static_cast<int>(gesture.to));
  TEST_ASSERT_EQUAL_UINT32(650, gesture.durationMs);
  TEST_ASSERT_GREATER_THAN_FLOAT(sleep.eyeOpen, wake.eyeOpen);
  TEST_ASSERT_LESS_THAN_FLOAT(sleep.faceY, wake.faceY);
}

void test_face_animator_speech_envelope_owns_mouth_channel() {
  FaceAnimator animator;
  RobotFrame frame = makeNeutralFrame();
  frame.mode = CharacterMode::Speak;
  frame.face.eyeOpen = 0.85f;
  animator.composeFrame(frame, 0);

  animator.setSpeechEnvelope(0.05f, SpeechViseme::Ah, 40);
  const FaceTargets quiet = animator.composeFrame(frame, 40);
  animator.setSpeechEnvelope(0.90f, SpeechViseme::Ah, 260);
  const FaceTargets loud = animator.composeFrame(frame, 260);

  TEST_ASSERT_TRUE(animator.speechTelemetry().active);
  TEST_ASSERT_EQUAL(static_cast<int>(SpeechViseme::Ah), static_cast<int>(animator.speechTelemetry().viseme));
  TEST_ASSERT_GREATER_THAN_FLOAT(quiet.mouthOpen, loud.mouthOpen);
  TEST_ASSERT_GREATER_THAN_FLOAT(quiet.browTilt, loud.browTilt);
}

void test_face_animator_speech_visemes_change_mouth_shape() {
  FaceAnimator animator;
  RobotFrame frame = makeNeutralFrame();
  frame.mode = CharacterMode::Speak;
  frame.face.eyeOpen = 0.85f;
  animator.composeFrame(frame, 0);

  animator.setSpeechEnvelope(0.75f, SpeechViseme::Ah, 40);
  const FaceTargets ah = animator.composeFrame(frame, 40);
  animator.setSpeechEnvelope(0.75f, SpeechViseme::Oh, 260);
  const FaceTargets oh = animator.composeFrame(frame, 260);
  animator.setSpeechEnvelope(0.75f, SpeechViseme::Ee, 520);
  const FaceTargets ee = animator.composeFrame(frame, 520);

  TEST_ASSERT_LESS_THAN_FLOAT(ah.mouthWidthDelta, oh.mouthWidthDelta);
  TEST_ASSERT_GREATER_THAN_FLOAT(oh.mouthWidthDelta, ee.mouthWidthDelta);
  TEST_ASSERT_LESS_THAN_FLOAT(ah.mouthOpen, ee.mouthOpen);
}

void test_face_animator_speech_sidecar_expires_when_updates_stop() {
  FaceAnimator animator;
  RobotFrame frame = makeNeutralFrame();
  frame.mode = CharacterMode::Speak;
  frame.face.eyeOpen = 0.85f;
  animator.composeFrame(frame, 0);

  animator.setSpeechEnvelope(0.85f, SpeechViseme::Ah, 40);
  const FaceTargets active = animator.composeFrame(frame, 40);
  frame.mode = CharacterMode::Idle;
  const FaceTargets expired = animator.composeFrame(frame, 260);

  TEST_ASSERT_FALSE(animator.speechTelemetry().active);
  TEST_ASSERT_LESS_THAN_FLOAT(active.mouthOpen, expired.mouthOpen);
}

void test_robot_frame_carries_character_mode_for_renderer() {
  RobotFrame frame = makeNeutralFrame();
  frame.mode = CharacterMode::Listen;
  TEST_ASSERT_EQUAL(static_cast<int>(CharacterMode::Listen), static_cast<int>(frame.mode));
}

void test_robot_frame_carries_speech_cue_for_output_adapters() {
  RobotFrame frame = makeNeutralFrame();
  TEST_ASSERT_FALSE(frame.speech.shouldSpeak());
  TEST_ASSERT_EQUAL_UINT32(0, frame.speechSeq);

  frame.speech = {SpeechIntent::Think, "Input received. I am thinking now.", 150,
                  SpeechEarcon::Think, 80};
  frame.speechSeq = 7;

  TEST_ASSERT_TRUE(frame.speech.shouldSpeak());
  TEST_ASSERT_TRUE(frame.speech.hasEarcon());
  TEST_ASSERT_EQUAL_UINT32(7, frame.speechSeq);
}

void test_intent_engine_emits_deduped_speech_cue_on_external_event() {
  IntentEngine engine;
  engine.begin();

  RobotEvent event;
  event.type = EventType::WakeWord;
  event.strength = 1.0f;
  engine.applyEvent(event, CharacterMode::Listen);

  const RobotFrame first = engine.update(100);
  TEST_ASSERT_TRUE(first.speech.shouldSpeak());
  TEST_ASSERT_EQUAL(static_cast<int>(SpeechIntent::Listen), static_cast<int>(first.speech.intent));
  TEST_ASSERT_EQUAL_STRING("I am listening with maximum attention.", first.speech.text);
  TEST_ASSERT_EQUAL(static_cast<int>(SpeechEarcon::Confirm), static_cast<int>(first.speech.earcon));
  TEST_ASSERT_EQUAL_UINT32(1, first.speechSeq);

  const RobotFrame held = engine.update(500);
  TEST_ASSERT_TRUE(held.speech.shouldSpeak());
  TEST_ASSERT_EQUAL_UINT32(first.speechSeq, held.speechSeq);

  const RobotFrame expired = engine.update(800);
  TEST_ASSERT_FALSE(expired.speech.shouldSpeak());
  TEST_ASSERT_EQUAL_UINT32(0, expired.speechSeq);
}

void test_sensor_adapter_parses_serial_mode_command() {
  BenchControl control;
  TEST_ASSERT_TRUE(parseBenchControlLine("mode listen 0.75", 1234, &control));
  TEST_ASSERT_FALSE(control.wantsHelp);
  TEST_ASSERT_TRUE(control.hasEvent);
  TEST_ASSERT_FALSE(control.hasSpeech);
  TEST_ASSERT_EQUAL(static_cast<int>(CharacterMode::Listen), static_cast<int>(control.mode));
  TEST_ASSERT_EQUAL(static_cast<int>(EventType::WakeWord), static_cast<int>(control.event.type));
  TEST_ASSERT_FLOAT_WITHIN(0.001f, 0.75f, control.event.strength);
  TEST_ASSERT_EQUAL_UINT32(1234, control.event.timestampMs);
  TEST_ASSERT_EQUAL_STRING("mode_listen", control.command);
}

void test_sensor_adapter_parses_help_without_event() {
  BenchControl control;
  TEST_ASSERT_TRUE(parseBenchControlLine("help", 1000, &control));
  TEST_ASSERT_TRUE(control.wantsHelp);
  TEST_ASSERT_FALSE(control.wantsStatus);
  TEST_ASSERT_FALSE(control.hasEvent);
  TEST_ASSERT_FALSE(control.hasSpeech);
  TEST_ASSERT_EQUAL_STRING("help", control.command);

  TEST_ASSERT_TRUE(parseBenchControlLine("?", 1000, &control));
  TEST_ASSERT_TRUE(control.wantsHelp);
  TEST_ASSERT_EQUAL_STRING("help", control.command);
}

void test_sensor_adapter_parses_status_without_event() {
  BenchControl control;
  TEST_ASSERT_TRUE(parseBenchControlLine("status", 1100, &control));
  TEST_ASSERT_FALSE(control.wantsHelp);
  TEST_ASSERT_TRUE(control.wantsStatus);
  TEST_ASSERT_FALSE(control.hasEvent);
  TEST_ASSERT_FALSE(control.hasSpeech);
  TEST_ASSERT_FALSE(control.hasReducedMotion);
  TEST_ASSERT_EQUAL_STRING("status", control.command);

  TEST_ASSERT_TRUE(parseBenchControlLine("health", 1200, &control));
  TEST_ASSERT_TRUE(control.wantsStatus);
  TEST_ASSERT_EQUAL_STRING("status", control.command);

  TEST_ASSERT_TRUE(parseBenchControlLine("telemetry", 1300, &control));
  TEST_ASSERT_TRUE(control.wantsStatus);
  TEST_ASSERT_EQUAL_STRING("status", control.command);
}

void test_sensor_adapter_parses_event_aliases_and_clamps_strength() {
  BenchControl control;
  TEST_ASSERT_TRUE(parseBenchControlLine("event response-start 2.5", 2000, &control));
  TEST_ASSERT_TRUE(control.hasEvent);
  TEST_ASSERT_EQUAL(static_cast<int>(CharacterMode::Speak), static_cast<int>(control.mode));
  TEST_ASSERT_EQUAL(static_cast<int>(EventType::ResponseStarted), static_cast<int>(control.event.type));
  TEST_ASSERT_FLOAT_WITHIN(0.001f, 1.0f, control.event.strength);
  TEST_ASSERT_EQUAL_STRING("event_response", control.command);

  TEST_ASSERT_TRUE(parseBenchControlLine("touch", 2400, &control));
  TEST_ASSERT_EQUAL(static_cast<int>(CharacterMode::React), static_cast<int>(control.mode));
  TEST_ASSERT_EQUAL(static_cast<int>(EventType::UserTouched), static_cast<int>(control.event.type));
  TEST_ASSERT_EQUAL_STRING("event_touch", control.command);
}

void test_sensor_adapter_parses_speech_envelope_command() {
  BenchControl control;
  TEST_ASSERT_TRUE(parseBenchControlLine("speech 0.82 oh 900", 3200, &control));
  TEST_ASSERT_TRUE(control.hasEvent);
  TEST_ASSERT_TRUE(control.hasSpeech);
  TEST_ASSERT_EQUAL(static_cast<int>(CharacterMode::Speak), static_cast<int>(control.mode));
  TEST_ASSERT_EQUAL(static_cast<int>(EventType::ResponseStarted), static_cast<int>(control.event.type));
  TEST_ASSERT_FLOAT_WITHIN(0.001f, 0.82f, control.speech.envelope);
  TEST_ASSERT_EQUAL(static_cast<int>(BenchSpeechViseme::Oh), static_cast<int>(control.speech.viseme));
  TEST_ASSERT_EQUAL_UINT16(900, control.speech.durationMs);
  TEST_ASSERT_FALSE(control.speech.clear);
  TEST_ASSERT_EQUAL_STRING("speech_env", control.command);
}

void test_sensor_adapter_parses_speech_clear_and_rejects_unknown_viseme() {
  BenchControl control;
  TEST_ASSERT_TRUE(parseBenchControlLine("mouth clear", 3600, &control));
  TEST_ASSERT_TRUE(control.hasEvent);
  TEST_ASSERT_TRUE(control.hasSpeech);
  TEST_ASSERT_TRUE(control.speech.clear);
  TEST_ASSERT_EQUAL(static_cast<int>(CharacterMode::Idle), static_cast<int>(control.mode));
  TEST_ASSERT_EQUAL(static_cast<int>(EventType::SpeechEnded), static_cast<int>(control.event.type));
  TEST_ASSERT_EQUAL_STRING("speech_clear", control.command);

  TEST_ASSERT_FALSE(parseBenchControlLine("speech 0.5 banana", 3800, &control));
}

void test_sensor_adapter_parses_reduced_motion_commands() {
  BenchControl control;
  TEST_ASSERT_TRUE(parseBenchControlLine("reduced on", 4100, &control));
  TEST_ASSERT_FALSE(control.hasEvent);
  TEST_ASSERT_FALSE(control.hasSpeech);
  TEST_ASSERT_TRUE(control.hasReducedMotion);
  TEST_ASSERT_TRUE(control.reducedMotion);
  TEST_ASSERT_EQUAL_STRING("reduced_motion_on", control.command);

  TEST_ASSERT_TRUE(parseBenchControlLine("motion reduced off", 4200, &control));
  TEST_ASSERT_FALSE(control.hasEvent);
  TEST_ASSERT_TRUE(control.hasReducedMotion);
  TEST_ASSERT_FALSE(control.reducedMotion);
  TEST_ASSERT_EQUAL_STRING("reduced_motion_off", control.command);

  TEST_ASSERT_TRUE(parseBenchControlLine("reduced_motion 1", 4300, &control));
  TEST_ASSERT_TRUE(control.hasReducedMotion);
  TEST_ASSERT_TRUE(control.reducedMotion);

  TEST_ASSERT_FALSE(parseBenchControlLine("motion reduced maybe", 4400, &control));
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

bool containsText(const char* haystack, const char* needle) {
  return strstr(haystack, needle) != nullptr;
}

void test_speech_planner_uses_original_stackchan_lines() {
  SpeechPlanner planner;
  EmotionalProfile emotion;

  const SpeechCue boot = planner.plan(CharacterMode::Boot, emotion);
  TEST_ASSERT_TRUE(boot.shouldSpeak());
  TEST_ASSERT_EQUAL(SpeechIntent::Boot, boot.intent);
  TEST_ASSERT_EQUAL_STRING("Hello. I am Stackchan, and I am awake.", boot.text);
  TEST_ASSERT_TRUE(boot.hasEarcon());
  TEST_ASSERT_EQUAL(SpeechEarcon::Wake, boot.earcon);

  const SpeechCue think = planner.plan(CharacterMode::Think, emotion);
  TEST_ASSERT_TRUE(think.shouldSpeak());
  TEST_ASSERT_EQUAL(SpeechIntent::Think, think.intent);
  TEST_ASSERT_EQUAL_STRING("Input received. I am thinking now.", think.text);
  TEST_ASSERT_EQUAL(SpeechEarcon::Think, think.earcon);
  TEST_ASSERT_GREATER_THAN_UINT16(0, think.earconDelayMs);
}

void test_speech_planner_keeps_idle_quiet_until_emotion_moves() {
  SpeechPlanner planner;
  EmotionalProfile emotion;

  SpeechCue cue = planner.plan(CharacterMode::Idle, emotion);
  TEST_ASSERT_FALSE(cue.shouldSpeak());
  TEST_ASSERT_FALSE(cue.hasEarcon());

  emotion.arousal = 0.80f;
  cue = planner.plan(CharacterMode::Idle, emotion);
  TEST_ASSERT_TRUE(cue.shouldSpeak());
  TEST_ASSERT_EQUAL(SpeechIntent::Idle, cue.intent);
  TEST_ASSERT_EQUAL_STRING("Curiosity level rising.", cue.text);
  TEST_ASSERT_EQUAL(SpeechEarcon::Think, cue.earcon);
}

void test_speech_planner_marks_safety_with_distinct_earcon() {
  SpeechPlanner planner;
  EmotionalProfile emotion;
  emotion.focus = 0.90f;

  const SpeechCue cue = planner.plan(CharacterMode::Error, emotion);
  TEST_ASSERT_TRUE(cue.shouldSpeak());
  TEST_ASSERT_EQUAL(SpeechIntent::Safety, cue.intent);
  TEST_ASSERT_EQUAL(SpeechEarcon::Safety, cue.earcon);
  TEST_ASSERT_EQUAL_UINT16(0, cue.earconDelayMs);
}

void test_speech_planner_avoids_character_clone_markers() {
  SpeechPlanner planner;
  EmotionalProfile emotion;
  emotion.valence = 0.80f;
  emotion.arousal = 0.80f;
  emotion.focus = 0.80f;

  const CharacterMode modes[] = {
      CharacterMode::Boot,  CharacterMode::Idle,  CharacterMode::Attend,
      CharacterMode::Listen, CharacterMode::Think, CharacterMode::Speak,
      CharacterMode::React, CharacterMode::Sleep, CharacterMode::Error,
  };

  for (const CharacterMode mode : modes) {
    const SpeechCue cue = planner.plan(mode, emotion);
    if (!cue.shouldSpeak()) {
      continue;
    }

    TEST_ASSERT_FALSE(containsText(cue.text, "Johnny"));
    TEST_ASSERT_FALSE(containsText(cue.text, "Short Circuit"));
    TEST_ASSERT_FALSE(containsText(cue.text, "Number 5"));
    TEST_ASSERT_FALSE(containsText(cue.text, "No disassemble"));
  }
}

int main() {
  UNITY_BEGIN();
  RUN_TEST(test_spring_converges_without_exploding);
  RUN_TEST(test_dt_clamp_limits_large_step);
  RUN_TEST(test_wake_word_increases_arousal_and_focus);
  RUN_TEST(test_mood_decay_returns_toward_baseline);
  RUN_TEST(test_positive_valence_smiles);
  RUN_TEST(test_sleep_mode_closes_eyes_and_mouth);
  RUN_TEST(test_expression_mapper_sets_brow_tilt_direction);
  RUN_TEST(test_face_animator_outback_overshoots_then_settles);
  RUN_TEST(test_face_animator_smooths_channels_with_independent_timing);
  RUN_TEST(test_face_animator_uses_mode_authored_pose_keys);
  RUN_TEST(test_face_animator_autonomic_layer_adds_life_over_time);
  RUN_TEST(test_face_animator_reduced_motion_dampens_autonomic_offsets);
  RUN_TEST(test_robot_config_exposes_face_reduced_motion_default);
  RUN_TEST(test_face_animator_starts_listen_transition_with_blink_and_pop);
  RUN_TEST(test_face_animator_think_to_speak_centers_gaze_before_mouth_settles);
  RUN_TEST(test_face_animator_sleep_wake_transition_uses_longer_startle_clip);
  RUN_TEST(test_face_animator_speech_envelope_owns_mouth_channel);
  RUN_TEST(test_face_animator_speech_visemes_change_mouth_shape);
  RUN_TEST(test_face_animator_speech_sidecar_expires_when_updates_stop);
  RUN_TEST(test_robot_frame_carries_character_mode_for_renderer);
  RUN_TEST(test_robot_frame_carries_speech_cue_for_output_adapters);
  RUN_TEST(test_intent_engine_emits_deduped_speech_cue_on_external_event);
  RUN_TEST(test_sensor_adapter_parses_serial_mode_command);
  RUN_TEST(test_sensor_adapter_parses_help_without_event);
  RUN_TEST(test_sensor_adapter_parses_status_without_event);
  RUN_TEST(test_sensor_adapter_parses_event_aliases_and_clamps_strength);
  RUN_TEST(test_sensor_adapter_parses_speech_envelope_command);
  RUN_TEST(test_sensor_adapter_parses_speech_clear_and_rejects_unknown_viseme);
  RUN_TEST(test_sensor_adapter_parses_reduced_motion_commands);
  RUN_TEST(test_actuation_clamps_pitch_and_yaw_angle);
  RUN_TEST(test_actuation_clamps_yaw_velocity);
  RUN_TEST(test_disabled_yaw_commands_zero_velocity);
  RUN_TEST(test_speech_planner_uses_original_stackchan_lines);
  RUN_TEST(test_speech_planner_keeps_idle_quiet_until_emotion_moves);
  RUN_TEST(test_speech_planner_marks_safety_with_distinct_earcon);
  RUN_TEST(test_speech_planner_avoids_character_clone_markers);
  return UNITY_END();
}
