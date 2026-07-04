#include <unity.h>

#include <cmath>
#include <cstdio>
#include <cstdint>
#include <cstring>
#include <fstream>
#include <string>
#include <vector>

#include "face/ExpressionMapper.hpp"
#include "face/FaceAnimator.hpp"
#include "io/AudioOut.hpp"
#include "io/BridgeAudioDownlink.hpp"
#include "io/BridgeClient.hpp"
#include "io/BridgeEndpointControl.hpp"
#include "io/BridgeEndpointRegistry.hpp"
#include "io/BridgeEndpointStore.hpp"
#include "io/BridgeNetworkSession.hpp"
#include "io/BridgeSocketWriter.hpp"
#include "io/BridgeWebSocketTransport.hpp"
#include "io/CameraAdapter.hpp"
#include "io/SensorAdapter.hpp"
#include "io/SpeechAdapter.hpp"
#include "io/StackChanServoAdapter.hpp"
#include "motion/ActuationEngine.hpp"
#include "motion/Spring.hpp"
#include "PersonaBehavior.hpp"
#include "PersonaExpressions.hpp"
#include "PersonaPromptAssets.hpp"
#include "persona/AudioSaliency.hpp"
#include "persona/CommandMap.hpp"
#include "persona/EarconSynth.hpp"
#include "persona/EmotionModel.hpp"
#include "persona/GazeTracker.hpp"
#include "persona/IdleLife.hpp"
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

struct WavPcmFixture {
  uint32_t sampleRate = 0;
  std::vector<int16_t> left;
  std::vector<int16_t> right;
};

uint16_t readLe16(const std::vector<uint8_t>& bytes, size_t offset) {
  return static_cast<uint16_t>(bytes[offset] | (bytes[offset + 1] << 8));
}

uint32_t readLe32(const std::vector<uint8_t>& bytes, size_t offset) {
  return static_cast<uint32_t>(bytes[offset] | (bytes[offset + 1] << 8) |
                               (bytes[offset + 2] << 16) | (bytes[offset + 3] << 24));
}

bool readWavFixture(const char* relativePath, WavPcmFixture& out) {
  const char* roots[] = {"", "../", "../../"};
  std::ifstream file;
  for (const char* root : roots) {
    const std::string candidate = std::string(root) + relativePath;
    file.open(candidate, std::ios::binary);
    if (file.good()) {
      break;
    }
    file.close();
  }
  if (!file.good()) {
    return false;
  }

  std::vector<uint8_t> bytes((std::istreambuf_iterator<char>(file)), std::istreambuf_iterator<char>());
  if (bytes.size() < 44 || std::memcmp(bytes.data(), "RIFF", 4) != 0 ||
      std::memcmp(bytes.data() + 8, "WAVE", 4) != 0) {
    return false;
  }

  uint16_t channels = 0;
  uint16_t bitsPerSample = 0;
  uint16_t audioFormat = 0;
  size_t dataOffset = 0;
  uint32_t dataBytes = 0;

  size_t offset = 12;
  while (offset + 8 <= bytes.size()) {
    const uint32_t chunkSize = readLe32(bytes, offset + 4);
    const size_t payload = offset + 8;
    if (payload + chunkSize > bytes.size()) {
      return false;
    }
    if (std::memcmp(bytes.data() + offset, "fmt ", 4) == 0) {
      audioFormat = readLe16(bytes, payload);
      channels = readLe16(bytes, payload + 2);
      out.sampleRate = readLe32(bytes, payload + 4);
      bitsPerSample = readLe16(bytes, payload + 14);
    } else if (std::memcmp(bytes.data() + offset, "data", 4) == 0) {
      dataOffset = payload;
      dataBytes = chunkSize;
    }
    offset = payload + chunkSize + (chunkSize & 1);
  }

  if (audioFormat != 1 || channels != 2 || bitsPerSample != 16 || dataOffset == 0) {
    return false;
  }

  const size_t frameCount = dataBytes / 4;
  out.left.clear();
  out.right.clear();
  out.left.reserve(frameCount);
  out.right.reserve(frameCount);
  for (size_t i = 0; i < frameCount; ++i) {
    const size_t frameOffset = dataOffset + i * 4;
    out.left.push_back(static_cast<int16_t>(readLe16(bytes, frameOffset)));
    out.right.push_back(static_cast<int16_t>(readLe16(bytes, frameOffset + 2)));
  }
  return true;
}

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

void test_ambient_dark_night_increases_fatigue() {
  EmotionModel model;
  model.reset();

  const float initialArousal = model.profile().arousal;
  model.applyAmbient(4.0f, 23);

  TEST_ASSERT_GREATER_THAN_FLOAT(0.05f, model.profile().fatigue);
  TEST_ASSERT_LESS_THAN_FLOAT(initialArousal, model.profile().arousal);
}

void test_ambient_bright_day_reduces_fatigue_and_lifts_arousal() {
  EmotionModel model;
  model.reset();
  model.applyAmbient(4.0f, 23);

  const float tiredFatigue = model.profile().fatigue;
  const float tiredArousal = model.profile().arousal;
  model.applyAmbient(900.0f, 11);

  TEST_ASSERT_LESS_THAN_FLOAT(tiredFatigue, model.profile().fatigue);
  TEST_ASSERT_GREATER_THAN_FLOAT(tiredArousal, model.profile().arousal);
}

void test_circadian_evening_raises_fatigue_and_morning_recovers() {
  EmotionModel model;
  model.reset();

  const float initialArousal = model.profile().arousal;
  model.applyCircadian(22);

  const float nightFatigue = model.profile().fatigue;
  TEST_ASSERT_GREATER_THAN_FLOAT(0.05f, nightFatigue);
  TEST_ASSERT_LESS_THAN_FLOAT(initialArousal, model.profile().arousal);

  model.applyCircadian(7);
  TEST_ASSERT_LESS_THAN_FLOAT(nightFatigue, model.profile().fatigue);
}

void test_physical_events_shape_emotion() {
  EmotionModel forehead;
  forehead.reset();
  RobotEvent event;
  event.type = EventType::UserTouched;
  event.strength = 1.0f;
  event.hasPayload = true;
  event.y = -0.75f;
  forehead.applyEvent(event);
  TEST_ASSERT_GREATER_THAN_FLOAT(0.50f, forehead.profile().valence);
  TEST_ASSERT_FLOAT_WITHIN(0.02f, 0.20f, forehead.profile().arousal);

  EmotionModel poke;
  poke.reset();
  event.hasPayload = false;
  event.strength = 1.0f;
  poke.applyEvent(event);
  TEST_ASSERT_LESS_THAN_FLOAT(0.45f, poke.profile().valence);
  TEST_ASSERT_GREATER_THAN_FLOAT(0.30f, poke.profile().arousal);

  EmotionModel shaken;
  shaken.reset();
  event.type = EventType::Shaken;
  event.strength = 1.0f;
  shaken.applyEvent(event);
  TEST_ASSERT_GREATER_THAN_FLOAT(0.60f, shaken.profile().arousal);
  TEST_ASSERT_LESS_THAN_FLOAT(0.20f, shaken.profile().valence);
}

void test_audio_events_shape_attention_and_startle() {
  EmotionModel sound;
  sound.reset();
  RobotEvent event;
  event.type = EventType::SoundDirection;
  event.strength = 0.8f;
  event.hasPayload = true;
  event.x = -0.50f;
  event.z = 0.8f;
  sound.applyEvent(event);
  TEST_ASSERT_GREATER_THAN_FLOAT(0.85f, sound.profile().focus);
  TEST_ASSERT_GREATER_THAN_FLOAT(0.25f, sound.profile().arousal);

  EmotionModel loud;
  loud.reset();
  event.type = EventType::LoudNoise;
  event.strength = 1.0f;
  loud.applyEvent(event);
  TEST_ASSERT_GREATER_THAN_FLOAT(0.50f, loud.profile().arousal);
  TEST_ASSERT_LESS_THAN_FLOAT(0.35f, loud.profile().valence);
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

void test_audio_saliency_detects_speech_direction_and_habituation() {
  AudioSaliency saliency;
  saliency.reset(0.02f);

  AudioSaliencyResult first = saliency.process({100, 0.06f, 0.32f, 0.12f});
  TEST_ASSERT_TRUE(first.salient);
  TEST_ASSERT_TRUE(first.speechActive);
  TEST_ASSERT_TRUE(first.speechStarted);
  TEST_ASSERT_GREATER_THAN_FLOAT(45.0f, first.azimuthDeg);
  TEST_ASSERT_FLOAT_WITHIN(0.001f, 0.0f, first.habituation);

  AudioSaliencyResult repeated = saliency.process({900, 0.06f, 0.32f, 0.12f});
  TEST_ASSERT_TRUE(repeated.speechActive);
  TEST_ASSERT_GREATER_THAN_FLOAT(0.50f, repeated.habituation);

  AudioSaliencyResult novel = saliency.process({2300, 0.34f, 0.05f, 0.11f});
  TEST_ASSERT_TRUE(novel.salient);
  TEST_ASSERT_TRUE(novel.speechActive);
  TEST_ASSERT_LESS_THAN_FLOAT(-45.0f, novel.azimuthDeg);

  AudioSaliencyResult quiet = saliency.process({2600, 0.012f, 0.014f, 0.01f});
  TEST_ASSERT_FALSE(quiet.speechActive);
  TEST_ASSERT_TRUE(quiet.speechEnded);
}

void test_audio_saliency_marks_loud_noise_without_speech_band() {
  AudioSaliency saliency;
  saliency.reset(0.03f);

  AudioSaliencyResult result = saliency.process({100, 0.90f, 0.84f, 0.70f});
  TEST_ASSERT_TRUE(result.salient);
  TEST_ASSERT_TRUE(result.loudNoise);
  TEST_ASSERT_FALSE(result.speechActive);
  TEST_ASSERT_GREATER_THAN_FLOAT(0.80f, result.level);
}

void test_audio_saliency_uses_wav_fixtures_for_vad_and_direction() {
  WavPcmFixture rightSpeech;
  WavPcmFixture leftSpeech;
  WavPcmFixture music;
  WavPcmFixture fan;
  TEST_ASSERT_TRUE(readWavFixture("test/fixtures/audio/speech_right.wav", rightSpeech));
  TEST_ASSERT_TRUE(readWavFixture("test/fixtures/audio/speech_left.wav", leftSpeech));
  TEST_ASSERT_TRUE(readWavFixture("test/fixtures/audio/music_center.wav", music));
  TEST_ASSERT_TRUE(readWavFixture("test/fixtures/audio/fan_noise.wav", fan));
  TEST_ASSERT_EQUAL_UINT32(16000, rightSpeech.sampleRate);

  AudioSaliency saliency;
  saliency.reset(0.02f);
  AudioSaliencySample sample = makeAudioSaliencySample({100, rightSpeech.left.data(), rightSpeech.right.data(),
                                                        static_cast<uint16_t>(rightSpeech.left.size())});
  AudioSaliencyResult result = saliency.process(sample);
  TEST_ASSERT_TRUE(result.speechActive);
  TEST_ASSERT_TRUE(result.salient);
  TEST_ASSERT_GREATER_THAN_FLOAT(45.0f, result.azimuthDeg);
  TEST_ASSERT_GREATER_THAN_FLOAT(0.05f, sample.zeroCrossingRate);
  TEST_ASSERT_LESS_THAN_FLOAT(0.32f, sample.zeroCrossingRate);

  saliency.reset(0.02f);
  sample = makeAudioSaliencySample({100, leftSpeech.left.data(), leftSpeech.right.data(),
                                    static_cast<uint16_t>(leftSpeech.left.size())});
  result = saliency.process(sample);
  TEST_ASSERT_TRUE(result.speechActive);
  TEST_ASSERT_LESS_THAN_FLOAT(-45.0f, result.azimuthDeg);

  saliency.reset(0.02f);
  sample = makeAudioSaliencySample({100, music.left.data(), music.right.data(),
                                    static_cast<uint16_t>(music.left.size())});
  result = saliency.process(sample);
  TEST_ASSERT_FALSE(result.speechActive);
  TEST_ASSERT_FALSE(result.loudNoise);
  TEST_ASSERT_GREATER_THAN_FLOAT(0.32f, sample.zeroCrossingRate);

  saliency.reset(0.02f);
  sample = makeAudioSaliencySample({100, fan.left.data(), fan.right.data(),
                                    static_cast<uint16_t>(fan.left.size())});
  result = saliency.process(sample);
  TEST_ASSERT_FALSE(result.speechActive);
  TEST_ASSERT_FALSE(result.loudNoise);
  TEST_ASSERT_LESS_THAN_FLOAT(0.035f, sample.zeroCrossingRate);
}

void test_audio_reflex_maps_saliency_to_persona_events() {
  AudioReflex reflex;
  reflex.reset(0.02f);

  AudioReflexEvent events[3];
  uint8_t count = reflex.process({100, 0.05f, 0.35f, 0.12f}, events, 3);
  TEST_ASSERT_EQUAL_UINT8(2, count);
  TEST_ASSERT_TRUE(events[0].valid);
  TEST_ASSERT_EQUAL(static_cast<int>(EventType::UserSpeaking), static_cast<int>(events[0].event.type));
  TEST_ASSERT_EQUAL(static_cast<int>(CharacterMode::Listen), static_cast<int>(events[0].mode));
  TEST_ASSERT_EQUAL_STRING("audio_user_speaking", events[0].command);
  TEST_ASSERT_TRUE(events[1].valid);
  TEST_ASSERT_EQUAL(static_cast<int>(EventType::SoundDirection), static_cast<int>(events[1].event.type));
  TEST_ASSERT_EQUAL(static_cast<int>(CharacterMode::Attend), static_cast<int>(events[1].mode));
  TEST_ASSERT_GREATER_THAN_FLOAT(0.45f, events[1].event.x);
  TEST_ASSERT_GREATER_THAN_FLOAT(0.19f, events[1].event.z);
  TEST_ASSERT_EQUAL_STRING("audio_sound_direction", events[1].command);

  count = reflex.process({360, 0.012f, 0.010f, 0.01f}, events, 3);
  TEST_ASSERT_EQUAL_UINT8(1, count);
  TEST_ASSERT_EQUAL(static_cast<int>(EventType::SpeechEnded), static_cast<int>(events[0].event.type));
  TEST_ASSERT_EQUAL(static_cast<int>(CharacterMode::Idle), static_cast<int>(events[0].mode));
  TEST_ASSERT_EQUAL_STRING("audio_speech_ended", events[0].command);
  TEST_ASSERT_FALSE(reflex.telemetry().speechActive);
}

void test_audio_reflex_loud_noise_preempts_speech_events() {
  AudioReflex reflex;
  reflex.reset(0.03f);

  AudioReflexEvent events[3];
  const uint8_t count = reflex.process({100, 0.86f, 0.90f, 0.12f}, events, 3);
  TEST_ASSERT_EQUAL_UINT8(1, count);
  TEST_ASSERT_TRUE(events[0].valid);
  TEST_ASSERT_EQUAL(static_cast<int>(EventType::LoudNoise), static_cast<int>(events[0].event.type));
  TEST_ASSERT_EQUAL(static_cast<int>(CharacterMode::React), static_cast<int>(events[0].mode));
  TEST_ASSERT_EQUAL_STRING("audio_loud_noise", events[0].command);
  TEST_ASSERT_TRUE(reflex.telemetry().loudNoise);
  TEST_ASSERT_GREATER_THAN_FLOAT(0.80f, reflex.telemetry().level);
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

void test_persona_expression_codegen_exposes_pose_targets() {
  TEST_ASSERT_EQUAL_STRING("spark", generated_persona::kExpressionsPersonaId);
  TEST_ASSERT_FLOAT_WITHIN(0.001f, 0.85f, generated_persona::kNeutralExpression.eyeOpen);
  TEST_ASSERT_FLOAT_WITHIN(0.001f, 0.15f, generated_persona::kNeutralExpression.eyeSmile);
  TEST_ASSERT_FLOAT_WITHIN(0.001f, 0.15f, generated_persona::kNeutralExpression.mouthSmile);
  TEST_ASSERT_FLOAT_WITHIN(0.001f, 0.58f, generated_persona::kDrowsyExpression.eyeOpen);
  TEST_ASSERT_FLOAT_WITHIN(0.001f, -0.20f, generated_persona::kThinkPupilY);
  TEST_ASSERT_FLOAT_WITHIN(0.001f, 18.0f, generated_persona::kThinkYawBiasDeg);
  TEST_ASSERT_FLOAT_WITHIN(0.001f, -4.0f, generated_persona::kListenPitchBiasDeg);
  TEST_ASSERT_EQUAL_UINT32(1200, generated_persona::kYawnDurationMs);
  TEST_ASSERT_FLOAT_WITHIN(0.001f, 0.55f, generated_persona::kYawnMouthOpen);
}

void test_expression_mapper_uses_persona_expression_defaults() {
  ExpressionMapper mapper;
  EmotionalProfile emotion;
  FaceTargets neutral = mapper.map(emotion, CharacterMode::Idle);

  TEST_ASSERT_FLOAT_WITHIN(0.001f, generated_persona::kNeutralExpression.eyeOpen, neutral.eyeOpen);
  TEST_ASSERT_FLOAT_WITHIN(0.001f, generated_persona::kNeutralExpression.eyeSmile, neutral.eyeSmile);
  TEST_ASSERT_FLOAT_WITHIN(0.001f, generated_persona::kNeutralExpression.mouthSmile, neutral.mouthSmile);

  emotion.fatigue = 0.90f;
  FaceTargets drowsy = mapper.map(emotion, CharacterMode::Idle);
  TEST_ASSERT_FLOAT_WITHIN(0.001f, generated_persona::kDrowsyExpression.eyeOpen, drowsy.eyeOpen);
  TEST_ASSERT_FLOAT_WITHIN(0.001f, generated_persona::kDrowsyExpression.faceY, drowsy.faceY);
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

void test_face_animator_uses_persona_behavior_breathing_amplitude() {
  FaceAnimator animator;
  RobotFrame frame = makeNeutralFrame();
  frame.mode = CharacterMode::Idle;
  frame.emotion.arousal = 0.20f;

  const FaceTargets face = animator.composeFrame(frame, 1250);

  TEST_ASSERT_FLOAT_WITHIN(0.15f, generated_persona::kIdleBreathingPx, face.faceY);
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
  TEST_ASSERT_TRUE(reducedMotion.isReducedMotion());
  TEST_ASSERT_FALSE(fullMotion.isReducedMotion());
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

void test_intent_engine_demo_can_be_disabled_and_resumed() {
  IntentEngine engine;
  engine.begin();
  TEST_ASSERT_TRUE(engine.isDemoEnabled());

  engine.setDemoEnabled(false, 0);
  TEST_ASSERT_FALSE(engine.isDemoEnabled());
  const RobotFrame quiet = engine.update(4000);
  TEST_ASSERT_EQUAL(static_cast<int>(CharacterMode::Idle), static_cast<int>(quiet.mode));

  engine.setDemoEnabled(true, 4000);
  TEST_ASSERT_TRUE(engine.isDemoEnabled());
  const RobotFrame held = engine.update(6500);
  TEST_ASSERT_EQUAL(static_cast<int>(CharacterMode::Idle), static_cast<int>(held.mode));

  const RobotFrame demo = engine.update(7100);
  TEST_ASSERT_EQUAL(static_cast<int>(CharacterMode::Think), static_cast<int>(demo.mode));
}

void test_idle_life_breathing_moves_face_and_body_together() {
  IdleLife idle;
  idle.reset(0);
  RobotFrame frame = makeNeutralFrame();
  frame.timestampMs = 1250;
  frame.mode = CharacterMode::Idle;
  frame.emotion.arousal = 0.20f;
  frame.emotion.focus = 0.55f;

  idle.apply(frame, 1250, false);

  TEST_ASSERT_GREATER_THAN_FLOAT(0.20f, fabsf(frame.face.faceY));
  TEST_ASSERT_GREATER_THAN_FLOAT(0.05f, fabsf(frame.motion.pitchDeg));
  TEST_ASSERT_GREATER_THAN_FLOAT(0.90f, frame.face.pupilScale);
}

void test_persona_behavior_codegen_exposes_idle_life_tuning() {
  TEST_ASSERT_EQUAL_STRING("spark", generated_persona::kBehaviorPersonaId);
  TEST_ASSERT_FLOAT_WITHIN(0.001f, 0.20f, generated_persona::kIdleBreathingHz);
  TEST_ASSERT_FLOAT_WITHIN(0.001f, 1.50f, generated_persona::kIdleBreathingPx);
  TEST_ASSERT_EQUAL_UINT32(10000, generated_persona::kIdleFidgetMinMs);
  TEST_ASSERT_EQUAL_UINT32(30000, generated_persona::kIdleFidgetMaxMs);
  TEST_ASSERT_FLOAT_WITHIN(0.001f, 0.30f, generated_persona::kReducedMotionScale);
  TEST_ASSERT_EQUAL_UINT8(18, generated_persona::kEveningStartHour);
  TEST_ASSERT_EQUAL_UINT8(21, generated_persona::kNightStartHour);
  TEST_ASSERT_EQUAL_UINT8(6, generated_persona::kMorningStartHour);
  TEST_ASSERT_EQUAL_UINT8(10, generated_persona::kMorningEndHour);
}

void test_idle_life_reduced_motion_dampens_offsets() {
  IdleLife fullMotion;
  IdleLife reducedMotion;
  fullMotion.reset(0);
  reducedMotion.reset(0);
  RobotFrame full = makeNeutralFrame();
  RobotFrame reduced = makeNeutralFrame();
  full.emotion.arousal = 0.20f;
  reduced.emotion.arousal = 0.20f;

  fullMotion.apply(full, 1250, false);
  reducedMotion.apply(reduced, 1250, true);

  TEST_ASSERT_GREATER_THAN_FLOAT(fabsf(reduced.face.faceY), fabsf(full.face.faceY));
  TEST_ASSERT_GREATER_THAN_FLOAT(fabsf(reduced.motion.pitchDeg), fabsf(full.motion.pitchDeg));
}

void test_idle_life_micro_expression_is_deterministic() {
  IdleLife first;
  IdleLife second;
  first.reset(0);
  second.reset(0);
  RobotFrame a = makeNeutralFrame();
  RobotFrame b = makeNeutralFrame();

  first.apply(a, 1920, false);
  second.apply(b, 1920, false);

  TEST_ASSERT_GREATER_THAN_FLOAT(0.18f, a.face.mouthSmile);
  TEST_ASSERT_FLOAT_WITHIN(0.0001f, a.face.mouthSmile, b.face.mouthSmile);
  TEST_ASSERT_FLOAT_WITHIN(0.0001f, first.telemetry().microExpression, second.telemetry().microExpression);
}

void test_idle_life_yawn_uses_fatigue_and_reduced_motion() {
  IdleLife fullMotion;
  IdleLife reducedMotion;
  fullMotion.reset(0);
  reducedMotion.reset(0);

  RobotFrame full = makeNeutralFrame();
  RobotFrame reduced = makeNeutralFrame();
  full.emotion.fatigue = 0.90f;
  reduced.emotion.fatigue = 0.90f;

  fullMotion.apply(full, 4800, false);
  reducedMotion.apply(reduced, 4800, true);

  TEST_ASSERT_GREATER_THAN_FLOAT(0.20f, full.face.mouthOpen);
  TEST_ASSERT_LESS_THAN_FLOAT(0.80f, full.face.eyeOpen);
  TEST_ASSERT_GREATER_THAN_FLOAT(reduced.face.mouthOpen * 2.0f, full.face.mouthOpen);
  TEST_ASSERT_GREATER_THAN_FLOAT(reducedMotion.telemetry().yawn * 2.0f, fullMotion.telemetry().yawn);
}

void test_intent_engine_reduced_motion_dampens_idle_life() {
  IntentEngine fullMotion;
  IntentEngine reducedMotion;
  fullMotion.begin();
  reducedMotion.begin();
  fullMotion.setDemoEnabled(false, 0);
  reducedMotion.setDemoEnabled(false, 0);
  reducedMotion.setReducedMotion(true);

  const RobotFrame full = fullMotion.update(1250);
  const RobotFrame reduced = reducedMotion.update(1250);

  TEST_ASSERT_FALSE(fullMotion.isReducedMotion());
  TEST_ASSERT_TRUE(reducedMotion.isReducedMotion());
  TEST_ASSERT_GREATER_THAN_FLOAT(fabsf(reduced.face.faceY), fabsf(full.face.faceY));
}

void test_intent_engine_applies_ambient_context() {
  IntentEngine engine;
  engine.begin();
  engine.setDemoEnabled(false, 0);
  engine.applyAmbient(5.0f, 22);

  const RobotFrame frame = engine.update(250);
  TEST_ASSERT_GREATER_THAN_FLOAT(0.05f, frame.emotion.fatigue);
  TEST_ASSERT_LESS_THAN_FLOAT(0.20f, frame.emotion.arousal);
}

void test_intent_engine_applies_circadian_context() {
  IntentEngine engine;
  engine.begin();
  engine.setDemoEnabled(false, 0);
  engine.applyCircadian(23);

  const RobotFrame frame = engine.update(250);
  TEST_ASSERT_GREATER_THAN_FLOAT(0.05f, frame.emotion.fatigue);
  TEST_ASSERT_LESS_THAN_FLOAT(0.20f, frame.emotion.arousal);
}

void test_intent_engine_orients_toward_sound_event() {
  IntentEngine engine;
  engine.begin();
  engine.setDemoEnabled(false, 0);

  const RobotFrame before = engine.update(100);

  RobotEvent event;
  event.type = EventType::SoundDirection;
  event.timestampMs = 150;
  event.strength = 0.8f;
  event.hasPayload = true;
  event.x = 0.50f;
  event.z = 0.8f;
  engine.applyEvent(event, CharacterMode::Attend);

  const RobotFrame oriented = engine.update(200);
  TEST_ASSERT_EQUAL(static_cast<int>(CharacterMode::Attend), static_cast<int>(oriented.mode));
  TEST_ASSERT_GREATER_THAN_FLOAT(before.face.pupilX + 0.10f, oriented.face.pupilX);
  TEST_ASSERT_GREATER_THAN_FLOAT(before.motion.yawDeg + 5.0f, oriented.motion.yawDeg);
}

void test_gaze_tracker_uses_face_payload_for_eye_and_head_tracking() {
  GazeTracker tracker;
  tracker.reset(0);
  RobotFrame frame = makeNeutralFrame();
  frame.motion.yawMode = YawMode::Angle;

  RobotEvent event;
  event.type = EventType::FaceDetected;
  event.timestampMs = 100;
  event.strength = 1.0f;
  event.hasPayload = true;
  event.x = 0.65f;
  event.y = -0.25f;
  event.z = 0.70f;
  tracker.applyEvent(event);
  tracker.apply(frame, 140, false);

  TEST_ASSERT_TRUE(tracker.telemetry().tracking);
  TEST_ASSERT_GREATER_THAN_FLOAT(0.12f, frame.face.pupilX);
  TEST_ASSERT_LESS_THAN_FLOAT(-0.02f, frame.face.pupilY);
  TEST_ASSERT_GREATER_THAN_FLOAT(1.0f, frame.face.faceX);
  TEST_ASSERT_GREATER_THAN_FLOAT(4.0f, frame.motion.yawDeg);
  TEST_ASSERT_LESS_THAN_FLOAT(-0.5f, frame.motion.pitchDeg);
}

void test_gaze_tracker_reduced_motion_dampens_face_tracking() {
  GazeTracker tracker;
  RobotEvent event;
  event.type = EventType::FaceDetected;
  event.timestampMs = 100;
  event.strength = 1.0f;
  event.hasPayload = true;
  event.x = 0.80f;
  event.y = 0.20f;
  event.z = 0.80f;

  RobotFrame full = makeNeutralFrame();
  full.motion.yawMode = YawMode::Angle;
  tracker.reset(0);
  tracker.applyEvent(event);
  tracker.apply(full, 130, false);

  RobotFrame reduced = makeNeutralFrame();
  reduced.motion.yawMode = YawMode::Angle;
  tracker.reset(0);
  tracker.applyEvent(event);
  tracker.apply(reduced, 130, true);

  TEST_ASSERT_GREATER_THAN_FLOAT(fabsf(reduced.face.pupilX) * 2.0f, fabsf(full.face.pupilX));
  TEST_ASSERT_GREATER_THAN_FLOAT(fabsf(reduced.motion.yawDeg) * 2.0f, fabsf(full.motion.yawDeg));
}

void test_gaze_tracker_face_lost_holds_then_decays_last_seen_direction() {
  GazeTracker tracker;
  tracker.reset(0);

  RobotEvent seen;
  seen.type = EventType::FaceDetected;
  seen.timestampMs = 100;
  seen.strength = 1.0f;
  seen.hasPayload = true;
  seen.x = -0.70f;
  seen.y = 0.0f;
  seen.z = 0.60f;
  tracker.applyEvent(seen);

  RobotEvent lost;
  lost.type = EventType::FaceLost;
  lost.timestampMs = 900;
  lost.strength = 1.0f;
  tracker.applyEvent(lost);

  RobotFrame searching = makeNeutralFrame();
  searching.motion.yawMode = YawMode::Angle;
  tracker.apply(searching, 1300, false);
  TEST_ASSERT_FALSE(tracker.telemetry().tracking);
  TEST_ASSERT_LESS_THAN_FLOAT(-0.02f, searching.face.pupilX);
  TEST_ASSERT_LESS_THAN_FLOAT(-0.3f, searching.motion.yawDeg);

  RobotFrame settled = makeNeutralFrame();
  settled.motion.yawMode = YawMode::Angle;
  tracker.apply(settled, 7000, false);
  TEST_ASSERT_FLOAT_WITHIN(0.001f, 0.0f, settled.face.pupilX);
}

void test_intent_engine_tracks_face_position_payload() {
  IntentEngine engine;
  engine.begin();
  engine.setDemoEnabled(false, 100);

  RobotFrame before = engine.update(100);
  RobotEvent event;
  event.type = EventType::FaceDetected;
  event.timestampMs = 120;
  event.strength = 1.0f;
  event.hasPayload = true;
  event.x = -0.65f;
  event.y = 0.20f;
  event.z = 0.75f;
  engine.applyEvent(event, CharacterMode::Attend);

  const RobotFrame tracked = engine.update(160);
  TEST_ASSERT_EQUAL(static_cast<int>(CharacterMode::Attend), static_cast<int>(tracked.mode));
  TEST_ASSERT_LESS_THAN_FLOAT(before.face.pupilX - 0.10f, tracked.face.pupilX);
  TEST_ASSERT_LESS_THAN_FLOAT(before.motion.yawDeg - 3.0f, tracked.motion.yawDeg);
}

void test_camera_adapter_publishes_clamped_face_detection() {
  CameraAdapter camera;
  TEST_ASSERT_TRUE(camera.begin());
  TEST_ASSERT_TRUE(camera.telemetry().ready);
  TEST_ASSERT_FALSE(camera.telemetry().hardwareEnabled);
  TEST_ASSERT_FALSE(camera.telemetry().active);

  camera.submitFace(1.4f, -1.2f, 1.8f, 501);

  RobotEvent event;
  TEST_ASSERT_TRUE(camera.poll(&event));
  TEST_ASSERT_EQUAL(static_cast<int>(EventType::FaceDetected), static_cast<int>(event.type));
  TEST_ASSERT_TRUE(event.hasPayload);
  TEST_ASSERT_FLOAT_WITHIN(0.001f, 1.0f, event.x);
  TEST_ASSERT_FLOAT_WITHIN(0.001f, -1.0f, event.y);
  TEST_ASSERT_FLOAT_WITHIN(0.001f, 1.0f, event.z);
  TEST_ASSERT_EQUAL_UINT32(1, camera.telemetry().eventsPublished);
  TEST_ASSERT_EQUAL_UINT32(501, camera.telemetry().lastEventMs);
  TEST_ASSERT_FALSE(camera.poll(&event));
}

void test_camera_adapter_publishes_face_lost_event() {
  CameraAdapter camera;
  TEST_ASSERT_TRUE(camera.begin());
  camera.submitFaceLost(700, 1.5f);

  RobotEvent event;
  TEST_ASSERT_TRUE(camera.poll(&event));
  TEST_ASSERT_EQUAL(static_cast<int>(EventType::FaceLost), static_cast<int>(event.type));
  TEST_ASSERT_FALSE(event.hasPayload);
  TEST_ASSERT_FLOAT_WITHIN(0.001f, 1.0f, event.strength);
  TEST_ASSERT_EQUAL_UINT32(1, camera.telemetry().eventsPublished);
}

void test_command_map_maps_multinet_phrase_ids_to_existing_actions() {
  const CommandMapResult sleep = CommandMap::mapPhraseId(1, 6100);
  TEST_ASSERT_TRUE(sleep.valid);
  TEST_ASSERT_TRUE(sleep.hasEvent);
  TEST_ASSERT_TRUE(sleep.hasSpeechCue);
  TEST_ASSERT_EQUAL(static_cast<int>(CharacterMode::Sleep), static_cast<int>(sleep.mode));
  TEST_ASSERT_EQUAL(static_cast<int>(EventType::IdleTimeout), static_cast<int>(sleep.event.type));
  TEST_ASSERT_EQUAL(static_cast<int>(SpeechIntent::Sleep), static_cast<int>(sleep.speechCue.intent));
  TEST_ASSERT_EQUAL(static_cast<int>(SpeechEarcon::Sleep), static_cast<int>(sleep.speechCue.earcon));
  TEST_ASSERT_EQUAL_UINT32(6100, sleep.event.timestampMs);
  TEST_ASSERT_EQUAL_STRING("command_go_to_sleep", sleep.command);

  const CommandMapResult wake = CommandMap::mapPhraseId(2, 6200);
  TEST_ASSERT_TRUE(wake.valid);
  TEST_ASSERT_TRUE(wake.hasEvent);
  TEST_ASSERT_TRUE(wake.hasSpeechCue);
  TEST_ASSERT_EQUAL(static_cast<int>(CharacterMode::Listen), static_cast<int>(wake.mode));
  TEST_ASSERT_EQUAL(static_cast<int>(EventType::WakeWord), static_cast<int>(wake.event.type));
  TEST_ASSERT_EQUAL(static_cast<int>(SpeechEarcon::Wake), static_cast<int>(wake.speechCue.earcon));
  TEST_ASSERT_EQUAL_STRING("command_wake_up", wake.command);

  const CommandMapResult look = CommandMap::mapPhraseId(3, 6300);
  TEST_ASSERT_TRUE(look.valid);
  TEST_ASSERT_TRUE(look.hasEvent);
  TEST_ASSERT_TRUE(look.hasSpeechCue);
  TEST_ASSERT_TRUE(look.event.hasPayload);
  TEST_ASSERT_EQUAL(static_cast<int>(CharacterMode::Attend), static_cast<int>(look.mode));
  TEST_ASSERT_EQUAL(static_cast<int>(EventType::FaceDetected), static_cast<int>(look.event.type));
  TEST_ASSERT_EQUAL(static_cast<int>(SpeechIntent::Attend), static_cast<int>(look.speechCue.intent));
  TEST_ASSERT_FLOAT_WITHIN(0.001f, 0.0f, look.event.x);
  TEST_ASSERT_EQUAL_STRING("command_look_at_me", look.command);

  const CommandMapResult stop = CommandMap::mapPhraseId(4, 6400);
  TEST_ASSERT_TRUE(stop.valid);
  TEST_ASSERT_FALSE(stop.hasEvent);
  TEST_ASSERT_TRUE(stop.hasMotionEnable);
  TEST_ASSERT_FALSE(stop.motionEnabled);
  TEST_ASSERT_TRUE(stop.hasSpeechCue);
  TEST_ASSERT_EQUAL(static_cast<int>(SpeechIntent::Safety), static_cast<int>(stop.speechCue.intent));
  TEST_ASSERT_EQUAL(static_cast<int>(SpeechEarcon::Safety), static_cast<int>(stop.speechCue.earcon));
  TEST_ASSERT_EQUAL_STRING("command_stop_moving", stop.command);

  const CommandMapResult feel = CommandMap::mapPhraseId(5, 6500);
  TEST_ASSERT_TRUE(feel.valid);
  TEST_ASSERT_TRUE(feel.hasEvent);
  TEST_ASSERT_TRUE(feel.hasSpeechCue);
  TEST_ASSERT_EQUAL(static_cast<int>(CharacterMode::Speak), static_cast<int>(feel.mode));
  TEST_ASSERT_EQUAL(static_cast<int>(EventType::ResponseStarted), static_cast<int>(feel.event.type));
  TEST_ASSERT_EQUAL(static_cast<int>(SpeechIntent::Speak), static_cast<int>(feel.speechCue.intent));
  TEST_ASSERT_EQUAL_STRING("command_how_do_you_feel", feel.command);

  TEST_ASSERT_FALSE(CommandMap::mapPhraseId(99, 6600).valid);
}

void test_command_map_accepts_bench_tokens_matching_yaml_keys() {
  TEST_ASSERT_EQUAL(static_cast<int>(SpokenCommandId::GoToSleep),
                    static_cast<int>(CommandMap::fromToken("go_to_sleep")));
  TEST_ASSERT_EQUAL(static_cast<int>(SpokenCommandId::WakeUp),
                    static_cast<int>(CommandMap::fromToken("wake_up")));
  TEST_ASSERT_EQUAL(static_cast<int>(SpokenCommandId::LookAtMe),
                    static_cast<int>(CommandMap::fromToken("look_at_me")));
  TEST_ASSERT_EQUAL(static_cast<int>(SpokenCommandId::StopMoving),
                    static_cast<int>(CommandMap::fromToken("stop_moving")));
  TEST_ASSERT_EQUAL(static_cast<int>(SpokenCommandId::HowDoYouFeel),
                    static_cast<int>(CommandMap::fromToken("how_do_you_feel")));
  TEST_ASSERT_EQUAL(static_cast<int>(SpokenCommandId::LookAtMe),
                    static_cast<int>(CommandMap::fromToken("3")));
  TEST_ASSERT_EQUAL(static_cast<int>(SpokenCommandId::Unknown),
                    static_cast<int>(CommandMap::fromToken("dance")));
}

void test_intent_engine_prioritizes_explicit_command_speech_cue() {
  IntentEngine engine;
  engine.begin();
  engine.setDemoEnabled(false, 100);

  RobotEvent event;
  event.type = EventType::FaceDetected;
  event.timestampMs = 200;
  event.strength = 1.0f;
  engine.applyEvent(event, CharacterMode::Attend);

  SpeechCue cue;
  cue.intent = SpeechIntent::Safety;
  cue.text = "Motion hold active. I will stay still.";
  cue.priority = 250;
  cue.earcon = SpeechEarcon::Safety;
  cue.earconDelayMs = 0;
  engine.queueSpeechCue(cue, 205);

  const RobotFrame frame = engine.update(210);
  TEST_ASSERT_TRUE(frame.speech.shouldSpeak());
  TEST_ASSERT_EQUAL(static_cast<int>(SpeechIntent::Safety), static_cast<int>(frame.speech.intent));
  TEST_ASSERT_EQUAL(static_cast<int>(SpeechEarcon::Safety), static_cast<int>(frame.speech.earcon));
  TEST_ASSERT_EQUAL_STRING("Motion hold active. I will stay still.", frame.speech.text);
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

void test_sensor_adapter_parses_ambient_context_commands() {
  BenchControl control;
  TEST_ASSERT_TRUE(parseBenchControlLine("ambient 12 22", 3900, &control));
  TEST_ASSERT_FALSE(control.hasEvent);
  TEST_ASSERT_FALSE(control.hasSpeech);
  TEST_ASSERT_TRUE(control.hasAmbient);
  TEST_ASSERT_FLOAT_WITHIN(0.001f, 12.0f, control.ambient.lux);
  TEST_ASSERT_EQUAL_UINT8(22, control.ambient.hourOfDay);
  TEST_ASSERT_EQUAL_STRING("ambient_context", control.command);

  TEST_ASSERT_TRUE(parseBenchControlLine("light lux=700 hour=10", 4000, &control));
  TEST_ASSERT_TRUE(control.hasAmbient);
  TEST_ASSERT_FLOAT_WITHIN(0.001f, 700.0f, control.ambient.lux);
  TEST_ASSERT_EQUAL_UINT8(10, control.ambient.hourOfDay);

  TEST_ASSERT_FALSE(parseBenchControlLine("ambient lux 40 hour 25", 4050, &control));
}

void test_sensor_adapter_parses_circadian_context_commands() {
  BenchControl control;
  TEST_ASSERT_TRUE(parseBenchControlLine("time 22", 4060, &control));
  TEST_ASSERT_FALSE(control.hasEvent);
  TEST_ASSERT_FALSE(control.hasSpeech);
  TEST_ASSERT_FALSE(control.hasAmbient);
  TEST_ASSERT_TRUE(control.hasCircadian);
  TEST_ASSERT_EQUAL_UINT8(22, control.hourOfDay);
  TEST_ASSERT_EQUAL_STRING("circadian_context", control.command);

  TEST_ASSERT_TRUE(parseBenchControlLine("circadian hour 7", 4070, &control));
  TEST_ASSERT_TRUE(control.hasCircadian);
  TEST_ASSERT_EQUAL_UINT8(7, control.hourOfDay);

  TEST_ASSERT_FALSE(parseBenchControlLine("time 24", 4080, &control));
}

void test_sensor_adapter_parses_face_tracking_commands() {
  BenchControl control;
  TEST_ASSERT_TRUE(parseBenchControlLine("facepos x=-0.50 y=0.25 s=0.70", 4081, &control));
  TEST_ASSERT_TRUE(control.hasEvent);
  TEST_ASSERT_EQUAL(static_cast<int>(CharacterMode::Attend), static_cast<int>(control.mode));
  TEST_ASSERT_EQUAL(static_cast<int>(EventType::FaceDetected), static_cast<int>(control.event.type));
  TEST_ASSERT_TRUE(control.event.hasPayload);
  TEST_ASSERT_FLOAT_WITHIN(0.001f, -0.50f, control.event.x);
  TEST_ASSERT_FLOAT_WITHIN(0.001f, 0.25f, control.event.y);
  TEST_ASSERT_FLOAT_WITHIN(0.001f, 0.70f, control.event.z);
  TEST_ASSERT_EQUAL_STRING("face_position", control.command);

  TEST_ASSERT_TRUE(parseBenchControlLine("facepos 0.40 -0.20 0.60", 4082, &control));
  TEST_ASSERT_TRUE(control.event.hasPayload);
  TEST_ASSERT_FLOAT_WITHIN(0.001f, 0.40f, control.event.x);
  TEST_ASSERT_FLOAT_WITHIN(0.001f, -0.20f, control.event.y);
  TEST_ASSERT_FLOAT_WITHIN(0.001f, 0.60f, control.event.z);

  TEST_ASSERT_TRUE(parseBenchControlLine("facelost", 4083, &control));
  TEST_ASSERT_TRUE(control.hasEvent);
  TEST_ASSERT_EQUAL(static_cast<int>(CharacterMode::Idle), static_cast<int>(control.mode));
  TEST_ASSERT_EQUAL(static_cast<int>(EventType::FaceLost), static_cast<int>(control.event.type));
  TEST_ASSERT_EQUAL_STRING("face_lost", control.command);

  TEST_ASSERT_TRUE(parseBenchControlLine("face", 4084, &control));
  TEST_ASSERT_EQUAL_STRING("event_face", control.command);
  TEST_ASSERT_EQUAL(static_cast<int>(EventType::FaceDetected), static_cast<int>(control.event.type));

  TEST_ASSERT_FALSE(parseBenchControlLine("facepos x=0.1 y=0.2", 4085, &control));
}

void test_sensor_adapter_parses_spoken_command_bench_events() {
  BenchControl control;
  TEST_ASSERT_TRUE(parseBenchControlLine("command 3", 4081, &control));
  TEST_ASSERT_TRUE(control.hasEvent);
  TEST_ASSERT_TRUE(control.hasSpeechCue);
  TEST_ASSERT_EQUAL(static_cast<int>(CharacterMode::Attend), static_cast<int>(control.mode));
  TEST_ASSERT_EQUAL(static_cast<int>(EventType::FaceDetected), static_cast<int>(control.event.type));
  TEST_ASSERT_EQUAL(static_cast<int>(SpeechIntent::Attend), static_cast<int>(control.speechCue.intent));
  TEST_ASSERT_TRUE(control.event.hasPayload);
  TEST_ASSERT_EQUAL_STRING("command_look_at_me", control.command);

  TEST_ASSERT_TRUE(parseBenchControlLine("cmd stop_moving", 4082, &control));
  TEST_ASSERT_FALSE(control.hasEvent);
  TEST_ASSERT_TRUE(control.hasMotionEnable);
  TEST_ASSERT_FALSE(control.motionEnabled);
  TEST_ASSERT_TRUE(control.hasSpeechCue);
  TEST_ASSERT_EQUAL(static_cast<int>(SpeechIntent::Safety), static_cast<int>(control.speechCue.intent));
  TEST_ASSERT_EQUAL(static_cast<int>(SpeechEarcon::Safety), static_cast<int>(control.speechCue.earcon));
  TEST_ASSERT_EQUAL_STRING("command_stop_moving", control.command);

  TEST_ASSERT_TRUE(parseBenchControlLine("phrase how-do-you-feel", 4083, &control));
  TEST_ASSERT_TRUE(control.hasEvent);
  TEST_ASSERT_TRUE(control.hasSpeechCue);
  TEST_ASSERT_EQUAL(static_cast<int>(CharacterMode::Speak), static_cast<int>(control.mode));
  TEST_ASSERT_EQUAL(static_cast<int>(EventType::ResponseStarted), static_cast<int>(control.event.type));
  TEST_ASSERT_EQUAL(static_cast<int>(SpeechIntent::Speak), static_cast<int>(control.speechCue.intent));
  TEST_ASSERT_EQUAL_STRING("command_how_do_you_feel", control.command);

  TEST_ASSERT_FALSE(parseBenchControlLine("command unknown", 4084, &control));
}

void test_sensor_adapter_parses_direct_speech_intent_cues() {
  const SpeechIntent intents[] = {
      SpeechIntent::Boot,
      SpeechIntent::Idle,
      SpeechIntent::Attend,
      SpeechIntent::Listen,
      SpeechIntent::Think,
      SpeechIntent::Speak,
      SpeechIntent::React,
      SpeechIntent::Happy,
      SpeechIntent::Concern,
      SpeechIntent::Sleep,
      SpeechIntent::Error,
      SpeechIntent::Safety,
  };
  const char* names[] = {
      "boot",
      "idle",
      "attend",
      "listen",
      "think",
      "speak",
      "react",
      "happy",
      "concern",
      "sleep",
      "error",
      "safety",
  };

  for (size_t i = 0; i < sizeof(intents) / sizeof(intents[0]); ++i) {
    char command[32] = {};
    snprintf(command, sizeof(command), "speak %s", names[i]);
    BenchControl control;
    TEST_ASSERT_TRUE(parseBenchControlLine(command, 4090 + static_cast<uint32_t>(i), &control));
    TEST_ASSERT_FALSE(control.hasEvent);
    TEST_ASSERT_TRUE(control.hasSpeechCue);
    TEST_ASSERT_EQUAL(static_cast<int>(intents[i]), static_cast<int>(control.speechCue.intent));
    TEST_ASSERT_TRUE(control.speechCue.shouldSpeak());
    TEST_ASSERT_NOT_EQUAL(static_cast<int>(SpeechEarcon::None), static_cast<int>(control.speechCue.earcon));
    TEST_ASSERT_EQUAL_STRING("speak_intent", control.command);
  }

  BenchControl speakMode;
  TEST_ASSERT_TRUE(parseBenchControlLine("speak 0.5", 4104, &speakMode));
  TEST_ASSERT_TRUE(speakMode.hasEvent);
  TEST_ASSERT_FALSE(speakMode.hasSpeechCue);
  TEST_ASSERT_EQUAL(static_cast<int>(CharacterMode::Speak), static_cast<int>(speakMode.mode));

  BenchControl unknown;
  TEST_ASSERT_FALSE(parseBenchControlLine("speak unknown", 4105, &unknown));
}

void test_sensor_adapter_parses_bridge_conversation_commands() {
  BenchControl control;
  TEST_ASSERT_TRUE(parseBenchControlLine("bridge hello session42", 4110, &control));
  TEST_ASSERT_TRUE(control.hasBridge);
  TEST_ASSERT_EQUAL_STRING("bridge_control", control.command);
  TEST_ASSERT_EQUAL_STRING("{\"type\":\"hello\",\"session\":\"session42\"}", control.bridge.controlLine);

  TEST_ASSERT_TRUE(parseBenchControlLine("bridge thinking 42", 4111, &control));
  TEST_ASSERT_TRUE(control.hasBridge);
  TEST_ASSERT_EQUAL_STRING("{\"type\":\"thinking\",\"seq\":42}", control.bridge.controlLine);

  TEST_ASSERT_TRUE(parseBenchControlLine("bridge response happy 42 hello i am awake", 4112, &control));
  TEST_ASSERT_TRUE(control.hasBridge);
  TEST_ASSERT_NOT_NULL(std::strstr(control.bridge.controlLine, "\"type\":\"response_start\""));
  TEST_ASSERT_NOT_NULL(std::strstr(control.bridge.controlLine, "\"intent\":\"happy\""));
  TEST_ASSERT_NOT_NULL(std::strstr(control.bridge.controlLine, "\"text\":\"hello i am awake\""));

  TEST_ASSERT_TRUE(parseBenchControlLine("bridge audio 0.70 ee 20 final", 4113, &control));
  TEST_ASSERT_TRUE(control.hasBridge);
  TEST_ASSERT_NOT_NULL(std::strstr(control.bridge.controlLine, "\"type\":\"audio\""));
  TEST_ASSERT_NOT_NULL(std::strstr(control.bridge.controlLine, "\"viseme\":\"ee\""));
  TEST_ASSERT_NOT_NULL(std::strstr(control.bridge.controlLine, "\"final\":true"));

  TEST_ASSERT_TRUE(parseBenchControlLine("bridge end 42", 4114, &control));
  TEST_ASSERT_EQUAL_STRING("{\"type\":\"response_end\",\"seq\":42}", control.bridge.controlLine);
}

void test_sensor_adapter_parses_audio_awareness_commands() {
  BenchControl control;
  TEST_ASSERT_TRUE(parseBenchControlLine("sound dir=-45 level=0.70", 4081, &control));
  TEST_ASSERT_TRUE(control.hasEvent);
  TEST_ASSERT_EQUAL(static_cast<int>(CharacterMode::Attend), static_cast<int>(control.mode));
  TEST_ASSERT_EQUAL(static_cast<int>(EventType::SoundDirection), static_cast<int>(control.event.type));
  TEST_ASSERT_TRUE(control.event.hasPayload);
  TEST_ASSERT_FLOAT_WITHIN(0.001f, -0.50f, control.event.x);
  TEST_ASSERT_FLOAT_WITHIN(0.001f, 0.70f, control.event.z);
  TEST_ASSERT_FLOAT_WITHIN(0.001f, 0.70f, control.event.strength);
  TEST_ASSERT_EQUAL_STRING("sound_direction", control.command);

  TEST_ASSERT_TRUE(parseBenchControlLine("sound 30 0.40", 4082, &control));
  TEST_ASSERT_EQUAL(static_cast<int>(EventType::SoundDirection), static_cast<int>(control.event.type));
  TEST_ASSERT_FLOAT_WITHIN(0.001f, 0.333f, control.event.x);
  TEST_ASSERT_FLOAT_WITHIN(0.001f, 0.40f, control.event.strength);

  TEST_ASSERT_TRUE(parseBenchControlLine("noise level=0.90", 4083, &control));
  TEST_ASSERT_EQUAL(static_cast<int>(CharacterMode::React), static_cast<int>(control.mode));
  TEST_ASSERT_EQUAL(static_cast<int>(EventType::LoudNoise), static_cast<int>(control.event.type));
  TEST_ASSERT_TRUE(control.event.hasPayload);
  TEST_ASSERT_FLOAT_WITHIN(0.001f, 0.90f, control.event.z);
  TEST_ASSERT_EQUAL_STRING("loud_noise", control.command);

  TEST_ASSERT_FALSE(parseBenchControlLine("sound level 0.50", 4084, &control));
}

void test_sensor_adapter_parses_physical_sense_commands() {
  BenchControl control;
  TEST_ASSERT_TRUE(parseBenchControlLine("touch cheek", 4090, &control));
  TEST_ASSERT_TRUE(control.hasEvent);
  TEST_ASSERT_EQUAL(static_cast<int>(CharacterMode::React), static_cast<int>(control.mode));
  TEST_ASSERT_EQUAL(static_cast<int>(EventType::UserTouched), static_cast<int>(control.event.type));
  TEST_ASSERT_TRUE(control.event.hasPayload);
  TEST_ASSERT_FLOAT_WITHIN(0.001f, 0.55f, control.event.x);
  TEST_ASSERT_FLOAT_WITHIN(0.001f, 0.55f, control.event.y);
  TEST_ASSERT_EQUAL_STRING("touch_payload", control.command);

  TEST_ASSERT_TRUE(parseBenchControlLine("touch forehead", 4100, &control));
  TEST_ASSERT_TRUE(control.event.hasPayload);
  TEST_ASSERT_FLOAT_WITHIN(0.001f, -0.75f, control.event.y);

  TEST_ASSERT_TRUE(parseBenchControlLine("touch 0.25 -0.60 0.75", 4110, &control));
  TEST_ASSERT_TRUE(control.event.hasPayload);
  TEST_ASSERT_FLOAT_WITHIN(0.001f, 0.25f, control.event.x);
  TEST_ASSERT_FLOAT_WITHIN(0.001f, -0.60f, control.event.y);
  TEST_ASSERT_FLOAT_WITHIN(0.001f, 0.75f, control.event.strength);

  TEST_ASSERT_TRUE(parseBenchControlLine("proximity 0.85", 4120, &control));
  TEST_ASSERT_EQUAL(static_cast<int>(CharacterMode::Attend), static_cast<int>(control.mode));
  TEST_ASSERT_EQUAL(static_cast<int>(EventType::UserNear), static_cast<int>(control.event.type));
  TEST_ASSERT_TRUE(control.event.hasPayload);
  TEST_ASSERT_FLOAT_WITHIN(0.001f, 0.85f, control.event.z);
  TEST_ASSERT_EQUAL_STRING("proximity_near", control.command);

  TEST_ASSERT_TRUE(parseBenchControlLine("pickup 0.80", 4130, &control));
  TEST_ASSERT_EQUAL(static_cast<int>(EventType::PickedUp), static_cast<int>(control.event.type));
  TEST_ASSERT_FLOAT_WITHIN(0.001f, 0.80f, control.event.strength);
  TEST_ASSERT_EQUAL_STRING("event_picked_up", control.command);

  TEST_ASSERT_TRUE(parseBenchControlLine("shake 1.0", 4140, &control));
  TEST_ASSERT_EQUAL(static_cast<int>(CharacterMode::Error), static_cast<int>(control.mode));
  TEST_ASSERT_EQUAL(static_cast<int>(EventType::Shaken), static_cast<int>(control.event.type));
  TEST_ASSERT_TRUE(control.hasMotionEnable);
  TEST_ASSERT_FALSE(control.motionEnabled);
  TEST_ASSERT_EQUAL_STRING("event_shaken_hold", control.command);

  TEST_ASSERT_TRUE(parseBenchControlLine("putdown", 4150, &control));
  TEST_ASSERT_EQUAL(static_cast<int>(EventType::PutDown), static_cast<int>(control.event.type));
  TEST_ASSERT_TRUE(control.hasMotionEnable);
  TEST_ASSERT_TRUE(control.motionEnabled);
  TEST_ASSERT_EQUAL_STRING("event_put_down_resume", control.command);

  TEST_ASSERT_TRUE(parseBenchControlLine("tilt x=0.40 y=-0.20 z=0.90", 4160, &control));
  TEST_ASSERT_EQUAL(static_cast<int>(EventType::Tilted), static_cast<int>(control.event.type));
  TEST_ASSERT_TRUE(control.event.hasPayload);
  TEST_ASSERT_FLOAT_WITHIN(0.001f, 0.40f, control.event.x);
  TEST_ASSERT_FLOAT_WITHIN(0.001f, -0.20f, control.event.y);
  TEST_ASSERT_FLOAT_WITHIN(0.001f, 0.90f, control.event.z);

  TEST_ASSERT_FALSE(parseBenchControlLine("tilt x 0.1 y banana z 0.2", 4170, &control));
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

void test_sensor_adapter_parses_motion_stop_commands() {
  BenchControl control;
  TEST_ASSERT_TRUE(parseBenchControlLine("motion stop", 4500, &control));
  TEST_ASSERT_FALSE(control.hasEvent);
  TEST_ASSERT_FALSE(control.hasSpeech);
  TEST_ASSERT_FALSE(control.hasReducedMotion);
  TEST_ASSERT_TRUE(control.hasMotionEnable);
  TEST_ASSERT_FALSE(control.motionEnabled);
  TEST_ASSERT_EQUAL_STRING("motion_stop", control.command);

  TEST_ASSERT_TRUE(parseBenchControlLine("servos on", 4600, &control));
  TEST_ASSERT_TRUE(control.hasMotionEnable);
  TEST_ASSERT_TRUE(control.motionEnabled);
  TEST_ASSERT_EQUAL_STRING("motion_resume", control.command);

  TEST_ASSERT_TRUE(parseBenchControlLine("halt", 4700, &control));
  TEST_ASSERT_TRUE(control.hasMotionEnable);
  TEST_ASSERT_FALSE(control.motionEnabled);
  TEST_ASSERT_EQUAL_STRING("motion_stop", control.command);

  TEST_ASSERT_FALSE(parseBenchControlLine("motion maybe", 4800, &control));
}

void test_sensor_adapter_parses_demo_enable_commands() {
  BenchControl control;
  TEST_ASSERT_TRUE(parseBenchControlLine("demo off", 4900, &control));
  TEST_ASSERT_FALSE(control.hasEvent);
  TEST_ASSERT_FALSE(control.hasSpeech);
  TEST_ASSERT_FALSE(control.hasReducedMotion);
  TEST_ASSERT_FALSE(control.hasMotionEnable);
  TEST_ASSERT_TRUE(control.hasDemoEnable);
  TEST_ASSERT_FALSE(control.demoEnabled);
  TEST_ASSERT_EQUAL_STRING("demo_off", control.command);

  TEST_ASSERT_TRUE(parseBenchControlLine("demo resume", 5000, &control));
  TEST_ASSERT_TRUE(control.hasDemoEnable);
  TEST_ASSERT_TRUE(control.demoEnabled);
  TEST_ASSERT_EQUAL_STRING("demo_on", control.command);

  TEST_ASSERT_FALSE(parseBenchControlLine("demo banana", 5100, &control));
}

void test_sensor_adapter_parses_safe_stop_command() {
  BenchControl control;
  TEST_ASSERT_TRUE(parseBenchControlLine("safe stop", 5200, &control));
  TEST_ASSERT_FALSE(control.hasEvent);
  TEST_ASSERT_TRUE(control.hasSpeech);
  TEST_ASSERT_TRUE(control.speech.clear);
  TEST_ASSERT_TRUE(control.hasReducedMotion);
  TEST_ASSERT_TRUE(control.reducedMotion);
  TEST_ASSERT_TRUE(control.hasMotionEnable);
  TEST_ASSERT_FALSE(control.motionEnabled);
  TEST_ASSERT_TRUE(control.hasDemoEnable);
  TEST_ASSERT_FALSE(control.demoEnabled);
  TEST_ASSERT_EQUAL_STRING("safe_stop", control.command);

  TEST_ASSERT_TRUE(parseBenchControlLine("panic", 5300, &control));
  TEST_ASSERT_TRUE(control.hasMotionEnable);
  TEST_ASSERT_FALSE(control.motionEnabled);
  TEST_ASSERT_TRUE(control.hasDemoEnable);
  TEST_ASSERT_FALSE(control.demoEnabled);
  TEST_ASSERT_EQUAL_STRING("safe_stop", control.command);
}

void test_sensor_adapter_parses_safe_resume_command() {
  BenchControl control;
  TEST_ASSERT_TRUE(parseBenchControlLine("safe resume", 5400, &control));
  TEST_ASSERT_FALSE(control.hasEvent);
  TEST_ASSERT_TRUE(control.hasSpeech);
  TEST_ASSERT_TRUE(control.speech.clear);
  TEST_ASSERT_TRUE(control.hasReducedMotion);
  TEST_ASSERT_FALSE(control.reducedMotion);
  TEST_ASSERT_TRUE(control.hasMotionEnable);
  TEST_ASSERT_TRUE(control.motionEnabled);
  TEST_ASSERT_TRUE(control.hasDemoEnable);
  TEST_ASSERT_TRUE(control.demoEnabled);
  TEST_ASSERT_EQUAL_STRING("safe_resume", control.command);

  TEST_ASSERT_TRUE(parseBenchControlLine("restore", 5500, &control));
  TEST_ASSERT_TRUE(control.hasReducedMotion);
  TEST_ASSERT_FALSE(control.reducedMotion);
  TEST_ASSERT_TRUE(control.hasMotionEnable);
  TEST_ASSERT_TRUE(control.motionEnabled);
  TEST_ASSERT_TRUE(control.hasDemoEnable);
  TEST_ASSERT_TRUE(control.demoEnabled);
  TEST_ASSERT_EQUAL_STRING("safe_resume", control.command);
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

void test_actuation_disable_stops_and_suppresses_writes_until_resumed() {
  RobotConfig config;
  FakeActuator actuator;
  ActuationEngine engine(config);
  engine.begin(&actuator);
  TEST_ASSERT_TRUE(engine.isEnabled());

  RobotFrame target = makeNeutralFrame();
  target.motion.yawMode = YawMode::Angle;
  target.motion.pitchDeg = 8.0f;
  target.motion.yawDeg = 12.0f;

  engine.setEnabled(false);
  TEST_ASSERT_FALSE(engine.isEnabled());
  engine.update(target, 10000);
  TEST_ASSERT_TRUE(actuator.stopped);
  TEST_ASSERT_EQUAL(0, actuator.pitchWrites);
  TEST_ASSERT_EQUAL(0, actuator.yawAngleWrites);
  TEST_ASSERT_EQUAL(0, actuator.yawVelocityWrites);

  engine.setEnabled(true);
  TEST_ASSERT_TRUE(engine.isEnabled());
  engine.update(target, 20000);
  TEST_ASSERT_GREATER_THAN(0, actuator.pitchWrites);
  TEST_ASSERT_GREATER_THAN(0, actuator.yawAngleWrites);
}

void test_stackchan_servo_stop_returns_tracked_axes_to_neutral() {
  StackChanServoAdapter adapter;
  TEST_ASSERT_TRUE(adapter.begin());

  adapter.writePitchDeg(9.0f);
  adapter.writeYawAngleDeg(-18.0f);
  TEST_ASSERT_FLOAT_WITHIN(0.001f, 9.0f, adapter.lastPitchDeg());
  TEST_ASSERT_FLOAT_WITHIN(0.001f, -18.0f, adapter.lastYawDeg());

  adapter.stop();
  TEST_ASSERT_FLOAT_WITHIN(0.001f, 0.0f, adapter.lastPitchDeg());
  TEST_ASSERT_FLOAT_WITHIN(0.001f, 0.0f, adapter.lastYawDeg());
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

void test_earcon_synth_renders_each_typed_cue() {
  int16_t buffer[6400] = {};
  const SpeechEarcon earcons[] = {
      SpeechEarcon::Wake,
      SpeechEarcon::Confirm,
      SpeechEarcon::Think,
      SpeechEarcon::Happy,
      SpeechEarcon::Concern,
      SpeechEarcon::Sleep,
      SpeechEarcon::Error,
      SpeechEarcon::Safety,
  };

  for (SpeechEarcon earcon : earcons) {
    const EarconRenderResult result = EarconSynth::render(earcon, buffer, 6400);
    TEST_ASSERT_FALSE(result.truncated);
    TEST_ASSERT_GREATER_THAN_UINT32(500, result.samplesWritten);
    TEST_ASSERT_GREATER_THAN_INT16(2000, result.peakAbs);
    TEST_ASSERT_EQUAL_UINT16(EarconSynth::expectedDurationMs(earcon), result.durationMs);
    TEST_ASSERT_NOT_EQUAL_UINT32(2166136261u, result.checksum);
  }
}

void test_earcon_synth_is_deterministic_and_respects_intensity() {
  int16_t fullA[6400] = {};
  int16_t fullB[6400] = {};
  int16_t quiet[6400] = {};

  const EarconRenderResult a = EarconSynth::render(SpeechEarcon::Happy, fullA, 6400);
  const EarconRenderResult b = EarconSynth::render(SpeechEarcon::Happy, fullB, 6400);

  EarconRenderConfig quietConfig;
  quietConfig.intensity = 0.35f;
  const EarconRenderResult q = EarconSynth::render(SpeechEarcon::Happy, quiet, 6400, quietConfig);

  TEST_ASSERT_EQUAL_UINT32(a.samplesWritten, b.samplesWritten);
  TEST_ASSERT_EQUAL_UINT32(a.checksum, b.checksum);
  TEST_ASSERT_EQUAL_INT16(a.peakAbs, b.peakAbs);
  TEST_ASSERT_LESS_THAN_INT16(a.peakAbs, q.peakAbs);
  TEST_ASSERT_EQUAL_UINT32(a.samplesWritten, q.samplesWritten);
}

void test_earcon_synth_reports_truncation_without_allocation() {
  int16_t small[32] = {};
  const EarconRenderResult result = EarconSynth::render(SpeechEarcon::Safety, small, 32);

  TEST_ASSERT_TRUE(result.truncated);
  TEST_ASSERT_EQUAL_UINT32(32, result.samplesWritten);
  TEST_ASSERT_GREATER_THAN_INT16(0, result.peakAbs);
}

void test_speech_adapter_prepares_packaged_prompt_and_earcon() {
  SpeechAdapter adapter;
  TEST_ASSERT_TRUE(adapter.begin(false));

  SpeechCue cue;
  cue.intent = SpeechIntent::Boot;
  cue.text = "Hello. I am Stackchan, and I am awake.";
  cue.priority = 220;
  cue.earcon = SpeechEarcon::Wake;
  cue.earconDelayMs = 40;

  EmotionalProfile emotion;
  emotion.arousal = 0.45f;
  TEST_ASSERT_TRUE(adapter.handleCue(cue, 7, emotion, 1234));

  const SpeechPlaybackPlan& plan = adapter.lastPlan();
  TEST_ASSERT_EQUAL_UINT32(7, plan.seq);
  TEST_ASSERT_EQUAL(static_cast<int>(PromptSource::PackagedPrompt), static_cast<int>(plan.promptSource));
  TEST_ASSERT_EQUAL_STRING("boot_awake", plan.promptId);
  TEST_ASSERT_EQUAL_STRING("media/voice/stackchan_spark_greeting.wav", plan.promptWavPath);
  TEST_ASSERT_EQUAL_STRING("media/voice/sidecars/stackchan_spark_greeting.speech_envelope.json", plan.promptSidecarPath);
  TEST_ASSERT_EQUAL_STRING(cue.text, plan.promptText);
  TEST_ASSERT_TRUE(plan.hasPrompt);
  TEST_ASSERT_TRUE(plan.hasEarcon);
  TEST_ASSERT_EQUAL_UINT16(40, plan.earconDelayMs);
  TEST_ASSERT_GREATER_THAN_UINT32(500, plan.earconRender.samplesWritten);
  TEST_ASSERT_GREATER_THAN_INT16(2000, plan.earconRender.peakAbs);
  TEST_ASSERT_EQUAL_UINT32(1, adapter.telemetry().cuesQueued);
  TEST_ASSERT_EQUAL_UINT32(1, adapter.telemetry().earconsRendered);
}

void test_speech_prompt_bank_covers_all_spoken_intents_with_sidecars() {
  const SpeechIntent intents[] = {
      SpeechIntent::Boot,
      SpeechIntent::Idle,
      SpeechIntent::Attend,
      SpeechIntent::Listen,
      SpeechIntent::Think,
      SpeechIntent::Speak,
      SpeechIntent::React,
      SpeechIntent::Happy,
      SpeechIntent::Concern,
      SpeechIntent::Sleep,
      SpeechIntent::Error,
      SpeechIntent::Safety,
  };

  for (SpeechIntent intent : intents) {
    const SpeechPromptAsset& asset = SpeechPromptBank::find(intent);
    TEST_ASSERT_EQUAL(static_cast<int>(PromptSource::PackagedPrompt), static_cast<int>(asset.source));
    TEST_ASSERT_NOT_NULL(asset.id);
    TEST_ASSERT_NOT_NULL(asset.wavPath);
    TEST_ASSERT_NOT_NULL(asset.sidecarPath);
    TEST_ASSERT_TRUE(asset.id[0] != '\0');
    TEST_ASSERT_TRUE(asset.wavPath[0] != '\0');
    TEST_ASSERT_TRUE(asset.sidecarPath[0] != '\0');
  }

  size_t count = 0;
  const SpeechPromptAsset* assets = SpeechPromptBank::assets(count);
  TEST_ASSERT_NOT_NULL(assets);
  TEST_ASSERT_EQUAL_UINT32(sizeof(intents) / sizeof(intents[0]), count);
  TEST_ASSERT_EQUAL_STRING("spark", generated_persona::kPromptAssetsPersonaId);
  TEST_ASSERT_EQUAL_UINT32(count, generated_persona::kPromptAssetCount);
}

void test_audio_out_accepts_packaged_prompt_requests() {
  AudioOut audio;
  TEST_ASSERT_TRUE(audio.begin(false));

  AudioOutPlaybackRequest request;
  request.seq = 42;
  request.queuedAtMs = 1234;
  request.source = AudioOutSource::PackagedPrompt;
  request.promptId = "boot_awake";
  request.wavPath = "media/voice/stackchan_spark_greeting.wav";
  request.sidecarPath = "media/voice/sidecars/stackchan_spark_greeting.speech_envelope.json";
  request.earconSamples = 1440;
  request.hasPrompt = true;
  request.hasEarcon = true;

  TEST_ASSERT_TRUE(audio.enqueue(request));
  TEST_ASSERT_EQUAL_UINT32(1, audio.telemetry().requestsQueued);
  TEST_ASSERT_EQUAL_UINT32(0, audio.telemetry().requestsDropped);
  TEST_ASSERT_EQUAL_UINT32(42, audio.telemetry().lastSeq);
  TEST_ASSERT_EQUAL(static_cast<int>(AudioOutSource::PackagedPrompt), static_cast<int>(audio.telemetry().lastSource));
  TEST_ASSERT_EQUAL_STRING("boot_awake", audio.lastRequest().promptId);
  TEST_ASSERT_EQUAL_STRING(request.wavPath, audio.telemetry().lastWavPath);
  TEST_ASSERT_EQUAL_STRING(request.sidecarPath, audio.telemetry().lastSidecarPath);
  TEST_ASSERT_TRUE(audio.lastRequest().duckOnBargeIn);
}

void test_audio_out_streams_packaged_sidecar_mouth_frames() {
  AudioOut audio;
  TEST_ASSERT_TRUE(audio.begin(false));

  AudioOutPlaybackRequest request;
  request.seq = 43;
  request.queuedAtMs = 1000;
  request.source = AudioOutSource::PackagedPrompt;
  request.promptId = "think_processing";
  request.wavPath = "media/voice/stackchan_spark_thinking.wav";
  request.sidecarPath = "media/voice/sidecars/stackchan_spark_thinking.speech_envelope.json";
  request.earconDelayMs = 80;
  request.promptChars = 56;
  request.hasPrompt = true;

  TEST_ASSERT_TRUE(audio.enqueue(request));
  TEST_ASSERT_TRUE(audio.telemetry().playbackActive);
  TEST_ASSERT_EQUAL_UINT16(421, audio.telemetry().sidecarFrames);
  TEST_ASSERT_EQUAL_UINT16(20, audio.telemetry().sidecarFrameMs);
  TEST_ASSERT_EQUAL_UINT32(8414, audio.telemetry().playbackDurationMs);

  AudioOutSpeechFrame frame;
  TEST_ASSERT_FALSE(audio.pollSpeechFrame(1070, &frame));
  TEST_ASSERT_TRUE(audio.pollSpeechFrame(1080, &frame));
  TEST_ASSERT_TRUE(frame.active);
  TEST_ASSERT_FALSE(frame.clear);
  TEST_ASSERT_EQUAL_UINT32(43, frame.seq);
  TEST_ASSERT_GREATER_THAN_FLOAT(0.0f, frame.envelope);
  TEST_ASSERT_NOT_EQUAL(static_cast<int>(AudioOutViseme::Neutral), static_cast<int>(frame.viseme));
  TEST_ASSERT_EQUAL_UINT32(1, audio.telemetry().speechFramesEmitted);

  TEST_ASSERT_FALSE(audio.pollSpeechFrame(1089, &frame));
  TEST_ASSERT_TRUE(audio.pollSpeechFrame(1100, &frame));
  TEST_ASSERT_EQUAL_UINT32(2, audio.telemetry().speechFramesEmitted);

  TEST_ASSERT_TRUE(audio.pollSpeechFrame(9500, &frame));
  TEST_ASSERT_TRUE(frame.clear);
  TEST_ASSERT_FALSE(frame.active);
  TEST_ASSERT_FALSE(audio.telemetry().playbackActive);
  TEST_ASSERT_EQUAL_UINT32(1, audio.telemetry().playbackCompleted);
}

void test_audio_out_ducks_active_playback_for_barge_in() {
  AudioOut audio;
  TEST_ASSERT_TRUE(audio.begin(false));

  AudioOutPlaybackRequest request;
  request.seq = 44;
  request.queuedAtMs = 2000;
  request.source = AudioOutSource::PackagedPrompt;
  request.promptId = "boot_awake";
  request.wavPath = "media/voice/stackchan_spark_greeting.wav";
  request.sidecarPath = "media/voice/sidecars/stackchan_spark_greeting.speech_envelope.json";
  request.hasPrompt = true;
  request.duckOnBargeIn = true;

  TEST_ASSERT_TRUE(audio.enqueue(request));
  AudioOutSpeechFrame frame;
  TEST_ASSERT_TRUE(audio.pollSpeechFrame(2040, &frame));
  const float normalEnvelope = frame.envelope;
  TEST_ASSERT_GREATER_THAN_FLOAT(0.05f, normalEnvelope);

  TEST_ASSERT_TRUE(audio.duck(2060));
  TEST_ASSERT_TRUE(audio.telemetry().duckActive);
  TEST_ASSERT_EQUAL_UINT32(1, audio.telemetry().duckEvents);
  TEST_ASSERT_TRUE(audio.pollSpeechFrame(2060, &frame));
  TEST_ASSERT_LESS_THAN_FLOAT(normalEnvelope, frame.envelope);
}

class CountingAudioOutSink : public AudioOutSpeakerSink {
 public:
  bool begin() override {
    beginCalls++;
    ready = true;
    return true;
  }

  bool start(const AudioOutPlaybackRequest& request, uint32_t promptStartMs, uint32_t durationMs) override {
    startCalls++;
    active = true;
    lastSeq = request.seq;
    lastPromptStartMs = promptStartMs;
    lastDurationMs = durationMs;
    lastPromptId = request.promptId;
    return true;
  }

  bool writeFrame(const AudioOutHardwareFrame& frame) override {
    frameCalls++;
    lastFrame = frame;
    return frameWriteResult;
  }

  void stop() override {
    stopCalls++;
    active = false;
  }

  bool isReady() const override {
    return ready;
  }

  bool ready = false;
  bool active = false;
  bool frameWriteResult = true;
  uint32_t beginCalls = 0;
  uint32_t startCalls = 0;
  uint32_t frameCalls = 0;
  uint32_t stopCalls = 0;
  uint32_t lastSeq = 0;
  uint32_t lastPromptStartMs = 0;
  uint32_t lastDurationMs = 0;
  const char* lastPromptId = "";
  AudioOutHardwareFrame lastFrame;
};

void test_audio_out_feeds_enabled_hardware_speaker_sink() {
  CountingAudioOutSink sink;
  AudioOut audio;
  TEST_ASSERT_TRUE(audio.begin(true, &sink));
  TEST_ASSERT_TRUE(audio.telemetry().hardwareEnabled);
  TEST_ASSERT_TRUE(audio.telemetry().hardwareReady);
  TEST_ASSERT_EQUAL_UINT32(1, sink.beginCalls);

  AudioOutPlaybackRequest request;
  request.seq = 45;
  request.queuedAtMs = 3000;
  request.source = AudioOutSource::PackagedPrompt;
  request.promptId = "boot_awake";
  request.wavPath = "media/voice/stackchan_spark_greeting.wav";
  request.sidecarPath = "media/voice/sidecars/stackchan_spark_greeting.speech_envelope.json";
  request.earconDelayMs = 40;
  request.hasPrompt = true;

  TEST_ASSERT_TRUE(audio.enqueue(request));
  TEST_ASSERT_TRUE(audio.telemetry().hardwarePlaybackActive);
  TEST_ASSERT_EQUAL_UINT32(1, audio.telemetry().hardwareStarts);
  TEST_ASSERT_EQUAL_UINT32(1, sink.startCalls);
  TEST_ASSERT_EQUAL_UINT32(45, sink.lastSeq);
  TEST_ASSERT_EQUAL_UINT32(3040, sink.lastPromptStartMs);
  TEST_ASSERT_EQUAL_UINT32(6313, sink.lastDurationMs);
  TEST_ASSERT_EQUAL_STRING("boot_awake", sink.lastPromptId);

  AudioOutSpeechFrame frame;
  TEST_ASSERT_TRUE(audio.pollSpeechFrame(3040, &frame));
  TEST_ASSERT_EQUAL_UINT32(1, sink.frameCalls);
  TEST_ASSERT_EQUAL_UINT32(1, audio.telemetry().hardwareFramesSubmitted);
  TEST_ASSERT_EQUAL_UINT32(45, sink.lastFrame.seq);
  TEST_ASSERT_TRUE(sink.lastFrame.active);
  TEST_ASSERT_FALSE(sink.lastFrame.ducked);

  TEST_ASSERT_TRUE(audio.duck(3060));
  TEST_ASSERT_TRUE(audio.pollSpeechFrame(3060, &frame));
  TEST_ASSERT_EQUAL_UINT32(2, sink.frameCalls);
  TEST_ASSERT_TRUE(sink.lastFrame.ducked);

  TEST_ASSERT_TRUE(audio.pollSpeechFrame(9400, &frame));
  TEST_ASSERT_TRUE(frame.clear);
  TEST_ASSERT_FALSE(audio.telemetry().hardwarePlaybackActive);
  TEST_ASSERT_EQUAL_UINT32(1, audio.telemetry().hardwareStops);
  TEST_ASSERT_EQUAL_UINT32(1, sink.stopCalls);
}

void test_speech_adapter_queues_audio_out_request() {
  AudioOut audio;
  SpeechAdapter adapter;
  TEST_ASSERT_TRUE(audio.begin(false));
  TEST_ASSERT_TRUE(adapter.begin(false, &audio));

  SpeechCue cue;
  cue.intent = SpeechIntent::Think;
  cue.text = "Input received. I am thinking now.";
  cue.priority = 180;
  cue.earcon = SpeechEarcon::Think;
  cue.earconDelayMs = 90;

  EmotionalProfile emotion;
  emotion.arousal = 0.35f;
  TEST_ASSERT_TRUE(adapter.handleCue(cue, 9, emotion, 2468));

  const AudioOutPlaybackRequest& request = audio.lastRequest();
  TEST_ASSERT_EQUAL_UINT32(1, audio.telemetry().requestsQueued);
  TEST_ASSERT_EQUAL_UINT32(9, request.seq);
  TEST_ASSERT_EQUAL_UINT32(2468, request.queuedAtMs);
  TEST_ASSERT_EQUAL(static_cast<int>(AudioOutSource::PackagedPrompt), static_cast<int>(request.source));
  TEST_ASSERT_EQUAL_STRING("think_processing", request.promptId);
  TEST_ASSERT_EQUAL_STRING("media/voice/stackchan_spark_thinking.wav", request.wavPath);
  TEST_ASSERT_EQUAL_STRING("media/voice/sidecars/stackchan_spark_thinking.speech_envelope.json", request.sidecarPath);
  TEST_ASSERT_EQUAL_UINT16(90, request.earconDelayMs);
  TEST_ASSERT_TRUE(request.hasPrompt);
  TEST_ASSERT_TRUE(request.hasEarcon);
  TEST_ASSERT_GREATER_THAN_UINT32(500, request.earconSamples);
}

void test_speech_adapter_rejects_empty_or_uninitialized_cues() {
  SpeechAdapter adapter;
  SpeechCue cue;
  cue.intent = SpeechIntent::Think;
  cue.text = "Input received. I am thinking now.";
  cue.earcon = SpeechEarcon::Think;

  EmotionalProfile emotion;
  TEST_ASSERT_FALSE(adapter.handleCue(cue, 1, emotion, 100));
  TEST_ASSERT_TRUE(adapter.begin(false));
  TEST_ASSERT_FALSE(adapter.handleCue(cue, 0, emotion, 100));

  SpeechCue empty;
  TEST_ASSERT_FALSE(adapter.handleCue(empty, 2, emotion, 120));
  TEST_ASSERT_EQUAL_UINT32(0, adapter.telemetry().cuesQueued);
}

void test_speech_adapter_scales_earcon_with_arousal() {
  SpeechAdapter adapter;
  TEST_ASSERT_TRUE(adapter.begin(false));

  SpeechCue cue;
  cue.intent = SpeechIntent::Happy;
  cue.text = "Happy signal detected.";
  cue.earcon = SpeechEarcon::Happy;

  EmotionalProfile calm;
  calm.arousal = 0.10f;
  TEST_ASSERT_TRUE(adapter.handleCue(cue, 1, calm, 100));
  const int16_t calmPeak = adapter.lastPlan().earconRender.peakAbs;

  EmotionalProfile excited;
  excited.arousal = 0.95f;
  TEST_ASSERT_TRUE(adapter.handleCue(cue, 2, excited, 130));
  const int16_t excitedPeak = adapter.lastPlan().earconRender.peakAbs;

  TEST_ASSERT_GREATER_THAN_INT16(calmPeak, excitedPeak);
  TEST_ASSERT_EQUAL_UINT32(2, adapter.telemetry().cuesQueued);
  TEST_ASSERT_EQUAL_UINT32(2, adapter.telemetry().earconsRendered);
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

void test_bridge_client_accepts_session_hello() {
  BridgeClient bridge;
  TEST_ASSERT_TRUE(bridge.begin());
  bridge.markConnecting(100);
  TEST_ASSERT_EQUAL(static_cast<int>(BridgeClientState::Connecting), static_cast<int>(bridge.telemetry().state));

  TEST_ASSERT_TRUE(bridge.submitControlLine("{\"type\":\"hello\",\"session\":\"abc123\"}", 120));

  BridgeClientOutput output;
  TEST_ASSERT_TRUE(bridge.poll(&output));
  TEST_ASSERT_EQUAL(static_cast<int>(BridgeClientOutputType::SessionReady), static_cast<int>(output.type));
  TEST_ASSERT_EQUAL_STRING("abc123", output.sessionId);
  TEST_ASSERT_EQUAL(static_cast<int>(BridgeClientState::Ready), static_cast<int>(bridge.telemetry().state));
  TEST_ASSERT_EQUAL_UINT32(1, bridge.telemetry().inboundMessages);
  TEST_ASSERT_EQUAL_UINT32(1, bridge.telemetry().outputsQueued);
}

void test_bridge_client_maps_thinking_and_response_events() {
  BridgeClient bridge;
  TEST_ASSERT_TRUE(bridge.begin());

  TEST_ASSERT_TRUE(bridge.submitControlLine("{\"type\":\"thinking\",\"seq\":41}", 200));
  BridgeClientOutput output;
  TEST_ASSERT_TRUE(bridge.poll(&output));
  TEST_ASSERT_EQUAL(static_cast<int>(BridgeClientOutputType::Event), static_cast<int>(output.type));
  TEST_ASSERT_EQUAL(static_cast<int>(EventType::ThinkingStarted), static_cast<int>(output.event.type));
  TEST_ASSERT_EQUAL_UINT32(200, output.event.timestampMs);
  TEST_ASSERT_EQUAL(static_cast<int>(BridgeClientState::Thinking), static_cast<int>(bridge.telemetry().state));

  TEST_ASSERT_TRUE(bridge.submitControlLine(
      "{\"type\":\"response_start\",\"seq\":41,\"intent\":\"happy\",\"arousal\":0.62,\"valence\":0.72,"
      "\"text\":\"Hello. I am awake.\"}",
      260));
  TEST_ASSERT_TRUE(bridge.poll(&output));
  TEST_ASSERT_EQUAL(static_cast<int>(BridgeClientOutputType::ResponseStart), static_cast<int>(output.type));
  TEST_ASSERT_EQUAL(static_cast<int>(EventType::ResponseStarted), static_cast<int>(output.event.type));
  TEST_ASSERT_EQUAL_UINT32(41, output.response.seq);
  TEST_ASSERT_EQUAL(static_cast<int>(SpeechIntent::Happy), static_cast<int>(output.response.intent));
  TEST_ASSERT_FLOAT_WITHIN(0.001f, 0.62f, output.response.arousal);
  TEST_ASSERT_FLOAT_WITHIN(0.001f, 0.72f, output.response.valence);
  TEST_ASSERT_EQUAL_STRING("Hello. I am awake.", output.response.text);
  TEST_ASSERT_EQUAL(static_cast<int>(BridgeClientState::Responding), static_cast<int>(bridge.telemetry().state));

  TEST_ASSERT_TRUE(bridge.submitControlLine("{\"type\":\"response_end\",\"seq\":41}", 420));
  TEST_ASSERT_TRUE(bridge.poll(&output));
  TEST_ASSERT_EQUAL(static_cast<int>(BridgeClientOutputType::ResponseEnd), static_cast<int>(output.type));
  TEST_ASSERT_EQUAL(static_cast<int>(EventType::ResponseEnded), static_cast<int>(output.event.type));
  TEST_ASSERT_EQUAL(static_cast<int>(BridgeClientState::Ready), static_cast<int>(bridge.telemetry().state));
}

void test_bridge_client_accepts_all_character_lock_intents() {
  struct IntentCase {
    const char* token;
    SpeechIntent intent;
  };
  const IntentCase cases[] = {
      {"boot", SpeechIntent::Boot},
      {"idle", SpeechIntent::Idle},
      {"attend", SpeechIntent::Attend},
      {"listen", SpeechIntent::Listen},
      {"think", SpeechIntent::Think},
      {"speak", SpeechIntent::Speak},
      {"react", SpeechIntent::React},
      {"happy", SpeechIntent::Happy},
      {"concern", SpeechIntent::Concern},
      {"sleep", SpeechIntent::Sleep},
      {"error", SpeechIntent::Error},
      {"safety", SpeechIntent::Safety},
  };

  for (size_t i = 0; i < sizeof(cases) / sizeof(cases[0]); ++i) {
    BridgeClient bridge;
    TEST_ASSERT_TRUE(bridge.begin());

    char line[160] = {};
    std::snprintf(line,
                  sizeof(line),
                  "{\"type\":\"response_start\",\"seq\":%u,\"intent\":\"%s\",\"text\":\"test\"}",
                  static_cast<unsigned>(i + 1),
                  cases[i].token);
    TEST_ASSERT_TRUE(bridge.submitControlLine(line, 300 + static_cast<uint32_t>(i)));

    BridgeClientOutput output;
    TEST_ASSERT_TRUE(bridge.poll(&output));
    TEST_ASSERT_EQUAL(static_cast<int>(BridgeClientOutputType::ResponseStart), static_cast<int>(output.type));
    TEST_ASSERT_EQUAL(static_cast<int>(cases[i].intent), static_cast<int>(output.response.intent));
  }
}

void test_serial_bridge_response_preserves_attend_intent() {
  BenchControl control;
  TEST_ASSERT_TRUE(parseBenchControlLine("bridge response attend 9 Looking at you now.", 4250, &control));
  TEST_ASSERT_TRUE(control.hasBridge);

  BridgeClient bridge;
  TEST_ASSERT_TRUE(bridge.begin());
  TEST_ASSERT_TRUE(bridge.submitControlLine(control.bridge.controlLine, 4251));

  BridgeClientOutput output;
  TEST_ASSERT_TRUE(bridge.poll(&output));
  TEST_ASSERT_EQUAL(static_cast<int>(BridgeClientOutputType::ResponseStart), static_cast<int>(output.type));
  TEST_ASSERT_EQUAL(static_cast<int>(SpeechIntent::Attend), static_cast<int>(output.response.intent));
  TEST_ASSERT_EQUAL_STRING("looking at you now.", output.response.text);
}

void test_bridge_client_parses_audio_frames_for_mouth_sync() {
  BridgeClient bridge;
  TEST_ASSERT_TRUE(bridge.begin());

  TEST_ASSERT_TRUE(
      bridge.submitControlLine("{\"type\":\"audio\",\"seq\":7,\"env\":1.25,\"viseme\":\"ee\",\"duration_ms\":240,"
                               "\"final\":true}",
                               500));

  BridgeClientOutput output;
  TEST_ASSERT_TRUE(bridge.poll(&output));
  TEST_ASSERT_EQUAL(static_cast<int>(BridgeClientOutputType::AudioFrame), static_cast<int>(output.type));
  TEST_ASSERT_EQUAL_UINT32(7, output.audio.seq);
  TEST_ASSERT_FLOAT_WITHIN(0.001f, 1.0f, output.audio.envelope);
  TEST_ASSERT_EQUAL(static_cast<int>(AudioOutViseme::Ee), static_cast<int>(output.audio.viseme));
  TEST_ASSERT_EQUAL_UINT16(200, output.audio.durationMs);
  TEST_ASSERT_TRUE(output.audio.finalChunk);
}

void test_bridge_client_parses_audio_stream_metadata() {
  BridgeClient bridge;
  TEST_ASSERT_TRUE(bridge.begin());

  TEST_ASSERT_TRUE(bridge.submitControlLine(
      "{\"type\":\"audio_stream_start\",\"seq\":12,\"format\":\"wav\",\"sample_rate\":22050,"
      "\"audio_bytes\":7,\"chunk_bytes\":3,\"chunks\":3}",
      520));

  BridgeClientOutput output;
  TEST_ASSERT_TRUE(bridge.poll(&output));
  TEST_ASSERT_EQUAL(static_cast<int>(BridgeClientOutputType::AudioStreamStart), static_cast<int>(output.type));
  TEST_ASSERT_EQUAL_UINT32(12, output.stream.seq);
  TEST_ASSERT_EQUAL_STRING("wav", output.stream.format);
  TEST_ASSERT_EQUAL_UINT32(22050, output.stream.sampleRate);
  TEST_ASSERT_EQUAL_UINT32(7, output.stream.audioBytes);
  TEST_ASSERT_EQUAL_UINT32(3, output.stream.chunkBytes);
  TEST_ASSERT_EQUAL_UINT32(3, output.stream.chunks);
  TEST_ASSERT_EQUAL_UINT32(1, bridge.telemetry().audioStreamsStarted);
  TEST_ASSERT_EQUAL_UINT32(7, bridge.telemetry().audioStreamBytes);
  TEST_ASSERT_EQUAL_UINT32(3, bridge.telemetry().audioStreamChunksExpected);
  TEST_ASSERT_TRUE(bridge.telemetry().audioStreamActive);
  TEST_ASSERT_EQUAL(static_cast<int>(BridgeClientState::Responding), static_cast<int>(bridge.telemetry().state));

  const uint8_t chunk0[] = {1, 2, 3};
  const uint8_t chunk1[] = {4, 5, 6};
  const uint8_t chunk2[] = {7};

  TEST_ASSERT_TRUE(bridge.submitBinaryFrame(chunk0, sizeof(chunk0), 525));
  TEST_ASSERT_TRUE(bridge.poll(&output));
  TEST_ASSERT_EQUAL(static_cast<int>(BridgeClientOutputType::AudioStreamChunk), static_cast<int>(output.type));
  TEST_ASSERT_EQUAL_UINT32(12, output.streamChunk.seq);
  TEST_ASSERT_EQUAL_UINT32(1, output.streamChunk.index);
  TEST_ASSERT_EQUAL_UINT32(3, output.streamChunk.bytes);
  TEST_ASSERT_EQUAL_UINT32(3, output.streamChunk.payloadBytes);
  TEST_ASSERT_NOT_NULL(output.streamChunk.payload);
  TEST_ASSERT_EQUAL_UINT8(1, output.streamChunk.payload[0]);
  TEST_ASSERT_EQUAL_UINT8(2, output.streamChunk.payload[1]);
  TEST_ASSERT_EQUAL_UINT8(3, output.streamChunk.payload[2]);
  TEST_ASSERT_EQUAL_UINT32(3, output.streamChunk.receivedBytes);
  TEST_ASSERT_FALSE(output.streamChunk.finalChunk);

  TEST_ASSERT_TRUE(bridge.submitBinaryFrame(chunk1, sizeof(chunk1), 530));
  TEST_ASSERT_TRUE(bridge.poll(&output));
  TEST_ASSERT_EQUAL(static_cast<int>(BridgeClientOutputType::AudioStreamChunk), static_cast<int>(output.type));
  TEST_ASSERT_EQUAL_UINT32(2, output.streamChunk.index);
  TEST_ASSERT_EQUAL_UINT32(6, output.streamChunk.receivedBytes);
  TEST_ASSERT_FALSE(output.streamChunk.finalChunk);

  TEST_ASSERT_TRUE(bridge.submitBinaryFrame(chunk2, sizeof(chunk2), 535));
  TEST_ASSERT_TRUE(bridge.poll(&output));
  TEST_ASSERT_EQUAL(static_cast<int>(BridgeClientOutputType::AudioStreamChunk), static_cast<int>(output.type));
  TEST_ASSERT_EQUAL_UINT32(3, output.streamChunk.index);
  TEST_ASSERT_EQUAL_UINT32(1, output.streamChunk.bytes);
  TEST_ASSERT_EQUAL_UINT32(1, output.streamChunk.payloadBytes);
  TEST_ASSERT_NOT_NULL(output.streamChunk.payload);
  TEST_ASSERT_EQUAL_UINT8(7, output.streamChunk.payload[0]);
  TEST_ASSERT_EQUAL_UINT32(7, output.streamChunk.receivedBytes);
  TEST_ASSERT_TRUE(output.streamChunk.finalChunk);
  TEST_ASSERT_GREATER_THAN_UINT32(0, output.streamChunk.checksum);
  TEST_ASSERT_EQUAL_UINT32(7, bridge.telemetry().audioStreamBytesReceived);
  TEST_ASSERT_EQUAL_UINT32(3, bridge.telemetry().audioStreamChunksReceived);

  TEST_ASSERT_TRUE(bridge.submitControlLine(
      "{\"type\":\"audio_stream_end\",\"seq\":12,\"audio_bytes\":7,\"chunks\":3}",
      540));

  TEST_ASSERT_TRUE(bridge.poll(&output));
  TEST_ASSERT_EQUAL(static_cast<int>(BridgeClientOutputType::AudioStreamEnd), static_cast<int>(output.type));
  TEST_ASSERT_EQUAL_UINT32(12, output.stream.seq);
  TEST_ASSERT_EQUAL_UINT32(7, output.stream.audioBytes);
  TEST_ASSERT_EQUAL_UINT32(3, output.stream.chunks);
  TEST_ASSERT_EQUAL_UINT32(1, bridge.telemetry().audioStreamsEnded);
  TEST_ASSERT_FALSE(bridge.telemetry().audioStreamActive);
  TEST_ASSERT_GREATER_THAN_UINT32(0, bridge.telemetry().audioStreamChecksum);
}

void test_bridge_client_rejects_binary_without_audio_stream() {
  BridgeClient bridge;
  TEST_ASSERT_TRUE(bridge.begin());

  const uint8_t chunk[] = {1, 2, 3};
  TEST_ASSERT_FALSE(bridge.submitBinaryFrame(chunk, sizeof(chunk), 600));

  BridgeClientOutput output;
  TEST_ASSERT_TRUE(bridge.poll(&output));
  TEST_ASSERT_EQUAL(static_cast<int>(BridgeClientOutputType::Error), static_cast<int>(output.type));
  TEST_ASSERT_EQUAL_STRING("binary_without_audio_stream", output.error);
  TEST_ASSERT_EQUAL_UINT32(1, bridge.telemetry().parseErrors);
  TEST_ASSERT_EQUAL_UINT32(1, bridge.telemetry().audioStreamErrors);
  TEST_ASSERT_EQUAL(static_cast<int>(BridgeClientState::Error), static_cast<int>(bridge.telemetry().state));
}

void test_bridge_client_rejects_truncated_audio_stream() {
  BridgeClient bridge;
  TEST_ASSERT_TRUE(bridge.begin());

  TEST_ASSERT_TRUE(bridge.submitControlLine(
      "{\"type\":\"audio_stream_start\",\"seq\":14,\"format\":\"wav\",\"sample_rate\":22050,"
      "\"audio_bytes\":7,\"chunk_bytes\":3,\"chunks\":3}",
      620));

  BridgeClientOutput output;
  TEST_ASSERT_TRUE(bridge.poll(&output));
  TEST_ASSERT_EQUAL(static_cast<int>(BridgeClientOutputType::AudioStreamStart), static_cast<int>(output.type));

  const uint8_t chunk[] = {1, 2, 3};
  TEST_ASSERT_TRUE(bridge.submitBinaryFrame(chunk, sizeof(chunk), 625));
  TEST_ASSERT_TRUE(bridge.poll(&output));
  TEST_ASSERT_EQUAL(static_cast<int>(BridgeClientOutputType::AudioStreamChunk), static_cast<int>(output.type));

  TEST_ASSERT_FALSE(bridge.submitControlLine(
      "{\"type\":\"audio_stream_end\",\"seq\":14,\"audio_bytes\":7,\"chunks\":3}",
      640));
  TEST_ASSERT_TRUE(bridge.poll(&output));
  TEST_ASSERT_EQUAL(static_cast<int>(BridgeClientOutputType::Error), static_cast<int>(output.type));
  TEST_ASSERT_EQUAL_STRING("audio_stream_payload_bytes_mismatch", output.error);
  TEST_ASSERT_EQUAL_UINT32(1, bridge.telemetry().parseErrors);
  TEST_ASSERT_EQUAL_UINT32(1, bridge.telemetry().audioStreamErrors);
  TEST_ASSERT_FALSE(bridge.telemetry().audioStreamActive);
}

void test_bridge_client_rejects_oversized_audio_stream_chunk() {
  BridgeClient bridge;
  TEST_ASSERT_TRUE(bridge.begin());

  TEST_ASSERT_FALSE(bridge.submitControlLine(
      "{\"type\":\"audio_stream_start\",\"seq\":15,\"format\":\"wav\",\"sample_rate\":22050,"
      "\"audio_bytes\":4097,\"chunk_bytes\":4097,\"chunks\":1}",
      642));

  BridgeClientOutput output;
  TEST_ASSERT_TRUE(bridge.poll(&output));
  TEST_ASSERT_EQUAL(static_cast<int>(BridgeClientOutputType::Error), static_cast<int>(output.type));
  TEST_ASSERT_EQUAL_STRING("audio_stream_chunk_too_large", output.error);
  TEST_ASSERT_FALSE(bridge.telemetry().audioStreamActive);

  TEST_ASSERT_TRUE(bridge.submitControlLine("{\"type\":\"hello\",\"session\":\"after-oversize-metadata\"}", 644));
  TEST_ASSERT_TRUE(bridge.poll(&output));
  TEST_ASSERT_EQUAL(static_cast<int>(BridgeClientOutputType::SessionReady), static_cast<int>(output.type));

  TEST_ASSERT_TRUE(bridge.submitControlLine(
      "{\"type\":\"audio_stream_start\",\"seq\":16,\"format\":\"wav\",\"sample_rate\":22050,"
      "\"audio_bytes\":4097,\"chunk_bytes\":4096,\"chunks\":1}",
      645));

  TEST_ASSERT_TRUE(bridge.poll(&output));
  TEST_ASSERT_EQUAL(static_cast<int>(BridgeClientOutputType::AudioStreamStart), static_cast<int>(output.type));

  uint8_t chunk[kBridgeAudioStreamChunkPayloadMax + 1] = {};
  TEST_ASSERT_FALSE(bridge.submitBinaryFrame(chunk, sizeof(chunk), 650));
  TEST_ASSERT_TRUE(bridge.poll(&output));
  TEST_ASSERT_EQUAL(static_cast<int>(BridgeClientOutputType::Error), static_cast<int>(output.type));
  TEST_ASSERT_EQUAL_STRING("audio_stream_chunk_too_large", output.error);
  TEST_ASSERT_EQUAL_UINT32(2, bridge.telemetry().parseErrors);
  TEST_ASSERT_EQUAL_UINT32(2, bridge.telemetry().audioStreamErrors);
  TEST_ASSERT_FALSE(bridge.telemetry().audioStreamActive);
}

void test_bridge_audio_downlink_consumes_bridge_payload_output() {
  BridgeClient bridge;
  TEST_ASSERT_TRUE(bridge.begin());
  BridgeAudioDownlink downlink;
  TEST_ASSERT_TRUE(downlink.begin());

  TEST_ASSERT_TRUE(bridge.submitControlLine(
      "{\"type\":\"audio_stream_start\",\"seq\":17,\"format\":\"wav\",\"sample_rate\":22050,"
      "\"audio_bytes\":4,\"chunk_bytes\":4,\"chunks\":1}",
      700));

  BridgeClientOutput output;
  TEST_ASSERT_TRUE(bridge.poll(&output));
  TEST_ASSERT_EQUAL(static_cast<int>(BridgeClientOutputType::AudioStreamStart), static_cast<int>(output.type));
  TEST_ASSERT_TRUE(downlink.start(output.stream, 700));

  const uint8_t chunk[] = {9, 8, 7, 6};
  TEST_ASSERT_TRUE(bridge.submitBinaryFrame(chunk, sizeof(chunk), 710));
  TEST_ASSERT_TRUE(bridge.poll(&output));
  TEST_ASSERT_EQUAL(static_cast<int>(BridgeClientOutputType::AudioStreamChunk), static_cast<int>(output.type));
  TEST_ASSERT_TRUE(downlink.submitChunk(output.streamChunk, 710));

  TEST_ASSERT_TRUE(bridge.submitControlLine("{\"type\":\"audio_stream_end\",\"seq\":17,\"audio_bytes\":4,\"chunks\":1}", 720));
  TEST_ASSERT_TRUE(bridge.poll(&output));
  TEST_ASSERT_EQUAL(static_cast<int>(BridgeClientOutputType::AudioStreamEnd), static_cast<int>(output.type));
  TEST_ASSERT_TRUE(downlink.end(output.stream, 720));

  const BridgeAudioDownlinkTelemetry& telemetry = downlink.telemetry();
  TEST_ASSERT_FALSE(telemetry.active);
  TEST_ASSERT_EQUAL_UINT32(1, telemetry.streamsStarted);
  TEST_ASSERT_EQUAL_UINT32(1, telemetry.streamsCompleted);
  TEST_ASSERT_EQUAL_UINT32(1, telemetry.chunksAccepted);
  TEST_ASSERT_EQUAL_UINT32(4, telemetry.bytesAccepted);
  TEST_ASSERT_EQUAL_UINT32(4, telemetry.lastPayloadBytes);
  TEST_ASSERT_GREATER_THAN_UINT32(0, telemetry.checksum);
  TEST_ASSERT_EQUAL_UINT32(0, telemetry.errors);
}

class CountingBridgeDownlinkSink : public BridgeAudioDownlinkSink {
 public:
  bool begin() override {
    beginCalls++;
    ready = true;
    return true;
  }

  bool start(const BridgeAudioStream& stream, uint32_t nowMs) override {
    startCalls++;
    active = true;
    lastSeq = stream.seq;
    lastSampleRate = stream.sampleRate;
    lastStartMs = nowMs;
    strncpy(lastFormat, stream.format, sizeof(lastFormat) - 1);
    lastFormat[sizeof(lastFormat) - 1] = '\0';
    return startResult;
  }

  bool writeChunk(const BridgeAudioStreamChunk& chunk, uint32_t nowMs) override {
    chunkCalls++;
    lastChunkMs = nowMs;
    lastPayloadBytes = chunk.payloadBytes;
    bytesWritten += chunk.payloadBytes;
    return chunkResult;
  }

  void stop(uint32_t nowMs) override {
    stopCalls++;
    lastStopMs = nowMs;
    active = false;
  }

  bool isReady() const override {
    return ready;
  }

  bool ready = false;
  bool active = false;
  bool startResult = true;
  bool chunkResult = true;
  uint32_t beginCalls = 0;
  uint32_t startCalls = 0;
  uint32_t chunkCalls = 0;
  uint32_t stopCalls = 0;
  uint32_t lastSeq = 0;
  uint32_t lastSampleRate = 0;
  uint32_t lastStartMs = 0;
  uint32_t lastChunkMs = 0;
  uint32_t lastStopMs = 0;
  uint32_t lastPayloadBytes = 0;
  uint32_t bytesWritten = 0;
  char lastFormat[kBridgeAudioFormatMax] = {};
};

void test_bridge_audio_downlink_hands_pcm16_chunks_to_playback_sink() {
  CountingBridgeDownlinkSink sink;
  BridgeAudioDownlink downlink;
  TEST_ASSERT_TRUE(downlink.begin(true, &sink));
  TEST_ASSERT_TRUE(downlink.telemetry().playbackEnabled);
  TEST_ASSERT_TRUE(downlink.telemetry().playbackReady);
  TEST_ASSERT_EQUAL_UINT32(1, sink.beginCalls);

  BridgeAudioStream stream;
  stream.seq = 19;
  stream.sampleRate = 22050;
  stream.audioBytes = 4;
  stream.chunkBytes = 4;
  stream.chunks = 1;
  strncpy(stream.format, "pcm16", sizeof(stream.format) - 1);
  TEST_ASSERT_TRUE(downlink.start(stream, 900));
  TEST_ASSERT_TRUE(downlink.telemetry().playbackActive);
  TEST_ASSERT_EQUAL_UINT32(1, downlink.telemetry().playbackStarts);
  TEST_ASSERT_EQUAL_UINT32(1, sink.startCalls);
  TEST_ASSERT_EQUAL_UINT32(19, sink.lastSeq);
  TEST_ASSERT_EQUAL_UINT32(22050, sink.lastSampleRate);
  TEST_ASSERT_EQUAL_STRING("pcm16", sink.lastFormat);

  const uint8_t payload[] = {0x00, 0x00, 0xff, 0x7f};
  BridgeAudioStreamChunk chunk;
  chunk.seq = 19;
  chunk.index = 1;
  chunk.bytes = sizeof(payload);
  chunk.payloadBytes = sizeof(payload);
  chunk.receivedBytes = sizeof(payload);
  chunk.finalChunk = true;
  chunk.payload = payload;
  TEST_ASSERT_TRUE(downlink.submitChunk(chunk, 910));
  TEST_ASSERT_EQUAL_UINT32(1, downlink.telemetry().playbackChunks);
  TEST_ASSERT_EQUAL_UINT32(sizeof(payload), downlink.telemetry().playbackBytes);
  TEST_ASSERT_EQUAL_UINT32(1, sink.chunkCalls);
  TEST_ASSERT_EQUAL_UINT32(sizeof(payload), sink.bytesWritten);

  TEST_ASSERT_TRUE(downlink.end(stream, 920));
  TEST_ASSERT_FALSE(downlink.telemetry().playbackActive);
  TEST_ASSERT_EQUAL_UINT32(1, downlink.telemetry().playbackStops);
  TEST_ASSERT_EQUAL_UINT32(1, sink.stopCalls);
  TEST_ASSERT_EQUAL_UINT32(0, downlink.telemetry().playbackErrors);
}

void test_bridge_audio_downlink_counts_unsupported_playback_format_without_failing_stream() {
  CountingBridgeDownlinkSink sink;
  BridgeAudioDownlink downlink;
  TEST_ASSERT_TRUE(downlink.begin(true, &sink));

  BridgeAudioStream stream;
  stream.seq = 20;
  stream.sampleRate = 22050;
  stream.audioBytes = 4;
  stream.chunkBytes = 4;
  stream.chunks = 1;
  strncpy(stream.format, "wav", sizeof(stream.format) - 1);
  TEST_ASSERT_TRUE(downlink.start(stream, 940));
  TEST_ASSERT_FALSE(downlink.telemetry().playbackActive);
  TEST_ASSERT_EQUAL_UINT32(1, downlink.telemetry().playbackUnsupported);
  TEST_ASSERT_EQUAL_UINT32(0, sink.startCalls);

  const uint8_t payload[] = {1, 2, 3, 4};
  BridgeAudioStreamChunk chunk;
  chunk.seq = 20;
  chunk.index = 1;
  chunk.bytes = sizeof(payload);
  chunk.payloadBytes = sizeof(payload);
  chunk.receivedBytes = sizeof(payload);
  chunk.finalChunk = true;
  chunk.payload = payload;
  TEST_ASSERT_TRUE(downlink.submitChunk(chunk, 950));
  TEST_ASSERT_TRUE(downlink.end(stream, 960));

  TEST_ASSERT_EQUAL_UINT32(1, downlink.telemetry().streamsCompleted);
  TEST_ASSERT_EQUAL_UINT32(sizeof(payload), downlink.telemetry().bytesAccepted);
  TEST_ASSERT_EQUAL_UINT32(0, downlink.telemetry().playbackStarts);
  TEST_ASSERT_EQUAL_UINT32(0, downlink.telemetry().playbackChunks);
  TEST_ASSERT_EQUAL_UINT32(0, downlink.telemetry().playbackErrors);
}

void test_bridge_audio_downlink_stops_playback_on_end_mismatch() {
  CountingBridgeDownlinkSink sink;
  BridgeAudioDownlink downlink;
  TEST_ASSERT_TRUE(downlink.begin(true, &sink));

  BridgeAudioStream stream;
  stream.seq = 21;
  stream.sampleRate = 22050;
  stream.audioBytes = 4;
  stream.chunkBytes = 4;
  stream.chunks = 1;
  strncpy(stream.format, "pcm16", sizeof(stream.format) - 1);
  TEST_ASSERT_TRUE(downlink.start(stream, 980));

  const uint8_t payload[] = {0x00, 0x00};
  BridgeAudioStreamChunk chunk;
  chunk.seq = 21;
  chunk.index = 1;
  chunk.bytes = sizeof(payload);
  chunk.payloadBytes = sizeof(payload);
  chunk.receivedBytes = sizeof(payload);
  chunk.finalChunk = true;
  chunk.payload = payload;
  TEST_ASSERT_TRUE(downlink.submitChunk(chunk, 990));
  TEST_ASSERT_TRUE(downlink.telemetry().playbackActive);

  TEST_ASSERT_FALSE(downlink.end(stream, 1000));
  TEST_ASSERT_FALSE(downlink.telemetry().active);
  TEST_ASSERT_FALSE(downlink.telemetry().playbackActive);
  TEST_ASSERT_EQUAL_UINT32(0, downlink.telemetry().streamsCompleted);
  TEST_ASSERT_EQUAL_UINT32(1, downlink.telemetry().errors);
  TEST_ASSERT_EQUAL_UINT32(1, downlink.telemetry().playbackStops);
  TEST_ASSERT_EQUAL_UINT32(1, sink.stopCalls);
}

void test_bridge_audio_downlink_rejects_invalid_payload_and_aborts() {
  BridgeAudioDownlink downlink;
  TEST_ASSERT_TRUE(downlink.begin());

  BridgeAudioStream stream;
  stream.seq = 18;
  stream.audioBytes = 4;
  stream.chunkBytes = 4;
  stream.chunks = 1;
  strncpy(stream.format, "wav", sizeof(stream.format) - 1);
  TEST_ASSERT_TRUE(downlink.start(stream, 800));

  BridgeAudioStreamChunk chunk;
  chunk.seq = 18;
  chunk.index = 1;
  chunk.bytes = 4;
  chunk.payloadBytes = 4;
  chunk.payload = nullptr;

  TEST_ASSERT_FALSE(downlink.submitChunk(chunk, 810));
  TEST_ASSERT_TRUE(downlink.telemetry().active);
  TEST_ASSERT_EQUAL_UINT32(1, downlink.telemetry().errors);
  downlink.abort(820, 42);
  TEST_ASSERT_FALSE(downlink.telemetry().active);
  TEST_ASSERT_EQUAL_UINT32(1, downlink.telemetry().streamsAborted);
  TEST_ASSERT_EQUAL_UINT32(42, downlink.telemetry().lastErrorCode);
}

void test_bridge_client_recovers_after_error_aborts_audio_stream() {
  BridgeClient bridge;
  TEST_ASSERT_TRUE(bridge.begin());

  TEST_ASSERT_TRUE(bridge.submitControlLine("{\"type\":\"hello\",\"session\":\"before-drop\"}", 650));
  BridgeClientOutput output;
  TEST_ASSERT_TRUE(bridge.poll(&output));
  TEST_ASSERT_EQUAL(static_cast<int>(BridgeClientOutputType::SessionReady), static_cast<int>(output.type));
  TEST_ASSERT_EQUAL(static_cast<int>(BridgeClientState::Ready), static_cast<int>(bridge.telemetry().state));

  TEST_ASSERT_TRUE(bridge.submitControlLine(
      "{\"type\":\"audio_stream_start\",\"seq\":21,\"format\":\"wav\",\"sample_rate\":22050,"
      "\"audio_bytes\":6,\"chunk_bytes\":3,\"chunks\":2}",
      660));
  TEST_ASSERT_TRUE(bridge.poll(&output));
  TEST_ASSERT_EQUAL(static_cast<int>(BridgeClientOutputType::AudioStreamStart), static_cast<int>(output.type));
  TEST_ASSERT_TRUE(bridge.telemetry().audioStreamActive);
  TEST_ASSERT_EQUAL(static_cast<int>(BridgeClientState::Responding), static_cast<int>(bridge.telemetry().state));

  const uint8_t chunk[] = {1, 2, 3};
  TEST_ASSERT_TRUE(bridge.submitBinaryFrame(chunk, sizeof(chunk), 665));
  TEST_ASSERT_TRUE(bridge.poll(&output));
  TEST_ASSERT_EQUAL(static_cast<int>(BridgeClientOutputType::AudioStreamChunk), static_cast<int>(output.type));
  TEST_ASSERT_EQUAL_UINT32(3, bridge.telemetry().audioStreamBytesReceived);
  TEST_ASSERT_TRUE(bridge.telemetry().audioStreamActive);

  TEST_ASSERT_TRUE(bridge.submitControlLine("{\"type\":\"error\",\"seq\":21,\"code\":\"bridge_closed\"}", 670));
  TEST_ASSERT_TRUE(bridge.poll(&output));
  TEST_ASSERT_EQUAL(static_cast<int>(BridgeClientOutputType::Error), static_cast<int>(output.type));
  TEST_ASSERT_EQUAL_STRING("bridge_closed", output.error);
  TEST_ASSERT_EQUAL(static_cast<int>(BridgeClientState::Error), static_cast<int>(bridge.telemetry().state));
  TEST_ASSERT_FALSE(bridge.telemetry().audioStreamActive);
  TEST_ASSERT_EQUAL_UINT32(0, bridge.telemetry().audioStreamErrors);

  TEST_ASSERT_TRUE(bridge.submitControlLine("{\"type\":\"hello\",\"session\":\"after-drop\"}", 700));
  TEST_ASSERT_TRUE(bridge.poll(&output));
  TEST_ASSERT_EQUAL(static_cast<int>(BridgeClientOutputType::SessionReady), static_cast<int>(output.type));
  TEST_ASSERT_EQUAL_STRING("after-drop", output.sessionId);
  TEST_ASSERT_EQUAL(static_cast<int>(BridgeClientState::Ready), static_cast<int>(bridge.telemetry().state));

  TEST_ASSERT_TRUE(bridge.submitControlLine(
      "{\"type\":\"response_start\",\"seq\":22,\"intent\":\"concern\",\"arousal\":0.4,\"valence\":0.35,"
      "\"text\":\"I lost the bridge, but I am still here.\"}",
      710));
  TEST_ASSERT_TRUE(bridge.poll(&output));
  TEST_ASSERT_EQUAL(static_cast<int>(BridgeClientOutputType::ResponseStart), static_cast<int>(output.type));
  TEST_ASSERT_EQUAL_UINT32(22, output.response.seq);
  TEST_ASSERT_EQUAL(static_cast<int>(SpeechIntent::Concern), static_cast<int>(output.response.intent));
  TEST_ASSERT_EQUAL_STRING("I lost the bridge, but I am still here.", output.response.text);

  TEST_ASSERT_TRUE(bridge.submitControlLine("{\"type\":\"response_end\",\"seq\":22}", 730));
  TEST_ASSERT_TRUE(bridge.poll(&output));
  TEST_ASSERT_EQUAL(static_cast<int>(BridgeClientOutputType::ResponseEnd), static_cast<int>(output.type));
  TEST_ASSERT_EQUAL(static_cast<int>(BridgeClientState::Ready), static_cast<int>(bridge.telemetry().state));
  TEST_ASSERT_FALSE(bridge.telemetry().audioStreamActive);
}

void test_bridge_client_reports_parse_errors_without_allocating() {
  BridgeClient bridge;
  TEST_ASSERT_TRUE(bridge.begin());

  TEST_ASSERT_FALSE(bridge.submitControlLine("{\"type\":\"mystery\"}", 700));

  BridgeClientOutput output;
  TEST_ASSERT_TRUE(bridge.poll(&output));
  TEST_ASSERT_EQUAL(static_cast<int>(BridgeClientOutputType::Error), static_cast<int>(output.type));
  TEST_ASSERT_EQUAL(static_cast<int>(EventType::Error), static_cast<int>(output.event.type));
  TEST_ASSERT_EQUAL_STRING("unknown_type", output.error);
  TEST_ASSERT_EQUAL_UINT32(1, bridge.telemetry().parseErrors);
  TEST_ASSERT_EQUAL(static_cast<int>(BridgeClientState::Error), static_cast<int>(bridge.telemetry().state));
}

void test_bridge_client_times_out_active_session_once() {
  BridgeClient bridge;
  BridgeClientConfig config;
  config.responseTimeoutMs = 100;
  TEST_ASSERT_TRUE(bridge.begin(config));

  TEST_ASSERT_TRUE(bridge.submitControlLine("{\"type\":\"thinking\",\"seq\":9}", 1000));

  BridgeClientOutput output;
  TEST_ASSERT_TRUE(bridge.poll(&output));
  TEST_ASSERT_EQUAL(static_cast<int>(BridgeClientOutputType::Event), static_cast<int>(output.type));
  TEST_ASSERT_EQUAL(static_cast<int>(BridgeClientState::Thinking), static_cast<int>(bridge.telemetry().state));

  TEST_ASSERT_FALSE(bridge.update(1099));
  TEST_ASSERT_FALSE(bridge.poll(&output));

  TEST_ASSERT_TRUE(bridge.update(1100));
  TEST_ASSERT_TRUE(bridge.poll(&output));
  TEST_ASSERT_EQUAL(static_cast<int>(BridgeClientOutputType::Error), static_cast<int>(output.type));
  TEST_ASSERT_EQUAL(static_cast<int>(EventType::Error), static_cast<int>(output.event.type));
  TEST_ASSERT_EQUAL_STRING("bridge_timeout", output.error);
  TEST_ASSERT_EQUAL_UINT32(1100, output.event.timestampMs);
  TEST_ASSERT_EQUAL_UINT32(1, bridge.telemetry().timeouts);
  TEST_ASSERT_EQUAL(static_cast<int>(BridgeClientState::Error), static_cast<int>(bridge.telemetry().state));

  TEST_ASSERT_FALSE(bridge.update(1400));
  TEST_ASSERT_FALSE(bridge.poll(&output));
  TEST_ASSERT_EQUAL_UINT32(1, bridge.telemetry().timeouts);
}

void test_bridge_client_timeout_aborts_audio_stream() {
  BridgeClient bridge;
  BridgeClientConfig config;
  config.responseTimeoutMs = 100;
  TEST_ASSERT_TRUE(bridge.begin(config));

  TEST_ASSERT_TRUE(bridge.submitControlLine(
      "{\"type\":\"audio_stream_start\",\"seq\":31,\"format\":\"wav\",\"sample_rate\":22050,"
      "\"audio_bytes\":6,\"chunk_bytes\":3,\"chunks\":2}",
      1200));

  BridgeClientOutput output;
  TEST_ASSERT_TRUE(bridge.poll(&output));
  TEST_ASSERT_EQUAL(static_cast<int>(BridgeClientOutputType::AudioStreamStart), static_cast<int>(output.type));
  TEST_ASSERT_TRUE(bridge.telemetry().audioStreamActive);
  TEST_ASSERT_EQUAL(static_cast<int>(BridgeClientState::Responding), static_cast<int>(bridge.telemetry().state));

  TEST_ASSERT_TRUE(bridge.update(1300));
  TEST_ASSERT_TRUE(bridge.poll(&output));
  TEST_ASSERT_EQUAL(static_cast<int>(BridgeClientOutputType::Error), static_cast<int>(output.type));
  TEST_ASSERT_EQUAL_STRING("bridge_timeout", output.error);
  TEST_ASSERT_EQUAL(static_cast<int>(BridgeClientState::Error), static_cast<int>(bridge.telemetry().state));
  TEST_ASSERT_FALSE(bridge.telemetry().audioStreamActive);
  TEST_ASSERT_EQUAL_UINT32(1, bridge.telemetry().timeouts);
}

void test_bridge_client_accepts_serial_bridge_transcript() {
  BridgeClient bridge;
  TEST_ASSERT_TRUE(bridge.begin());

  const char* commands[] = {
      "bridge hello bench",
      "bridge thinking 5",
      "bridge response happy 5 hello stackchan friend",
      "bridge audio 0.55 ah 20",
      "bridge end 5",
  };

  BridgeClientOutput output;
  for (size_t i = 0; i < sizeof(commands) / sizeof(commands[0]); ++i) {
    BenchControl control;
    TEST_ASSERT_TRUE(parseBenchControlLine(commands[i], 8000 + static_cast<uint32_t>(i), &control));
    TEST_ASSERT_TRUE(control.hasBridge);
    TEST_ASSERT_TRUE(bridge.submitControlLine(control.bridge.controlLine, 9000 + static_cast<uint32_t>(i)));
    TEST_ASSERT_TRUE(bridge.poll(&output));
  }

  TEST_ASSERT_EQUAL(static_cast<int>(BridgeClientOutputType::ResponseEnd), static_cast<int>(output.type));
  TEST_ASSERT_EQUAL(static_cast<int>(EventType::ResponseEnded), static_cast<int>(output.event.type));
  TEST_ASSERT_EQUAL_UINT32(5, bridge.telemetry().inboundMessages);
  TEST_ASSERT_EQUAL_UINT32(5, bridge.telemetry().outputsQueued);
  TEST_ASSERT_EQUAL_UINT32(0, bridge.telemetry().parseErrors);
}

size_t encodeServerWebSocketFrame(uint8_t opcode,
                                  const uint8_t* payload,
                                  size_t length,
                                  uint8_t* out,
                                  size_t outSize) {
  const size_t headerBytes = length < 126 ? 2u : 4u;
  const size_t totalBytes = headerBytes + length;
  if (out == nullptr || outSize < totalBytes || length > 0xffffu) {
    return 0;
  }
  out[0] = static_cast<uint8_t>(0x80 | (opcode & 0x0f));
  if (length < 126) {
    out[1] = static_cast<uint8_t>(length);
  } else {
    out[1] = 126;
    out[2] = static_cast<uint8_t>((length >> 8) & 0xff);
    out[3] = static_cast<uint8_t>(length & 0xff);
  }
  if (length > 0) {
    std::memcpy(out + headerBytes, payload, length);
  }
  return totalBytes;
}

size_t encodeServerWebSocketText(const char* payload, uint8_t* out, size_t outSize) {
  return encodeServerWebSocketFrame(static_cast<uint8_t>(BridgeWebSocketOpcode::Text),
                                    reinterpret_cast<const uint8_t*>(payload),
                                    std::strlen(payload),
                                    out,
                                    outSize);
}

class CapturingBridgeSocketSink final : public BridgeSocketWriterSink {
 public:
  bool isConnected() const override {
    return connected;
  }

  size_t write(const uint8_t* data, size_t length) override {
    if (!connected || data == nullptr || length == 0) {
      return 0;
    }
    const size_t allowed = maxWriteBytes == 0 || maxWriteBytes > length ? length : maxWriteBytes;
    bytes.insert(bytes.end(), data, data + allowed);
    writes++;
    return allowed;
  }

  bool connected = true;
  size_t maxWriteBytes = 0;
  uint32_t writes = 0;
  std::vector<uint8_t> bytes;
};

class FakeBridgeNetworkSocket final : public BridgeNetworkSocket {
 public:
  bool connect(const char* host, uint16_t port) override {
    lastHost = host != nullptr ? host : "";
    lastPort = port;
    connectAttempts++;
    connected = connectSucceeds;
    return connected;
  }

  bool isConnected() const override {
    return connected;
  }

  int available() override {
    return connected ? static_cast<int>(incoming.size() - readOffset) : 0;
  }

  int read(uint8_t* out, size_t outSize) override {
    if (!connected || out == nullptr || outSize == 0 || readOffset >= incoming.size()) {
      return 0;
    }
    const size_t remaining = incoming.size() - readOffset;
    const size_t count = remaining < outSize ? remaining : outSize;
    std::memcpy(out, incoming.data() + readOffset, count);
    readOffset += count;
    return static_cast<int>(count);
  }

  size_t write(const uint8_t* data, size_t length) override {
    if (!connected || data == nullptr || length == 0) {
      return 0;
    }
    const size_t count = maxWriteBytes == 0 || maxWriteBytes > length ? length : maxWriteBytes;
    outgoing.insert(outgoing.end(), data, data + count);
    writes++;
    return count;
  }

  void stop() override {
    connected = false;
    stops++;
  }

  void pushIncoming(const char* text) {
    if (text == nullptr) {
      return;
    }
    incoming.insert(incoming.end(), text, text + std::strlen(text));
  }

  void pushIncoming(const uint8_t* data, size_t length) {
    if (data == nullptr || length == 0) {
      return;
    }
    incoming.insert(incoming.end(), data, data + length);
  }

  void clearOutgoing() {
    outgoing.clear();
    writes = 0;
  }

  bool connected = false;
  bool connectSucceeds = true;
  size_t maxWriteBytes = 0;
  uint32_t connectAttempts = 0;
  uint32_t writes = 0;
  uint32_t stops = 0;
  std::string lastHost;
  uint16_t lastPort = 0;
  std::vector<uint8_t> incoming;
  std::vector<uint8_t> outgoing;
  size_t readOffset = 0;
};

bool decodeMaskedClientTextFrame(const std::vector<uint8_t>& frame, char* out, size_t outSize) {
  if (out == nullptr || outSize == 0 || frame.size() < 6 || frame[0] != 0x81 ||
      (frame[1] & 0x80) == 0) {
    return false;
  }

  size_t payloadLength = frame[1] & 0x7f;
  size_t maskOffset = 2;
  if (payloadLength == 126) {
    if (frame.size() < 8) {
      return false;
    }
    payloadLength = (static_cast<size_t>(frame[2]) << 8) | frame[3];
    maskOffset = 4;
  }

  const size_t payloadOffset = maskOffset + 4u;
  if (frame.size() < payloadOffset + payloadLength || outSize <= payloadLength) {
    return false;
  }
  const uint8_t* mask = frame.data() + maskOffset;
  for (size_t i = 0; i < payloadLength; ++i) {
    out[i] = static_cast<char>(frame[payloadOffset + i] ^ mask[i % 4u]);
  }
  out[payloadLength] = '\0';
  return true;
}

void test_bridge_websocket_builds_upgrade_request_and_accepts_response() {
  BridgeClientConfig config;
  config.deviceId = "stackchan-test";

  char request[kBridgeWebSocketHandshakeMax] = {};
  const size_t requestBytes = BridgeWebSocketTransport::buildHandshakeRequest(
      request,
      sizeof(request),
      "127.0.0.1",
      8765,
      "/bridge",
      "dGhlIHNhbXBsZSBub25jZQ==",
      config);

  TEST_ASSERT_GREATER_THAN_UINT32(0, requestBytes);
  TEST_ASSERT_TRUE(containsText(request, "GET /bridge HTTP/1.1"));
  TEST_ASSERT_TRUE(containsText(request, "Host: 127.0.0.1:8765"));
  TEST_ASSERT_TRUE(containsText(request, "Upgrade: websocket"));
  TEST_ASSERT_TRUE(containsText(request, "Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ=="));
  TEST_ASSERT_TRUE(containsText(request, "X-Stackchan-Protocol: stackchan.bridge.v1"));
  TEST_ASSERT_TRUE(containsText(request, "X-Stackchan-Device: stackchan-test"));

  BridgeClient bridge;
  TEST_ASSERT_TRUE(bridge.begin(config));
  BridgeWebSocketTransport transport;
  TEST_ASSERT_TRUE(transport.begin(bridge, 100));
  TEST_ASSERT_EQUAL(static_cast<int>(BridgeClientState::Connecting), static_cast<int>(bridge.telemetry().state));

  const char* response =
      "HTTP/1.1 101 Switching Protocols\r\n"
      "Upgrade: websocket\r\n"
      "Connection: Upgrade\r\n"
      "Sec-WebSocket-Accept: s3pPLMBiTxaQ9kYGzzhZRbK+xOo=\r\n"
      "\r\n";
  TEST_ASSERT_TRUE(transport.acceptHandshakeResponse(response, 120, "s3pPLMBiTxaQ9kYGzzhZRbK+xOo="));
  TEST_ASSERT_EQUAL(static_cast<int>(BridgeWebSocketTransportState::Connected),
                    static_cast<int>(transport.telemetry().state));
  TEST_ASSERT_TRUE(transport.telemetry().handshakeAccepted);
  TEST_ASSERT_EQUAL_UINT32(1, transport.telemetry().handshakesAccepted);
  TEST_ASSERT_EQUAL_UINT32(0, transport.telemetry().handshakesRejected);
}

void test_bridge_websocket_encodes_masked_client_text_frames() {
  const char* payload = "{\"type\":\"hello\",\"protocol\":\"stackchan.bridge.v1\"}";
  const uint8_t maskKey[4] = {0x11, 0x22, 0x33, 0x44};
  uint8_t frame[160] = {};

  const size_t frameBytes = BridgeWebSocketTransport::encodeClientTextFrame(
      payload,
      maskKey,
      frame,
      sizeof(frame));

  TEST_ASSERT_GREATER_THAN_UINT32(0, frameBytes);
  TEST_ASSERT_EQUAL_HEX8(0x81, frame[0]);
  TEST_ASSERT_TRUE((frame[1] & 0x80) != 0);
  TEST_ASSERT_EQUAL_UINT32(std::strlen(payload), frame[1] & 0x7f);
  TEST_ASSERT_EQUAL_HEX8(maskKey[0], frame[2]);
  TEST_ASSERT_EQUAL_HEX8(maskKey[1], frame[3]);
  TEST_ASSERT_EQUAL_HEX8(maskKey[2], frame[4]);
  TEST_ASSERT_EQUAL_HEX8(maskKey[3], frame[5]);

  const size_t payloadOffset = 6;
  for (size_t i = 0; i < std::strlen(payload); ++i) {
    TEST_ASSERT_EQUAL_HEX8(static_cast<uint8_t>(payload[i]),
                           frame[payloadOffset + i] ^ maskKey[i % 4u]);
  }
}

void test_bridge_websocket_decodes_server_text_to_bridge_client() {
  BridgeClient bridge;
  TEST_ASSERT_TRUE(bridge.begin());
  BridgeWebSocketTransport transport;
  TEST_ASSERT_TRUE(transport.begin(bridge, 200));
  TEST_ASSERT_TRUE(transport.acceptHandshakeResponse(
      "HTTP/1.1 101 Switching Protocols\r\n"
      "Upgrade: websocket\r\n"
      "Connection: Upgrade\r\n"
      "Sec-WebSocket-Accept: ok\r\n"
      "\r\n",
      210));

  const char* hello = "{\"type\":\"hello\",\"protocol\":\"stackchan.bridge.v1\",\"session\":\"ws-ok\"}";
  uint8_t frame[160] = {};
  const size_t frameBytes = encodeServerWebSocketText(hello, frame, sizeof(frame));
  TEST_ASSERT_GREATER_THAN_UINT32(0, frameBytes);

  TEST_ASSERT_TRUE(transport.submitBytes(frame, 2, 220));
  BridgeClientOutput output;
  TEST_ASSERT_FALSE(bridge.poll(&output));
  TEST_ASSERT_TRUE(transport.submitBytes(frame + 2, frameBytes - 2, 225));
  TEST_ASSERT_TRUE(bridge.poll(&output));
  TEST_ASSERT_EQUAL(static_cast<int>(BridgeClientOutputType::SessionReady), static_cast<int>(output.type));
  TEST_ASSERT_EQUAL_STRING("ws-ok", output.sessionId);
  TEST_ASSERT_EQUAL(static_cast<int>(BridgeClientState::Ready), static_cast<int>(bridge.telemetry().state));
  TEST_ASSERT_EQUAL_UINT32(1, transport.telemetry().textFramesDecoded);
  TEST_ASSERT_EQUAL_UINT32(std::strlen(hello), transport.telemetry().maxPayloadBytes);
}

void test_bridge_websocket_decodes_binary_downlink_chunks() {
  BridgeClient bridge;
  TEST_ASSERT_TRUE(bridge.begin());
  BridgeWebSocketTransport transport;
  TEST_ASSERT_TRUE(transport.begin(bridge, 300));
  TEST_ASSERT_TRUE(transport.acceptHandshakeResponse(
      "HTTP/1.1 101 Switching Protocols\r\n"
      "Upgrade: websocket\r\n"
      "Connection: Upgrade\r\n"
      "Sec-WebSocket-Accept: ok\r\n"
      "\r\n",
      305));

  uint8_t frame[256] = {};
  const char* start =
      "{\"type\":\"audio_stream_start\",\"seq\":44,\"format\":\"pcm16\",\"sample_rate\":22050,"
      "\"audio_bytes\":4,\"chunk_bytes\":4,\"chunks\":1}";
  size_t frameBytes = encodeServerWebSocketText(start, frame, sizeof(frame));
  TEST_ASSERT_TRUE(transport.submitBytes(frame, frameBytes, 310));

  BridgeClientOutput output;
  TEST_ASSERT_TRUE(bridge.poll(&output));
  TEST_ASSERT_EQUAL(static_cast<int>(BridgeClientOutputType::AudioStreamStart), static_cast<int>(output.type));
  TEST_ASSERT_EQUAL_UINT32(44, output.stream.seq);
  TEST_ASSERT_EQUAL_STRING("pcm16", output.stream.format);

  const uint8_t payload[] = {0x00, 0x00, 0xff, 0x7f};
  frameBytes = encodeServerWebSocketFrame(static_cast<uint8_t>(BridgeWebSocketOpcode::Binary),
                                          payload,
                                          sizeof(payload),
                                          frame,
                                          sizeof(frame));
  TEST_ASSERT_TRUE(transport.submitBytes(frame, frameBytes, 315));
  TEST_ASSERT_TRUE(bridge.poll(&output));
  TEST_ASSERT_EQUAL(static_cast<int>(BridgeClientOutputType::AudioStreamChunk), static_cast<int>(output.type));
  TEST_ASSERT_EQUAL_UINT32(44, output.streamChunk.seq);
  TEST_ASSERT_EQUAL_UINT32(4, output.streamChunk.payloadBytes);
  TEST_ASSERT_NOT_NULL(output.streamChunk.payload);
  TEST_ASSERT_EQUAL_HEX8(0x00, output.streamChunk.payload[0]);
  TEST_ASSERT_EQUAL_HEX8(0x7f, output.streamChunk.payload[3]);
  TEST_ASSERT_TRUE(output.streamChunk.finalChunk);

  const char* end = "{\"type\":\"audio_stream_end\",\"seq\":44,\"audio_bytes\":4,\"chunks\":1}";
  frameBytes = encodeServerWebSocketText(end, frame, sizeof(frame));
  TEST_ASSERT_TRUE(transport.submitBytes(frame, frameBytes, 320));
  TEST_ASSERT_TRUE(bridge.poll(&output));
  TEST_ASSERT_EQUAL(static_cast<int>(BridgeClientOutputType::AudioStreamEnd), static_cast<int>(output.type));
  TEST_ASSERT_EQUAL_UINT32(1, transport.telemetry().binaryFramesDecoded);
  TEST_ASSERT_EQUAL_UINT32(2, transport.telemetry().textFramesDecoded);
  TEST_ASSERT_EQUAL_UINT32(0, transport.telemetry().bridgeSubmitsRejected);
}

void test_bridge_websocket_rejects_masked_server_frames() {
  BridgeClient bridge;
  TEST_ASSERT_TRUE(bridge.begin());
  BridgeWebSocketTransport transport;
  TEST_ASSERT_TRUE(transport.begin(bridge, 400));
  TEST_ASSERT_TRUE(transport.acceptHandshakeResponse(
      "HTTP/1.1 101 Switching Protocols\r\n"
      "Upgrade: websocket\r\n"
      "Connection: Upgrade\r\n"
      "Sec-WebSocket-Accept: ok\r\n"
      "\r\n",
      405));

  const uint8_t maskedServerFrame[] = {
      0x81,
      static_cast<uint8_t>(0x80 | 2),
      0x01,
      0x02,
      0x03,
      0x04,
      static_cast<uint8_t>('h' ^ 0x01),
      static_cast<uint8_t>('i' ^ 0x02),
  };
  TEST_ASSERT_FALSE(transport.submitBytes(maskedServerFrame, sizeof(maskedServerFrame), 410));
  TEST_ASSERT_EQUAL(static_cast<int>(BridgeWebSocketTransportState::Error),
                    static_cast<int>(transport.telemetry().state));
  TEST_ASSERT_EQUAL_STRING("masked_server_websocket_frame", transport.telemetry().lastError);
  TEST_ASSERT_EQUAL_UINT32(1, transport.telemetry().frameErrors);
  TEST_ASSERT_EQUAL_UINT32(0, bridge.telemetry().inboundMessages);
}

void test_bridge_websocket_close_marks_bridge_disconnected() {
  BridgeClient bridge;
  TEST_ASSERT_TRUE(bridge.begin());
  BridgeWebSocketTransport transport;
  TEST_ASSERT_TRUE(transport.begin(bridge, 500));
  TEST_ASSERT_TRUE(transport.acceptHandshakeResponse(
      "HTTP/1.1 101 Switching Protocols\r\n"
      "Upgrade: websocket\r\n"
      "Connection: Upgrade\r\n"
      "Sec-WebSocket-Accept: ok\r\n"
      "\r\n",
      505));

  uint8_t frame[160] = {};
  size_t frameBytes = encodeServerWebSocketText("{\"type\":\"hello\",\"session\":\"before-close\"}",
                                                frame,
                                                sizeof(frame));
  TEST_ASSERT_TRUE(transport.submitBytes(frame, frameBytes, 510));
  BridgeClientOutput output;
  TEST_ASSERT_TRUE(bridge.poll(&output));
  TEST_ASSERT_EQUAL(static_cast<int>(BridgeClientState::Ready), static_cast<int>(bridge.telemetry().state));

  const uint8_t closeFrame[] = {0x88, 0x00};
  TEST_ASSERT_TRUE(transport.submitBytes(closeFrame, sizeof(closeFrame), 520));
  TEST_ASSERT_EQUAL(static_cast<int>(BridgeWebSocketTransportState::Closed),
                    static_cast<int>(transport.telemetry().state));
  TEST_ASSERT_EQUAL(static_cast<int>(BridgeClientState::Offline), static_cast<int>(bridge.telemetry().state));
  TEST_ASSERT_EQUAL_UINT32(1, transport.telemetry().closeFramesDecoded);
}

void test_bridge_websocket_routes_endpoint_control_to_pending_response() {
  BridgeClient bridge;
  TEST_ASSERT_TRUE(bridge.begin());
  BridgeEndpointRegistry registry;
  TEST_ASSERT_TRUE(registry.begin());
  BridgeEndpointControl endpointControl;
  TEST_ASSERT_TRUE(endpointControl.begin(registry));

  BridgeWebSocketTransport transport;
  TEST_ASSERT_TRUE(transport.begin(bridge, 540));
  transport.attachEndpointControl(&endpointControl);
  TEST_ASSERT_TRUE(transport.acceptHandshakeResponse(
      "HTTP/1.1 101 Switching Protocols\r\n"
      "Upgrade: websocket\r\n"
      "Connection: Upgrade\r\n"
      "Sec-WebSocket-Accept: ok\r\n"
      "\r\n",
      545));

  const char* endpointHello =
      "{\"type\":\"endpoint_hello\",\"protocol\":\"stackchan.bridge.v1\","
      "\"endpoint_id\":\"phone-rob-01\",\"endpoint_name\":\"Rob's Phone\","
      "\"endpoint_kind\":\"android\",\"priority\":60,"
      "\"capabilities\":[\"settings\",\"llm\",\"tts\"]}";
  uint8_t frame[320] = {};
  const size_t frameBytes = encodeServerWebSocketText(endpointHello, frame, sizeof(frame));
  TEST_ASSERT_GREATER_THAN_UINT32(0, frameBytes);
  TEST_ASSERT_TRUE(transport.submitBytes(frame, frameBytes, 550));

  TEST_ASSERT_TRUE(transport.hasPendingTextResponse());
  TEST_ASSERT_EQUAL_UINT32(1, transport.telemetry().textFramesDecoded);
  TEST_ASSERT_EQUAL_UINT32(1, transport.telemetry().endpointControlFrames);
  TEST_ASSERT_EQUAL_UINT32(1, transport.telemetry().endpointControlResponsesQueued);
  TEST_ASSERT_EQUAL_UINT32(0, bridge.telemetry().inboundMessages);
  TEST_ASSERT_TRUE(registry.isTrusted("phone-rob-01"));

  char response[kBridgeEndpointControlResponseMax] = {};
  TEST_ASSERT_TRUE(transport.popPendingTextResponse(response, sizeof(response)));
  TEST_ASSERT_FALSE(transport.hasPendingTextResponse());
  TEST_ASSERT_NOT_NULL(std::strstr(response, "\"type\":\"endpoint_hello_result\""));
  TEST_ASSERT_NOT_NULL(std::strstr(response, "\"endpoint_id\":\"phone-rob-01\""));
}

void test_bridge_websocket_encodes_pending_endpoint_response_as_masked_client_frame() {
  BridgeClient bridge;
  TEST_ASSERT_TRUE(bridge.begin());
  BridgeEndpointRegistry registry;
  TEST_ASSERT_TRUE(registry.begin());
  BridgeEndpointControl endpointControl;
  TEST_ASSERT_TRUE(endpointControl.begin(registry));

  BridgeWebSocketTransport transport;
  TEST_ASSERT_TRUE(transport.begin(bridge, 560));
  transport.attachEndpointControl(&endpointControl);
  TEST_ASSERT_TRUE(transport.acceptHandshakeResponse(
      "HTTP/1.1 101 Switching Protocols\r\n"
      "Upgrade: websocket\r\n"
      "Connection: Upgrade\r\n"
      "Sec-WebSocket-Accept: ok\r\n"
      "\r\n",
      565));

  const char* status = "{\"type\":\"owner_status\",\"protocol\":\"stackchan.bridge.v1\"}";
  uint8_t serverFrame[160] = {};
  const size_t serverFrameBytes = encodeServerWebSocketText(status, serverFrame, sizeof(serverFrame));
  TEST_ASSERT_TRUE(transport.submitBytes(serverFrame, serverFrameBytes, 570));
  TEST_ASSERT_TRUE(transport.hasPendingTextResponse());

  const uint8_t maskKey[4] = {0x10, 0x20, 0x30, 0x40};
  uint8_t clientFrame[kBridgeEndpointControlResponseMax + 16] = {};
  const size_t clientFrameBytes =
      transport.encodePendingTextResponseFrame(maskKey, clientFrame, sizeof(clientFrame));
  TEST_ASSERT_GREATER_THAN_UINT32(0, clientFrameBytes);
  TEST_ASSERT_FALSE(transport.hasPendingTextResponse());
  TEST_ASSERT_EQUAL_UINT32(1, transport.telemetry().outgoingTextFramesEncoded);
  TEST_ASSERT_EQUAL_HEX8(0x81, clientFrame[0]);
  TEST_ASSERT_TRUE((clientFrame[1] & 0x80) != 0);

  const size_t payloadLength = clientFrame[1] == (0x80 | 126)
                                   ? (static_cast<size_t>(clientFrame[2]) << 8) | clientFrame[3]
                                   : static_cast<size_t>(clientFrame[1] & 0x7f);
  const size_t maskOffset = clientFrame[1] == (0x80 | 126) ? 4u : 2u;
  TEST_ASSERT_EQUAL_HEX8(maskKey[0], clientFrame[maskOffset + 0]);
  TEST_ASSERT_EQUAL_HEX8(maskKey[1], clientFrame[maskOffset + 1]);
  TEST_ASSERT_EQUAL_HEX8(maskKey[2], clientFrame[maskOffset + 2]);
  TEST_ASSERT_EQUAL_HEX8(maskKey[3], clientFrame[maskOffset + 3]);
  TEST_ASSERT_GREATER_THAN_UINT32(0, payloadLength);

  char decoded[kBridgeEndpointControlResponseMax] = {};
  const size_t payloadOffset = maskOffset + 4u;
  TEST_ASSERT_LESS_THAN(sizeof(decoded), payloadLength + 1u);
  for (size_t i = 0; i < payloadLength; ++i) {
    decoded[i] = static_cast<char>(clientFrame[payloadOffset + i] ^ maskKey[i % 4u]);
  }
  decoded[payloadLength] = '\0';
  TEST_ASSERT_NOT_NULL(std::strstr(decoded, "\"type\":\"owner_status\""));
}

void test_bridge_websocket_ignored_endpoint_control_falls_through_to_bridge_client() {
  BridgeClient bridge;
  TEST_ASSERT_TRUE(bridge.begin());
  BridgeEndpointRegistry registry;
  TEST_ASSERT_TRUE(registry.begin());
  BridgeEndpointControl endpointControl;
  TEST_ASSERT_TRUE(endpointControl.begin(registry));

  BridgeWebSocketTransport transport;
  TEST_ASSERT_TRUE(transport.begin(bridge, 580));
  transport.attachEndpointControl(&endpointControl);
  TEST_ASSERT_TRUE(transport.acceptHandshakeResponse(
      "HTTP/1.1 101 Switching Protocols\r\n"
      "Upgrade: websocket\r\n"
      "Connection: Upgrade\r\n"
      "Sec-WebSocket-Accept: ok\r\n"
      "\r\n",
      585));

  const char* hello = "{\"type\":\"hello\",\"protocol\":\"stackchan.bridge.v1\",\"session\":\"ws-bridge\"}";
  uint8_t frame[160] = {};
  const size_t frameBytes = encodeServerWebSocketText(hello, frame, sizeof(frame));
  TEST_ASSERT_TRUE(transport.submitBytes(frame, frameBytes, 590));

  TEST_ASSERT_FALSE(transport.hasPendingTextResponse());
  TEST_ASSERT_EQUAL_UINT32(0, transport.telemetry().endpointControlFrames);
  BridgeClientOutput output;
  TEST_ASSERT_TRUE(bridge.poll(&output));
  TEST_ASSERT_EQUAL(static_cast<int>(BridgeClientOutputType::SessionReady), static_cast<int>(output.type));
  TEST_ASSERT_EQUAL_STRING("ws-bridge", output.sessionId);
}

void test_bridge_socket_writer_no_pending_is_noop() {
  BridgeClient bridge;
  TEST_ASSERT_TRUE(bridge.begin());
  BridgeWebSocketTransport transport;
  TEST_ASSERT_TRUE(transport.begin(bridge, 600));
  TEST_ASSERT_TRUE(transport.acceptHandshakeResponse(
      "HTTP/1.1 101 Switching Protocols\r\n"
      "Upgrade: websocket\r\n"
      "Connection: Upgrade\r\n"
      "Sec-WebSocket-Accept: ok\r\n"
      "\r\n",
      605));

  CapturingBridgeSocketSink sink;
  BridgeSocketWriter writer;
  TEST_ASSERT_TRUE(writer.begin(transport, sink, 0x12345678));
  TEST_ASSERT_EQUAL(static_cast<int>(BridgeSocketWriterDrainResult::NoPending),
                    static_cast<int>(writer.drainPendingTextResponse(610)));
  TEST_ASSERT_EQUAL_UINT32(1, writer.telemetry().drainAttempts);
  TEST_ASSERT_EQUAL_UINT32(0, writer.telemetry().framesEncoded);
  TEST_ASSERT_EQUAL_UINT32(0, writer.telemetry().framesWritten);
  TEST_ASSERT_EQUAL_UINT32(0, sink.writes);
  TEST_ASSERT_TRUE(sink.bytes.empty());
}

void test_bridge_socket_writer_writes_pending_endpoint_response_frame() {
  BridgeClient bridge;
  TEST_ASSERT_TRUE(bridge.begin());
  BridgeEndpointRegistry registry;
  TEST_ASSERT_TRUE(registry.begin());
  BridgeEndpointControl endpointControl;
  TEST_ASSERT_TRUE(endpointControl.begin(registry));
  BridgeWebSocketTransport transport;
  TEST_ASSERT_TRUE(transport.begin(bridge, 620));
  transport.attachEndpointControl(&endpointControl);
  TEST_ASSERT_TRUE(transport.acceptHandshakeResponse(
      "HTTP/1.1 101 Switching Protocols\r\n"
      "Upgrade: websocket\r\n"
      "Connection: Upgrade\r\n"
      "Sec-WebSocket-Accept: ok\r\n"
      "\r\n",
      625));

  const char* status = "{\"type\":\"owner_status\",\"protocol\":\"stackchan.bridge.v1\"}";
  uint8_t serverFrame[160] = {};
  const size_t serverFrameBytes = encodeServerWebSocketText(status, serverFrame, sizeof(serverFrame));
  TEST_ASSERT_TRUE(transport.submitBytes(serverFrame, serverFrameBytes, 630));
  TEST_ASSERT_TRUE(transport.hasPendingTextResponse());

  CapturingBridgeSocketSink sink;
  BridgeSocketWriter writer;
  TEST_ASSERT_TRUE(writer.begin(transport, sink, 0x22334455));
  TEST_ASSERT_EQUAL(static_cast<int>(BridgeSocketWriterDrainResult::WroteFrame),
                    static_cast<int>(writer.drainPendingTextResponse(635)));
  TEST_ASSERT_FALSE(transport.hasPendingTextResponse());
  TEST_ASSERT_EQUAL_UINT32(1, writer.telemetry().framesEncoded);
  TEST_ASSERT_EQUAL_UINT32(1, writer.telemetry().framesWritten);
  TEST_ASSERT_EQUAL_UINT32(1, transport.telemetry().outgoingTextFramesEncoded);
  TEST_ASSERT_GREATER_THAN_UINT32(0, writer.telemetry().bytesWritten);

  char decoded[kBridgeEndpointControlResponseMax] = {};
  TEST_ASSERT_TRUE(decodeMaskedClientTextFrame(sink.bytes, decoded, sizeof(decoded)));
  TEST_ASSERT_NOT_NULL(std::strstr(decoded, "\"type\":\"owner_status\""));
  TEST_ASSERT_NOT_NULL(std::strstr(decoded, "\"active_brain_owner\":\"\""));
}

void test_bridge_socket_writer_retains_partial_frame_until_complete() {
  BridgeClient bridge;
  TEST_ASSERT_TRUE(bridge.begin());
  BridgeEndpointRegistry registry;
  TEST_ASSERT_TRUE(registry.begin());
  BridgeEndpointControl endpointControl;
  TEST_ASSERT_TRUE(endpointControl.begin(registry));
  BridgeWebSocketTransport transport;
  TEST_ASSERT_TRUE(transport.begin(bridge, 640));
  transport.attachEndpointControl(&endpointControl);
  TEST_ASSERT_TRUE(transport.acceptHandshakeResponse(
      "HTTP/1.1 101 Switching Protocols\r\n"
      "Upgrade: websocket\r\n"
      "Connection: Upgrade\r\n"
      "Sec-WebSocket-Accept: ok\r\n"
      "\r\n",
      645));

  const char* status = "{\"type\":\"owner_status\",\"protocol\":\"stackchan.bridge.v1\"}";
  uint8_t serverFrame[160] = {};
  const size_t serverFrameBytes = encodeServerWebSocketText(status, serverFrame, sizeof(serverFrame));
  TEST_ASSERT_TRUE(transport.submitBytes(serverFrame, serverFrameBytes, 650));

  CapturingBridgeSocketSink sink;
  sink.maxWriteBytes = 5;
  BridgeSocketWriter writer;
  TEST_ASSERT_TRUE(writer.begin(transport, sink, 0x33445566));
  TEST_ASSERT_EQUAL(static_cast<int>(BridgeSocketWriterDrainResult::Partial),
                    static_cast<int>(writer.drainPendingTextResponse(655)));
  TEST_ASSERT_FALSE(transport.hasPendingTextResponse());
  TEST_ASSERT_TRUE(writer.telemetry().frameBuffered);
  TEST_ASSERT_EQUAL_UINT32(1, writer.telemetry().framesEncoded);
  TEST_ASSERT_EQUAL_UINT32(0, writer.telemetry().framesWritten);
  TEST_ASSERT_EQUAL_UINT32(1, writer.telemetry().partialWrites);

  BridgeSocketWriterDrainResult result = BridgeSocketWriterDrainResult::Partial;
  for (size_t i = 0; i < 80 && result == BridgeSocketWriterDrainResult::Partial; ++i) {
    result = writer.drainPendingTextResponse(660 + static_cast<uint32_t>(i));
  }
  TEST_ASSERT_EQUAL(static_cast<int>(BridgeSocketWriterDrainResult::WroteFrame), static_cast<int>(result));
  TEST_ASSERT_FALSE(writer.telemetry().frameBuffered);
  TEST_ASSERT_EQUAL_UINT32(1, writer.telemetry().framesWritten);
  TEST_ASSERT_GREATER_THAN_UINT32(1, sink.writes);

  char decoded[kBridgeEndpointControlResponseMax] = {};
  TEST_ASSERT_TRUE(decodeMaskedClientTextFrame(sink.bytes, decoded, sizeof(decoded)));
  TEST_ASSERT_NOT_NULL(std::strstr(decoded, "\"type\":\"owner_status\""));
}

void test_bridge_socket_writer_disconnected_keeps_pending_response() {
  BridgeClient bridge;
  TEST_ASSERT_TRUE(bridge.begin());
  BridgeEndpointRegistry registry;
  TEST_ASSERT_TRUE(registry.begin());
  BridgeEndpointControl endpointControl;
  TEST_ASSERT_TRUE(endpointControl.begin(registry));
  BridgeWebSocketTransport transport;
  TEST_ASSERT_TRUE(transport.begin(bridge, 680));
  transport.attachEndpointControl(&endpointControl);
  TEST_ASSERT_TRUE(transport.acceptHandshakeResponse(
      "HTTP/1.1 101 Switching Protocols\r\n"
      "Upgrade: websocket\r\n"
      "Connection: Upgrade\r\n"
      "Sec-WebSocket-Accept: ok\r\n"
      "\r\n",
      685));

  const char* status = "{\"type\":\"owner_status\",\"protocol\":\"stackchan.bridge.v1\"}";
  uint8_t serverFrame[160] = {};
  const size_t serverFrameBytes = encodeServerWebSocketText(status, serverFrame, sizeof(serverFrame));
  TEST_ASSERT_TRUE(transport.submitBytes(serverFrame, serverFrameBytes, 690));

  CapturingBridgeSocketSink sink;
  sink.connected = false;
  BridgeSocketWriter writer;
  TEST_ASSERT_TRUE(writer.begin(transport, sink, 0x44556677));
  TEST_ASSERT_EQUAL(static_cast<int>(BridgeSocketWriterDrainResult::NotConnected),
                    static_cast<int>(writer.drainPendingTextResponse(695)));
  TEST_ASSERT_TRUE(transport.hasPendingTextResponse());
  TEST_ASSERT_EQUAL_UINT32(0, writer.telemetry().framesEncoded);
  TEST_ASSERT_EQUAL_STRING("socket_not_connected", writer.telemetry().lastError);

  sink.connected = true;
  TEST_ASSERT_EQUAL(static_cast<int>(BridgeSocketWriterDrainResult::WroteFrame),
                    static_cast<int>(writer.drainPendingTextResponse(700)));
  TEST_ASSERT_FALSE(transport.hasPendingTextResponse());
  TEST_ASSERT_EQUAL_UINT32(1, writer.telemetry().framesWritten);
}

BridgeNetworkSessionConfig makeBridgeNetworkSessionConfig() {
  BridgeNetworkSessionConfig config;
  config.enabled = true;
  config.host = "127.0.0.1";
  config.port = 8788;
  config.path = "/bridge";
  config.secWebSocketKey = "dGhlIHNhbXBsZSBub25jZQ==";
  config.handshakeTimeoutMs = 500;
  config.reconnectDelayMs = 100;
  config.readBudgetBytes = 512;
  config.maskSeed = 0x55667788;
  config.bridge.deviceId = "stackchan-test";
  return config;
}

void test_bridge_network_session_starts_and_accepts_handshake() {
  BridgeClient bridge;
  TEST_ASSERT_TRUE(bridge.begin());
  FakeBridgeNetworkSocket socket;
  BridgeNetworkSession session;
  const BridgeNetworkSessionConfig config = makeBridgeNetworkSessionConfig();
  TEST_ASSERT_TRUE(session.begin(bridge, socket, config, 700));
  TEST_ASSERT_TRUE(session.start(705));
  TEST_ASSERT_EQUAL(static_cast<int>(BridgeNetworkSessionState::Handshaking),
                    static_cast<int>(session.telemetry().state));
  TEST_ASSERT_EQUAL_UINT32(1, socket.connectAttempts);
  TEST_ASSERT_EQUAL_STRING("127.0.0.1", socket.lastHost.c_str());
  TEST_ASSERT_EQUAL_UINT16(8788, socket.lastPort);
  TEST_ASSERT_FALSE(socket.outgoing.empty());

  std::string request(reinterpret_cast<const char*>(socket.outgoing.data()), socket.outgoing.size());
  TEST_ASSERT_NOT_NULL(std::strstr(request.c_str(), "GET /bridge HTTP/1.1"));
  TEST_ASSERT_NOT_NULL(std::strstr(request.c_str(), "Host: 127.0.0.1:8788"));
  TEST_ASSERT_NOT_NULL(std::strstr(request.c_str(), "X-Stackchan-Device: stackchan-test"));

  socket.pushIncoming(
      "HTTP/1.1 101 Switching Protocols\r\n"
      "Upgrade: websocket\r\n"
      "Connection: Upgrade\r\n"
      "Sec-WebSocket-Accept: ok\r\n"
      "\r\n");
  session.update(720);
  TEST_ASSERT_EQUAL(static_cast<int>(BridgeNetworkSessionState::Connected),
                    static_cast<int>(session.telemetry().state));
  TEST_ASSERT_EQUAL_UINT32(1, session.telemetry().handshakesSent);
  TEST_ASSERT_EQUAL_UINT32(1, session.telemetry().handshakesAccepted);
  TEST_ASSERT_EQUAL(static_cast<int>(BridgeWebSocketTransportState::Connected),
                    static_cast<int>(session.transport().telemetry().state));
}

void test_bridge_network_session_feeds_server_frames_to_bridge_client() {
  BridgeClient bridge;
  TEST_ASSERT_TRUE(bridge.begin());
  FakeBridgeNetworkSocket socket;
  BridgeNetworkSession session;
  const BridgeNetworkSessionConfig config = makeBridgeNetworkSessionConfig();
  TEST_ASSERT_TRUE(session.begin(bridge, socket, config, 740));
  TEST_ASSERT_TRUE(session.start(745));
  socket.pushIncoming(
      "HTTP/1.1 101 Switching Protocols\r\n"
      "Upgrade: websocket\r\n"
      "Connection: Upgrade\r\n"
      "Sec-WebSocket-Accept: ok\r\n"
      "\r\n");
  session.update(750);
  TEST_ASSERT_EQUAL(static_cast<int>(BridgeNetworkSessionState::Connected),
                    static_cast<int>(session.telemetry().state));

  const char* hello = "{\"type\":\"hello\",\"protocol\":\"stackchan.bridge.v1\",\"session\":\"lan-ok\"}";
  uint8_t frame[160] = {};
  const size_t frameBytes = encodeServerWebSocketText(hello, frame, sizeof(frame));
  socket.pushIncoming(frame, frameBytes);
  session.update(760);

  BridgeClientOutput output;
  TEST_ASSERT_TRUE(bridge.poll(&output));
  TEST_ASSERT_EQUAL(static_cast<int>(BridgeClientOutputType::SessionReady), static_cast<int>(output.type));
  TEST_ASSERT_EQUAL_STRING("lan-ok", output.sessionId);
  TEST_ASSERT_EQUAL_UINT32(1, session.transport().telemetry().textFramesDecoded);
  TEST_ASSERT_GREATER_THAN_UINT32(frameBytes, session.telemetry().bytesRead);
}

void test_bridge_network_session_writes_endpoint_control_response() {
  BridgeClient bridge;
  TEST_ASSERT_TRUE(bridge.begin());
  BridgeEndpointRegistry registry;
  TEST_ASSERT_TRUE(registry.begin());
  BridgeEndpointControl endpointControl;
  TEST_ASSERT_TRUE(endpointControl.begin(registry));
  FakeBridgeNetworkSocket socket;
  BridgeNetworkSession session;
  const BridgeNetworkSessionConfig config = makeBridgeNetworkSessionConfig();
  TEST_ASSERT_TRUE(session.begin(bridge, socket, config, 780));
  session.attachEndpointControl(&endpointControl);
  TEST_ASSERT_TRUE(session.start(785));
  socket.pushIncoming(
      "HTTP/1.1 101 Switching Protocols\r\n"
      "Upgrade: websocket\r\n"
      "Connection: Upgrade\r\n"
      "Sec-WebSocket-Accept: ok\r\n"
      "\r\n");
  session.update(790);
  socket.clearOutgoing();

  const char* status = "{\"type\":\"owner_status\",\"protocol\":\"stackchan.bridge.v1\"}";
  uint8_t frame[160] = {};
  const size_t frameBytes = encodeServerWebSocketText(status, frame, sizeof(frame));
  socket.pushIncoming(frame, frameBytes);
  session.update(800);

  TEST_ASSERT_FALSE(socket.outgoing.empty());
  TEST_ASSERT_EQUAL_UINT32(1, session.telemetry().writerFrames);
  TEST_ASSERT_EQUAL_UINT32(1, session.writer().telemetry().framesWritten);
  TEST_ASSERT_EQUAL_UINT32(1, session.transport().telemetry().endpointControlFrames);
  char decoded[kBridgeEndpointControlResponseMax] = {};
  TEST_ASSERT_TRUE(decodeMaskedClientTextFrame(socket.outgoing, decoded, sizeof(decoded)));
  TEST_ASSERT_NOT_NULL(std::strstr(decoded, "\"type\":\"owner_status\""));
}

void test_bridge_network_session_reconnects_after_socket_disconnect() {
  BridgeClient bridge;
  TEST_ASSERT_TRUE(bridge.begin());
  FakeBridgeNetworkSocket socket;
  BridgeNetworkSession session;
  const BridgeNetworkSessionConfig config = makeBridgeNetworkSessionConfig();
  TEST_ASSERT_TRUE(session.begin(bridge, socket, config, 820));
  TEST_ASSERT_TRUE(session.start(825));
  socket.pushIncoming(
      "HTTP/1.1 101 Switching Protocols\r\n"
      "Upgrade: websocket\r\n"
      "Connection: Upgrade\r\n"
      "Sec-WebSocket-Accept: ok\r\n"
      "\r\n");
  session.update(830);
  TEST_ASSERT_EQUAL(static_cast<int>(BridgeNetworkSessionState::Connected),
                    static_cast<int>(session.telemetry().state));

  socket.connected = false;
  session.update(840);
  TEST_ASSERT_EQUAL(static_cast<int>(BridgeNetworkSessionState::Backoff),
                    static_cast<int>(session.telemetry().state));
  TEST_ASSERT_EQUAL_UINT32(1, session.telemetry().socketDisconnects);
  TEST_ASSERT_EQUAL_STRING("socket_disconnected", session.telemetry().lastError);

  session.update(950);
  TEST_ASSERT_EQUAL_UINT32(2, socket.connectAttempts);
  TEST_ASSERT_EQUAL(static_cast<int>(BridgeNetworkSessionState::Handshaking),
                    static_cast<int>(session.telemetry().state));
}

BridgeEndpointRecord makeBridgeEndpoint(const char* id,
                                        BridgeEndpointKind kind,
                                        uint8_t priority,
                                        bool autoConnect = true,
                                        uint32_t capabilities = BridgeEndpointCapabilityStt |
                                                                BridgeEndpointCapabilityLlm |
                                                                BridgeEndpointCapabilityTts) {
  BridgeEndpointRecord endpoint;
  std::strncpy(endpoint.endpointId, id, sizeof(endpoint.endpointId) - 1);
  std::snprintf(endpoint.endpointName, sizeof(endpoint.endpointName), "%s-name", id);
  std::snprintf(endpoint.publicKeyFingerprint,
                sizeof(endpoint.publicKeyFingerprint),
                "sha256:%s",
                id);
  endpoint.kind = kind;
  endpoint.priority = priority;
  endpoint.autoConnect = autoConnect;
  endpoint.capabilities = capabilities;
  return endpoint;
}

void test_bridge_endpoint_registry_upserts_and_bounds_trusted_endpoints() {
  BridgeEndpointRegistry registry;
  TEST_ASSERT_TRUE(registry.begin());

  BridgeEndpointRecord pc = makeBridgeEndpoint("pc-studio-01", BridgeEndpointKind::Pc, 80);
  TEST_ASSERT_TRUE(registry.upsertEndpoint(pc, 100));
  TEST_ASSERT_EQUAL_UINT32(1, registry.count());
  TEST_ASSERT_TRUE(registry.isTrusted("pc-studio-01"));
  TEST_ASSERT_EQUAL_UINT8(1, registry.telemetry().trustedCount);

  pc.priority = 90;
  std::strncpy(pc.endpointName, "Studio PC Updated", sizeof(pc.endpointName) - 1);
  TEST_ASSERT_TRUE(registry.upsertEndpoint(pc, 120));
  TEST_ASSERT_EQUAL_UINT32(1, registry.count());
  const BridgeEndpointRecord* updated = registry.findEndpoint("pc-studio-01");
  TEST_ASSERT_NOT_NULL(updated);
  TEST_ASSERT_EQUAL_UINT8(90, updated->priority);
  TEST_ASSERT_EQUAL_STRING("Studio PC Updated", updated->endpointName);

  const char* ids[] = {
      "phone-rob-01",
      "dev-01",
      "dev-02",
      "dev-03",
      "dev-04",
      "dev-05",
      "dev-06",
  };
  for (size_t i = 0; i < sizeof(ids) / sizeof(ids[0]); ++i) {
    TEST_ASSERT_TRUE(registry.upsertEndpoint(
        makeBridgeEndpoint(ids[i], BridgeEndpointKind::Dev, static_cast<uint8_t>(10 + i)),
        130 + static_cast<uint32_t>(i)));
  }
  TEST_ASSERT_EQUAL_UINT32(kBridgeEndpointMax, registry.count());
  TEST_ASSERT_FALSE(registry.upsertEndpoint(makeBridgeEndpoint("overflow", BridgeEndpointKind::Dev, 1), 200));
  TEST_ASSERT_EQUAL_UINT32(1, registry.telemetry().rejected);
  TEST_ASSERT_EQUAL_UINT32(kBridgeEndpointMax, registry.count());
}

void test_bridge_endpoint_registry_explicit_claim_overrides_current_owner() {
  BridgeEndpointRegistry registry;
  TEST_ASSERT_TRUE(registry.begin());
  TEST_ASSERT_TRUE(registry.upsertEndpoint(makeBridgeEndpoint("pc-studio-01", BridgeEndpointKind::Pc, 80), 100));
  TEST_ASSERT_TRUE(registry.upsertEndpoint(makeBridgeEndpoint("phone-rob-01", BridgeEndpointKind::Android, 60), 110));

  registry.update(120);
  TEST_ASSERT_TRUE(registry.isActiveOwner("pc-studio-01"));

  TEST_ASSERT_TRUE(registry.claimOwner("phone-rob-01", 130, true));
  TEST_ASSERT_TRUE(registry.isActiveOwner("phone-rob-01"));
  registry.update(200);
  TEST_ASSERT_TRUE(registry.isActiveOwner("phone-rob-01"));
  TEST_ASSERT_EQUAL_UINT32(1, registry.telemetry().explicitClaims);
  TEST_ASSERT_EQUAL_UINT32(2, registry.telemetry().ownerChanges);
}

void test_bridge_endpoint_registry_timeout_promotes_highest_priority_healthy_endpoint() {
  BridgeEndpointRegistryConfig config;
  config.ownerHeartbeatTimeoutMs = 100;
  BridgeEndpointRegistry registry;
  TEST_ASSERT_TRUE(registry.begin(config));
  TEST_ASSERT_TRUE(registry.upsertEndpoint(makeBridgeEndpoint("pc-studio-01", BridgeEndpointKind::Pc, 80), 100));
  TEST_ASSERT_TRUE(registry.upsertEndpoint(makeBridgeEndpoint("phone-rob-01", BridgeEndpointKind::Android, 60), 110));
  TEST_ASSERT_TRUE(registry.claimOwner("phone-rob-01", 120, true));
  TEST_ASSERT_TRUE(registry.markHeartbeat("pc-studio-01", 180));

  registry.update(221);
  TEST_ASSERT_TRUE(registry.isActiveOwner("pc-studio-01"));
  TEST_ASSERT_EQUAL_UINT32(1, registry.telemetry().ownerExpirations);
  TEST_ASSERT_EQUAL_UINT32(3, registry.telemetry().ownerChanges);
}

void test_bridge_endpoint_registry_tie_breaks_by_recent_seen() {
  BridgeEndpointRegistry registry;
  TEST_ASSERT_TRUE(registry.begin());
  TEST_ASSERT_TRUE(registry.upsertEndpoint(makeBridgeEndpoint("pc-studio-01", BridgeEndpointKind::Pc, 70), 100));
  TEST_ASSERT_TRUE(registry.upsertEndpoint(makeBridgeEndpoint("phone-rob-01", BridgeEndpointKind::Android, 70), 200));

  registry.update(210);
  TEST_ASSERT_TRUE(registry.isActiveOwner("phone-rob-01"));
}

void test_bridge_endpoint_registry_forget_active_owner_promotes_next_endpoint() {
  BridgeEndpointRegistry registry;
  TEST_ASSERT_TRUE(registry.begin());
  TEST_ASSERT_TRUE(registry.upsertEndpoint(makeBridgeEndpoint("pc-studio-01", BridgeEndpointKind::Pc, 80), 100));
  TEST_ASSERT_TRUE(registry.upsertEndpoint(makeBridgeEndpoint("phone-rob-01", BridgeEndpointKind::Android, 60), 120));
  TEST_ASSERT_TRUE(registry.claimOwner("phone-rob-01", 130, true));
  TEST_ASSERT_TRUE(registry.markHeartbeat("pc-studio-01", 135));

  TEST_ASSERT_TRUE(registry.forgetEndpoint("phone-rob-01", 140));
  TEST_ASSERT_FALSE(registry.isTrusted("phone-rob-01"));
  TEST_ASSERT_EQUAL_UINT32(1, registry.count());
  TEST_ASSERT_TRUE(registry.isActiveOwner("pc-studio-01"));
  TEST_ASSERT_EQUAL_UINT32(1, registry.telemetry().forgotten);
  TEST_ASSERT_EQUAL_UINT32(1, registry.telemetry().releases);
}

void test_bridge_endpoint_registry_disconnect_active_owner_promotes_next_endpoint() {
  BridgeEndpointRegistry registry;
  TEST_ASSERT_TRUE(registry.begin());
  TEST_ASSERT_TRUE(registry.upsertEndpoint(makeBridgeEndpoint("pc-studio-01", BridgeEndpointKind::Pc, 80), 100));
  TEST_ASSERT_TRUE(registry.upsertEndpoint(makeBridgeEndpoint("phone-rob-01", BridgeEndpointKind::Android, 60), 120));
  TEST_ASSERT_TRUE(registry.claimOwner("pc-studio-01", 130, true));
  TEST_ASSERT_TRUE(registry.markHeartbeat("phone-rob-01", 135));

  TEST_ASSERT_TRUE(registry.markDisconnected("pc-studio-01", 150));
  TEST_ASSERT_TRUE(registry.isActiveOwner("phone-rob-01"));
  TEST_ASSERT_EQUAL_UINT32(1, registry.telemetry().releases);
  TEST_ASSERT_EQUAL_UINT32(3, registry.telemetry().ownerChanges);
}

void test_bridge_endpoint_registry_auto_connect_false_waits_for_explicit_claim() {
  BridgeEndpointRegistry registry;
  TEST_ASSERT_TRUE(registry.begin());
  TEST_ASSERT_TRUE(registry.upsertEndpoint(
      makeBridgeEndpoint("pc-studio-01", BridgeEndpointKind::Pc, 90, false),
      100));
  TEST_ASSERT_TRUE(registry.upsertEndpoint(makeBridgeEndpoint("phone-rob-01", BridgeEndpointKind::Android, 60), 110));

  registry.update(120);
  TEST_ASSERT_TRUE(registry.isActiveOwner("phone-rob-01"));

  TEST_ASSERT_TRUE(registry.claimOwner("pc-studio-01", 130, true));
  TEST_ASSERT_TRUE(registry.isActiveOwner("pc-studio-01"));
  TEST_ASSERT_TRUE(registry.updateCapabilities("pc-studio-01",
                                               BridgeEndpointCapabilitySettings |
                                                   BridgeEndpointCapabilityAudioDownlink,
                                               140));
  const BridgeEndpointRecord* owner = registry.activeOwner();
  TEST_ASSERT_NOT_NULL(owner);
  TEST_ASSERT_EQUAL_UINT32(BridgeEndpointCapabilitySettings | BridgeEndpointCapabilityAudioDownlink,
                           owner->capabilities);
}

bool bridgeEndpointControlSubmit(BridgeEndpointControl& control,
                                 const char* line,
                                 char* response,
                                 uint32_t nowMs,
                                 BridgeEndpointControlResult expected) {
  const BridgeEndpointControlResult result =
      control.submitControlLine(line, response, kBridgeEndpointControlResponseMax, nowMs);
  TEST_ASSERT_EQUAL_INT(static_cast<int>(expected), static_cast<int>(result));
  return result == expected;
}

void test_bridge_endpoint_control_registers_endpoint_and_returns_result() {
  BridgeEndpointRegistry registry;
  TEST_ASSERT_TRUE(registry.begin());
  BridgeEndpointControl control;
  TEST_ASSERT_TRUE(control.begin(registry));

  char response[kBridgeEndpointControlResponseMax] = {};
  TEST_ASSERT_TRUE(bridgeEndpointControlSubmit(
      control,
      "{\"type\":\"endpoint_hello\",\"protocol\":\"stackchan.bridge.v1\","
      "\"endpoint_id\":\"phone-rob-01\",\"endpoint_name\":\"Rob's Phone\","
      "\"endpoint_kind\":\"android\",\"priority\":60,\"supports_binary_audio\":true,"
      "\"capabilities\":[\"settings\",\"llm\",\"tts\",\"settings\",\"diagnostics\"]}",
      response,
      100,
      BridgeEndpointControlResult::Handled));

  TEST_ASSERT_NOT_NULL(std::strstr(response, "\"type\":\"endpoint_hello_result\""));
  TEST_ASSERT_NOT_NULL(std::strstr(response, "\"endpoint_id\":\"phone-rob-01\""));
  TEST_ASSERT_NOT_NULL(std::strstr(response, "\"trusted\":true"));
  TEST_ASSERT_NOT_NULL(std::strstr(response, "\"active_brain_owner\":\"phone-rob-01\""));
  TEST_ASSERT_NOT_NULL(std::strstr(response, "\"audio_downlink\""));
  TEST_ASSERT_TRUE(registry.isTrusted("phone-rob-01"));
  TEST_ASSERT_TRUE(registry.isActiveOwner("phone-rob-01"));
  const BridgeEndpointRecord* endpoint = registry.findEndpoint("phone-rob-01");
  TEST_ASSERT_NOT_NULL(endpoint);
  TEST_ASSERT_EQUAL_UINT32(BridgeEndpointCapabilitySettings |
                               BridgeEndpointCapabilityLlm |
                               BridgeEndpointCapabilityTts |
                               BridgeEndpointCapabilityAudioDownlink |
                               BridgeEndpointCapabilityDiagnostics,
                           endpoint->capabilities);
  TEST_ASSERT_EQUAL_UINT32(1, control.telemetry().endpointHellos);
}

void test_bridge_endpoint_control_claim_and_release_handoff() {
  BridgeEndpointRegistry registry;
  TEST_ASSERT_TRUE(registry.begin());
  BridgeEndpointControl control;
  TEST_ASSERT_TRUE(control.begin(registry));
  char response[kBridgeEndpointControlResponseMax] = {};

  TEST_ASSERT_TRUE(bridgeEndpointControlSubmit(
      control,
      "{\"type\":\"endpoint_hello\",\"endpoint_id\":\"pc-studio-01\","
      "\"endpoint_kind\":\"pc\",\"priority\":80,\"capabilities\":[\"settings\",\"stt\",\"llm\",\"tts\"]}",
      response,
      100,
      BridgeEndpointControlResult::Handled));
  TEST_ASSERT_TRUE(bridgeEndpointControlSubmit(
      control,
      "{\"type\":\"endpoint_hello\",\"endpoint_id\":\"phone-rob-01\","
      "\"endpoint_kind\":\"android\",\"priority\":60,\"capabilities\":[\"settings\",\"llm\",\"tts\"]}",
      response,
      120,
      BridgeEndpointControlResult::Handled));
  TEST_ASSERT_TRUE(registry.isActiveOwner("pc-studio-01"));

  TEST_ASSERT_TRUE(bridgeEndpointControlSubmit(
      control,
      "{\"type\":\"claim_brain\",\"endpoint_id\":\"phone-rob-01\",\"reason\":\"user_selected\"}",
      response,
      140,
      BridgeEndpointControlResult::Handled));
  TEST_ASSERT_NOT_NULL(std::strstr(response, "\"type\":\"owner_status\""));
  TEST_ASSERT_NOT_NULL(std::strstr(response, "\"active_brain_owner\":\"phone-rob-01\""));
  TEST_ASSERT_TRUE(registry.isActiveOwner("phone-rob-01"));

  TEST_ASSERT_TRUE(bridgeEndpointControlSubmit(
      control,
      "{\"type\":\"release_brain\",\"endpoint_id\":\"pc-studio-01\"}",
      response,
      150,
      BridgeEndpointControlResult::Rejected));
  TEST_ASSERT_NOT_NULL(std::strstr(response, "\"code\":\"brain_owner_mismatch\""));
  TEST_ASSERT_TRUE(registry.isActiveOwner("phone-rob-01"));

  TEST_ASSERT_TRUE(bridgeEndpointControlSubmit(
      control,
      "{\"type\":\"release_brain\",\"endpoint_id\":\"phone-rob-01\",\"reason\":\"handoff_to_pc\"}",
      response,
      170,
      BridgeEndpointControlResult::Handled));
  TEST_ASSERT_NOT_NULL(std::strstr(response, "\"active_brain_owner\":\"pc-studio-01\""));
  TEST_ASSERT_TRUE(registry.isActiveOwner("pc-studio-01"));
  TEST_ASSERT_EQUAL_UINT32(1, control.telemetry().ownerClaims);
  TEST_ASSERT_EQUAL_UINT32(1, control.telemetry().ownerReleases);
}

void test_bridge_endpoint_control_heartbeat_handles_endpoint_only() {
  BridgeEndpointRegistry registry;
  TEST_ASSERT_TRUE(registry.begin());
  BridgeEndpointControl control;
  TEST_ASSERT_TRUE(control.begin(registry));
  char response[kBridgeEndpointControlResponseMax] = {};

  TEST_ASSERT_TRUE(bridgeEndpointControlSubmit(
      control,
      "{\"type\":\"heartbeat\"}",
      response,
      100,
      BridgeEndpointControlResult::Ignored));
  TEST_ASSERT_EQUAL_STRING("", response);

  TEST_ASSERT_TRUE(registry.upsertEndpoint(makeBridgeEndpoint("pc-studio-01", BridgeEndpointKind::Pc, 80), 110));
  TEST_ASSERT_TRUE(bridgeEndpointControlSubmit(
      control,
      "{\"type\":\"heartbeat\",\"endpoint_id\":\"pc-studio-01\"}",
      response,
      150,
      BridgeEndpointControlResult::Handled));
  TEST_ASSERT_NOT_NULL(std::strstr(response, "\"type\":\"heartbeat\""));
  TEST_ASSERT_NOT_NULL(std::strstr(response, "\"endpoint_id\":\"pc-studio-01\""));
  const BridgeEndpointRecord* endpoint = registry.findEndpoint("pc-studio-01");
  TEST_ASSERT_NOT_NULL(endpoint);
  TEST_ASSERT_EQUAL_UINT32(150, endpoint->lastHeartbeatMs);
  TEST_ASSERT_EQUAL_UINT32(1, control.telemetry().heartbeats);
  TEST_ASSERT_EQUAL_UINT32(1, control.telemetry().ignoredMessages);
}

void test_bridge_endpoint_control_lists_and_forgets_endpoints() {
  BridgeEndpointRegistry registry;
  TEST_ASSERT_TRUE(registry.begin());
  BridgeEndpointControl control;
  TEST_ASSERT_TRUE(control.begin(registry));
  char response[kBridgeEndpointControlResponseMax] = {};

  TEST_ASSERT_TRUE(bridgeEndpointControlSubmit(
      control,
      "{\"type\":\"endpoint_hello\",\"endpoint_id\":\"pc-studio-01\","
      "\"endpoint_name\":\"Studio PC\",\"endpoint_kind\":\"pc\",\"priority\":80,"
      "\"capabilities\":[\"settings\",\"llm\"]}",
      response,
      100,
      BridgeEndpointControlResult::Handled));
  TEST_ASSERT_TRUE(bridgeEndpointControlSubmit(
      control,
      "{\"type\":\"endpoint_hello\",\"endpoint_id\":\"phone-rob-01\","
      "\"endpoint_name\":\"Rob Phone\",\"endpoint_kind\":\"android\",\"priority\":60,"
      "\"capabilities\":[\"settings\"]}",
      response,
      110,
      BridgeEndpointControlResult::Handled));

  TEST_ASSERT_TRUE(bridgeEndpointControlSubmit(
      control,
      "{\"type\":\"trusted_endpoints\"}",
      response,
      120,
      BridgeEndpointControlResult::Handled));
  TEST_ASSERT_NOT_NULL(std::strstr(response, "\"type\":\"trusted_endpoints_result\""));
  TEST_ASSERT_NOT_NULL(std::strstr(response, "\"endpoint_id\":\"pc-studio-01\""));
  TEST_ASSERT_NOT_NULL(std::strstr(response, "\"endpoint_id\":\"phone-rob-01\""));

  TEST_ASSERT_TRUE(bridgeEndpointControlSubmit(
      control,
      "{\"type\":\"forget_endpoint\",\"endpoint_id\":\"pc-studio-01\"}",
      response,
      130,
      BridgeEndpointControlResult::Handled));
  TEST_ASSERT_NOT_NULL(std::strstr(response, "\"type\":\"forget_endpoint_result\""));
  TEST_ASSERT_NOT_NULL(std::strstr(response, "\"ok\":true"));
  TEST_ASSERT_NOT_NULL(std::strstr(response, "\"active_brain_owner\":\"phone-rob-01\""));
  TEST_ASSERT_FALSE(registry.isTrusted("pc-studio-01"));
  TEST_ASSERT_TRUE(registry.isActiveOwner("phone-rob-01"));
  TEST_ASSERT_EQUAL_UINT32(1, control.telemetry().forgotten);
}

void test_bridge_endpoint_control_updates_capabilities() {
  BridgeEndpointRegistry registry;
  TEST_ASSERT_TRUE(registry.begin());
  BridgeEndpointControl control;
  TEST_ASSERT_TRUE(control.begin(registry));
  char response[kBridgeEndpointControlResponseMax] = {};

  TEST_ASSERT_TRUE(bridgeEndpointControlSubmit(
      control,
      "{\"type\":\"endpoint_hello\",\"endpoint_id\":\"phone-rob-01\","
      "\"endpoint_kind\":\"android\",\"priority\":60,\"capabilities\":[\"settings\"]}",
      response,
      100,
      BridgeEndpointControlResult::Handled));
  TEST_ASSERT_TRUE(bridgeEndpointControlSubmit(
      control,
      "{\"type\":\"capability_update\",\"endpoint_id\":\"phone-rob-01\","
      "\"capabilities\":[\"settings\",\"model_profiles\",\"diagnostics\",\"pcm16_upload\",\"unknown\"]}",
      response,
      130,
      BridgeEndpointControlResult::Handled));
  TEST_ASSERT_NOT_NULL(std::strstr(response, "\"type\":\"capability_update_result\""));
  TEST_ASSERT_NOT_NULL(std::strstr(response, "\"model_profiles\""));
  TEST_ASSERT_NOT_NULL(std::strstr(response, "\"diagnostics\""));
  TEST_ASSERT_NOT_NULL(std::strstr(response, "\"pcm16_upload\""));
  TEST_ASSERT_NULL(std::strstr(response, "\"unknown\""));
  const BridgeEndpointRecord* endpoint = registry.findEndpoint("phone-rob-01");
  TEST_ASSERT_NOT_NULL(endpoint);
  TEST_ASSERT_EQUAL_UINT32(BridgeEndpointCapabilitySettings |
                               BridgeEndpointCapabilityModelProfiles |
                               BridgeEndpointCapabilityDiagnostics |
                               BridgeEndpointCapabilityPcm16Upload,
                           endpoint->capabilities);
  TEST_ASSERT_EQUAL_UINT32(1, control.telemetry().capabilityUpdates);
}

void test_bridge_endpoint_control_rejects_bad_endpoint_frames_and_ignores_bridge_frames() {
  BridgeEndpointRegistry registry;
  TEST_ASSERT_TRUE(registry.begin());
  BridgeEndpointControl control;
  TEST_ASSERT_TRUE(control.begin(registry));
  char response[kBridgeEndpointControlResponseMax] = {};

  TEST_ASSERT_TRUE(bridgeEndpointControlSubmit(
      control,
      "{\"type\":\"hello\",\"protocol\":\"stackchan.bridge.v1\"}",
      response,
      100,
      BridgeEndpointControlResult::Ignored));
  TEST_ASSERT_EQUAL_STRING("", response);

  TEST_ASSERT_TRUE(bridgeEndpointControlSubmit(
      control,
      "{\"type\":\"endpoint_hello\",\"protocol\":\"wrong\",\"endpoint_id\":\"pc-studio-01\"}",
      response,
      110,
      BridgeEndpointControlResult::Rejected));
  TEST_ASSERT_NOT_NULL(std::strstr(response, "\"code\":\"protocol_mismatch\""));

  TEST_ASSERT_TRUE(bridgeEndpointControlSubmit(
      control,
      "{\"type\":\"endpoint_hello\"",
      response,
      120,
      BridgeEndpointControlResult::Rejected));
  TEST_ASSERT_NOT_NULL(std::strstr(response, "\"code\":\"malformed_json\""));
  TEST_ASSERT_FALSE(registry.isTrusted("pc-studio-01"));
  TEST_ASSERT_EQUAL_UINT32(1, control.telemetry().ignoredMessages);
  TEST_ASSERT_EQUAL_UINT32(2, control.telemetry().rejectedMessages);
}

void test_bridge_endpoint_registry_restore_keeps_endpoint_unhealthy_until_heartbeat() {
  BridgeEndpointRegistry registry;
  TEST_ASSERT_TRUE(registry.begin());

  BridgeEndpointRecord restored = makeBridgeEndpoint("pc-studio-01", BridgeEndpointKind::Pc, 80);
  restored.lastSeenMs = 222;
  TEST_ASSERT_TRUE(registry.restoreEndpoint(restored, 1000));
  TEST_ASSERT_TRUE(registry.isTrusted("pc-studio-01"));
  TEST_ASSERT_NULL(registry.activeOwner());
  const BridgeEndpointRecord* endpoint = registry.findEndpoint("pc-studio-01");
  TEST_ASSERT_NOT_NULL(endpoint);
  TEST_ASSERT_EQUAL_UINT32(222, endpoint->lastSeenMs);
  TEST_ASSERT_EQUAL_UINT32(0, endpoint->lastHeartbeatMs);
  TEST_ASSERT_EQUAL_UINT32(1, registry.telemetry().restores);

  registry.update(1100);
  TEST_ASSERT_NULL(registry.activeOwner());
  TEST_ASSERT_TRUE(registry.markHeartbeat("pc-studio-01", 1200));
  registry.update(1201);
  TEST_ASSERT_TRUE(registry.isActiveOwner("pc-studio-01"));
}

void test_bridge_endpoint_store_saves_and_loads_trusted_endpoints_without_owner() {
  BridgeEndpointRegistry source;
  TEST_ASSERT_TRUE(source.begin());
  TEST_ASSERT_TRUE(source.upsertEndpoint(makeBridgeEndpoint("pc-studio-01", BridgeEndpointKind::Pc, 80), 100));
  BridgeEndpointRecord phone = makeBridgeEndpoint("phone-rob-01",
                                                  BridgeEndpointKind::Android,
                                                  60,
                                                  false,
                                                  BridgeEndpointCapabilitySettings |
                                                      BridgeEndpointCapabilityModelProfiles);
  std::strncpy(phone.endpointName, "Rob Phone", sizeof(phone.endpointName) - 1);
  TEST_ASSERT_TRUE(source.upsertEndpoint(phone, 120));
  TEST_ASSERT_TRUE(source.claimOwner("phone-rob-01", 130, true));

  BridgeEndpointMemoryStore backend;
  BridgeEndpointStore store;
  TEST_ASSERT_TRUE(store.begin(backend));
  TEST_ASSERT_TRUE(store.save(source, 140));
  TEST_ASSERT_NOT_NULL(std::strstr(backend.value(), "\"schema\":\"stackchan.bridge-endpoints.v1\""));
  TEST_ASSERT_NOT_NULL(std::strstr(backend.value(), "\"endpoint_id\":\"pc-studio-01\""));
  TEST_ASSERT_NOT_NULL(std::strstr(backend.value(), "\"endpoint_id\":\"phone-rob-01\""));
  TEST_ASSERT_NOT_NULL(std::strstr(backend.value(), "\"auto_connect\":false"));

  BridgeEndpointRegistry restored;
  TEST_ASSERT_TRUE(restored.begin());
  TEST_ASSERT_TRUE(store.load(restored, 1000));
  TEST_ASSERT_EQUAL_UINT32(2, restored.count());
  TEST_ASSERT_TRUE(restored.isTrusted("pc-studio-01"));
  TEST_ASSERT_TRUE(restored.isTrusted("phone-rob-01"));
  TEST_ASSERT_NULL(restored.activeOwner());
  const BridgeEndpointRecord* restoredPhone = restored.findEndpoint("phone-rob-01");
  TEST_ASSERT_NOT_NULL(restoredPhone);
  TEST_ASSERT_EQUAL_STRING("Rob Phone", restoredPhone->endpointName);
  TEST_ASSERT_EQUAL_UINT8(60, restoredPhone->priority);
  TEST_ASSERT_FALSE(restoredPhone->autoConnect);
  TEST_ASSERT_EQUAL_UINT32(BridgeEndpointCapabilitySettings |
                               BridgeEndpointCapabilityModelProfiles,
                           restoredPhone->capabilities);
  TEST_ASSERT_EQUAL_UINT32(2, store.telemetry().endpointsLoaded);
  TEST_ASSERT_EQUAL_UINT32(2, restored.telemetry().restores);
}

void test_bridge_endpoint_store_clear_removes_persisted_registry() {
  BridgeEndpointRegistry registry;
  TEST_ASSERT_TRUE(registry.begin());
  TEST_ASSERT_TRUE(registry.upsertEndpoint(makeBridgeEndpoint("pc-studio-01", BridgeEndpointKind::Pc, 80), 100));

  BridgeEndpointMemoryStore backend;
  BridgeEndpointStore store;
  TEST_ASSERT_TRUE(store.begin(backend));
  TEST_ASSERT_TRUE(store.save(registry, 110));
  TEST_ASSERT_TRUE(std::strlen(backend.value()) > 0);
  TEST_ASSERT_TRUE(store.clear(120));
  TEST_ASSERT_EQUAL_STRING("", backend.value());

  BridgeEndpointRegistry empty;
  TEST_ASSERT_TRUE(empty.begin());
  TEST_ASSERT_TRUE(store.load(empty, 130));
  TEST_ASSERT_EQUAL_UINT32(0, empty.count());
  TEST_ASSERT_EQUAL_UINT32(1, store.telemetry().clears);
}

void test_bridge_endpoint_store_rejects_malformed_or_wrong_schema_payloads() {
  BridgeEndpointMemoryStore backend;
  BridgeEndpointStore store;
  TEST_ASSERT_TRUE(store.begin(backend));
  TEST_ASSERT_TRUE(backend.write("{\"schema\":\"wrong\",\"endpoints\":[]}"));

  BridgeEndpointRegistry registry;
  TEST_ASSERT_TRUE(registry.begin());
  TEST_ASSERT_FALSE(store.load(registry, 100));
  TEST_ASSERT_EQUAL_UINT32(1, store.telemetry().parseErrors);
  TEST_ASSERT_EQUAL_UINT32(0, registry.count());

  TEST_ASSERT_TRUE(backend.write("{\"schema\":\"stackchan.bridge-endpoints.v1\",\"endpoints\":[{}]}"));
  TEST_ASSERT_FALSE(store.load(registry, 110));
  TEST_ASSERT_EQUAL_UINT32(2, store.telemetry().parseErrors);
  TEST_ASSERT_EQUAL_UINT32(0, registry.count());
}

void test_bridge_endpoint_control_persists_pairing_and_forget_when_store_attached() {
  BridgeEndpointRegistry registry;
  TEST_ASSERT_TRUE(registry.begin());
  BridgeEndpointMemoryStore backend;
  BridgeEndpointStore store;
  TEST_ASSERT_TRUE(store.begin(backend));
  BridgeEndpointControl control;
  TEST_ASSERT_TRUE(control.begin(registry));
  control.attachStore(&store);
  char response[kBridgeEndpointControlResponseMax] = {};

  TEST_ASSERT_TRUE(bridgeEndpointControlSubmit(
      control,
      "{\"type\":\"endpoint_hello\",\"endpoint_id\":\"phone-rob-01\","
      "\"endpoint_kind\":\"android\",\"priority\":60,\"capabilities\":[\"settings\"]}",
      response,
      100,
      BridgeEndpointControlResult::Handled));
  TEST_ASSERT_NOT_NULL(std::strstr(backend.value(), "\"endpoint_id\":\"phone-rob-01\""));
  TEST_ASSERT_EQUAL_UINT32(1, control.telemetry().persistenceSaves);
  TEST_ASSERT_EQUAL_UINT32(1, store.telemetry().saves);

  TEST_ASSERT_TRUE(bridgeEndpointControlSubmit(
      control,
      "{\"type\":\"capability_update\",\"endpoint_id\":\"phone-rob-01\","
      "\"capabilities\":[\"settings\",\"diagnostics\"]}",
      response,
      120,
      BridgeEndpointControlResult::Handled));
  TEST_ASSERT_NOT_NULL(std::strstr(backend.value(), "\"capabilities\":"));
  TEST_ASSERT_EQUAL_UINT32(2, control.telemetry().persistenceSaves);

  TEST_ASSERT_TRUE(bridgeEndpointControlSubmit(
      control,
      "{\"type\":\"forget_endpoint\",\"endpoint_id\":\"phone-rob-01\"}",
      response,
      140,
      BridgeEndpointControlResult::Handled));
  TEST_ASSERT_NULL(std::strstr(backend.value(), "\"endpoint_id\":\"phone-rob-01\""));
  TEST_ASSERT_NOT_NULL(std::strstr(backend.value(), "\"count\":0"));
  TEST_ASSERT_EQUAL_UINT32(3, control.telemetry().persistenceSaves);
  TEST_ASSERT_EQUAL_UINT32(3, store.telemetry().saves);
}

int main() {
  UNITY_BEGIN();
  RUN_TEST(test_spring_converges_without_exploding);
  RUN_TEST(test_dt_clamp_limits_large_step);
  RUN_TEST(test_wake_word_increases_arousal_and_focus);
  RUN_TEST(test_ambient_dark_night_increases_fatigue);
  RUN_TEST(test_ambient_bright_day_reduces_fatigue_and_lifts_arousal);
  RUN_TEST(test_circadian_evening_raises_fatigue_and_morning_recovers);
  RUN_TEST(test_physical_events_shape_emotion);
  RUN_TEST(test_audio_events_shape_attention_and_startle);
  RUN_TEST(test_mood_decay_returns_toward_baseline);
  RUN_TEST(test_audio_saliency_detects_speech_direction_and_habituation);
  RUN_TEST(test_audio_saliency_marks_loud_noise_without_speech_band);
  RUN_TEST(test_audio_saliency_uses_wav_fixtures_for_vad_and_direction);
  RUN_TEST(test_audio_reflex_maps_saliency_to_persona_events);
  RUN_TEST(test_audio_reflex_loud_noise_preempts_speech_events);
  RUN_TEST(test_positive_valence_smiles);
  RUN_TEST(test_sleep_mode_closes_eyes_and_mouth);
  RUN_TEST(test_expression_mapper_sets_brow_tilt_direction);
  RUN_TEST(test_persona_expression_codegen_exposes_pose_targets);
  RUN_TEST(test_expression_mapper_uses_persona_expression_defaults);
  RUN_TEST(test_face_animator_outback_overshoots_then_settles);
  RUN_TEST(test_face_animator_smooths_channels_with_independent_timing);
  RUN_TEST(test_face_animator_uses_mode_authored_pose_keys);
  RUN_TEST(test_face_animator_autonomic_layer_adds_life_over_time);
  RUN_TEST(test_face_animator_uses_persona_behavior_breathing_amplitude);
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
  RUN_TEST(test_intent_engine_demo_can_be_disabled_and_resumed);
  RUN_TEST(test_idle_life_breathing_moves_face_and_body_together);
  RUN_TEST(test_persona_behavior_codegen_exposes_idle_life_tuning);
  RUN_TEST(test_idle_life_reduced_motion_dampens_offsets);
  RUN_TEST(test_idle_life_micro_expression_is_deterministic);
  RUN_TEST(test_idle_life_yawn_uses_fatigue_and_reduced_motion);
  RUN_TEST(test_intent_engine_reduced_motion_dampens_idle_life);
  RUN_TEST(test_intent_engine_applies_ambient_context);
  RUN_TEST(test_intent_engine_applies_circadian_context);
  RUN_TEST(test_intent_engine_orients_toward_sound_event);
  RUN_TEST(test_gaze_tracker_uses_face_payload_for_eye_and_head_tracking);
  RUN_TEST(test_gaze_tracker_reduced_motion_dampens_face_tracking);
  RUN_TEST(test_gaze_tracker_face_lost_holds_then_decays_last_seen_direction);
  RUN_TEST(test_intent_engine_tracks_face_position_payload);
  RUN_TEST(test_camera_adapter_publishes_clamped_face_detection);
  RUN_TEST(test_camera_adapter_publishes_face_lost_event);
  RUN_TEST(test_command_map_maps_multinet_phrase_ids_to_existing_actions);
  RUN_TEST(test_command_map_accepts_bench_tokens_matching_yaml_keys);
  RUN_TEST(test_intent_engine_prioritizes_explicit_command_speech_cue);
  RUN_TEST(test_sensor_adapter_parses_serial_mode_command);
  RUN_TEST(test_sensor_adapter_parses_help_without_event);
  RUN_TEST(test_sensor_adapter_parses_status_without_event);
  RUN_TEST(test_sensor_adapter_parses_event_aliases_and_clamps_strength);
  RUN_TEST(test_sensor_adapter_parses_speech_envelope_command);
  RUN_TEST(test_sensor_adapter_parses_speech_clear_and_rejects_unknown_viseme);
  RUN_TEST(test_sensor_adapter_parses_ambient_context_commands);
  RUN_TEST(test_sensor_adapter_parses_circadian_context_commands);
  RUN_TEST(test_sensor_adapter_parses_face_tracking_commands);
  RUN_TEST(test_sensor_adapter_parses_spoken_command_bench_events);
  RUN_TEST(test_sensor_adapter_parses_direct_speech_intent_cues);
  RUN_TEST(test_sensor_adapter_parses_bridge_conversation_commands);
  RUN_TEST(test_sensor_adapter_parses_audio_awareness_commands);
  RUN_TEST(test_sensor_adapter_parses_physical_sense_commands);
  RUN_TEST(test_sensor_adapter_parses_reduced_motion_commands);
  RUN_TEST(test_sensor_adapter_parses_motion_stop_commands);
  RUN_TEST(test_sensor_adapter_parses_demo_enable_commands);
  RUN_TEST(test_sensor_adapter_parses_safe_stop_command);
  RUN_TEST(test_sensor_adapter_parses_safe_resume_command);
  RUN_TEST(test_actuation_clamps_pitch_and_yaw_angle);
  RUN_TEST(test_actuation_disable_stops_and_suppresses_writes_until_resumed);
  RUN_TEST(test_stackchan_servo_stop_returns_tracked_axes_to_neutral);
  RUN_TEST(test_actuation_clamps_yaw_velocity);
  RUN_TEST(test_disabled_yaw_commands_zero_velocity);
  RUN_TEST(test_speech_planner_uses_original_stackchan_lines);
  RUN_TEST(test_speech_planner_keeps_idle_quiet_until_emotion_moves);
  RUN_TEST(test_speech_planner_marks_safety_with_distinct_earcon);
  RUN_TEST(test_earcon_synth_renders_each_typed_cue);
  RUN_TEST(test_earcon_synth_is_deterministic_and_respects_intensity);
  RUN_TEST(test_earcon_synth_reports_truncation_without_allocation);
  RUN_TEST(test_speech_adapter_prepares_packaged_prompt_and_earcon);
  RUN_TEST(test_speech_prompt_bank_covers_all_spoken_intents_with_sidecars);
  RUN_TEST(test_audio_out_accepts_packaged_prompt_requests);
  RUN_TEST(test_audio_out_streams_packaged_sidecar_mouth_frames);
  RUN_TEST(test_audio_out_ducks_active_playback_for_barge_in);
  RUN_TEST(test_audio_out_feeds_enabled_hardware_speaker_sink);
  RUN_TEST(test_speech_adapter_queues_audio_out_request);
  RUN_TEST(test_speech_adapter_rejects_empty_or_uninitialized_cues);
  RUN_TEST(test_speech_adapter_scales_earcon_with_arousal);
  RUN_TEST(test_speech_planner_avoids_character_clone_markers);
  RUN_TEST(test_bridge_client_accepts_session_hello);
  RUN_TEST(test_bridge_client_maps_thinking_and_response_events);
  RUN_TEST(test_bridge_client_accepts_all_character_lock_intents);
  RUN_TEST(test_serial_bridge_response_preserves_attend_intent);
  RUN_TEST(test_bridge_client_parses_audio_frames_for_mouth_sync);
  RUN_TEST(test_bridge_client_parses_audio_stream_metadata);
  RUN_TEST(test_bridge_client_rejects_binary_without_audio_stream);
  RUN_TEST(test_bridge_client_rejects_truncated_audio_stream);
  RUN_TEST(test_bridge_client_rejects_oversized_audio_stream_chunk);
  RUN_TEST(test_bridge_audio_downlink_consumes_bridge_payload_output);
  RUN_TEST(test_bridge_audio_downlink_hands_pcm16_chunks_to_playback_sink);
  RUN_TEST(test_bridge_audio_downlink_counts_unsupported_playback_format_without_failing_stream);
  RUN_TEST(test_bridge_audio_downlink_stops_playback_on_end_mismatch);
  RUN_TEST(test_bridge_audio_downlink_rejects_invalid_payload_and_aborts);
  RUN_TEST(test_bridge_client_recovers_after_error_aborts_audio_stream);
  RUN_TEST(test_bridge_client_reports_parse_errors_without_allocating);
  RUN_TEST(test_bridge_client_times_out_active_session_once);
  RUN_TEST(test_bridge_client_timeout_aborts_audio_stream);
  RUN_TEST(test_bridge_client_accepts_serial_bridge_transcript);
  RUN_TEST(test_bridge_websocket_builds_upgrade_request_and_accepts_response);
  RUN_TEST(test_bridge_websocket_encodes_masked_client_text_frames);
  RUN_TEST(test_bridge_websocket_decodes_server_text_to_bridge_client);
  RUN_TEST(test_bridge_websocket_decodes_binary_downlink_chunks);
  RUN_TEST(test_bridge_websocket_rejects_masked_server_frames);
  RUN_TEST(test_bridge_websocket_close_marks_bridge_disconnected);
  RUN_TEST(test_bridge_websocket_routes_endpoint_control_to_pending_response);
  RUN_TEST(test_bridge_websocket_encodes_pending_endpoint_response_as_masked_client_frame);
  RUN_TEST(test_bridge_websocket_ignored_endpoint_control_falls_through_to_bridge_client);
  RUN_TEST(test_bridge_socket_writer_no_pending_is_noop);
  RUN_TEST(test_bridge_socket_writer_writes_pending_endpoint_response_frame);
  RUN_TEST(test_bridge_socket_writer_retains_partial_frame_until_complete);
  RUN_TEST(test_bridge_socket_writer_disconnected_keeps_pending_response);
  RUN_TEST(test_bridge_network_session_starts_and_accepts_handshake);
  RUN_TEST(test_bridge_network_session_feeds_server_frames_to_bridge_client);
  RUN_TEST(test_bridge_network_session_writes_endpoint_control_response);
  RUN_TEST(test_bridge_network_session_reconnects_after_socket_disconnect);
  RUN_TEST(test_bridge_endpoint_registry_upserts_and_bounds_trusted_endpoints);
  RUN_TEST(test_bridge_endpoint_registry_explicit_claim_overrides_current_owner);
  RUN_TEST(test_bridge_endpoint_registry_timeout_promotes_highest_priority_healthy_endpoint);
  RUN_TEST(test_bridge_endpoint_registry_tie_breaks_by_recent_seen);
  RUN_TEST(test_bridge_endpoint_registry_forget_active_owner_promotes_next_endpoint);
  RUN_TEST(test_bridge_endpoint_registry_disconnect_active_owner_promotes_next_endpoint);
  RUN_TEST(test_bridge_endpoint_registry_auto_connect_false_waits_for_explicit_claim);
  RUN_TEST(test_bridge_endpoint_control_registers_endpoint_and_returns_result);
  RUN_TEST(test_bridge_endpoint_control_claim_and_release_handoff);
  RUN_TEST(test_bridge_endpoint_control_heartbeat_handles_endpoint_only);
  RUN_TEST(test_bridge_endpoint_control_lists_and_forgets_endpoints);
  RUN_TEST(test_bridge_endpoint_control_updates_capabilities);
  RUN_TEST(test_bridge_endpoint_control_rejects_bad_endpoint_frames_and_ignores_bridge_frames);
  RUN_TEST(test_bridge_endpoint_registry_restore_keeps_endpoint_unhealthy_until_heartbeat);
  RUN_TEST(test_bridge_endpoint_store_saves_and_loads_trusted_endpoints_without_owner);
  RUN_TEST(test_bridge_endpoint_store_clear_removes_persisted_registry);
  RUN_TEST(test_bridge_endpoint_store_rejects_malformed_or_wrong_schema_payloads);
  RUN_TEST(test_bridge_endpoint_control_persists_pairing_and_forget_when_store_attached);
  return UNITY_END();
}
