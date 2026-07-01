#include "face/ProceduralFace.hpp"

#include <Arduino.h>

namespace stackchan {

void ProceduralFace::begin(IDisplay* display) {
  display_ = display;
  if (display_ != nullptr) {
    display_->begin();
  }
}

void ProceduralFace::render(const RobotFrame& frame, uint32_t nowMs) {
  if (display_ == nullptr) {
    return;
  }

  saccade_.update(nowMs, frame.emotion);
  const float blinkRatio = blink_.update(nowMs, frame.emotion);

  display_->clear();
  display_->drawEye(makeEye(frame, false, blinkRatio), false);
  display_->drawEye(makeEye(frame, true, blinkRatio), true);
  display_->drawMouth(makeMouth(frame));
  display_->flush();
}

EyeGeometry ProceduralFace::makeEye(const RobotFrame& frame, bool rightEye, float blinkRatio) const {
  EyeGeometry eye;
  eye.cx = rightEye ? 214.0f : 106.0f;
  eye.cy = 104.0f;
  eye.width = 70.0f - frame.face.squint * 10.0f;
  eye.height = max(6.0f, 56.0f * frame.face.eyeOpen * blinkRatio);
  eye.upperLid = frame.face.squint * 8.0f;
  eye.lowerLid = frame.face.eyeSmile * 10.0f;
  eye.pupilX = constrain(frame.face.pupilX + saccade_.offsetX, -1.0f, 1.0f);
  eye.pupilY = constrain(frame.face.pupilY + saccade_.offsetY, -1.0f, 1.0f);
  eye.squint = frame.face.squint;
  eye.smile = frame.face.eyeSmile;
  return eye;
}

MouthGeometry ProceduralFace::makeMouth(const RobotFrame& frame) const {
  MouthGeometry mouth;
  mouth.smile = frame.face.mouthSmile;
  mouth.open = frame.face.mouthOpen;
  return mouth;
}

}  // namespace stackchan
