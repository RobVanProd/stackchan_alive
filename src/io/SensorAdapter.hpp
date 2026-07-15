#pragma once

#include "io/BridgeClient.hpp"
#include "io/BridgeWiFiProvisioningStore.hpp"
#include "persona/EventBus.hpp"
#include "persona/StateMatrix.hpp"

namespace stackchan {

enum class BenchSpeechViseme : uint8_t {
  Neutral,
  Ah,
  Oh,
  Ee,
};

struct BenchSpeechEnvelope {
  float envelope = 0.0f;
  BenchSpeechViseme viseme = BenchSpeechViseme::Neutral;
  uint16_t durationMs = 600;
  bool clear = false;
};

struct BenchAmbientReading {
  float lux = 0.0f;
  uint8_t hourOfDay = 12;
};

struct BenchBridgeControl {
  char controlLine[192] = {};
};

enum class BenchBridgeUploadAction : uint8_t {
  None,
  Start,
  Chunk,
  End,
  Abort,
};

struct BenchBridgeUpload {
  BenchBridgeUploadAction action = BenchBridgeUploadAction::None;
  uint32_t seq = 1;
  uint16_t bytes = 160;
  bool wakeGateOpen = true;
};

struct BenchBridgeTextTurn {
  uint32_t seq = 1;
  char text[96] = {};
};

struct BenchPairingControl {
  bool clear = false;
  char code[7] = {};
};

struct BenchPairingTicketControl {
  char code[7] = {};
  bool useTls = false;
  char bridgeHost[kBridgeWiFiHostMax] = {};
  uint16_t bridgePort = 8765;
  char bridgePath[kBridgeWiFiPathMax] = "/bridge";
  char endpointId[64] = {};
  char fingerprint[80] = {};
};

enum class BenchWiFiProvisioningAction : uint8_t {
  SetProfile,
  UseProfile,
  ClearProfile,
  ClearAll,
  Status,
};

struct BenchWiFiProvisioningControl {
  BenchWiFiProvisioningAction action = BenchWiFiProvisioningAction::SetProfile;
  BridgeWiFiProfileId profile = BridgeWiFiProfileId::Home;
  bool clear = false;
  bool useTls = false;
  char ssid[kBridgeWiFiSsidMax] = {};
  char password[kBridgeWiFiPasswordMax] = {};
  char bridgeHost[kBridgeWiFiHostMax] = {};
  uint16_t bridgePort = 8765;
  char bridgePath[kBridgeWiFiPathMax] = "/bridge";
  char accessClientId[kBridgeAccessCredentialMax] = {};
  char accessClientSecret[kBridgeAccessCredentialMax] = {};
};

struct BenchControl {
  bool wantsHelp = false;
  bool wantsStatus = false;
  bool hasEvent = false;
  bool hasSpeech = false;
  bool hasReducedMotion = false;
  bool hasMotionEnable = false;
  bool hasDemoEnable = false;
  bool hasAmbient = false;
  bool hasCircadian = false;
  bool hasSpeechCue = false;
  bool hasBridge = false;
  bool hasBridgeUpload = false;
  bool hasBridgeTextTurn = false;
  bool hasPairingControl = false;
  bool hasPairingTicket = false;
  bool hasWiFiProvisioning = false;
  bool hasSpeakerTest = false;
  bool hasMicCueTest = false;
  bool reducedMotion = false;
  bool motionEnabled = true;
  bool demoEnabled = true;
  uint8_t hourOfDay = 12;
  CharacterMode mode = CharacterMode::Idle;
  RobotEvent event;
  BenchSpeechEnvelope speech;
  BenchAmbientReading ambient;
  BenchBridgeControl bridge;
  BenchBridgeUpload bridgeUpload;
  BenchBridgeTextTurn bridgeTextTurn;
  BenchPairingControl pairing;
  BenchPairingTicketControl pairingTicket;
  BenchWiFiProvisioningControl wifi;
  SpeechCue speechCue;
  const char* command = "";
};

bool parseBenchControlLine(const char* line, uint32_t nowMs, BenchControl* controlOut);

class SensorAdapter {
 public:
  bool begin();

  bool poll(BenchControl* controlOut);

 private:
  void printHelp() const;

  char line_[256] = {};
  uint8_t lineLength_ = 0;
};

}  // namespace stackchan
