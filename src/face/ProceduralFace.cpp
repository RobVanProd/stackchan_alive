#include "face/ProceduralFace.hpp"

#include <Arduino.h>
#include <math.h>

namespace stackchan {

void ProceduralFace::begin(IDisplay* display) {
  begin(display, FaceConfig {});
}

void ProceduralFace::begin(IDisplay* display, const FaceConfig& config) {
  display_ = display;
  animator_.setReducedMotion(config.reducedMotion);
  if (display_ != nullptr) {
    display_->begin();
  }
  Serial.print(F("[face] reduced_motion="));
  Serial.println(config.reducedMotion ? 1 : 0);
}

void ProceduralFace::setReducedMotion(bool enabled) {
  animator_.setReducedMotion(enabled);
  Serial.print(F("[face] reduced_motion="));
  Serial.println(enabled ? 1 : 0);
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
  printAnimatorTelemetry(composed, nowMs);
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

void ProceduralFace::printAnimatorTelemetry(const RobotFrame& frame, uint32_t nowMs) {
  if (lastTelemetryMs_ == 0) {
    lastTelemetryMs_ = nowMs;
    return;
  }
  if (nowMs - lastTelemetryMs_ < 5000) {
    return;
  }
  lastTelemetryMs_ = nowMs;

  const FaceAutonomicTelemetry& autonomic = animator_.autonomicTelemetry();
  const FaceGestureTelemetry& gesture = animator_.gestureTelemetry();
  const FaceSpeechTelemetry& speech = animator_.speechTelemetry();
  Serial.print(F("[face] mode="));
  Serial.print(static_cast<int>(frame.mode));
  Serial.print(F(" blink_count="));
  Serial.print(autonomic.blinkCount);
  Serial.print(F(" saccade_count="));
  Serial.print(autonomic.saccadeCount);
  Serial.print(F(" blink_open="));
  Serial.print(autonomic.blinkOpen, 2);
  Serial.print(F(" breath_y="));
  Serial.print(autonomic.breathY, 2);
  Serial.print(F(" gaze_x="));
  Serial.print(autonomic.gazeX, 2);
  Serial.print(F(" gaze_y="));
  Serial.print(autonomic.gazeY, 2);
  Serial.print(F(" gesture_active="));
  Serial.print(gesture.active ? 1 : 0);
  Serial.print(F(" speech_active="));
  Serial.print(speech.active ? 1 : 0);
  Serial.print(F(" speech_env="));
  Serial.println(speech.envelope, 2);
}

}  // namespace stackchan
