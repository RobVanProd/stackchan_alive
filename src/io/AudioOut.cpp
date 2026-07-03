#include "io/AudioOut.hpp"

namespace stackchan {

bool AudioOut::begin(bool hardwareEnabled) {
  telemetry_ = AudioOutTelemetry {};
  lastRequest_ = AudioOutPlaybackRequest {};
  telemetry_.ready = true;
  telemetry_.hardwareEnabled = hardwareEnabled;
  telemetry_.taskPinnedToCore0 = false;
  return true;
}

bool AudioOut::enqueue(const AudioOutPlaybackRequest& request) {
  if (!telemetry_.ready || request.seq == 0 || (!request.hasPrompt && !request.hasEarcon)) {
    telemetry_.requestsDropped++;
    return false;
  }

  lastRequest_ = request;
  telemetry_.requestsQueued++;
  telemetry_.lastSeq = request.seq;
  telemetry_.lastSource = request.source;
  telemetry_.lastPromptId = request.promptId;
  telemetry_.lastWavPath = request.wavPath;
  telemetry_.lastSidecarPath = request.sidecarPath;
  telemetry_.lastEarconSamples = request.earconSamples;
  return true;
}

}  // namespace stackchan
