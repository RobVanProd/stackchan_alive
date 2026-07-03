#include "io/CameraAdapter.hpp"

#if !defined(STACKCHAN_ENABLE_CAMERA)
#define STACKCHAN_ENABLE_CAMERA 0
#endif

namespace stackchan {

bool CameraAdapter::begin() {
  telemetry_ = CameraAdapterTelemetry {};
  telemetry_.ready = true;
  telemetry_.hardwareEnabled = STACKCHAN_ENABLE_CAMERA != 0;
  telemetry_.active = telemetry_.hardwareEnabled;
  hasPending_ = false;
  return true;
}

void CameraAdapter::setActive(bool active) {
  telemetry_.active = active && telemetry_.hardwareEnabled;
}

void CameraAdapter::submitFace(float x, float y, float size, uint32_t nowMs) {
  RobotEvent event;
  event.type = EventType::FaceDetected;
  event.timestampMs = nowMs;
  event.strength = 1.0f;
  event.hasPayload = true;
  event.x = constrain(x, -1.0f, 1.0f);
  event.y = constrain(y, -1.0f, 1.0f);
  event.z = constrain(size, 0.0f, 1.0f);
  queueEvent(event);
}

void CameraAdapter::submitFaceLost(uint32_t nowMs, float strength) {
  RobotEvent event;
  event.type = EventType::FaceLost;
  event.timestampMs = nowMs;
  event.strength = constrain(strength, 0.0f, 1.0f);
  event.hasPayload = false;
  queueEvent(event);
}

bool CameraAdapter::poll(RobotEvent* eventOut) {
  if (eventOut == nullptr || !hasPending_) {
    return false;
  }

  *eventOut = pending_;
  hasPending_ = false;
  return true;
}

void CameraAdapter::queueEvent(const RobotEvent& event) {
  pending_ = event;
  hasPending_ = true;
  telemetry_.eventsPublished++;
  telemetry_.lastEventMs = event.timestampMs;
  if (event.type == EventType::FaceDetected && event.hasPayload) {
    telemetry_.lastX = event.x;
    telemetry_.lastY = event.y;
    telemetry_.lastSize = event.z;
  }
}

}  // namespace stackchan
