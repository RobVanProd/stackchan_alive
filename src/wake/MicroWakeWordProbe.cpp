#ifndef STACKCHAN_ENABLE_MWW_WAKE_PROBE
#define STACKCHAN_ENABLE_MWW_WAKE_PROBE 0
#endif

#if STACKCHAN_ENABLE_MWW_WAKE_PROBE

#include "wake/MicroWakeWordProbe.hpp"

#include <Arduino.h>

#include <algorithm>
#include <string.h>

#include <esp_heap_caps.h>
#include <tensorflow/lite/core/c/common.h>
#include <tensorflow/lite/schema/schema_generated.h>

namespace stackchan {
namespace {

uint8_t* allocateArena(size_t bytes) {
  // Streaming models keep CALL_ONCE and recurrent resource state in these
  // arenas. Fresh allocations must not inherit arbitrary PSRAM contents.
  uint8_t* ptr = static_cast<uint8_t*>(
      heap_caps_calloc(1u, bytes, MALLOC_CAP_SPIRAM | MALLOC_CAP_8BIT));
  if (ptr == nullptr) {
    ptr = static_cast<uint8_t*>(
        heap_caps_calloc(1u, bytes, MALLOC_CAP_INTERNAL | MALLOC_CAP_8BIT));
  }
  if (ptr == nullptr) {
    ptr = static_cast<uint8_t*>(heap_caps_calloc(1u, bytes, MALLOC_CAP_8BIT));
  }
  return ptr;
}

bool arenaIsZeroInitialized(const uint8_t* arena, size_t bytes) {
  if (arena == nullptr) {
    return false;
  }
  for (size_t i = 0; i < bytes; ++i) {
    if (arena[i] != 0u) {
      return false;
    }
  }
  return true;
}

}  // namespace

bool MicroWakeWordProbe::begin(const MicroWakeWordProbeConfig& config) {
  config_ = config;
  telemetry_ = MicroWakeWordProbeTelemetry {};
  if (config_.modelData == nullptr || config_.modelSize == 0) {
    copyError("mww_model_missing");
    return false;
  }
  if (config_.slidingWindowSize == 0 || config_.slidingWindowSize > kMaxSlidingWindow) {
    copyError("mww_bad_window");
    return false;
  }
  if (config_.featureStepMs == 0) {
    copyError("mww_bad_step");
    return false;
  }

  if (!registerOps()) {
    copyError("mww_ops_failed");
    return false;
  }

  frontendConfig_.window.size_ms = kFeatureWindowMs;
  frontendConfig_.window.step_size_ms = config_.featureStepMs;
  frontendConfig_.filterbank.num_channels = kFeatureSize;
  frontendConfig_.filterbank.lower_band_limit = 125.0f;
  frontendConfig_.filterbank.upper_band_limit = 7500.0f;
  frontendConfig_.noise_reduction.smoothing_bits = 10;
  frontendConfig_.noise_reduction.even_smoothing = 0.025f;
  frontendConfig_.noise_reduction.odd_smoothing = 0.06f;
  frontendConfig_.noise_reduction.min_signal_remaining = 0.05f;
  frontendConfig_.pcan_gain_control.enable_pcan = 1;
  frontendConfig_.pcan_gain_control.strength = 0.95f;
  frontendConfig_.pcan_gain_control.offset = 80.0f;
  frontendConfig_.pcan_gain_control.gain_bits = 21;
  frontendConfig_.log_scale.enable_log = 1;
  frontendConfig_.log_scale.scale_shift = 6;

  if (!FrontendPopulateState(&frontendConfig_, &frontendState_, 16000)) {
    copyError("mww_frontend_failed");
    return false;
  }
  frontendReady_ = true;

  variableArena_ = allocateArena(config_.variableArenaSize);
  if (variableArena_ == nullptr) {
    copyError("mww_var_alloc_failed");
    return false;
  }
  if (!arenaIsZeroInitialized(variableArena_, config_.variableArenaSize)) {
    copyError("mww_var_not_zeroed");
    return false;
  }
  allocator_ = tflite::MicroAllocator::Create(variableArena_, config_.variableArenaSize);
  resourceVariables_ = tflite::MicroResourceVariables::Create(allocator_, 20);
  if (allocator_ == nullptr || resourceVariables_ == nullptr) {
    copyError("mww_resource_failed");
    return false;
  }

  tensorArena_ = allocateArena(config_.tensorArenaSize);
  if (tensorArena_ == nullptr) {
    copyError("mww_tensor_alloc_failed");
    return false;
  }
  if (!arenaIsZeroInitialized(tensorArena_, config_.tensorArenaSize)) {
    copyError("mww_tensor_not_zeroed");
    return false;
  }
  telemetry_.arenasZeroInitialized = true;

  const tflite::Model* model = tflite::GetModel(config_.modelData);
  if (model == nullptr || model->version() != TFLITE_SCHEMA_VERSION) {
    copyError("mww_schema_failed");
    return false;
  }

  interpreter_ = std::make_unique<tflite::MicroInterpreter>(
      model, resolver_, tensorArena_, config_.tensorArenaSize, resourceVariables_);
  if (!interpreter_ || interpreter_->AllocateTensors() != kTfLiteOk) {
    copyError("mww_allocate_failed");
    return false;
  }

  TfLiteTensor* input = interpreter_->input(0);
  TfLiteTensor* output = interpreter_->output(0);
  if (input == nullptr || output == nullptr || input->type != kTfLiteInt8 || output->type != kTfLiteUInt8 ||
      input->dims == nullptr || input->dims->size != 3 || input->dims->data[0] != 1 ||
      input->dims->data[2] != static_cast<int>(kFeatureSize) || input->dims->data[1] <= 0 ||
      input->dims->data[1] > 255 || output->dims == nullptr || output->dims->size != 2 ||
      output->dims->data[0] != 1 || output->dims->data[1] != 1) {
    copyError("mww_shape_failed");
    return false;
  }

  stride_ = static_cast<uint8_t>(input->dims->data[1]);
  telemetry_.arenaUsedBytes = interpreter_->arena_used_bytes();
  telemetry_.modelStride = stride_;
  telemetry_.probabilityCutoff = config_.probabilityCutoff;
  telemetry_.slidingWindowSize = config_.slidingWindowSize;
  telemetry_.ready = true;
  copyError("");
  reset();
  return true;
}

void MicroWakeWordProbe::reset() {
  strideIndex_ = 0;
  recentIndex_ = 0;
  memset(recent_, 0, sizeof(recent_));
  warmup_ = -static_cast<int16_t>(config_.warmupWindows);
  telemetry_.lastProbability = 0;
  telemetry_.averageProbability = 0;
  telemetry_.maxAverageProbability = 0;
  telemetry_.lastFeatureMin = 0;
  telemetry_.lastFeatureMax = 0;
  telemetry_.minFeatureSeen = 0;
  telemetry_.maxFeatureSeen = 0;
  if (interpreter_) {
    interpreter_->Reset();
  }
  if (frontendReady_) {
    FrontendReset(&frontendState_);
  }
}

void MicroWakeWordProbe::clearTelemetry() {
  const bool ready = telemetry_.ready;
  const bool arenasZeroInitialized = telemetry_.arenasZeroInitialized;
  const uint32_t arenaUsedBytes = telemetry_.arenaUsedBytes;
  const uint32_t modelStride = telemetry_.modelStride;
  const uint32_t probabilityCutoff = telemetry_.probabilityCutoff;
  const uint32_t slidingWindowSize = telemetry_.slidingWindowSize;
  char savedError[sizeof(telemetry_.error)] = {};
  memcpy(savedError, telemetry_.error, sizeof(savedError));
  telemetry_ = MicroWakeWordProbeTelemetry {};
  telemetry_.ready = ready;
  telemetry_.arenasZeroInitialized = arenasZeroInitialized;
  telemetry_.arenaUsedBytes = arenaUsedBytes;
  telemetry_.modelStride = modelStride;
  telemetry_.probabilityCutoff = probabilityCutoff;
  telemetry_.slidingWindowSize = slidingWindowSize;
  memcpy(telemetry_.error, savedError, sizeof(telemetry_.error));
}

bool MicroWakeWordProbe::feed(const int16_t* samples, size_t sampleCount) {
  if (!telemetry_.ready || samples == nullptr || sampleCount == 0 || !interpreter_) {
    return false;
  }

  size_t offset = 0;
  int8_t features[kFeatureSize] {};
  while (offset < sampleCount) {
    size_t processedSamples = 0;
    const FrontendOutput output =
        FrontendProcessSamples(&frontendState_, samples + offset, sampleCount - offset, &processedSamples);
    if (processedSamples == 0) {
      break;
    }
    offset += processedSamples;
    if (output.size == 0) {
      continue;
    }
    if (output.size != kFeatureSize) {
      telemetry_.featureErrors++;
      continue;
    }

    int32_t featureMin = 127;
    int32_t featureMax = -128;
    for (size_t i = 0; i < kFeatureSize; ++i) {
      constexpr int32_t kValueScale = 256;
      constexpr int32_t kValueDiv = 666;
      int32_t value = ((output.values[i] * kValueScale) + (kValueDiv / 2)) / kValueDiv;
      value -= 128;
      if (value < -128) {
        value = -128;
      } else if (value > 127) {
        value = 127;
      }
      if (value < featureMin) {
        featureMin = value;
      }
      if (value > featureMax) {
        featureMax = value;
      }
      features[i] = static_cast<int8_t>(value);
    }

    telemetry_.lastFeatureMin = featureMin;
    telemetry_.lastFeatureMax = featureMax;
    if (telemetry_.features == 0 || featureMin < telemetry_.minFeatureSeen) {
      telemetry_.minFeatureSeen = featureMin;
    }
    if (telemetry_.features == 0 || featureMax > telemetry_.maxFeatureSeen) {
      telemetry_.maxFeatureSeen = featureMax;
    }
    telemetry_.features++;
    if (processFeature(features)) {
      return true;
    }
  }
  return false;
}

bool MicroWakeWordProbe::registerOps() {
  if (opsRegistered_) {
    return true;
  }
  if (resolver_.AddCallOnce() != kTfLiteOk) return false;
  if (resolver_.AddVarHandle() != kTfLiteOk) return false;
  if (resolver_.AddReshape() != kTfLiteOk) return false;
  if (resolver_.AddReadVariable() != kTfLiteOk) return false;
  if (resolver_.AddStridedSlice() != kTfLiteOk) return false;
  if (resolver_.AddConcatenation() != kTfLiteOk) return false;
  if (resolver_.AddAssignVariable() != kTfLiteOk) return false;
  if (resolver_.AddConv2D() != kTfLiteOk) return false;
  if (resolver_.AddMul() != kTfLiteOk) return false;
  if (resolver_.AddAdd() != kTfLiteOk) return false;
  if (resolver_.AddMean() != kTfLiteOk) return false;
  if (resolver_.AddFullyConnected() != kTfLiteOk) return false;
  if (resolver_.AddLogistic() != kTfLiteOk) return false;
  if (resolver_.AddQuantize() != kTfLiteOk) return false;
  if (resolver_.AddDepthwiseConv2D() != kTfLiteOk) return false;
  if (resolver_.AddAveragePool2D() != kTfLiteOk) return false;
  if (resolver_.AddMaxPool2D() != kTfLiteOk) return false;
  if (resolver_.AddPad() != kTfLiteOk) return false;
  if (resolver_.AddPack() != kTfLiteOk) return false;
  if (resolver_.AddSplitV() != kTfLiteOk) return false;
  opsRegistered_ = true;
  return true;
}

bool MicroWakeWordProbe::processFeature(const int8_t* features) {
  TfLiteTensor* input = interpreter_->input(0);
  int8_t* inputData = input->data.int8;
  if (inputData == nullptr || stride_ == 0) {
    telemetry_.featureErrors++;
    return false;
  }

  memcpy(inputData + (static_cast<size_t>(strideIndex_) * kFeatureSize), features, kFeatureSize);
  strideIndex_++;
  if (strideIndex_ < stride_) {
    return false;
  }
  strideIndex_ = 0;

  const uint32_t startUs = micros();
  if (interpreter_->Invoke() != kTfLiteOk) {
    telemetry_.invokeErrors++;
    return false;
  }
  const uint32_t inferenceUs = micros() - startUs;
  telemetry_.lastInferenceUs = inferenceUs;
  if (inferenceUs > telemetry_.maxInferenceUs) {
    telemetry_.maxInferenceUs = inferenceUs;
  }

  TfLiteTensor* output = interpreter_->output(0);
  const uint8_t probability = output->data.uint8[0];
  telemetry_.lastProbability = probability;
  if (probability > telemetry_.maxProbability) {
    telemetry_.maxProbability = probability;
  }
  telemetry_.inferences++;

  recent_[recentIndex_] = probability;
  recentIndex_ = (recentIndex_ + 1u) % config_.slidingWindowSize;
  warmup_ = std::min<int16_t>(static_cast<int16_t>(warmup_ + 1), 0);
  if (warmup_ < 0) {
    return false;
  }

  uint32_t sum = 0;
  for (size_t i = 0; i < config_.slidingWindowSize; ++i) {
    sum += recent_[i];
  }
  telemetry_.averageProbability = sum / config_.slidingWindowSize;
  if (telemetry_.averageProbability > telemetry_.maxAverageProbability) {
    telemetry_.maxAverageProbability = telemetry_.averageProbability;
  }
  if (sum > static_cast<uint32_t>(config_.probabilityCutoff) * config_.slidingWindowSize) {
    telemetry_.detections++;
    telemetry_.lastDetectionProbability = probability;
    telemetry_.lastDetectionAverageProbability = telemetry_.averageProbability;
    if (telemetry_.averageProbability > telemetry_.maxDetectionAverageProbability) {
      telemetry_.maxDetectionAverageProbability = telemetry_.averageProbability;
    }
    reset();
    return true;
  }
  return false;
}

void MicroWakeWordProbe::copyError(const char* value) {
  if (value == nullptr) {
    telemetry_.error[0] = '\0';
    return;
  }
  const size_t len = strlen(value);
  const size_t copyLen = len < sizeof(telemetry_.error) - 1u ? len : sizeof(telemetry_.error) - 1u;
  memcpy(telemetry_.error, value, copyLen);
  telemetry_.error[copyLen] = '\0';
}

}  // namespace stackchan

#endif  // STACKCHAN_ENABLE_MWW_WAKE_PROBE
