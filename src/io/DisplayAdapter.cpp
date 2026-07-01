#include "io/DisplayAdapter.hpp"

#include <Arduino.h>

namespace stackchan {

bool DisplayAdapter::begin() {
  Serial.println(F("[display] adapter ready; renderer backend pending"));
  return true;
}

void DisplayAdapter::clear() {}

void DisplayAdapter::drawEye(const EyeGeometry& eye, bool rightEye) {
  (void)eye;
  (void)rightEye;
}

void DisplayAdapter::drawMouth(const MouthGeometry& mouth) {
  (void)mouth;
}

void DisplayAdapter::flush() {
  frameCount_++;
}

}  // namespace stackchan
