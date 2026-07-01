#include <Arduino.h>
#include <M5Unified.h>
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

const __FlashStringHelper* firmwareMode() {
#if STACKCHAN_ENABLE_SERVOS
  return F("servo_calibration");
#else
  return F("display_only");
#endif
}

void printBootMarker() {
  Serial.print(F("[boot] stackchan_alive mode="));
  Serial.print(firmwareMode());
  Serial.println(F(" serial=v1"));
}

void printHeartbeat() {
  Serial.print(F("[heartbeat] stackchan_alive mode="));
  Serial.print(firmwareMode());
  Serial.print(F(" uptime_ms="));
  Serial.println(millis());
}

void publishFrame(const RobotFrame& frame) {
  if (gFrameQueue != nullptr) {
    xQueueOverwrite(gFrameQueue, &frame);
  }
}

RobotFrame readLatestFrame(const RobotFrame& fallback) {
  RobotFrame incoming;
  if (gFrameQueue != nullptr && xQueuePeek(gFrameQueue, &incoming, 0) == pdTRUE) {
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

#if !defined(PIO_UNIT_TESTING) && !defined(UNIT_TEST)
void setup() {
  auto cfg = M5.config();
  cfg.serial_baudrate = 115200;
  M5.begin(cfg);
  M5.Log.setLogLevel(m5::log_target_serial, ESP_LOG_INFO);
  M5.Log.setEnableColor(m5::log_target_serial, false);
  delay(200);
  printBootMarker();
  randomSeed(esp_random());

  gFrameQueue = xQueueCreate(1, sizeof(RobotFrame));
  if (gFrameQueue == nullptr) {
    Serial.println(F("[fatal] frame queue allocation failed"));
    abort();
  }

  gSensors.begin();
  gActuation.begin(&gServo);
  gFace.begin(&gDisplay);
  gIntent.begin();

  publishFrame(makeNeutralFrame());

  BaseType_t ok = xTaskCreatePinnedToCore(MotionTask, "MotionTask", 4096, nullptr, 3, nullptr, 1);
  ok &= xTaskCreatePinnedToCore(FaceTask, "FaceTask", 4096, nullptr, 2, nullptr, 1);
  ok &= xTaskCreatePinnedToCore(IntentTask, "IntentTask", 4096, nullptr, 2, nullptr, 1);

  if (ok != pdPASS) {
    Serial.println(F("[fatal] task creation failed"));
    abort();
  }
}

void loop() {
  M5.update();
  static uint32_t lastHeartbeatMs = 0;
  const uint32_t nowMs = millis();
  if (lastHeartbeatMs == 0 || nowMs - lastHeartbeatMs >= 10000) {
    lastHeartbeatMs = nowMs;
    printHeartbeat();
  }
  vTaskDelay(pdMS_TO_TICKS(1000));
}
#endif
