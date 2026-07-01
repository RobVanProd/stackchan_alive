#pragma once

#include <algorithm>
#include <cmath>
#include <cstdint>

using std::int16_t;
using std::uint8_t;
using std::uint32_t;

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

inline uint32_t millis() {
  return 0;
}
