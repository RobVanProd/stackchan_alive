#pragma once

#include <stddef.h>
#include <stdint.h>

#include "persona/StateMatrix.hpp"

namespace stackchan {

enum class PromptSource : uint8_t {
  None,
  PackagedPrompt,
  HostBridge,
};

struct SpeechPromptAsset {
  SpeechIntent intent = SpeechIntent::None;
  PromptSource source = PromptSource::None;
  const char* id = "";
  const char* transcript = "";
  const char* wavPath = "";
  const char* sidecarPath = "";
};

class SpeechPromptBank {
 public:
  static const SpeechPromptAsset& find(SpeechIntent intent);
  static const SpeechPromptAsset* assets(size_t& count);
};

}  // namespace stackchan
