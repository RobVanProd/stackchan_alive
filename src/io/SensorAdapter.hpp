#pragma once

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

struct BenchControl {
  bool wantsHelp = false;
  bool hasEvent = false;
  bool hasSpeech = false;
  bool hasReducedMotion = false;
  bool reducedMotion = false;
  CharacterMode mode = CharacterMode::Idle;
  RobotEvent event;
  BenchSpeechEnvelope speech;
  const char* command = "";
};

bool parseBenchControlLine(const char* line, uint32_t nowMs, BenchControl* controlOut);

class SensorAdapter {
 public:
  bool begin();

  bool poll(BenchControl* controlOut);

 private:
  void printHelp() const;

  char line_[96] = {};
  uint8_t lineLength_ = 0;
};

}  // namespace stackchan
