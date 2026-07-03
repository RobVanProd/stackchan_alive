#pragma once

#include <Arduino.h>

#include "persona/EventBus.hpp"

namespace stackchan {

struct CameraAdapterTelemetry {
  bool ready = false;
  bool active = false;
  bool hardwareEnabled = false;
  uint32_t eventsPublished = 0;
  uint32_t lastEventMs = 0;
  float lastX = 0.0f;
  float lastY = 0.0f;
  float lastSize = 0.0f;
};

class CameraAdapter {
 public:
  bool begin();
  void setActive(bool active);

  void submitFace(float x, float y, float size, uint32_t nowMs);
  void submitFaceLost(uint32_t nowMs, float strength = 1.0f);
  bool poll(RobotEvent* eventOut);

  const CameraAdapterTelemetry& telemetry() const {
    return telemetry_;
  }

 private:
  void queueEvent(const RobotEvent& event);

  CameraAdapterTelemetry telemetry_;
  RobotEvent pending_;
  bool hasPending_ = false;
};

}  // namespace stackchan
