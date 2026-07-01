#pragma once

namespace stackchan {

struct EyeGeometry {
  float cx = 0.0f;
  float cy = 0.0f;
  float width = 72.0f;
  float height = 56.0f;
  float upperLid = 0.0f;
  float lowerLid = 0.0f;
  float upperLidTilt = 0.0f;
  float lowerLidTilt = 0.0f;
  float pupilX = 0.0f;
  float pupilY = 0.0f;
  float pupilScale = 1.0f;
  float browTilt = 0.0f;
  float squint = 0.0f;
  float smile = 0.0f;
  float cornerTL = 0.0f;
  float cornerTR = 0.0f;
  float cornerBL = 0.0f;
  float cornerBR = 0.0f;
};

}  // namespace stackchan
