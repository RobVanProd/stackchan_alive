#pragma once

#include <Arduino.h>

#include "persona/EventBus.hpp"
#include "persona/ActiveSpeakerTracker.hpp"

#ifndef STACKCHAN_ENABLE_CAMERA
#define STACKCHAN_ENABLE_CAMERA 0
#endif

namespace stackchan {

struct CameraAdapterTelemetry {
  bool ready = false;
  bool active = false;
  bool hardwareEnabled = false;
  bool captureReady = false;
  uint32_t initAttempts = 0;
  uint32_t initFailures = 0;
  int32_t lastInitError = 0;
  uint32_t framesCaptured = 0;
  uint32_t captureFailures = 0;
  uint32_t lastCaptureMs = 0;
  uint32_t lastCaptureUs = 0;
  uint32_t maxCaptureUs = 0;
  size_t lastFrameBytes = 0;
  uint16_t lastFrameWidth = 0;
  uint16_t lastFrameHeight = 0;
  uint32_t lastFrameChecksum = 0;
  uint32_t hostFrameRequests = 0;
  uint32_t hostFrameFailures = 0;
  uint32_t hostTargetUpdates = 0;
  uint32_t hostAuthFailures = 0;
  uint32_t eventsPublished = 0;
  uint32_t lastEventMs = 0;
  uint32_t faceBatches = 0;
  uint32_t facesObserved = 0;
  uint32_t audioMatchedSelections = 0;
  uint32_t replyHeldSelections = 0;
  float lastX = 0.0f;
  float lastY = 0.0f;
  float lastSize = 0.0f;
};

struct CameraFrameView {
  const uint8_t* data = nullptr;
  size_t length = 0;
  uint16_t width = 0;
  uint16_t height = 0;
  uint8_t format = 0;
  void* handle = nullptr;
};

struct CameraGrayFrame {
  size_t length = 0;
  uint16_t width = 0;
  uint16_t height = 0;
};

class CameraAdapter {
 public:
  bool begin();
  void setActive(bool active);

  void submitFace(float x, float y, float size, uint32_t nowMs);
  void submitFaces(const FaceCandidate* faces, uint8_t count, uint32_t nowMs);
  void submitSoundDirection(float azimuthNorm, float strength, uint32_t nowMs);
  void setRobotSpeaking(bool speaking, uint32_t nowMs);
  void submitFaceLost(uint32_t nowMs, float strength = 1.0f);
  bool captureFrame(CameraFrameView* frameOut);
  bool captureGray160(uint8_t* destination,
                      size_t capacity,
                      CameraGrayFrame* frameOut,
                      uint32_t nowMs);
  void releaseFrame(CameraFrameView* frame);
  bool serviceCaptureProbe(uint32_t nowMs);
  bool poll(RobotEvent* eventOut);
  void noteHostAuthFailure();
  void noteHostFrameFailure();
  void noteHostTargetUpdate();

  const CameraAdapterTelemetry& telemetry() const {
    return telemetry_;
  }

 private:
  bool initializeHardware();
  void queueEvent(const RobotEvent& event);

  CameraAdapterTelemetry telemetry_;
  ActiveSpeakerTracker activeSpeaker_;
  RobotEvent pending_;
  bool hasPending_ = false;
};

}  // namespace stackchan
