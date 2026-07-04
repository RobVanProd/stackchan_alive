#include "face/ExpressionMapper.hpp"

#include <Arduino.h>

#include "PersonaExpressions.hpp"

namespace stackchan {

namespace {

float blendValue(float a, float b, float t) {
  return a + (b - a) * t;
}

}  // namespace

FaceTargets ExpressionMapper::map(const EmotionalProfile& emotion, CharacterMode mode) const {
  FaceTargets face;
  const generated_persona::PersonaExpressionTargets& neutral = generated_persona::kNeutralExpression;
  face.eyeOpen = constrain(neutral.eyeOpen + (emotion.arousal - 0.20f) * 0.30f - emotion.fatigue * 0.35f,
                           0.15f,
                           1.08f);
  face.squint = constrain((emotion.valence < 0.0f ? -emotion.valence : 0.0f) * 0.5f, 0.0f, 1.0f);
  face.eyeSmile = constrain(neutral.eyeSmile + (emotion.valence - 0.45f) * 0.55f, 0.0f, 1.0f);
  face.pupilX = 0.0f;
  face.pupilY = mode == CharacterMode::Think ? generated_persona::kThinkPupilY : 0.0f;
  face.browTilt = constrain(emotion.valence * 0.30f + emotion.arousal * 0.15f, -1.0f, 1.0f);
  face.mouthSmile = constrain(neutral.mouthSmile + (emotion.valence - 0.45f) * 0.75f, -1.0f, 1.0f);
  face.mouthOpen = mode == CharacterMode::Speak ? 0.45f + emotion.arousal * 0.35f : 0.0f;

  const float drowsy = constrain((emotion.fatigue - 0.45f) / 0.35f, 0.0f, 1.0f);
  if (drowsy > 0.0f && mode != CharacterMode::Speak && mode != CharacterMode::Sleep) {
    const generated_persona::PersonaExpressionTargets& sleepy = generated_persona::kDrowsyExpression;
    face.eyeOpen = blendValue(face.eyeOpen, sleepy.eyeOpen, drowsy);
    face.squint = blendValue(face.squint, sleepy.squint, drowsy);
    face.browTilt = blendValue(face.browTilt, sleepy.browTilt, drowsy);
    face.mouthSmile = blendValue(face.mouthSmile, sleepy.mouthSmile, drowsy);
    face.faceY = blendValue(face.faceY, sleepy.faceY, drowsy);
  }

  if (mode == CharacterMode::Sleep) {
    face.eyeOpen = 0.15f;
    face.mouthOpen = 0.0f;
  } else if (mode == CharacterMode::Error) {
    face.squint = 0.75f;
    face.mouthSmile = -0.65f;
  }

  return face;
}

}  // namespace stackchan
