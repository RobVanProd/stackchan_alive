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
constexpr uint32_t kFrameBudgetUs = 33333;
constexpr int kOpenMouthSegments = 12;
constexpr float kSmilePow06[] = {
  0.000000f, 0.189465f, 0.287175f, 0.366270f, 0.435275f, 0.497634f,
  0.555161f, 0.608957f, 0.659754f, 0.708066f, 0.754272f, 0.798663f,
  0.841466f, 0.882864f, 0.923007f, 0.962017f, 1.000000f,
};

int32_t roundToInt(float value) {
  return static_cast<int32_t>(value + (value >= 0.0f ? 0.5f : -0.5f));
}

float qbez(float p0, float p1, float p2, float u) {
  const float a = 1.0f - u;
  return a * a * p0 + 2.0f * a * u * p1 + u * u * p2;
}

float smileCurveGain(float smileMagnitude) {
  const float x = constrain(smileMagnitude, 0.0f, 1.0f) * 16.0f;
  const int index = constrain(static_cast<int>(x), 0, 15);
  const float frac = x - static_cast<float>(index);
  return kSmilePow06[index] + (kSmilePow06[index + 1] - kSmilePow06[index]) * frac;
}

}  // namespace

namespace stackchan {

namespace detail {
class FaceCanvas final : public M5Canvas {
 public:
  FaceCanvas() : M5Canvas(&M5.Display) {}
};
}  // namespace detail

DisplayAdapter::DisplayAdapter() = default;

DisplayAdapter::~DisplayAdapter() {
  delete canvas_;
}

bool DisplayAdapter::begin() {
  M5.Display.setRotation(1);
  M5.Display.setBrightness(180);
  M5.Display.fillScreen(kBg);
  M5.Display.setTextColor(kAccent, kBg);
  M5.Display.setTextDatum(middle_center);

  if (canvas_ == nullptr) {
    canvas_ = new detail::FaceCanvas();
  }
  if (canvas_ == nullptr) {
    Serial.println(F("[display] M5 canvas allocation failed"));
    return false;
  }
  canvas_->setColorDepth(16);
  canvas_->setPsram(true);
  if (canvas_->createSprite(320, 240) == nullptr) {
    Serial.println(F("[display] M5 canvas sprite allocation failed"));
    return false;
  }
  canvas_->setTextColor(kAccent, kBg);
  canvas_->setTextDatum(middle_center);
  canvas_->fillSprite(kBg);
  canvas_->pushSprite(0, 0);

  begun_ = true;
  lastTelemetryMs_ = millis();
  Serial.println(F("[display] M5 display renderer ready canvas=double-buffered"));
  return true;
}

void DisplayAdapter::clear() {
  if (!begun_) {
    return;
  }
  frameStartUs_ = micros();
  canvas_->fillSprite(kBg);
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

  canvas_->fillRoundRect(x, y, w, h, radius, kEye);

  const int32_t cutTL = constrain(roundToInt(eye.cornerTL * eye.height * 0.5f), 0, h / 2);
  const int32_t cutTR = constrain(roundToInt(eye.cornerTR * eye.height * 0.5f), 0, h / 2);
  const int32_t cutBL = constrain(roundToInt(eye.cornerBL * eye.height * 0.5f), 0, h / 2);
  const int32_t cutBR = constrain(roundToInt(eye.cornerBR * eye.height * 0.5f), 0, h / 2);
  if (cutTL >= 2) {
    canvas_->fillTriangle(x, y, x + cutTL, y, x, y + cutTL, kBg);
  }
  if (cutTR >= 2) {
    canvas_->fillTriangle(x + w, y, x + w - cutTR, y, x + w, y + cutTR, kBg);
  }
  if (cutBL >= 2) {
    canvas_->fillTriangle(x, y + h, x + cutBL, y + h, x, y + h - cutBL, kBg);
  }
  if (cutBR >= 2) {
    canvas_->fillTriangle(x + w, y + h, x + w - cutBR, y + h, x + w, y + h - cutBR, kBg);
  }

  const int32_t pupilRx = max<int32_t>(4, roundToInt(static_cast<float>(w) * 0.10f * eye.pupilScale));
  const int32_t pupilRy = max<int32_t>(4, roundToInt(static_cast<float>(h) * 0.20f * eye.pupilScale));
  const int32_t pupilX = roundToInt(eye.cx + eye.pupilX * eye.width * 0.22f);
  const int32_t pupilY = roundToInt(eye.cy + eye.pupilY * eye.height * 0.18f);
  canvas_->fillEllipse(pupilX, pupilY, pupilRx, pupilRy, kPupil);
  const int32_t highlightX = pupilX - pupilRx / 2 - roundToInt(eye.pupilX);
  const int32_t highlightY = pupilY - pupilRy / 2 - roundToInt(eye.pupilY);
  canvas_->fillCircle(highlightX, highlightY, max<int32_t>(1, pupilRx / 3), kEye);

  const int32_t upperCoverage = constrain(roundToInt(eye.upperLid), 0, h);
  if (upperCoverage > 0) {
    const int32_t tilt = roundToInt(constrain(eye.upperLidTilt, -1.0f, 1.0f) * 15.0f);
    const int32_t edgeL = constrain(y + upperCoverage + tilt, y, y + h);
    const int32_t edgeR = constrain(y + upperCoverage - tilt, y, y + h);
    canvas_->fillTriangle(x, y, x + w, y, x, edgeL, kBg);
    canvas_->fillTriangle(x + w, y, x + w, edgeR, x, edgeL, kBg);
    if (upperCoverage < h - 2) {
      canvas_->drawLine(x + 4, edgeL, x + w - 4, edgeR, kAccent);
    }
  }

  const int32_t lowerCoverage = constrain(roundToInt(eye.lowerLid), 0, h - upperCoverage);
  if (lowerCoverage > 0) {
    const int32_t tilt = roundToInt(constrain(eye.lowerLidTilt, -1.0f, 1.0f) * 8.0f);
    const int32_t edgeL = constrain(y + h - lowerCoverage + tilt, y, y + h);
    const int32_t edgeR = constrain(y + h - lowerCoverage - tilt, y, y + h);
    canvas_->fillTriangle(x, y + h, x + w, y + h, x, edgeL, kBg);
    canvas_->fillTriangle(x + w, y + h, x + w, edgeR, x, edgeL, kBg);
    canvas_->drawLine(x + 4, edgeL, x + w - 4, edgeR, kAccent);
  }

  if (fabsf(eye.browTilt) > 0.03f || eye.squint > 0.05f) {
    const int32_t browY = roundToInt(eye.cy - eye.height * 0.72f);
    const int32_t browHalf = max<int32_t>(16, w / 4);
    const float squintTilt = eye.browTilt < 0.0f ? 0.0f : eye.squint * 0.35f;
    const float tilt = constrain(eye.browTilt + squintTilt, -1.0f, 1.0f) * 9.0f;
    const int32_t innerY = browY + roundToInt(tilt);
    const int32_t outerY = browY - roundToInt(tilt);
    const int32_t x1 = roundToInt(eye.cx - browHalf);
    const int32_t x2 = roundToInt(eye.cx + browHalf);
    const int32_t y1 = rightEye ? innerY : outerY;
    const int32_t y2 = rightEye ? outerY : innerY;
    canvas_->drawLine(x1, y1, x2, y2, kEye);
    canvas_->drawLine(x1, y1 + 1, x2, y2 + 1, kEye);
  }
}

void DisplayAdapter::drawMouth(const MouthGeometry& mouth) {
  if (!begun_) {
    return;
  }

  const int32_t cx = roundToInt(mouth.cx);
  const int32_t cy = roundToInt(mouth.cy);
  const int32_t half = roundToInt(mouth.width * 0.5f);
  const float smileMagnitude = smileCurveGain(fabsf(mouth.smile));
  const float smileSign = mouth.smile < 0.0f ? -1.0f : 1.0f;
  const int32_t curve = roundToInt(smileSign * smileMagnitude * 22.0f);
  const int32_t open = roundToInt(mouth.open * 18.0f);
  const int32_t leftY = cy + roundToInt(mouth.cornerL);
  const int32_t rightY = cy + roundToInt(mouth.cornerR);

  if (open > 3) {
    const int32_t topCtrlY = cy - max<int32_t>(2, open / 3);
    const int32_t bottomCtrlY = cy + curve + open;
    int32_t prevTopX = cx - half;
    int32_t prevTopY = leftY;
    int32_t prevBottomX = cx - half;
    int32_t prevBottomY = leftY + max<int32_t>(2, open / 2);
    for (int i = 1; i <= kOpenMouthSegments; ++i) {
      const float u = static_cast<float>(i) / static_cast<float>(kOpenMouthSegments);
      const int32_t topX = roundToInt(qbez(cx - half, cx, cx + half, u));
      const int32_t topY = roundToInt(qbez(leftY, topCtrlY, rightY, u));
      const int32_t bottomX = topX;
      const int32_t bottomY = roundToInt(qbez(leftY + open / 2, bottomCtrlY, rightY + open / 2, u));
      canvas_->fillTriangle(prevTopX, prevTopY, prevBottomX, prevBottomY, topX, topY, kMouth);
      canvas_->fillTriangle(topX, topY, prevBottomX, prevBottomY, bottomX, bottomY, kMouth);
      prevTopX = topX;
      prevTopY = topY;
      prevBottomX = bottomX;
      prevBottomY = bottomY;
    }
    return;
  }

  canvas_->drawBezier(cx - half, leftY, cx, cy + curve, cx + half, rightY, kMouth);
  canvas_->drawBezier(cx - half, leftY + 1, cx, cy + curve + 1, cx + half, rightY + 1, kMouth);
}

void DisplayAdapter::flush() {
  if (!begun_) {
    return;
  }
  canvas_->setTextColor(kAccent, kBg);
  canvas_->setTextDatum(middle_center);
  canvas_->drawString("Stackchan Alive", 160, 220);
  canvas_->pushSprite(0, 0);
  M5.Display.waitDisplay();
  frameCount_++;
  windowFrameCount_++;

  const uint32_t frameUs = micros() - frameStartUs_;
  avgFrameUs_ = frameCount_ == 1 ? static_cast<float>(frameUs) : (avgFrameUs_ * 0.90f + static_cast<float>(frameUs) * 0.10f);
  if (frameUs > maxFrameUs_) {
    maxFrameUs_ = frameUs;
  }
  if (frameUs > kFrameBudgetUs) {
    slowFrameCount_++;
  }

  const uint32_t nowMs = millis();
  if (nowMs - lastTelemetryMs_ >= 5000) {
    const uint32_t telemetryElapsedMs = nowMs - lastTelemetryMs_;
    lastTelemetryMs_ = nowMs;
    const float avgMs = avgFrameUs_ / 1000.0f;
    const float maxMs = static_cast<float>(maxFrameUs_) / 1000.0f;
    const float fpsWindow = telemetryElapsedMs > 0 ? (static_cast<float>(windowFrameCount_) * 1000.0f) / telemetryElapsedMs : 0.0f;
    Serial.print(F("[display] frame_ms_avg="));
    Serial.print(avgMs, 2);
    Serial.print(F(" frame_ms_max="));
    Serial.print(maxMs, 2);
    Serial.print(F(" fps_avg="));
    Serial.print(avgMs > 0.0f ? 1000.0f / avgMs : 0.0f, 1);
    Serial.print(F(" fps_window="));
    Serial.print(fpsWindow, 1);
    Serial.print(F(" frame_budget_us="));
    Serial.print(kFrameBudgetUs);
    Serial.print(F(" slow_frames="));
    Serial.println(slowFrameCount_);
    maxFrameUs_ = 0;
    slowFrameCount_ = 0;
    windowFrameCount_ = 0;
  }
}

}  // namespace stackchan
