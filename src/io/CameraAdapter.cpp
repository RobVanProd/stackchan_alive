#include "io/CameraAdapter.hpp"

#if !defined(STACKCHAN_ENABLE_CAMERA)
#define STACKCHAN_ENABLE_CAMERA 0
#endif

#if STACKCHAN_ENABLE_CAMERA && __has_include(<M5Unified.h>) && __has_include(<esp_camera.h>)
#include <M5Unified.h>
#include <esp_camera.h>
#define STACKCHAN_CAMERA_CAPTURE_AVAILABLE 1
#else
#define STACKCHAN_CAMERA_CAPTURE_AVAILABLE 0
#endif

namespace stackchan {

bool CameraAdapter::begin() {
  telemetry_ = CameraAdapterTelemetry {};
  telemetry_.ready = true;
  telemetry_.hardwareEnabled = STACKCHAN_ENABLE_CAMERA != 0;
  telemetry_.captureReady = !telemetry_.hardwareEnabled || initializeHardware();
  telemetry_.active = telemetry_.hardwareEnabled && telemetry_.captureReady;
  activeSpeaker_.reset(millis());
  hasPending_ = false;
  return telemetry_.captureReady;
}

void CameraAdapter::setActive(bool active) {
  telemetry_.active = active && telemetry_.hardwareEnabled && telemetry_.captureReady;
}

bool CameraAdapter::initializeHardware() {
  ++telemetry_.initAttempts;
#if STACKCHAN_CAMERA_CAPTURE_AVAILABLE
  if (!M5.In_I2C.isEnabled()) {
    ++telemetry_.initFailures;
    telemetry_.lastInitError = -1;
    return false;
  }

  camera_config_t config = {};
  config.pin_pwdn = -1;
  config.pin_reset = -1;
  config.pin_xclk = -1;
  // The camera SCCB device shares CoreS3's managed internal bus. Reuse it;
  // releasing M5.In_I2C would also detach PMIC, audio, touch, and body devices.
  config.pin_sccb_sda = -1;
  config.pin_sccb_scl = -1;
  config.pin_d7 = 47;
  config.pin_d6 = 48;
  config.pin_d5 = 16;
  config.pin_d4 = 15;
  config.pin_d3 = 42;
  config.pin_d2 = 41;
  config.pin_d1 = 40;
  config.pin_d0 = 39;
  config.pin_vsync = 46;
  config.pin_href = 38;
  config.pin_pclk = 45;
  config.xclk_freq_hz = 20000000;
  config.ledc_timer = LEDC_TIMER_0;
  config.ledc_channel = LEDC_CHANNEL_0;
  config.pixel_format = PIXFORMAT_RGB565;
  config.frame_size = FRAMESIZE_QVGA;
  config.jpeg_quality = 12;
  config.fb_count = 1;
  config.fb_location = CAMERA_FB_IN_PSRAM;
  config.grab_mode = CAMERA_GRAB_WHEN_EMPTY;
  config.sccb_i2c_port = M5.In_I2C.getPort();

  const esp_err_t result = esp_camera_init(&config);
  telemetry_.lastInitError = result;
  if (result != ESP_OK) {
    ++telemetry_.initFailures;
    return false;
  }
  return true;
#else
  ++telemetry_.initFailures;
  telemetry_.lastInitError = -2;
  return false;
#endif
}

bool CameraAdapter::captureFrame(CameraFrameView* frameOut) {
  if (frameOut == nullptr || !telemetry_.active || !telemetry_.captureReady) {
    return false;
  }
#if STACKCHAN_CAMERA_CAPTURE_AVAILABLE
  camera_fb_t* frame = esp_camera_fb_get();
  if (frame == nullptr) {
    ++telemetry_.captureFailures;
    return false;
  }
  frameOut->data = frame->buf;
  frameOut->length = frame->len;
  frameOut->width = static_cast<uint16_t>(frame->width);
  frameOut->height = static_cast<uint16_t>(frame->height);
  frameOut->format = static_cast<uint8_t>(frame->format);
  frameOut->handle = frame;
  ++telemetry_.framesCaptured;
  return true;
#else
  ++telemetry_.captureFailures;
  return false;
#endif
}

bool CameraAdapter::captureGray160(uint8_t* destination,
                                   size_t capacity,
                                   CameraGrayFrame* frameOut,
                                   uint32_t nowMs) {
  ++telemetry_.hostFrameRequests;
  if (destination == nullptr || frameOut == nullptr) {
    ++telemetry_.hostFrameFailures;
    return false;
  }
  const uint32_t startedUs = micros();
  CameraFrameView source;
  if (!captureFrame(&source)) {
    ++telemetry_.hostFrameFailures;
    return false;
  }
#if STACKCHAN_CAMERA_CAPTURE_AVAILABLE
  const uint16_t outputWidth = source.width / 2;
  const uint16_t outputHeight = source.height / 2;
  const size_t outputLength = static_cast<size_t>(outputWidth) * outputHeight;
  const size_t sourceLength = static_cast<size_t>(source.width) * source.height * 2;
  if (source.format != static_cast<uint8_t>(PIXFORMAT_RGB565) || outputWidth == 0 ||
      outputHeight == 0 || outputLength > capacity || source.length < sourceLength) {
    releaseFrame(&source);
    ++telemetry_.hostFrameFailures;
    return false;
  }

  for (uint16_t y = 0; y < outputHeight; ++y) {
    const size_t sourceRow = static_cast<size_t>(y * 2) * source.width * 2;
    const size_t destinationRow = static_cast<size_t>(y) * outputWidth;
    for (uint16_t x = 0; x < outputWidth; ++x) {
      const size_t index = sourceRow + static_cast<size_t>(x * 2) * 2;
      const uint16_t rgb565 =
          (static_cast<uint16_t>(source.data[index]) << 8) | source.data[index + 1];
      const uint16_t red = (rgb565 >> 11) & 0x1Fu;
      const uint16_t green = (rgb565 >> 5) & 0x3Fu;
      const uint16_t blue = rgb565 & 0x1Fu;
      destination[destinationRow + x] = static_cast<uint8_t>(
          (red * 77u * 255u / 31u + green * 150u * 255u / 63u +
           blue * 29u * 255u / 31u) >>
          8);
    }
  }

  const uint32_t elapsedUs = micros() - startedUs;
  telemetry_.lastCaptureMs = nowMs;
  telemetry_.lastCaptureUs = elapsedUs;
  telemetry_.maxCaptureUs = max(telemetry_.maxCaptureUs, elapsedUs);
  telemetry_.lastFrameBytes = outputLength;
  telemetry_.lastFrameWidth = outputWidth;
  telemetry_.lastFrameHeight = outputHeight;
  uint32_t checksum = 2166136261u;
  const size_t stride = outputLength > 256 ? outputLength / 256 : 1;
  for (size_t i = 0; i < outputLength; i += stride) {
    checksum = (checksum ^ destination[i]) * 16777619u;
  }
  telemetry_.lastFrameChecksum = checksum;
  frameOut->length = outputLength;
  frameOut->width = outputWidth;
  frameOut->height = outputHeight;
  releaseFrame(&source);
  return true;
#else
  releaseFrame(&source);
  ++telemetry_.hostFrameFailures;
  return false;
#endif
}

void CameraAdapter::releaseFrame(CameraFrameView* frame) {
  if (frame == nullptr || frame->handle == nullptr) {
    return;
  }
#if STACKCHAN_CAMERA_CAPTURE_AVAILABLE
  esp_camera_fb_return(static_cast<camera_fb_t*>(frame->handle));
#endif
  *frame = CameraFrameView {};
}

bool CameraAdapter::serviceCaptureProbe(uint32_t nowMs) {
  if (!telemetry_.active ||
      (telemetry_.lastCaptureMs != 0 && nowMs - telemetry_.lastCaptureMs < 1000)) {
    return false;
  }
  const uint32_t startedUs = micros();
  CameraFrameView frame;
  if (!captureFrame(&frame)) {
    telemetry_.lastCaptureMs = nowMs;
    return false;
  }
  const uint32_t elapsedUs = micros() - startedUs;
  telemetry_.lastCaptureMs = nowMs;
  telemetry_.lastCaptureUs = elapsedUs;
  telemetry_.maxCaptureUs = max(telemetry_.maxCaptureUs, elapsedUs);
  telemetry_.lastFrameBytes = frame.length;
  telemetry_.lastFrameWidth = frame.width;
  telemetry_.lastFrameHeight = frame.height;
  uint32_t checksum = 2166136261u;
  const size_t stride = frame.length > 256 ? frame.length / 256 : 1;
  for (size_t i = 0; i < frame.length; i += stride) {
    checksum = (checksum ^ frame.data[i]) * 16777619u;
  }
  telemetry_.lastFrameChecksum = checksum;
  releaseFrame(&frame);
  return true;
}

void CameraAdapter::submitFace(float x, float y, float size, uint32_t nowMs) {
  const FaceCandidate face {x, y, size, 1.0f};
  submitFaces(&face, 1, nowMs);
}

void CameraAdapter::submitFaces(const FaceCandidate* faces, uint8_t count, uint32_t nowMs) {
  if (faces == nullptr || count == 0) {
    submitFaceLost(nowMs, 1.0f);
    return;
  }
  const ActiveSpeakerTarget target = activeSpeaker_.updateFaces(faces, count, nowMs);
  if (!target.valid) {
    return;
  }
  RobotEvent event;
  event.type = EventType::FaceDetected;
  event.timestampMs = nowMs;
  event.strength = constrain(target.confidence, 0.1f, 1.0f);
  event.hasPayload = true;
  event.x = target.x;
  event.y = target.y;
  event.z = target.size;
  telemetry_.faceBatches++;
  telemetry_.facesObserved += min(count, kActiveSpeakerMaxFaces);
  if (target.audioMatched) {
    telemetry_.audioMatchedSelections++;
  }
  if (target.heldForReply) {
    telemetry_.replyHeldSelections++;
  }
  queueEvent(event);
}

void CameraAdapter::submitSoundDirection(float azimuthNorm, float strength, uint32_t nowMs) {
  activeSpeaker_.updateSoundDirection(azimuthNorm, strength, nowMs);
}

void CameraAdapter::setRobotSpeaking(bool speaking, uint32_t nowMs) {
  activeSpeaker_.setRobotSpeaking(speaking, nowMs);
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

void CameraAdapter::noteHostAuthFailure() {
  ++telemetry_.hostAuthFailures;
}

void CameraAdapter::noteHostFrameFailure() {
  ++telemetry_.hostFrameFailures;
}

void CameraAdapter::noteHostTargetUpdate() {
  ++telemetry_.hostTargetUpdates;
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
