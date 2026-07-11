#pragma once

#include <cstddef>
#include <cstdint>

#include "persona/ActiveSpeakerTracker.hpp"

namespace stackchan {

struct CameraHostVisionTarget {
  char pairingCode[7] = {};
  FaceCandidate faces[kActiveSpeakerMaxFaces] = {};
  uint8_t faceCount = 0;
};

bool parseCameraHostPairingCode(const char* requestTarget,
                                const char* expectedPath,
                                char* pairingCodeOut,
                                size_t pairingCodeOutSize);

bool parseCameraHostVisionTarget(const char* requestTarget,
                                 CameraHostVisionTarget* targetOut);

}  // namespace stackchan
