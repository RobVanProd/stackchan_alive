#pragma once

#include <stddef.h>
#include <stdint.h>

#include <memory>

#include <frontend.h>
#include <frontend_util.h>
#include <tensorflow/lite/micro/micro_allocator.h>
#include <tensorflow/lite/micro/micro_interpreter.h>
#include <tensorflow/lite/micro/micro_mutable_op_resolver.h>
#include <tensorflow/lite/micro/micro_resource_variable.h>

namespace stackchan {

struct MicroWakeWordProbeConfig {
  const uint8_t* modelData = nullptr;
  size_t modelSize = 0;
  uint8_t probabilityCutoff = 217;
  uint8_t slidingWindowSize = 5;
  uint8_t featureStepMs = 10;
  uint16_t warmupWindows = 100;
  size_t tensorArenaSize = 65536;
  size_t variableArenaSize = 1024;
};

struct MicroWakeWordProbeTelemetry {
  bool ready = false;
  bool arenasZeroInitialized = false;
  uint32_t arenaUsedBytes = 0;
  uint32_t modelStride = 0;
  uint32_t features = 0;
  uint32_t inferences = 0;
  uint32_t detections = 0;
  uint32_t invokeErrors = 0;
  uint32_t featureErrors = 0;
  uint32_t lastProbability = 0;
  uint32_t maxProbability = 0;
  uint32_t averageProbability = 0;
  uint32_t maxAverageProbability = 0;
  uint32_t probabilityCutoff = 0;
  uint32_t slidingWindowSize = 0;
  uint32_t lastDetectionProbability = 0;
  uint32_t lastDetectionAverageProbability = 0;
  uint32_t maxDetectionAverageProbability = 0;
  int32_t lastFeatureMin = 0;
  int32_t lastFeatureMax = 0;
  int32_t minFeatureSeen = 0;
  int32_t maxFeatureSeen = 0;
  uint32_t lastInferenceUs = 0;
  uint32_t maxInferenceUs = 0;
  char error[48] = {};
};

class MicroWakeWordProbe {
 public:
  bool begin(const MicroWakeWordProbeConfig& config);
  void reset();
  void clearTelemetry();
  bool feed(const int16_t* samples, size_t sampleCount);
  const MicroWakeWordProbeTelemetry& telemetry() const {
    return telemetry_;
  }

 private:
  static constexpr size_t kFeatureSize = 40;
  static constexpr size_t kFeatureWindowMs = 30;
  static constexpr size_t kMaxSlidingWindow = 16;

  bool registerOps();
  bool processFeature(const int8_t* features);
  void copyError(const char* value);

  MicroWakeWordProbeConfig config_;
  MicroWakeWordProbeTelemetry telemetry_;
  bool opsRegistered_ = false;
  bool frontendReady_ = false;
  uint8_t stride_ = 0;
  uint8_t strideIndex_ = 0;
  uint8_t recent_[kMaxSlidingWindow] = {};
  size_t recentIndex_ = 0;
  int16_t warmup_ = 0;
  uint8_t* tensorArena_ = nullptr;
  uint8_t* variableArena_ = nullptr;
  FrontendConfig frontendConfig_ {};
  FrontendState frontendState_ {};
  std::unique_ptr<tflite::MicroInterpreter> interpreter_;
  tflite::MicroAllocator* allocator_ = nullptr;
  tflite::MicroResourceVariables* resourceVariables_ = nullptr;
  tflite::MicroMutableOpResolver<20> resolver_;
};

}  // namespace stackchan
