#include "io/BridgeDebugHttpPolicy.hpp"

#include <cstring>
#include <initializer_list>

namespace {

constexpr size_t kMaximumMethodLength = 16;

BridgeDebugHttpDecision decision(BridgeDebugHttpMethod method,
                                 BridgeDebugHttpRoute route,
                                 BridgeDebugHttpDisposition disposition,
                                 uint16_t statusCode) {
  BridgeDebugHttpDecision result;
  result.method = method;
  result.route = route;
  result.disposition = disposition;
  result.statusCode = statusCode;
  return result;
}

bool equals(const char* value, size_t valueLength, const char* expected) {
  const size_t expectedLength = std::strlen(expected);
  return valueLength == expectedLength && std::memcmp(value, expected, valueLength) == 0;
}

bool isExactOrQuery(const char* target, size_t targetLength, const char* route) {
  const size_t routeLength = std::strlen(route);
  return targetLength == routeLength
             ? std::memcmp(target, route, routeLength) == 0
             : targetLength > routeLength && target[routeLength] == '?' &&
                   std::memcmp(target, route, routeLength) == 0;
}

bool isQueryFamily(const char* target, size_t targetLength, const char* route) {
  const size_t routeLength = std::strlen(route);
  return targetLength > routeLength && target[routeLength] == '?' &&
         std::memcmp(target, route, routeLength) == 0;
}

BridgeDebugHttpMethod parseMethod(const char* method, size_t methodLength) {
  if (equals(method, methodLength, "GET")) {
    return BridgeDebugHttpMethod::Get;
  }
  if (equals(method, methodLength, "POST")) {
    return BridgeDebugHttpMethod::Post;
  }
  if (equals(method, methodLength, "HEAD")) {
    return BridgeDebugHttpMethod::Head;
  }
  if (equals(method, methodLength, "PUT")) {
    return BridgeDebugHttpMethod::Put;
  }
  if (equals(method, methodLength, "DELETE")) {
    return BridgeDebugHttpMethod::Delete;
  }
  if (equals(method, methodLength, "PATCH")) {
    return BridgeDebugHttpMethod::Patch;
  }
  if (equals(method, methodLength, "OPTIONS")) {
    return BridgeDebugHttpMethod::Options;
  }
  return BridgeDebugHttpMethod::Custom;
}

bool isGetOrPost(BridgeDebugHttpMethod method) {
  return method == BridgeDebugHttpMethod::Get || method == BridgeDebugHttpMethod::Post;
}

}  // namespace

BridgeDebugHttpDecision evaluateBridgeDebugHttpRequestLine(const char* requestLine,
                                                           bool firstLineComplete,
                                                           bool requestLineOverflow,
                                                           bool requestLineInvalid,
                                                           char* cameraRequestTarget,
                                                           size_t cameraRequestTargetSize) {
  if (cameraRequestTarget != nullptr && cameraRequestTargetSize > 0) {
    cameraRequestTarget[0] = '\0';
  }
  if (requestLineOverflow) {
    return decision(BridgeDebugHttpMethod::Unknown,
                    BridgeDebugHttpRoute::Unknown,
                    BridgeDebugHttpDisposition::RejectUriTooLong,
                    414);
  }
  if (!firstLineComplete || requestLineInvalid || requestLine == nullptr ||
      cameraRequestTarget == nullptr ||
      cameraRequestTargetSize == 0) {
    return decision(BridgeDebugHttpMethod::Unknown,
                    BridgeDebugHttpRoute::Unknown,
                    BridgeDebugHttpDisposition::RejectBadRequest,
                    400);
  }

  const char* firstSpace = std::strchr(requestLine, ' ');
  if (firstSpace == nullptr || firstSpace == requestLine) {
    return decision(BridgeDebugHttpMethod::Unknown,
                    BridgeDebugHttpRoute::Unknown,
                    BridgeDebugHttpDisposition::RejectBadRequest,
                    400);
  }
  const size_t methodLength = static_cast<size_t>(firstSpace - requestLine);
  if (methodLength > kMaximumMethodLength) {
    return decision(BridgeDebugHttpMethod::Unknown,
                    BridgeDebugHttpRoute::Unknown,
                    BridgeDebugHttpDisposition::RejectBadRequest,
                    400);
  }
  for (size_t i = 0; i < methodLength; ++i) {
    if (requestLine[i] < 'A' || requestLine[i] > 'Z') {
      return decision(BridgeDebugHttpMethod::Unknown,
                      BridgeDebugHttpRoute::Unknown,
                      BridgeDebugHttpDisposition::RejectBadRequest,
                      400);
    }
  }
  const BridgeDebugHttpMethod method = parseMethod(requestLine, methodLength);

  const char* target = firstSpace + 1;
  const char* secondSpace = std::strchr(target, ' ');
  if (secondSpace == nullptr || secondSpace == target || std::strchr(secondSpace + 1, ' ') != nullptr) {
    return decision(method,
                    BridgeDebugHttpRoute::Unknown,
                    BridgeDebugHttpDisposition::RejectBadRequest,
                    400);
  }
  const size_t targetLength = static_cast<size_t>(secondSpace - target);
  if (targetLength >= cameraRequestTargetSize) {
    return decision(method,
                    BridgeDebugHttpRoute::Unknown,
                    BridgeDebugHttpDisposition::RejectUriTooLong,
                    414);
  }
  if (target[0] != '/') {
    return decision(method,
                    BridgeDebugHttpRoute::Unknown,
                    BridgeDebugHttpDisposition::RejectBadRequest,
                    400);
  }
  for (size_t i = 0; i < targetLength; ++i) {
    const unsigned char ch = static_cast<unsigned char>(target[i]);
    if (ch < 0x21u || ch > 0x7eu) {
      return decision(method,
                      BridgeDebugHttpRoute::Unknown,
                      BridgeDebugHttpDisposition::RejectBadRequest,
                      400);
    }
  }
  const char* version = secondSpace + 1;
  if (std::strcmp(version, "HTTP/1.0") != 0 && std::strcmp(version, "HTTP/1.1") != 0) {
    return decision(method,
                    BridgeDebugHttpRoute::Unknown,
                    BridgeDebugHttpDisposition::RejectBadRequest,
                    400);
  }

  constexpr const char* unsafeRoutes[] = {
      "/tone",         "/speaker-test", "/mic-tone",      "/mic-tone-soft",
      "/mic-tone-tap", "/mic-tone-old", "/wake-reset",    "/motion-resume",
      "/motion-on",    "/servos-on",    "/recover",       "/bridge-recover",
      "/wifi-recover", "/reboot",       "/restart",       "/reset",
      "/wake.wav",     "/wake-pcm.wav",
  };
  for (const char* unsafeRoute : unsafeRoutes) {
    if (isExactOrQuery(target, targetLength, unsafeRoute)) {
      return decision(method,
                      BridgeDebugHttpRoute::UnsafeControl,
                      BridgeDebugHttpDisposition::RejectForbidden,
                      403);
    }
  }

  if (equals(target, targetLength, "/")) {
    return method == BridgeDebugHttpMethod::Get
               ? decision(method, BridgeDebugHttpRoute::Root,
                          BridgeDebugHttpDisposition::ServeStatus, 200)
               : decision(method, BridgeDebugHttpRoute::Root,
                          BridgeDebugHttpDisposition::RejectMethod, 405);
  }
  if (equals(target, targetLength, "/debug")) {
    return method == BridgeDebugHttpMethod::Get
               ? decision(method, BridgeDebugHttpRoute::Debug,
                          BridgeDebugHttpDisposition::ServeDebug, 200)
               : decision(method, BridgeDebugHttpRoute::Debug,
                          BridgeDebugHttpDisposition::RejectMethod, 405);
  }

  for (const char* audioStop : {"/audio-stop", "/playback-stop"}) {
    if (equals(target, targetLength, audioStop)) {
      return isGetOrPost(method)
                 ? decision(method, BridgeDebugHttpRoute::AudioStop,
                            BridgeDebugHttpDisposition::EmergencyAudioStop, 202)
                 : decision(method, BridgeDebugHttpRoute::AudioStop,
                            BridgeDebugHttpDisposition::RejectMethod, 405);
    }
  }
  for (const char* motionStop : {"/motion-stop", "/motion-off", "/servos-off"}) {
    if (equals(target, targetLength, motionStop)) {
      return isGetOrPost(method)
                 ? decision(method, BridgeDebugHttpRoute::MotionStop,
                            BridgeDebugHttpDisposition::EmergencyMotionStop, 202)
                 : decision(method, BridgeDebugHttpRoute::MotionStop,
                            BridgeDebugHttpDisposition::RejectMethod, 405);
    }
  }

  if (isQueryFamily(target, targetLength, "/camera-gray.pgm")) {
    if (method != BridgeDebugHttpMethod::Get) {
      return decision(method,
                      BridgeDebugHttpRoute::CameraGray,
                      BridgeDebugHttpDisposition::RejectMethod,
                      405);
    }
    std::memcpy(cameraRequestTarget, target, targetLength);
    cameraRequestTarget[targetLength] = '\0';
    return decision(method,
                    BridgeDebugHttpRoute::CameraGray,
                    BridgeDebugHttpDisposition::CameraGray,
                    0);
  }
  if (isQueryFamily(target, targetLength, "/vision-target")) {
    if (method != BridgeDebugHttpMethod::Get) {
      return decision(method,
                      BridgeDebugHttpRoute::CameraVision,
                      BridgeDebugHttpDisposition::RejectMethod,
                      405);
    }
    std::memcpy(cameraRequestTarget, target, targetLength);
    cameraRequestTarget[targetLength] = '\0';
    return decision(method,
                    BridgeDebugHttpRoute::CameraVision,
                    BridgeDebugHttpDisposition::CameraVision,
                    0);
  }

  if (std::memchr(target, '?', targetLength) != nullptr) {
    return decision(method,
                    BridgeDebugHttpRoute::Unknown,
                    BridgeDebugHttpDisposition::RejectBadRequest,
                    400);
  }
  return decision(method,
                  BridgeDebugHttpRoute::Unknown,
                  BridgeDebugHttpDisposition::RejectNotFound,
                  404);
}

const char* bridgeDebugHttpMethodName(BridgeDebugHttpMethod method) {
  switch (method) {
    case BridgeDebugHttpMethod::Get: return "GET";
    case BridgeDebugHttpMethod::Post: return "POST";
    case BridgeDebugHttpMethod::Head: return "HEAD";
    case BridgeDebugHttpMethod::Put: return "PUT";
    case BridgeDebugHttpMethod::Delete: return "DELETE";
    case BridgeDebugHttpMethod::Patch: return "PATCH";
    case BridgeDebugHttpMethod::Options: return "OPTIONS";
    case BridgeDebugHttpMethod::Custom: return "CUSTOM";
    default: return "UNKNOWN";
  }
}

const char* bridgeDebugHttpRouteName(BridgeDebugHttpRoute route) {
  switch (route) {
    case BridgeDebugHttpRoute::Root: return "root";
    case BridgeDebugHttpRoute::Debug: return "debug";
    case BridgeDebugHttpRoute::AudioStop: return "audio_stop";
    case BridgeDebugHttpRoute::MotionStop: return "motion_stop";
    case BridgeDebugHttpRoute::UnsafeControl: return "unsafe_control";
    case BridgeDebugHttpRoute::CameraGray: return "camera_gray";
    case BridgeDebugHttpRoute::CameraVision: return "camera_vision";
    default: return "unknown";
  }
}

const char* bridgeDebugHttpDispositionName(BridgeDebugHttpDisposition disposition) {
  switch (disposition) {
    case BridgeDebugHttpDisposition::RejectBadRequest: return "rejected_bad_request";
    case BridgeDebugHttpDisposition::RejectForbidden: return "rejected_forbidden";
    case BridgeDebugHttpDisposition::RejectNotFound: return "rejected_not_found";
    case BridgeDebugHttpDisposition::RejectMethod: return "rejected_method";
    case BridgeDebugHttpDisposition::RejectUriTooLong: return "rejected_uri_too_long";
    case BridgeDebugHttpDisposition::ServeStatus: return "status";
    case BridgeDebugHttpDisposition::ServeDebug: return "debug";
    case BridgeDebugHttpDisposition::EmergencyAudioStop: return "audio_stop_accepted";
    case BridgeDebugHttpDisposition::EmergencyMotionStop: return "motion_stop_admitted";
    case BridgeDebugHttpDisposition::CameraGray: return "camera_gray";
    case BridgeDebugHttpDisposition::CameraVision: return "camera_vision";
    default: return "unknown";
  }
}
