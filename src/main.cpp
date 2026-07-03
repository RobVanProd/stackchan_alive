#include <Arduino.h>
#include <Esp.h>
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
QueueHandle_t gSpeechQueue = nullptr;
QueueHandle_t gFaceControlQueue = nullptr;
QueueHandle_t gMotionControlQueue = nullptr;
RobotConfig gConfig = defaultRobotConfig();
StackChanServoAdapter gServo;
DisplayAdapter gDisplay;
SensorAdapter gSensors;
ActuationEngine gActuation(gConfig);
ProceduralFace gFace;
IntentEngine gIntent;
TaskHandle_t gMotionTaskHandle = nullptr;
TaskHandle_t gFaceTaskHandle = nullptr;
TaskHandle_t gIntentTaskHandle = nullptr;

struct FaceSpeechInput {
  bool clear = false;
  float envelope = 0.0f;
  SpeechViseme viseme = SpeechViseme::Neutral;
  uint32_t timestampMs = 0;
  uint32_t durationMs = 0;
};

struct FaceControlInput {
  bool hasReducedMotion = false;
  bool reducedMotion = false;
};

struct MotionControlInput {
  bool hasMotionEnable = false;
  bool motionEnabled = true;
};

const __FlashStringHelper* firmwareMode() {
#if STACKCHAN_ENABLE_SERVOS
  return F("servo_calibration");
#else
  return F("display_only");
#endif
}

const __FlashStringHelper* characterModeName(CharacterMode mode) {
  switch (mode) {
    case CharacterMode::Boot:
      return F("boot");
    case CharacterMode::Idle:
      return F("idle");
    case CharacterMode::Attend:
      return F("attend");
    case CharacterMode::Listen:
      return F("listen");
    case CharacterMode::Think:
      return F("think");
    case CharacterMode::Speak:
      return F("speak");
    case CharacterMode::React:
      return F("react");
    case CharacterMode::Sleep:
      return F("sleep");
    case CharacterMode::Error:
      return F("error");
  }
  return F("unknown");
}

const __FlashStringHelper* eventTypeName(EventType type) {
  switch (type) {
    case EventType::Boot:
      return F("boot");
    case EventType::FaceDetected:
      return F("face_detected");
    case EventType::FaceLost:
      return F("face_lost");
    case EventType::UserNear:
      return F("user_near");
    case EventType::UserTouched:
      return F("user_touched");
    case EventType::WakeWord:
      return F("wake_word");
    case EventType::UserSpeaking:
      return F("user_speaking");
    case EventType::SpeechEnded:
      return F("speech_ended");
    case EventType::ThinkingStarted:
      return F("thinking_started");
    case EventType::ResponseStarted:
      return F("response_started");
    case EventType::ResponseEnded:
      return F("response_ended");
    case EventType::IdleTimeout:
      return F("idle_timeout");
    case EventType::Error:
      return F("error");
    case EventType::PickedUp:
      return F("picked_up");
    case EventType::Shaken:
      return F("shaken");
    case EventType::PutDown:
      return F("put_down");
    case EventType::Tilted:
      return F("tilted");
    case EventType::SoundDirection:
      return F("sound_direction");
    case EventType::LoudNoise:
      return F("loud_noise");
  }
  return F("unknown");
}

bool isAudioTelemetryEvent(EventType type) {
  return type == EventType::SoundDirection || type == EventType::LoudNoise ||
         type == EventType::UserSpeaking || type == EventType::SpeechEnded;
}

const __FlashStringHelper* speechVisemeName(SpeechViseme viseme) {
  switch (viseme) {
    case SpeechViseme::Ah:
      return F("ah");
    case SpeechViseme::Oh:
      return F("oh");
    case SpeechViseme::Ee:
      return F("ee");
    case SpeechViseme::Neutral:
      return F("neutral");
  }
  return F("unknown");
}

SpeechViseme toSpeechViseme(BenchSpeechViseme viseme) {
  switch (viseme) {
    case BenchSpeechViseme::Ah:
      return SpeechViseme::Ah;
    case BenchSpeechViseme::Oh:
      return SpeechViseme::Oh;
    case BenchSpeechViseme::Ee:
      return SpeechViseme::Ee;
    case BenchSpeechViseme::Neutral:
      return SpeechViseme::Neutral;
  }
  return SpeechViseme::Neutral;
}

const __FlashStringHelper* speechIntentName(SpeechIntent intent) {
  switch (intent) {
    case SpeechIntent::Boot:
      return F("boot");
    case SpeechIntent::Idle:
      return F("idle");
    case SpeechIntent::Attend:
      return F("attend");
    case SpeechIntent::Listen:
      return F("listen");
    case SpeechIntent::Think:
      return F("think");
    case SpeechIntent::Speak:
      return F("speak");
    case SpeechIntent::React:
      return F("react");
    case SpeechIntent::Happy:
      return F("happy");
    case SpeechIntent::Concern:
      return F("concern");
    case SpeechIntent::Sleep:
      return F("sleep");
    case SpeechIntent::Error:
      return F("error");
    case SpeechIntent::Safety:
      return F("safety");
    case SpeechIntent::None:
      break;
  }
  return F("none");
}

const __FlashStringHelper* speechEarconName(SpeechEarcon earcon) {
  switch (earcon) {
    case SpeechEarcon::Wake:
      return F("wake");
    case SpeechEarcon::Confirm:
      return F("confirm");
    case SpeechEarcon::Think:
      return F("think");
    case SpeechEarcon::Happy:
      return F("happy");
    case SpeechEarcon::Concern:
      return F("concern");
    case SpeechEarcon::Sleep:
      return F("sleep");
    case SpeechEarcon::Error:
      return F("error");
    case SpeechEarcon::Safety:
      return F("safety");
    case SpeechEarcon::None:
      break;
  }
  return F("none");
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

UBaseType_t stackHighWater(TaskHandle_t handle) {
  return handle == nullptr ? 0 : uxTaskGetStackHighWaterMark(handle);
}

void printSystemTelemetry() {
  Serial.print(F("[system] heap_free="));
  Serial.print(ESP.getFreeHeap());
  Serial.print(F(" heap_min="));
  Serial.print(ESP.getMinFreeHeap());
  Serial.print(F(" stack_loop_hwm="));
  Serial.print(uxTaskGetStackHighWaterMark(nullptr));
  Serial.print(F(" stack_motion_hwm="));
  Serial.print(stackHighWater(gMotionTaskHandle));
  Serial.print(F(" stack_face_hwm="));
  Serial.print(stackHighWater(gFaceTaskHandle));
  Serial.print(F(" stack_intent_hwm="));
  Serial.println(stackHighWater(gIntentTaskHandle));
}

void printRuntimeStatus() {
  const FaceSpeechTelemetry& speech = gFace.speechTelemetry();
  Serial.print(F("[runtime] motion_enabled="));
  Serial.print(gActuation.isEnabled() ? 1 : 0);
  Serial.print(F(" demo_enabled="));
  Serial.print(gIntent.isDemoEnabled() ? 1 : 0);
  Serial.print(F(" reduced_motion="));
  Serial.print(gFace.isReducedMotion() ? 1 : 0);
  Serial.print(F(" speech_active="));
  Serial.print(speech.active ? 1 : 0);
  Serial.print(F(" speech_env="));
  Serial.println(speech.envelope, 2);
}

void printSpeechCue(const SpeechCue& cue, uint32_t speechSeq, uint32_t nowMs) {
  Serial.print(F("[speech] seq="));
  Serial.print(speechSeq);
  Serial.print(F(" at_ms="));
  Serial.print(nowMs);
  Serial.print(F(" intent="));
  Serial.print(speechIntentName(cue.intent));
  Serial.print(F(" priority="));
  Serial.print(cue.priority);
  Serial.print(F(" earcon="));
  Serial.print(speechEarconName(cue.earcon));
  Serial.print(F(" earcon_delay_ms="));
  Serial.print(cue.earconDelayMs);
  Serial.print(F(" text=\""));
  Serial.print(cue.text);
  Serial.println(F("\""));
}

void printBenchControl(const BenchControl& control) {
  Serial.print(F("[control] command="));
  Serial.print(control.command);
  if (control.hasEvent) {
    Serial.print(F(" mode="));
    Serial.print(characterModeName(control.mode));
    Serial.print(F(" event="));
    Serial.print(eventTypeName(control.event.type));
    Serial.print(F(" strength="));
    Serial.print(control.event.strength, 2);
    if (control.event.hasPayload) {
      Serial.print(F(" payload_x="));
      Serial.print(control.event.x, 2);
      Serial.print(F(" payload_y="));
      Serial.print(control.event.y, 2);
      Serial.print(F(" payload_z="));
      Serial.print(control.event.z, 2);
    }
  }
  if (control.hasSpeech) {
    Serial.print(F(" speech_clear="));
    Serial.print(control.speech.clear ? 1 : 0);
    Serial.print(F(" speech_env="));
    Serial.print(control.speech.envelope, 2);
    Serial.print(F(" viseme="));
    Serial.print(speechVisemeName(toSpeechViseme(control.speech.viseme)));
    Serial.print(F(" speech_duration_ms="));
    Serial.print(control.speech.durationMs);
  }
  if (control.hasReducedMotion) {
    Serial.print(F(" reduced_motion="));
    Serial.print(control.reducedMotion ? 1 : 0);
  }
  if (control.hasMotionEnable) {
    Serial.print(F(" motion_enabled="));
    Serial.print(control.motionEnabled ? 1 : 0);
  }
  if (control.hasDemoEnable) {
    Serial.print(F(" demo_enabled="));
    Serial.print(control.demoEnabled ? 1 : 0);
  }
  if (control.hasAmbient) {
    Serial.print(F(" ambient_lux="));
    Serial.print(control.ambient.lux, 1);
    Serial.print(F(" hour="));
    Serial.print(control.ambient.hourOfDay);
  }
  if (control.hasCircadian) {
    Serial.print(F(" circadian_hour="));
    Serial.print(control.hourOfDay);
  }
  if (control.hasSpeechCue) {
    Serial.print(F(" cue_intent="));
    Serial.print(speechIntentName(control.speechCue.intent));
    Serial.print(F(" cue_earcon="));
    Serial.print(speechEarconName(control.speechCue.earcon));
  }
  Serial.print(F(" at_ms="));
  Serial.println(control.hasEvent ? control.event.timestampMs : millis());
}

void printAudioTelemetry(const RobotEvent& event, uint32_t frameMs) {
  const uint32_t latencyMs = frameMs >= event.timestampMs ? frameMs - event.timestampMs : 0;
  Serial.print(F("[audio] event="));
  Serial.print(eventTypeName(event.type));
  Serial.print(F(" detect_ms="));
  Serial.print(event.timestampMs);
  Serial.print(F(" frame_ms="));
  Serial.print(frameMs);
  Serial.print(F(" latency_ms="));
  Serial.print(latencyMs);
  Serial.print(F(" level="));
  Serial.print(event.hasPayload ? event.z : event.strength, 2);
  if (event.hasPayload) {
    Serial.print(F(" azimuth_deg="));
    Serial.print(event.x * 90.0f, 1);
  }
  Serial.println();
}

void publishSpeechInput(const BenchControl& control) {
  if (gSpeechQueue == nullptr || !control.hasSpeech) {
    return;
  }

  FaceSpeechInput input;
  input.clear = control.speech.clear;
  input.envelope = control.speech.envelope;
  input.viseme = toSpeechViseme(control.speech.viseme);
  input.timestampMs = control.hasEvent ? control.event.timestampMs : millis();
  input.durationMs = control.speech.durationMs;
  xQueueOverwrite(gSpeechQueue, &input);
}

void publishFaceControl(const BenchControl& control) {
  if (gFaceControlQueue == nullptr || !control.hasReducedMotion) {
    return;
  }

  FaceControlInput input;
  input.hasReducedMotion = true;
  input.reducedMotion = control.reducedMotion;
  xQueueOverwrite(gFaceControlQueue, &input);
}

void publishMotionControl(const BenchControl& control) {
  if (gMotionControlQueue == nullptr || !control.hasMotionEnable) {
    return;
  }

  MotionControlInput input;
  input.hasMotionEnable = true;
  input.motionEnabled = control.motionEnabled;
  xQueueOverwrite(gMotionControlQueue, &input);
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

void applySpeechInput(uint32_t nowMs) {
  static FaceSpeechInput active;
  static bool hasActive = false;

  FaceSpeechInput incoming;
  while (gSpeechQueue != nullptr && xQueueReceive(gSpeechQueue, &incoming, 0) == pdTRUE) {
    active = incoming;
    hasActive = !incoming.clear;
    if (incoming.clear) {
      gFace.clearSpeechEnvelope(nowMs);
    }
  }

  if (!hasActive) {
    return;
  }

  const uint32_t elapsedMs = nowMs - active.timestampMs;
  if (elapsedMs <= active.durationMs) {
    gFace.setSpeechEnvelope(active.envelope, active.viseme, nowMs);
  } else {
    hasActive = false;
    gFace.clearSpeechEnvelope(nowMs);
  }
}

void applyFaceControlInput() {
  FaceControlInput input;
  while (gFaceControlQueue != nullptr && xQueueReceive(gFaceControlQueue, &input, 0) == pdTRUE) {
    if (input.hasReducedMotion) {
      gFace.setReducedMotion(input.reducedMotion);
    }
  }
}

void applyMotionControlInput() {
  MotionControlInput input;
  while (gMotionControlQueue != nullptr && xQueueReceive(gMotionControlQueue, &input, 0) == pdTRUE) {
    if (input.hasMotionEnable) {
      gActuation.setEnabled(input.motionEnabled);
      Serial.print(F("[motion] enabled="));
      Serial.println(input.motionEnabled ? 1 : 0);
    }
  }
}

void MotionTask(void* pv) {
  (void)pv;
  RobotFrame target = makeNeutralFrame();
  TickType_t wake = xTaskGetTickCount();

  while (true) {
    target = readLatestFrame(target);
    applyMotionControlInput();
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
    const uint32_t nowMs = millis();
    applyFaceControlInput();
    applySpeechInput(nowMs);
    gFace.render(target, nowMs);
    vTaskDelayUntil(&wake, pdMS_TO_TICKS(gConfig.timing.facePeriodMs));
  }
}

void IntentTask(void* pv) {
  (void)pv;
  TickType_t wake = xTaskGetTickCount();
  uint32_t lastSpeechSeq = 0;
  RobotEvent pendingAudioEvent;
  bool hasPendingAudioEvent = false;

  while (true) {
    BenchControl control;
    while (gSensors.poll(&control)) {
      if (control.hasEvent) {
        gIntent.applyEvent(control.event, control.mode);
        if (isAudioTelemetryEvent(control.event.type)) {
          pendingAudioEvent = control.event;
          hasPendingAudioEvent = true;
        }
      }
      if (control.wantsStatus) {
        printHeartbeat();
        printSystemTelemetry();
        printRuntimeStatus();
      }
      if (control.hasDemoEnable) {
        gIntent.setDemoEnabled(control.demoEnabled, millis());
      }
      if (control.hasReducedMotion) {
        gIntent.setReducedMotion(control.reducedMotion);
      }
      if (control.hasAmbient) {
        gIntent.applyAmbient(control.ambient.lux, control.ambient.hourOfDay);
      }
      if (control.hasCircadian) {
        gIntent.applyCircadian(control.hourOfDay);
      }
      if (control.hasSpeechCue) {
        gIntent.queueSpeechCue(control.speechCue, millis());
      }
      publishSpeechInput(control);
      publishFaceControl(control);
      publishMotionControl(control);
      printBenchControl(control);
    }

    RobotFrame frame = gIntent.update(millis());
    if (hasPendingAudioEvent) {
      printAudioTelemetry(pendingAudioEvent, frame.timestampMs);
      hasPendingAudioEvent = false;
    }
    if (frame.speechSeq != 0 && frame.speechSeq != lastSpeechSeq && frame.speech.shouldSpeak()) {
      lastSpeechSeq = frame.speechSeq;
      printSpeechCue(frame.speech, frame.speechSeq, frame.timestampMs);
    }
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
  gSpeechQueue = xQueueCreate(1, sizeof(FaceSpeechInput));
  gFaceControlQueue = xQueueCreate(1, sizeof(FaceControlInput));
  gMotionControlQueue = xQueueCreate(1, sizeof(MotionControlInput));
  if (gFrameQueue == nullptr || gSpeechQueue == nullptr || gFaceControlQueue == nullptr || gMotionControlQueue == nullptr) {
    Serial.println(F("[fatal] queue allocation failed"));
    abort();
  }

  gSensors.begin();
  gActuation.begin(&gServo);
  gFace.begin(&gDisplay, gConfig.face);
  gIntent.begin();

  publishFrame(makeNeutralFrame());

  BaseType_t ok = xTaskCreatePinnedToCore(MotionTask, "MotionTask", 4096, nullptr, 3, &gMotionTaskHandle, 1);
  ok &= xTaskCreatePinnedToCore(FaceTask, "FaceTask", 4096, nullptr, 2, &gFaceTaskHandle, 1);
  ok &= xTaskCreatePinnedToCore(IntentTask, "IntentTask", 4096, nullptr, 2, &gIntentTaskHandle, 1);

  if (ok != pdPASS) {
    Serial.println(F("[fatal] task creation failed"));
    abort();
  }
}

void loop() {
  static uint32_t lastHeartbeatMs = 0;
  const uint32_t nowMs = millis();
  if (lastHeartbeatMs == 0 || nowMs - lastHeartbeatMs >= 10000) {
    lastHeartbeatMs = nowMs;
    printHeartbeat();
    printSystemTelemetry();
    printRuntimeStatus();
  }
  vTaskDelay(pdMS_TO_TICKS(1000));
}
#endif
