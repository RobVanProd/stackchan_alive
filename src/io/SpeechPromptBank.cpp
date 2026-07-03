#include "io/SpeechPromptBank.hpp"

namespace stackchan {
namespace {

constexpr SpeechPromptAsset kNoPrompt = {};

constexpr SpeechPromptAsset kPromptAssets[] = {
    {SpeechIntent::Boot,
     PromptSource::PackagedPrompt,
     "boot_awake",
     "Hello. I am Stackchan, and I am awake.",
     "media/voice/stackchan_spark_greeting.wav",
     "media/voice/sidecars/stackchan_spark_greeting.speech_envelope.json"},
    {SpeechIntent::Idle,
     PromptSource::PackagedPrompt,
     "idle_curiosity",
     "Hello. I am Stackchan, and I am awake.",
     "media/voice/stackchan_spark_greeting.wav",
     "media/voice/sidecars/stackchan_spark_greeting.speech_envelope.json"},
    {SpeechIntent::Attend,
     PromptSource::PackagedPrompt,
     "listen_attention",
     "Hello. I am Stackchan, and I am awake.",
     "media/voice/stackchan_spark_greeting.wav",
     "media/voice/sidecars/stackchan_spark_greeting.speech_envelope.json"},
    {SpeechIntent::Listen,
     PromptSource::PackagedPrompt,
     "listen_attention",
     "Hello. I am Stackchan, and I am awake.",
     "media/voice/stackchan_spark_greeting.wav",
     "media/voice/sidecars/stackchan_spark_greeting.speech_envelope.json"},
    {SpeechIntent::Think,
     PromptSource::PackagedPrompt,
     "think_processing",
     "Input received. I am thinking now. Curiosity level rising.",
     "media/voice/stackchan_spark_thinking.wav",
     "media/voice/sidecars/stackchan_spark_thinking.speech_envelope.json"},
    {SpeechIntent::Speak,
     PromptSource::PackagedPrompt,
     "speak_new_information",
     "Input received. I am thinking now. Curiosity level rising.",
     "media/voice/stackchan_spark_thinking.wav",
     "media/voice/sidecars/stackchan_spark_thinking.speech_envelope.json"},
    {SpeechIntent::React,
     PromptSource::PackagedPrompt,
     "react_display_ready",
     "Hello. I am Stackchan, and I am awake.",
     "media/voice/stackchan_spark_greeting.wav",
     "media/voice/sidecars/stackchan_spark_greeting.speech_envelope.json"},
    {SpeechIntent::Happy,
     PromptSource::PackagedPrompt,
     "happy_signal",
     "Hello. I am Stackchan, and I am awake.",
     "media/voice/stackchan_spark_greeting.wav",
     "media/voice/sidecars/stackchan_spark_greeting.speech_envelope.json"},
    {SpeechIntent::Concern,
     PromptSource::PackagedPrompt,
     "concern_more_data",
     "Small problem found. I can help fix it. Safety first.",
     "media/voice/stackchan_spark_safety.wav",
     "media/voice/sidecars/stackchan_spark_safety.speech_envelope.json"},
    {SpeechIntent::Sleep,
     PromptSource::PackagedPrompt,
     "sleep_systems_quiet",
     "Small problem found. I can help fix it. Safety first.",
     "media/voice/stackchan_spark_safety.wav",
     "media/voice/sidecars/stackchan_spark_safety.speech_envelope.json"},
    {SpeechIntent::Error,
     PromptSource::PackagedPrompt,
     "error_small_problem",
     "Small problem found. I can help fix it. Safety first.",
     "media/voice/stackchan_spark_safety.wav",
     "media/voice/sidecars/stackchan_spark_safety.speech_envelope.json"},
    {SpeechIntent::Safety,
     PromptSource::PackagedPrompt,
     "safety_servo_not_armed",
     "Small problem found. I can help fix it. Safety first.",
     "media/voice/stackchan_spark_safety.wav",
     "media/voice/sidecars/stackchan_spark_safety.speech_envelope.json"},
};

}  // namespace

const SpeechPromptAsset& SpeechPromptBank::find(SpeechIntent intent) {
  for (const SpeechPromptAsset& asset : kPromptAssets) {
    if (asset.intent == intent) {
      return asset;
    }
  }
  return kNoPrompt;
}

const SpeechPromptAsset* SpeechPromptBank::assets(size_t& count) {
  count = sizeof(kPromptAssets) / sizeof(kPromptAssets[0]);
  return kPromptAssets;
}

}  // namespace stackchan
