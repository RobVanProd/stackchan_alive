#pragma once

#include "face/EyeGeometry.hpp"
#include "face/FaceAnimator.hpp"
#include "face/MouthGeometry.hpp"
#include "persona/StateMatrix.hpp"

namespace stackchan {

class IDisplay {
 public:
  virtual ~IDisplay() = default;
  virtual bool begin() = 0;
  virtual void clear() = 0;
  virtual void drawEye(const EyeGeometry& eye, bool rightEye) = 0;
  virtual void drawMouth(const MouthGeometry& mouth) = 0;
  virtual void flush() = 0;
};

class ProceduralFace {
 public:
  void begin(IDisplay* display);
  void render(const RobotFrame& frame, uint32_t nowMs);

 private:
  IDisplay* display_ = nullptr;
  FaceAnimator animator_;

  EyeGeometry makeEye(const RobotFrame& frame, bool rightEye) const;
  MouthGeometry makeMouth(const RobotFrame& frame) const;
};

}  // namespace stackchan
