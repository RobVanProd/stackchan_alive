#include "face/ExpressionMapper.hpp"

#include <Arduino.h>

#include "persona/IntentEngine.hpp"

namespace stackchan {

FaceTargets ExpressionMapper::map(const EmotionalProfile& emotion, CharacterMode mode) const {
  FaceTargets face;
  face.eyeOpen = constrain(0.72f + emotion.arousal * 0.30f - emotion.fatigue * 0.35f, 0.15f, 1.0f);
  face.squint = constrain((emotion.valence < 0.0f ? -emotion.valence : 0.0f) * 0.5f, 0.0f, 1.0f);
  face.eyeSmile = constrain(max(0.0f, emotion.valence) * 0.55f, 0.0f, 1.0f);
  face.pupilX = 0.0f;
  face.pupilY = mode == CharacterMode::Think ? -0.20f : 0.0f;
  face.browTilt = constrain(emotion.valence * 0.30f + emotion.arousal * 0.15f, -1.0f, 1.0f);
  face.mouthSmile = constrain(emotion.valence * 0.75f, -1.0f, 1.0f);
  face.mouthOpen = mode == CharacterMode::Speak ? 0.45f + emotion.arousal * 0.35f : 0.0f;

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
