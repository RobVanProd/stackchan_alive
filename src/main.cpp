#include <Arduino.h>
#include <Esp.h>
#include <M5Unified.h>
#include <freertos/FreeRTOS.h>
#include <freertos/queue.h>
#include <freertos/task.h>

#include "config/RobotConfig.hpp"
#include "face/ProceduralFace.hpp"
#include "io/AudioCaptureAdapter.hpp"
#include "io/AudioOut.hpp"
#include "io/BridgeAudioDownlink.hpp"
#include "io/BridgeAudioUplink.hpp"
#include "io/BridgeClient.hpp"
#include "io/BridgeEndpointControl.hpp"
#include "io/BridgeEndpointRegistry.hpp"
#include "io/BridgeEndpointStore.hpp"
#include "io/BridgeNetworkSession.hpp"
#include "io/BridgeWakeGate.hpp"
#include "io/BridgeWiFiClientSocket.hpp"
#include "io/BridgeWiFiProvisioner.hpp"
#include "io/CameraAdapter.hpp"
#include "io/DisplayAdapter.hpp"
#include "io/SensorAdapter.hpp"
#include "io/SpeechAdapter.hpp"
#include "io/StackChanServoAdapter.hpp"
#include "motion/ActuationEngine.hpp"
#include "persona/IntentEngine.hpp"
#include "persona/StateMatrix.hpp"

#if __has_include("FirmwareVoiceAssets.hpp")
#include "FirmwareVoiceAssets.hpp"
#define STACKCHAN_HAS_FIRMWARE_VOICE_ASSETS 1
#else
#define STACKCHAN_HAS_FIRMWARE_VOICE_ASSETS 0
#endif

#ifndef STACKCHAN_ENABLE_SPEAKER
#define STACKCHAN_ENABLE_SPEAKER 0
#endif

using namespace stackchan;

namespace {

QueueHandle_t gFrameQueue = nullptr;
QueueHandle_t gSpeechQueue = nullptr;
QueueHandle_t gFaceControlQueue = nullptr;
QueueHandle_t gMotionControlQueue = nullptr;
RobotConfig gConfig = defaultRobotConfig();
StackChanServoAdapter gServo;
DisplayAdapter gDisplay;
SensorAdapter gSensors;
CameraAdapter gCamera;
AudioCaptureAdapter gAudioCapture;
M5MicAudioCaptureSource gAudioCaptureSource;
AudioOut gAudioOut;
BridgeAudioDownlink gBridgeAudioDownlink;
BridgeAudioUplink gBridgeAudioUplink;
SpeechAdapter gSpeechAdapter;
BridgeClient gBridge;
BridgeEndpointRegistry gBridgeEndpointRegistry;
BridgeEndpointControl gBridgeEndpointControl;
BridgeEndpointStore gBridgeEndpointStore;
BridgeWakeGate gBridgeWakeGate;
BridgeWiFiProvisioner gBridgeWiFi;
BridgeNetworkSession gBridgeNetworkSession;
BridgeWiFiClientSocket gBridgeSocket;
#if defined(ARDUINO_ARCH_ESP32)
BridgeEndpointPreferencesStore gBridgeEndpointStoreBackend;
#else
BridgeEndpointMemoryStore gBridgeEndpointStoreBackend;
#endif
ActuationEngine gActuation(gConfig);
ProceduralFace gFace;
IntentEngine gIntent;
TaskHandle_t gMotionTaskHandle = nullptr;
TaskHandle_t gFaceTaskHandle = nullptr;
TaskHandle_t gIntentTaskHandle = nullptr;

struct FaceSpeechInput {
  bool clear = false;
  float envelope = 0.0f;
  SpeechViseme viseme = SpeechViseme::Neutral;
  uint32_t timestampMs = 0;
  uint32_t durationMs = 0;
};

struct FaceControlInput {
  bool hasReducedMotion = false;
  bool reducedMotion = false;
};

struct MotionControlInput {
  bool hasMotionEnable = false;
  bool motionEnabled = true;
};

class M5SpeakerAudioSink : public AudioOutSpeakerSink, public BridgeAudioDownlinkSink {
 public:
  bool begin() override {
    if (!M5.Speaker.begin()) {
      ready_ = false;
      return false;
    }
    M5.Speaker.setVolume(96);
    M5.Speaker.setChannelVolume(kChannel, 255);
    ready_ = true;
    return true;
  }

  bool start(const AudioOutPlaybackRequest& request, uint32_t promptStartMs, uint32_t durationMs) override {
    (void)promptStartMs;
    (void)durationMs;
    if (!ready_) {
      return false;
    }
    M5.Speaker.stop(kChannel);
    active_ = true;
    phase_ = 0;
    phaseFifth_ = 0;
    noise_ = 0x1234abcd;
#if STACKCHAN_HAS_FIRMWARE_VOICE_ASSETS
    const firmware_voice::FirmwareVoiceAsset* asset = firmware_voice::find(request.wavPath);
    if (asset != nullptr) {
      wavActive_ = M5.Speaker.playWav(asset->data, asset->size, 1, kChannel, true);
      M5.Speaker.setChannelVolume(kChannel, 255);
    } else {
      wavActive_ = false;
    }
#else
    wavActive_ = false;
#endif
    return true;
  }

  bool writeFrame(const AudioOutHardwareFrame& frame) override {
    if (!ready_ || !active_) {
      return false;
    }
    if (frame.clear || !frame.active) {
      stop();
      return true;
    }

    if (wavActive_) {
      M5.Speaker.setChannelVolume(kChannel, frame.ducked ? 84 : 255);
      return true;
    }

    renderFrame(frame);
    return M5.Speaker.playRaw(samples_, kSamplesPerFrame, kSampleRate, false, 1, kChannel, false);
  }

  bool start(const BridgeAudioStream& stream, uint32_t nowMs) override {
    (void)nowMs;
    if (!ready_) {
      return false;
    }
    M5.Speaker.stop(kChannel);
    active_ = false;
    wavActive_ = false;
    downlinkActive_ = true;
    downlinkSampleRate_ = stream.sampleRate >= 8000 && stream.sampleRate <= 48000 ? stream.sampleRate : kSampleRate;
    M5.Speaker.setChannelVolume(kChannel, 255);
    return true;
  }

  bool writeChunk(const BridgeAudioStreamChunk& chunk, uint32_t nowMs) override {
    (void)nowMs;
    if (!ready_ || !downlinkActive_ || chunk.payload == nullptr || chunk.payloadBytes < 2) {
      return false;
    }

    const size_t sampleCount = min(static_cast<size_t>(chunk.payloadBytes / 2u), kMaxStreamSamples);
    for (size_t i = 0; i < sampleCount; ++i) {
      const uint8_t lo = chunk.payload[i * 2u];
      const uint8_t hi = chunk.payload[i * 2u + 1u];
      streamSamples_[i] = static_cast<int16_t>(static_cast<uint16_t>(lo) | (static_cast<uint16_t>(hi) << 8));
    }
    return M5.Speaker.playRaw(streamSamples_, sampleCount, downlinkSampleRate_, false, 1, kChannel, false);
  }

  void stop() override {
    if (!ready_) {
      return;
    }
    M5.Speaker.stop(kChannel);
    active_ = false;
    wavActive_ = false;
    downlinkActive_ = false;
  }

  void stop(uint32_t nowMs) override {
    (void)nowMs;
    stop();
  }

  bool isReady() const override {
    return ready_;
  }

 private:
  static constexpr int kChannel = 0;
  static constexpr uint32_t kSampleRate = 22050;
  static constexpr size_t kSamplesPerFrame = 441;
  static constexpr size_t kMaxStreamSamples = kBridgeAudioStreamChunkPayloadMax / 2u;

  static uint32_t frequencyForViseme(AudioOutViseme viseme) {
    switch (viseme) {
      case AudioOutViseme::Ah:
        return 190;
      case AudioOutViseme::Oh:
        return 145;
      case AudioOutViseme::Ee:
        return 260;
      case AudioOutViseme::Neutral:
        return 115;
    }
    return 160;
  }

  void renderFrame(const AudioOutHardwareFrame& frame) {
    const uint32_t baseFrequency = frequencyForViseme(frame.viseme);
    const uint32_t fifthFrequency = (baseFrequency * 3u) / 2u;
    const int32_t gain = static_cast<int32_t>(frame.envelope * (frame.ducked ? 2600.0f : 7200.0f));
    const uint32_t sampleHold = frame.viseme == AudioOutViseme::Neutral ? 13u : 7u;

    for (size_t i = 0; i < kSamplesPerFrame; ++i) {
      phase_ += baseFrequency;
      if (phase_ >= kSampleRate) {
        phase_ -= kSampleRate;
      }
      phaseFifth_ += fifthFrequency;
      if (phaseFifth_ >= kSampleRate) {
        phaseFifth_ -= kSampleRate;
      }

      if ((i % sampleHold) == 0) {
        noise_ = noise_ * 1664525u + 1013904223u;
        heldNoise_ = static_cast<int32_t>((noise_ >> 23) & 0x1ffu) - 256;
      }

      const int32_t saw = (static_cast<int32_t>(phase_) * 2 * 32767 / static_cast<int32_t>(kSampleRate)) - 32767;
      const int32_t fifth = phaseFifth_ < (kSampleRate / 2u) ? 6000 : -6000;
      int32_t sample = ((saw / 5) + fifth + heldNoise_ * 12) * gain / 8192;
      if (sample > 32767) {
        sample = 32767;
      } else if (sample < -32768) {
        sample = -32768;
      }
      samples_[i] = static_cast<int16_t>(sample);
    }
  }

  bool ready_ = false;
  bool active_ = false;
  bool wavActive_ = false;
  bool downlinkActive_ = false;
  uint32_t downlinkSampleRate_ = kSampleRate;
  uint32_t phase_ = 0;
  uint32_t phaseFifth_ = 0;
  uint32_t noise_ = 0x1234abcd;
  int32_t heldNoise_ = 0;
  int16_t samples_[kSamplesPerFrame] {};
  int16_t streamSamples_[kMaxStreamSamples] {};
};

M5SpeakerAudioSink gSpeakerSink;
char gBridgeSpeechText[kBridgeTextMax] = {};
char gBridgeEndpointResponse[kBridgeEndpointControlResponseMax] = {};

const __FlashStringHelper* firmwareMode() {
#if STACKCHAN_ENABLE_SERVOS
  return F("servo_calibration");
#else
  return F("display_only");
#endif
}

const __FlashStringHelper* characterModeName(CharacterMode mode) {
  switch (mode) {
    case CharacterMode::Boot:
      return F("boot");
    case CharacterMode::Idle:
      return F("idle");
    case CharacterMode::Attend:
      return F("attend");
    case CharacterMode::Listen:
      return F("listen");
    case CharacterMode::Think:
      return F("think");
    case CharacterMode::Speak:
      return F("speak");
    case CharacterMode::React:
      return F("react");
    case CharacterMode::Sleep:
      return F("sleep");
    case CharacterMode::Error:
      return F("error");
  }
  return F("unknown");
}

const __FlashStringHelper* eventTypeName(EventType type) {
  switch (type) {
    case EventType::Boot:
      return F("boot");
    case EventType::FaceDetected:
      return F("face_detected");
    case EventType::FaceLost:
      return F("face_lost");
    case EventType::UserNear:
      return F("user_near");
    case EventType::UserTouched:
      return F("user_touched");
    case EventType::WakeWord:
      return F("wake_word");
    case EventType::UserSpeaking:
      return F("user_speaking");
    case EventType::SpeechEnded:
      return F("speech_ended");
    case EventType::ThinkingStarted:
      return F("thinking_started");
    case EventType::ResponseStarted:
      return F("response_started");
    case EventType::ResponseEnded:
      return F("response_ended");
    case EventType::IdleTimeout:
      return F("idle_timeout");
    case EventType::Error:
      return F("error");
    case EventType::PickedUp:
      return F("picked_up");
    case EventType::Shaken:
      return F("shaken");
    case EventType::PutDown:
      return F("put_down");
    case EventType::Tilted:
      return F("tilted");
    case EventType::SoundDirection:
      return F("sound_direction");
    case EventType::LoudNoise:
      return F("loud_noise");
  }
  return F("unknown");
}

bool isAudioTelemetryEvent(EventType type) {
  return type == EventType::SoundDirection || type == EventType::LoudNoise ||
         type == EventType::UserSpeaking || type == EventType::SpeechEnded;
}

CharacterMode visionModeForEvent(EventType type) {
  return type == EventType::FaceLost ? CharacterMode::Idle : CharacterMode::Attend;
}

CharacterMode bridgeModeForEvent(EventType type) {
  switch (type) {
    case EventType::UserSpeaking:
      return CharacterMode::Listen;
    case EventType::ThinkingStarted:
      return CharacterMode::Think;
    case EventType::ResponseStarted:
      return CharacterMode::Speak;
    case EventType::ResponseEnded:
      return CharacterMode::Attend;
    case EventType::Error:
      return CharacterMode::Error;
    default:
      break;
  }
  return CharacterMode::Attend;
}

const __FlashStringHelper* speechVisemeName(SpeechViseme viseme) {
  switch (viseme) {
    case SpeechViseme::Ah:
      return F("ah");
    case SpeechViseme::Oh:
      return F("oh");
    case SpeechViseme::Ee:
      return F("ee");
    case SpeechViseme::Neutral:
      return F("neutral");
  }
  return F("unknown");
}

SpeechViseme toSpeechViseme(BenchSpeechViseme viseme) {
  switch (viseme) {
    case BenchSpeechViseme::Ah:
      return SpeechViseme::Ah;
    case BenchSpeechViseme::Oh:
      return SpeechViseme::Oh;
    case BenchSpeechViseme::Ee:
      return SpeechViseme::Ee;
    case BenchSpeechViseme::Neutral:
      return SpeechViseme::Neutral;
  }
  return SpeechViseme::Neutral;
}

SpeechViseme toSpeechViseme(AudioOutViseme viseme) {
  switch (viseme) {
    case AudioOutViseme::Ah:
      return SpeechViseme::Ah;
    case AudioOutViseme::Oh:
      return SpeechViseme::Oh;
    case AudioOutViseme::Ee:
      return SpeechViseme::Ee;
    case AudioOutViseme::Neutral:
      return SpeechViseme::Neutral;
  }
  return SpeechViseme::Neutral;
}

const __FlashStringHelper* speechIntentName(SpeechIntent intent) {
  switch (intent) {
    case SpeechIntent::Boot:
      return F("boot");
    case SpeechIntent::Idle:
      return F("idle");
    case SpeechIntent::Attend:
      return F("attend");
    case SpeechIntent::Listen:
      return F("listen");
    case SpeechIntent::Think:
      return F("think");
    case SpeechIntent::Speak:
      return F("speak");
    case SpeechIntent::React:
      return F("react");
    case SpeechIntent::Happy:
      return F("happy");
    case SpeechIntent::Concern:
      return F("concern");
    case SpeechIntent::Sleep:
      return F("sleep");
    case SpeechIntent::Error:
      return F("error");
    case SpeechIntent::Safety:
      return F("safety");
    case SpeechIntent::None:
      break;
  }
  return F("none");
}

const __FlashStringHelper* speechEarconName(SpeechEarcon earcon) {
  switch (earcon) {
    case SpeechEarcon::Wake:
      return F("wake");
    case SpeechEarcon::Confirm:
      return F("confirm");
    case SpeechEarcon::Think:
      return F("think");
    case SpeechEarcon::Happy:
      return F("happy");
    case SpeechEarcon::Concern:
      return F("concern");
    case SpeechEarcon::Sleep:
      return F("sleep");
    case SpeechEarcon::Error:
      return F("error");
    case SpeechEarcon::Safety:
      return F("safety");
    case SpeechEarcon::None:
      break;
  }
  return F("none");
}

const __FlashStringHelper* promptSourceName(PromptSource source) {
  switch (source) {
    case PromptSource::PackagedPrompt:
      return F("packaged_prompt");
    case PromptSource::HostBridge:
      return F("host_bridge");
    case PromptSource::None:
      break;
  }
  return F("none");
}

const __FlashStringHelper* audioOutSourceName(AudioOutSource source) {
  switch (source) {
    case AudioOutSource::PackagedPrompt:
      return F("packaged_prompt");
    case AudioOutSource::None:
      break;
  }
  return F("none");
}

const __FlashStringHelper* bridgeOutputTypeName(BridgeClientOutputType type) {
  switch (type) {
    case BridgeClientOutputType::SessionReady:
      return F("session_ready");
    case BridgeClientOutputType::Event:
      return F("event");
    case BridgeClientOutputType::ResponseStart:
      return F("response_start");
    case BridgeClientOutputType::AudioFrame:
      return F("audio");
    case BridgeClientOutputType::AudioStreamStart:
      return F("audio_stream_start");
    case BridgeClientOutputType::AudioStreamChunk:
      return F("audio_stream_chunk");
    case BridgeClientOutputType::AudioStreamEnd:
      return F("audio_stream_end");
    case BridgeClientOutputType::ResponseEnd:
      return F("response_end");
    case BridgeClientOutputType::Error:
      return F("error");
    case BridgeClientOutputType::None:
      break;
  }
  return F("none");
}

const __FlashStringHelper* bridgeStateName(BridgeClientState state) {
  switch (state) {
    case BridgeClientState::Offline:
      return F("offline");
    case BridgeClientState::Connecting:
      return F("connecting");
    case BridgeClientState::Ready:
      return F("ready");
    case BridgeClientState::Listening:
      return F("listening");
    case BridgeClientState::Thinking:
      return F("thinking");
    case BridgeClientState::Responding:
      return F("responding");
    case BridgeClientState::Error:
      return F("error");
  }
  return F("unknown");
}

const __FlashStringHelper* bridgeNetworkStateName(BridgeNetworkSessionState state) {
  switch (state) {
    case BridgeNetworkSessionState::Idle:
      return F("idle");
    case BridgeNetworkSessionState::Connecting:
      return F("connecting");
    case BridgeNetworkSessionState::Handshaking:
      return F("handshaking");
    case BridgeNetworkSessionState::Connected:
      return F("connected");
    case BridgeNetworkSessionState::Backoff:
      return F("backoff");
    case BridgeNetworkSessionState::Error:
      return F("error");
  }
  return F("unknown");
}

const __FlashStringHelper* bridgeUploadActionName(BenchBridgeUploadAction action) {
  switch (action) {
    case BenchBridgeUploadAction::Start:
      return F("start");
    case BenchBridgeUploadAction::Chunk:
      return F("chunk");
    case BenchBridgeUploadAction::End:
      return F("end");
    case BenchBridgeUploadAction::Abort:
      return F("abort");
    case BenchBridgeUploadAction::None:
      break;
  }
  return F("none");
}

SpeechEarcon earconForIntent(SpeechIntent intent) {
  switch (intent) {
    case SpeechIntent::Boot:
    case SpeechIntent::Listen:
      return SpeechEarcon::Wake;
    case SpeechIntent::Idle:
    case SpeechIntent::Think:
      return SpeechEarcon::Think;
    case SpeechIntent::Happy:
      return SpeechEarcon::Happy;
    case SpeechIntent::Concern:
      return SpeechEarcon::Concern;
    case SpeechIntent::Sleep:
      return SpeechEarcon::Sleep;
    case SpeechIntent::Error:
      return SpeechEarcon::Error;
    case SpeechIntent::Safety:
      return SpeechEarcon::Safety;
    case SpeechIntent::Attend:
    case SpeechIntent::Speak:
    case SpeechIntent::React:
    case SpeechIntent::None:
      break;
  }
  return SpeechEarcon::Confirm;
}

void printBootMarker() {
  Serial.print(F("[boot] stackchan_alive mode="));
  Serial.print(firmwareMode());
  Serial.println(F(" serial=v1"));
}

void printHeartbeat() {
  Serial.print(F("[heartbeat] stackchan_alive mode="));
  Serial.print(firmwareMode());
  Serial.print(F(" uptime_ms="));
  Serial.println(millis());
}

UBaseType_t stackHighWater(TaskHandle_t handle) {
  return handle == nullptr ? 0 : uxTaskGetStackHighWaterMark(handle);
}

void printSystemTelemetry() {
  Serial.print(F("[system] heap_free="));
  Serial.print(ESP.getFreeHeap());
  Serial.print(F(" heap_min="));
  Serial.print(ESP.getMinFreeHeap());
  Serial.print(F(" stack_loop_hwm="));
  Serial.print(uxTaskGetStackHighWaterMark(nullptr));
  Serial.print(F(" stack_motion_hwm="));
  Serial.print(stackHighWater(gMotionTaskHandle));
  Serial.print(F(" stack_face_hwm="));
  Serial.print(stackHighWater(gFaceTaskHandle));
  Serial.print(F(" stack_intent_hwm="));
  Serial.println(stackHighWater(gIntentTaskHandle));
}

void printRuntimeStatus() {
  const FaceSpeechTelemetry& speech = gFace.speechTelemetry();
  Serial.print(F("[runtime] motion_enabled="));
  Serial.print(gActuation.isEnabled() ? 1 : 0);
  Serial.print(F(" demo_enabled="));
  Serial.print(gIntent.isDemoEnabled() ? 1 : 0);
  Serial.print(F(" reduced_motion="));
  Serial.print(gFace.isReducedMotion() ? 1 : 0);
  Serial.print(F(" speech_active="));
  Serial.print(speech.active ? 1 : 0);
  Serial.print(F(" speech_env="));
  Serial.print(speech.envelope, 2);
  const CameraAdapterTelemetry& camera = gCamera.telemetry();
  Serial.print(F(" camera_ready="));
  Serial.print(camera.ready ? 1 : 0);
  Serial.print(F(" camera_hw="));
  Serial.print(camera.hardwareEnabled ? 1 : 0);
  Serial.print(F(" camera_active="));
  Serial.print(camera.active ? 1 : 0);
  Serial.print(F(" camera_events="));
  Serial.print(camera.eventsPublished);
  const SpeechAdapterTelemetry& speechOut = gSpeechAdapter.telemetry();
  const AudioOutTelemetry& audioOut = gAudioOut.telemetry();
  Serial.print(F(" speech_adapter_ready="));
  Serial.print(speechOut.ready ? 1 : 0);
  Serial.print(F(" speech_adapter_hw="));
  Serial.print(speechOut.hardwareEnabled ? 1 : 0);
  const AudioCaptureTelemetry& capture = gAudioCapture.telemetry();
  Serial.print(F(" audio_capture_ready="));
  Serial.print(capture.ready ? 1 : 0);
  Serial.print(F(" audio_capture_enabled="));
  Serial.print(capture.enabled ? 1 : 0);
  Serial.print(F(" audio_capture_hw_ready="));
  Serial.print(capture.hardwareReady ? 1 : 0);
  Serial.print(F(" audio_capture_windows="));
  Serial.print(capture.windowsCaptured);
  Serial.print(F(" audio_capture_drops="));
  Serial.print(capture.windowsDropped);
  Serial.print(F(" audio_capture_events="));
  Serial.print(capture.eventsPublished);
  Serial.print(F(" audio_capture_level="));
  Serial.print(capture.lastLevel, 3);
  Serial.print(F(" audio_capture_zcr="));
  Serial.print(capture.lastZeroCrossingRate, 3);
  Serial.print(F(" speech_cues="));
  Serial.print(speechOut.cuesQueued);
  Serial.print(F(" speech_earcons="));
  Serial.print(speechOut.earconsRendered);
  Serial.print(F(" audio_out_ready="));
  Serial.print(audioOut.ready ? 1 : 0);
  Serial.print(F(" audio_out_hw="));
  Serial.print(audioOut.hardwareEnabled ? 1 : 0);
  Serial.print(F(" audio_out_hw_ready="));
  Serial.print(audioOut.hardwareReady ? 1 : 0);
  Serial.print(F(" audio_out_core0="));
  Serial.print(audioOut.taskPinnedToCore0 ? 1 : 0);
  Serial.print(F(" audio_out_requests="));
  Serial.print(audioOut.requestsQueued);
  Serial.print(F(" audio_out_playing="));
  Serial.print(audioOut.playbackActive ? 1 : 0);
  Serial.print(F(" audio_out_frames="));
  Serial.print(audioOut.speechFramesEmitted);
  Serial.print(F(" audio_out_ducks="));
  Serial.print(audioOut.duckEvents);
  Serial.print(F(" audio_out_hw_frames="));
  Serial.print(audioOut.hardwareFramesSubmitted);
  Serial.print(F(" audio_out_hw_drops="));
  Serial.print(audioOut.hardwareFrameDrops);
  const BridgeClientTelemetry& bridge = gBridge.telemetry();
  Serial.print(F(" bridge_ready="));
  Serial.print(bridge.ready ? 1 : 0);
  Serial.print(F(" bridge_state="));
  Serial.print(bridgeStateName(bridge.state));
  Serial.print(F(" bridge_messages="));
  Serial.print(bridge.inboundMessages);
  Serial.print(F(" bridge_outputs="));
  Serial.print(bridge.outputsQueued);
  Serial.print(F(" bridge_parse_errors="));
  Serial.print(bridge.parseErrors);
  Serial.print(F(" bridge_audio_streams="));
  Serial.print(bridge.audioStreamsStarted);
  Serial.print(F(" bridge_audio_stream_bytes="));
  Serial.print(bridge.audioStreamBytes);
  Serial.print(F(" bridge_audio_stream_bytes_received="));
  Serial.print(bridge.audioStreamBytesReceived);
  Serial.print(F(" bridge_audio_stream_chunks="));
  Serial.print(bridge.audioStreamChunksReceived);
  Serial.print(F(" bridge_audio_stream_errors="));
  Serial.print(bridge.audioStreamErrors);
  Serial.print(F(" bridge_audio_stream_active="));
  Serial.print(bridge.audioStreamActive ? 1 : 0);
  const BridgeWiFiProvisioningTelemetry& wifi = gBridgeWiFi.telemetry();
  Serial.print(F(" bridge_wifi_ready="));
  Serial.print(wifi.ready ? 1 : 0);
  Serial.print(F(" bridge_wifi_configured="));
  Serial.print(wifi.configured ? 1 : 0);
  Serial.print(F(" bridge_wifi_connecting="));
  Serial.print(wifi.connecting ? 1 : 0);
  Serial.print(F(" bridge_wifi_connected="));
  Serial.print(wifi.connected ? 1 : 0);
  Serial.print(F(" bridge_wifi_attempts="));
  Serial.print(wifi.beginAttempts);
  Serial.print(F(" bridge_wifi_failures="));
  Serial.print(wifi.connectFailures);
  Serial.print(F(" bridge_wifi_status="));
  Serial.print(wifi.status);
  const BridgeNetworkSessionTelemetry& network = gBridgeNetworkSession.telemetry();
  Serial.print(F(" bridge_network_ready="));
  Serial.print(network.ready ? 1 : 0);
  Serial.print(F(" bridge_network_state="));
  Serial.print(bridgeNetworkStateName(network.state));
  Serial.print(F(" bridge_network_connects="));
  Serial.print(network.connectAttempts);
  Serial.print(F(" bridge_network_handshakes="));
  Serial.print(network.handshakesAccepted);
  Serial.print(F(" bridge_network_reconnects="));
  Serial.print(network.reconnectsScheduled);
  Serial.print(F(" bridge_network_bytes_in="));
  Serial.print(network.bytesRead);
  Serial.print(F(" bridge_network_bytes_out="));
  Serial.print(network.bytesWritten);
  Serial.print(F(" bridge_network_writer_frames="));
  Serial.print(network.writerFrames);
  Serial.print(F(" bridge_network_writer_text_frames="));
  Serial.print(network.writerTextFrames);
  Serial.print(F(" bridge_network_writer_binary_frames="));
  Serial.print(network.writerBinaryFrames);
  Serial.print(F(" bridge_network_text_queued="));
  Serial.print(gBridgeNetworkSession.writer().telemetry().textFramesQueued);
  Serial.print(F(" bridge_network_text_dropped="));
  Serial.print(gBridgeNetworkSession.writer().telemetry().textFramesDropped);
  Serial.print(F(" bridge_network_binary_queued="));
  Serial.print(gBridgeNetworkSession.writer().telemetry().binaryFramesQueued);
  Serial.print(F(" bridge_network_binary_dropped="));
  Serial.print(gBridgeNetworkSession.writer().telemetry().binaryFramesDropped);
  const BridgeEndpointRegistryTelemetry& endpoints = gBridgeEndpointRegistry.telemetry();
  Serial.print(F(" bridge_endpoint_registry_ready="));
  Serial.print(endpoints.ready ? 1 : 0);
  Serial.print(F(" bridge_endpoint_count="));
  Serial.print(endpoints.trustedCount);
  Serial.print(F(" bridge_endpoint_active="));
  const BridgeEndpointRecord* activeEndpoint = gBridgeEndpointRegistry.activeOwner();
  Serial.print(activeEndpoint == nullptr ? "" : activeEndpoint->endpointId);
  Serial.print(F(" bridge_endpoint_restores="));
  Serial.print(endpoints.restores);
  const BridgeEndpointControlTelemetry& endpointControl = gBridgeEndpointControl.telemetry();
  Serial.print(F(" bridge_endpoint_control_ready="));
  Serial.print(endpointControl.ready ? 1 : 0);
  Serial.print(F(" bridge_endpoint_messages="));
  Serial.print(endpointControl.handledMessages);
  Serial.print(F(" bridge_endpoint_rejected="));
  Serial.print(endpointControl.rejectedMessages);
  Serial.print(F(" bridge_endpoint_persistence_saves="));
  Serial.print(endpointControl.persistenceSaves);
  Serial.print(F(" bridge_endpoint_persistence_errors="));
  Serial.print(endpointControl.persistenceErrors);
  const BridgeEndpointStoreTelemetry& endpointStore = gBridgeEndpointStore.telemetry();
  Serial.print(F(" bridge_endpoint_store_ready="));
  Serial.print(endpointStore.ready ? 1 : 0);
  Serial.print(F(" bridge_endpoint_store_loads="));
  Serial.print(endpointStore.loads);
  Serial.print(F(" bridge_endpoint_store_saves="));
  Serial.print(endpointStore.saves);
  Serial.print(F(" bridge_endpoint_store_loaded="));
  Serial.print(endpointStore.endpointsLoaded);
  Serial.print(F(" bridge_endpoint_store_saved="));
  Serial.print(endpointStore.endpointsSaved);
  Serial.print(F(" bridge_endpoint_store_parse_errors="));
  Serial.print(endpointStore.parseErrors);
  Serial.print(F(" bridge_endpoint_store_write_errors="));
  Serial.print(endpointStore.writeErrors);
  const BridgeAudioDownlinkTelemetry& downlink = gBridgeAudioDownlink.telemetry();
  Serial.print(F(" bridge_downlink_ready="));
  Serial.print(downlink.ready ? 1 : 0);
  Serial.print(F(" bridge_downlink_active="));
  Serial.print(downlink.active ? 1 : 0);
  Serial.print(F(" bridge_downlink_streams="));
  Serial.print(downlink.streamsStarted);
  Serial.print(F(" bridge_downlink_completed="));
  Serial.print(downlink.streamsCompleted);
  Serial.print(F(" bridge_downlink_chunks="));
  Serial.print(downlink.chunksAccepted);
  Serial.print(F(" bridge_downlink_bytes="));
  Serial.print(downlink.bytesAccepted);
  Serial.print(F(" bridge_downlink_errors="));
  Serial.print(downlink.errors);
  Serial.print(F(" bridge_downlink_playback_ready="));
  Serial.print(downlink.playbackReady ? 1 : 0);
  Serial.print(F(" bridge_downlink_playback_active="));
  Serial.print(downlink.playbackActive ? 1 : 0);
  Serial.print(F(" bridge_downlink_playback_starts="));
  Serial.print(downlink.playbackStarts);
  Serial.print(F(" bridge_downlink_playback_chunks="));
  Serial.print(downlink.playbackChunks);
  Serial.print(F(" bridge_downlink_playback_bytes="));
  Serial.print(downlink.playbackBytes);
  Serial.print(F(" bridge_downlink_playback_unsupported="));
  Serial.print(downlink.playbackUnsupported);
  Serial.print(F(" bridge_downlink_playback_errors="));
  Serial.print(downlink.playbackErrors);
  const BridgeAudioUplinkTelemetry& uplink = gBridgeAudioUplink.telemetry();
  Serial.print(F(" bridge_uplink_ready="));
  Serial.print(uplink.ready ? 1 : 0);
  Serial.print(F(" bridge_uplink_enabled="));
  Serial.print(uplink.enabled ? 1 : 0);
  Serial.print(F(" bridge_uplink_active="));
  Serial.print(uplink.active ? 1 : 0);
  Serial.print(F(" bridge_uplink_wake_gate_required="));
  Serial.print(uplink.wakeGateRequired ? 1 : 0);
  Serial.print(F(" bridge_uplink_turns="));
  Serial.print(uplink.turnsStarted);
  Serial.print(F(" bridge_uplink_completed="));
  Serial.print(uplink.turnsCompleted);
  Serial.print(F(" bridge_uplink_aborted="));
  Serial.print(uplink.turnsAborted);
  Serial.print(F(" bridge_uplink_chunks="));
  Serial.print(uplink.chunksQueued);
  Serial.print(F(" bridge_uplink_bytes="));
  Serial.print(uplink.bytesQueued);
  Serial.print(F(" bridge_uplink_errors="));
  Serial.print(uplink.errors);
  Serial.print(F(" bridge_uplink_gate_blocks="));
  Serial.print(uplink.gateBlocks);
  Serial.print(F(" bridge_uplink_queue_failures="));
  Serial.print(uplink.queueFailures);
  Serial.print(F(" bridge_uplink_last_seq="));
  Serial.print(uplink.lastSeq);
  const BridgeWakeGateTelemetry& wakeGate = gBridgeWakeGate.telemetry();
  Serial.print(F(" bridge_wake_gate_ready="));
  Serial.print(wakeGate.ready ? 1 : 0);
  Serial.print(F(" bridge_wake_gate_open="));
  Serial.print(wakeGate.gateOpen ? 1 : 0);
  Serial.print(F(" bridge_wake_gate_turn_active="));
  Serial.print(wakeGate.turnActive ? 1 : 0);
  Serial.print(F(" bridge_wake_gate_opens="));
  Serial.print(wakeGate.gatesOpened);
  Serial.print(F(" bridge_wake_gate_expired="));
  Serial.print(wakeGate.gatesExpired);
  Serial.print(F(" bridge_wake_gate_turns="));
  Serial.print(wakeGate.turnsStarted);
  Serial.print(F(" bridge_wake_gate_completed="));
  Serial.print(wakeGate.turnsCompleted);
  Serial.print(F(" bridge_wake_gate_suppressed="));
  Serial.print(wakeGate.suppressedStarts);
  Serial.print(F(" bridge_wake_gate_error=\""));
  Serial.print(wakeGate.lastError);
  Serial.print(F("\""));
  Serial.print(F(" bridge_timeouts="));
  Serial.println(bridge.timeouts);
}

void printSpeechCue(const SpeechCue& cue, uint32_t speechSeq, uint32_t nowMs) {
  Serial.print(F("[speech] seq="));
  Serial.print(speechSeq);
  Serial.print(F(" at_ms="));
  Serial.print(nowMs);
  Serial.print(F(" intent="));
  Serial.print(speechIntentName(cue.intent));
  Serial.print(F(" priority="));
  Serial.print(cue.priority);
  Serial.print(F(" earcon="));
  Serial.print(speechEarconName(cue.earcon));
  Serial.print(F(" earcon_delay_ms="));
  Serial.print(cue.earconDelayMs);
  Serial.print(F(" text=\""));
  Serial.print(cue.text);
  Serial.println(F("\""));
}

void printSpeechPlayback(const SpeechPlaybackPlan& plan) {
  Serial.print(F("[speech_audio] seq="));
  Serial.print(plan.seq);
  Serial.print(F(" queued_ms="));
  Serial.print(plan.queuedAtMs);
  Serial.print(F(" intent="));
  Serial.print(speechIntentName(plan.intent));
  Serial.print(F(" source="));
  Serial.print(promptSourceName(plan.promptSource));
  Serial.print(F(" prompt_id="));
  Serial.print(plan.promptId);
  Serial.print(F(" prompt_wav="));
  Serial.print(plan.promptWavPath);
  Serial.print(F(" prompt_sidecar="));
  Serial.print(plan.promptSidecarPath);
  Serial.print(F(" prompt_chars="));
  Serial.print(plan.promptChars);
  Serial.print(F(" earcon="));
  Serial.print(speechEarconName(plan.earcon));
  Serial.print(F(" earcon_delay_ms="));
  Serial.print(plan.earconDelayMs);
  Serial.print(F(" earcon_samples="));
  Serial.print(plan.earconRender.samplesWritten);
  Serial.print(F(" earcon_peak="));
  Serial.print(plan.earconRender.peakAbs);
  Serial.print(F(" earcon_checksum="));
  Serial.println(plan.earconRender.checksum, HEX);
}

void printAudioOutPlayback(const AudioOutPlaybackRequest& request) {
  Serial.print(F("[audio_out] seq="));
  Serial.print(request.seq);
  Serial.print(F(" source="));
  Serial.print(audioOutSourceName(request.source));
  Serial.print(F(" prompt_id="));
  Serial.print(request.promptId);
  Serial.print(F(" wav="));
  Serial.print(request.wavPath);
  Serial.print(F(" sidecar="));
  Serial.print(request.sidecarPath);
  Serial.print(F(" earcon_samples="));
  Serial.print(request.earconSamples);
  Serial.print(F(" sidecar_frames="));
  Serial.print(gAudioOut.telemetry().sidecarFrames);
  Serial.print(F(" sidecar_frame_ms="));
  Serial.print(gAudioOut.telemetry().sidecarFrameMs);
  Serial.print(F(" playback_ms="));
  Serial.print(gAudioOut.telemetry().playbackDurationMs);
  Serial.print(F(" hw_ready="));
  Serial.print(gAudioOut.telemetry().hardwareReady ? 1 : 0);
  Serial.print(F(" hw_playing="));
  Serial.print(gAudioOut.telemetry().hardwarePlaybackActive ? 1 : 0);
  Serial.print(F(" hw_starts="));
  Serial.print(gAudioOut.telemetry().hardwareStarts);
  Serial.print(F(" duck_on_barge_in="));
  Serial.println(request.duckOnBargeIn ? 1 : 0);
}

void printBenchControl(const BenchControl& control) {
  Serial.print(F("[control] command="));
  Serial.print(control.command);
  if (control.hasEvent) {
    Serial.print(F(" mode="));
    Serial.print(characterModeName(control.mode));
    Serial.print(F(" event="));
    Serial.print(eventTypeName(control.event.type));
    Serial.print(F(" strength="));
    Serial.print(control.event.strength, 2);
    if (control.event.hasPayload) {
      Serial.print(F(" payload_x="));
      Serial.print(control.event.x, 2);
      Serial.print(F(" payload_y="));
      Serial.print(control.event.y, 2);
      Serial.print(F(" payload_z="));
      Serial.print(control.event.z, 2);
    }
  }
  if (control.hasSpeech) {
    Serial.print(F(" speech_clear="));
    Serial.print(control.speech.clear ? 1 : 0);
    Serial.print(F(" speech_env="));
    Serial.print(control.speech.envelope, 2);
    Serial.print(F(" viseme="));
    Serial.print(speechVisemeName(toSpeechViseme(control.speech.viseme)));
    Serial.print(F(" speech_duration_ms="));
    Serial.print(control.speech.durationMs);
  }
  if (control.hasReducedMotion) {
    Serial.print(F(" reduced_motion="));
    Serial.print(control.reducedMotion ? 1 : 0);
  }
  if (control.hasMotionEnable) {
    Serial.print(F(" motion_enabled="));
    Serial.print(control.motionEnabled ? 1 : 0);
  }
  if (control.hasDemoEnable) {
    Serial.print(F(" demo_enabled="));
    Serial.print(control.demoEnabled ? 1 : 0);
  }
  if (control.hasAmbient) {
    Serial.print(F(" ambient_lux="));
    Serial.print(control.ambient.lux, 1);
    Serial.print(F(" hour="));
    Serial.print(control.ambient.hourOfDay);
  }
  if (control.hasCircadian) {
    Serial.print(F(" circadian_hour="));
    Serial.print(control.hourOfDay);
  }
  if (control.hasSpeechCue) {
    Serial.print(F(" cue_intent="));
    Serial.print(speechIntentName(control.speechCue.intent));
    Serial.print(F(" cue_earcon="));
    Serial.print(speechEarconName(control.speechCue.earcon));
  }
  if (control.hasBridge) {
    Serial.print(F(" bridge_line=\""));
    Serial.print(control.bridge.controlLine);
    Serial.print(F("\""));
  }
  if (control.hasBridgeUpload) {
    Serial.print(F(" bridge_uplink_action="));
    Serial.print(bridgeUploadActionName(control.bridgeUpload.action));
    Serial.print(F(" bridge_uplink_seq="));
    Serial.print(control.bridgeUpload.seq);
    Serial.print(F(" bridge_uplink_bytes="));
    Serial.print(control.bridgeUpload.bytes);
    Serial.print(F(" bridge_uplink_wake="));
    Serial.print(control.bridgeUpload.wakeGateOpen ? 1 : 0);
  }
  Serial.print(F(" at_ms="));
  Serial.println(control.hasEvent ? control.event.timestampMs : millis());
}

void printBridgeUplinkResult(BenchBridgeUploadAction action,
                             bool accepted,
                             uint32_t seq,
                             uint16_t bytes,
                             uint32_t nowMs) {
  const BridgeAudioUplinkTelemetry& uplink = gBridgeAudioUplink.telemetry();
  Serial.print(F("[bridge_uplink] action="));
  Serial.print(bridgeUploadActionName(action));
  Serial.print(F(" result="));
  Serial.print(accepted ? F("accepted") : F("rejected"));
  Serial.print(F(" seq="));
  Serial.print(seq);
  Serial.print(F(" bytes="));
  Serial.print(bytes);
  Serial.print(F(" active="));
  Serial.print(uplink.active ? 1 : 0);
  Serial.print(F(" chunks="));
  Serial.print(uplink.chunksQueued);
  Serial.print(F(" queued_bytes="));
  Serial.print(uplink.bytesQueued);
  Serial.print(F(" gate_blocks="));
  Serial.print(uplink.gateBlocks);
  Serial.print(F(" queue_failures="));
  Serial.print(uplink.queueFailures);
  Serial.print(F(" errors="));
  Serial.print(uplink.errors);
  Serial.print(F(" error=\""));
  Serial.print(uplink.lastError);
  Serial.print(F("\" at_ms="));
  Serial.println(nowMs);
}

void handleBridgeUplinkBench(const BenchBridgeUpload& upload, uint32_t nowMs) {
  bool accepted = false;
  uint16_t bytes = upload.bytes;
  uint8_t payload[512] = {};

  switch (upload.action) {
    case BenchBridgeUploadAction::Start:
      accepted = gBridgeAudioUplink.beginTurn(upload.seq, nowMs, upload.wakeGateOpen);
      break;
    case BenchBridgeUploadAction::Chunk:
      if (bytes > sizeof(payload)) {
        bytes = sizeof(payload);
      }
      if ((bytes & 1u) != 0) {
        bytes--;
      }
      for (uint16_t i = 0; i < bytes; ++i) {
        payload[i] = static_cast<uint8_t>((upload.seq + i) & 0xffu);
      }
      accepted = gBridgeAudioUplink.submitPcmBytes(upload.seq, payload, bytes, nowMs);
      break;
    case BenchBridgeUploadAction::End:
      accepted = gBridgeAudioUplink.endTurn(upload.seq, nowMs);
      break;
    case BenchBridgeUploadAction::Abort:
      gBridgeAudioUplink.abort(nowMs, "bench_audio_uplink_abort");
      accepted = true;
      bytes = 0;
      break;
    case BenchBridgeUploadAction::None:
      accepted = false;
      bytes = 0;
      break;
  }

  printBridgeUplinkResult(upload.action, accepted, upload.seq, bytes, nowMs);
}

void submitCapturedAudioWindowToBridgeUplink(uint32_t nowMs) {
  gBridgeWakeGate.update(nowMs);
  const BridgeAudioUplinkTelemetry& uplink = gBridgeAudioUplink.telemetry();
  if (!uplink.active) {
    return;
  }

  const int16_t* samples = gAudioCapture.lastPcmWindow();
  const uint16_t sampleCount = gAudioCapture.lastPcmSampleCount();
  if (samples == nullptr || sampleCount == 0) {
    return;
  }

  gBridgeAudioUplink.submitPcmChunk(uplink.lastSeq, samples, sampleCount, nowMs);
}

void printBridgeOutput(const BridgeClientOutput& output, uint32_t nowMs) {
  Serial.print(F("[bridge] type="));
  Serial.print(bridgeOutputTypeName(output.type));
  Serial.print(F(" state="));
  Serial.print(bridgeStateName(gBridge.telemetry().state));
  Serial.print(F(" seq="));
  uint32_t seq = output.response.seq != 0 ? output.response.seq : output.audio.seq;
  if (seq == 0) {
    seq = output.stream.seq;
  }
  if (seq == 0) {
    seq = output.streamChunk.seq;
  }
  Serial.print(seq);
  Serial.print(F(" at_ms="));
  Serial.print(nowMs);
  if (output.type == BridgeClientOutputType::Event ||
      output.type == BridgeClientOutputType::ResponseStart ||
      output.type == BridgeClientOutputType::ResponseEnd ||
      output.type == BridgeClientOutputType::Error) {
    Serial.print(F(" event="));
    Serial.print(eventTypeName(output.event.type));
  }
  if (output.type == BridgeClientOutputType::ResponseStart) {
    Serial.print(F(" intent="));
    Serial.print(speechIntentName(output.response.intent));
    Serial.print(F(" text=\""));
    Serial.print(output.response.text);
    Serial.print(F("\""));
  }
  if (output.type == BridgeClientOutputType::AudioFrame) {
    Serial.print(F(" env="));
    Serial.print(output.audio.envelope, 2);
    Serial.print(F(" viseme="));
    Serial.print(speechVisemeName(toSpeechViseme(output.audio.viseme)));
    Serial.print(F(" duration_ms="));
    Serial.print(output.audio.durationMs);
    Serial.print(F(" final="));
    Serial.print(output.audio.finalChunk ? 1 : 0);
  }
  if (output.type == BridgeClientOutputType::AudioStreamStart ||
      output.type == BridgeClientOutputType::AudioStreamEnd) {
    Serial.print(F(" format="));
    Serial.print(output.stream.format);
    Serial.print(F(" sample_rate="));
    Serial.print(output.stream.sampleRate);
    Serial.print(F(" audio_bytes="));
    Serial.print(output.stream.audioBytes);
    Serial.print(F(" chunk_bytes="));
    Serial.print(output.stream.chunkBytes);
    Serial.print(F(" chunks="));
    Serial.print(output.stream.chunks);
  }
  if (output.type == BridgeClientOutputType::AudioStreamChunk) {
    Serial.print(F(" chunk_index="));
    Serial.print(output.streamChunk.index);
    Serial.print(F(" chunk_bytes="));
    Serial.print(output.streamChunk.bytes);
    Serial.print(F(" payload_bytes="));
    Serial.print(output.streamChunk.payloadBytes);
    Serial.print(F(" received_bytes="));
    Serial.print(output.streamChunk.receivedBytes);
    Serial.print(F(" checksum="));
    Serial.print(output.streamChunk.checksum, HEX);
    Serial.print(F(" final="));
    Serial.print(output.streamChunk.finalChunk ? 1 : 0);
  }
  if (output.type == BridgeClientOutputType::SessionReady) {
    Serial.print(F(" session="));
    Serial.print(output.sessionId);
  }
  if (output.type == BridgeClientOutputType::Error) {
    Serial.print(F(" code="));
    Serial.print(output.error);
  }
  Serial.println();
}

const __FlashStringHelper* endpointControlResultName(BridgeEndpointControlResult result) {
  switch (result) {
    case BridgeEndpointControlResult::Handled:
      return F("handled");
    case BridgeEndpointControlResult::Rejected:
      return F("rejected");
    case BridgeEndpointControlResult::Ignored:
    default:
      return F("ignored");
  }
}

bool handleEndpointControlLine(const char* line, uint32_t nowMs) {
  gBridgeEndpointResponse[0] = '\0';
  const BridgeEndpointControlResult result = gBridgeEndpointControl.submitControlLine(
      line, gBridgeEndpointResponse, sizeof(gBridgeEndpointResponse), nowMs);
  if (result == BridgeEndpointControlResult::Ignored) {
    return false;
  }

  Serial.print(F("[endpoint] result="));
  Serial.print(endpointControlResultName(result));
  Serial.print(F(" at_ms="));
  Serial.print(nowMs);
  Serial.print(F(" response="));
  Serial.print(gBridgeEndpointResponse);
  Serial.println();
  return true;
}

void printAudioTelemetry(const RobotEvent& event, uint32_t frameMs) {
  const uint32_t latencyMs = frameMs >= event.timestampMs ? frameMs - event.timestampMs : 0;
  Serial.print(F("[audio] event="));
  Serial.print(eventTypeName(event.type));
  Serial.print(F(" detect_ms="));
  Serial.print(event.timestampMs);
  Serial.print(F(" frame_ms="));
  Serial.print(frameMs);
  Serial.print(F(" latency_ms="));
  Serial.print(latencyMs);
  Serial.print(F(" level="));
  Serial.print(event.hasPayload ? event.z : event.strength, 2);
  if (event.hasPayload) {
    Serial.print(F(" azimuth_deg="));
    Serial.print(event.x * 90.0f, 1);
  }
  Serial.println();
}

void printVisionTelemetry(const RobotEvent& event, uint32_t frameMs) {
  const uint32_t latencyMs = frameMs >= event.timestampMs ? frameMs - event.timestampMs : 0;
  Serial.print(F("[vision] event="));
  Serial.print(eventTypeName(event.type));
  Serial.print(F(" detect_ms="));
  Serial.print(event.timestampMs);
  Serial.print(F(" frame_ms="));
  Serial.print(frameMs);
  Serial.print(F(" latency_ms="));
  Serial.print(latencyMs);
  if (event.hasPayload) {
    Serial.print(F(" x="));
    Serial.print(event.x, 2);
    Serial.print(F(" y="));
    Serial.print(event.y, 2);
    Serial.print(F(" size="));
    Serial.print(event.z, 2);
  }
  Serial.println();
}

void publishSpeechInput(const BenchControl& control) {
  if (gSpeechQueue == nullptr || !control.hasSpeech) {
    return;
  }

  FaceSpeechInput input;
  input.clear = control.speech.clear;
  input.envelope = control.speech.envelope;
  input.viseme = toSpeechViseme(control.speech.viseme);
  input.timestampMs = control.hasEvent ? control.event.timestampMs : millis();
  input.durationMs = control.speech.durationMs;
  xQueueOverwrite(gSpeechQueue, &input);
}

void publishAudioOutSpeechFrame(uint32_t nowMs) {
  if (gSpeechQueue == nullptr) {
    return;
  }

  AudioOutSpeechFrame frame;
  if (!gAudioOut.pollSpeechFrame(nowMs, &frame)) {
    return;
  }

  FaceSpeechInput input;
  input.clear = frame.clear;
  input.envelope = frame.envelope;
  input.viseme = toSpeechViseme(frame.viseme);
  input.timestampMs = frame.timestampMs;
  input.durationMs = frame.clear ? 0 : frame.durationMs;
  xQueueOverwrite(gSpeechQueue, &input);
}

void publishBridgeSpeechFrame(const BridgeAudioChunk& audio, uint32_t nowMs) {
  if (gSpeechQueue == nullptr) {
    return;
  }

  FaceSpeechInput input;
  input.clear = audio.finalChunk && audio.envelope <= 0.01f;
  input.envelope = audio.envelope;
  input.viseme = toSpeechViseme(audio.viseme);
  input.timestampMs = nowMs;
  input.durationMs = audio.finalChunk ? 80 : audio.durationMs;
  xQueueOverwrite(gSpeechQueue, &input);
}

void publishFaceControl(const BenchControl& control) {
  if (gFaceControlQueue == nullptr || !control.hasReducedMotion) {
    return;
  }

  FaceControlInput input;
  input.hasReducedMotion = true;
  input.reducedMotion = control.reducedMotion;
  xQueueOverwrite(gFaceControlQueue, &input);
}

void publishMotionControl(const BenchControl& control) {
  if (gMotionControlQueue == nullptr || !control.hasMotionEnable) {
    return;
  }

  MotionControlInput input;
  input.hasMotionEnable = true;
  input.motionEnabled = control.motionEnabled;
  xQueueOverwrite(gMotionControlQueue, &input);
}

void handleBridgeOutput(const BridgeClientOutput& output, uint32_t nowMs) {
  printBridgeOutput(output, nowMs);

  if (output.type == BridgeClientOutputType::Event ||
      output.type == BridgeClientOutputType::ResponseEnd ||
      output.type == BridgeClientOutputType::Error) {
    gIntent.applyEvent(output.event, bridgeModeForEvent(output.event.type));
    gBridgeWakeGate.applyEvent(output.event, nowMs);
    if (output.event.type == EventType::UserSpeaking) {
      gAudioOut.duck(nowMs);
    }
  }

  if (output.type == BridgeClientOutputType::ResponseStart) {
    gIntent.applyEvent(output.event, CharacterMode::Speak);
    gBridgeWakeGate.applyEvent(output.event, nowMs);
    strncpy(gBridgeSpeechText, output.response.text, sizeof(gBridgeSpeechText) - 1);
    gBridgeSpeechText[sizeof(gBridgeSpeechText) - 1] = '\0';

    SpeechCue cue;
    cue.intent = output.response.intent;
    cue.text = gBridgeSpeechText;
    cue.priority = 250;
    cue.earcon = earconForIntent(output.response.intent);
    cue.earconDelayMs = 40;
    gIntent.queueSpeechCue(cue, nowMs);
  }

  if (output.type == BridgeClientOutputType::AudioFrame) {
    publishBridgeSpeechFrame(output.audio, nowMs);
  }

  if (output.type == BridgeClientOutputType::AudioStreamStart) {
    gBridgeAudioDownlink.start(output.stream, nowMs);
  }
  if (output.type == BridgeClientOutputType::AudioStreamChunk) {
    gBridgeAudioDownlink.submitChunk(output.streamChunk, nowMs);
  }
  if (output.type == BridgeClientOutputType::AudioStreamEnd) {
    gBridgeAudioDownlink.end(output.stream, nowMs);
  }
  if (output.type == BridgeClientOutputType::Error ||
      output.type == BridgeClientOutputType::ResponseEnd) {
    gBridgeAudioDownlink.abort(nowMs);
  }
}

void pollBridgeOutputs(uint32_t nowMs) {
  gBridge.update(nowMs);
  BridgeClientOutput output;
  while (gBridge.poll(&output)) {
    handleBridgeOutput(output, nowMs);
  }
}

void updateBridgeNetwork(uint32_t nowMs) {
  gBridgeWiFi.update(nowMs);
  const BridgeWiFiProvisioningTelemetry& wifi = gBridgeWiFi.telemetry();
  if (!wifi.ready || !wifi.configured) {
    return;
  }

  if (!gBridgeWiFi.isConnected()) {
    const BridgeNetworkSessionState state = gBridgeNetworkSession.telemetry().state;
    if (state == BridgeNetworkSessionState::Connecting ||
        state == BridgeNetworkSessionState::Handshaking ||
        state == BridgeNetworkSessionState::Connected) {
      gBridgeNetworkSession.stop(nowMs);
    }
    return;
  }

  gBridgeNetworkSession.update(nowMs);
}

void publishFrame(const RobotFrame& frame) {
  if (gFrameQueue != nullptr) {
    xQueueOverwrite(gFrameQueue, &frame);
  }
}

RobotFrame readLatestFrame(const RobotFrame& fallback) {
  RobotFrame incoming;
  if (gFrameQueue != nullptr && xQueuePeek(gFrameQueue, &incoming, 0) == pdTRUE) {
    return incoming;
  }
  return fallback;
}

void applySpeechInput(uint32_t nowMs) {
  static FaceSpeechInput active;
  static bool hasActive = false;

  FaceSpeechInput incoming;
  while (gSpeechQueue != nullptr && xQueueReceive(gSpeechQueue, &incoming, 0) == pdTRUE) {
    active = incoming;
    hasActive = !incoming.clear;
    if (incoming.clear) {
      gFace.clearSpeechEnvelope(nowMs);
    }
  }

  if (!hasActive) {
    return;
  }

  const uint32_t elapsedMs = nowMs - active.timestampMs;
  if (elapsedMs <= active.durationMs) {
    gFace.setSpeechEnvelope(active.envelope, active.viseme, nowMs);
  } else {
    hasActive = false;
    gFace.clearSpeechEnvelope(nowMs);
  }
}

void applyFaceControlInput() {
  FaceControlInput input;
  while (gFaceControlQueue != nullptr && xQueueReceive(gFaceControlQueue, &input, 0) == pdTRUE) {
    if (input.hasReducedMotion) {
      gFace.setReducedMotion(input.reducedMotion);
    }
  }
}

void applyMotionControlInput() {
  MotionControlInput input;
  while (gMotionControlQueue != nullptr && xQueueReceive(gMotionControlQueue, &input, 0) == pdTRUE) {
    if (input.hasMotionEnable) {
      gActuation.setEnabled(input.motionEnabled);
      Serial.print(F("[motion] enabled="));
      Serial.println(input.motionEnabled ? 1 : 0);
    }
  }
}

void MotionTask(void* pv) {
  (void)pv;
  RobotFrame target = makeNeutralFrame();
  TickType_t wake = xTaskGetTickCount();

  while (true) {
    target = readLatestFrame(target);
    applyMotionControlInput();
    gActuation.update(target, micros());
    vTaskDelayUntil(&wake, pdMS_TO_TICKS(gConfig.timing.motionPeriodMs));
  }
}

void FaceTask(void* pv) {
  (void)pv;
  RobotFrame target = makeNeutralFrame();
  TickType_t wake = xTaskGetTickCount();

  while (true) {
    target = readLatestFrame(target);
    const uint32_t nowMs = millis();
    applyFaceControlInput();
    applySpeechInput(nowMs);
    gFace.render(target, nowMs);
    vTaskDelayUntil(&wake, pdMS_TO_TICKS(gConfig.timing.facePeriodMs));
  }
}

void IntentTask(void* pv) {
  (void)pv;
  TickType_t wake = xTaskGetTickCount();
  uint32_t lastSpeechSeq = 0;
  RobotEvent pendingAudioEvents[4];
  uint8_t pendingAudioEventCount = 0;

  while (true) {
    const uint32_t loopMs = millis();
    gBridgeEndpointControl.update(loopMs);
    gBridgeWakeGate.update(loopMs);
    updateBridgeNetwork(loopMs);

    AudioReflexEvent audioEvents[3];
    const uint32_t audioWindowsBefore = gAudioCapture.telemetry().windowsCaptured;
    const uint8_t audioEventCount = gAudioCapture.poll(loopMs, audioEvents, 3);
    if (gAudioCapture.telemetry().windowsCaptured != audioWindowsBefore) {
      submitCapturedAudioWindowToBridgeUplink(loopMs);
    }
    for (uint8_t i = 0; i < audioEventCount; ++i) {
      if (!audioEvents[i].valid) {
        continue;
      }
      gIntent.applyEvent(audioEvents[i].event, audioEvents[i].mode);
      if (pendingAudioEventCount < 4) {
        pendingAudioEvents[pendingAudioEventCount++] = audioEvents[i].event;
      }
      gBridgeWakeGate.applyEvent(audioEvents[i].event, loopMs);
      if (audioEvents[i].event.type == EventType::UserSpeaking) {
        gAudioOut.duck(loopMs);
      }
    }

    RobotEvent cameraEvent;
    while (gCamera.poll(&cameraEvent)) {
      gIntent.applyEvent(cameraEvent, visionModeForEvent(cameraEvent.type));
      printVisionTelemetry(cameraEvent, millis());
    }

    BenchControl control;
    while (gSensors.poll(&control)) {
      if (control.hasEvent) {
        gIntent.applyEvent(control.event, control.mode);
        gBridgeWakeGate.applyEvent(control.event, millis());
        if (isAudioTelemetryEvent(control.event.type)) {
          if (pendingAudioEventCount < 4) {
            pendingAudioEvents[pendingAudioEventCount++] = control.event;
          }
        }
        if (control.event.type == EventType::UserSpeaking) {
          gAudioOut.duck(millis());
        }
      }
      if (control.wantsStatus) {
        printHeartbeat();
        printSystemTelemetry();
        printRuntimeStatus();
      }
      if (control.hasDemoEnable) {
        gIntent.setDemoEnabled(control.demoEnabled, millis());
      }
      if (control.hasReducedMotion) {
        gIntent.setReducedMotion(control.reducedMotion);
      }
      if (control.hasAmbient) {
        gIntent.applyAmbient(control.ambient.lux, control.ambient.hourOfDay);
      }
      if (control.hasCircadian) {
        gIntent.applyCircadian(control.hourOfDay);
      }
      if (control.hasSpeechCue) {
        gIntent.queueSpeechCue(control.speechCue, millis());
      }
      if (control.hasBridge) {
        const uint32_t nowMs = millis();
        if (!handleEndpointControlLine(control.bridge.controlLine, nowMs)) {
          gBridge.submitControlLine(control.bridge.controlLine, nowMs);
        }
      }
      if (control.hasBridgeUpload) {
        handleBridgeUplinkBench(control.bridgeUpload, millis());
      }
      publishSpeechInput(control);
      publishFaceControl(control);
      publishMotionControl(control);
      pollBridgeOutputs(millis());
      printBenchControl(control);
    }
    pollBridgeOutputs(millis());

    RobotFrame frame = gIntent.update(millis());
    for (uint8_t i = 0; i < pendingAudioEventCount; ++i) {
      printAudioTelemetry(pendingAudioEvents[i], frame.timestampMs);
    }
    pendingAudioEventCount = 0;
    if (frame.speechSeq != 0 && frame.speechSeq != lastSpeechSeq && frame.speech.shouldSpeak()) {
      lastSpeechSeq = frame.speechSeq;
      printSpeechCue(frame.speech, frame.speechSeq, frame.timestampMs);
      if (gSpeechAdapter.handleCue(frame.speech, frame.speechSeq, frame.emotion, frame.timestampMs)) {
        printSpeechPlayback(gSpeechAdapter.lastPlan());
        printAudioOutPlayback(gAudioOut.lastRequest());
      }
    }
    publishAudioOutSpeechFrame(frame.timestampMs);
    publishFrame(frame);
    vTaskDelayUntil(&wake, pdMS_TO_TICKS(gConfig.timing.intentPeriodMs));
  }
}

}  // namespace

#if !defined(PIO_UNIT_TESTING) && !defined(UNIT_TEST)
void setup() {
  auto cfg = M5.config();
  cfg.serial_baudrate = 115200;
  M5.begin(cfg);
  M5.Log.setLogLevel(m5::log_target_serial, ESP_LOG_INFO);
  M5.Log.setEnableColor(m5::log_target_serial, false);
  delay(200);
  printBootMarker();
  randomSeed(esp_random());

  gFrameQueue = xQueueCreate(1, sizeof(RobotFrame));
  gSpeechQueue = xQueueCreate(1, sizeof(FaceSpeechInput));
  gFaceControlQueue = xQueueCreate(1, sizeof(FaceControlInput));
  gMotionControlQueue = xQueueCreate(1, sizeof(MotionControlInput));
  if (gFrameQueue == nullptr || gSpeechQueue == nullptr || gFaceControlQueue == nullptr || gMotionControlQueue == nullptr) {
    Serial.println(F("[fatal] queue allocation failed"));
    abort();
  }

  gSensors.begin();
  gCamera.begin();
  gAudioOut.begin(STACKCHAN_ENABLE_SPEAKER != 0, STACKCHAN_ENABLE_SPEAKER != 0 ? &gSpeakerSink : nullptr);
  gBridgeAudioDownlink.begin(STACKCHAN_ENABLE_SPEAKER != 0, STACKCHAN_ENABLE_SPEAKER != 0 ? &gSpeakerSink : nullptr);
  gSpeechAdapter.begin(false, &gAudioOut);
  gBridge.begin();
  const uint32_t bootMs = millis();
  gBridgeEndpointRegistry.begin();
  gBridgeEndpointStore.begin(gBridgeEndpointStoreBackend);
  gBridgeEndpointStore.load(gBridgeEndpointRegistry, bootMs);
  gBridgeEndpointControl.begin(gBridgeEndpointRegistry);
  gBridgeEndpointControl.attachStore(&gBridgeEndpointStore);
  gAudioCapture.begin(AudioCaptureConfig {}, &gAudioCaptureSource);
  gBridgeWiFi.begin(BridgeWiFiProvisioningConfig {}, bootMs);
  gBridgeNetworkSession.begin(gBridge, gBridgeSocket, gBridgeWiFi.networkSessionConfig(), bootMs);
  gBridgeNetworkSession.attachEndpointControl(&gBridgeEndpointControl);
  gBridgeAudioUplink.begin(BridgeAudioUplinkConfig {}, &gBridgeNetworkSession);
  gBridgeWakeGate.begin(BridgeWakeGateConfig {}, &gBridgeAudioUplink);
  gActuation.begin(&gServo);
  gFace.begin(&gDisplay, gConfig.face);
  gIntent.begin();

  publishFrame(makeNeutralFrame());

  BaseType_t ok = xTaskCreatePinnedToCore(MotionTask, "MotionTask", 4096, nullptr, 3, &gMotionTaskHandle, 1);
  ok &= xTaskCreatePinnedToCore(FaceTask, "FaceTask", 4096, nullptr, 2, &gFaceTaskHandle, 1);
  ok &= xTaskCreatePinnedToCore(IntentTask, "IntentTask", 4096, nullptr, 2, &gIntentTaskHandle, 1);

  if (ok != pdPASS) {
    Serial.println(F("[fatal] task creation failed"));
    abort();
  }
}

void loop() {
  static uint32_t lastHeartbeatMs = 0;
  const uint32_t nowMs = millis();
  if (lastHeartbeatMs == 0 || nowMs - lastHeartbeatMs >= 10000) {
    lastHeartbeatMs = nowMs;
    printHeartbeat();
    printSystemTelemetry();
    printRuntimeStatus();
  }
  vTaskDelay(pdMS_TO_TICKS(1000));
}
#endif
