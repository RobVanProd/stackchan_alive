#pragma once

#include "face/ProceduralFace.hpp"

namespace stackchan {

namespace detail {
class FaceCanvas;
}

struct DisplayTelemetry {
  bool ready = false;
  uint32_t frameCount = 0;
  uint32_t lastFrameUs = 0;
  uint32_t avgFrameUs = 0;
  uint32_t windowFrameCount = 0;
  uint32_t windowMaxFrameUs = 0;
  uint32_t windowSlowFrames = 0;
  uint32_t windowMs = 0;
  uint32_t lastDirtyPixels = 0;
  uint32_t windowMaxDirtyPixels = 0;
  float windowFps = 0.0f;
};

struct DisplayRect {
  int16_t x = 0;
  int16_t y = 0;
  int16_t w = 0;
  int16_t h = 0;
  bool valid = false;
};

class DisplayAdapter final : public IDisplay {
 public:
  DisplayAdapter();
  ~DisplayAdapter() override;

  bool begin() override;
  void clear() override;
  void drawEye(const EyeGeometry& eye, bool rightEye) override;
  void drawMouth(const MouthGeometry& mouth) override;
  void flush() override;

  const DisplayTelemetry& telemetry() const {
    return telemetry_;
  }

 private:
  void markDirty(const DisplayRect& rect);
  void clearCanvasRect(const DisplayRect& rect);
  void drawStaticText();
  void keepDisplayAwake(uint32_t nowMs);
  void pushDirtyRect();

  detail::FaceCanvas* canvas_ = nullptr;
  DisplayRect dirty_;
  DisplayRect previousLeftEye_;
  DisplayRect previousRightEye_;
  DisplayRect previousMouth_;
  uint32_t frameCount_ = 0;
  uint32_t windowFrameCount_ = 0;
  uint32_t slowFrameCount_ = 0;
  uint32_t frameStartUs_ = 0;
  uint32_t lastTelemetryMs_ = 0;
  uint32_t lastDisplayKeepAliveMs_ = 0;
  uint32_t maxFrameUs_ = 0;
  uint32_t maxDirtyPixels_ = 0;
  float avgFrameUs_ = 0.0f;
  bool begun_ = false;
  bool fullRefreshPending_ = true;
  DisplayTelemetry telemetry_;
};

}  // namespace stackchan
