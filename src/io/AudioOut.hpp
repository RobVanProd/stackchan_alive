#pragma once

#include <stdint.h>

namespace stackchan {

enum class AudioOutSource : uint8_t {
  None,
  PackagedPrompt,
};

struct AudioOutPlaybackRequest {
  uint32_t seq = 0;
  uint32_t queuedAtMs = 0;
  AudioOutSource source = AudioOutSource::None;
  const char* promptId = "";
  const char* wavPath = "";
  const char* sidecarPath = "";
  uint32_t earconSamples = 0;
  uint16_t earconDelayMs = 0;
  uint16_t promptChars = 0;
  bool hasPrompt = false;
  bool hasEarcon = false;
  bool duckOnBargeIn = true;
};

struct AudioOutTelemetry {
  bool ready = false;
  bool hardwareEnabled = false;
  bool taskPinnedToCore0 = false;
  uint32_t requestsQueued = 0;
  uint32_t requestsDropped = 0;
  uint32_t lastSeq = 0;
  AudioOutSource lastSource = AudioOutSource::None;
  const char* lastPromptId = "";
  const char* lastWavPath = "";
  const char* lastSidecarPath = "";
  uint32_t lastEarconSamples = 0;
};

class AudioOut {
 public:
  bool begin(bool hardwareEnabled = false);
  bool enqueue(const AudioOutPlaybackRequest& request);

  const AudioOutTelemetry& telemetry() const {
    return telemetry_;
  }

  const AudioOutPlaybackRequest& lastRequest() const {
    return lastRequest_;
  }

 private:
  AudioOutTelemetry telemetry_;
  AudioOutPlaybackRequest lastRequest_;
};

}  // namespace stackchan
