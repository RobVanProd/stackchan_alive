#pragma once

#include "config/RobotConfig.hpp"
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
  void begin(IDisplay* display, const FaceConfig& config);
  void setReducedMotion(bool enabled);
  void setSpeechEnvelope(float envelope, SpeechViseme viseme, uint32_t nowMs);
  void clearSpeechEnvelope(uint32_t nowMs);
  bool isReducedMotion() const {
    return animator_.isReducedMotion();
  }
  const FaceSpeechTelemetry& speechTelemetry() const {
    return animator_.speechTelemetry();
  }
  void render(const RobotFrame& frame, uint32_t nowMs);

 private:
  IDisplay* display_ = nullptr;
  FaceAnimator animator_;
  uint32_t lastTelemetryMs_ = 0;

  EyeGeometry makeEye(const RobotFrame& frame, bool rightEye) const;
  MouthGeometry makeMouth(const RobotFrame& frame) const;
  void printAnimatorTelemetry(const RobotFrame& frame, uint32_t nowMs);
};

}  // namespace stackchan
