#include <Arduino.h>
#include <freertos/FreeRTOS.h>
#include <freertos/queue.h>
#include <freertos/task.h>

#include "config/RobotConfig.hpp"
#include "face/ProceduralFace.hpp"
#include "io/DisplayAdapter.hpp"
#include "io/SensorAdapter.hpp"
#include "io/StackChanServoAdapter.hpp"
#include "motion/ActuationEngine.hpp"
#include "persona/IntentEngine.hpp"
#include "persona/StateMatrix.hpp"

using namespace stackchan;

namespace {

QueueHandle_t gFrameQueue = nullptr;
RobotConfig gConfig = defaultRobotConfig();
StackChanServoAdapter gServo;
DisplayAdapter gDisplay;
SensorAdapter gSensors;
ActuationEngine gActuation(gConfig);
ProceduralFace gFace;
IntentEngine gIntent;

void publishFrame(const RobotFrame& frame) {
  if (gFrameQueue != nullptr) {
    xQueueOverwrite(gFrameQueue, &frame);
  }
}

RobotFrame readLatestFrame(const RobotFrame& fallback) {
  RobotFrame incoming;
  if (gFrameQueue != nullptr && xQueueReceive(gFrameQueue, &incoming, 0) == pdTRUE) {
    return incoming;
  }
  return fallback;
}

void MotionTask(void* pv) {
  (void)pv;
  RobotFrame target = makeNeutralFrame();
  TickType_t wake = xTaskGetTickCount();

  while (true) {
    target = readLatestFrame(target);
    gActuation.update(target, micros());
    vTaskDelayUntil(&wake, pdMS_TO_TICKS(gConfig.timing.motionPeriodMs));
  }
}

void FaceTask(void* pv) {
  (void)pv;
  RobotFrame target = makeNeutralFrame();
  TickType_t wake = xTaskGetTickCount();

  while (true) {
    target = readLatestFrame(target);
    gFace.render(target, millis());
    vTaskDelayUntil(&wake, pdMS_TO_TICKS(gConfig.timing.facePeriodMs));
  }
}

void IntentTask(void* pv) {
  (void)pv;
  TickType_t wake = xTaskGetTickCount();

  while (true) {
    RobotFrame frame = gIntent.update(millis());
    publishFrame(frame);
    vTaskDelayUntil(&wake, pdMS_TO_TICKS(gConfig.timing.intentPeriodMs));
  }
}

}  // namespace

void setup() {
  Serial.begin(115200);
  delay(200);
  randomSeed(esp_random());

  gFrameQueue = xQueueCreate(1, sizeof(RobotFrame));
  gSensors.begin();
  gActuation.begin(&gServo);
  gFace.begin(&gDisplay);
  gIntent.begin();

  publishFrame(makeNeutralFrame());

  xTaskCreatePinnedToCore(MotionTask, "MotionTask", 4096, nullptr, 3, nullptr, 1);
  xTaskCreatePinnedToCore(FaceTask, "FaceTask", 4096, nullptr, 2, nullptr, 1);
  xTaskCreatePinnedToCore(IntentTask, "IntentTask", 4096, nullptr, 2, nullptr, 1);
}

void loop() {
  vTaskDelay(pdMS_TO_TICKS(1000));
}
