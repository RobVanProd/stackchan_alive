#pragma once

#include <cstddef>
#include <cstdint>

enum class BridgeDebugHttpMethod : uint8_t {
  Unknown = 0,
  Get,
  Post,
  Head,
  Put,
  Delete,
  Patch,
  Options,
  Custom,
};

enum class BridgeDebugHttpRoute : uint8_t {
  Unknown = 0,
  Root,
  Debug,
  AudioStop,
  MotionStop,
  UnsafeControl,
  CameraGray,
  CameraVision,
};

enum class BridgeDebugHttpDisposition : uint8_t {
  RejectBadRequest = 0,
  RejectForbidden,
  RejectNotFound,
  RejectMethod,
  RejectUriTooLong,
  ServeStatus,
  ServeDebug,
  EmergencyAudioStop,
  EmergencyMotionStop,
  CameraGray,
  CameraVision,
};

struct BridgeDebugHttpDecision {
  BridgeDebugHttpMethod method = BridgeDebugHttpMethod::Unknown;
  BridgeDebugHttpRoute route = BridgeDebugHttpRoute::Unknown;
  BridgeDebugHttpDisposition disposition = BridgeDebugHttpDisposition::RejectBadRequest;
  uint16_t statusCode = 400;
};

BridgeDebugHttpDecision evaluateBridgeDebugHttpRequestLine(const char* requestLine,
                                                           bool firstLineComplete,
                                                           bool requestLineOverflow,
                                                           bool requestLineInvalid,
                                                           char* cameraRequestTarget,
                                                           size_t cameraRequestTargetSize);

const char* bridgeDebugHttpMethodName(BridgeDebugHttpMethod method);
const char* bridgeDebugHttpRouteName(BridgeDebugHttpRoute route);
const char* bridgeDebugHttpDispositionName(BridgeDebugHttpDisposition disposition);
