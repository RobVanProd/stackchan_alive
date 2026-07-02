#pragma once

#include "config/RobotConfig.hpp"
#include "motion/Spring.hpp"
#include "persona/StateMatrix.hpp"

namespace stackchan {

class IActuator {
 public:
  virtual ~IActuator() = default;
  virtual bool begin() = 0;
  virtual void writePitchDeg(float pitchDeg) = 0;
  virtual void writeYawAngleDeg(float yawDeg) = 0;
  virtual void writeYawVelocity(float yawVel) = 0;
  virtual void stop() = 0;
};

class ActuationEngine {
 public:
  explicit ActuationEngine(const RobotConfig& config);

  void begin(IActuator* actuator);
  void setEnabled(bool enabled);
  void update(const RobotFrame& target, uint32_t nowUs);

 private:
  RobotConfig config_;
  IActuator* actuator_ = nullptr;
  Spring1D pitch_;
  Spring1D yaw_;
  uint32_t lastUs_ = 0;
  bool enabled_ = true;
};

}  // namespace stackchan
