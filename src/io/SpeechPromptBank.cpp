#include "io/SpeechPromptBank.hpp"

#include "PersonaPromptAssets.hpp"

namespace stackchan {
namespace {

constexpr SpeechPromptAsset kNoPrompt = {};

}  // namespace

const SpeechPromptAsset& SpeechPromptBank::find(SpeechIntent intent) {
  for (const SpeechPromptAsset& asset : generated_persona::kPromptAssets) {
    if (asset.intent == intent) {
      return asset;
    }
  }
  return kNoPrompt;
}

const SpeechPromptAsset* SpeechPromptBank::assets(size_t& count) {
  count = generated_persona::kPromptAssetCount;
  return generated_persona::kPromptAssets;
}

}  // namespace stackchan
