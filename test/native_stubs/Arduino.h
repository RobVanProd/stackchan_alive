#pragma once

#include <algorithm>
#include <cmath>
#include <cstdint>

#define F(value) value

using std::int16_t;
using std::uint8_t;
using std::uint32_t;

class SerialStub {
 public:
  template <typename T>
  void print(const T&) {}

  template <typename T>
  void println(const T&) {}

  void println() {}
};

inline SerialStub Serial;

template <typename T>
T constrain(T value, T low, T high) {
  return std::max(low, std::min(value, high));
}

template <typename T>
T min(T left, T right) {
  return std::min(left, right);
}

template <typename T>
T max(T left, T right) {
  return std::max(left, right);
}

inline uint32_t& fakeArduinoMillis() {
  static uint32_t value = 0;
  return value;
}

inline uint32_t& fakeArduinoMicros() {
  static uint32_t value = 0;
  return value;
}

inline void setFakeArduinoTime(uint32_t millisValue, uint32_t microsValue) {
  fakeArduinoMillis() = millisValue;
  fakeArduinoMicros() = microsValue;
}

inline uint32_t millis() {
  return fakeArduinoMillis();
}

inline uint32_t micros() {
  return fakeArduinoMicros();
}

inline long random(long max) {
  return max > 0 ? max / 2 : 0;
}

inline long random(long min, long max) {
  return max > min ? min + ((max - min) / 2) : min;
}
