#pragma once

#include "persona/EventBus.hpp"
#include "persona/StateMatrix.hpp"

namespace stackchan {

struct BenchControl {
  CharacterMode mode = CharacterMode::Idle;
  RobotEvent event;
  const char* command = "";
};

bool parseBenchControlLine(const char* line, uint32_t nowMs, BenchControl* controlOut);

class SensorAdapter {
 public:
  bool begin();

  bool poll(BenchControl* controlOut);

 private:
  char line_[96] = {};
  uint8_t lineLength_ = 0;
};

}  // namespace stackchan
