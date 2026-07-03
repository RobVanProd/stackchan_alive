#pragma once

#include <stdint.h>

namespace stackchan {

enum class AudioOutSource : uint8_t {
  None,
  PackagedPrompt,
};

enum class AudioOutViseme : uint8_t {
  Neutral,
  Ah,
  Oh,
  Ee,
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

struct AudioOutSpeechFrame {
  bool active = false;
  bool clear = false;
  float envelope = 0.0f;
  AudioOutViseme viseme = AudioOutViseme::Neutral;
  uint32_t seq = 0;
  uint32_t timestampMs = 0;
  uint16_t durationMs = 80;
};

struct AudioOutTelemetry {
  bool ready = false;
  bool hardwareEnabled = false;
  bool taskPinnedToCore0 = false;
  bool playbackActive = false;
  bool duckActive = false;
  uint32_t requestsQueued = 0;
  uint32_t requestsDropped = 0;
  uint32_t playbackCompleted = 0;
  uint32_t speechFramesEmitted = 0;
  uint32_t duckEvents = 0;
  uint32_t lastSeq = 0;
  uint32_t playbackSeq = 0;
  uint32_t playbackStartedMs = 0;
  uint32_t playbackElapsedMs = 0;
  uint32_t playbackDurationMs = 0;
  uint16_t sidecarFrameMs = 0;
  uint16_t sidecarFrames = 0;
  AudioOutSource lastSource = AudioOutSource::None;
  const char* lastPromptId = "";
  const char* lastWavPath = "";
  const char* lastSidecarPath = "";
  uint32_t lastEarconSamples = 0;
  float lastEnvelope = 0.0f;
  AudioOutViseme lastViseme = AudioOutViseme::Neutral;
};

class AudioOut {
 public:
  bool begin(bool hardwareEnabled = false);
  bool enqueue(const AudioOutPlaybackRequest& request);
  bool pollSpeechFrame(uint32_t nowMs, AudioOutSpeechFrame* frameOut);
  bool duck(uint32_t nowMs);

  const AudioOutTelemetry& telemetry() const {
    return telemetry_;
  }

  const AudioOutPlaybackRequest& lastRequest() const {
    return lastRequest_;
  }

 private:
  struct SidecarTiming {
    uint16_t frameMs = 20;
    uint16_t frames = 0;
    uint32_t durationMs = 0;
    uint8_t voiceShape = 0;
  };

  struct PlaybackState {
    bool active = false;
    bool clearPending = false;
    bool duckActive = false;
    uint32_t seq = 0;
    uint32_t startMs = 0;
    uint32_t promptStartMs = 0;
    uint32_t durationMs = 0;
    uint32_t duckUntilMs = 0;
    int32_t lastFrameIndex = -1;
    SidecarTiming timing;
  };

  static SidecarTiming resolveSidecar(const AudioOutPlaybackRequest& request);
  static float envelopeForFrame(const SidecarTiming& timing, uint32_t frameIndex);
  static AudioOutViseme visemeForFrame(const SidecarTiming& timing, uint32_t frameIndex, float envelope);

  AudioOutTelemetry telemetry_;
  AudioOutPlaybackRequest lastRequest_;
  PlaybackState playback_;
};

}  // namespace stackchan
