#include "io/CameraHostProtocol.hpp"

#include <cstdlib>
#include <cstring>

namespace stackchan {
namespace {

bool parseScaled(const char** cursor, int minimum, int maximum, float* valueOut) {
  if (cursor == nullptr || *cursor == nullptr || valueOut == nullptr) return false;
  char* end = nullptr;
  const long value = std::strtol(*cursor, &end, 10);
  if (end == *cursor || value < minimum || value > maximum) return false;
  *cursor = end;
  *valueOut = static_cast<float>(value) / 1000.0f;
  return true;
}

bool parsePairingCode(const char** cursor, char* out, size_t outSize) {
  if (cursor == nullptr || *cursor == nullptr || out == nullptr || outSize < 7) return false;
  const char* start = *cursor;
  for (size_t i = 0; i < 6; ++i) {
    if (start[i] < '0' || start[i] > '9') return false;
    out[i] = start[i];
  }
  if (start[6] != '&' && start[6] != '\0') return false;
  out[6] = '\0';
  *cursor = start + 6;
  return true;
}

}  // namespace

bool parseCameraHostPairingCode(const char* requestTarget,
                                const char* expectedPath,
                                char* pairingCodeOut,
                                size_t pairingCodeOutSize) {
  if (requestTarget == nullptr || expectedPath == nullptr || pairingCodeOut == nullptr) {
    return false;
  }
  const size_t pathLength = std::strlen(expectedPath);
  const size_t targetLength = std::strlen(requestTarget);
  if (targetLength < pathLength + 9 ||
      std::strncmp(requestTarget, expectedPath, pathLength) != 0 ||
      std::strncmp(requestTarget + pathLength, "?p=", 3) != 0) {
    return false;
  }
  const char* cursor = requestTarget + pathLength + 3;
  return parsePairingCode(&cursor, pairingCodeOut, pairingCodeOutSize) && *cursor == '\0';
}

bool parseCameraHostVisionTarget(const char* requestTarget,
                                 CameraHostVisionTarget* targetOut) {
  if (requestTarget == nullptr || targetOut == nullptr) return false;
  constexpr const char* kPrefix = "/vision-target?p=";
  constexpr size_t kPrefixLength = 17;
  if (std::strlen(requestTarget) < kPrefixLength + 9 ||
      std::strncmp(requestTarget, kPrefix, kPrefixLength) != 0) {
    return false;
  }

  CameraHostVisionTarget parsed;
  const char* cursor = requestTarget + kPrefixLength;
  if (!parsePairingCode(&cursor, parsed.pairingCode, sizeof(parsed.pairingCode)) ||
      std::strncmp(cursor, "&f=", 3) != 0) {
    return false;
  }
  cursor += 3;
  if (*cursor == '\0') {
    *targetOut = parsed;
    return true;
  }

  while (*cursor != '\0' && parsed.faceCount < kActiveSpeakerMaxFaces) {
    FaceCandidate face;
    if (!parseScaled(&cursor, -1000, 1000, &face.x) || *cursor++ != ',' ||
        !parseScaled(&cursor, -1000, 1000, &face.y) || *cursor++ != ',' ||
        !parseScaled(&cursor, 0, 1000, &face.size) || *cursor++ != ',' ||
        !parseScaled(&cursor, 0, 1000, &face.confidence)) {
      return false;
    }
    parsed.faces[parsed.faceCount++] = face;
    if (*cursor == '\0') break;
    if (*cursor++ != ';') return false;
  }
  if (*cursor != '\0') return false;
  *targetOut = parsed;
  return true;
}

}  // namespace stackchan
