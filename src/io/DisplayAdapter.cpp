#include "io/DisplayAdapter.hpp"

#include <Arduino.h>
#include <M5Unified.h>
#include <math.h>

namespace {

constexpr uint32_t kBg = 0x071013;
constexpr uint32_t kEye = 0xF7FBFF;
constexpr uint32_t kPupil = 0x111827;
constexpr uint32_t kAccent = 0x61E4D7;
constexpr uint32_t kMouth = 0xFF6B8A;

int32_t roundToInt(float value) {
  return static_cast<int32_t>(value + (value >= 0.0f ? 0.5f : -0.5f));
}

}  // namespace

namespace stackchan {

bool DisplayAdapter::begin() {
  M5.Display.setRotation(1);
  M5.Display.setBrightness(180);
  M5.Display.fillScreen(kBg);
  M5.Display.setTextColor(kAccent, kBg);
  M5.Display.setTextDatum(middle_center);
  begun_ = true;
  Serial.println(F("[display] M5 display renderer ready"));
  return true;
}

void DisplayAdapter::clear() {
  if (!begun_) {
    return;
  }
  M5.Display.fillScreen(kBg);
}

void DisplayAdapter::drawEye(const EyeGeometry& eye, bool rightEye) {
  if (!begun_) {
    return;
  }

  const int32_t x = roundToInt(eye.cx - eye.width * 0.5f);
  const int32_t y = roundToInt(eye.cy - eye.height * 0.5f);
  const int32_t w = max<int32_t>(8, roundToInt(eye.width));
  const int32_t h = max<int32_t>(4, roundToInt(eye.height));
  const int32_t radius = min<int32_t>(18, h / 2);

  M5.Display.fillRoundRect(x, y, w, h, radius, kEye);

  const int32_t pupilRx = max<int32_t>(4, w / 10);
  const int32_t pupilRy = max<int32_t>(4, h / 5);
  const int32_t pupilX = roundToInt(eye.cx + eye.pupilX * eye.width * 0.22f);
  const int32_t pupilY = roundToInt(eye.cy + eye.pupilY * eye.height * 0.18f);
  M5.Display.fillEllipse(pupilX, pupilY, pupilRx, pupilRy, kPupil);
  M5.Display.fillCircle(pupilX - pupilRx / 2, pupilY - pupilRy / 2, max<int32_t>(1, pupilRx / 3), kEye);

  const int32_t upperCoverage = constrain(roundToInt(eye.upperLid), 0, h);
  if (upperCoverage > 0) {
    M5.Display.fillRect(x, y, w, upperCoverage, kBg);
    if (upperCoverage < h - 2) {
      const int32_t lidY = y + upperCoverage;
      M5.Display.drawLine(x + 4, lidY, x + w - 4, lidY, kAccent);
    }
  }

  const int32_t lowerCoverage = constrain(roundToInt(eye.lowerLid), 0, h - upperCoverage);
  if (lowerCoverage > 0) {
    const int32_t lidY = y + h - lowerCoverage;
    M5.Display.fillRect(x, lidY, w, lowerCoverage, kBg);
    M5.Display.drawLine(x + 4, lidY, x + w - 4, lidY, kAccent);
  }

  if (fabsf(eye.browTilt) > 0.03f || eye.squint > 0.05f) {
    const int32_t browY = roundToInt(eye.cy - eye.height * 0.72f);
    const int32_t browHalf = max<int32_t>(16, w / 4);
    const float tilt = constrain(eye.browTilt + eye.squint * 0.35f, -1.0f, 1.0f) * 9.0f;
    const int32_t innerY = browY + roundToInt(tilt);
    const int32_t outerY = browY - roundToInt(tilt);
    const int32_t x1 = roundToInt(eye.cx - browHalf);
    const int32_t x2 = roundToInt(eye.cx + browHalf);
    const int32_t y1 = rightEye ? innerY : outerY;
    const int32_t y2 = rightEye ? outerY : innerY;
    M5.Display.drawLine(x1, y1, x2, y2, kEye);
    M5.Display.drawLine(x1, y1 + 1, x2, y2 + 1, kEye);
  }
}

void DisplayAdapter::drawMouth(const MouthGeometry& mouth) {
  if (!begun_) {
    return;
  }

  const int32_t cx = roundToInt(mouth.cx);
  const int32_t cy = roundToInt(mouth.cy);
  const int32_t half = roundToInt(mouth.width * 0.5f);
  const float smileMagnitude = powf(fabsf(mouth.smile), 0.6f);
  const float smileSign = mouth.smile < 0.0f ? -1.0f : 1.0f;
  const int32_t curve = roundToInt(smileSign * smileMagnitude * 22.0f);
  const int32_t open = roundToInt(mouth.open * 18.0f);

  if (open > 3) {
    M5.Display.fillEllipse(cx, cy + open / 3, half / 2, open, kMouth);
    M5.Display.fillEllipse(cx, cy + open / 4, half / 3, max<int32_t>(2, open / 2), kBg);
    return;
  }

  M5.Display.drawBezier(cx - half, cy, cx, cy + curve, cx + half, cy, kMouth);
  M5.Display.drawBezier(cx - half, cy + 1, cx, cy + curve + 1, cx + half, cy + 1, kMouth);
}

void DisplayAdapter::flush() {
  if (!begun_) {
    return;
  }
  M5.Display.setTextColor(kAccent, kBg);
  M5.Display.setTextDatum(middle_center);
  M5.Display.drawString("Stackchan Alive", 160, 220);
  M5.Display.waitDisplay();
  frameCount_++;
}

}  // namespace stackchan
