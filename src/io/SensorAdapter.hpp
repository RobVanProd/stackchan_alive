#pragma once

#include "io/BridgeClient.hpp"
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

struct BenchPairingControl {
  bool clear = false;
  char code[7] = {};
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
  bool hasPairingControl = false;
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
  BenchPairingControl pairing;
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

  char line_[192] = {};
  uint8_t lineLength_ = 0;
};

}  // namespace stackchan
