#pragma once

#include "persona/EventBus.hpp"

namespace stackchan {

class SensorAdapter {
 public:
  bool begin() {
    return true;
  }

  bool poll(RobotEvent* eventOut) {
    (void)eventOut;
    return false;
  }
};

}  // namespace stackchan
