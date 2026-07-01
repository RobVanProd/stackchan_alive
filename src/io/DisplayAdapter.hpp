#pragma once

#include "face/ProceduralFace.hpp"

namespace stackchan {

class DisplayAdapter final : public IDisplay {
 public:
  bool begin() override;
  void clear() override;
  void drawEye(const EyeGeometry& eye, bool rightEye) override;
  void drawMouth(const MouthGeometry& mouth) override;
  void flush() override;

 private:
  uint32_t frameCount_ = 0;
};

}  // namespace stackchan
