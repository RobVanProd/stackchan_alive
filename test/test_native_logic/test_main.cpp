#include <unity.h>

#include <cmath>
#include <cstdint>
#include <cstring>
#include <fstream>
#include <string>
#include <vector>

#include "face/ExpressionMapper.hpp"
#include "face/FaceAnimator.hpp"
#include "io/CameraAdapter.hpp"
#include "io/SensorAdapter.hpp"
#include "io/SpeechAdapter.hpp"
#include "io/StackChanServoAdapter.hpp"
#include "motion/ActuationEngine.hpp"
#include "motion/Spring.hpp"
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
  RUN_TEST(test_intent_engine_demo_can_be_disabled_and_resumed);
  RUN_TEST(test_idle_life_breathing_moves_face_and_body_together);
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
  RUN_TEST(test_speech_adapter_rejects_empty_or_uninitialized_cues);
  RUN_TEST(test_speech_adapter_scales_earcon_with_arousal);
  RUN_TEST(test_speech_planner_avoids_character_clone_markers);
  return UNITY_END();
}
