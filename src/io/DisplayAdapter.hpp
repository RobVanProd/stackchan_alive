#pragma once

#include "face/ProceduralFace.hpp"

namespace stackchan {

namespace detail {
class FaceCanvas;
}

class DisplayAdapter final : public IDisplay {
 public:
  DisplayAdapter();
  ~DisplayAdapter() override;

  bool begin() override;
  void clear() override;
  void drawEye(const EyeGeometry& eye, bool rightEye) override;
  void drawMouth(const MouthGeometry& mouth) override;
  void flush() override;

 private:
  detail::FaceCanvas* canvas_ = nullptr;
  uint32_t frameCount_ = 0;
  uint32_t frameStartUs_ = 0;
  uint32_t lastTelemetryMs_ = 0;
  uint32_t maxFrameUs_ = 0;
  float avgFrameUs_ = 0.0f;
  bool begun_ = false;
};

}  // namespace stackchan
