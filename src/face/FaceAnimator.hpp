#pragma once

#include <stdint.h>

#include "persona/StateMatrix.hpp"

namespace stackchan {

enum class Ease : uint8_t {
  Linear,
  InOutCubic,
  OutQuad,
  InQuad,
  OutBack,
};

float applyEase(Ease ease, float x);

struct FaceAutonomicTelemetry {
  float blinkOpen = 1.0f;
  float breathY = 0.0f;
  float gazeX = 0.0f;
  float gazeY = 0.0f;
  uint32_t blinkCount = 0;
  uint32_t saccadeCount = 0;
};

class FaceAnimator {
 public:
  FaceTargets composeFrame(const RobotFrame& frame, uint32_t nowMs);
  void reset(const FaceTargets& face, uint32_t nowMs);
  void setReducedMotion(bool enabled);
  const FaceAutonomicTelemetry& autonomicTelemetry() const {
    return telemetry_;
  }

 private:
  enum class BlinkPhase : uint8_t {
    Open,
    Closing,
    Hold,
    Opening,
  };

  struct BlinkState {
    BlinkPhase phase = BlinkPhase::Open;
    uint32_t phaseStartMs = 0;
    uint32_t phaseDurationMs = 1;
    uint32_t nextMs = 0;
    uint8_t queuedBlinks = 0;
    float open = 1.0f;
    uint32_t count = 0;
  };

  struct SaccadeState {
    uint32_t nextMs = 0;
    uint32_t settleStartMs = 0;
    float startX = 0.0f;
    float startY = 0.0f;
    float overshootX = 0.0f;
    float overshootY = 0.0f;
    float targetX = 0.0f;
    float targetY = 0.0f;
    float offsetX = 0.0f;
    float offsetY = 0.0f;
    uint32_t count = 0;
    bool settling = false;
  };

  struct FidgetState {
    uint32_t nextMs = 0;
    uint32_t startMs = 0;
    uint32_t durationMs = 0;
    uint8_t kind = 0;
    bool active = false;
  };

  bool initialized_ = false;
  uint32_t lastMs_ = 0;
  uint32_t rng_ = 0x51A7C0DEu;
  bool reducedMotion_ = false;
  FaceTargets current_;
  BlinkState blink_;
  SaccadeState saccade_;
  FidgetState fidget_;
  FaceAutonomicTelemetry telemetry_;

  FaceTargets samplePose(const RobotFrame& frame, uint32_t nowMs) const;
  void applyAutonomic(FaceTargets& face, const RobotFrame& frame, uint32_t nowMs);
  void applyGesture(FaceTargets& face, const RobotFrame& frame, uint32_t nowMs) const;
  void applyReactive(FaceTargets& face, const RobotFrame& frame, uint32_t nowMs) const;
  FaceTargets smoothToward(const FaceTargets& target, uint32_t nowMs);
  float updateBlink(const RobotFrame& frame, uint32_t nowMs);
  void scheduleBlink(const RobotFrame& frame, uint32_t nowMs, uint32_t minDelayMs = 0);
  void startBlink(const RobotFrame& frame, uint32_t nowMs);
  void updateSaccade(const RobotFrame& frame, uint32_t nowMs);
  void scheduleSaccade(const RobotFrame& frame, uint32_t nowMs);
  void chooseSaccadeTarget(const RobotFrame& frame, float& x, float& y);
  void updateFidget(FaceTargets& face, const RobotFrame& frame, uint32_t nowMs, float motionScale);
  uint32_t randomRange(uint32_t low, uint32_t high);
  float randomUnit();
  float randomSigned(float amplitude);
};

}  // namespace stackchan
