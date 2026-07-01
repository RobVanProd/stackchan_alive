#include "face/ProceduralFace.hpp"

#include <Arduino.h>
#include <math.h>

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

  RobotFrame composed = frame;
  composed.face = animator_.composeFrame(frame, nowMs);

  display_->clear();
  display_->drawEye(makeEye(composed, false), false);
  display_->drawEye(makeEye(composed, true), true);
  display_->drawMouth(makeMouth(composed));
  display_->flush();
}

EyeGeometry ProceduralFace::makeEye(const RobotFrame& frame, bool rightEye) const {
  EyeGeometry eye;
  eye.cx = (rightEye ? 214.0f : 106.0f) + frame.face.faceX;
  eye.cy = 104.0f + frame.face.faceY;
  eye.width = (70.0f - frame.face.squint * 10.0f) * frame.face.eyeWidthScale;
  eye.height = 56.0f;
  const float visibleOpen = constrain(frame.face.eyeOpen, 0.0f, 1.08f);
  eye.upperLid = (1.0f - visibleOpen) * eye.height;
  eye.lowerLid = frame.face.eyeSmile * 10.0f;
  eye.upperLidTilt = frame.face.upperLidTilt;
  eye.lowerLidTilt = frame.face.lowerLidTilt;
  eye.pupilX = constrain(frame.face.pupilX, -1.0f, 1.0f);
  eye.pupilY = constrain(frame.face.pupilY, -1.0f, 1.0f);
  eye.pupilScale = frame.face.pupilScale;
  eye.browTilt = frame.face.browTilt;
  eye.squint = frame.face.squint;
  eye.smile = frame.face.eyeSmile;
  const FaceTargets::EyeCorners corners = rightEye ? frame.face.rightCorners : frame.face.leftCorners;
  eye.cornerTL = corners.tl;
  eye.cornerTR = corners.tr;
  eye.cornerBL = corners.bl;
  eye.cornerBR = corners.br;
  return eye;
}

MouthGeometry ProceduralFace::makeMouth(const RobotFrame& frame) const {
  MouthGeometry mouth;
  mouth.cx += frame.face.faceX;
  mouth.cy += frame.face.faceY;
  mouth.width += frame.face.mouthWidthDelta;
  mouth.smile = frame.face.mouthSmile;
  mouth.open = frame.face.mouthOpen;
  mouth.cornerL = frame.face.mouthCornerL;
  mouth.cornerR = frame.face.mouthCornerR;
  return mouth;
}

}  // namespace stackchan
