#pragma once

#include <Arduino.h>

namespace stackchan {

constexpr uint8_t kActiveSpeakerMaxFaces = 4;

struct FaceCandidate {
  float x = 0.0f;
  float y = 0.0f;
  float size = 0.0f;
  float confidence = 1.0f;
};

struct ActiveSpeakerTarget {
  bool valid = false;
  float x = 0.0f;
  float y = 0.0f;
  float size = 0.0f;
  float confidence = 0.0f;
  bool audioMatched = false;
  float audioDirectionError = 1.0f;
  bool heldForReply = false;
  uint32_t selectedAtMs = 0;
};

class ActiveSpeakerTracker {
 public:
  void reset(uint32_t nowMs = 0);
  void updateSoundDirection(float azimuthNorm, float strength, uint32_t nowMs);
  ActiveSpeakerTarget updateFaces(const FaceCandidate* faces, uint8_t count, uint32_t nowMs);
  void setRobotSpeaking(bool speaking, uint32_t nowMs);
  ActiveSpeakerTarget target(uint32_t nowMs) const;

 private:
  ActiveSpeakerTarget target_;
  float soundAzimuthNorm_ = 0.0f;
  float soundStrength_ = 0.0f;
  uint32_t soundAtMs_ = 0;
  uint32_t lastFaceAtMs_ = 0;
  uint32_t replyStartedAtMs_ = 0;
  bool robotSpeaking_ = false;
};

}  // namespace stackchan
