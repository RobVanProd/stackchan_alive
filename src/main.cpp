#include <Arduino.h>
#include <Esp.h>
#include <M5Unified.h>
#if __has_include(<utility/power/INA226_Class.hpp>)
#include <utility/power/INA226_Class.hpp>
#define STACKCHAN_HAS_INA226_MONITOR 1
#else
#define STACKCHAN_HAS_INA226_MONITOR 0
#endif
#include <freertos/FreeRTOS.h>
#include <freertos/queue.h>
#include <freertos/task.h>
#include <math.h>
#include <stdarg.h>
#include <stdlib.h>
#include <string.h>

#if defined(ARDUINO_ARCH_ESP32)
#include <esp_heap_caps.h>
#include <esp_system.h>
#endif

#ifndef STACKCHAN_ENABLE_SR_WAKE_PROBE
#define STACKCHAN_ENABLE_SR_WAKE_PROBE 0
#endif

#if STACKCHAN_ENABLE_SR_WAKE_PROBE
#include "sdkconfig.h"
#if __has_include(<ESP_SR_M5Unified.h>) && defined(CONFIG_IDF_TARGET_ESP32S3) && CONFIG_IDF_TARGET_ESP32S3 && \
    defined(CONFIG_MODEL_IN_FLASH) && CONFIG_MODEL_IN_FLASH
#include <ESP_SR_M5Unified.h>
#define STACKCHAN_HAS_SR_WAKE_PROBE 1
#else
#define STACKCHAN_HAS_SR_WAKE_PROBE 0
#endif
#else
#define STACKCHAN_HAS_SR_WAKE_PROBE 0
#endif

#ifndef STACKCHAN_ENABLE_SR_WAKE_DIRECT
#define STACKCHAN_ENABLE_SR_WAKE_DIRECT 0
#endif

#ifndef STACKCHAN_ENABLE_SR_WAKE_AFE_LITE
#define STACKCHAN_ENABLE_SR_WAKE_AFE_LITE 0
#endif

#ifndef STACKCHAN_SR_WAKE_DIRECT_TASK_CORE
#define STACKCHAN_SR_WAKE_DIRECT_TASK_CORE 0
#endif

#ifndef STACKCHAN_SR_WAKE_DIRECT_TASK_PRIORITY
#define STACKCHAN_SR_WAKE_DIRECT_TASK_PRIORITY 1
#endif

#ifndef STACKCHAN_SR_WAKE_DIRECT_COOLDOWN_MS
#define STACKCHAN_SR_WAKE_DIRECT_COOLDOWN_MS 1500
#endif

#ifndef STACKCHAN_SR_WAKE_DIRECT_GAIN_Q8
#define STACKCHAN_SR_WAKE_DIRECT_GAIN_Q8 256
#endif

#ifndef STACKCHAN_SR_WAKE_DIRECT_MIC_MAGNIFICATION
#define STACKCHAN_SR_WAKE_DIRECT_MIC_MAGNIFICATION 2
#endif

#ifndef STACKCHAN_SR_WAKE_DIRECT_STEREO
#define STACKCHAN_SR_WAKE_DIRECT_STEREO 0
#endif

#ifndef STACKCHAN_SR_WAKE_DIRECT_MONO_CHANNEL
#define STACKCHAN_SR_WAKE_DIRECT_MONO_CHANNEL 0
#endif

#ifndef STACKCHAN_SR_WAKE_DIRECT_MIC_INPUT_STEREO
#define STACKCHAN_SR_WAKE_DIRECT_MIC_INPUT_STEREO 0
#endif

#ifndef STACKCHAN_SR_WAKE_DIRECT_DET_MODE
#define STACKCHAN_SR_WAKE_DIRECT_DET_MODE DET_MODE_90
#endif

#ifndef STACKCHAN_SR_WAKE_DIRECT_RECORD_SAMPLES
#define STACKCHAN_SR_WAKE_DIRECT_RECORD_SAMPLES 0
#endif

#ifndef STACKCHAN_SR_WAKE_MIC_TASK_CORE
#define STACKCHAN_SR_WAKE_MIC_TASK_CORE 0
#endif

#ifndef STACKCHAN_SR_WAKE_MIC_TASK_PRIORITY
#define STACKCHAN_SR_WAKE_MIC_TASK_PRIORITY 2
#endif

#ifndef STACKCHAN_SR_WAKE_MIC_NOISE_FILTER_LEVEL
#define STACKCHAN_SR_WAKE_MIC_NOISE_FILTER_LEVEL 0
#endif

#ifndef STACKCHAN_SR_WAKE_PROBE_INIT_TASK_PRIORITY
#define STACKCHAN_SR_WAKE_PROBE_INIT_TASK_PRIORITY 3
#endif

#ifndef STACKCHAN_SR_WAKE_PROBE_RUN_TASK_PRIORITY
#define STACKCHAN_SR_WAKE_PROBE_RUN_TASK_PRIORITY 1
#endif

#ifndef STACKCHAN_SR_WAKE_PROBE_TASK_STACK_WORDS
#define STACKCHAN_SR_WAKE_PROBE_TASK_STACK_WORDS 12288
#endif

#ifndef STACKCHAN_SR_WAKE_PROBE_USE_M5_MIC_DEFAULTS
#define STACKCHAN_SR_WAKE_PROBE_USE_M5_MIC_DEFAULTS 0
#endif

#ifndef STACKCHAN_SR_WAKE_PROBE_COMMAND_WAKE
#define STACKCHAN_SR_WAKE_PROBE_COMMAND_WAKE 0
#endif

#ifndef STACKCHAN_SR_WAKE_PROBE_LISTEN_MS
#define STACKCHAN_SR_WAKE_PROBE_LISTEN_MS 0
#endif

#ifndef STACKCHAN_SR_WAKE_PROBE_REST_MS
#define STACKCHAN_SR_WAKE_PROBE_REST_MS 0
#endif

#ifndef STACKCHAN_SR_WAKE_AFE_LITE_FEED_TASK_CORE
#define STACKCHAN_SR_WAKE_AFE_LITE_FEED_TASK_CORE 0
#endif

#ifndef STACKCHAN_SR_WAKE_AFE_LITE_FEED_TASK_PRIORITY
#define STACKCHAN_SR_WAKE_AFE_LITE_FEED_TASK_PRIORITY 1
#endif

#ifndef STACKCHAN_SR_WAKE_AFE_LITE_FETCH_TASK_CORE
#define STACKCHAN_SR_WAKE_AFE_LITE_FETCH_TASK_CORE 0
#endif

#ifndef STACKCHAN_SR_WAKE_AFE_LITE_FETCH_TASK_PRIORITY
#define STACKCHAN_SR_WAKE_AFE_LITE_FETCH_TASK_PRIORITY 1
#endif

#ifndef STACKCHAN_SR_WAKE_AFE_LITE_AFE_TASK_CORE
#define STACKCHAN_SR_WAKE_AFE_LITE_AFE_TASK_CORE 0
#endif

#ifndef STACKCHAN_SR_WAKE_AFE_LITE_AFE_TASK_PRIORITY
#define STACKCHAN_SR_WAKE_AFE_LITE_AFE_TASK_PRIORITY 1
#endif

#ifndef STACKCHAN_SR_WAKE_AFE_LITE_STEREO
#define STACKCHAN_SR_WAKE_AFE_LITE_STEREO 0
#endif

#ifndef STACKCHAN_SR_WAKE_AFE_LITE_MONO_CHANNEL
#define STACKCHAN_SR_WAKE_AFE_LITE_MONO_CHANNEL 0
#endif

#ifndef STACKCHAN_SR_WAKE_AFE_LITE_MIC_INPUT_STEREO
#define STACKCHAN_SR_WAKE_AFE_LITE_MIC_INPUT_STEREO 0
#endif

#ifndef STACKCHAN_SR_WAKE_AFE_LITE_MIC_MAGNIFICATION
#define STACKCHAN_SR_WAKE_AFE_LITE_MIC_MAGNIFICATION STACKCHAN_SR_WAKE_DIRECT_MIC_MAGNIFICATION
#endif

#ifndef STACKCHAN_SR_WAKE_AFE_LITE_RECORD_SAMPLES
#define STACKCHAN_SR_WAKE_AFE_LITE_RECORD_SAMPLES 0
#endif

#ifndef STACKCHAN_SR_WAKE_AFE_LITE_GAIN_Q8
#define STACKCHAN_SR_WAKE_AFE_LITE_GAIN_Q8 256
#endif

#ifndef STACKCHAN_SR_WAKE_AFE_LITE_DET_MODE
#define STACKCHAN_SR_WAKE_AFE_LITE_DET_MODE DET_MODE_90
#endif

#ifndef STACKCHAN_SR_WAKE_AFE_LITE_COOLDOWN_MS
#define STACKCHAN_SR_WAKE_AFE_LITE_COOLDOWN_MS STACKCHAN_SR_WAKE_DIRECT_COOLDOWN_MS
#endif

#ifndef STACKCHAN_SR_WAKE_AFE_LITE_DISABLE_EXTRA_ALGOS
#define STACKCHAN_SR_WAKE_AFE_LITE_DISABLE_EXTRA_ALGOS 0
#endif

#ifndef STACKCHAN_SR_WAKE_AFE_LITE_HIGH_PERF
#define STACKCHAN_SR_WAKE_AFE_LITE_HIGH_PERF 0
#endif

#ifndef STACKCHAN_ENABLE_MWW_WAKE_PROBE
#define STACKCHAN_ENABLE_MWW_WAKE_PROBE 0
#endif

#ifndef STACKCHAN_ENABLE_PERIODIC_SERIAL_TELEMETRY
#define STACKCHAN_ENABLE_PERIODIC_SERIAL_TELEMETRY 1
#endif

#ifndef STACKCHAN_CAMERA_CAPTURE_PROBE_ONLY
#define STACKCHAN_CAMERA_CAPTURE_PROBE_ONLY 0
#endif

#ifndef STACKCHAN_ENABLE_CAMERA_HOST_VISION
#define STACKCHAN_ENABLE_CAMERA_HOST_VISION 0
#endif

#ifndef STACKCHAN_CAMERA_AUDIO_DIRECTION_INVERT
#define STACKCHAN_CAMERA_AUDIO_DIRECTION_INVERT 0
#endif

#ifndef STACKCHAN_ENABLE_WAKE_SERIAL_LOGS
#define STACKCHAN_ENABLE_WAKE_SERIAL_LOGS 1
#endif

#ifndef STACKCHAN_ENABLE_BRIDGE_SERIAL_LOGS
#define STACKCHAN_ENABLE_BRIDGE_SERIAL_LOGS 1
#endif

#ifndef STACKCHAN_ENABLE_MIC_ACTIVATION_CUE
#define STACKCHAN_ENABLE_MIC_ACTIVATION_CUE 1
#endif

#ifndef STACKCHAN_BRIDGE_DEBUG_PORT
#define STACKCHAN_BRIDGE_DEBUG_PORT 8789
#endif

#ifndef STACKCHAN_BRIDGE_DEBUG_REQUEST_TIMEOUT_MS
#define STACKCHAN_BRIDGE_DEBUG_REQUEST_TIMEOUT_MS 40
#endif

#ifndef STACKCHAN_CHIP_TEMP_TELEMETRY_PERIOD_MS
#define STACKCHAN_CHIP_TEMP_TELEMETRY_PERIOD_MS 2000
#endif

#ifndef STACKCHAN_POWER_TELEMETRY_PERIOD_MS
#define STACKCHAN_POWER_TELEMETRY_PERIOD_MS 500
#endif

#ifndef STACKCHAN_ENABLE_POWER_FORENSICS
#define STACKCHAN_ENABLE_POWER_FORENSICS 0
#endif

#ifndef STACKCHAN_OTA_PORT
#define STACKCHAN_OTA_PORT 8790
#endif

#ifndef STACKCHAN_OTA_TOKEN_SHA256
#define STACKCHAN_OTA_TOKEN_SHA256 ""
#endif

#ifndef STACKCHAN_OTA_MIN_VBUS_MV
#define STACKCHAN_OTA_MIN_VBUS_MV 4550
#endif

#ifndef STACKCHAN_OTA_MIN_FREE_HEAP_BYTES
#define STACKCHAN_OTA_MIN_FREE_HEAP_BYTES 65536
#endif

static_assert(STACKCHAN_OTA_MIN_FREE_HEAP_BYTES >= 24576,
              "OTA heap safety floor must retain at least 24 KiB of internal heap");

#ifndef STACKCHAN_OTA_HEALTH_MIN_VBUS_MV
#define STACKCHAN_OTA_HEALTH_MIN_VBUS_MV 4400
#endif

#ifndef STACKCHAN_OTA_HEALTH_MAX_FRAME_US
#define STACKCHAN_OTA_HEALTH_MAX_FRAME_US 120000
#endif

#ifndef STACKCHAN_BASE_USB_POWER_INPUT
#define STACKCHAN_BASE_USB_POWER_INPUT 0
#endif

#ifndef STACKCHAN_CHARGE_CURRENT_MA
#define STACKCHAN_CHARGE_CURRENT_MA 0
#endif

#ifndef STACKCHAN_LOW_INPUT_CHARGE_CURRENT_MA
#define STACKCHAN_LOW_INPUT_CHARGE_CURRENT_MA 0
#endif

#ifndef STACKCHAN_PMIC_VINDPM_MV
#define STACKCHAN_PMIC_VINDPM_MV 0
#endif

#ifndef STACKCHAN_ENABLE_PMIC_INPUT_TELEMETRY
#define STACKCHAN_ENABLE_PMIC_INPUT_TELEMETRY 1
#endif

static_assert(STACKCHAN_PMIC_VINDPM_MV == 0 ||
                  (STACKCHAN_PMIC_VINDPM_MV >= 3880 && STACKCHAN_PMIC_VINDPM_MV <= 5080),
              "AXP2101 VINDPM must be disabled or within its 3.88-5.08 V range");
static_assert(STACKCHAN_PMIC_VINDPM_MV == 0 ||
                  ((STACKCHAN_PMIC_VINDPM_MV - 3880) % 80) == 0,
              "AXP2101 VINDPM must align to an 80 mV register step");
static_assert(STACKCHAN_ENABLE_PMIC_INPUT_TELEMETRY == 0 ||
                  STACKCHAN_ENABLE_PMIC_INPUT_TELEMETRY == 1,
              "PMIC input telemetry must be disabled or enabled");

#ifndef STACKCHAN_ENABLE_BODY_POWER_MONITOR
#define STACKCHAN_ENABLE_BODY_POWER_MONITOR 0
#endif

#ifndef STACKCHAN_BODY_POWER_TELEMETRY_PERIOD_MS
#define STACKCHAN_BODY_POWER_TELEMETRY_PERIOD_MS 250
#endif

#ifndef STACKCHAN_INTENT_TASK_PRIORITY
#define STACKCHAN_INTENT_TASK_PRIORITY 3
#endif

#ifndef STACKCHAN_MOTION_TASK_PRIORITY
#define STACKCHAN_MOTION_TASK_PRIORITY 3
#endif

#ifndef STACKCHAN_MOTION_AUDIO_LOAD_SHED_COOLDOWN_MS
#define STACKCHAN_MOTION_AUDIO_LOAD_SHED_COOLDOWN_MS 0
#endif

#ifndef STACKCHAN_MOTION_THERMAL_LOAD_SHED_C
#define STACKCHAN_MOTION_THERMAL_LOAD_SHED_C 0
#endif

#ifndef STACKCHAN_MOTION_THERMAL_RESUME_C
#define STACKCHAN_MOTION_THERMAL_RESUME_C 0
#endif

#ifndef STACKCHAN_MOTION_POWER_LOAD_SHED_MV
#define STACKCHAN_MOTION_POWER_LOAD_SHED_MV 0
#endif

#ifndef STACKCHAN_MOTION_POWER_RESUME_MV
#define STACKCHAN_MOTION_POWER_RESUME_MV 0
#endif

#ifndef STACKCHAN_MOTION_POWER_MIN_SUPPRESS_MS
#define STACKCHAN_MOTION_POWER_MIN_SUPPRESS_MS 0
#endif

#ifndef STACKCHAN_MOTION_POWER_HARD_FLOOR_MV
#define STACKCHAN_MOTION_POWER_HARD_FLOOR_MV STACKCHAN_MOTION_POWER_LOAD_SHED_MV
#endif

#ifndef STACKCHAN_MOTION_POWER_CHARGE_BACKED_CURRENT_MA
#define STACKCHAN_MOTION_POWER_CHARGE_BACKED_CURRENT_MA 0
#endif

#ifndef STACKCHAN_FACE_TASK_PRIORITY
#define STACKCHAN_FACE_TASK_PRIORITY 2
#endif

#ifndef STACKCHAN_MWW_WAKE_TASK_CORE
#define STACKCHAN_MWW_WAKE_TASK_CORE 0
#endif

#ifndef STACKCHAN_MWW_WAKE_TASK_PRIORITY
#define STACKCHAN_MWW_WAKE_TASK_PRIORITY 1
#endif

#ifndef STACKCHAN_MWW_WAKE_TASK_STACK_WORDS
#define STACKCHAN_MWW_WAKE_TASK_STACK_WORDS 12288
#endif

#ifndef STACKCHAN_MWW_WAKE_RECORD_SAMPLES
#define STACKCHAN_MWW_WAKE_RECORD_SAMPLES 160
#endif

#ifndef STACKCHAN_MWW_WAKE_CAPTURE_SAMPLE_RATE
#define STACKCHAN_MWW_WAKE_CAPTURE_SAMPLE_RATE 16000
#endif

#ifndef STACKCHAN_MWW_WAKE_DC_CORRECT
#define STACKCHAN_MWW_WAKE_DC_CORRECT 0
#endif

#ifndef STACKCHAN_MWW_WAKE_ES7210_GAIN_REG
#define STACKCHAN_MWW_WAKE_ES7210_GAIN_REG -1
#endif

#ifndef STACKCHAN_MWW_WAKE_HIGHPASS_Q15
#define STACKCHAN_MWW_WAKE_HIGHPASS_Q15 0
#endif

#ifndef STACKCHAN_MWW_WAKE_PROBABILITY_CUTOFF
#define STACKCHAN_MWW_WAKE_PROBABILITY_CUTOFF 217
#endif

#ifndef STACKCHAN_MWW_WAKE_PEAK_PROBABILITY_CUTOFF
#define STACKCHAN_MWW_WAKE_PEAK_PROBABILITY_CUTOFF 0
#endif

#ifndef STACKCHAN_MWW_WAKE_DIAG_INTERVAL
#define STACKCHAN_MWW_WAKE_DIAG_INTERVAL 500
#endif

#ifndef STACKCHAN_MWW_WAKE_RESET_MODEL_ON_VALIDATION
#define STACKCHAN_MWW_WAKE_RESET_MODEL_ON_VALIDATION 0
#endif

#ifndef STACKCHAN_MWW_WAKE_COOLDOWN_MS
#define STACKCHAN_MWW_WAKE_COOLDOWN_MS 1500
#endif

#ifndef STACKCHAN_MWW_WAKE_STARTUP_SUPPRESSION_MS
#define STACKCHAN_MWW_WAKE_STARTUP_SUPPRESSION_MS 4000
#endif

#ifndef STACKCHAN_MWW_WAKE_MIC_MAGNIFICATION
#define STACKCHAN_MWW_WAKE_MIC_MAGNIFICATION 2
#endif

#ifndef STACKCHAN_MWW_WAKE_MIC_INPUT_STEREO
#define STACKCHAN_MWW_WAKE_MIC_INPUT_STEREO 0
#endif

#ifndef STACKCHAN_MWW_WAKE_RECORD_STEREO
#define STACKCHAN_MWW_WAKE_RECORD_STEREO 0
#endif

#ifndef STACKCHAN_MWW_WAKE_MONO_CHANNEL
#define STACKCHAN_MWW_WAKE_MONO_CHANNEL 0
#endif

#ifndef STACKCHAN_MWW_WAKE_STEREO_MONO_CHANNEL
#define STACKCHAN_MWW_WAKE_STEREO_MONO_CHANNEL 0
#endif

#ifndef STACKCHAN_MWW_WAKE_USE_M5_MODEL
#define STACKCHAN_MWW_WAKE_USE_M5_MODEL 0
#endif

#ifndef STACKCHAN_MWW_WAKE_USE_HI_STACKCHAN_MODEL
#define STACKCHAN_MWW_WAKE_USE_HI_STACKCHAN_MODEL 0
#endif

#ifndef STACKCHAN_MWW_WAKE_DRIVES_AUDIO_UPLINK
#define STACKCHAN_MWW_WAKE_DRIVES_AUDIO_UPLINK 0
#endif

#ifndef STACKCHAN_MWW_DEDICATED_WAKE_CAPTURE
#define STACKCHAN_MWW_DEDICATED_WAKE_CAPTURE 0
#endif

#ifndef STACKCHAN_MWW_WAKE_UPLINK_CHUNK_SAMPLES
#define STACKCHAN_MWW_WAKE_UPLINK_CHUNK_SAMPLES 1600
#endif

#ifndef STACKCHAN_MWW_WAKE_UPLINK_QUEUE_DEPTH
#define STACKCHAN_MWW_WAKE_UPLINK_QUEUE_DEPTH 3
#endif

#ifndef STACKCHAN_MWW_WAKE_UPLINK_SUBMIT_RETRY_ATTEMPTS
#define STACKCHAN_MWW_WAKE_UPLINK_SUBMIT_RETRY_ATTEMPTS 40
#endif

#ifndef STACKCHAN_MWW_WAKE_UPLINK_SUBMIT_RETRY_DELAY_MS
#define STACKCHAN_MWW_WAKE_UPLINK_SUBMIT_RETRY_DELAY_MS 3
#endif

#ifndef STACKCHAN_SPEAKER_MAGNIFICATION
#define STACKCHAN_SPEAKER_MAGNIFICATION 16
#endif

#ifndef STACKCHAN_VOICE_MASTER_VOLUME
#define STACKCHAN_VOICE_MASTER_VOLUME 150
#endif

#ifndef STACKCHAN_VOICE_CHANNEL_VOLUME
#define STACKCHAN_VOICE_CHANNEL_VOLUME 255
#endif

#ifndef STACKCHAN_VOICE_DUCKED_CHANNEL_VOLUME
#define STACKCHAN_VOICE_DUCKED_CHANNEL_VOLUME 84
#endif

#ifndef STACKCHAN_ENABLE_BRIDGE_AUDIO_DOWNLINK_PLAYBACK
#define STACKCHAN_ENABLE_BRIDGE_AUDIO_DOWNLINK_PLAYBACK 0
#endif

#ifndef STACKCHAN_BRIDGE_AUDIO_DOWNLINK_BUFFER_BYTES
#define STACKCHAN_BRIDGE_AUDIO_DOWNLINK_BUFFER_BYTES 65536
#endif

#ifndef STACKCHAN_BRIDGE_AUDIO_STREAMING_PLAYBACK
#define STACKCHAN_BRIDGE_AUDIO_STREAMING_PLAYBACK 0
#endif

#ifndef STACKCHAN_BRIDGE_AUDIO_STREAMING_BUFFER_COUNT
#define STACKCHAN_BRIDGE_AUDIO_STREAMING_BUFFER_COUNT 3
#endif

#ifndef STACKCHAN_REMOTE_RECOVERY_ENABLE
#define STACKCHAN_REMOTE_RECOVERY_ENABLE STACKCHAN_ENABLE_WIFI_BRIDGE
#endif

#ifndef STACKCHAN_RECOVERY_WIFI_RESTART_MS
#define STACKCHAN_RECOVERY_WIFI_RESTART_MS 90000
#endif

#ifndef STACKCHAN_RECOVERY_BRIDGE_RESTART_MS
#define STACKCHAN_RECOVERY_BRIDGE_RESTART_MS 120000
#endif

#ifndef STACKCHAN_RECOVERY_REBOOT_MS
#define STACKCHAN_RECOVERY_REBOOT_MS 600000
#endif

#ifndef STACKCHAN_RECOVERY_RESTART_COOLDOWN_MS
#define STACKCHAN_RECOVERY_RESTART_COOLDOWN_MS 60000
#endif

#ifndef STACKCHAN_REMOTE_REBOOT_DELAY_MS
#define STACKCHAN_REMOTE_REBOOT_DELAY_MS 350
#endif

#ifndef STACKCHAN_REMOTE_RECOVERY_DELAY_MS
#define STACKCHAN_REMOTE_RECOVERY_DELAY_MS 750
#endif

#if STACKCHAN_ENABLE_SR_WAKE_DIRECT
#include "sdkconfig.h"
#if __has_include(<esp_wn_models.h>) && __has_include(<model_path.h>) && defined(CONFIG_IDF_TARGET_ESP32S3) && \
    CONFIG_IDF_TARGET_ESP32S3 && defined(CONFIG_MODEL_IN_FLASH) && CONFIG_MODEL_IN_FLASH
#include <esp_heap_caps.h>
#include <esp_wn_iface.h>
#include <esp_wn_models.h>
#include <model_path.h>
#define STACKCHAN_HAS_SR_WAKE_DIRECT 1
#else
#define STACKCHAN_HAS_SR_WAKE_DIRECT 0
#endif
#else
#define STACKCHAN_HAS_SR_WAKE_DIRECT 0
#endif

#if STACKCHAN_ENABLE_SR_WAKE_AFE_LITE
#include "sdkconfig.h"
#if __has_include(<esp_afe_config.h>) && __has_include(<esp_afe_sr_iface.h>) && \
        __has_include(<esp_afe_sr_models.h>) && __has_include(<model_path.h>) && \
    defined(CONFIG_IDF_TARGET_ESP32S3) && CONFIG_IDF_TARGET_ESP32S3 && defined(CONFIG_MODEL_IN_FLASH) && \
    CONFIG_MODEL_IN_FLASH
#include <esp_afe_config.h>
#include <esp_afe_sr_iface.h>
#include <esp_afe_sr_models.h>
#include <esp_err.h>
#include <esp_heap_caps.h>
#include <model_path.h>
#define STACKCHAN_HAS_SR_WAKE_AFE_LITE 1
#else
#define STACKCHAN_HAS_SR_WAKE_AFE_LITE 0
#endif
#else
#define STACKCHAN_HAS_SR_WAKE_AFE_LITE 0
#endif

#if STACKCHAN_ENABLE_MWW_WAKE_PROBE
#include "sdkconfig.h"
#if __has_include("wake/MicroWakeWordProbe.hpp") && __has_include("wake/HeyStackchanV1Model.hpp") && \
    __has_include(<frontend.h>) && __has_include(<tensorflow/lite/micro/micro_interpreter.h>) && \
    defined(CONFIG_IDF_TARGET_ESP32S3) && CONFIG_IDF_TARGET_ESP32S3
#include "wake/HeyStackchanV1Model.hpp"
#if __has_include("wake/HiStackchanModel.hpp")
#include "wake/HiStackchanModel.hpp"
#define STACKCHAN_HAS_MWW_HI_STACKCHAN_MODEL 1
#else
#define STACKCHAN_HAS_MWW_HI_STACKCHAN_MODEL 0
#endif
#if __has_include("wake/HeyM5V3Model.hpp")
#include "wake/HeyM5V3Model.hpp"
#define STACKCHAN_HAS_MWW_M5_MODEL 1
#else
#define STACKCHAN_HAS_MWW_M5_MODEL 0
#endif
#include "wake/MicroWakeWordProbe.hpp"
#define STACKCHAN_HAS_MWW_WAKE_PROBE 1
#else
#define STACKCHAN_HAS_MWW_HI_STACKCHAN_MODEL 0
#define STACKCHAN_HAS_MWW_M5_MODEL 0
#define STACKCHAN_HAS_MWW_WAKE_PROBE 0
#endif
#else
#define STACKCHAN_HAS_MWW_HI_STACKCHAN_MODEL 0
#define STACKCHAN_HAS_MWW_M5_MODEL 0
#define STACKCHAN_HAS_MWW_WAKE_PROBE 0
#endif

#if defined(ARDUINO_ARCH_ESP32)
#include <WiFi.h>
#include <WiFiClient.h>
#include <WiFiServer.h>
#endif

#include "config/RobotConfig.hpp"
#include "face/ProceduralFace.hpp"
#include "io/AudioCaptureAdapter.hpp"
#include "io/AudioOut.hpp"
#include "io/BridgeAudioDownlink.hpp"
#include "io/BridgeAudioUplink.hpp"
#include "io/BridgeClient.hpp"
#include "io/BridgeEndpointControl.hpp"
#include "io/BridgeEndpointRegistry.hpp"
#include "io/BridgeEndpointStore.hpp"
#include "io/BridgeNetworkSession.hpp"
#include "io/BridgeWakeGate.hpp"
#include "io/BridgeWiFiClientSocket.hpp"
#include "io/BridgeWiFiProvisioner.hpp"
#include "io/BridgeWiFiProvisioningStore.hpp"
#include "io/BodyPeripheralAdapter.hpp"
#include "io/CameraAdapter.hpp"
#include "io/CameraHostProtocol.hpp"
#include "io/DisplayAdapter.hpp"
#include "io/ImuAdapter.hpp"
#include "io/LanOtaServer.hpp"
#include "io/SensorAdapter.hpp"
#include "io/SpeechAdapter.hpp"
#include "io/StackChanServoAdapter.hpp"
#include "motion/ActuationEngine.hpp"
#include "persona/IntentEngine.hpp"
#include "persona/BodyFeedback.hpp"
#include "persona/StateMatrix.hpp"
#include "persona/StereoDirection.hpp"
#include "power/PowerCoordinator.hpp"
#include "power/PowerForensics.hpp"
#include "wake/WakeCueSequence.hpp"

#if __has_include("FirmwareVoiceAssets.hpp")
#include "FirmwareVoiceAssets.hpp"
#define STACKCHAN_HAS_FIRMWARE_VOICE_ASSETS 1
#else
#define STACKCHAN_HAS_FIRMWARE_VOICE_ASSETS 0
#endif

#ifndef STACKCHAN_ENABLE_SPEAKER
#define STACKCHAN_ENABLE_SPEAKER 0
#endif

#ifndef STACKCHAN_PAIRING_SHORT_CODE
#define STACKCHAN_PAIRING_SHORT_CODE ""
#endif

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
CameraAdapter gCamera;
ImuAdapter gImu;
BodyPeripheralAdapter gBodyPeripheral;
BodyFeedback gBodyFeedback;
AudioCaptureAdapter gAudioCapture;
M5MicAudioCaptureSource gAudioCaptureSource;
AudioOut gAudioOut;
BridgeAudioDownlink gBridgeAudioDownlink;
BridgeAudioUplink gBridgeAudioUplink;
SpeechAdapter gSpeechAdapter;
BridgeClient gBridge;
BridgeEndpointRegistry gBridgeEndpointRegistry;
BridgeEndpointControl gBridgeEndpointControl;
BridgeEndpointStore gBridgeEndpointStore;
BridgeWakeGate gBridgeWakeGate;
BridgeWiFiProvisioner gBridgeWiFi;
BridgeWiFiProvisioningStore gBridgeWiFiStore;
BridgeNetworkSession gBridgeNetworkSession;
BridgeWiFiClientSocket gBridgeSocket;
char gRuntimeWiFiSsid[kBridgeWiFiSsidMax] = {};
char gRuntimeWiFiPassword[kBridgeWiFiPasswordMax] = {};
char gRuntimeBridgeHost[kBridgeWiFiHostMax] = {};
char gRuntimeBridgePath[kBridgeWiFiPathMax] = "/bridge";
uint16_t gRuntimeBridgePort = STACKCHAN_BRIDGE_PORT;
#if defined(ARDUINO_ARCH_ESP32)
BridgeEndpointPreferencesStore gBridgeEndpointStoreBackend;
BridgeWiFiProvisioningPreferencesStore gBridgeWiFiStoreBackend;
WiFiServer gBridgeDebugServer(STACKCHAN_BRIDGE_DEBUG_PORT);
LanOtaServer gLanOtaServer(STACKCHAN_OTA_PORT);
bool gBridgeDebugServerStarted = false;
RTC_DATA_ATTR uint32_t gRtcBootCount = 0;
esp_reset_reason_t gBootResetReason = ESP_RST_UNKNOWN;
bool gChipTemperatureValid = false;
float gChipTemperatureC = 0.0f;
float gChipTemperatureMaxC = 0.0f;
uint32_t gChipTemperatureSamples = 0;
uint32_t gChipTemperatureReadFailures = 0;
uint32_t gChipTemperatureLastReadMs = 0;
bool gPowerTelemetryValid = false;
bool gPowerVbusValid = false;
int16_t gPowerVbusMv = -1;
int16_t gPowerVbusMinMv = 0;
int16_t gPowerVbusMaxMv = 0;
uint32_t gPowerVbusRejectedSamples = 0;
int16_t gPowerVbusLastRejectedMv = -1;
bool gPowerPmicVbusPresentValid = false;
bool gPowerPmicVbusPresent = false;
uint32_t gPowerPmicVbusPresentSamples = 0;
uint32_t gPowerPmicVbusAbsentSamples = 0;
uint32_t gPowerPmicVbusTransitions = 0;
uint32_t gPowerPmicVbusLossEntries = 0;
uint32_t gPowerPmicVbusLastTransitionMs = 0;
bool gPowerPmicBatteryPresentValid = false;
bool gPowerPmicBatteryPresent = false;
bool gPowerPmicTemperatureValid = false;
float gPowerPmicTemperatureC = 0.0f;
float gPowerPmicTemperatureMaxC = 0.0f;
bool gPowerPmicInputStateValid = false;
uint8_t gPowerPmicStatus1Raw = 0;
uint8_t gPowerPmicStatus2Raw = 0;
bool gPowerPmicInputCurrentLimited = false;
bool gPowerPmicVindpmActive = false;
uint8_t gPowerPmicBatteryDirection = 0;
uint8_t gPowerPmicChargeStatus = 0;
uint32_t gPowerPmicInputCurrentLimitSamples = 0;
uint32_t gPowerPmicInputCurrentLimitEntries = 0;
uint32_t gPowerPmicVindpmSamples = 0;
uint32_t gPowerPmicVindpmEntries = 0;
uint32_t gPowerPmicBatterySupplementSamples = 0;
uint32_t gPowerPmicBatterySupplementEntries = 0;
uint32_t gPowerPmicInputStateReadFailures = 0;
bool gPowerPmicConfigValid = false;
uint8_t gPowerPmicMinSystemRaw = 0;
uint8_t gPowerPmicVindpmRaw = 0;
uint8_t gPowerPmicInputCurrentLimitRaw = 0;
bool gPowerPmicVindpmConfigured = false;
uint32_t gPowerPmicConfigReadFailures = 0;
bool gPowerVsysValid = false;
int16_t gPowerVsysMv = -1;
int16_t gPowerVsysMinMv = 0;
int16_t gPowerVsysMaxMv = 0;
uint32_t gPowerVsysSamples = 0;
uint32_t gPowerVsysReadFailures = 0;
bool gPowerBatteryValid = false;
int16_t gPowerBatteryMv = -1;
int16_t gPowerBatteryMinMv = 0;
int16_t gPowerBatteryMaxMv = 0;
uint32_t gPowerBatteryRejectedSamples = 0;
int16_t gPowerBatteryLastRejectedMv = -1;
int32_t gPowerBatteryLevel = -1;
int32_t gPowerChargingState = -1;
uint32_t gPowerTelemetrySamples = 0;
uint32_t gPowerTelemetryReadFailures = 0;
uint32_t gPowerTelemetryLastReadMs = 0;
bool gBaseInputModeConfigured = false;
bool gBatteryChargeConfigured = false;
bool gExternalOutputEnabled = false;
uint16_t gAppliedChargeCurrentMa = 0;
uint32_t gChargeCurrentTransitions = 0;
uint32_t gChargeCurrentLastChangeMs = 0;
#if STACKCHAN_ENABLE_BODY_POWER_MONITOR && STACKCHAN_HAS_INA226_MONITOR
m5::INA226_Class* gBodyPowerMonitor = nullptr;
#endif
bool gBodyPowerMonitorReady = false;
bool gBodyPowerTelemetryValid = false;
float gBodyPowerBusV = 0.0f;
float gBodyPowerBusMinV = 0.0f;
float gBodyPowerBusMaxV = 0.0f;
float gBodyPowerCurrentMa = 0.0f;
float gBodyPowerCurrentMinMa = 0.0f;
float gBodyPowerCurrentMaxMa = 0.0f;
float gBodyPowerMw = 0.0f;
uint32_t gBodyPowerTelemetrySamples = 0;
uint32_t gBodyPowerTelemetryReadFailures = 0;
uint32_t gBodyPowerTelemetryLastReadMs = 0;
bool gMotionThermalSuppressed = false;
uint32_t gMotionThermalSuppressEntries = 0;
bool gMotionPowerSuppressed = false;
uint32_t gMotionPowerSuppressEntries = 0;
uint32_t gMotionPowerSuppressedAtMs = 0;
bool gMotionPowerChargeBacked = false;
uint32_t gMotionPowerChargeBackedSamples = 0;
#else
BridgeEndpointMemoryStore gBridgeEndpointStoreBackend;
BridgeWiFiProvisioningMemoryStore gBridgeWiFiStoreBackend;
#endif

struct BridgeRecoveryTelemetry {
  bool recoveryRequested = false;
  bool rebootRequested = false;
  uint32_t wifiOfflineSinceMs = 0;
  uint32_t bridgeOfflineSinceMs = 0;
  uint32_t lastRecoveryMs = 0;
  uint32_t scheduledRecoveryMs = 0;
  uint32_t scheduledRebootMs = 0;
  uint32_t wifiRestarts = 0;
  uint32_t bridgeRestarts = 0;
  uint32_t rebootRequests = 0;
  const char* lastReason = "";
};

BridgeRecoveryTelemetry gBridgeRecovery;
PowerCoordinator gPowerCoordinator;
PowerFloorTracker gPowerFloorTracker;
#if STACKCHAN_ENABLE_POWER_FORENSICS
PmicPowerForensics gPmicPowerForensics;
#endif
volatile bool gMotionRequested = STACKCHAN_MOTION_ENABLED_AT_BOOT != 0;
bool gMotionAudioPlaybackActive = false;
bool gMotionAudioPreemptActive = false;
MotionAudioPreemptionGate gMotionAudioPreemptionGate;
ActuationEngine gActuation(gConfig);
ProceduralFace gFace;
IntentEngine gIntent;
TaskHandle_t gMotionTaskHandle = nullptr;
TaskHandle_t gFaceTaskHandle = nullptr;
TaskHandle_t gIntentTaskHandle = nullptr;
TaskHandle_t gWakeSrTaskHandle = nullptr;
TaskHandle_t gWakeSrFeedTaskHandle = nullptr;

struct WakeSrProbeTelemetry {
  bool enabled = (STACKCHAN_ENABLE_SR_WAKE_PROBE != 0) || (STACKCHAN_ENABLE_SR_WAKE_DIRECT != 0) ||
                 (STACKCHAN_ENABLE_SR_WAKE_AFE_LITE != 0) || (STACKCHAN_ENABLE_MWW_WAKE_PROBE != 0);
  bool wrapperEnabled = STACKCHAN_ENABLE_SR_WAKE_PROBE != 0;
  bool directEnabled = STACKCHAN_ENABLE_SR_WAKE_DIRECT != 0;
  bool afeLiteEnabled = STACKCHAN_ENABLE_SR_WAKE_AFE_LITE != 0;
  bool mwwEnabled = STACKCHAN_ENABLE_MWW_WAKE_PROBE != 0;
  bool compiled = (STACKCHAN_HAS_SR_WAKE_PROBE != 0) || (STACKCHAN_HAS_SR_WAKE_DIRECT != 0) ||
                  (STACKCHAN_HAS_SR_WAKE_AFE_LITE != 0) || (STACKCHAN_HAS_MWW_WAKE_PROBE != 0);
  bool directCompiled = STACKCHAN_HAS_SR_WAKE_DIRECT != 0;
  bool afeLiteCompiled = STACKCHAN_HAS_SR_WAKE_AFE_LITE != 0;
  bool mwwCompiled = STACKCHAN_HAS_MWW_WAKE_PROBE != 0;
  bool taskStarted = false;
  bool micReady = false;
  bool srReady = false;
  uint32_t beginAttempts = 0;
  uint32_t beginFailures = 0;
  uint32_t recordOk = 0;
  uint32_t recordDrops = 0;
  uint32_t samplesFed = 0;
  uint32_t detectCalls = 0;
  uint32_t detectNonzero = 0;
  uint32_t detectChannelVerified = 0;
  int32_t lastDetectResult = 0;
  uint32_t chunkSamples = 0;
  uint32_t recordSamples = 0;
  uint32_t audioChannels = 1;
  uint32_t sampleRate = 0;
  uint32_t detectMode = 0;
  uint32_t micMagnification = STACKCHAN_SR_WAKE_DIRECT_MIC_MAGNIFICATION;
  uint32_t monoChannel = STACKCHAN_SR_WAKE_DIRECT_MONO_CHANNEL;
  bool micInputStereo = STACKCHAN_SR_WAKE_DIRECT_MIC_INPUT_STEREO != 0;
  int32_t micTaskCore = STACKCHAN_SR_WAKE_MIC_TASK_CORE;
  uint32_t micTaskPriority = STACKCHAN_SR_WAKE_MIC_TASK_PRIORITY;
  uint32_t micNoiseFilterLevel = STACKCHAN_SR_WAKE_MIC_NOISE_FILTER_LEVEL;
  bool stereo = STACKCHAN_SR_WAKE_DIRECT_STEREO != 0;
  uint32_t detectAvgUs = 0;
  uint32_t detectMaxUs = 0;
  uint32_t audioGainQ8 = STACKCHAN_SR_WAKE_DIRECT_GAIN_Q8;
  uint32_t audioPeak = 0;
  uint32_t audioPeakMax = 0;
  uint32_t audioPeakWindowMax = 0;
  uint32_t audioMeanAbs = 0;
  uint32_t audioMeanAbsMax = 0;
  uint32_t audioMeanAbsWindowMax = 0;
  uint32_t audioWindowStartMs = 0;
  uint32_t audioWindowMs = 0;
  uint32_t audioPeakLeft = 0;
  uint32_t audioPeakRight = 0;
  uint32_t audioMeanAbsLeft = 0;
  uint32_t audioMeanAbsRight = 0;
  uint32_t audioClips = 0;
  uint32_t stereoDirectionEstimates = 0;
  uint32_t stereoDirectionRejected = 0;
  float stereoDirectionLastAzimuthNorm = 0.0f;
  float stereoDirectionLastConfidence = 0.0f;
  float stereoDirectionLastCorrelation = 0.0f;
  int32_t stereoDirectionLastLagSamples = 0;
  uint32_t mwwFeatures = 0;
  uint32_t mwwInferences = 0;
  uint32_t mwwDetections = 0;
  uint32_t mwwInvokeErrors = 0;
  uint32_t mwwFeatureErrors = 0;
  uint32_t mwwLastProbability = 0;
  uint32_t mwwMaxProbability = 0;
  uint32_t mwwAverageProbability = 0;
  uint32_t mwwMaxAverageProbability = 0;
  uint32_t mwwProbabilityCutoff = 0;
  uint32_t mwwSlidingWindowSize = 0;
  uint32_t mwwLastDetectionProbability = 0;
  uint32_t mwwLastDetectionAverageProbability = 0;
  uint32_t mwwMaxDetectionAverageProbability = 0;
  int32_t mwwLastFeatureMin = 0;
  int32_t mwwLastFeatureMax = 0;
  int32_t mwwMinFeatureSeen = 0;
  int32_t mwwMaxFeatureSeen = 0;
  uint32_t mwwLastInferenceUs = 0;
  uint32_t mwwMaxInferenceUs = 0;
  bool mwwArenasZeroInitialized = false;
  uint32_t mwwArenaUsedBytes = 0;
  uint32_t mwwModelStride = 0;
  uint32_t wakeDetections = 0;
  uint32_t wakeEventsApplied = 0;
  uint32_t lastRecordMs = 0;
  uint32_t lastWakeMs = 0;
  bool audioPauseRequested = false;
  bool audioPaused = false;
  uint32_t audioPauseRequests = 0;
  uint32_t audioPauseEnters = 0;
  uint32_t audioResumeRequests = 0;
  uint32_t audioResumes = 0;
  uint32_t audioPauseFailures = 0;
  uint32_t audioLastPauseMs = 0;
  uint32_t audioLastResumeMs = 0;
  char modelName[64] = {};
  char wakeWord[64] = {};
  char lastError[48] = {};
};

WakeSrProbeTelemetry gWakeSrProbe;

#if STACKCHAN_HAS_SR_WAKE_PROBE
portMUX_TYPE gWakeSrMux = portMUX_INITIALIZER_UNLOCKED;
volatile uint32_t gWakeSrPendingDetections = 0;
#endif

#if STACKCHAN_HAS_SR_WAKE_DIRECT
portMUX_TYPE gWakeSrDirectMux = portMUX_INITIALIZER_UNLOCKED;
volatile uint32_t gWakeSrDirectPendingDetections = 0;
#endif

#if STACKCHAN_HAS_SR_WAKE_AFE_LITE
portMUX_TYPE gWakeSrAfeLiteMux = portMUX_INITIALIZER_UNLOCKED;
volatile uint32_t gWakeSrAfeLitePendingDetections = 0;

struct WakeSrAfeLiteRuntime {
  const esp_afe_sr_iface_t* afeHandle = nullptr;
  esp_afe_sr_data_t* afeData = nullptr;
  srmodel_list_t* models = nullptr;
  int feedChunkSamples = 0;
  int feedChannels = 0;
  int sampleRate = 16000;
};

WakeSrAfeLiteRuntime gWakeSrAfeLiteRuntime;
#endif

#if STACKCHAN_HAS_MWW_WAKE_PROBE
portMUX_TYPE gWakeMwwMux = portMUX_INITIALIZER_UNLOCKED;
volatile uint32_t gWakeMwwPendingDetections = 0;
MicroWakeWordProbe gMicroWakeWordProbe;
constexpr size_t kWakeMwwPcmRingSamples = 24000;
int16_t* gWakeMwwPcmRing = nullptr;
volatile uint32_t gWakeMwwPcmWriteIndex = 0;
volatile uint32_t gWakeMwwPcmAvailable = 0;
volatile uint32_t gWakeMwwPcmSequence = 0;
volatile uint32_t gWakeMwwSuppressUntilMs = 0;
volatile bool gWakeMwwResetRequested = false;
volatile bool gWakeMwwInteractionLatched = false;
volatile uint32_t gWakeMwwInteractionLatchedAtMs = 0;
volatile bool gWakeMwwAudioPauseRequested = false;
volatile bool gWakeMwwAudioPaused = false;
#if STACKCHAN_ENABLE_CAMERA && STACKCHAN_MWW_WAKE_RECORD_STEREO
struct WakeMwwStereoDirectionPending {
  float azimuthNorm = 0.0f;
  float confidence = 0.0f;
  uint32_t capturedAtMs = 0;
};
portMUX_TYPE gWakeMwwStereoDirectionMux = portMUX_INITIALIZER_UNLOCKED;
WakeMwwStereoDirectionPending gWakeMwwStereoDirectionPending;
volatile bool gWakeMwwStereoDirectionPendingReady = false;
#endif
#if STACKCHAN_ENABLE_BRIDGE_AUDIO_UPLINK && STACKCHAN_MWW_DEDICATED_WAKE_CAPTURE
constexpr uint32_t kWakeMwwCueCompletionTimeoutMs = 120;
constexpr uint8_t kWakeMwwDedicatedCaptureChunks = 96;
RobotEvent gWakeMwwPendingCaptureEvent {};
bool gWakeMwwPendingCaptureEventReady = false;
WakeCueSequence gWakeCueSequence;
struct WakeMwwDedicatedCaptureRuntime {
  bool active = false;
  uint32_t seq = 0;
  uint16_t chunksAttempted = 0;
  uint16_t chunksSubmitted = 0;
  uint32_t serviceCalls = 0;
  uint32_t maxServiceUs = 0;
};
WakeMwwDedicatedCaptureRuntime gWakeMwwDedicatedCapture;
#endif
#if STACKCHAN_ENABLE_BRIDGE_AUDIO_UPLINK && STACKCHAN_MWW_WAKE_DRIVES_AUDIO_UPLINK
struct WakeMwwUplinkChunk {
  uint32_t capturedAtMs = 0;
  uint16_t sampleCount = 0;
  int16_t samples[STACKCHAN_MWW_WAKE_UPLINK_CHUNK_SAMPLES] {};
};

WakeMwwUplinkChunk gWakeMwwUplinkPending;
volatile bool gWakeMwwUplinkPendingReady = false;
volatile uint32_t gWakeMwwUplinkQueued = 0;
volatile uint32_t gWakeMwwUplinkDropped = 0;
volatile uint32_t gWakeMwwUplinkSubmitted = 0;
volatile uint32_t gWakeMwwUplinkSubmitFailed = 0;
volatile uint32_t gWakeMwwUplinkReset = 0;
#endif
bool ensureWakeMwwUplinkQueue();
void resetWakeMwwUplinkQueue();
void queueWakeMwwUplinkAudio(const int16_t* samples, size_t sampleCount, uint32_t capturedAtMs);
void drainWakeMwwUplinkQueue(uint32_t nowMs);
#endif
bool requestWakeMwwAudioPause(uint32_t nowMs, uint32_t timeoutMs);
void releaseWakeMwwAudioPause(uint32_t nowMs);

bool gWakeSrStartAttempted = false;
bool gWakeSrStartOk = true;

bool requestWakeMwwAudioPause(uint32_t nowMs, uint32_t timeoutMs) {
#if STACKCHAN_HAS_MWW_WAKE_PROBE
  if (!gWakeSrProbe.mwwEnabled) {
    return true;
  }
  if (!gWakeMwwAudioPauseRequested) {
    gWakeSrProbe.audioPauseRequests++;
  }
  gWakeMwwAudioPauseRequested = true;
  gWakeSrProbe.audioPauseRequested = true;
  if (!gWakeSrProbe.taskStarted || gWakeMwwAudioPaused) {
    return true;
  }

  const uint32_t startMs = nowMs != 0 ? nowMs : millis();
  while (!gWakeMwwAudioPaused) {
    const uint32_t currentMs = millis();
    if (timeoutMs == 0 || currentMs - startMs >= timeoutMs) {
      gWakeMwwAudioPauseRequested = false;
      gWakeSrProbe.audioPauseRequested = false;
      gWakeSrProbe.audioPauseFailures++;
      return false;
    }
    vTaskDelay(pdMS_TO_TICKS(5));
  }
  return true;
#else
  (void)nowMs;
  (void)timeoutMs;
  return true;
#endif
}

void releaseWakeMwwAudioPause(uint32_t nowMs) {
#if STACKCHAN_HAS_MWW_WAKE_PROBE
  (void)nowMs;
  if (!gWakeSrProbe.mwwEnabled) {
    return;
  }
  if (gWakeMwwAudioPauseRequested || gWakeMwwAudioPaused) {
    gWakeSrProbe.audioResumeRequests++;
  }
  gWakeMwwAudioPauseRequested = false;
  gWakeSrProbe.audioPauseRequested = false;
#else
  (void)nowMs;
#endif
}

void applyWakeEventFromLocalSource(
    const RobotEvent& event,
    CharacterMode mode,
    const __FlashStringHelper* source,
    uint32_t count,
    uint32_t nowMs);

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

class M5SpeakerAudioSink : public AudioOutSpeakerSink, public BridgeAudioDownlinkSink {
 public:
  bool begin() override {
    if (!startSpeakerHardware()) {
      ready_ = false;
      return false;
    }
    M5.Speaker.setVolume(kVoiceMasterVolume);
    M5.Speaker.setChannelVolume(kChannel, kVoiceChannelVolume);
    renderMicCue(false);
    ready_ = true;
    powerDownSpeakerHardware();
    return true;
  }

  bool start(const AudioOutPlaybackRequest& request, uint32_t promptStartMs, uint32_t durationMs) override {
    (void)promptStartMs;
    (void)durationMs;
    if (!ready_) {
      return false;
    }
    const uint32_t nowMs = millis();
    if (!prepareSpeakerPlayback(nowMs)) {
      return false;
    }
    M5.Speaker.setVolume(kVoiceMasterVolume);
    M5.Speaker.setChannelVolume(kChannel, kVoiceChannelVolume);
    M5.Speaker.stop(kChannel);
    active_ = true;
    phase_ = 0;
    phaseFifth_ = 0;
    noise_ = 0x1234abcd;
#if STACKCHAN_HAS_FIRMWARE_VOICE_ASSETS
    const firmware_voice::FirmwareVoiceAsset* asset = firmware_voice::find(request.wavPath);
    if (asset != nullptr) {
      wavActive_ = M5.Speaker.playWav(asset->data, asset->size, 1, kChannel, true);
      M5.Speaker.setChannelVolume(kChannel, kVoiceChannelVolume);
    } else {
      wavActive_ = false;
    }
#else
    wavActive_ = false;
#endif
    return true;
  }

  bool writeFrame(const AudioOutHardwareFrame& frame) override {
    if (!ready_ || !active_) {
      return false;
    }
    if (frame.clear || !frame.active) {
      stop();
      return true;
    }

    if (wavActive_) {
      M5.Speaker.setChannelVolume(
          kChannel,
          frame.ducked ? kVoiceDuckedChannelVolume : kVoiceChannelVolume);
      return true;
    }

    renderFrame(frame);
    const bool ok = M5.Speaker.playRaw(samples_, kSamplesPerFrame, kSampleRate, false, 1, kChannel, false);
    if (!ok) {
      stop();
    }
    return ok;
  }

  bool start(const BridgeAudioStream& stream, uint32_t nowMs) override {
    if (!ready_) {
      return false;
    }
#if !STACKCHAN_BRIDGE_AUDIO_STREAMING_PLAYBACK
    const uint32_t requestedBytes =
        stream.audioBytes > 0 ? stream.audioBytes : STACKCHAN_BRIDGE_AUDIO_DOWNLINK_BUFFER_BYTES;
    if (requestedBytes > STACKCHAN_BRIDGE_AUDIO_DOWNLINK_BUFFER_BYTES ||
        !ensureDownlinkBuffer(requestedBytes)) {
      return false;
    }
#endif
    if (!prepareSpeakerPlayback(nowMs)) {
      return false;
    }
    M5.Speaker.setVolume(kVoiceMasterVolume);
    M5.Speaker.setChannelVolume(kChannel, kVoiceChannelVolume);
    M5.Speaker.stop(kChannel);
    active_ = false;
    wavActive_ = false;
    downlinkActive_ = true;
    downlinkSampleRate_ = stream.sampleRate >= 8000 && stream.sampleRate <= 48000 ? stream.sampleRate : kSampleRate;
    downlinkBufferedBytes_ = 0;
    downlinkBufferedChunks_ = 0;
    downlinkExpectedBytes_ = stream.audioBytes;
    downlinkExpectedChunks_ = stream.chunks;
    downlinkStartedAtMs_ = nowMs;
    downlinkLastActivityAtMs_ = nowMs;
    streamWatchdogStopPending_ = false;
    downlinkFirstChunkQueuedAtMs_ = 0;
    downlinkQueuedAudioMs_ = 0;
    downlinkNextStreamingBuffer_ = 0;
    M5.Speaker.setChannelVolume(kChannel, kVoiceChannelVolume);
    return true;
  }

  bool writeChunk(const BridgeAudioStreamChunk& chunk, uint32_t nowMs) override {
    if (!ready_ || !downlinkActive_ || chunk.payload == nullptr || chunk.payloadBytes < 2) {
      return false;
    }
    downlinkLastActivityAtMs_ = nowMs;

#if STACKCHAN_BRIDGE_AUDIO_STREAMING_PLAYBACK
    if ((chunk.payloadBytes & 1u) != 0 || chunk.payloadBytes > kBridgeAudioStreamChunkPayloadMax ||
        downlinkSampleRate_ == 0) {
      return false;
    }

    const uint32_t copyBytes = chunk.payloadBytes;
    const size_t sampleCount = static_cast<size_t>(copyBytes / 2u);
    int16_t* buffer = downlinkStreamingBuffers_[downlinkNextStreamingBuffer_];
    memcpy(buffer, chunk.payload, copyBytes);

    const uint32_t queueStartedUs = micros();
    const bool ok = M5.Speaker.playRaw(
        buffer,
        sampleCount,
        downlinkSampleRate_,
        false,
        1,
        kChannel,
        false);
    const uint32_t queueWaitUs = micros() - queueStartedUs;
    if (queueWaitUs > streamQueueWaitMaxUs_) {
      streamQueueWaitMaxUs_ = queueWaitUs;
    }
    if (!ok) {
      streamPlayRawFailed_++;
      return false;
    }

    const uint32_t queuedAtMs = millis();
    if (downlinkBufferedChunks_ == 0) {
      downlinkFirstChunkQueuedAtMs_ = queuedAtMs;
      streamLastFirstChunkDelayMs_ = queuedAtMs - downlinkStartedAtMs_;
    }
    const uint32_t durationMs = static_cast<uint32_t>(
        (static_cast<uint64_t>(sampleCount) * 1000ull + downlinkSampleRate_ - 1u) /
        downlinkSampleRate_);
    if (UINT32_MAX - downlinkQueuedAudioMs_ < durationMs) {
      downlinkQueuedAudioMs_ = UINT32_MAX;
    } else {
      downlinkQueuedAudioMs_ += durationMs;
    }
    downlinkNextStreamingBuffer_ =
        (downlinkNextStreamingBuffer_ + 1u) % STACKCHAN_BRIDGE_AUDIO_STREAMING_BUFFER_COUNT;
    downlinkBufferedBytes_ += copyBytes;
    downlinkBufferedChunks_++;
    streamTaskChunks_++;
    streamTaskBytes_ += copyBytes;
    streamPlayRawOk_++;
    streamLastSampleCount_ = static_cast<uint32_t>(sampleCount);
    streamLastSampleRate_ = downlinkSampleRate_;
    return true;
#else
    (void)nowMs;
    if (downlinkBuffer_ == nullptr || downlinkBufferedBytes_ > downlinkBufferCapacity_ ||
        chunk.payloadBytes > downlinkBufferCapacity_ - downlinkBufferedBytes_) {
      return false;
    }

    const uint32_t copyBytes = min(chunk.payloadBytes, static_cast<uint32_t>(kBridgeAudioStreamChunkPayloadMax));
    memcpy(downlinkBuffer_ + downlinkBufferedBytes_, chunk.payload, copyBytes);
    downlinkBufferedBytes_ += copyBytes;
    downlinkBufferedChunks_++;
    streamTaskChunks_++;
    streamTaskBytes_ += copyBytes;
    return true;
#endif
  }

  void stop() override {
    if (!ready_) {
      return;
    }
    M5.Speaker.stop(kChannel);
    active_ = false;
    wavActive_ = false;
    downlinkActive_ = false;
    downlinkLastActivityAtMs_ = 0;
    streamWatchdogStopPending_ = false;
    releaseAudioHardware(millis());
  }

  bool finish(uint32_t nowMs) override {
    if (!ready_) {
      return false;
    }
    if (!downlinkActive_) {
      return true;
    }
#if STACKCHAN_BRIDGE_AUDIO_STREAMING_PLAYBACK
    const bool ok = finishStreamingDownlink(nowMs);
#else
    const bool ok = playBufferedDownlink(nowMs);
#endif
    downlinkActive_ = false;
    downlinkLastActivityAtMs_ = 0;
    streamWatchdogStopPending_ = false;
    downlinkBufferedBytes_ = 0;
    downlinkBufferedChunks_ = 0;
    return ok;
  }

  void stop(uint32_t nowMs) override {
    if (!ready_) {
      return;
    }
    M5.Speaker.stop(kChannel);
    downlinkActive_ = false;
    downlinkLastActivityAtMs_ = 0;
    streamWatchdogStopPending_ = false;
    releaseAudioHardware(nowMs);
  }

  void service(uint32_t nowMs) {
    if (micCueRestoreAtMs_ != 0 && static_cast<int32_t>(nowMs - micCueRestoreAtMs_) >= 0) {
      M5.Speaker.setVolume(kVoiceMasterVolume);
      M5.Speaker.setChannelVolume(kChannel, kVoiceChannelVolume);
      micCueRestoreAtMs_ = 0;
    }
    if (audioPauseHeld_ && audioPauseReleaseAtMs_ != 0 &&
        static_cast<int32_t>(nowMs - audioPauseReleaseAtMs_) >= 0) {
      if (M5.Speaker.isPlaying(kChannel) != 0) {
#if STACKCHAN_BRIDGE_AUDIO_STREAMING_PLAYBACK
        if (audioPauseForceReleaseAtMs_ == 0 ||
            static_cast<int32_t>(nowMs - audioPauseForceReleaseAtMs_) < 0) {
          streamReleaseDeferrals_++;
          audioPauseReleaseAtMs_ = nowMs + kStreamingDrainPollMs;
          return;
        }
        streamForcedStops_++;
#endif
        M5.Speaker.stop(kChannel);
      }
      releaseAudioHardware(nowMs);
    }
    if (downlinkActive_ && downlinkLastActivityAtMs_ != 0 && !streamWatchdogStopPending_ &&
        nowMs - downlinkLastActivityAtMs_ >= kStreamingInactivityTimeoutMs) {
      streamWatchdogStopPending_ = true;
      streamOrphanStops_++;
    }
  }

  bool takeStreamWatchdogStop() {
    const bool pending = streamWatchdogStopPending_;
    streamWatchdogStopPending_ = false;
    return pending;
  }

  bool isReady() const override {
    return ready_;
  }

  bool playDiagnosticTone(uint32_t frequency = 880, uint32_t durationMs = 700) {
    if (!ready_) {
      diagnosticToneFailed_++;
      return false;
    }
    const uint32_t nowMs = millis();
    if (!prepareSpeakerPlayback(nowMs)) {
      diagnosticToneFailed_++;
      return false;
    }
    M5.Speaker.stop(kChannel);
    M5.Speaker.setVolume(kVoiceMasterVolume);
    M5.Speaker.setChannelVolume(kChannel, kVoiceChannelVolume);
    const bool ok = M5.Speaker.tone(static_cast<float>(frequency), durationMs, kChannel, true);
    if (ok) {
      diagnosticToneOk_++;
      scheduleAudioHardwareRelease(millis(), durationMs + kMicPauseReleaseSlackMs);
    } else {
      diagnosticToneFailed_++;
      releaseAudioHardware(nowMs);
    }
    return ok;
  }

  bool playMicActivationTone() {
    return playMicActivationPcmCue(false, false);
  }

  bool playMicActivationToneForCapture() {
    return playMicActivationPcmCue(false, true);
  }

  bool playMicActivationTap() {
    return playMicActivationPcmCue(true, false);
  }

  bool playLegacyMicActivationTone() {
    if (!ready_) {
      diagnosticToneFailed_++;
      return false;
    }
    const uint32_t nowMs = millis();
    if (!prepareSpeakerPlayback(nowMs)) {
      diagnosticToneFailed_++;
      return false;
    }
    M5.Speaker.stop(kChannel);
    M5.Speaker.setVolume(kLegacyMicCueMasterVolume);
    M5.Speaker.setChannelVolume(kChannel, kLegacyMicCueChannelVolume);
    const bool ok = M5.Speaker.tone(kLegacyMicCueFrequencyHz, kLegacyMicCueDurationMs, kChannel, true);
    if (ok) {
      diagnosticToneOk_++;
      micCueRestoreAtMs_ = millis() + kLegacyMicCueDurationMs + kMicCueRestoreDelayMs;
      scheduleAudioHardwareRelease(millis(), kLegacyMicCueDurationMs + kMicPauseReleaseSlackMs);
    } else {
      diagnosticToneFailed_++;
      releaseAudioHardware(nowMs);
    }
    return ok;
  }

  bool playMicActivationPcmCue(bool tap, bool retainWakeMicPause) {
    if (!ready_) {
      diagnosticToneFailed_++;
      return false;
    }
    renderMicCue(tap);
    if (micCueSamplesWritten_ == 0) {
      diagnosticToneFailed_++;
      return false;
    }
    const uint32_t nowMs = millis();
    if (!prepareSpeakerPlayback(nowMs, retainWakeMicPause)) {
      diagnosticToneFailed_++;
      return false;
    }
    const uint8_t masterVolume = tap ? kTapMicCueMasterVolume : kSoftMicCueMasterVolume;
    const uint8_t channelVolume = tap ? kTapMicCueChannelVolume : kSoftMicCueChannelVolume;
    M5.Speaker.stop(kChannel);
    M5.Speaker.setVolume(masterVolume);
    M5.Speaker.setChannelVolume(kChannel, channelVolume);
    const bool ok = M5.Speaker.playRaw(
        micCueSamples_, micCueSamplesWritten_, kMicCueSampleRate, false, 1, kChannel, true);
    if (ok) {
      diagnosticToneOk_++;
      micCueRestoreAtMs_ = millis() + micCueDurationMs_ + kMicCueRestoreDelayMs;
      if (!retainWakeMicPause) {
        scheduleAudioHardwareRelease(millis(), micCueDurationMs_ + kMicPauseReleaseSlackMs);
      }
    } else {
      diagnosticToneFailed_++;
      releaseAudioHardware(nowMs, !retainWakeMicPause);
    }
    return ok;
  }

  uint32_t micActivationCueDurationMs() const {
    return micCueDurationMs_;
  }

  void handoffMicActivationCueToCapture(uint32_t nowMs) {
    if (M5.Speaker.isPlaying(kChannel) != 0) {
      M5.Speaker.stop(kChannel);
    }
    powerDownSpeakerHardware();
    micCueRestoreAtMs_ = 0;
    if (audioPauseHeld_) {
      audioPauseHeld_ = false;
    }
    audioPauseReleaseAtMs_ = 0;
    audioPauseForceReleaseAtMs_ = 0;
    (void)nowMs;
  }

  uint32_t streamTaskChunks() const {
    return streamTaskChunks_;
  }

  uint32_t streamTaskBytes() const {
    return streamTaskBytes_;
  }

  uint32_t streamPlayRawOk() const {
    return streamPlayRawOk_;
  }

  uint32_t streamPlayRawFailed() const {
    return streamPlayRawFailed_;
  }

  uint32_t streamLastSampleCount() const {
    return streamLastSampleCount_;
  }

  uint32_t streamLastSampleRate() const {
    return streamLastSampleRate_;
  }

  uint32_t streamPlaybackChunked() const {
    return STACKCHAN_BRIDGE_AUDIO_STREAMING_PLAYBACK ? 1u : 0u;
  }

  uint32_t streamLastFirstChunkDelayMs() const {
    return streamLastFirstChunkDelayMs_;
  }

  uint32_t streamLastQueuedAudioMs() const {
    return streamLastQueuedAudioMs_;
  }

  uint32_t streamQueueWaitMaxUs() const {
    return streamQueueWaitMaxUs_;
  }

  uint32_t streamReleaseDeferrals() const {
    return streamReleaseDeferrals_;
  }

  uint32_t streamForcedStops() const {
    return streamForcedStops_;
  }

  uint32_t streamOrphanStops() const {
    return streamOrphanStops_;
  }

  uint8_t speakerVolume() const {
    return ready_ ? M5.Speaker.getVolume() : 0;
  }

  uint32_t speakerEnabled() const {
    return M5.Speaker.isEnabled() ? 1u : 0u;
  }

  uint32_t speakerRunning() const {
    return M5.Speaker.isRunning() ? 1u : 0u;
  }

  uint32_t speakerPowerActive() const {
    return speakerPowerActive_ ? 1u : 0u;
  }

  uint32_t speakerPowerUpEntries() const {
    return speakerPowerUpEntries_;
  }

  uint32_t speakerPowerDownEntries() const {
    return speakerPowerDownEntries_;
  }

  uint32_t speakerChannelState() const {
    return ready_ ? static_cast<uint32_t>(M5.Speaker.isPlaying(kChannel)) : 0u;
  }

  int speakerPinDataOut() const {
    return M5.Speaker.config().pin_data_out;
  }

  int speakerPinBck() const {
    return M5.Speaker.config().pin_bck;
  }

  int speakerPinWs() const {
    return M5.Speaker.config().pin_ws;
  }

  uint32_t speakerMagnification() const {
    return M5.Speaker.config().magnification;
  }

  uint32_t speakerSampleRate() const {
    return M5.Speaker.config().sample_rate;
  }

  uint32_t diagnosticToneOk() const {
    return diagnosticToneOk_;
  }

  uint32_t diagnosticToneFailed() const {
    return diagnosticToneFailed_;
  }

 private:
  static constexpr int kChannel = 0;
  static constexpr uint32_t kSampleRate = 22050;
  static constexpr size_t kSamplesPerFrame = 441;
  static constexpr uint8_t kVoiceMasterVolume = STACKCHAN_VOICE_MASTER_VOLUME;
  static constexpr uint8_t kVoiceChannelVolume = STACKCHAN_VOICE_CHANNEL_VOLUME;
  static constexpr uint8_t kVoiceDuckedChannelVolume = STACKCHAN_VOICE_DUCKED_CHANNEL_VOLUME;
  static constexpr uint8_t kSoftMicCueMasterVolume = 96;
  static constexpr uint8_t kSoftMicCueChannelVolume = 190;
  static constexpr uint8_t kTapMicCueMasterVolume = 82;
  static constexpr uint8_t kTapMicCueChannelVolume = 165;
  static constexpr uint8_t kLegacyMicCueMasterVolume = 70;
  static constexpr uint8_t kLegacyMicCueChannelVolume = 120;
  static constexpr float kLegacyMicCueFrequencyHz = 330.0f;
  static constexpr uint32_t kLegacyMicCueDurationMs = 90;
  static constexpr uint32_t kMicCueSampleRate = 48000;
  static constexpr uint32_t kMicCueMaxDurationMs = 180;
  static constexpr size_t kMicCueMaxSamples = (kMicCueSampleRate * kMicCueMaxDurationMs) / 1000u;
  static constexpr float kTwoPi = 6.28318530718f;
  static constexpr uint32_t kMicCueRestoreDelayMs = 60;
  static constexpr uint32_t kMicPauseAcquireTimeoutMs = 350;
  static constexpr uint32_t kMicPauseReleaseSlackMs = 80;
  static constexpr uint32_t kSpeakerReclaimSettleMs = 12;
  static constexpr uint32_t kDownlinkReleaseSlackMs = 180;
  static constexpr uint32_t kStreamingDrainPollMs = 25;
  static constexpr uint32_t kStreamingForceReleaseSlackMs = 5000;
  static constexpr uint32_t kStreamingInactivityTimeoutMs = 30000;
  static constexpr size_t kStreamingSamplesPerBuffer = kBridgeAudioStreamChunkPayloadMax / 2u;
  static constexpr uint8_t kCoreS3Aw9523Address = 0x58;
  static constexpr uint32_t kCoreS3AudioI2cFrequency = 400000;

  static_assert(STACKCHAN_BRIDGE_AUDIO_STREAMING_BUFFER_COUNT >= 3,
                "Streaming speaker playback requires at least three stable PCM buffers");

  static uint32_t frequencyForViseme(AudioOutViseme viseme) {
    switch (viseme) {
      case AudioOutViseme::Ah:
        return 190;
      case AudioOutViseme::Oh:
        return 145;
      case AudioOutViseme::Ee:
        return 260;
      case AudioOutViseme::Neutral:
        return 115;
    }
    return 160;
  }

  bool startSpeakerHardware() {
    resetCoreS3SpeakerAmp();
    auto speakerConfig = M5.Speaker.config();
    speakerConfig.magnification = STACKCHAN_SPEAKER_MAGNIFICATION;
    M5.Speaker.config(speakerConfig);
    const bool ok = M5.Speaker.begin();
    speakerPowerActive_ = ok;
    if (ok) {
      ++speakerPowerUpEntries_;
    }
    return ok;
  }

  void powerDownSpeakerHardware() {
    if (!speakerPowerActive_ && !M5.Speaker.isEnabled()) {
      return;
    }
    M5.Speaker.stop(kChannel);
    M5.Speaker.end();
    speakerPowerActive_ = false;
    ++speakerPowerDownEntries_;
  }

  bool resetCoreS3SpeakerAmp() {
    bool ok = true;
    ok &= M5.In_I2C.writeRegister8(kCoreS3Aw9523Address, 0x02, 0b00000111, kCoreS3AudioI2cFrequency);
    ok &= M5.In_I2C.writeRegister8(kCoreS3Aw9523Address, 0x03, 0b10001111, kCoreS3AudioI2cFrequency);
    ok &= M5.In_I2C.writeRegister8(kCoreS3Aw9523Address, 0x04, 0b00011000, kCoreS3AudioI2cFrequency);
    ok &= M5.In_I2C.writeRegister8(kCoreS3Aw9523Address, 0x05, 0b00001100, kCoreS3AudioI2cFrequency);
    ok &= M5.In_I2C.writeRegister8(kCoreS3Aw9523Address, 0x11, 0b00010000, kCoreS3AudioI2cFrequency);
    ok &= M5.In_I2C.writeRegister8(kCoreS3Aw9523Address, 0x12, 0b11111111, kCoreS3AudioI2cFrequency);
    ok &= M5.In_I2C.writeRegister8(kCoreS3Aw9523Address, 0x13, 0b11111111, kCoreS3AudioI2cFrequency);
    ok &= M5.In_I2C.writeRegister8(kCoreS3Aw9523Address, 0x02, 0b00000011, kCoreS3AudioI2cFrequency);
    vTaskDelay(pdMS_TO_TICKS(10));
    ok &= M5.In_I2C.writeRegister8(kCoreS3Aw9523Address, 0x02, 0b00000111, kCoreS3AudioI2cFrequency);
    vTaskDelay(pdMS_TO_TICKS(50));
    speakerAmpResetAttempts_++;
    if (ok) {
      speakerAmpResetOk_++;
    } else {
      speakerAmpResetFailed_++;
    }
    return ok;
  }

  bool reclaimSpeakerHardware() {
    if (speakerPowerActive_ || M5.Speaker.isEnabled()) {
      powerDownSpeakerHardware();
      vTaskDelay(pdMS_TO_TICKS(kSpeakerReclaimSettleMs));
    }
    if (!startSpeakerHardware()) {
      ready_ = false;
      return false;
    }
    vTaskDelay(pdMS_TO_TICKS(kSpeakerReclaimSettleMs));
    return true;
  }

  static uint8_t* allocateDownlinkBuffer(size_t bytes) {
#if defined(ARDUINO_ARCH_ESP32)
    uint8_t* buffer = static_cast<uint8_t*>(
        heap_caps_malloc(bytes, MALLOC_CAP_SPIRAM | MALLOC_CAP_8BIT));
    if (buffer == nullptr) {
      buffer = static_cast<uint8_t*>(heap_caps_malloc(bytes, MALLOC_CAP_8BIT));
    }
    return buffer;
#else
    return static_cast<uint8_t*>(malloc(bytes));
#endif
  }

  static void freeDownlinkBuffer(uint8_t* buffer) {
    if (buffer == nullptr) {
      return;
    }
#if defined(ARDUINO_ARCH_ESP32)
    heap_caps_free(buffer);
#else
    free(buffer);
#endif
  }

  bool ensureDownlinkBuffer(uint32_t bytes) {
    if (bytes == 0 || bytes > STACKCHAN_BRIDGE_AUDIO_DOWNLINK_BUFFER_BYTES) {
      return false;
    }
    if (downlinkBuffer_ != nullptr && downlinkBufferCapacity_ >= bytes) {
      return true;
    }
    freeDownlinkBuffer(downlinkBuffer_);
    downlinkBuffer_ = allocateDownlinkBuffer(bytes);
    downlinkBufferCapacity_ = downlinkBuffer_ != nullptr ? bytes : 0;
    return downlinkBuffer_ != nullptr;
  }

  bool finishStreamingDownlink(uint32_t nowMs) {
    if (downlinkBufferedChunks_ == 0 || downlinkQueuedAudioMs_ == 0) {
      releaseAudioHardware(nowMs);
      return false;
    }

    streamLastQueuedAudioMs_ = downlinkQueuedAudioMs_;
    const uint32_t elapsedMs = nowMs - downlinkFirstChunkQueuedAtMs_;
    const uint32_t remainingMs =
        elapsedMs < downlinkQueuedAudioMs_ ? downlinkQueuedAudioMs_ - elapsedMs : 0;
    scheduleAudioHardwareRelease(nowMs, remainingMs + kDownlinkReleaseSlackMs);
    return true;
  }

  bool playBufferedDownlink(uint32_t nowMs) {
    if (downlinkBuffer_ == nullptr || downlinkBufferedBytes_ < 2) {
      releaseAudioHardware(nowMs);
      return false;
    }
    const uint32_t playableBytes = downlinkBufferedBytes_ & ~1u;
    const size_t sampleCount = static_cast<size_t>(playableBytes / 2u);
    if (sampleCount == 0 || downlinkSampleRate_ == 0) {
      releaseAudioHardware(nowMs);
      return false;
    }

    M5.Speaker.stop(kChannel);
    M5.Speaker.setVolume(kVoiceMasterVolume);
    M5.Speaker.setChannelVolume(kChannel, kVoiceChannelVolume);
    streamLastSampleCount_ = static_cast<uint32_t>(sampleCount);
    streamLastSampleRate_ = downlinkSampleRate_;
    const bool ok = M5.Speaker.playRaw(
        reinterpret_cast<const int16_t*>(downlinkBuffer_),
        sampleCount,
        downlinkSampleRate_,
        false,
        1,
        kChannel,
        true);
    if (ok) {
      streamPlayRawOk_++;
      const uint32_t durationMs =
          static_cast<uint32_t>((static_cast<uint64_t>(sampleCount) * 1000ull) / downlinkSampleRate_);
      scheduleAudioHardwareRelease(nowMs, durationMs + kDownlinkReleaseSlackMs);
      return true;
    }

    streamPlayRawFailed_++;
    releaseAudioHardware(nowMs);
    return false;
  }

  static float micCueEnvelope(uint32_t index, uint32_t total, uint32_t fadeSamples) {
    if (total == 0 || fadeSamples == 0) {
      return 1.0f;
    }
    const uint32_t remaining = total - index;
    const uint32_t edge = index < remaining ? index : remaining;
    if (edge >= fadeSamples) {
      return 1.0f;
    }
    return static_cast<float>(edge) / static_cast<float>(fadeSamples);
  }

  bool acquireAudioHardware(uint32_t nowMs) {
    if (audioPauseHeld_) {
      audioPauseReleaseAtMs_ = 0;
      audioPauseForceReleaseAtMs_ = 0;
      return true;
    }
    if (!requestWakeMwwAudioPause(nowMs, kMicPauseAcquireTimeoutMs)) {
      return false;
    }
    audioPauseHeld_ = true;
    audioPauseReleaseAtMs_ = 0;
    audioPauseForceReleaseAtMs_ = 0;
    return true;
  }

  bool prepareSpeakerPlayback(uint32_t nowMs, bool retainWakeMicPauseOnFailure = false) {
    if (!acquireAudioHardware(nowMs)) {
      return false;
    }
    if (!reclaimSpeakerHardware()) {
      releaseAudioHardware(nowMs, !retainWakeMicPauseOnFailure);
      return false;
    }
    return true;
  }

  void scheduleAudioHardwareRelease(uint32_t nowMs, uint32_t holdMs) {
    if (!audioPauseHeld_) {
      return;
    }
    audioPauseReleaseAtMs_ = nowMs + holdMs;
    audioPauseForceReleaseAtMs_ = audioPauseReleaseAtMs_ + kStreamingForceReleaseSlackMs;
  }

  void releaseAudioHardware(uint32_t nowMs, bool resumeWakeMic = true) {
    powerDownSpeakerHardware();
    if (!audioPauseHeld_) {
      return;
    }
    if (resumeWakeMic) {
      releaseWakeMwwAudioPause(nowMs);
    }
    audioPauseHeld_ = false;
    audioPauseReleaseAtMs_ = 0;
    audioPauseForceReleaseAtMs_ = 0;
  }

  size_t appendMicCueTone(size_t offset,
                          float frequencyHz,
                          uint32_t durationMs,
                          uint32_t gapMs,
                          float amplitude,
                          uint32_t fadeMs) {
    const uint32_t toneSamples = (kMicCueSampleRate * durationMs) / 1000u;
    const uint32_t fadeSamples = (kMicCueSampleRate * fadeMs) / 1000u;
    const float phaseStep = kTwoPi * frequencyHz / static_cast<float>(kMicCueSampleRate);
    for (uint32_t i = 0; i < toneSamples && offset < kMicCueMaxSamples; ++i) {
      const float envelope = micCueEnvelope(i, toneSamples, fadeSamples);
      const float sample = sinf(phaseStep * static_cast<float>(i)) * envelope * amplitude;
      micCueSamples_[offset++] = static_cast<int16_t>(sample);
    }
    const uint32_t gapSamples = (kMicCueSampleRate * gapMs) / 1000u;
    for (uint32_t i = 0; i < gapSamples && offset < kMicCueMaxSamples; ++i) {
      micCueSamples_[offset++] = 0;
    }
    return offset;
  }

  void renderMicCue(bool tap) {
    size_t offset = 0;
    memset(micCueSamples_, 0, sizeof(micCueSamples_));
    if (tap) {
      offset = appendMicCueTone(offset, 820.0f, 56, 0, 7000.0f, 10);
    } else {
      offset = appendMicCueTone(offset, 620.0f, 82, 12, 9000.0f, 14);
      offset = appendMicCueTone(offset, 930.0f, 72, 0, 7600.0f, 12);
    }
    micCueSamplesWritten_ = offset;
    micCueDurationMs_ = static_cast<uint32_t>((offset * 1000u) / kMicCueSampleRate);
  }

  void renderFrame(const AudioOutHardwareFrame& frame) {
    const uint32_t baseFrequency = frequencyForViseme(frame.viseme);
    const uint32_t fifthFrequency = (baseFrequency * 3u) / 2u;
    const int32_t gain = static_cast<int32_t>(frame.envelope * (frame.ducked ? 2600.0f : 7200.0f));
    const uint32_t sampleHold = frame.viseme == AudioOutViseme::Neutral ? 13u : 7u;

    for (size_t i = 0; i < kSamplesPerFrame; ++i) {
      phase_ += baseFrequency;
      if (phase_ >= kSampleRate) {
        phase_ -= kSampleRate;
      }
      phaseFifth_ += fifthFrequency;
      if (phaseFifth_ >= kSampleRate) {
        phaseFifth_ -= kSampleRate;
      }

      if ((i % sampleHold) == 0) {
        noise_ = noise_ * 1664525u + 1013904223u;
        heldNoise_ = static_cast<int32_t>((noise_ >> 23) & 0x1ffu) - 256;
      }

      const int32_t saw = (static_cast<int32_t>(phase_) * 2 * 32767 / static_cast<int32_t>(kSampleRate)) - 32767;
      const int32_t fifth = phaseFifth_ < (kSampleRate / 2u) ? 6000 : -6000;
      int32_t sample = ((saw / 5) + fifth + heldNoise_ * 12) * gain / 8192;
      if (sample > 32767) {
        sample = 32767;
      } else if (sample < -32768) {
        sample = -32768;
      }
      samples_[i] = static_cast<int16_t>(sample);
    }
  }

  bool ready_ = false;
  bool active_ = false;
  bool wavActive_ = false;
  bool downlinkActive_ = false;
  uint8_t* downlinkBuffer_ = nullptr;
  uint32_t downlinkBufferCapacity_ = 0;
  uint32_t downlinkBufferedBytes_ = 0;
  uint32_t downlinkBufferedChunks_ = 0;
  uint32_t downlinkExpectedBytes_ = 0;
  uint32_t downlinkExpectedChunks_ = 0;
  uint32_t downlinkSampleRate_ = kSampleRate;
  uint32_t downlinkStartedAtMs_ = 0;
  uint32_t downlinkLastActivityAtMs_ = 0;
  uint32_t downlinkFirstChunkQueuedAtMs_ = 0;
  uint32_t downlinkQueuedAudioMs_ = 0;
  uint32_t downlinkNextStreamingBuffer_ = 0;
  uint32_t streamTaskChunks_ = 0;
  uint32_t streamTaskBytes_ = 0;
  uint32_t streamPlayRawOk_ = 0;
  uint32_t streamPlayRawFailed_ = 0;
  uint32_t streamLastSampleCount_ = 0;
  uint32_t streamLastSampleRate_ = 0;
  uint32_t streamLastFirstChunkDelayMs_ = 0;
  uint32_t streamLastQueuedAudioMs_ = 0;
  uint32_t streamQueueWaitMaxUs_ = 0;
  uint32_t streamReleaseDeferrals_ = 0;
  uint32_t streamForcedStops_ = 0;
  uint32_t streamOrphanStops_ = 0;
  bool streamWatchdogStopPending_ = false;
  uint32_t diagnosticToneOk_ = 0;
  uint32_t diagnosticToneFailed_ = 0;
  uint32_t speakerAmpResetAttempts_ = 0;
  uint32_t speakerAmpResetOk_ = 0;
  uint32_t speakerAmpResetFailed_ = 0;
  bool speakerPowerActive_ = false;
  uint32_t speakerPowerUpEntries_ = 0;
  uint32_t speakerPowerDownEntries_ = 0;
  uint32_t micCueRestoreAtMs_ = 0;
  size_t micCueSamplesWritten_ = 0;
  uint32_t micCueDurationMs_ = 0;
  bool audioPauseHeld_ = false;
  uint32_t audioPauseReleaseAtMs_ = 0;
  uint32_t audioPauseForceReleaseAtMs_ = 0;
  uint32_t phase_ = 0;
  uint32_t phaseFifth_ = 0;
  uint32_t noise_ = 0x1234abcd;
  int32_t heldNoise_ = 0;
#if STACKCHAN_BRIDGE_AUDIO_STREAMING_PLAYBACK
  int16_t downlinkStreamingBuffers_[STACKCHAN_BRIDGE_AUDIO_STREAMING_BUFFER_COUNT]
                                    [kStreamingSamplesPerBuffer] {};
#endif
  int16_t samples_[kSamplesPerFrame] {};
  int16_t micCueSamples_[kMicCueMaxSamples] {};
};

M5SpeakerAudioSink gSpeakerSink;
char gBridgeSpeechText[kBridgeTextMax] = {};
char gBridgeEndpointResponse[kBridgeEndpointControlResponseMax] = {};
SpeechCue gPendingBridgeSpeechCue {};
bool gBridgeSpeechCuePending = false;
bool gBridgeResponseHadAudioStream = false;
uint32_t gBridgeLocalSpeechSuppressedUntilMs = 0;

enum class BridgeAudioSafetyStopReason : uint8_t {
  None = 0,
  TransportDisconnected,
  StreamWatchdog,
  RemoteRequest,
};

uint32_t gBridgeAudioSafetyStops = 0;
uint32_t gBridgeAudioDisconnectStops = 0;
uint32_t gBridgeAudioWatchdogStops = 0;
uint32_t gBridgeAudioRemoteStopRequests = 0;
uint32_t gBridgeAudioLastSafetyStopMs = 0;
BridgeAudioSafetyStopReason gBridgeAudioLastSafetyStopReason = BridgeAudioSafetyStopReason::None;

const char* bridgeAudioSafetyStopReasonName(BridgeAudioSafetyStopReason reason) {
  switch (reason) {
    case BridgeAudioSafetyStopReason::TransportDisconnected:
      return "transport_disconnected";
    case BridgeAudioSafetyStopReason::StreamWatchdog:
      return "stream_watchdog";
    case BridgeAudioSafetyStopReason::RemoteRequest:
      return "remote_request";
    case BridgeAudioSafetyStopReason::None:
      break;
  }
  return "none";
}

bool bridgeAudioRuntimeHeld() {
  const BridgeAudioDownlinkTelemetry& downlink = gBridgeAudioDownlink.telemetry();
  return downlink.active || downlink.playbackActive || gSpeakerSink.speakerPowerActive() != 0 ||
         gSpeakerSink.speakerRunning() != 0;
}

bool stopBridgeAudioRuntime(uint32_t nowMs, BridgeAudioSafetyStopReason reason) {
  const bool held = bridgeAudioRuntimeHeld();
  gBridgeAudioDownlink.abort(nowMs, 100u + static_cast<uint32_t>(reason));
  gAudioOut.cancel();
  gSpeakerSink.stop(nowMs);
  gBridgeSpeechCuePending = false;
  gBridgeResponseHadAudioStream = false;
  gBridgeLocalSpeechSuppressedUntilMs = 0;
  if (!held) {
    return false;
  }

  gBridgeAudioSafetyStops++;
  if (reason == BridgeAudioSafetyStopReason::TransportDisconnected) {
    gBridgeAudioDisconnectStops++;
  } else if (reason == BridgeAudioSafetyStopReason::StreamWatchdog) {
    gBridgeAudioWatchdogStops++;
  }
  gBridgeAudioLastSafetyStopMs = nowMs;
  gBridgeAudioLastSafetyStopReason = reason;
  return true;
}

void serviceBridgeAudioTransportSafety(uint32_t nowMs) {
  static bool initialized = false;
  static bool wasConnected = false;
  const bool connected =
      gBridgeNetworkSession.telemetry().state == BridgeNetworkSessionState::Connected;
  if (initialized && wasConnected && !connected && bridgeAudioRuntimeHeld()) {
    stopBridgeAudioRuntime(nowMs, BridgeAudioSafetyStopReason::TransportDisconnected);
  }
  wasConnected = connected;
  initialized = true;
}

const __FlashStringHelper* firmwareMode() {
#if STACKCHAN_SERVO_HARDWARE_ENABLE
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

CharacterMode visionModeForEvent(EventType type) {
  return type == EventType::FaceLost ? CharacterMode::Idle : CharacterMode::Attend;
}

CharacterMode imuModeForEvent(EventType type) {
  switch (type) {
    case EventType::Shaken:
      return CharacterMode::Error;
    case EventType::PutDown:
      return CharacterMode::Attend;
    case EventType::PickedUp:
    case EventType::Tilted:
      return CharacterMode::React;
    default:
      return CharacterMode::Idle;
  }
}

CharacterMode bridgeModeForEvent(EventType type) {
  switch (type) {
    case EventType::UserSpeaking:
      return CharacterMode::Listen;
    case EventType::ThinkingStarted:
      return CharacterMode::Think;
    case EventType::ResponseStarted:
      return CharacterMode::Speak;
    case EventType::ResponseEnded:
      return CharacterMode::Attend;
    case EventType::Error:
      return CharacterMode::Error;
    default:
      break;
  }
  return CharacterMode::Attend;
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

SpeechViseme toSpeechViseme(AudioOutViseme viseme) {
  switch (viseme) {
    case AudioOutViseme::Ah:
      return SpeechViseme::Ah;
    case AudioOutViseme::Oh:
      return SpeechViseme::Oh;
    case AudioOutViseme::Ee:
      return SpeechViseme::Ee;
    case AudioOutViseme::Neutral:
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

const __FlashStringHelper* promptSourceName(PromptSource source) {
  switch (source) {
    case PromptSource::PackagedPrompt:
      return F("packaged_prompt");
    case PromptSource::HostBridge:
      return F("host_bridge");
    case PromptSource::None:
      break;
  }
  return F("none");
}

const __FlashStringHelper* audioOutSourceName(AudioOutSource source) {
  switch (source) {
    case AudioOutSource::PackagedPrompt:
      return F("packaged_prompt");
    case AudioOutSource::None:
      break;
  }
  return F("none");
}

const __FlashStringHelper* bridgeOutputTypeName(BridgeClientOutputType type) {
  switch (type) {
    case BridgeClientOutputType::SessionReady:
      return F("session_ready");
    case BridgeClientOutputType::Event:
      return F("event");
    case BridgeClientOutputType::ResponseStart:
      return F("response_start");
    case BridgeClientOutputType::AudioFrame:
      return F("audio");
    case BridgeClientOutputType::AudioStreamStart:
      return F("audio_stream_start");
    case BridgeClientOutputType::AudioStreamChunk:
      return F("audio_stream_chunk");
    case BridgeClientOutputType::AudioStreamEnd:
      return F("audio_stream_end");
    case BridgeClientOutputType::ResponseEnd:
      return F("response_end");
    case BridgeClientOutputType::Error:
      return F("error");
    case BridgeClientOutputType::None:
      break;
  }
  return F("none");
}

const __FlashStringHelper* bridgeStateName(BridgeClientState state) {
  switch (state) {
    case BridgeClientState::Offline:
      return F("offline");
    case BridgeClientState::Connecting:
      return F("connecting");
    case BridgeClientState::Ready:
      return F("ready");
    case BridgeClientState::Listening:
      return F("listening");
    case BridgeClientState::Thinking:
      return F("thinking");
    case BridgeClientState::Responding:
      return F("responding");
    case BridgeClientState::Error:
      return F("error");
  }
  return F("unknown");
}

const __FlashStringHelper* bridgeNetworkStateName(BridgeNetworkSessionState state) {
  switch (state) {
    case BridgeNetworkSessionState::Idle:
      return F("idle");
    case BridgeNetworkSessionState::Connecting:
      return F("connecting");
    case BridgeNetworkSessionState::Handshaking:
      return F("handshaking");
    case BridgeNetworkSessionState::Connected:
      return F("connected");
    case BridgeNetworkSessionState::Backoff:
      return F("backoff");
    case BridgeNetworkSessionState::Error:
      return F("error");
  }
  return F("unknown");
}

const __FlashStringHelper* bridgeUploadActionName(BenchBridgeUploadAction action) {
  switch (action) {
    case BenchBridgeUploadAction::Start:
      return F("start");
    case BenchBridgeUploadAction::Chunk:
      return F("chunk");
    case BenchBridgeUploadAction::End:
      return F("end");
    case BenchBridgeUploadAction::Abort:
      return F("abort");
    case BenchBridgeUploadAction::None:
      break;
  }
  return F("none");
}

SpeechEarcon earconForIntent(SpeechIntent intent) {
  switch (intent) {
    case SpeechIntent::Boot:
    case SpeechIntent::Listen:
      return SpeechEarcon::Wake;
    case SpeechIntent::Idle:
    case SpeechIntent::Think:
      return SpeechEarcon::Think;
    case SpeechIntent::Happy:
      return SpeechEarcon::Happy;
    case SpeechIntent::Concern:
      return SpeechEarcon::Concern;
    case SpeechIntent::Sleep:
      return SpeechEarcon::Sleep;
    case SpeechIntent::Error:
      return SpeechEarcon::Error;
    case SpeechIntent::Safety:
      return SpeechEarcon::Safety;
    case SpeechIntent::Attend:
    case SpeechIntent::Speak:
    case SpeechIntent::React:
    case SpeechIntent::None:
      break;
  }
  return SpeechEarcon::Confirm;
}

void printBootMarker() {
  Serial.print(F("[boot] stackchan_alive mode="));
  Serial.print(firmwareMode());
#if defined(ARDUINO_ARCH_ESP32)
  Serial.print(F(" reset_reason="));
  Serial.print(static_cast<int>(gBootResetReason));
  Serial.print(F(" boot_count="));
  Serial.print(gRtcBootCount);
#endif
  Serial.println(F(" serial=v1"));
}

#if defined(ARDUINO_ARCH_ESP32)
const char* resetReasonName(esp_reset_reason_t reason) {
  switch (reason) {
    case ESP_RST_POWERON:
      return "poweron";
    case ESP_RST_EXT:
      return "external";
    case ESP_RST_SW:
      return "software";
    case ESP_RST_PANIC:
      return "panic";
    case ESP_RST_INT_WDT:
      return "interrupt_watchdog";
    case ESP_RST_TASK_WDT:
      return "task_watchdog";
    case ESP_RST_WDT:
      return "watchdog";
    case ESP_RST_DEEPSLEEP:
      return "deepsleep";
    case ESP_RST_BROWNOUT:
      return "brownout";
    case ESP_RST_SDIO:
      return "sdio";
    case ESP_RST_UNKNOWN:
    default:
      return "unknown";
  }
}

bool sampleChipTemperature(uint32_t nowMs, bool force) {
  if (!force && gChipTemperatureLastReadMs != 0 &&
      nowMs - gChipTemperatureLastReadMs < STACKCHAN_CHIP_TEMP_TELEMETRY_PERIOD_MS) {
    return gChipTemperatureValid;
  }
  gChipTemperatureLastReadMs = nowMs;
  const float value = temperatureRead();
  if (value > -40.0f && value < 125.0f) {
    gChipTemperatureC = value;
    if (!gChipTemperatureValid || value > gChipTemperatureMaxC) {
      gChipTemperatureMaxC = value;
    }
    gChipTemperatureValid = true;
    ++gChipTemperatureSamples;
    return true;
  }
  ++gChipTemperatureReadFailures;
  return false;
}

#if STACKCHAN_ENABLE_POWER_FORENSICS && defined(CONFIG_IDF_TARGET_ESP32S3)
bool readPmicPowerEventMask(uint32_t* eventMask) {
  if (eventMask == nullptr) {
    return false;
  }
  uint8_t raw[3] = {};
  if (!M5.In_I2C.readRegister(0x34, 0x48, raw, sizeof(raw), 400000)) {
    return false;
  }
  *eventMask = static_cast<uint32_t>(raw[0]) |
               (static_cast<uint32_t>(raw[1]) << 8u) |
               (static_cast<uint32_t>(raw[2]) << 16u);
  return true;
}

bool clearPmicPowerEventMask() {
  const uint8_t clear[3] = {0xFF, 0xFF, 0xFF};
  return M5.In_I2C.writeRegister(0x34, 0x48, clear, sizeof(clear), 400000);
}

bool configurePmicPowerForensicsIrqs() {
  const uint8_t desired[3] = {
      static_cast<uint8_t>(kPmicForensicsIrqEnableMask & 0xFFu),
      static_cast<uint8_t>((kPmicForensicsIrqEnableMask >> 8u) & 0xFFu),
      static_cast<uint8_t>((kPmicForensicsIrqEnableMask >> 16u) & 0xFFu),
  };
  if (!M5.In_I2C.writeRegister(0x34, 0x40, desired, sizeof(desired), 400000)) {
    return false;
  }
  uint8_t readback[3] = {};
  return M5.In_I2C.readRegister(0x34, 0x40, readback, sizeof(readback), 400000) &&
         memcmp(desired, readback, sizeof(desired)) == 0;
}

PmicPowerEventContext currentPmicPowerEventContext() {
  const ServoPowerTelemetry servoPower = gServo.powerTelemetry();
  PmicPowerEventContext context;
  context.vbusMv = gPowerVbusMv;
  context.batteryMv = gPowerBatteryMv;
  context.chipTemperatureDeciC = static_cast<int16_t>(gChipTemperatureC * 10.0f);
  context.pmicTemperatureDeciC = static_cast<int16_t>(gPowerPmicTemperatureC * 10.0f);
  context.bodyBusMv = static_cast<int16_t>(gBodyPowerBusV * 1000.0f);
  context.bodyCurrentMa = static_cast<int16_t>(gBodyPowerCurrentMa);
  context.heapFree = ESP.getFreeHeap();
  context.vbusValid = gPowerVbusValid;
  context.batteryValid = gPowerBatteryValid;
  context.chipTemperatureValid = gChipTemperatureValid;
  context.pmicTemperatureValid = gPowerPmicTemperatureValid;
  context.bodyPowerValid = gBodyPowerTelemetryValid;
  context.pmicVbusPresent = gPowerPmicVbusPresent;
  context.pmicBatteryPresent = gPowerPmicBatteryPresent;
  context.motionRequested = gMotionRequested;
  context.servoRailEnabled = servoPower.railEnabled;
  context.servoTorqueEnabled = servoPower.torqueEnabled;
  context.speakerPowerActive = gSpeakerSink.speakerPowerActive() != 0;
  return context;
}

void initializePmicPowerForensics() {
  uint32_t bootEventMask = 0;
  const bool bootStatusValid = readPmicPowerEventMask(&bootEventMask);
  gPmicPowerForensics.begin(bootStatusValid, bootEventMask);
  if (!bootStatusValid) {
    gPmicPowerForensics.noteReadFailure();
  } else if (!clearPmicPowerEventMask()) {
    gPmicPowerForensics.noteClearFailure();
  }

  const bool enabled = configurePmicPowerForensicsIrqs();
  gPmicPowerForensics.setIrqEnableResult(true, enabled);

  Serial.print(F("[power-forensics] boot_valid="));
  Serial.print(bootStatusValid ? 1 : 0);
  Serial.print(F(" boot_mask=0x"));
  Serial.print(bootEventMask, HEX);
  Serial.print(F(" boot_event="));
  Serial.print(pmicPowerEventName(bootEventMask));
  Serial.print(F(" irq_enable="));
  Serial.println(enabled ? 1 : 0);
}

void pollPmicPowerForensics(uint32_t nowMs) {
  uint32_t eventMask = 0;
  if (!readPmicPowerEventMask(&eventMask)) {
    gPmicPowerForensics.noteReadFailure();
    return;
  }
  if (eventMask == 0) {
    return;
  }

  const uint32_t selectedEventMask = eventMask & kPmicForensicsIrqEnableMask;
  const uint32_t ignoredEventMask = eventMask & ~kPmicForensicsIrqEnableMask;
  if (ignoredEventMask != 0) {
    gPmicPowerForensics.recordIgnoredRuntimeEvent(ignoredEventMask);
  }
  if (!clearPmicPowerEventMask()) {
    gPmicPowerForensics.noteClearFailure();
  }
  if (selectedEventMask == 0) {
    return;
  }

  const PmicPowerEventContext context = currentPmicPowerEventContext();
  gPmicPowerForensics.recordRuntimeEvent(selectedEventMask, nowMs, context);

  Serial.print(F("[power-forensics] runtime_mask=0x"));
  Serial.print(selectedEventMask, HEX);
  Serial.print(F(" event="));
  Serial.print(pmicPowerEventName(selectedEventMask));
  Serial.print(F(" vbus_mv="));
  Serial.print(context.vbusValid ? context.vbusMv : -1);
  Serial.print(F(" battery_mv="));
  Serial.print(context.batteryValid ? context.batteryMv : -1);
  Serial.print(F(" motion="));
  Serial.print(context.motionRequested ? 1 : 0);
  Serial.print(F(" rail="));
  Serial.print(context.servoRailEnabled ? 1 : 0);
  Serial.print(F(" speaker="));
  Serial.println(context.speakerPowerActive ? 1 : 0);
}
#endif

constexpr uint8_t kAxp2101Address = 0x34;
constexpr uint32_t kAxp2101I2cFrequency = 400000;

bool configurePmicInputPolicy() {
#if defined(CONFIG_IDF_TARGET_ESP32S3)
  if (!STACKCHAN_BASE_USB_POWER_INPUT || STACKCHAN_PMIC_VINDPM_MV == 0) {
    return true;
  }
  uint8_t config[3] = {};
  if (!M5.In_I2C.readRegister(
          kAxp2101Address, 0x14, config, sizeof(config), kAxp2101I2cFrequency)) {
    ++gPowerPmicConfigReadFailures;
    return false;
  }
  const uint8_t current = config[1];
  const uint8_t desired = static_cast<uint8_t>(
      (current & 0xF0) | axp2101VindpmRegisterForMv(STACKCHAN_PMIC_VINDPM_MV));
  if (!M5.In_I2C.writeRegister8(
          kAxp2101Address, 0x15, desired, kAxp2101I2cFrequency)) {
    return false;
  }
  if (!M5.In_I2C.readRegister(
          kAxp2101Address, 0x14, config, sizeof(config), kAxp2101I2cFrequency)) {
    ++gPowerPmicConfigReadFailures;
    return false;
  }
  gPowerPmicMinSystemRaw = config[0];
  gPowerPmicVindpmRaw = config[1];
  gPowerPmicInputCurrentLimitRaw = config[2];
  gPowerPmicConfigValid = true;
  return (config[1] & 0x0F) == (desired & 0x0F);
#else
  return true;
#endif
}

void samplePmicInputTelemetry() {
#if defined(CONFIG_IDF_TARGET_ESP32S3)
  uint8_t status[2] = {};
  if (M5.In_I2C.readRegister(
          kAxp2101Address, 0x00, status, sizeof(status), kAxp2101I2cFrequency)) {
    const bool wasCurrentLimited = gPowerPmicInputCurrentLimited;
    const bool wasVindpmActive = gPowerPmicVindpmActive;
    const bool wasSupplementing = gPowerPmicInputStateValid &&
                                  gPowerPmicBatteryDirection == 2 &&
                                  (gPowerPmicStatus1Raw & 0x20) != 0;
    gPowerPmicStatus1Raw = status[0];
    gPowerPmicStatus2Raw = status[1];
    gPowerPmicInputCurrentLimited = (status[0] & 0x01) != 0;
    gPowerPmicVindpmActive = (status[1] & 0x08) != 0;
    gPowerPmicBatteryDirection = static_cast<uint8_t>((status[1] >> 5) & 0x03);
    gPowerPmicChargeStatus = static_cast<uint8_t>(status[1] & 0x07);
    const bool supplementing = gPowerPmicBatteryDirection == 2 && (status[0] & 0x20) != 0;
    if (gPowerPmicInputCurrentLimited) {
      ++gPowerPmicInputCurrentLimitSamples;
      if (!gPowerPmicInputStateValid || !wasCurrentLimited) {
        ++gPowerPmicInputCurrentLimitEntries;
      }
    }
    if (gPowerPmicVindpmActive) {
      ++gPowerPmicVindpmSamples;
      if (!gPowerPmicInputStateValid || !wasVindpmActive) {
        ++gPowerPmicVindpmEntries;
      }
    }
    if (supplementing) {
      ++gPowerPmicBatterySupplementSamples;
      if (!wasSupplementing) {
        ++gPowerPmicBatterySupplementEntries;
      }
    }
    gPowerPmicInputStateValid = true;
  } else {
    ++gPowerPmicInputStateReadFailures;
  }

  uint8_t config[3] = {};
  if (M5.In_I2C.readRegister(
          kAxp2101Address, 0x14, config, sizeof(config), kAxp2101I2cFrequency)) {
    gPowerPmicMinSystemRaw = config[0];
    gPowerPmicVindpmRaw = config[1];
    gPowerPmicInputCurrentLimitRaw = config[2];
    if (STACKCHAN_PMIC_VINDPM_MV > 0) {
      gPowerPmicVindpmConfigured =
          (config[1] & 0x0F) == axp2101VindpmRegisterForMv(STACKCHAN_PMIC_VINDPM_MV);
    }
    gPowerPmicConfigValid = true;
  } else {
    ++gPowerPmicConfigReadFailures;
  }

  uint8_t vsys[2] = {};
  if (M5.In_I2C.readRegister(
          kAxp2101Address, 0x3A, vsys, sizeof(vsys), kAxp2101I2cFrequency)) {
    const int16_t millivolts = static_cast<int16_t>(((vsys[0] & 0x3F) << 8) | vsys[1]);
    if (millivolts >= 2500 && millivolts <= 6000) {
      gPowerVsysMv = millivolts;
      if (!gPowerVsysValid || millivolts < gPowerVsysMinMv) {
        gPowerVsysMinMv = millivolts;
      }
      if (!gPowerVsysValid || millivolts > gPowerVsysMaxMv) {
        gPowerVsysMaxMv = millivolts;
      }
      gPowerVsysValid = true;
      ++gPowerVsysSamples;
    } else {
      ++gPowerVsysReadFailures;
    }
  } else {
    ++gPowerVsysReadFailures;
  }
#endif
}

void initializeManagedPowerHardware(uint32_t nowMs) {
#if defined(ARDUINO_ARCH_ESP32)
  if (STACKCHAN_BASE_USB_POWER_INPUT) {
    M5.Power.setExtOutput(false);
    gExternalOutputEnabled = M5.Power.getExtOutput();
    gBaseInputModeConfigured = !gExternalOutputEnabled;
  } else {
    gExternalOutputEnabled = M5.Power.getExtOutput();
    gBaseInputModeConfigured = false;
  }

  if (STACKCHAN_CHARGE_CURRENT_MA > 0) {
    M5.Power.setBatteryCharge(true);
    M5.Power.setChargeCurrent(STACKCHAN_CHARGE_CURRENT_MA);
    gBatteryChargeConfigured = true;
    gAppliedChargeCurrentMa = STACKCHAN_CHARGE_CURRENT_MA;
  }
  const bool pmicInputPolicyReady = configurePmicInputPolicy();
  gPowerPmicVindpmConfigured =
      STACKCHAN_PMIC_VINDPM_MV > 0 && pmicInputPolicyReady;

  gPowerCoordinator.begin(gBaseInputModeConfigured,
                          STACKCHAN_CHARGE_CURRENT_MA,
                          nowMs,
                          STACKCHAN_LOW_INPUT_CHARGE_CURRENT_MA);
  gPowerFloorTracker.begin(STACKCHAN_MOTION_POWER_HARD_FLOOR_MV);

#if STACKCHAN_ENABLE_BODY_POWER_MONITOR && STACKCHAN_HAS_INA226_MONITOR
  static m5::INA226_Class bodyPowerMonitor(0x41, 100000, &M5.In_I2C);
  gBodyPowerMonitor = &bodyPowerMonitor;
  if (M5.In_I2C.isEnabled() && gBodyPowerMonitor->begin()) {
    m5::INA226_Class::config_t monitorConfig;
    monitorConfig.shunt_res = 0.01f;
    monitorConfig.max_expected_current = 3.2f;
    monitorConfig.sampling_rate = m5::INA226_Class::Sampling::Rate16;
    monitorConfig.shunt_conversion_time = m5::INA226_Class::ConversionTime::US_1100;
    monitorConfig.bus_conversion_time = m5::INA226_Class::ConversionTime::US_1100;
    monitorConfig.mode = m5::INA226_Class::Mode::ShuntAndBus;
    gBodyPowerMonitor->config(monitorConfig);
    gBodyPowerMonitorReady = true;
  }
#endif

  Serial.print(F("[power] base_input_mode="));
  Serial.print(gBaseInputModeConfigured ? 1 : 0);
  Serial.print(F(" ext_output="));
  Serial.print(gExternalOutputEnabled ? 1 : 0);
  Serial.print(F(" charge_enabled="));
  Serial.print(gBatteryChargeConfigured ? 1 : 0);
  Serial.print(F(" charge_current_ma="));
  Serial.print(STACKCHAN_CHARGE_CURRENT_MA);
  Serial.print(F(" body_monitor="));
  Serial.print(gBodyPowerMonitorReady ? 1 : 0);
  Serial.print(F(" vindpm_target_mv="));
  Serial.print(STACKCHAN_PMIC_VINDPM_MV);
  Serial.print(F(" vindpm_configured="));
  Serial.println(gPowerPmicVindpmConfigured ? 1 : 0);
#else
  (void)nowMs;
  gPowerCoordinator.begin(false, 0, 0, 0);
  gPowerFloorTracker.begin(0);
#endif
}

void applyManagedChargeCurrent(uint32_t nowMs) {
#if defined(ARDUINO_ARCH_ESP32)
  if (!gBatteryChargeConfigured) {
    return;
  }
  const uint16_t desiredMa = gPowerCoordinator.telemetry().chargeCurrentMa;
  if (desiredMa == 0 || desiredMa == gAppliedChargeCurrentMa) {
    return;
  }
  M5.Power.setChargeCurrent(desiredMa);
  gAppliedChargeCurrentMa = desiredMa;
  gChargeCurrentLastChangeMs = nowMs;
  ++gChargeCurrentTransitions;
  Serial.print(F("[power] charge_current_ma="));
  Serial.println(gAppliedChargeCurrentMa);
#else
  (void)nowMs;
#endif
}

bool sampleBodyPowerTelemetry(uint32_t nowMs, bool force) {
#if defined(ARDUINO_ARCH_ESP32) && STACKCHAN_ENABLE_BODY_POWER_MONITOR && STACKCHAN_HAS_INA226_MONITOR
  if (!gBodyPowerMonitorReady || gBodyPowerMonitor == nullptr) {
    return false;
  }
  if (!force && gBodyPowerTelemetryLastReadMs != 0 &&
      nowMs - gBodyPowerTelemetryLastReadMs < STACKCHAN_BODY_POWER_TELEMETRY_PERIOD_MS) {
    return gBodyPowerTelemetryValid;
  }

  gBodyPowerTelemetryLastReadMs = nowMs;
  const float busV = gBodyPowerMonitor->getBusVoltage();
  const float currentMa = gBodyPowerMonitor->getShuntCurrent() * 1000.0f;
  const float powerMw = gBodyPowerMonitor->getPower() * 1000.0f;
  const bool valid = isfinite(busV) && isfinite(currentMa) && isfinite(powerMw) && busV >= 2.5f &&
                     busV <= 6.5f && fabsf(currentMa) <= 5000.0f && fabsf(powerMw) <= 30000.0f;
  if (!valid) {
    ++gBodyPowerTelemetryReadFailures;
    return gBodyPowerTelemetryValid;
  }

  const bool first = !gBodyPowerTelemetryValid;
  gBodyPowerBusV = busV;
  gBodyPowerCurrentMa = currentMa;
  gBodyPowerMw = powerMw;
  if (first || busV < gBodyPowerBusMinV) {
    gBodyPowerBusMinV = busV;
  }
  if (first || busV > gBodyPowerBusMaxV) {
    gBodyPowerBusMaxV = busV;
  }
  if (first || currentMa < gBodyPowerCurrentMinMa) {
    gBodyPowerCurrentMinMa = currentMa;
  }
  if (first || currentMa > gBodyPowerCurrentMaxMa) {
    gBodyPowerCurrentMaxMa = currentMa;
  }
  gBodyPowerTelemetryValid = true;
  ++gBodyPowerTelemetrySamples;
  return true;
#else
  (void)nowMs;
  (void)force;
  return false;
#endif
}

bool samplePowerTelemetry(uint32_t nowMs, bool force) {
  sampleBodyPowerTelemetry(nowMs, force);
  if (!force && gPowerTelemetryLastReadMs != 0 &&
      nowMs - gPowerTelemetryLastReadMs < STACKCHAN_POWER_TELEMETRY_PERIOD_MS) {
    return gPowerTelemetryValid;
  }

  gPowerTelemetryLastReadMs = nowMs;
#if defined(CONFIG_IDF_TARGET_ESP32S3)
#if STACKCHAN_ENABLE_PMIC_INPUT_TELEMETRY
  samplePmicInputTelemetry();
#endif
  const bool pmicVbusPresent = M5.Power.Axp2101.isVBUS();
  const bool pmicBatteryPresent = M5.Power.Axp2101.getBatState();
  const float pmicTemperatureC = M5.Power.Axp2101.getInternalTemperature();
  if (!gPowerPmicVbusPresentValid) {
    gPowerPmicVbusPresentValid = true;
    gPowerPmicVbusPresent = pmicVbusPresent;
  } else if (pmicVbusPresent != gPowerPmicVbusPresent) {
    gPowerPmicVbusPresent = pmicVbusPresent;
    ++gPowerPmicVbusTransitions;
    if (!pmicVbusPresent) {
      ++gPowerPmicVbusLossEntries;
    }
    gPowerPmicVbusLastTransitionMs = nowMs;
  }
  if (pmicVbusPresent) {
    ++gPowerPmicVbusPresentSamples;
  } else {
    ++gPowerPmicVbusAbsentSamples;
  }
  gPowerPmicBatteryPresentValid = true;
  gPowerPmicBatteryPresent = pmicBatteryPresent;
  if (isfinite(pmicTemperatureC) && pmicTemperatureC > -40.0f && pmicTemperatureC < 125.0f) {
    gPowerPmicTemperatureC = pmicTemperatureC;
    if (!gPowerPmicTemperatureValid || pmicTemperatureC > gPowerPmicTemperatureMaxC) {
      gPowerPmicTemperatureMaxC = pmicTemperatureC;
    }
    gPowerPmicTemperatureValid = true;
  }
#endif
  const int16_t vbusMv = M5.Power.getVBUSVoltage();
  const int16_t batteryMv = M5.Power.getBatteryVoltage();
  const int32_t batteryLevel = M5.Power.getBatteryLevel();
  const int32_t chargingState = static_cast<int32_t>(M5.Power.isCharging());
  const bool vbusValid = vbusMv >= 2500 && vbusMv <= 6000;
  const bool batteryValid = batteryMv >= 2500 && batteryMv <= 5000;
  int16_t confirmVbusMv = -1;
  int16_t confirmBatteryMv = -1;
  bool confirmVbusValid = false;
  bool confirmBatteryValid = false;
  if (vbusValid && STACKCHAN_MOTION_POWER_HARD_FLOOR_MV > 0 &&
      vbusMv < STACKCHAN_MOTION_POWER_HARD_FLOOR_MV) {
    confirmVbusMv = M5.Power.getVBUSVoltage();
    confirmBatteryMv = M5.Power.getBatteryVoltage();
    confirmVbusValid = confirmVbusMv >= 2500 && confirmVbusMv <= 6000;
    confirmBatteryValid = confirmBatteryMv >= 2500 && confirmBatteryMv <= 5000;
  }
  const bool batteryLevelValid = batteryLevel >= 0 && batteryLevel <= 100;
  const bool chargingStateValid = chargingState >= 0 && chargingState <= 2;
  const bool valid = vbusValid || batteryValid || batteryLevelValid || chargingStateValid;
  if (!valid) {
    ++gPowerTelemetryReadFailures;
#if STACKCHAN_ENABLE_POWER_FORENSICS && defined(CONFIG_IDF_TARGET_ESP32S3)
    pollPmicPowerForensics(nowMs);
#endif
    return gPowerTelemetryValid;
  }

  gPowerVbusValid = vbusValid;
  if (vbusValid) {
    gPowerVbusMv = vbusMv;
    if (gPowerVbusMinMv == 0 || vbusMv < gPowerVbusMinMv) {
      gPowerVbusMinMv = vbusMv;
    }
    if (vbusMv > gPowerVbusMaxMv) {
      gPowerVbusMaxMv = vbusMv;
    }
  } else {
    gPowerVbusMv = -1;
    gPowerVbusLastRejectedMv = vbusMv;
    ++gPowerVbusRejectedSamples;
  }

  gPowerBatteryValid = batteryValid;
  if (batteryValid) {
    gPowerBatteryMv = batteryMv;
    if (gPowerBatteryMinMv == 0 || batteryMv < gPowerBatteryMinMv) {
      gPowerBatteryMinMv = batteryMv;
    }
    if (batteryMv > gPowerBatteryMaxMv) {
      gPowerBatteryMaxMv = batteryMv;
    }
  } else {
    gPowerBatteryMv = -1;
    gPowerBatteryLastRejectedMv = batteryMv;
    ++gPowerBatteryRejectedSamples;
  }
  gPowerBatteryLevel = batteryLevelValid ? batteryLevel : -1;
  gPowerChargingState = chargingStateValid ? chargingState : 2;

  const ServoPowerTelemetry servoPower = gServo.powerTelemetry();
  PowerFloorSample floorSample;
  floorSample.vbusValid = vbusValid;
  floorSample.vbusMv = vbusMv;
  floorSample.confirmVbusValid = confirmVbusValid;
  floorSample.confirmVbusMv = confirmVbusMv;
  floorSample.batteryValid = batteryValid;
  floorSample.batteryMv = batteryMv;
  floorSample.confirmBatteryValid = confirmBatteryValid;
  floorSample.confirmBatteryMv = confirmBatteryMv;
  floorSample.bodyPowerValid = gBodyPowerTelemetryValid;
  floorSample.bodyBusV = gBodyPowerBusV;
  floorSample.bodyCurrentMa = gBodyPowerCurrentMa;
  floorSample.motionRequested = gMotionRequested;
  floorSample.servoRailEnabled = servoPower.railEnabled;
  floorSample.servoTorqueEnabled = servoPower.torqueEnabled;
  floorSample.speakerPowerActive = gSpeakerSink.speakerPowerActive() != 0;
  floorSample.pmicInputCurrentLimited = gPowerPmicInputCurrentLimited;
  floorSample.pmicVindpmActive = gPowerPmicVindpmActive;
  floorSample.pmicBatteryDischarging = gPowerPmicBatteryDirection == 2;
  floorSample.pmicVsysValid = gPowerVsysValid;
  floorSample.pmicVsysMv = gPowerVsysMv;
  if (gPowerFloorTracker.update(floorSample, nowMs)) {
    Serial.print(F("[power] hard_floor_entry=1 vbus_mv="));
    Serial.print(vbusMv);
    Serial.print(F(" confirm_vbus_mv="));
    Serial.print(confirmVbusValid ? confirmVbusMv : -1);
    Serial.print(F(" body_bus_v="));
    Serial.print(gBodyPowerTelemetryValid ? gBodyPowerBusV : -1.0f, 3);
    Serial.print(F(" body_current_ma="));
    Serial.print(gBodyPowerTelemetryValid ? gBodyPowerCurrentMa : 0.0f, 1);
    Serial.print(F(" vsys_mv="));
    Serial.print(gPowerVsysValid ? gPowerVsysMv : -1);
    Serial.print(F(" vindpm="));
    Serial.print(gPowerPmicVindpmActive ? 1 : 0);
    Serial.print(F(" input_limited="));
    Serial.println(gPowerPmicInputCurrentLimited ? 1 : 0);
  }
  gPowerTelemetryValid = true;
  ++gPowerTelemetrySamples;
#if STACKCHAN_ENABLE_POWER_FORENSICS && defined(CONFIG_IDF_TARGET_ESP32S3)
  pollPmicPowerForensics(nowMs);
#endif
  return true;
}

void formatChipTemperatureJson(char* buffer, size_t bufferSize) {
  if (buffer == nullptr || bufferSize == 0) {
    return;
  }
  if (gChipTemperatureValid) {
    snprintf(
        buffer,
        bufferSize,
        ",\"chip_temp_c\":%.1f,\"chip_temp_max_c\":%.1f",
        static_cast<double>(gChipTemperatureC),
        static_cast<double>(gChipTemperatureMaxC));
  } else {
    snprintf(buffer, bufferSize, ",\"chip_temp_c\":null,\"chip_temp_max_c\":null");
  }
}
#endif

void printHeartbeat() {
  Serial.print(F("[heartbeat] stackchan_alive mode="));
  Serial.print(firmwareMode());
  Serial.print(F(" uptime_ms="));
  Serial.println(millis());
}

UBaseType_t stackHighWater(TaskHandle_t handle) {
  return handle == nullptr ? 0 : uxTaskGetStackHighWaterMark(handle);
}

void copyWakeSrError(const char* reason) {
  if (reason == nullptr) {
    gWakeSrProbe.lastError[0] = '\0';
    return;
  }
  const size_t len = strlen(reason);
  const size_t copyLen = len < (sizeof(gWakeSrProbe.lastError) - 1u)
                             ? len
                             : (sizeof(gWakeSrProbe.lastError) - 1u);
  memcpy(gWakeSrProbe.lastError, reason, copyLen);
  gWakeSrProbe.lastError[copyLen] = '\0';
}

void copyWakeSrString(char* destination, size_t destinationSize, const char* value) {
  if (destination == nullptr || destinationSize == 0) {
    return;
  }
  if (value == nullptr) {
    destination[0] = '\0';
    return;
  }
  const size_t len = strlen(value);
  const size_t copyLen = len < (destinationSize - 1u) ? len : (destinationSize - 1u);
  memcpy(destination, value, copyLen);
  destination[copyLen] = '\0';
}

#if STACKCHAN_HAS_SR_WAKE_PROBE || STACKCHAN_HAS_SR_WAKE_DIRECT || STACKCHAN_HAS_SR_WAKE_AFE_LITE || \
    STACKCHAN_HAS_MWW_WAKE_PROBE
void conditionWakeSrDirectAudio(int16_t* audioBuf, int sampleCount, int channelCount);
#endif

#if STACKCHAN_HAS_SR_WAKE_PROBE
#if STACKCHAN_SR_WAKE_PROBE_COMMAND_WAKE
const sr_cmd_t kWakeCommandPhrases[] = {
    {1, "hey stack chan", "hd STaK paN"},
    {1, "hey stack chahn", "hd STaK pnN"},
    {1, "hey stack chawn", "hd STaK peN"},
    {1, "hey stack chun", "hd STaK pcN"},
    {1, "hey stackchan", "hd STaKaN"},
    {1, "hi stack chan", "hi STaK paN"},
    {1, "hi stack chahn", "hi STaK pnN"},
    {1, "hi stack chawn", "hi STaK peN"},
    {1, "hi stackchan", "hi STaKaN"},
    {1, "stack chan", "STaK paN"},
    {1, "stack chahn", "STaK pnN"},
    {1, "stack chawn", "STaK peN"},
};
constexpr size_t kWakeCommandPhraseCount =
    sizeof(kWakeCommandPhrases) / sizeof(kWakeCommandPhrases[0]);
#endif

void onWakeSrProbeEvent(sr_event_t event, int commandId, int phraseId) {
  (void)phraseId;
#if STACKCHAN_SR_WAKE_PROBE_COMMAND_WAKE
  if (event == SR_EVENT_TIMEOUT) {
    ESP_SR_M5.setMode(SR_MODE_COMMAND);
    return;
  }
  const bool isWakeEvent =
      event == SR_EVENT_WAKEWORD || (event == SR_EVENT_COMMAND && commandId == 1);
#else
  (void)commandId;
  const bool isWakeEvent = event == SR_EVENT_WAKEWORD;
#endif
  if (!isWakeEvent) {
    return;
  }

  const uint32_t nowMs = millis();
  portENTER_CRITICAL(&gWakeSrMux);
  gWakeSrPendingDetections = gWakeSrPendingDetections + 1;
  gWakeSrProbe.wakeDetections++;
  gWakeSrProbe.lastWakeMs = nowMs;
  portEXIT_CRITICAL(&gWakeSrMux);
#if STACKCHAN_SR_WAKE_PROBE_COMMAND_WAKE
  ESP_SR_M5.setMode(SR_MODE_COMMAND);
#else
  ESP_SR_M5.setMode(SR_MODE_WAKEWORD);
#endif
}

uint32_t takeWakeSrPendingDetections() {
  portENTER_CRITICAL(&gWakeSrMux);
  const uint32_t pending = gWakeSrPendingDetections;
  gWakeSrPendingDetections = 0;
  portEXIT_CRITICAL(&gWakeSrMux);
  return pending;
}

void WakeSrProbeTask(void* pv) {
  (void)pv;
  constexpr size_t kWakeSrProbeFrameSamples = STACKCHAN_SR_WAKE_DIRECT_STEREO ? 1024 : 512;
  constexpr size_t kWakeSrProbeAudioChannels = STACKCHAN_SR_WAKE_DIRECT_STEREO ? 2 : 1;
  constexpr size_t kWakeSrProbeRecordSamples = kWakeSrProbeFrameSamples * kWakeSrProbeAudioChannels;
  static int16_t audioBuf[kWakeSrProbeRecordSamples];

  gWakeSrProbe.beginAttempts++;
  auto micConfig = M5.Mic.config();
  micConfig.sample_rate = 16000;
#if !STACKCHAN_SR_WAKE_PROBE_USE_M5_MIC_DEFAULTS
  micConfig.magnification = STACKCHAN_SR_WAKE_DIRECT_MIC_MAGNIFICATION;
  micConfig.noise_filter_level = STACKCHAN_SR_WAKE_MIC_NOISE_FILTER_LEVEL;
  micConfig.task_priority = STACKCHAN_SR_WAKE_MIC_TASK_PRIORITY;
  micConfig.task_pinned_core = STACKCHAN_SR_WAKE_MIC_TASK_CORE;
#if STACKCHAN_SR_WAKE_DIRECT_STEREO || STACKCHAN_SR_WAKE_DIRECT_MIC_INPUT_STEREO
  micConfig.input_channel = m5::input_channel_t::input_stereo;
  micConfig.stereo = true;
#else
  micConfig.stereo = false;
#endif
#endif
  M5.Mic.config(micConfig);
  if (!M5.Mic.begin()) {
    gWakeSrProbe.beginFailures++;
    copyWakeSrError("sr_wake_mic_begin_failed");
    Serial.println(F("[sr_wake] ready=0 error=mic_begin_failed"));
    vTaskDelete(nullptr);
    return;
  }
  gWakeSrProbe.micReady = true;

  ESP_SR_M5.onEvent(onWakeSrProbeEvent);
  Serial.println(F("[sr_wake] begin_sr=1"));
  const bool srBeginOk = ESP_SR_M5.begin(
#if STACKCHAN_SR_WAKE_PROBE_COMMAND_WAKE
      kWakeCommandPhrases,
      kWakeCommandPhraseCount,
      SR_MODE_COMMAND,
#else
      nullptr,
      0,
      SR_MODE_WAKEWORD,
#endif
      STACKCHAN_SR_WAKE_DIRECT_STEREO ? SR_CHANNELS_STEREO : SR_CHANNELS_MONO);
  Serial.print(F("[sr_wake] begin_sr_done=1 ok="));
  Serial.println(srBeginOk ? 1 : 0);
  if (!srBeginOk) {
    gWakeSrProbe.beginFailures++;
    copyWakeSrError("sr_wake_begin_failed");
    Serial.println(F("[sr_wake] ready=0 error=sr_begin_failed"));
    vTaskDelete(nullptr);
    return;
  }

  gWakeSrProbe.srReady = true;
  gWakeSrProbe.taskStarted = true;
  gWakeSrProbe.chunkSamples = kWakeSrProbeFrameSamples;
  gWakeSrProbe.recordSamples = kWakeSrProbeRecordSamples;
  gWakeSrProbe.audioChannels = kWakeSrProbeAudioChannels;
  gWakeSrProbe.sampleRate = 16000;
  const auto appliedMicConfig = M5.Mic.config();
  gWakeSrProbe.micMagnification = appliedMicConfig.magnification;
  gWakeSrProbe.monoChannel = appliedMicConfig.input_channel == m5::input_channel_t::input_only_left ? 1 : 0;
  gWakeSrProbe.micInputStereo =
      appliedMicConfig.input_channel == m5::input_channel_t::input_stereo;
  gWakeSrProbe.micTaskCore = appliedMicConfig.task_pinned_core;
  gWakeSrProbe.micTaskPriority = appliedMicConfig.task_priority;
  gWakeSrProbe.micNoiseFilterLevel = appliedMicConfig.noise_filter_level;
  gWakeSrProbe.stereo = appliedMicConfig.stereo;
  gWakeSrProbe.audioGainQ8 = STACKCHAN_SR_WAKE_DIRECT_GAIN_Q8;
  copyWakeSrString(
      gWakeSrProbe.modelName,
      sizeof(gWakeSrProbe.modelName),
#if STACKCHAN_SR_WAKE_PROBE_COMMAND_WAKE
      "ESP_SR_M5Unified_CommandWake"
#else
      "ESP_SR_M5Unified"
#endif
  );
  copyWakeSrString(
      gWakeSrProbe.wakeWord,
      sizeof(gWakeSrProbe.wakeWord),
#if STACKCHAN_SR_WAKE_PROBE_COMMAND_WAKE
      "Hey Stack Chan"
#else
      "Hi,Stack Chan"
#endif
  );
  copyWakeSrError("");
#if STACKCHAN_SR_WAKE_PROBE_COMMAND_WAKE
  Serial.println(F("[sr_wake] ready=1 phrase=\"Hey Stack Chan\" mode=command_wake task_core=0"));
#else
  Serial.println(F("[sr_wake] ready=1 phrase=\"Hi Stack Chan\" mode=wake_only task_core=0"));
#endif
  vTaskPrioritySet(nullptr, STACKCHAN_SR_WAKE_PROBE_RUN_TASK_PRIORITY);

  bool srPaused = false;
  uint32_t listenStartMs = millis();
  uint32_t restStartMs = 0;

  while (true) {
#if STACKCHAN_SR_WAKE_PROBE_LISTEN_MS > 0 && STACKCHAN_SR_WAKE_PROBE_REST_MS > 0
    const uint32_t nowMs = millis();
    if (!srPaused && nowMs - listenStartMs >= STACKCHAN_SR_WAKE_PROBE_LISTEN_MS) {
      ESP_SR_M5.pause();
      srPaused = true;
      restStartMs = nowMs;
    }
    if (srPaused) {
      if (nowMs - restStartMs < STACKCHAN_SR_WAKE_PROBE_REST_MS) {
        vTaskDelay(pdMS_TO_TICKS(5));
        continue;
      }
      ESP_SR_M5.resume();
      ESP_SR_M5.setMode(SR_MODE_WAKEWORD);
      srPaused = false;
      listenStartMs = nowMs;
    }
#endif
    if (M5.Mic.record(
            audioBuf,
            kWakeSrProbeRecordSamples,
            16000,
            kWakeSrProbeAudioChannels > 1)) {
      conditionWakeSrDirectAudio(
          audioBuf, kWakeSrProbeRecordSamples, static_cast<int>(kWakeSrProbeAudioChannels));
      ESP_SR_M5.feedAudio(audioBuf, kWakeSrProbeRecordSamples);
      gWakeSrProbe.recordOk++;
      gWakeSrProbe.samplesFed += kWakeSrProbeRecordSamples;
      gWakeSrProbe.lastRecordMs = millis();
    } else {
      gWakeSrProbe.recordDrops++;
      vTaskDelay(pdMS_TO_TICKS(1));
    }
  }
}

void pollWakeSrProbe(uint32_t nowMs) {
  const uint32_t pending = takeWakeSrPendingDetections();
  for (uint32_t i = 0; i < pending; ++i) {
    RobotEvent event;
    event.type = EventType::WakeWord;
    event.timestampMs = nowMs;
    event.strength = 1.0f;
    applyWakeEventFromLocalSource(
        event, CharacterMode::Listen, F("sr_wake_probe"), gWakeSrProbe.wakeDetections, nowMs);
    gWakeSrProbe.wakeEventsApplied++;
    Serial.print(F("[sr_wake] event=wake_word applied=1 detections="));
    Serial.print(gWakeSrProbe.wakeDetections);
    Serial.print(F(" applied_total="));
    Serial.print(gWakeSrProbe.wakeEventsApplied);
    Serial.print(F(" at_ms="));
    Serial.println(nowMs);
  }
}

bool startWakeSrProbe() {
  const BaseType_t ok = xTaskCreatePinnedToCore(
      WakeSrProbeTask,
      "WakeSrProbe",
      STACKCHAN_SR_WAKE_PROBE_TASK_STACK_WORDS,
      nullptr,
      STACKCHAN_SR_WAKE_PROBE_INIT_TASK_PRIORITY,
      &gWakeSrTaskHandle,
      0);
  if (ok != pdPASS) {
    gWakeSrProbe.beginFailures++;
    copyWakeSrError("sr_wake_task_create_failed");
    Serial.println(F("[sr_wake] ready=0 error=task_create_failed"));
    return false;
  }
  return true;
}
#else
void pollWakeSrProbe(uint32_t nowMs) {
  (void)nowMs;
}

bool startWakeSrProbe() {
#if STACKCHAN_ENABLE_SR_WAKE_PROBE
  gWakeSrProbe.beginFailures++;
  copyWakeSrError("sr_wake_not_compiled");
  Serial.println(F("[sr_wake] ready=0 error=not_compiled"));
  return false;
#else
  return true;
#endif
}
#endif

void suppressWakeMwwDetections(uint32_t nowMs, uint32_t durationMs) {
#if STACKCHAN_HAS_MWW_WAKE_PROBE
  gWakeMwwSuppressUntilMs = nowMs + durationMs;
#else
  (void)nowMs;
  (void)durationMs;
#endif
}

bool wakeMwwDetectionsSuppressed(uint32_t nowMs) {
#if STACKCHAN_HAS_MWW_WAKE_PROBE
  const uint32_t untilMs = gWakeMwwSuppressUntilMs;
  return untilMs != 0 && static_cast<int32_t>(untilMs - nowMs) > 0;
#else
  (void)nowMs;
  return false;
#endif
}

bool wakeMwwInteractionReadyForWake(uint32_t nowMs) {
  (void)nowMs;
#if STACKCHAN_HAS_MWW_WAKE_PROBE
  const BridgeWakeGateTelemetry& wakeGate = gBridgeWakeGate.telemetry();
  const BridgeAudioUplinkTelemetry& uplink = gBridgeAudioUplink.telemetry();
  const BridgeNetworkSessionTelemetry& network = gBridgeNetworkSession.telemetry();
  const BridgeClientTelemetry& bridge = gBridge.telemetry();
  const bool bridgeBusy =
      bridge.state == BridgeClientState::Listening ||
      bridge.state == BridgeClientState::Thinking ||
      bridge.state == BridgeClientState::Responding ||
      gBridge.hasPendingOutput();
  return network.state == BridgeNetworkSessionState::Connected && !bridgeBusy &&
         !wakeGate.turnActive && !uplink.active;
#else
  return false;
#endif
}

void refreshWakeMwwInteractionLatch(uint32_t nowMs) {
#if STACKCHAN_HAS_MWW_WAKE_PROBE
  if (!gWakeMwwInteractionLatched) {
    return;
  }
  if (wakeMwwInteractionReadyForWake(nowMs) &&
      nowMs - gWakeMwwInteractionLatchedAtMs >= 500u) {
    gWakeMwwInteractionLatched = false;
#if STACKCHAN_ENABLE_WAKE_SERIAL_LOGS
    Serial.print(F("[mww_wake] interaction_latch=0 reason=ready at_ms="));
    Serial.println(nowMs);
#endif
    return;
  }
  if (nowMs - gWakeMwwInteractionLatchedAtMs >= (kBridgeWakeGateMaxTurnMs + 3000u)) {
    gWakeMwwInteractionLatched = false;
#if STACKCHAN_ENABLE_WAKE_SERIAL_LOGS
    Serial.print(F("[mww_wake] interaction_latch=0 reason=timeout at_ms="));
    Serial.println(nowMs);
#endif
  }
#else
  (void)nowMs;
#endif
}

void playLocalWakeToneIfNeeded(const __FlashStringHelper* source) {
#if STACKCHAN_ENABLE_SPEAKER && !STACKCHAN_ENABLE_BRIDGE_AUDIO_UPLINK
  const uint32_t nowMs = millis();
  suppressWakeMwwDetections(nowMs, 900);
  const bool accepted = gSpeakerSink.playMicActivationTone();
#if STACKCHAN_ENABLE_WAKE_SERIAL_LOGS
  Serial.print(F("[mic] activation_tone=1 source="));
  Serial.print(source);
  Serial.print(F(" accepted="));
  Serial.print(accepted ? 1 : 0);
  Serial.print(F(" at_ms="));
  Serial.println(nowMs);
#else
  (void)accepted;
#endif
#else
  (void)source;
#endif
}

void applyWakeEventFromLocalSource(
    const RobotEvent& event,
    CharacterMode mode,
    const __FlashStringHelper* source,
    uint32_t count,
    uint32_t nowMs) {
  gIntent.applyEvent(event, mode);
#if STACKCHAN_ENABLE_WIFI_BRIDGE
  gBridgeNetworkSession.update(nowMs);
#endif
  gBridgeWakeGate.applyEvent(event, nowMs);
#if STACKCHAN_ENABLE_WIFI_BRIDGE
  gBridgeNetworkSession.update(nowMs);
#endif
  playLocalWakeToneIfNeeded(source);
#if STACKCHAN_ENABLE_WAKE_SERIAL_LOGS
  Serial.print(F("[wake] source="));
  Serial.print(source);
  Serial.print(F(" event=wake_word applied=1 count="));
  Serial.print(count);
  Serial.print(F(" at_ms="));
  Serial.println(nowMs);
#else
  (void)source;
  (void)count;
#endif
}

#if STACKCHAN_HAS_SR_WAKE_DIRECT || STACKCHAN_HAS_SR_WAKE_AFE_LITE
char* chooseWakeSrModel(srmodel_list_t* models) {
  char* modelName = esp_srmodel_filter(models, ESP_WN_PREFIX, "stackchan");
  if (modelName != nullptr) {
    return modelName;
  }
  modelName = esp_srmodel_filter(models, ESP_WN_PREFIX, "histackchan");
  if (modelName != nullptr) {
    return modelName;
  }
  return esp_srmodel_filter(models, ESP_WN_PREFIX, nullptr);
}
#endif

#if STACKCHAN_HAS_SR_WAKE_PROBE || STACKCHAN_HAS_SR_WAKE_DIRECT || STACKCHAN_HAS_SR_WAKE_AFE_LITE || \
    STACKCHAN_HAS_MWW_WAKE_PROBE
void updateWakeSrAudioWindow(uint32_t peak, uint32_t meanAbs, uint32_t nowMs) {
  constexpr uint32_t kWindowMs = 5000;
  if (gWakeSrProbe.audioWindowStartMs == 0 ||
      nowMs - gWakeSrProbe.audioWindowStartMs >= kWindowMs) {
    gWakeSrProbe.audioWindowStartMs = nowMs;
    gWakeSrProbe.audioWindowMs = 0;
    gWakeSrProbe.audioPeakWindowMax = peak;
    gWakeSrProbe.audioMeanAbsWindowMax = meanAbs;
    return;
  }
  gWakeSrProbe.audioWindowMs = nowMs - gWakeSrProbe.audioWindowStartMs;
  if (peak > gWakeSrProbe.audioPeakWindowMax) {
    gWakeSrProbe.audioPeakWindowMax = peak;
  }
  if (meanAbs > gWakeSrProbe.audioMeanAbsWindowMax) {
    gWakeSrProbe.audioMeanAbsWindowMax = meanAbs;
  }
}
#endif

#if STACKCHAN_HAS_MWW_WAKE_PROBE && STACKCHAN_ENABLE_CAMERA && STACKCHAN_MWW_WAKE_RECORD_STEREO
void queueWakeMwwStereoDirection(const StereoDirectionEstimate& estimate, uint32_t nowMs) {
  if (!estimate.valid) {
    gWakeSrProbe.stereoDirectionRejected++;
    return;
  }
  float azimuthNorm = estimate.azimuthNorm;
#if STACKCHAN_CAMERA_AUDIO_DIRECTION_INVERT
  azimuthNorm = -azimuthNorm;
#endif
  gWakeSrProbe.stereoDirectionEstimates++;
  gWakeSrProbe.stereoDirectionLastAzimuthNorm = azimuthNorm;
  gWakeSrProbe.stereoDirectionLastConfidence = estimate.confidence;
  gWakeSrProbe.stereoDirectionLastCorrelation = estimate.correlation;
  gWakeSrProbe.stereoDirectionLastLagSamples = estimate.lagSamples;
  portENTER_CRITICAL(&gWakeMwwStereoDirectionMux);
  gWakeMwwStereoDirectionPending.azimuthNorm = azimuthNorm;
  gWakeMwwStereoDirectionPending.confidence = estimate.confidence;
  gWakeMwwStereoDirectionPending.capturedAtMs = nowMs;
  gWakeMwwStereoDirectionPendingReady = true;
  portEXIT_CRITICAL(&gWakeMwwStereoDirectionMux);
}

bool takeWakeMwwStereoDirection(WakeMwwStereoDirectionPending* directionOut) {
  if (directionOut == nullptr) {
    return false;
  }
  bool ready = false;
  portENTER_CRITICAL(&gWakeMwwStereoDirectionMux);
  if (gWakeMwwStereoDirectionPendingReady) {
    *directionOut = gWakeMwwStereoDirectionPending;
    gWakeMwwStereoDirectionPendingReady = false;
    ready = true;
  }
  portEXIT_CRITICAL(&gWakeMwwStereoDirectionMux);
  return ready;
}
#endif

#if STACKCHAN_HAS_SR_WAKE_DIRECT
uint32_t takeWakeSrDirectPendingDetections() {
  portENTER_CRITICAL(&gWakeSrDirectMux);
  const uint32_t pending = gWakeSrDirectPendingDetections;
  gWakeSrDirectPendingDetections = 0;
  portEXIT_CRITICAL(&gWakeSrDirectMux);
  return pending;
}

void queueWakeSrDirectDetection(uint32_t nowMs) {
  portENTER_CRITICAL(&gWakeSrDirectMux);
  gWakeSrDirectPendingDetections = gWakeSrDirectPendingDetections + 1;
  gWakeSrProbe.wakeDetections++;
  gWakeSrProbe.lastWakeMs = nowMs;
  portEXIT_CRITICAL(&gWakeSrDirectMux);
}
#endif

#if STACKCHAN_HAS_SR_WAKE_PROBE || STACKCHAN_HAS_SR_WAKE_DIRECT || STACKCHAN_HAS_SR_WAKE_AFE_LITE || \
    STACKCHAN_HAS_MWW_WAKE_PROBE
int16_t clampWakeSrSample(int32_t sample) {
  if (sample > 32767) {
    return 32767;
  }
  if (sample < -32768) {
    return -32768;
  }
  return static_cast<int16_t>(sample);
}

void highPassWakeMwwAudio(int16_t* audioBuf, size_t sampleCount, int32_t& previousInput, int32_t& previousOutput) {
#if STACKCHAN_MWW_WAKE_HIGHPASS_Q15 > 0
  constexpr int32_t kAlphaQ15 = STACKCHAN_MWW_WAKE_HIGHPASS_Q15;
  for (size_t i = 0; i < sampleCount; ++i) {
    const int32_t input = audioBuf[i];
    const int32_t output = (kAlphaQ15 * (previousOutput + input - previousInput)) / 32768;
    previousInput = input;
    previousOutput = output;
    audioBuf[i] = clampWakeSrSample(output);
  }
#else
  (void)audioBuf;
  (void)sampleCount;
  (void)previousInput;
  (void)previousOutput;
#endif
}

bool recordWakeMwwAudioBlocking(int16_t* audioBuf, size_t sampleCount, uint32_t sampleRate, bool stereo) {
  if (!M5.Mic.record(audioBuf, sampleCount, sampleRate, stereo)) {
    return false;
  }
  while (M5.Mic.isRecording() != 0) {
    vTaskDelay(pdMS_TO_TICKS(1));
  }
  return true;
}

void conditionWakeSrDirectAudio(int16_t* audioBuf, int sampleCount, int channelCount) {
  uint32_t peak = 0;
  uint32_t meanAbs = 0;
  uint32_t channelPeak[2] = {0, 0};
  uint32_t channelMeanAbs[2] = {0, 0};
  uint32_t channelSamples[2] = {0, 0};
  uint32_t clips = 0;
  constexpr int32_t kGainQ8 = STACKCHAN_SR_WAKE_DIRECT_GAIN_Q8;
  for (int i = 0; i < sampleCount; ++i) {
    int32_t sample = audioBuf[i];
    if (kGainQ8 != 256) {
      sample = (sample * kGainQ8) / 256;
      if (sample > 32767 || sample < -32768) {
        clips++;
      }
      audioBuf[i] = clampWakeSrSample(sample);
      sample = audioBuf[i];
    }
    const uint32_t absSample = sample < 0 ? static_cast<uint32_t>(-sample) : static_cast<uint32_t>(sample);
    if (absSample > peak) {
      peak = absSample;
    }
    meanAbs += absSample;
    if (channelCount >= 2) {
      const int channel = i & 1;
      if (absSample > channelPeak[channel]) {
        channelPeak[channel] = absSample;
      }
      channelMeanAbs[channel] += absSample;
      channelSamples[channel]++;
    } else {
      if (absSample > channelPeak[0]) {
        channelPeak[0] = absSample;
      }
      channelMeanAbs[0] += absSample;
      channelSamples[0]++;
    }
  }
  gWakeSrProbe.audioPeak = peak;
  if (peak > gWakeSrProbe.audioPeakMax) {
    gWakeSrProbe.audioPeakMax = peak;
  }
  gWakeSrProbe.audioMeanAbs = sampleCount > 0 ? meanAbs / static_cast<uint32_t>(sampleCount) : 0;
  if (gWakeSrProbe.audioMeanAbs > gWakeSrProbe.audioMeanAbsMax) {
    gWakeSrProbe.audioMeanAbsMax = gWakeSrProbe.audioMeanAbs;
  }
  updateWakeSrAudioWindow(peak, gWakeSrProbe.audioMeanAbs, millis());
  gWakeSrProbe.audioPeakLeft = channelPeak[0];
  gWakeSrProbe.audioMeanAbsLeft =
      channelSamples[0] > 0 ? channelMeanAbs[0] / channelSamples[0] : 0;
  gWakeSrProbe.audioPeakRight = channelPeak[1];
  gWakeSrProbe.audioMeanAbsRight =
      channelSamples[1] > 0 ? channelMeanAbs[1] / channelSamples[1] : 0;
  gWakeSrProbe.audioClips += clips;
}

void applyWakeMwwEs7210GainOverride() {
#if STACKCHAN_MWW_WAKE_ES7210_GAIN_REG >= 0
  constexpr uint8_t kEs7210Address = 0x40;
  constexpr uint8_t kGainRegisterValue = static_cast<uint8_t>(STACKCHAN_MWW_WAKE_ES7210_GAIN_REG);
  const bool mic1Ok = M5.In_I2C.writeRegister8(kEs7210Address, 0x43, kGainRegisterValue, 400000);
  const bool mic2Ok = M5.In_I2C.writeRegister8(kEs7210Address, 0x44, kGainRegisterValue, 400000);
  const uint8_t mic1 = M5.In_I2C.readRegister8(kEs7210Address, 0x43, 400000);
  const uint8_t mic2 = M5.In_I2C.readRegister8(kEs7210Address, 0x44, 400000);
#if STACKCHAN_ENABLE_WAKE_SERIAL_LOGS
  Serial.print(F("[mww_wake] es7210_gain_override=1 value=0x"));
  Serial.print(kGainRegisterValue, HEX);
  Serial.print(F(" mic1_ok="));
  Serial.print(mic1Ok ? 1 : 0);
  Serial.print(F(" mic2_ok="));
  Serial.print(mic2Ok ? 1 : 0);
  Serial.print(F(" mic1=0x"));
  Serial.print(mic1, HEX);
  Serial.print(F(" mic2=0x"));
  Serial.println(mic2, HEX);
#else
  (void)mic1Ok;
  (void)mic2Ok;
  (void)mic1;
  (void)mic2;
#endif
#endif
}
#endif

#if STACKCHAN_HAS_SR_WAKE_DIRECT
void WakeSrDirectTask(void* pv) {
  (void)pv;
  gWakeSrProbe.beginAttempts++;
  Serial.println(F("[sr_wake_direct] task_enter=1"));

  auto micConfig = M5.Mic.config();
  micConfig.sample_rate = 16000;
  micConfig.magnification = STACKCHAN_SR_WAKE_DIRECT_MIC_MAGNIFICATION;
  micConfig.noise_filter_level = STACKCHAN_SR_WAKE_MIC_NOISE_FILTER_LEVEL;
  micConfig.task_priority = STACKCHAN_SR_WAKE_MIC_TASK_PRIORITY;
  micConfig.task_pinned_core = STACKCHAN_SR_WAKE_MIC_TASK_CORE;
#if STACKCHAN_SR_WAKE_DIRECT_STEREO
  micConfig.input_channel = m5::input_channel_t::input_stereo;
  micConfig.stereo = true;
#elif STACKCHAN_SR_WAKE_DIRECT_MIC_INPUT_STEREO
  micConfig.input_channel = m5::input_channel_t::input_stereo;
  micConfig.stereo = true;
#elif STACKCHAN_SR_WAKE_DIRECT_MONO_CHANNEL
  micConfig.input_channel = m5::input_channel_t::input_only_left;
  micConfig.stereo = false;
#else
  micConfig.input_channel = m5::input_channel_t::input_only_right;
  micConfig.stereo = false;
#endif
  M5.Mic.config(micConfig);
  if (!M5.Mic.begin()) {
    gWakeSrProbe.beginFailures++;
    copyWakeSrError("sr_direct_mic_begin_failed");
    Serial.println(F("[sr_wake_direct] ready=0 error=mic_begin_failed"));
    vTaskDelete(nullptr);
    return;
  }
  gWakeSrProbe.micReady = true;

  srmodel_list_t* models = esp_srmodel_init("model");
  if (models == nullptr || models->num <= 0) {
    gWakeSrProbe.beginFailures++;
    copyWakeSrError("sr_direct_model_init_failed");
    Serial.println(F("[sr_wake_direct] ready=0 error=model_init_failed"));
    vTaskDelete(nullptr);
    return;
  }

  char* modelName = chooseWakeSrModel(models);
  if (modelName == nullptr) {
    gWakeSrProbe.beginFailures++;
    copyWakeSrError("sr_direct_model_not_found");
    Serial.println(F("[sr_wake_direct] ready=0 error=model_not_found"));
    esp_srmodel_deinit(models);
    vTaskDelete(nullptr);
    return;
  }
  copyWakeSrString(gWakeSrProbe.modelName, sizeof(gWakeSrProbe.modelName), modelName);

  const esp_wn_iface_t* wakeNet = esp_wn_handle_from_name(modelName);
  if (wakeNet == nullptr) {
    gWakeSrProbe.beginFailures++;
    copyWakeSrError("sr_direct_iface_not_found");
    Serial.println(F("[sr_wake_direct] ready=0 error=iface_not_found"));
    esp_srmodel_deinit(models);
    vTaskDelete(nullptr);
    return;
  }

  model_iface_data_t* wakeData = wakeNet->create(modelName, STACKCHAN_SR_WAKE_DIRECT_DET_MODE);
  if (wakeData == nullptr) {
    gWakeSrProbe.beginFailures++;
    copyWakeSrError("sr_direct_create_failed");
    Serial.println(F("[sr_wake_direct] ready=0 error=create_failed"));
    esp_srmodel_deinit(models);
    vTaskDelete(nullptr);
    return;
  }

  const int chunkSamples = wakeNet->get_samp_chunksize(wakeData);
  int channelCount = wakeNet->get_channel_num(wakeData);
  if (channelCount <= 0) {
    channelCount = STACKCHAN_SR_WAKE_DIRECT_STEREO ? 2 : 1;
  }
  const int sampleRate = wakeNet->get_samp_rate(wakeData);
  if (chunkSamples <= 0 || channelCount <= 0 || sampleRate <= 0) {
    gWakeSrProbe.beginFailures++;
    copyWakeSrError("sr_direct_bad_model_shape");
    Serial.println(F("[sr_wake_direct] ready=0 error=bad_model_shape"));
    wakeNet->destroy(wakeData);
    esp_srmodel_deinit(models);
    vTaskDelete(nullptr);
    return;
  }

  const size_t totalSamples = static_cast<size_t>(chunkSamples) * static_cast<size_t>(channelCount);
  size_t recordSamples = totalSamples;
#if STACKCHAN_SR_WAKE_DIRECT_RECORD_SAMPLES > 0
  if (static_cast<size_t>(STACKCHAN_SR_WAKE_DIRECT_RECORD_SAMPLES) < totalSamples) {
    recordSamples = static_cast<size_t>(STACKCHAN_SR_WAKE_DIRECT_RECORD_SAMPLES);
  }
#endif
  int16_t* audioBuf = static_cast<int16_t*>(
      heap_caps_malloc(totalSamples * sizeof(int16_t), MALLOC_CAP_INTERNAL | MALLOC_CAP_8BIT));
  if (audioBuf == nullptr) {
    audioBuf = static_cast<int16_t*>(
        heap_caps_malloc(totalSamples * sizeof(int16_t), MALLOC_CAP_8BIT));
  }
  if (audioBuf == nullptr) {
    gWakeSrProbe.beginFailures++;
    copyWakeSrError("sr_direct_audio_alloc_failed");
    Serial.println(F("[sr_wake_direct] ready=0 error=audio_alloc_failed"));
    wakeNet->destroy(wakeData);
    esp_srmodel_deinit(models);
    vTaskDelete(nullptr);
    return;
  }
  int16_t* recordBuf = audioBuf;
  if (recordSamples < totalSamples) {
    recordBuf = static_cast<int16_t*>(
        heap_caps_malloc(recordSamples * sizeof(int16_t), MALLOC_CAP_INTERNAL | MALLOC_CAP_8BIT));
    if (recordBuf == nullptr) {
      recordBuf = static_cast<int16_t*>(
          heap_caps_malloc(recordSamples * sizeof(int16_t), MALLOC_CAP_8BIT));
    }
    if (recordBuf == nullptr) {
      recordSamples = totalSamples;
      recordBuf = audioBuf;
    }
  }

  char* wakeWord = esp_srmodel_get_wake_words(models, modelName);
  copyWakeSrString(gWakeSrProbe.wakeWord, sizeof(gWakeSrProbe.wakeWord), wakeWord);
  gWakeSrProbe.chunkSamples = static_cast<uint32_t>(chunkSamples);
  gWakeSrProbe.recordSamples = static_cast<uint32_t>(recordSamples);
  gWakeSrProbe.audioChannels = static_cast<uint32_t>(channelCount);
  gWakeSrProbe.sampleRate = static_cast<uint32_t>(sampleRate);
  gWakeSrProbe.detectMode = static_cast<uint32_t>(STACKCHAN_SR_WAKE_DIRECT_DET_MODE);
  gWakeSrProbe.micMagnification = STACKCHAN_SR_WAKE_DIRECT_MIC_MAGNIFICATION;
  gWakeSrProbe.monoChannel = STACKCHAN_SR_WAKE_DIRECT_MONO_CHANNEL;
  gWakeSrProbe.micInputStereo = STACKCHAN_SR_WAKE_DIRECT_MIC_INPUT_STEREO != 0;
  gWakeSrProbe.micTaskCore = STACKCHAN_SR_WAKE_MIC_TASK_CORE;
  gWakeSrProbe.micTaskPriority = STACKCHAN_SR_WAKE_MIC_TASK_PRIORITY;
  gWakeSrProbe.micNoiseFilterLevel = STACKCHAN_SR_WAKE_MIC_NOISE_FILTER_LEVEL;
  gWakeSrProbe.stereo = STACKCHAN_SR_WAKE_DIRECT_STEREO != 0;
  gWakeSrProbe.audioGainQ8 = STACKCHAN_SR_WAKE_DIRECT_GAIN_Q8;
  gWakeSrProbe.srReady = true;
  gWakeSrProbe.taskStarted = true;
  copyWakeSrError("");
  Serial.print(F("[sr_wake_direct] ready=1 model="));
  Serial.print(gWakeSrProbe.modelName);
  Serial.print(F(" wake_word=\""));
  Serial.print(gWakeSrProbe.wakeWord);
  Serial.print(F("\" chunk_samples="));
  Serial.print(gWakeSrProbe.chunkSamples);
  Serial.print(F(" record_samples="));
  Serial.print(gWakeSrProbe.recordSamples);
  Serial.print(F(" channels="));
  Serial.print(gWakeSrProbe.audioChannels);
  Serial.print(F(" sample_rate="));
  Serial.print(gWakeSrProbe.sampleRate);
  Serial.print(F(" det_mode="));
  Serial.print(gWakeSrProbe.detectMode);
  Serial.print(F(" mic_mag="));
  Serial.print(gWakeSrProbe.micMagnification);
  Serial.print(F(" mono_channel="));
  Serial.print(gWakeSrProbe.monoChannel);
  Serial.print(F(" mic_input_stereo="));
  Serial.print(gWakeSrProbe.micInputStereo ? 1 : 0);
  Serial.print(F(" stereo="));
  Serial.print(gWakeSrProbe.stereo ? 1 : 0);
  Serial.print(F(" gain_q8="));
  Serial.print(gWakeSrProbe.audioGainQ8);
  Serial.print(F(" task_core="));
  Serial.print(STACKCHAN_SR_WAKE_DIRECT_TASK_CORE);
  Serial.print(F(" priority="));
  Serial.print(STACKCHAN_SR_WAKE_DIRECT_TASK_PRIORITY);
  Serial.print(F(" mic_task_core="));
  Serial.print(STACKCHAN_SR_WAKE_MIC_TASK_CORE);
  Serial.print(F(" mic_task_priority="));
  Serial.print(STACKCHAN_SR_WAKE_MIC_TASK_PRIORITY);
  Serial.print(F(" mic_noise_filter="));
  Serial.println(STACKCHAN_SR_WAKE_MIC_NOISE_FILTER_LEVEL);

  uint32_t lastDetectionMs = 0;
  size_t bufferedSamples = 0;
  auto runWakeDetect = [&]() {
    const uint32_t detectStartUs = micros();
    const int32_t rawResult = static_cast<int32_t>(wakeNet->detect(wakeData, audioBuf));
    const uint32_t detectUs = micros() - detectStartUs;
    gWakeSrProbe.lastDetectResult = rawResult;
    gWakeSrProbe.detectCalls++;
    gWakeSrProbe.detectAvgUs =
        gWakeSrProbe.detectCalls == 1 ? detectUs : ((gWakeSrProbe.detectAvgUs * 7u) + detectUs) / 8u;
    if (detectUs > gWakeSrProbe.detectMaxUs) {
      gWakeSrProbe.detectMaxUs = detectUs;
    }

    if (rawResult != static_cast<int32_t>(WAKENET_NO_DETECT)) {
      const uint32_t nowMs = millis();
      gWakeSrProbe.detectNonzero++;
      Serial.print(F("[sr_wake_direct] result="));
      Serial.print(rawResult);
      Serial.print(F(" peak="));
      Serial.print(gWakeSrProbe.audioPeak);
      Serial.print(F(" peak_l="));
      Serial.print(gWakeSrProbe.audioPeakLeft);
      Serial.print(F(" peak_r="));
      Serial.print(gWakeSrProbe.audioPeakRight);
      Serial.print(F(" at_ms="));
      Serial.println(nowMs);
      if (rawResult == static_cast<int32_t>(WAKENET_CHANNEL_VERIFIED)) {
        gWakeSrProbe.detectChannelVerified++;
      }
      if (rawResult > 0 &&
          (lastDetectionMs == 0 || nowMs - lastDetectionMs >= STACKCHAN_SR_WAKE_DIRECT_COOLDOWN_MS)) {
        lastDetectionMs = nowMs;
        queueWakeSrDirectDetection(nowMs);
        wakeNet->clean(wakeData);
      }
    }
  };

  while (true) {
    if (!M5.Mic.record(
            recordBuf,
            recordSamples,
            static_cast<uint32_t>(sampleRate),
            STACKCHAN_SR_WAKE_DIRECT_STEREO != 0)) {
      gWakeSrProbe.recordDrops++;
      vTaskDelay(pdMS_TO_TICKS(1));
      continue;
    }

    conditionWakeSrDirectAudio(recordBuf, static_cast<int>(recordSamples), channelCount);
    gWakeSrProbe.recordOk++;
    gWakeSrProbe.samplesFed += static_cast<uint32_t>(recordSamples);
    gWakeSrProbe.lastRecordMs = millis();

    if (recordBuf == audioBuf) {
      runWakeDetect();
    } else {
      size_t copiedSamples = 0;
      while (copiedSamples < recordSamples) {
        const size_t remainingBufferSamples = totalSamples - bufferedSamples;
        const size_t remainingRecordSamples = recordSamples - copiedSamples;
        const size_t copySamples =
            remainingRecordSamples < remainingBufferSamples ? remainingRecordSamples : remainingBufferSamples;
        memcpy(
            audioBuf + bufferedSamples,
            recordBuf + copiedSamples,
            copySamples * sizeof(int16_t));
        bufferedSamples += copySamples;
        copiedSamples += copySamples;
        if (bufferedSamples >= totalSamples) {
          runWakeDetect();
          bufferedSamples = 0;
        }
      }
    }

    vTaskDelay(pdMS_TO_TICKS(1));
  }
}

void pollWakeSrDirect(uint32_t nowMs) {
  const uint32_t pending = takeWakeSrDirectPendingDetections();
  for (uint32_t i = 0; i < pending; ++i) {
    RobotEvent event;
    event.type = EventType::WakeWord;
    event.timestampMs = nowMs;
    event.strength = 1.0f;
    applyWakeEventFromLocalSource(
        event,
        CharacterMode::Listen,
        F("sr_wake_direct"),
        gWakeSrProbe.wakeDetections,
        nowMs);
    gWakeSrProbe.wakeEventsApplied++;
    Serial.print(F("[sr_wake_direct] event=wake_word applied=1 detections="));
    Serial.print(gWakeSrProbe.wakeDetections);
    Serial.print(F(" applied_total="));
    Serial.print(gWakeSrProbe.wakeEventsApplied);
    Serial.print(F(" at_ms="));
    Serial.println(nowMs);
  }
}

bool startWakeSrDirect() {
  Serial.print(F("[sr_wake_direct] start_request=1 core="));
  Serial.print(STACKCHAN_SR_WAKE_DIRECT_TASK_CORE);
  Serial.print(F(" priority="));
  Serial.println(STACKCHAN_SR_WAKE_DIRECT_TASK_PRIORITY);
  const BaseType_t ok = xTaskCreatePinnedToCore(
      WakeSrDirectTask,
      "WakeSrDirect",
      8192,
      nullptr,
      STACKCHAN_SR_WAKE_DIRECT_TASK_PRIORITY,
      &gWakeSrTaskHandle,
      STACKCHAN_SR_WAKE_DIRECT_TASK_CORE);
  if (ok != pdPASS) {
    gWakeSrProbe.beginFailures++;
    copyWakeSrError("sr_direct_task_create_failed");
    Serial.println(F("[sr_wake_direct] ready=0 error=task_create_failed"));
    return false;
  }
  Serial.println(F("[sr_wake_direct] task_created=1"));
  return true;
}
#else
void pollWakeSrDirect(uint32_t nowMs) {
  (void)nowMs;
}

bool startWakeSrDirect() {
#if STACKCHAN_ENABLE_SR_WAKE_DIRECT
  gWakeSrProbe.beginFailures++;
  copyWakeSrError("sr_direct_not_compiled");
  Serial.println(F("[sr_wake_direct] ready=0 error=not_compiled"));
  return false;
#else
  return true;
#endif
}
#endif

#if STACKCHAN_HAS_SR_WAKE_AFE_LITE
uint32_t takeWakeSrAfeLitePendingDetections() {
  portENTER_CRITICAL(&gWakeSrAfeLiteMux);
  const uint32_t pending = gWakeSrAfeLitePendingDetections;
  gWakeSrAfeLitePendingDetections = 0;
  portEXIT_CRITICAL(&gWakeSrAfeLiteMux);
  return pending;
}

void queueWakeSrAfeLiteDetection(uint32_t nowMs) {
  portENTER_CRITICAL(&gWakeSrAfeLiteMux);
  gWakeSrAfeLitePendingDetections = gWakeSrAfeLitePendingDetections + 1;
  gWakeSrProbe.wakeDetections++;
  gWakeSrProbe.lastWakeMs = nowMs;
  portEXIT_CRITICAL(&gWakeSrAfeLiteMux);
}

int16_t clampWakeSrAfeLiteSample(int32_t sample) {
  if (sample > 32767) {
    return 32767;
  }
  if (sample < -32768) {
    return -32768;
  }
  return static_cast<int16_t>(sample);
}

void conditionWakeSrAfeLiteAudio(int16_t* audioBuf, int sampleCount, int channelCount) {
  uint32_t peak = 0;
  uint32_t meanAbs = 0;
  uint32_t channelPeak[2] = {0, 0};
  uint32_t channelMeanAbs[2] = {0, 0};
  uint32_t channelSamples[2] = {0, 0};
  uint32_t clips = 0;
  constexpr int32_t kGainQ8 = STACKCHAN_SR_WAKE_AFE_LITE_GAIN_Q8;
  for (int i = 0; i < sampleCount; ++i) {
    int32_t sample = audioBuf[i];
    if (kGainQ8 != 256) {
      sample = (sample * kGainQ8) / 256;
      if (sample > 32767 || sample < -32768) {
        clips++;
      }
      audioBuf[i] = clampWakeSrAfeLiteSample(sample);
      sample = audioBuf[i];
    }
    const uint32_t absSample = sample < 0 ? static_cast<uint32_t>(-sample) : static_cast<uint32_t>(sample);
    if (absSample > peak) {
      peak = absSample;
    }
    meanAbs += absSample;
    const int channel = channelCount >= 2 ? (i & 1) : 0;
    if (absSample > channelPeak[channel]) {
      channelPeak[channel] = absSample;
    }
    channelMeanAbs[channel] += absSample;
    channelSamples[channel]++;
  }
  gWakeSrProbe.audioPeak = peak;
  if (peak > gWakeSrProbe.audioPeakMax) {
    gWakeSrProbe.audioPeakMax = peak;
  }
  gWakeSrProbe.audioMeanAbs = sampleCount > 0 ? meanAbs / static_cast<uint32_t>(sampleCount) : 0;
  if (gWakeSrProbe.audioMeanAbs > gWakeSrProbe.audioMeanAbsMax) {
    gWakeSrProbe.audioMeanAbsMax = gWakeSrProbe.audioMeanAbs;
  }
  updateWakeSrAudioWindow(peak, gWakeSrProbe.audioMeanAbs, millis());
  gWakeSrProbe.audioPeakLeft = channelPeak[0];
  gWakeSrProbe.audioMeanAbsLeft =
      channelSamples[0] > 0 ? channelMeanAbs[0] / channelSamples[0] : 0;
  gWakeSrProbe.audioPeakRight = channelPeak[1];
  gWakeSrProbe.audioMeanAbsRight =
      channelSamples[1] > 0 ? channelMeanAbs[1] / channelSamples[1] : 0;
  gWakeSrProbe.audioClips += clips;
}

void WakeSrAfeLiteFeedTask(void* pv) {
  auto* runtime = static_cast<WakeSrAfeLiteRuntime*>(pv);
  if (runtime == nullptr || runtime->afeHandle == nullptr || runtime->afeData == nullptr) {
    gWakeSrProbe.beginFailures++;
    copyWakeSrError("sr_afe_feed_bad_runtime");
    Serial.println(F("[sr_wake_afe] feed_ready=0 error=bad_runtime"));
    vTaskDelete(nullptr);
    return;
  }

  const size_t totalSamples =
      static_cast<size_t>(runtime->feedChunkSamples) * static_cast<size_t>(runtime->feedChannels);
  int16_t* audioBuf = static_cast<int16_t*>(
      heap_caps_malloc(totalSamples * sizeof(int16_t), MALLOC_CAP_INTERNAL | MALLOC_CAP_8BIT));
  if (audioBuf == nullptr) {
    audioBuf = static_cast<int16_t*>(
        heap_caps_malloc(totalSamples * sizeof(int16_t), MALLOC_CAP_SPIRAM | MALLOC_CAP_8BIT));
  }
  if (audioBuf == nullptr) {
    gWakeSrProbe.beginFailures++;
    copyWakeSrError("sr_afe_audio_alloc_failed");
    Serial.println(F("[sr_wake_afe] feed_ready=0 error=audio_alloc_failed"));
    vTaskDelete(nullptr);
    return;
  }

  Serial.print(F("[sr_wake_afe] feed_ready=1 total_samples="));
  Serial.print(static_cast<uint32_t>(totalSamples));
  Serial.print(F(" channels="));
  Serial.print(runtime->feedChannels);
  Serial.print(F(" core="));
  Serial.print(STACKCHAN_SR_WAKE_AFE_LITE_FEED_TASK_CORE);
  Serial.print(F(" priority="));
  Serial.println(STACKCHAN_SR_WAKE_AFE_LITE_FEED_TASK_PRIORITY);

  while (true) {
    const size_t recordSamples =
        STACKCHAN_SR_WAKE_AFE_LITE_RECORD_SAMPLES > 0 &&
                STACKCHAN_SR_WAKE_AFE_LITE_RECORD_SAMPLES < totalSamples
            ? static_cast<size_t>(STACKCHAN_SR_WAKE_AFE_LITE_RECORD_SAMPLES)
            : totalSamples;
    if (recordSamples < totalSamples) {
      memset(audioBuf, 0, totalSamples * sizeof(int16_t));
    }
    if (!M5.Mic.record(
            audioBuf,
            recordSamples,
            static_cast<uint32_t>(runtime->sampleRate),
            runtime->feedChannels > 1)) {
      gWakeSrProbe.recordDrops++;
      vTaskDelay(pdMS_TO_TICKS(1));
      continue;
    }

    conditionWakeSrAfeLiteAudio(audioBuf, static_cast<int>(totalSamples), runtime->feedChannels);
    runtime->afeHandle->feed(runtime->afeData, audioBuf);
    gWakeSrProbe.recordOk++;
    gWakeSrProbe.samplesFed += static_cast<uint32_t>(totalSamples);
    gWakeSrProbe.lastRecordMs = millis();
    vTaskDelay(pdMS_TO_TICKS(1));
  }
}

void WakeSrAfeLiteFetchTask(void* pv) {
  (void)pv;
  gWakeSrProbe.beginAttempts++;
  Serial.println(F("[sr_wake_afe] task_enter=1"));

  auto micConfig = M5.Mic.config();
  micConfig.sample_rate = 16000;
  micConfig.magnification = STACKCHAN_SR_WAKE_AFE_LITE_MIC_MAGNIFICATION;
  micConfig.noise_filter_level = STACKCHAN_SR_WAKE_MIC_NOISE_FILTER_LEVEL;
  micConfig.task_priority = STACKCHAN_SR_WAKE_MIC_TASK_PRIORITY;
  micConfig.task_pinned_core = STACKCHAN_SR_WAKE_MIC_TASK_CORE;
#if STACKCHAN_SR_WAKE_AFE_LITE_STEREO
  micConfig.input_channel = m5::input_channel_t::input_stereo;
  micConfig.stereo = true;
  const char* inputFormat = "MM";
#elif STACKCHAN_SR_WAKE_AFE_LITE_MIC_INPUT_STEREO
  micConfig.input_channel = m5::input_channel_t::input_stereo;
  micConfig.stereo = true;
  const char* inputFormat = "M";
#elif STACKCHAN_SR_WAKE_AFE_LITE_MONO_CHANNEL
  micConfig.input_channel = m5::input_channel_t::input_only_left;
  micConfig.stereo = false;
  const char* inputFormat = "M";
#else
  micConfig.input_channel = m5::input_channel_t::input_only_right;
  micConfig.stereo = false;
  const char* inputFormat = "M";
#endif
  M5.Mic.config(micConfig);
  if (!M5.Mic.begin()) {
    gWakeSrProbe.beginFailures++;
    copyWakeSrError("sr_afe_mic_begin_failed");
    Serial.println(F("[sr_wake_afe] ready=0 error=mic_begin_failed"));
    vTaskDelete(nullptr);
    return;
  }
  gWakeSrProbe.micReady = true;

  gWakeSrAfeLiteRuntime.models = esp_srmodel_init("model");
  if (gWakeSrAfeLiteRuntime.models == nullptr || gWakeSrAfeLiteRuntime.models->num <= 0) {
    gWakeSrProbe.beginFailures++;
    copyWakeSrError("sr_afe_model_init_failed");
    Serial.println(F("[sr_wake_afe] ready=0 error=model_init_failed"));
    vTaskDelete(nullptr);
    return;
  }

  char* modelName = chooseWakeSrModel(gWakeSrAfeLiteRuntime.models);
  if (modelName == nullptr) {
    gWakeSrProbe.beginFailures++;
    copyWakeSrError("sr_afe_model_not_found");
    Serial.println(F("[sr_wake_afe] ready=0 error=model_not_found"));
    vTaskDelete(nullptr);
    return;
  }
  copyWakeSrString(gWakeSrProbe.modelName, sizeof(gWakeSrProbe.modelName), modelName);
  char* wakeWord = esp_srmodel_get_wake_words(gWakeSrAfeLiteRuntime.models, modelName);
  copyWakeSrString(gWakeSrProbe.wakeWord, sizeof(gWakeSrProbe.wakeWord), wakeWord);

  afe_config_t* afeConfig = afe_config_init(
      inputFormat,
      gWakeSrAfeLiteRuntime.models,
      AFE_TYPE_SR,
      STACKCHAN_SR_WAKE_AFE_LITE_HIGH_PERF ? AFE_MODE_HIGH_PERF : AFE_MODE_LOW_COST);
  if (afeConfig == nullptr) {
    gWakeSrProbe.beginFailures++;
    copyWakeSrError("sr_afe_config_failed");
    Serial.println(F("[sr_wake_afe] ready=0 error=config_failed"));
    vTaskDelete(nullptr);
    return;
  }

  afeConfig->wakenet_init = true;
  afeConfig->wakenet_model_name = modelName;
  afeConfig->wakenet_model_name_2 = nullptr;
  afeConfig->wakenet_mode = STACKCHAN_SR_WAKE_AFE_LITE_DET_MODE;
#if STACKCHAN_SR_WAKE_AFE_LITE_DISABLE_EXTRA_ALGOS
  afeConfig->aec_init = false;
  afeConfig->se_init = false;
  afeConfig->ns_init = false;
  afeConfig->vad_init = false;
  afeConfig->agc_init = true;
  afeConfig->agc_mode = AFE_AGC_MODE_WAKENET;
#endif
  afeConfig->afe_perferred_core = STACKCHAN_SR_WAKE_AFE_LITE_AFE_TASK_CORE;
  afeConfig->afe_perferred_priority = STACKCHAN_SR_WAKE_AFE_LITE_AFE_TASK_PRIORITY;
  afeConfig->memory_alloc_mode = AFE_MEMORY_ALLOC_MORE_PSRAM;

  gWakeSrAfeLiteRuntime.afeHandle = esp_afe_handle_from_config(afeConfig);
  if (gWakeSrAfeLiteRuntime.afeHandle == nullptr) {
    gWakeSrProbe.beginFailures++;
    copyWakeSrError("sr_afe_handle_failed");
    Serial.println(F("[sr_wake_afe] ready=0 error=handle_failed"));
    afe_config_free(afeConfig);
    vTaskDelete(nullptr);
    return;
  }

  gWakeSrAfeLiteRuntime.afeData = gWakeSrAfeLiteRuntime.afeHandle->create_from_config(afeConfig);
  afe_config_free(afeConfig);
  if (gWakeSrAfeLiteRuntime.afeData == nullptr) {
    gWakeSrProbe.beginFailures++;
    copyWakeSrError("sr_afe_create_failed");
    Serial.println(F("[sr_wake_afe] ready=0 error=create_failed"));
    vTaskDelete(nullptr);
    return;
  }

  gWakeSrAfeLiteRuntime.feedChunkSamples =
      gWakeSrAfeLiteRuntime.afeHandle->get_feed_chunksize(gWakeSrAfeLiteRuntime.afeData);
  gWakeSrAfeLiteRuntime.feedChannels =
      gWakeSrAfeLiteRuntime.afeHandle->get_feed_channel_num(gWakeSrAfeLiteRuntime.afeData);
  gWakeSrAfeLiteRuntime.sampleRate =
      gWakeSrAfeLiteRuntime.afeHandle->get_samp_rate(gWakeSrAfeLiteRuntime.afeData);
  const int fetchChunkSamples =
      gWakeSrAfeLiteRuntime.afeHandle->get_fetch_chunksize(gWakeSrAfeLiteRuntime.afeData);
  if (gWakeSrAfeLiteRuntime.feedChunkSamples <= 0 || gWakeSrAfeLiteRuntime.feedChannels <= 0 ||
      gWakeSrAfeLiteRuntime.sampleRate <= 0 || fetchChunkSamples <= 0) {
    gWakeSrProbe.beginFailures++;
    copyWakeSrError("sr_afe_bad_shape");
    Serial.println(F("[sr_wake_afe] ready=0 error=bad_shape"));
    vTaskDelete(nullptr);
    return;
  }

  gWakeSrProbe.chunkSamples = static_cast<uint32_t>(gWakeSrAfeLiteRuntime.feedChunkSamples);
  gWakeSrProbe.recordSamples =
      STACKCHAN_SR_WAKE_AFE_LITE_RECORD_SAMPLES > 0 &&
              STACKCHAN_SR_WAKE_AFE_LITE_RECORD_SAMPLES < gWakeSrAfeLiteRuntime.feedChunkSamples
          ? static_cast<uint32_t>(STACKCHAN_SR_WAKE_AFE_LITE_RECORD_SAMPLES)
          : static_cast<uint32_t>(gWakeSrAfeLiteRuntime.feedChunkSamples);
  gWakeSrProbe.audioChannels = static_cast<uint32_t>(gWakeSrAfeLiteRuntime.feedChannels);
  gWakeSrProbe.sampleRate = static_cast<uint32_t>(gWakeSrAfeLiteRuntime.sampleRate);
  gWakeSrProbe.detectMode = static_cast<uint32_t>(STACKCHAN_SR_WAKE_AFE_LITE_DET_MODE);
  gWakeSrProbe.micMagnification = STACKCHAN_SR_WAKE_AFE_LITE_MIC_MAGNIFICATION;
  gWakeSrProbe.monoChannel = STACKCHAN_SR_WAKE_AFE_LITE_MONO_CHANNEL;
  gWakeSrProbe.micInputStereo = STACKCHAN_SR_WAKE_AFE_LITE_MIC_INPUT_STEREO != 0;
  gWakeSrProbe.stereo = STACKCHAN_SR_WAKE_AFE_LITE_STEREO != 0;
  gWakeSrProbe.audioGainQ8 = STACKCHAN_SR_WAKE_AFE_LITE_GAIN_Q8;

  const BaseType_t feedOk = xTaskCreatePinnedToCore(
      WakeSrAfeLiteFeedTask,
      "WakeSrAfeFeed",
      4096,
      &gWakeSrAfeLiteRuntime,
      STACKCHAN_SR_WAKE_AFE_LITE_FEED_TASK_PRIORITY,
      &gWakeSrFeedTaskHandle,
      STACKCHAN_SR_WAKE_AFE_LITE_FEED_TASK_CORE);
  if (feedOk != pdPASS) {
    gWakeSrProbe.beginFailures++;
    copyWakeSrError("sr_afe_feed_task_create_failed");
    Serial.println(F("[sr_wake_afe] ready=0 error=feed_task_create_failed"));
    vTaskDelete(nullptr);
    return;
  }

  gWakeSrProbe.srReady = true;
  gWakeSrProbe.taskStarted = true;
  copyWakeSrError("");
  Serial.print(F("[sr_wake_afe] ready=1 model="));
  Serial.print(gWakeSrProbe.modelName);
  Serial.print(F(" wake_word=\""));
  Serial.print(gWakeSrProbe.wakeWord);
  Serial.print(F("\" input_format="));
  Serial.print(inputFormat);
  Serial.print(F(" feed_chunk="));
  Serial.print(gWakeSrProbe.chunkSamples);
  Serial.print(F(" fetch_chunk="));
  Serial.print(fetchChunkSamples);
  Serial.print(F(" channels="));
  Serial.print(gWakeSrProbe.audioChannels);
  Serial.print(F(" sample_rate="));
  Serial.print(gWakeSrProbe.sampleRate);
  Serial.print(F(" det_mode="));
  Serial.print(gWakeSrProbe.detectMode);
  Serial.print(F(" mic_mag="));
  Serial.print(gWakeSrProbe.micMagnification);
  Serial.print(F(" mono_channel="));
  Serial.print(gWakeSrProbe.monoChannel);
  Serial.print(F(" mic_input_stereo="));
  Serial.print(gWakeSrProbe.micInputStereo ? 1 : 0);
  Serial.print(F(" stereo="));
  Serial.print(gWakeSrProbe.stereo ? 1 : 0);
  Serial.print(F(" afe_core="));
  Serial.print(STACKCHAN_SR_WAKE_AFE_LITE_AFE_TASK_CORE);
  Serial.print(F(" afe_priority="));
  Serial.print(STACKCHAN_SR_WAKE_AFE_LITE_AFE_TASK_PRIORITY);
  Serial.print(F(" fetch_core="));
  Serial.print(STACKCHAN_SR_WAKE_AFE_LITE_FETCH_TASK_CORE);
  Serial.print(F(" fetch_priority="));
  Serial.println(STACKCHAN_SR_WAKE_AFE_LITE_FETCH_TASK_PRIORITY);

  uint32_t lastDetectionMs = 0;
  uint32_t fetchFailCount = 0;
  while (true) {
    const uint32_t fetchStartUs = micros();
    afe_fetch_result_t* result = gWakeSrAfeLiteRuntime.afeHandle->fetch(gWakeSrAfeLiteRuntime.afeData);
    const uint32_t fetchUs = micros() - fetchStartUs;
    if (result == nullptr || result->ret_value == ESP_FAIL) {
      fetchFailCount++;
      gWakeSrProbe.recordDrops++;
      if ((fetchFailCount % 100u) == 1u) {
        Serial.print(F("[sr_wake_afe] fetch_failed count="));
        Serial.println(fetchFailCount);
      }
      vTaskDelay(pdMS_TO_TICKS(1));
      continue;
    }

    const wakenet_state_t wakeState = result->wakeup_state;
    gWakeSrProbe.lastDetectResult = static_cast<int32_t>(wakeState);
    gWakeSrProbe.detectCalls++;
    gWakeSrProbe.detectAvgUs =
        gWakeSrProbe.detectCalls == 1 ? fetchUs : ((gWakeSrProbe.detectAvgUs * 7u) + fetchUs) / 8u;
    if (fetchUs > gWakeSrProbe.detectMaxUs) {
      gWakeSrProbe.detectMaxUs = fetchUs;
    }

    if (wakeState != WAKENET_NO_DETECT) {
      const uint32_t nowMs = millis();
      gWakeSrProbe.detectNonzero++;
      if (wakeState == WAKENET_CHANNEL_VERIFIED) {
        gWakeSrProbe.detectChannelVerified++;
      }
      Serial.print(F("[sr_wake_afe] result="));
      Serial.print(static_cast<int32_t>(wakeState));
      Serial.print(F(" wake_index="));
      Serial.print(result->wake_word_index);
      Serial.print(F(" channel="));
      Serial.print(result->trigger_channel_id);
      Serial.print(F(" volume_db="));
      Serial.print(result->data_volume, 2);
      Serial.print(F(" peak="));
      Serial.print(gWakeSrProbe.audioPeak);
      Serial.print(F(" ring_free="));
      Serial.print(result->ringbuff_free_pct, 2);
      Serial.print(F(" at_ms="));
      Serial.println(nowMs);

      const bool isWake = wakeState == WAKENET_DETECTED || wakeState == WAKENET_CHANNEL_VERIFIED;
      if (isWake && (lastDetectionMs == 0 || nowMs - lastDetectionMs >= STACKCHAN_SR_WAKE_AFE_LITE_COOLDOWN_MS)) {
        lastDetectionMs = nowMs;
        queueWakeSrAfeLiteDetection(nowMs);
        if (gWakeSrAfeLiteRuntime.afeHandle->reset_buffer != nullptr) {
          gWakeSrAfeLiteRuntime.afeHandle->reset_buffer(gWakeSrAfeLiteRuntime.afeData);
        }
      }
    }

    vTaskDelay(pdMS_TO_TICKS(1));
  }
}

void pollWakeSrAfeLite(uint32_t nowMs) {
  const uint32_t pending = takeWakeSrAfeLitePendingDetections();
  for (uint32_t i = 0; i < pending; ++i) {
    RobotEvent event;
    event.type = EventType::WakeWord;
    event.timestampMs = nowMs;
    event.strength = 1.0f;
    applyWakeEventFromLocalSource(
        event,
        CharacterMode::Listen,
        F("sr_wake_afe"),
        gWakeSrProbe.wakeDetections,
        nowMs);
    gWakeSrProbe.wakeEventsApplied++;
    Serial.print(F("[sr_wake_afe] event=wake_word applied=1 detections="));
    Serial.print(gWakeSrProbe.wakeDetections);
    Serial.print(F(" applied_total="));
    Serial.print(gWakeSrProbe.wakeEventsApplied);
    Serial.print(F(" at_ms="));
    Serial.println(nowMs);
  }
}

bool startWakeSrAfeLite() {
  Serial.print(F("[sr_wake_afe] start_request=1 feed_core="));
  Serial.print(STACKCHAN_SR_WAKE_AFE_LITE_FEED_TASK_CORE);
  Serial.print(F(" feed_priority="));
  Serial.print(STACKCHAN_SR_WAKE_AFE_LITE_FEED_TASK_PRIORITY);
  Serial.print(F(" fetch_core="));
  Serial.print(STACKCHAN_SR_WAKE_AFE_LITE_FETCH_TASK_CORE);
  Serial.print(F(" fetch_priority="));
  Serial.println(STACKCHAN_SR_WAKE_AFE_LITE_FETCH_TASK_PRIORITY);
  const BaseType_t ok = xTaskCreatePinnedToCore(
      WakeSrAfeLiteFetchTask,
      "WakeSrAfeFetch",
      8192,
      nullptr,
      STACKCHAN_SR_WAKE_AFE_LITE_FETCH_TASK_PRIORITY,
      &gWakeSrTaskHandle,
      STACKCHAN_SR_WAKE_AFE_LITE_FETCH_TASK_CORE);
  if (ok != pdPASS) {
    gWakeSrProbe.beginFailures++;
    copyWakeSrError("sr_afe_task_create_failed");
    Serial.println(F("[sr_wake_afe] ready=0 error=task_create_failed"));
    return false;
  }
  Serial.println(F("[sr_wake_afe] task_created=1"));
  return true;
}
#else
void pollWakeSrAfeLite(uint32_t nowMs) {
  (void)nowMs;
}

bool startWakeSrAfeLite() {
#if STACKCHAN_ENABLE_SR_WAKE_AFE_LITE
  gWakeSrProbe.beginFailures++;
  copyWakeSrError("sr_afe_not_compiled");
  Serial.println(F("[sr_wake_afe] ready=0 error=not_compiled"));
  return false;
#else
  return true;
#endif
}
#endif

#if STACKCHAN_HAS_MWW_WAKE_PROBE
uint32_t takeWakeMwwPendingDetections() {
  portENTER_CRITICAL(&gWakeMwwMux);
  const uint32_t pending = gWakeMwwPendingDetections;
  gWakeMwwPendingDetections = 0;
  portEXIT_CRITICAL(&gWakeMwwMux);
  return pending;
}

void queueWakeMwwDetection(uint32_t nowMs) {
  portENTER_CRITICAL(&gWakeMwwMux);
  gWakeMwwPendingDetections = gWakeMwwPendingDetections + 1;
  gWakeSrProbe.wakeDetections++;
  gWakeSrProbe.lastWakeMs = nowMs;
  portEXIT_CRITICAL(&gWakeMwwMux);
}

void resetWakeMwwValidationCounters() {
  gMicroWakeWordProbe.reset();
  gMicroWakeWordProbe.clearTelemetry();
  const uint32_t nowMs = millis();
  portENTER_CRITICAL(&gWakeMwwMux);
  gWakeMwwPendingDetections = 0;
  gWakeSrProbe.mwwFeatures = 0;
  gWakeSrProbe.mwwInferences = 0;
  gWakeSrProbe.mwwDetections = 0;
  gWakeSrProbe.mwwInvokeErrors = 0;
  gWakeSrProbe.mwwFeatureErrors = 0;
    gWakeSrProbe.mwwLastProbability = 0;
    gWakeSrProbe.mwwMaxProbability = 0;
    gWakeSrProbe.mwwAverageProbability = 0;
    gWakeSrProbe.mwwMaxAverageProbability = 0;
    gWakeSrProbe.mwwLastDetectionProbability = 0;
    gWakeSrProbe.mwwLastDetectionAverageProbability = 0;
    gWakeSrProbe.mwwMaxDetectionAverageProbability = 0;
  gWakeSrProbe.mwwLastFeatureMin = 0;
  gWakeSrProbe.mwwLastFeatureMax = 0;
  gWakeSrProbe.mwwMinFeatureSeen = 0;
  gWakeSrProbe.mwwMaxFeatureSeen = 0;
  gWakeSrProbe.mwwLastInferenceUs = 0;
  gWakeSrProbe.mwwMaxInferenceUs = 0;
  gWakeSrProbe.wakeDetections = 0;
  gWakeSrProbe.wakeEventsApplied = 0;
  gWakeSrProbe.lastWakeMs = 0;
  gWakeSrProbe.audioPeak = 0;
  gWakeSrProbe.audioPeakMax = 0;
  gWakeSrProbe.audioPeakWindowMax = 0;
  gWakeSrProbe.audioMeanAbs = 0;
  gWakeSrProbe.audioMeanAbsMax = 0;
  gWakeSrProbe.audioMeanAbsWindowMax = 0;
  gWakeSrProbe.audioWindowStartMs = nowMs;
  gWakeSrProbe.audioWindowMs = 0;
  gWakeSrProbe.audioClips = 0;
  gWakeMwwInteractionLatched = false;
  gWakeMwwInteractionLatchedAtMs = 0;
  portEXIT_CRITICAL(&gWakeMwwMux);
#if STACKCHAN_ENABLE_BRIDGE_AUDIO_UPLINK && STACKCHAN_MWW_WAKE_DRIVES_AUDIO_UPLINK
  resetWakeMwwUplinkQueue();
  gWakeMwwUplinkQueued = 0;
  gWakeMwwUplinkDropped = 0;
  gWakeMwwUplinkSubmitted = 0;
  gWakeMwwUplinkSubmitFailed = 0;
#endif
}

bool ensureWakeMwwPcmRing() {
  if (gWakeMwwPcmRing != nullptr) {
    return true;
  }
  gWakeMwwPcmRing = static_cast<int16_t*>(
      heap_caps_malloc(kWakeMwwPcmRingSamples * sizeof(int16_t), MALLOC_CAP_SPIRAM | MALLOC_CAP_8BIT));
  if (gWakeMwwPcmRing == nullptr) {
    return false;
  }
  memset(gWakeMwwPcmRing, 0, kWakeMwwPcmRingSamples * sizeof(int16_t));
  gWakeMwwPcmWriteIndex = 0;
  gWakeMwwPcmAvailable = 0;
  gWakeMwwPcmSequence = 0;
  return true;
}

void storeWakeMwwPcm(const int16_t* samples, size_t sampleCount) {
  if (gWakeMwwPcmRing == nullptr || samples == nullptr || sampleCount == 0) {
    return;
  }
  uint32_t writeIndex = gWakeMwwPcmWriteIndex;
  uint32_t available = gWakeMwwPcmAvailable;
  for (size_t i = 0; i < sampleCount; ++i) {
    gWakeMwwPcmRing[writeIndex] = samples[i];
    writeIndex = (writeIndex + 1u) % kWakeMwwPcmRingSamples;
    if (available < kWakeMwwPcmRingSamples) {
      available++;
    }
  }
  gWakeMwwPcmWriteIndex = writeIndex;
  gWakeMwwPcmAvailable = available;
  gWakeMwwPcmSequence = gWakeMwwPcmSequence + 1u;
}

#if STACKCHAN_ENABLE_BRIDGE_AUDIO_UPLINK && STACKCHAN_MWW_WAKE_DRIVES_AUDIO_UPLINK
bool ensureWakeMwwUplinkQueue() {
  gWakeMwwUplinkPendingReady = false;
  gWakeMwwUplinkPending = WakeMwwUplinkChunk {};
  return true;
}

void resetWakeMwwUplinkQueue() {
  gWakeMwwUplinkPendingReady = false;
  gWakeMwwUplinkPending = WakeMwwUplinkChunk {};
  gWakeMwwUplinkReset = gWakeMwwUplinkReset + 1u;
}

void queueWakeMwwUplinkAudio(const int16_t* samples, size_t sampleCount, uint32_t capturedAtMs) {
  static WakeMwwUplinkChunk pending;
  static uint16_t pendingSamples = 0;

  if (samples == nullptr || sampleCount == 0 || !gBridgeAudioUplink.telemetry().active) {
    pendingSamples = 0;
    return;
  }
  if (gWakeMwwUplinkPendingReady) {
    gWakeMwwUplinkDropped = gWakeMwwUplinkDropped + 1u;
    return;
  }

  size_t copied = 0;
  while (copied < sampleCount) {
    const size_t freeSamples = STACKCHAN_MWW_WAKE_UPLINK_CHUNK_SAMPLES - pendingSamples;
    const size_t remaining = sampleCount - copied;
    const size_t copySamples = remaining < freeSamples ? remaining : freeSamples;
    if (pendingSamples == 0) {
      pending.capturedAtMs = capturedAtMs;
    }
    memcpy(pending.samples + pendingSamples, samples + copied, copySamples * sizeof(int16_t));
    pendingSamples += static_cast<uint16_t>(copySamples);
    copied += copySamples;

    if (pendingSamples >= STACKCHAN_MWW_WAKE_UPLINK_CHUNK_SAMPLES) {
      pending.sampleCount = pendingSamples;
      if (gWakeMwwUplinkPendingReady) {
        gWakeMwwUplinkDropped = gWakeMwwUplinkDropped + 1u;
      } else {
        gWakeMwwUplinkPending = pending;
        gWakeMwwUplinkPendingReady = true;
        gWakeMwwUplinkQueued = gWakeMwwUplinkQueued + 1u;
      }
      pending = WakeMwwUplinkChunk {};
      pendingSamples = 0;
    }
  }
}

void drainWakeMwwUplinkQueue(uint32_t nowMs) {
  if (!gBridgeAudioUplink.telemetry().active) {
    if (gWakeMwwUplinkPendingReady) {
      resetWakeMwwUplinkQueue();
    }
    return;
  }

  if (!gWakeMwwUplinkPendingReady) {
    return;
  }
  if (gWakeMwwUplinkPending.sampleCount == 0) {
    gWakeMwwUplinkPendingReady = false;
    return;
  }
  const BridgeAudioUplinkTelemetry& uplink = gBridgeAudioUplink.telemetry();
  if (gBridgeAudioUplink.submitPcmChunk(
          uplink.lastSeq,
          gWakeMwwUplinkPending.samples,
          gWakeMwwUplinkPending.sampleCount,
          nowMs)) {
    gWakeMwwUplinkPendingReady = false;
    gWakeMwwUplinkSubmitted = gWakeMwwUplinkSubmitted + 1u;
  } else {
    gWakeMwwUplinkSubmitFailed = gWakeMwwUplinkSubmitFailed + 1u;
  }
}
#else
bool ensureWakeMwwUplinkQueue() {
  return true;
}

void resetWakeMwwUplinkQueue() {}

void queueWakeMwwUplinkAudio(const int16_t* samples, size_t sampleCount, uint32_t capturedAtMs) {
  (void)samples;
  (void)sampleCount;
  (void)capturedAtMs;
}

void drainWakeMwwUplinkQueue(uint32_t nowMs) {
  (void)nowMs;
}
#endif

#if STACKCHAN_HAS_MWW_WAKE_PROBE && STACKCHAN_ENABLE_BRIDGE_AUDIO_UPLINK && STACKCHAN_MWW_DEDICATED_WAKE_CAPTURE
bool submitDedicatedWakeCaptureChunk(uint32_t seq,
                                     const int16_t* samples,
                                     uint16_t sampleCount,
                                     uint32_t nowMs) {
  constexpr uint16_t kSubmitAttempts =
      STACKCHAN_MWW_WAKE_UPLINK_SUBMIT_RETRY_ATTEMPTS > 0
          ? STACKCHAN_MWW_WAKE_UPLINK_SUBMIT_RETRY_ATTEMPTS
          : 1;
  constexpr uint16_t kSubmitDelayMs = STACKCHAN_MWW_WAKE_UPLINK_SUBMIT_RETRY_DELAY_MS;

  for (uint16_t attempt = 0; attempt < kSubmitAttempts; ++attempt) {
    const uint32_t attemptMs = millis();
    gBridgeNetworkSession.update(attemptMs);
    const BridgeSocketWriterTelemetry& writer = gBridgeNetworkSession.writer().telemetry();
    if (!writer.frameBuffered && !writer.binaryFrameQueued &&
        gBridgeAudioUplink.submitPcmChunk(seq, samples, sampleCount, attemptMs)) {
      gBridgeNetworkSession.update(millis());
      return true;
    }
    gBridgeNetworkSession.update(millis());
    if (kSubmitDelayMs > 0) {
      vTaskDelay(pdMS_TO_TICKS(kSubmitDelayMs));
    } else {
      taskYIELD();
    }
  }
  return false;
}

void finishDedicatedWakeCaptureTurn(uint32_t seq, uint32_t nowMs) {
  RobotEvent endEvent;
  endEvent.type = EventType::SpeechEnded;
  endEvent.timestampMs = nowMs;
  endEvent.strength = 1.0f;
  gBridgeWakeGate.applyEvent(endEvent, nowMs);
  if (gBridgeAudioUplink.telemetry().active) {
    gBridgeAudioUplink.endTurn(seq, nowMs);
  }
  for (uint8_t i = 0; i < 12; ++i) {
    gBridgeNetworkSession.update(millis());
    vTaskDelay(pdMS_TO_TICKS(2));
  }
}

bool beginDedicatedWakeCaptureAfterCue(const RobotEvent& wakeEvent) {
  if (gBridgeNetworkSession.telemetry().state != BridgeNetworkSessionState::Connected) {
    return false;
  }

  auto micConfig = M5.Mic.config();
  micConfig.sample_rate = STACKCHAN_MWW_WAKE_CAPTURE_SAMPLE_RATE;
  micConfig.magnification = STACKCHAN_MWW_WAKE_MIC_MAGNIFICATION;
  micConfig.noise_filter_level = STACKCHAN_SR_WAKE_MIC_NOISE_FILTER_LEVEL;
  micConfig.task_priority = STACKCHAN_SR_WAKE_MIC_TASK_PRIORITY;
  micConfig.task_pinned_core = STACKCHAN_SR_WAKE_MIC_TASK_CORE;
#if STACKCHAN_MWW_WAKE_RECORD_STEREO
  micConfig.input_channel = m5::input_channel_t::input_stereo;
  micConfig.stereo = true;
#elif STACKCHAN_MWW_WAKE_MONO_CHANNEL
  micConfig.input_channel = m5::input_channel_t::input_only_left;
  micConfig.stereo = false;
#else
  micConfig.input_channel = m5::input_channel_t::input_only_right;
  micConfig.stereo = false;
#endif
  M5.Mic.config(micConfig);
  if (!M5.Mic.begin()) {
    gWakeSrProbe.audioPauseFailures++;
    return false;
  }
  applyWakeMwwEs7210GainOverride();

  const uint32_t captureStartMs = millis();
  if (!gWakeCueSequence.noteCaptureStarted(captureStartMs, 0)) {
    return false;
  }
  gBridgeNetworkSession.update(captureStartMs);
  gBridgeWakeGate.applyEvent(wakeEvent, captureStartMs);
  gBridgeNetworkSession.update(captureStartMs);

  const BridgeAudioUplinkTelemetry& started = gBridgeAudioUplink.telemetry();
  if (!started.active) {
    return false;
  }

  gWakeMwwDedicatedCapture.active = true;
  gWakeMwwDedicatedCapture.seq = started.lastSeq;
  gWakeMwwDedicatedCapture.chunksAttempted = 0;
  gWakeMwwDedicatedCapture.chunksSubmitted = 0;
  return true;
}

void finishDedicatedWakeCaptureSession(bool captured) {
  if (gWakeMwwDedicatedCapture.active) {
    finishDedicatedWakeCaptureTurn(gWakeMwwDedicatedCapture.seq, millis());
  }
  M5.Mic.end();
  releaseWakeMwwAudioPause(millis());
  suppressWakeMwwDetections(millis(), 900);

  const uint32_t captureEndMs = millis();
  if (gWakeCueSequence.phase() == WakeCueSequencePhase::Capturing) {
    gWakeCueSequence.finishCapture(captureEndMs, captured);
  } else {
    gWakeCueSequence.abort(captureEndMs);
  }
  gWakeMwwPendingCaptureEventReady = false;
  gWakeMwwDedicatedCapture.active = false;
  if (captured) {
    ++gWakeSrProbe.wakeEventsApplied;
  }
}

void serviceDedicatedWakeCaptureChunk() {
  if (!gWakeMwwDedicatedCapture.active) {
    return;
  }

  const uint32_t serviceStartUs = micros();

  constexpr bool kRecordStereo = STACKCHAN_MWW_WAKE_RECORD_STEREO != 0;
  constexpr uint32_t kSampleRate = STACKCHAN_MWW_WAKE_CAPTURE_SAMPLE_RATE;
  constexpr size_t kMonoSamples = STACKCHAN_MWW_WAKE_UPLINK_CHUNK_SAMPLES;
  constexpr size_t kRecordChannels = kRecordStereo ? 2u : 1u;
  constexpr size_t kRecordSamples = kMonoSamples * kRecordChannels;
  static int16_t recordBuf[kRecordSamples];
  static int16_t monoBuf[kMonoSamples];

  ++gWakeMwwDedicatedCapture.serviceCalls;
  ++gWakeMwwDedicatedCapture.chunksAttempted;
  bool submitFailed = false;
  if (!recordWakeMwwAudioBlocking(recordBuf, kRecordSamples, kSampleRate, kRecordStereo)) {
    gWakeSrProbe.recordDrops++;
  } else {

    if constexpr (kRecordStereo) {
      constexpr size_t selectedChannel = STACKCHAN_MWW_WAKE_STEREO_MONO_CHANNEL ? 1u : 0u;
      for (size_t i = 0; i < kMonoSamples; ++i) {
        monoBuf[i] = recordBuf[(i * kRecordChannels) + selectedChannel];
      }
    } else {
      memcpy(monoBuf, recordBuf, sizeof(monoBuf));
    }
    conditionWakeSrDirectAudio(monoBuf, static_cast<int>(kMonoSamples), 1);
    storeWakeMwwPcm(monoBuf, kMonoSamples);
    gWakeSrProbe.recordOk++;
    gWakeSrProbe.samplesFed += kMonoSamples;
    gWakeSrProbe.lastRecordMs = millis();

    if (submitDedicatedWakeCaptureChunk(
            gWakeMwwDedicatedCapture.seq, monoBuf, kMonoSamples, gWakeSrProbe.lastRecordMs)) {
      ++gWakeMwwDedicatedCapture.chunksSubmitted;
    } else {
      gWakeMwwUplinkSubmitFailed = gWakeMwwUplinkSubmitFailed + 1u;
      submitFailed = true;
    }
  }

  const uint32_t serviceUs = micros() - serviceStartUs;
  if (serviceUs > gWakeMwwDedicatedCapture.maxServiceUs) {
    gWakeMwwDedicatedCapture.maxServiceUs = serviceUs;
  }
  const bool complete = submitFailed ||
                        gWakeMwwDedicatedCapture.chunksAttempted >=
                            kWakeMwwDedicatedCaptureChunks;
  if (complete) {
    finishDedicatedWakeCaptureSession(gWakeMwwDedicatedCapture.chunksSubmitted > 0);
  }
}

void serviceDedicatedWakeCapture(uint32_t nowMs) {
  if (gWakeMwwDedicatedCapture.active) {
    serviceDedicatedWakeCaptureChunk();
    return;
  }

  WakeCueSequencePhase phase = gWakeCueSequence.phase();
  if (phase == WakeCueSequencePhase::AwaitingAudioPause) {
    if (!requestWakeMwwAudioPause(nowMs, 700)) {
      gWakeCueSequence.abort(millis());
      gWakeMwwPendingCaptureEventReady = false;
      return;
    }
    const uint32_t pausedAtMs = millis();
    if (!gWakeCueSequence.noteAudioPaused(pausedAtMs)) {
      releaseWakeMwwAudioPause(millis());
      gWakeCueSequence.abort(millis());
      gWakeMwwPendingCaptureEventReady = false;
      return;
    }
    const bool cueAccepted = gSpeakerSink.playMicActivationToneForCapture();
    const uint32_t cueStartMs = millis();
    gWakeCueSequence.noteCueStarted(
        cueStartMs,
        gSpeakerSink.micActivationCueDurationMs(),
        kWakeMwwCueCompletionTimeoutMs,
        cueAccepted);
    phase = gWakeCueSequence.phase();
  }

  if (phase == WakeCueSequencePhase::CueFailed) {
    gSpeakerSink.handoffMicActivationCueToCapture(millis());
    releaseWakeMwwAudioPause(millis());
    gWakeCueSequence.abort(millis());
    gWakeMwwPendingCaptureEventReady = false;
    return;
  }

  if (phase == WakeCueSequencePhase::CuePlaying) {
    if (!gWakeCueSequence.updateCue(millis(), gSpeakerSink.speakerChannelState() != 0)) {
      return;
    }
    phase = gWakeCueSequence.phase();
  }

  if (phase == WakeCueSequencePhase::CueFailed) {
    releaseWakeMwwAudioPause(millis());
    gWakeCueSequence.abort(millis());
    gWakeMwwPendingCaptureEventReady = false;
    return;
  }

  if (phase != WakeCueSequencePhase::ReadyForCapture) {
    return;
  }

  const uint32_t handoffMs = millis();
  gSpeakerSink.handoffMicActivationCueToCapture(handoffMs);
  if (!gWakeCueSequence.noteAudioPauseHandoff(handoffMs)) {
    releaseWakeMwwAudioPause(millis());
    gWakeCueSequence.abort(millis());
    gWakeMwwPendingCaptureEventReady = false;
    return;
  }

  const bool started = gWakeMwwPendingCaptureEventReady &&
                       beginDedicatedWakeCaptureAfterCue(gWakeMwwPendingCaptureEvent);
  if (!started) {
    finishDedicatedWakeCaptureSession(false);
  }
}
#endif

void writeWakeWavLe16(uint8_t* dst, uint16_t value) {
  dst[0] = static_cast<uint8_t>(value & 0xFFu);
  dst[1] = static_cast<uint8_t>((value >> 8) & 0xFFu);
}

void writeWakeWavLe32(uint8_t* dst, uint32_t value) {
  dst[0] = static_cast<uint8_t>(value & 0xFFu);
  dst[1] = static_cast<uint8_t>((value >> 8) & 0xFFu);
  dst[2] = static_cast<uint8_t>((value >> 16) & 0xFFu);
  dst[3] = static_cast<uint8_t>((value >> 24) & 0xFFu);
}

void serveWakeMwwPcmWav(WiFiClient& client) {
  const uint32_t available = gWakeMwwPcmRing != nullptr ? gWakeMwwPcmAvailable : 0;
  const uint32_t writeIndex = gWakeMwwPcmWriteIndex;
  const uint32_t sampleCount =
      available < kWakeMwwPcmRingSamples ? available : static_cast<uint32_t>(kWakeMwwPcmRingSamples);
  const uint32_t dataBytes = sampleCount * sizeof(int16_t);
  const uint32_t contentLength = 44u + dataBytes;

  uint8_t header[44] = {};
  memcpy(header + 0, "RIFF", 4);
  writeWakeWavLe32(header + 4, contentLength - 8u);
  memcpy(header + 8, "WAVE", 4);
  memcpy(header + 12, "fmt ", 4);
  writeWakeWavLe32(header + 16, 16u);
  writeWakeWavLe16(header + 20, 1u);
  writeWakeWavLe16(header + 22, 1u);
  writeWakeWavLe32(header + 24, 16000u);
  writeWakeWavLe32(header + 28, 16000u * sizeof(int16_t));
  writeWakeWavLe16(header + 32, sizeof(int16_t));
  writeWakeWavLe16(header + 34, 16u);
  memcpy(header + 36, "data", 4);
  writeWakeWavLe32(header + 40, dataBytes);

  client.println(F("HTTP/1.1 200 OK"));
  client.println(F("Content-Type: audio/wav"));
  client.print(F("Content-Length: "));
  client.println(contentLength);
  client.println(F("Connection: close"));
  client.println();
  client.write(header, sizeof(header));

  if (sampleCount == 0 || gWakeMwwPcmRing == nullptr) {
    return;
  }

  const uint32_t start = (writeIndex + kWakeMwwPcmRingSamples - sampleCount) % kWakeMwwPcmRingSamples;
  const uint32_t firstCount =
      start + sampleCount <= kWakeMwwPcmRingSamples ? sampleCount : kWakeMwwPcmRingSamples - start;
  client.write(
      reinterpret_cast<const uint8_t*>(gWakeMwwPcmRing + start),
      firstCount * sizeof(int16_t));
  const uint32_t remaining = sampleCount - firstCount;
  if (remaining > 0) {
    client.write(reinterpret_cast<const uint8_t*>(gWakeMwwPcmRing), remaining * sizeof(int16_t));
  }
}

void WakeMwwProbeTask(void* pv) {
  (void)pv;
  gWakeSrProbe.beginAttempts++;
#if STACKCHAN_ENABLE_WAKE_SERIAL_LOGS
  Serial.println(F("[mww_wake] task_enter=1"));
#endif

  constexpr uint32_t kModelSampleRate = 16000;
  constexpr uint32_t kCaptureSampleRate = STACKCHAN_MWW_WAKE_CAPTURE_SAMPLE_RATE;
  static_assert(kCaptureSampleRate >= kModelSampleRate, "MWW capture rate must be at least 16 kHz");
  static_assert((kCaptureSampleRate % kModelSampleRate) == 0, "MWW capture rate must be divisible by 16 kHz");
  constexpr size_t kDecimationFactor = kCaptureSampleRate / kModelSampleRate;

  auto micConfig = M5.Mic.config();
  micConfig.sample_rate = kCaptureSampleRate;
  micConfig.magnification = STACKCHAN_MWW_WAKE_MIC_MAGNIFICATION;
  micConfig.noise_filter_level = STACKCHAN_SR_WAKE_MIC_NOISE_FILTER_LEVEL;
  micConfig.task_priority = STACKCHAN_SR_WAKE_MIC_TASK_PRIORITY;
  micConfig.task_pinned_core = STACKCHAN_SR_WAKE_MIC_TASK_CORE;
#if STACKCHAN_MWW_WAKE_MIC_INPUT_STEREO
  micConfig.input_channel = m5::input_channel_t::input_stereo;
  micConfig.stereo = true;
#elif STACKCHAN_MWW_WAKE_MONO_CHANNEL
  micConfig.input_channel = m5::input_channel_t::input_only_left;
  micConfig.stereo = false;
#else
  micConfig.input_channel = m5::input_channel_t::input_only_right;
  micConfig.stereo = false;
#endif
  M5.Mic.config(micConfig);
  if (!M5.Mic.begin()) {
    gWakeSrProbe.beginFailures++;
    copyWakeSrError("mww_mic_begin_failed");
#if STACKCHAN_ENABLE_WAKE_SERIAL_LOGS
    Serial.println(F("[mww_wake] ready=0 error=mic_begin_failed"));
#endif
    vTaskDelete(nullptr);
    return;
  }
  gWakeSrProbe.micReady = true;
  applyWakeMwwEs7210GainOverride();
  const bool pcmCaptureReady = ensureWakeMwwPcmRing();
  const bool uplinkQueueReady = ensureWakeMwwUplinkQueue();
#if STACKCHAN_ENABLE_WAKE_SERIAL_LOGS
  Serial.print(F("[mww_wake] pcm_capture_ready="));
  Serial.print(pcmCaptureReady ? 1 : 0);
  Serial.print(F(" samples="));
  Serial.println(pcmCaptureReady ? kWakeMwwPcmRingSamples : 0);
  Serial.print(F("[mww_wake] uplink_buffer_ready="));
  Serial.print(uplinkQueueReady ? 1 : 0);
  Serial.print(F(" chunk_samples="));
  Serial.print(STACKCHAN_MWW_WAKE_UPLINK_CHUNK_SAMPLES);
  Serial.println(F(" slots=1"));
#else
  (void)pcmCaptureReady;
  (void)uplinkQueueReady;
#endif

  MicroWakeWordProbeConfig config;
#if STACKCHAN_MWW_WAKE_USE_HI_STACKCHAN_MODEL && STACKCHAN_HAS_MWW_HI_STACKCHAN_MODEL
  const char* modelId = "hi_stackchan";
  const char* modelName = "microWakeWord:hi_stackchan";
  const char* wakeWord = "Hi StackChan";
  config.modelData = wake_models::kHiStackchanTflite;
  config.modelSize = wake_models::kHiStackchanTfliteSize;
#elif STACKCHAN_MWW_WAKE_USE_M5_MODEL && STACKCHAN_HAS_MWW_M5_MODEL
  const char* modelId = "hey_m5_v3";
  const char* modelName = "microWakeWord:hey_m5_v3";
  const char* wakeWord = "Hey M5";
  config.modelData = wake_models::kHeyM5V3Tflite;
  config.modelSize = wake_models::kHeyM5V3TfliteSize;
#else
  const char* modelId = "hey_stackchan_v1";
  const char* modelName = "microWakeWord:hey_stackchan_v1";
  const char* wakeWord = "Hey Stack Chan";
  config.modelData = wake_models::kHeyStackchanV1Tflite;
  config.modelSize = wake_models::kHeyStackchanV1TfliteSize;
#endif
  config.probabilityCutoff = STACKCHAN_MWW_WAKE_PROBABILITY_CUTOFF;
  config.slidingWindowSize = 5;
  config.featureStepMs = 10;
  config.warmupWindows = 100;
  config.tensorArenaSize = 65536;
  config.variableArenaSize = 1024;
  if (!gMicroWakeWordProbe.begin(config)) {
    gWakeSrProbe.beginFailures++;
    copyWakeSrError(gMicroWakeWordProbe.telemetry().error);
#if STACKCHAN_ENABLE_WAKE_SERIAL_LOGS
    Serial.print(F("[mww_wake] ready=0 error="));
    Serial.println(gMicroWakeWordProbe.telemetry().error);
#endif
    vTaskDelete(nullptr);
    return;
  }

  constexpr bool kRecordStereo = STACKCHAN_MWW_WAKE_RECORD_STEREO != 0;
  constexpr bool kDcCorrect = STACKCHAN_MWW_WAKE_DC_CORRECT != 0;
  constexpr size_t kMonoRecordSamples = STACKCHAN_MWW_WAKE_RECORD_SAMPLES;
  constexpr size_t kCaptureFrames = kMonoRecordSamples * kDecimationFactor;
  constexpr size_t kRecordChannels = kRecordStereo ? 2u : 1u;
  constexpr size_t kRecordSamples = kCaptureFrames * kRecordChannels;
  static int16_t audioBuf[kRecordSamples];
  static int16_t monoBuf[kMonoRecordSamples];
  const auto appliedMicConfig = M5.Mic.config();
  gWakeSrProbe.taskStarted = true;
  gWakeSrProbe.srReady = true;
  gWakeSrProbe.chunkSamples = kMonoRecordSamples;
  gWakeSrProbe.recordSamples = kRecordSamples;
  gWakeSrProbe.audioChannels = kRecordStereo ? 2 : 1;
  gWakeSrProbe.sampleRate = kCaptureSampleRate;
  gWakeSrProbe.detectMode = STACKCHAN_MWW_WAKE_PROBABILITY_CUTOFF;
  gWakeSrProbe.micMagnification = appliedMicConfig.magnification;
  gWakeSrProbe.monoChannel =
      kRecordStereo ? (STACKCHAN_MWW_WAKE_STEREO_MONO_CHANNEL ? 1 : 0)
                    : (appliedMicConfig.input_channel == m5::input_channel_t::input_only_left ? 1 : 0);
  gWakeSrProbe.micInputStereo = appliedMicConfig.input_channel == m5::input_channel_t::input_stereo;
  gWakeSrProbe.micTaskCore = appliedMicConfig.task_pinned_core;
  gWakeSrProbe.micTaskPriority = appliedMicConfig.task_priority;
  gWakeSrProbe.micNoiseFilterLevel = appliedMicConfig.noise_filter_level;
  gWakeSrProbe.stereo = kRecordStereo;
  gWakeSrProbe.audioGainQ8 = STACKCHAN_SR_WAKE_DIRECT_GAIN_Q8;
  gWakeSrProbe.mwwArenaUsedBytes = gMicroWakeWordProbe.telemetry().arenaUsedBytes;
  gWakeSrProbe.mwwArenasZeroInitialized =
      gMicroWakeWordProbe.telemetry().arenasZeroInitialized;
  gWakeSrProbe.mwwModelStride = gMicroWakeWordProbe.telemetry().modelStride;
  copyWakeSrString(gWakeSrProbe.modelName, sizeof(gWakeSrProbe.modelName), modelName);
  copyWakeSrString(gWakeSrProbe.wakeWord, sizeof(gWakeSrProbe.wakeWord), wakeWord);
  copyWakeSrError("");

#if STACKCHAN_ENABLE_WAKE_SERIAL_LOGS
  Serial.print(F("[mww_wake] ready=1 model="));
  Serial.print(modelId);
  Serial.print(F(" wake_word=\""));
  Serial.print(wakeWord);
  Serial.print(F("\" cutoff="));
  Serial.print(STACKCHAN_MWW_WAKE_PROBABILITY_CUTOFF);
  Serial.print(F(" record_samples="));
  Serial.print(kRecordSamples);
  Serial.print(F(" record_stereo="));
  Serial.print(kRecordStereo ? 1 : 0);
  Serial.print(F(" capture_hz="));
  Serial.print(kCaptureSampleRate);
  Serial.print(F(" decimate="));
  Serial.print(kDecimationFactor);
  Serial.print(F(" dc_correct="));
  Serial.print(kDcCorrect ? 1 : 0);
  Serial.print(F(" stride="));
  Serial.print(gMicroWakeWordProbe.telemetry().modelStride);
  Serial.print(F(" arena_used="));
  Serial.print(gMicroWakeWordProbe.telemetry().arenaUsedBytes);
  Serial.print(F(" mic_mag="));
  Serial.print(gWakeSrProbe.micMagnification);
  Serial.print(F(" task_core="));
  Serial.print(STACKCHAN_MWW_WAKE_TASK_CORE);
  Serial.print(F(" priority="));
  Serial.println(STACKCHAN_MWW_WAKE_TASK_PRIORITY);
#else
  (void)modelId;
#endif

#if STACKCHAN_MWW_WAKE_STARTUP_SUPPRESSION_MS > 0
  const uint32_t startupSuppressMs = millis();
  suppressWakeMwwDetections(startupSuppressMs, STACKCHAN_MWW_WAKE_STARTUP_SUPPRESSION_MS);
#if STACKCHAN_ENABLE_WAKE_SERIAL_LOGS
  Serial.print(F("[mww_wake] startup_suppression_ms="));
  Serial.print(STACKCHAN_MWW_WAKE_STARTUP_SUPPRESSION_MS);
  Serial.print(F(" at_ms="));
  Serial.println(startupSuppressMs);
#endif
#endif

  uint32_t lastDetectionMs = 0;
#if STACKCHAN_MWW_WAKE_DIAG_INTERVAL > 0
  uint32_t lastDiagInference = 0;
#endif
  int32_t highPassPreviousInput = 0;
  int32_t highPassPreviousOutput = 0;
  bool wasSuppressed = false;
  while (true) {
    if (gWakeMwwResetRequested) {
      gWakeMwwResetRequested = false;
      resetWakeMwwValidationCounters();
      highPassPreviousInput = 0;
      highPassPreviousOutput = 0;
      wasSuppressed = false;
#if STACKCHAN_ENABLE_WAKE_SERIAL_LOGS
      Serial.print(F("[mww_wake] validation_reset=1 at_ms="));
      Serial.println(millis());
#endif
    }

    if (gWakeMwwAudioPauseRequested) {
      if (!gWakeMwwAudioPaused) {
        M5.Mic.end();
        gWakeMwwAudioPaused = true;
        gWakeSrProbe.micReady = false;
        gWakeSrProbe.audioPauseRequested = true;
        gWakeSrProbe.audioPaused = true;
        gWakeSrProbe.audioPauseEnters++;
        gWakeSrProbe.audioLastPauseMs = millis();
        gMicroWakeWordProbe.reset();
#if STACKCHAN_ENABLE_WAKE_SERIAL_LOGS
        Serial.print(F("[mww_wake] audio_pause=1 at_ms="));
        Serial.println(gWakeSrProbe.audioLastPauseMs);
#endif
      }
      vTaskDelay(pdMS_TO_TICKS(10));
      continue;
    }

    if (gWakeMwwAudioPaused) {
      const uint32_t resumeMs = millis();
      M5.Mic.config(micConfig);
      if (!M5.Mic.begin()) {
        gWakeSrProbe.recordDrops++;
        gWakeSrProbe.audioPauseFailures++;
        copyWakeSrError("mww_mic_resume_failed");
#if STACKCHAN_ENABLE_WAKE_SERIAL_LOGS
        Serial.print(F("[mww_wake] audio_resume=0 error=mic_begin_failed at_ms="));
        Serial.println(resumeMs);
#endif
        vTaskDelay(pdMS_TO_TICKS(50));
        continue;
      }
      applyWakeMwwEs7210GainOverride();
      gWakeMwwAudioPaused = false;
      gWakeSrProbe.micReady = true;
      gWakeSrProbe.audioPauseRequested = false;
      gWakeSrProbe.audioPaused = false;
      gWakeSrProbe.audioResumes++;
      gWakeSrProbe.audioLastResumeMs = resumeMs;
      gMicroWakeWordProbe.reset();
      highPassPreviousInput = 0;
      highPassPreviousOutput = 0;
      wasSuppressed = true;
      suppressWakeMwwDetections(resumeMs, 600);
      copyWakeSrError("");
#if STACKCHAN_ENABLE_WAKE_SERIAL_LOGS
      Serial.print(F("[mww_wake] audio_resume=1 at_ms="));
      Serial.println(resumeMs);
#endif
    }

    if (!recordWakeMwwAudioBlocking(audioBuf, kRecordSamples, kCaptureSampleRate, kRecordStereo)) {
      gWakeSrProbe.recordDrops++;
      vTaskDelay(pdMS_TO_TICKS(1));
      continue;
    }

#if STACKCHAN_ENABLE_CAMERA && STACKCHAN_MWW_WAKE_RECORD_STEREO
    queueWakeMwwStereoDirection(
        estimateStereoDirection(audioBuf, kCaptureFrames, kCaptureSampleRate), millis());
#endif

    int16_t* modelAudio = monoBuf;
    size_t modelSamples = kMonoRecordSamples;
    if constexpr (kDecimationFactor == 1 && !kRecordStereo && !kDcCorrect) {
      modelAudio = audioBuf;
    } else {
      constexpr size_t selectedChannel = STACKCHAN_MWW_WAKE_STEREO_MONO_CHANNEL ? 1u : 0u;
      for (size_t i = 0; i < kMonoRecordSamples; ++i) {
        int32_t sum = 0;
        for (size_t j = 0; j < kDecimationFactor; ++j) {
          const size_t frameIndex = (i * kDecimationFactor) + j;
          const size_t sampleIndex = (frameIndex * kRecordChannels) + (kRecordStereo ? selectedChannel : 0u);
          sum += audioBuf[sampleIndex];
        }
        monoBuf[i] = clampWakeSrSample(sum / static_cast<int32_t>(kDecimationFactor));
      }
    }
    if constexpr (kDcCorrect) {
      int32_t mean = 0;
      for (size_t i = 0; i < kMonoRecordSamples; ++i) {
        mean += modelAudio[i];
      }
      mean /= static_cast<int32_t>(kMonoRecordSamples);
      for (size_t i = 0; i < kMonoRecordSamples; ++i) {
        modelAudio[i] = clampWakeSrSample(static_cast<int32_t>(modelAudio[i]) - mean);
      }
    }
    highPassWakeMwwAudio(modelAudio, modelSamples, highPassPreviousInput, highPassPreviousOutput);
    conditionWakeSrDirectAudio(modelAudio, static_cast<int>(modelSamples), 1);
    storeWakeMwwPcm(modelAudio, modelSamples);
    gWakeSrProbe.recordOk++;
    gWakeSrProbe.samplesFed += modelSamples;
    gWakeSrProbe.lastRecordMs = millis();
    const uint32_t recordMs = gWakeSrProbe.lastRecordMs;
    queueWakeMwwUplinkAudio(modelAudio, modelSamples, recordMs);
    const bool suppressed = wakeMwwDetectionsSuppressed(recordMs) || gWakeMwwInteractionLatched;
    if (suppressed) {
      if (!wasSuppressed) {
        gMicroWakeWordProbe.reset();
        wasSuppressed = true;
#if STACKCHAN_ENABLE_WAKE_SERIAL_LOGS
        Serial.print(F("[mww_wake] local_audio_suppression=1 until_ms="));
        Serial.println(gWakeMwwSuppressUntilMs);
#endif
      }
      vTaskDelay(pdMS_TO_TICKS(1));
      continue;
    }
    if (wasSuppressed) {
      gMicroWakeWordProbe.reset();
      wasSuppressed = false;
#if STACKCHAN_ENABLE_WAKE_SERIAL_LOGS
      Serial.print(F("[mww_wake] local_audio_suppression=0 at_ms="));
      Serial.println(recordMs);
#endif
    }
    const bool detected = gMicroWakeWordProbe.feed(modelAudio, modelSamples);
    const MicroWakeWordProbeTelemetry& mww = gMicroWakeWordProbe.telemetry();
    const bool peakDetected =
        (STACKCHAN_MWW_WAKE_PEAK_PROBABILITY_CUTOFF > 0) &&
        (mww.lastProbability >= STACKCHAN_MWW_WAKE_PEAK_PROBABILITY_CUTOFF);
    gWakeSrProbe.detectCalls = mww.inferences;
    gWakeSrProbe.detectNonzero = mww.maxProbability > 0 ? mww.inferences : 0;
    gWakeSrProbe.lastDetectResult = static_cast<int32_t>(mww.lastProbability);
    gWakeSrProbe.detectAvgUs = mww.averageProbability;
    gWakeSrProbe.detectMaxUs = mww.maxInferenceUs;
    gWakeSrProbe.mwwFeatures = mww.features;
    gWakeSrProbe.mwwInferences = mww.inferences;
    gWakeSrProbe.mwwDetections = mww.detections;
    gWakeSrProbe.mwwInvokeErrors = mww.invokeErrors;
    gWakeSrProbe.mwwFeatureErrors = mww.featureErrors;
    gWakeSrProbe.mwwLastProbability = mww.lastProbability;
    gWakeSrProbe.mwwMaxProbability = mww.maxProbability;
    gWakeSrProbe.mwwAverageProbability = mww.averageProbability;
    gWakeSrProbe.mwwMaxAverageProbability = mww.maxAverageProbability;
    gWakeSrProbe.mwwProbabilityCutoff = mww.probabilityCutoff;
    gWakeSrProbe.mwwSlidingWindowSize = mww.slidingWindowSize;
    gWakeSrProbe.mwwLastDetectionProbability = mww.lastDetectionProbability;
    gWakeSrProbe.mwwLastDetectionAverageProbability = mww.lastDetectionAverageProbability;
    gWakeSrProbe.mwwMaxDetectionAverageProbability = mww.maxDetectionAverageProbability;
    gWakeSrProbe.mwwLastFeatureMin = mww.lastFeatureMin;
    gWakeSrProbe.mwwLastFeatureMax = mww.lastFeatureMax;
    gWakeSrProbe.mwwMinFeatureSeen = mww.minFeatureSeen;
    gWakeSrProbe.mwwMaxFeatureSeen = mww.maxFeatureSeen;
    gWakeSrProbe.mwwLastInferenceUs = mww.lastInferenceUs;
    gWakeSrProbe.mwwMaxInferenceUs = mww.maxInferenceUs;
#if STACKCHAN_MWW_WAKE_DIAG_INTERVAL > 0
    if (mww.inferences > 0 && mww.inferences != lastDiagInference &&
        (mww.inferences % static_cast<uint32_t>(STACKCHAN_MWW_WAKE_DIAG_INTERVAL)) == 0u) {
      lastDiagInference = mww.inferences;
      Serial.print(F("[mww_wake] diag inferences="));
      Serial.print(mww.inferences);
      Serial.print(F(" last_prob="));
      Serial.print(mww.lastProbability);
      Serial.print(F(" max_prob="));
      Serial.print(mww.maxProbability);
      Serial.print(F(" avg_prob="));
      Serial.print(mww.averageProbability);
      Serial.print(F(" feature_min="));
      Serial.print(mww.lastFeatureMin);
      Serial.print(F(" feature_max="));
      Serial.print(mww.lastFeatureMax);
      Serial.print(F(" feature_min_seen="));
      Serial.print(mww.minFeatureSeen);
      Serial.print(F(" feature_max_seen="));
      Serial.print(mww.maxFeatureSeen);
      Serial.print(F(" peak="));
      Serial.print(gWakeSrProbe.audioPeak);
      Serial.print(F(" mean_abs="));
      Serial.println(gWakeSrProbe.audioMeanAbs);
    }
#endif
    if (detected || peakDetected) {
      const uint32_t nowMs = millis();
#if STACKCHAN_ENABLE_WAKE_SERIAL_LOGS
      Serial.print(F("[mww_wake] detection=1 probability="));
      Serial.print(mww.lastProbability);
      Serial.print(F(" avg_probability="));
      Serial.print(mww.averageProbability);
      Serial.print(F(" peak_gate="));
      Serial.print(peakDetected ? 1 : 0);
      Serial.print(F(" peak="));
      Serial.print(gWakeSrProbe.audioPeak);
      Serial.print(F(" at_ms="));
      Serial.println(nowMs);
#endif
      if (lastDetectionMs == 0 || nowMs - lastDetectionMs >= STACKCHAN_MWW_WAKE_COOLDOWN_MS) {
        lastDetectionMs = nowMs;
        queueWakeMwwDetection(nowMs);
      }
    }
    vTaskDelay(pdMS_TO_TICKS(1));
  }
}

void pollWakeMwwProbe(uint32_t nowMs) {
  refreshWakeMwwInteractionLatch(nowMs);
  const uint32_t pending = takeWakeMwwPendingDetections();
  for (uint32_t i = 0; i < pending; ++i) {
    if (gWakeMwwInteractionLatched || !wakeMwwInteractionReadyForWake(nowMs)) {
      suppressWakeMwwDetections(nowMs, 900);
#if STACKCHAN_ENABLE_WAKE_SERIAL_LOGS
      Serial.print(F("[mww_wake] event=wake_word suppressed=1 reason=interaction_busy detections="));
      Serial.print(gWakeSrProbe.wakeDetections);
      Serial.print(F(" at_ms="));
      Serial.println(nowMs);
#endif
      continue;
    }
    RobotEvent event;
    event.type = EventType::WakeWord;
    event.timestampMs = nowMs;
    event.strength = 1.0f;
    gWakeMwwInteractionLatched = true;
    gWakeMwwInteractionLatchedAtMs = nowMs;
    suppressWakeMwwDetections(nowMs, 900);
#if STACKCHAN_ENABLE_BRIDGE_AUDIO_UPLINK && STACKCHAN_MWW_DEDICATED_WAKE_CAPTURE
    const bool scheduled = gWakeCueSequence.begin(nowMs);
    if (scheduled) {
      gWakeMwwPendingCaptureEvent = event;
      gWakeMwwPendingCaptureEventReady = true;
      gIntent.applyEvent(event, CharacterMode::Listen);
      gBodyFeedback.notifyMicActivated(nowMs);
    }
#if STACKCHAN_ENABLE_WAKE_SERIAL_LOGS
    Serial.print(F("[mww_wake] event=wake_word dedicated_capture_scheduled="));
    Serial.print(scheduled ? 1 : 0);
    Serial.print(F(" detections="));
    Serial.print(gWakeSrProbe.wakeDetections);
    Serial.print(F(" applied_total="));
    Serial.print(gWakeSrProbe.wakeEventsApplied);
    Serial.print(F(" at_ms="));
    Serial.println(nowMs);
#endif
#else
    applyWakeEventFromLocalSource(
        event, CharacterMode::Listen, F("mww_wake_probe"), gWakeSrProbe.wakeDetections, nowMs);
    gWakeSrProbe.wakeEventsApplied++;
#if STACKCHAN_ENABLE_WAKE_SERIAL_LOGS
    Serial.print(F("[mww_wake] event=wake_word applied=1 detections="));
    Serial.print(gWakeSrProbe.wakeDetections);
    Serial.print(F(" applied_total="));
    Serial.print(gWakeSrProbe.wakeEventsApplied);
    Serial.print(F(" at_ms="));
    Serial.println(nowMs);
#endif
#endif
  }
}

bool startWakeMwwProbe() {
#if STACKCHAN_ENABLE_WAKE_SERIAL_LOGS
  Serial.print(F("[mww_wake] start_request=1 core="));
  Serial.print(STACKCHAN_MWW_WAKE_TASK_CORE);
  Serial.print(F(" priority="));
  Serial.println(STACKCHAN_MWW_WAKE_TASK_PRIORITY);
#endif
  const BaseType_t ok = xTaskCreatePinnedToCore(
      WakeMwwProbeTask,
      "WakeMww",
      STACKCHAN_MWW_WAKE_TASK_STACK_WORDS,
      nullptr,
      STACKCHAN_MWW_WAKE_TASK_PRIORITY,
      &gWakeSrTaskHandle,
      STACKCHAN_MWW_WAKE_TASK_CORE);
  if (ok != pdPASS) {
    gWakeSrProbe.beginFailures++;
    copyWakeSrError("mww_task_create_failed");
#if STACKCHAN_ENABLE_WAKE_SERIAL_LOGS
    Serial.println(F("[mww_wake] ready=0 error=task_create_failed"));
#endif
    return false;
  }
#if STACKCHAN_ENABLE_WAKE_SERIAL_LOGS
  Serial.println(F("[mww_wake] task_created=1"));
#endif
  return true;
}
#else
bool ensureWakeMwwUplinkQueue() {
  return true;
}

void resetWakeMwwUplinkQueue() {}

void queueWakeMwwUplinkAudio(const int16_t* samples, size_t sampleCount, uint32_t capturedAtMs) {
  (void)samples;
  (void)sampleCount;
  (void)capturedAtMs;
}

void drainWakeMwwUplinkQueue(uint32_t nowMs) {
  (void)nowMs;
}

void pollWakeMwwProbe(uint32_t nowMs) {
  (void)nowMs;
}

bool startWakeMwwProbe() {
#if STACKCHAN_ENABLE_MWW_WAKE_PROBE
  gWakeSrProbe.beginFailures++;
  copyWakeSrError("mww_not_compiled");
#if STACKCHAN_ENABLE_WAKE_SERIAL_LOGS
  Serial.println(F("[mww_wake] ready=0 error=not_compiled"));
#endif
  return false;
#else
  return true;
#endif
}
#endif

void ensureWakeSrStarted(uint32_t nowMs) {
  if (gWakeSrStartAttempted || !gWakeSrProbe.enabled || nowMs < 2500) {
    return;
  }
  gWakeSrStartAttempted = true;
  const uint8_t enabledImplCount =
      (STACKCHAN_ENABLE_SR_WAKE_PROBE ? 1 : 0) + (STACKCHAN_ENABLE_SR_WAKE_DIRECT ? 1 : 0) +
      (STACKCHAN_ENABLE_SR_WAKE_AFE_LITE ? 1 : 0) + (STACKCHAN_ENABLE_MWW_WAKE_PROBE ? 1 : 0);
  if (enabledImplCount > 1) {
  gWakeSrStartOk = false;
  gWakeSrProbe.beginFailures++;
  copyWakeSrError("sr_wake_multiple_impls_enabled");
  Serial.println(F("[sr_wake] startup_complete=1 ok=0 error=multiple_impls_enabled"));
  } else {
  Serial.println(F("[sr_wake] startup_begin=1"));
  const bool wakeSrProbeOk = startWakeSrProbe();
  const bool wakeSrDirectOk = startWakeSrDirect();
  const bool wakeSrAfeLiteOk = startWakeSrAfeLite();
  const bool wakeMwwOk = startWakeMwwProbe();
  gWakeSrStartOk = wakeSrProbeOk && wakeSrDirectOk && wakeSrAfeLiteOk && wakeMwwOk;
  Serial.print(F("[sr_wake] startup_complete=1 ok="));
  Serial.print(gWakeSrStartOk ? 1 : 0);
  Serial.print(F(" probe_ok="));
  Serial.print(wakeSrProbeOk ? 1 : 0);
  Serial.print(F(" direct_ok="));
  Serial.print(wakeSrDirectOk ? 1 : 0);
  Serial.print(F(" afe_ok="));
  Serial.print(wakeSrAfeLiteOk ? 1 : 0);
  Serial.print(F(" mww_ok="));
  Serial.print(wakeMwwOk ? 1 : 0);
  Serial.print(F(" at_ms="));
  Serial.println(nowMs);
  }
}

void printSystemTelemetry() {
#if defined(ARDUINO_ARCH_ESP32)
  sampleChipTemperature(millis(), false);
#endif
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
  Serial.print(stackHighWater(gIntentTaskHandle));
  Serial.print(F(" stack_wake_sr_hwm="));
  Serial.print(stackHighWater(gWakeSrTaskHandle));
  Serial.print(F(" stack_wake_sr_feed_hwm="));
  Serial.print(stackHighWater(gWakeSrFeedTaskHandle));
#if defined(ARDUINO_ARCH_ESP32)
  Serial.print(F(" chip_temp_c="));
  if (gChipTemperatureValid) {
    Serial.print(gChipTemperatureC, 1);
  } else {
    Serial.print(F("null"));
  }
  Serial.print(F(" chip_temp_max_c="));
  if (gChipTemperatureValid) {
    Serial.print(gChipTemperatureMaxC, 1);
  } else {
    Serial.print(F("null"));
  }
  Serial.print(F(" chip_temp_samples="));
  Serial.print(gChipTemperatureSamples);
  Serial.print(F(" chip_temp_read_failures="));
  Serial.print(gChipTemperatureReadFailures);
  Serial.print(F(" power_vbus_mv="));
  Serial.print(gPowerTelemetryValid ? gPowerVbusMv : -1);
  Serial.print(F(" power_vbus_min_mv="));
  Serial.print(gPowerTelemetryValid ? gPowerVbusMinMv : -1);
  Serial.print(F(" power_battery_mv="));
  Serial.print(gPowerTelemetryValid ? gPowerBatteryMv : -1);
  Serial.print(F(" power_battery_level="));
  Serial.print(gPowerTelemetryValid ? gPowerBatteryLevel : -1);
  Serial.print(F(" power_charging_state="));
  Serial.print(gPowerTelemetryValid ? gPowerChargingState : -1);
  Serial.print(F(" power_samples="));
  Serial.print(gPowerTelemetrySamples);
  Serial.print(F(" power_read_failures="));
  Serial.print(gPowerTelemetryReadFailures);
#endif
  Serial.println();
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
  Serial.print(speech.envelope, 2);
  const CameraAdapterTelemetry& camera = gCamera.telemetry();
  Serial.print(F(" camera_ready="));
  Serial.print(camera.ready ? 1 : 0);
  Serial.print(F(" camera_hw="));
  Serial.print(camera.hardwareEnabled ? 1 : 0);
  Serial.print(F(" camera_active="));
  Serial.print(camera.active ? 1 : 0);
  Serial.print(F(" camera_capture_ready="));
  Serial.print(camera.captureReady ? 1 : 0);
  Serial.print(F(" camera_init_failures="));
  Serial.print(camera.initFailures);
  Serial.print(F(" camera_frames="));
  Serial.print(camera.framesCaptured);
  Serial.print(F(" camera_capture_us="));
  Serial.print(camera.lastCaptureUs);
  Serial.print(F(" camera_capture_max_us="));
  Serial.print(camera.maxCaptureUs);
  Serial.print(F(" camera_frame_bytes="));
  Serial.print(camera.lastFrameBytes);
  Serial.print(F(" camera_events="));
  Serial.print(camera.eventsPublished);
  Serial.print(F(" camera_face_batches="));
  Serial.print(camera.faceBatches);
  Serial.print(F(" camera_audio_matches="));
  Serial.print(camera.audioMatchedSelections);
  Serial.print(F(" camera_reply_holds="));
  Serial.print(camera.replyHeldSelections);
  const ImuAdapterTelemetry& imu = gImu.telemetry();
  Serial.print(F(" imu_ready="));
  Serial.print(imu.ready ? 1 : 0);
  Serial.print(F(" imu_calibrated="));
  Serial.print(imu.calibrated ? 1 : 0);
  Serial.print(F(" imu_samples="));
  Serial.print(imu.samples);
  Serial.print(F(" imu_read_retries="));
  Serial.print(imu.readRetries);
  Serial.print(F(" imu_read_recoveries="));
  Serial.print(imu.readRecoveries);
  Serial.print(F(" imu_read_exhaustions="));
  Serial.print(imu.readExhaustions);
  Serial.print(F(" imu_read_exhaustion_recoveries="));
  Serial.print(imu.readExhaustionRecoveries);
  Serial.print(F(" imu_read_exhaustions_consecutive="));
  Serial.print(imu.consecutiveReadExhaustions);
  Serial.print(F(" imu_read_exhaustions_max_consecutive="));
  Serial.print(imu.maxConsecutiveReadExhaustions);
  Serial.print(F(" imu_read_failures="));
  Serial.print(imu.readFailures);
  Serial.print(F(" imu_events="));
  Serial.print(imu.eventsPublished);
  Serial.print(F(" imu_picked_up="));
  Serial.print(imu.pickedUp ? 1 : 0);
  const BodyPeripheralTelemetry& body = gBodyPeripheral.telemetry();
  Serial.print(F(" body_rgb_ready="));
  Serial.print(body.rgbReady ? 1 : 0);
  Serial.print(F(" body_rgb_frames="));
  Serial.print(body.rgbFrames);
  Serial.print(F(" body_rgb_failures="));
  Serial.print(body.rgbWriteFailures);
  Serial.print(F(" body_touch_ready="));
  Serial.print(body.touchReady ? 1 : 0);
  Serial.print(F(" body_touch_samples="));
  Serial.print(body.touchSamples);
  Serial.print(F(" body_touch_events="));
  Serial.print(body.touchEvents);
  const SpeechAdapterTelemetry& speechOut = gSpeechAdapter.telemetry();
  const AudioOutTelemetry& audioOut = gAudioOut.telemetry();
  Serial.print(F(" speech_adapter_ready="));
  Serial.print(speechOut.ready ? 1 : 0);
  Serial.print(F(" speech_adapter_hw="));
  Serial.print(speechOut.hardwareEnabled ? 1 : 0);
  const AudioCaptureTelemetry& capture = gAudioCapture.telemetry();
  Serial.print(F(" audio_capture_ready="));
  Serial.print(capture.ready ? 1 : 0);
  Serial.print(F(" audio_capture_enabled="));
  Serial.print(capture.enabled ? 1 : 0);
  Serial.print(F(" audio_capture_hw_ready="));
  Serial.print(capture.hardwareReady ? 1 : 0);
  Serial.print(F(" audio_capture_windows="));
  Serial.print(capture.windowsCaptured);
  Serial.print(F(" audio_capture_drops="));
  Serial.print(capture.windowsDropped);
  Serial.print(F(" audio_capture_events="));
  Serial.print(capture.eventsPublished);
  Serial.print(F(" audio_capture_level="));
  Serial.print(capture.lastLevel, 3);
  Serial.print(F(" audio_capture_zcr="));
  Serial.print(capture.lastZeroCrossingRate, 3);
  Serial.print(F(" sr_wake_enabled="));
  Serial.print(gWakeSrProbe.enabled ? 1 : 0);
  Serial.print(F(" sr_wake_compiled="));
  Serial.print(gWakeSrProbe.compiled ? 1 : 0);
  Serial.print(F(" sr_wake_wrapper_enabled="));
  Serial.print(gWakeSrProbe.wrapperEnabled ? 1 : 0);
  Serial.print(F(" sr_wake_direct_enabled="));
  Serial.print(gWakeSrProbe.directEnabled ? 1 : 0);
  Serial.print(F(" sr_wake_afe_lite_enabled="));
  Serial.print(gWakeSrProbe.afeLiteEnabled ? 1 : 0);
  Serial.print(F(" sr_wake_mww_enabled="));
  Serial.print(gWakeSrProbe.mwwEnabled ? 1 : 0);
  Serial.print(F(" sr_wake_direct_compiled="));
  Serial.print(gWakeSrProbe.directCompiled ? 1 : 0);
  Serial.print(F(" sr_wake_afe_lite_compiled="));
  Serial.print(gWakeSrProbe.afeLiteCompiled ? 1 : 0);
  Serial.print(F(" sr_wake_mww_compiled="));
  Serial.print(gWakeSrProbe.mwwCompiled ? 1 : 0);
  Serial.print(F(" sr_wake_task_started="));
  Serial.print(gWakeSrProbe.taskStarted ? 1 : 0);
  Serial.print(F(" sr_wake_mic_ready="));
  Serial.print(gWakeSrProbe.micReady ? 1 : 0);
  Serial.print(F(" sr_wake_audio_pause_requested="));
  Serial.print(gWakeSrProbe.audioPauseRequested ? 1 : 0);
  Serial.print(F(" sr_wake_audio_paused="));
  Serial.print(gWakeSrProbe.audioPaused ? 1 : 0);
  Serial.print(F(" sr_wake_audio_pause_requests="));
  Serial.print(gWakeSrProbe.audioPauseRequests);
  Serial.print(F(" sr_wake_audio_pause_enters="));
  Serial.print(gWakeSrProbe.audioPauseEnters);
  Serial.print(F(" sr_wake_audio_resume_requests="));
  Serial.print(gWakeSrProbe.audioResumeRequests);
  Serial.print(F(" sr_wake_audio_resumes="));
  Serial.print(gWakeSrProbe.audioResumes);
  Serial.print(F(" sr_wake_audio_pause_failures="));
  Serial.print(gWakeSrProbe.audioPauseFailures);
  Serial.print(F(" sr_wake_sr_ready="));
  Serial.print(gWakeSrProbe.srReady ? 1 : 0);
  Serial.print(F(" sr_wake_begin_attempts="));
  Serial.print(gWakeSrProbe.beginAttempts);
  Serial.print(F(" sr_wake_begin_failures="));
  Serial.print(gWakeSrProbe.beginFailures);
  Serial.print(F(" sr_wake_start_attempted="));
  Serial.print(gWakeSrStartAttempted ? 1 : 0);
  Serial.print(F(" sr_wake_start_ok="));
  Serial.print(gWakeSrStartOk ? 1 : 0);
  Serial.print(F(" sr_wake_record_ok="));
  Serial.print(gWakeSrProbe.recordOk);
  Serial.print(F(" sr_wake_record_drops="));
  Serial.print(gWakeSrProbe.recordDrops);
  Serial.print(F(" sr_wake_samples="));
  Serial.print(gWakeSrProbe.samplesFed);
  Serial.print(F(" sr_wake_detect_calls="));
  Serial.print(gWakeSrProbe.detectCalls);
  Serial.print(F(" sr_wake_detect_nonzero="));
  Serial.print(gWakeSrProbe.detectNonzero);
  Serial.print(F(" sr_wake_detect_channel_verified="));
  Serial.print(gWakeSrProbe.detectChannelVerified);
  Serial.print(F(" sr_wake_last_detect_result="));
  Serial.print(gWakeSrProbe.lastDetectResult);
  Serial.print(F(" sr_wake_detect_mode="));
  Serial.print(gWakeSrProbe.detectMode);
  Serial.print(F(" sr_wake_detect_avg_us="));
  Serial.print(gWakeSrProbe.detectAvgUs);
  Serial.print(F(" sr_wake_detect_max_us="));
  Serial.print(gWakeSrProbe.detectMaxUs);
  Serial.print(F(" sr_wake_audio_gain_q8="));
  Serial.print(gWakeSrProbe.audioGainQ8);
  Serial.print(F(" sr_wake_audio_peak="));
  Serial.print(gWakeSrProbe.audioPeak);
  Serial.print(F(" sr_wake_audio_peak_max="));
  Serial.print(gWakeSrProbe.audioPeakMax);
  Serial.print(F(" sr_wake_audio_peak_window_max="));
  Serial.print(gWakeSrProbe.audioPeakWindowMax);
  Serial.print(F(" sr_wake_audio_mean_abs="));
  Serial.print(gWakeSrProbe.audioMeanAbs);
  Serial.print(F(" sr_wake_audio_mean_abs_max="));
  Serial.print(gWakeSrProbe.audioMeanAbsMax);
  Serial.print(F(" sr_wake_audio_mean_abs_window_max="));
  Serial.print(gWakeSrProbe.audioMeanAbsWindowMax);
  Serial.print(F(" sr_wake_audio_window_ms="));
  Serial.print(gWakeSrProbe.audioWindowMs);
  Serial.print(F(" sr_wake_audio_peak_l="));
  Serial.print(gWakeSrProbe.audioPeakLeft);
  Serial.print(F(" sr_wake_audio_mean_abs_l="));
  Serial.print(gWakeSrProbe.audioMeanAbsLeft);
  Serial.print(F(" sr_wake_audio_peak_r="));
  Serial.print(gWakeSrProbe.audioPeakRight);
  Serial.print(F(" sr_wake_audio_mean_abs_r="));
  Serial.print(gWakeSrProbe.audioMeanAbsRight);
  Serial.print(F(" sr_wake_audio_clips="));
  Serial.print(gWakeSrProbe.audioClips);
  Serial.print(F(" sr_wake_chunk_samples="));
  Serial.print(gWakeSrProbe.chunkSamples);
  Serial.print(F(" sr_wake_record_samples="));
  Serial.print(gWakeSrProbe.recordSamples);
  Serial.print(F(" sr_wake_audio_channels="));
  Serial.print(gWakeSrProbe.audioChannels);
  Serial.print(F(" sr_wake_sample_rate="));
  Serial.print(gWakeSrProbe.sampleRate);
  Serial.print(F(" sr_wake_mic_magnification="));
  Serial.print(gWakeSrProbe.micMagnification);
  Serial.print(F(" sr_wake_mono_channel="));
  Serial.print(gWakeSrProbe.monoChannel);
  Serial.print(F(" sr_wake_mic_input_stereo="));
  Serial.print(gWakeSrProbe.micInputStereo ? 1 : 0);
  Serial.print(F(" sr_wake_mic_task_core="));
  Serial.print(gWakeSrProbe.micTaskCore);
  Serial.print(F(" sr_wake_mic_task_priority="));
  Serial.print(gWakeSrProbe.micTaskPriority);
  Serial.print(F(" sr_wake_mic_noise_filter="));
  Serial.print(gWakeSrProbe.micNoiseFilterLevel);
  Serial.print(F(" sr_wake_stereo="));
  Serial.print(gWakeSrProbe.stereo ? 1 : 0);
  Serial.print(F(" sr_wake_detections="));
  Serial.print(gWakeSrProbe.wakeDetections);
  Serial.print(F(" sr_wake_events_applied="));
  Serial.print(gWakeSrProbe.wakeEventsApplied);
  Serial.print(F(" sr_wake_last_record_ms="));
  Serial.print(gWakeSrProbe.lastRecordMs);
  Serial.print(F(" sr_wake_last_wake_ms="));
  Serial.print(gWakeSrProbe.lastWakeMs);
  Serial.print(F(" sr_wake_model=\""));
  Serial.print(gWakeSrProbe.modelName);
  Serial.print(F("\" sr_wake_word=\""));
  Serial.print(gWakeSrProbe.wakeWord);
  Serial.print(F("\""));
  Serial.print(F(" sr_wake_error=\""));
  Serial.print(gWakeSrProbe.lastError);
  Serial.print(F("\""));
  Serial.print(F(" speech_cues="));
  Serial.print(speechOut.cuesQueued);
  Serial.print(F(" speech_earcons="));
  Serial.print(speechOut.earconsRendered);
  Serial.print(F(" audio_out_ready="));
  Serial.print(audioOut.ready ? 1 : 0);
  Serial.print(F(" audio_out_hw="));
  Serial.print(audioOut.hardwareEnabled ? 1 : 0);
  Serial.print(F(" audio_out_hw_ready="));
  Serial.print(audioOut.hardwareReady ? 1 : 0);
  Serial.print(F(" audio_out_core0="));
  Serial.print(audioOut.taskPinnedToCore0 ? 1 : 0);
  Serial.print(F(" audio_out_requests="));
  Serial.print(audioOut.requestsQueued);
  Serial.print(F(" audio_out_playing="));
  Serial.print(audioOut.playbackActive ? 1 : 0);
  Serial.print(F(" audio_out_frames="));
  Serial.print(audioOut.speechFramesEmitted);
  Serial.print(F(" audio_out_ducks="));
  Serial.print(audioOut.duckEvents);
  Serial.print(F(" audio_out_hw_frames="));
  Serial.print(audioOut.hardwareFramesSubmitted);
  Serial.print(F(" audio_out_hw_drops="));
  Serial.print(audioOut.hardwareFrameDrops);
  Serial.print(F(" speaker_volume="));
  Serial.print(gSpeakerSink.speakerVolume());
  Serial.print(F(" speaker_enabled="));
  Serial.print(gSpeakerSink.speakerEnabled());
  Serial.print(F(" speaker_running="));
  Serial.print(gSpeakerSink.speakerRunning());
  Serial.print(F(" speaker_power_active="));
  Serial.print(gSpeakerSink.speakerPowerActive());
  Serial.print(F(" speaker_channel_state="));
  Serial.print(gSpeakerSink.speakerChannelState());
  Serial.print(F(" speaker_pin_data_out="));
  Serial.print(gSpeakerSink.speakerPinDataOut());
  Serial.print(F(" speaker_pin_bck="));
  Serial.print(gSpeakerSink.speakerPinBck());
  Serial.print(F(" speaker_pin_ws="));
  Serial.print(gSpeakerSink.speakerPinWs());
  Serial.print(F(" speaker_magnification="));
  Serial.print(gSpeakerSink.speakerMagnification());
  Serial.print(F(" speaker_sample_rate="));
  Serial.print(gSpeakerSink.speakerSampleRate());
  Serial.print(F(" speaker_stream_task_chunks="));
  Serial.print(gSpeakerSink.streamTaskChunks());
  Serial.print(F(" speaker_stream_task_bytes="));
  Serial.print(gSpeakerSink.streamTaskBytes());
  Serial.print(F(" speaker_stream_play_raw_ok="));
  Serial.print(gSpeakerSink.streamPlayRawOk());
  Serial.print(F(" speaker_stream_play_raw_failed="));
  Serial.print(gSpeakerSink.streamPlayRawFailed());
  Serial.print(F(" speaker_stream_chunked="));
  Serial.print(gSpeakerSink.streamPlaybackChunked());
  Serial.print(F(" speaker_stream_first_chunk_delay_ms="));
  Serial.print(gSpeakerSink.streamLastFirstChunkDelayMs());
  Serial.print(F(" speaker_stream_queued_audio_ms="));
  Serial.print(gSpeakerSink.streamLastQueuedAudioMs());
  Serial.print(F(" speaker_stream_queue_wait_max_us="));
  Serial.print(gSpeakerSink.streamQueueWaitMaxUs());
  Serial.print(F(" speaker_stream_release_deferrals="));
  Serial.print(gSpeakerSink.streamReleaseDeferrals());
  Serial.print(F(" speaker_stream_forced_stops="));
  Serial.print(gSpeakerSink.streamForcedStops());
  Serial.print(F(" speaker_tone_ok="));
  Serial.print(gSpeakerSink.diagnosticToneOk());
  Serial.print(F(" speaker_tone_failed="));
  Serial.print(gSpeakerSink.diagnosticToneFailed());
  const BridgeClientTelemetry& bridge = gBridge.telemetry();
  Serial.print(F(" bridge_ready="));
  Serial.print(bridge.ready ? 1 : 0);
  Serial.print(F(" bridge_state="));
  Serial.print(bridgeStateName(bridge.state));
  Serial.print(F(" bridge_messages="));
  Serial.print(bridge.inboundMessages);
  Serial.print(F(" bridge_outputs="));
  Serial.print(bridge.outputsQueued);
  Serial.print(F(" bridge_parse_errors="));
  Serial.print(bridge.parseErrors);
  Serial.print(F(" bridge_audio_streams="));
  Serial.print(bridge.audioStreamsStarted);
  Serial.print(F(" bridge_audio_stream_bytes="));
  Serial.print(bridge.audioStreamBytes);
  Serial.print(F(" bridge_audio_stream_bytes_received="));
  Serial.print(bridge.audioStreamBytesReceived);
  Serial.print(F(" bridge_audio_stream_chunks="));
  Serial.print(bridge.audioStreamChunksReceived);
  Serial.print(F(" bridge_audio_stream_errors="));
  Serial.print(bridge.audioStreamErrors);
  Serial.print(F(" bridge_audio_stream_active="));
  Serial.print(bridge.audioStreamActive ? 1 : 0);
  const BridgeWiFiProvisioningTelemetry& wifi = gBridgeWiFi.telemetry();
  Serial.print(F(" bridge_wifi_ready="));
  Serial.print(wifi.ready ? 1 : 0);
  Serial.print(F(" bridge_wifi_configured="));
  Serial.print(wifi.configured ? 1 : 0);
  Serial.print(F(" bridge_wifi_connecting="));
  Serial.print(wifi.connecting ? 1 : 0);
  Serial.print(F(" bridge_wifi_connected="));
  Serial.print(wifi.connected ? 1 : 0);
  Serial.print(F(" bridge_wifi_attempts="));
  Serial.print(wifi.beginAttempts);
  Serial.print(F(" bridge_wifi_failures="));
  Serial.print(wifi.connectFailures);
  Serial.print(F(" bridge_wifi_status="));
  Serial.print(wifi.status);
#if defined(ARDUINO_ARCH_ESP32)
  Serial.print(F(" bridge_wifi_local_ip="));
  Serial.print(WiFi.localIP());
  Serial.print(F(" bridge_wifi_gateway="));
  Serial.print(WiFi.gatewayIP());
  Serial.print(F(" bridge_wifi_rssi="));
  Serial.print(WiFi.RSSI());
#endif
  const BridgeWiFiProvisioningStoreTelemetry& wifiStore = gBridgeWiFiStore.telemetry();
  Serial.print(F(" bridge_wifi_store_ready="));
  Serial.print(wifiStore.ready ? 1 : 0);
  Serial.print(F(" bridge_wifi_store_has_record="));
  Serial.print(wifiStore.hasRecord ? 1 : 0);
  Serial.print(F(" bridge_wifi_store_loads="));
  Serial.print(wifiStore.loads);
  Serial.print(F(" bridge_wifi_store_saves="));
  Serial.print(wifiStore.saves);
  Serial.print(F(" bridge_wifi_store_clears="));
  Serial.print(wifiStore.clears);
  Serial.print(F(" bridge_wifi_store_parse_errors="));
  Serial.print(wifiStore.parseErrors);
  Serial.print(F(" bridge_wifi_store_write_errors="));
  Serial.print(wifiStore.writeErrors);
  const BridgeNetworkSessionTelemetry& network = gBridgeNetworkSession.telemetry();
  Serial.print(F(" bridge_network_ready="));
  Serial.print(network.ready ? 1 : 0);
  Serial.print(F(" bridge_network_state="));
  Serial.print(bridgeNetworkStateName(network.state));
  Serial.print(F(" bridge_network_connects="));
  Serial.print(network.connectAttempts);
  Serial.print(F(" bridge_network_connect_failures="));
  Serial.print(network.connectFailures);
  Serial.print(F(" bridge_network_handshakes_sent="));
  Serial.print(network.handshakesSent);
  Serial.print(F(" bridge_network_handshakes="));
  Serial.print(network.handshakesAccepted);
  Serial.print(F(" bridge_network_handshakes_failed="));
  Serial.print(network.handshakesFailed);
  Serial.print(F(" bridge_network_reconnects="));
  Serial.print(network.reconnectsScheduled);
  Serial.print(F(" bridge_network_error=\""));
  Serial.print(network.lastError);
  Serial.print(F("\""));
  Serial.print(F(" bridge_network_bytes_in="));
  Serial.print(network.bytesRead);
  Serial.print(F(" bridge_network_bytes_out="));
  Serial.print(network.bytesWritten);
  Serial.print(F(" bridge_network_writer_frames="));
  Serial.print(network.writerFrames);
  Serial.print(F(" bridge_network_writer_text_frames="));
  Serial.print(network.writerTextFrames);
  Serial.print(F(" bridge_network_writer_binary_frames="));
  Serial.print(network.writerBinaryFrames);
  Serial.print(F(" bridge_network_text_queued="));
  Serial.print(gBridgeNetworkSession.writer().telemetry().textFramesQueued);
  Serial.print(F(" bridge_network_text_dropped="));
  Serial.print(gBridgeNetworkSession.writer().telemetry().textFramesDropped);
  Serial.print(F(" bridge_network_binary_queued="));
  Serial.print(gBridgeNetworkSession.writer().telemetry().binaryFramesQueued);
  Serial.print(F(" bridge_network_binary_dropped="));
  Serial.print(gBridgeNetworkSession.writer().telemetry().binaryFramesDropped);
  const BridgeEndpointRegistryTelemetry& endpoints = gBridgeEndpointRegistry.telemetry();
  Serial.print(F(" bridge_endpoint_registry_ready="));
  Serial.print(endpoints.ready ? 1 : 0);
  Serial.print(F(" bridge_endpoint_count="));
  Serial.print(endpoints.trustedCount);
  Serial.print(F(" bridge_endpoint_active="));
  const BridgeEndpointRecord* activeEndpoint = gBridgeEndpointRegistry.activeOwner();
  Serial.print(activeEndpoint == nullptr ? "" : activeEndpoint->endpointId);
  Serial.print(F(" bridge_endpoint_restores="));
  Serial.print(endpoints.restores);
  const BridgeEndpointControlTelemetry& endpointControl = gBridgeEndpointControl.telemetry();
  Serial.print(F(" bridge_endpoint_control_ready="));
  Serial.print(endpointControl.ready ? 1 : 0);
  Serial.print(F(" bridge_endpoint_messages="));
  Serial.print(endpointControl.handledMessages);
  Serial.print(F(" bridge_endpoint_rejected="));
  Serial.print(endpointControl.rejectedMessages);
  Serial.print(F(" bridge_endpoint_pairing_required="));
  Serial.print(gBridgeEndpointControl.pairingCodeRequired() ? 1 : 0);
  Serial.print(F(" bridge_endpoint_pairing_code="));
  Serial.print(gBridgeEndpointControl.requiredPairingCode());
  Serial.print(F(" bridge_endpoint_pairing_rejects="));
  Serial.print(endpointControl.pairingRejects);
  Serial.print(F(" bridge_endpoint_persistence_saves="));
  Serial.print(endpointControl.persistenceSaves);
  Serial.print(F(" bridge_endpoint_persistence_errors="));
  Serial.print(endpointControl.persistenceErrors);
  const BridgeEndpointStoreTelemetry& endpointStore = gBridgeEndpointStore.telemetry();
  Serial.print(F(" bridge_endpoint_store_ready="));
  Serial.print(endpointStore.ready ? 1 : 0);
  Serial.print(F(" bridge_endpoint_store_loads="));
  Serial.print(endpointStore.loads);
  Serial.print(F(" bridge_endpoint_store_saves="));
  Serial.print(endpointStore.saves);
  Serial.print(F(" bridge_endpoint_store_loaded="));
  Serial.print(endpointStore.endpointsLoaded);
  Serial.print(F(" bridge_endpoint_store_saved="));
  Serial.print(endpointStore.endpointsSaved);
  Serial.print(F(" bridge_endpoint_store_parse_errors="));
  Serial.print(endpointStore.parseErrors);
  Serial.print(F(" bridge_endpoint_store_write_errors="));
  Serial.print(endpointStore.writeErrors);
  const BridgeAudioDownlinkTelemetry& downlink = gBridgeAudioDownlink.telemetry();
  Serial.print(F(" bridge_downlink_ready="));
  Serial.print(downlink.ready ? 1 : 0);
  Serial.print(F(" bridge_downlink_active="));
  Serial.print(downlink.active ? 1 : 0);
  Serial.print(F(" bridge_downlink_streams="));
  Serial.print(downlink.streamsStarted);
  Serial.print(F(" bridge_downlink_completed="));
  Serial.print(downlink.streamsCompleted);
  Serial.print(F(" bridge_downlink_chunks="));
  Serial.print(downlink.chunksAccepted);
  Serial.print(F(" bridge_downlink_bytes="));
  Serial.print(downlink.bytesAccepted);
  Serial.print(F(" bridge_downlink_errors="));
  Serial.print(downlink.errors);
  Serial.print(F(" bridge_downlink_playback_ready="));
  Serial.print(downlink.playbackReady ? 1 : 0);
  Serial.print(F(" bridge_downlink_playback_enabled="));
  Serial.print(downlink.playbackEnabled ? 1 : 0);
  Serial.print(F(" bridge_downlink_playback_active="));
  Serial.print(downlink.playbackActive ? 1 : 0);
  Serial.print(F(" bridge_downlink_playback_starts="));
  Serial.print(downlink.playbackStarts);
  Serial.print(F(" bridge_downlink_playback_chunks="));
  Serial.print(downlink.playbackChunks);
  Serial.print(F(" bridge_downlink_playback_bytes="));
  Serial.print(downlink.playbackBytes);
  Serial.print(F(" bridge_downlink_playback_unsupported="));
  Serial.print(downlink.playbackUnsupported);
  Serial.print(F(" bridge_downlink_playback_errors="));
  Serial.print(downlink.playbackErrors);
  const BridgeAudioUplinkTelemetry& uplink = gBridgeAudioUplink.telemetry();
  Serial.print(F(" bridge_uplink_ready="));
  Serial.print(uplink.ready ? 1 : 0);
  Serial.print(F(" bridge_uplink_enabled="));
  Serial.print(uplink.enabled ? 1 : 0);
  Serial.print(F(" bridge_uplink_active="));
  Serial.print(uplink.active ? 1 : 0);
  Serial.print(F(" bridge_uplink_wake_gate_required="));
  Serial.print(uplink.wakeGateRequired ? 1 : 0);
  Serial.print(F(" bridge_uplink_turns="));
  Serial.print(uplink.turnsStarted);
  Serial.print(F(" bridge_uplink_completed="));
  Serial.print(uplink.turnsCompleted);
  Serial.print(F(" bridge_uplink_aborted="));
  Serial.print(uplink.turnsAborted);
  Serial.print(F(" bridge_uplink_chunks="));
  Serial.print(uplink.chunksQueued);
  Serial.print(F(" bridge_uplink_bytes="));
  Serial.print(uplink.bytesQueued);
  Serial.print(F(" bridge_uplink_errors="));
  Serial.print(uplink.errors);
  Serial.print(F(" bridge_uplink_gate_blocks="));
  Serial.print(uplink.gateBlocks);
  Serial.print(F(" bridge_uplink_queue_failures="));
  Serial.print(uplink.queueFailures);
  Serial.print(F(" bridge_uplink_last_seq="));
  Serial.print(uplink.lastSeq);
#if STACKCHAN_HAS_MWW_WAKE_PROBE && STACKCHAN_ENABLE_BRIDGE_AUDIO_UPLINK && STACKCHAN_MWW_WAKE_DRIVES_AUDIO_UPLINK
  Serial.print(F(" mww_uplink_pending="));
  Serial.print(gWakeMwwUplinkPendingReady ? 1 : 0);
  Serial.print(F(" mww_uplink_queued="));
  Serial.print(gWakeMwwUplinkQueued);
  Serial.print(F(" mww_uplink_dropped="));
  Serial.print(gWakeMwwUplinkDropped);
  Serial.print(F(" mww_uplink_submitted="));
  Serial.print(gWakeMwwUplinkSubmitted);
  Serial.print(F(" mww_uplink_submit_failed="));
  Serial.print(gWakeMwwUplinkSubmitFailed);
  Serial.print(F(" mww_uplink_reset="));
  Serial.print(gWakeMwwUplinkReset);
#endif
  const BridgeWakeGateTelemetry& wakeGate = gBridgeWakeGate.telemetry();
  Serial.print(F(" bridge_wake_gate_ready="));
  Serial.print(wakeGate.ready ? 1 : 0);
  Serial.print(F(" bridge_wake_gate_speech_start="));
  Serial.print(wakeGate.speechStartsTurn ? 1 : 0);
  Serial.print(F(" bridge_wake_gate_open="));
  Serial.print(wakeGate.gateOpen ? 1 : 0);
  Serial.print(F(" bridge_wake_gate_turn_active="));
  Serial.print(wakeGate.turnActive ? 1 : 0);
  Serial.print(F(" bridge_wake_gate_opens="));
  Serial.print(wakeGate.gatesOpened);
  Serial.print(F(" bridge_wake_gate_expired="));
  Serial.print(wakeGate.gatesExpired);
  Serial.print(F(" bridge_wake_gate_turns="));
  Serial.print(wakeGate.turnsStarted);
  Serial.print(F(" bridge_wake_gate_completed="));
  Serial.print(wakeGate.turnsCompleted);
  Serial.print(F(" bridge_wake_gate_suppressed="));
  Serial.print(wakeGate.suppressedStarts);
  Serial.print(F(" bridge_wake_gate_error=\""));
  Serial.print(wakeGate.lastError);
  Serial.print(F("\""));
  Serial.print(F(" bridge_timeouts="));
  Serial.println(bridge.timeouts);
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

void printSpeechPlayback(const SpeechPlaybackPlan& plan) {
  Serial.print(F("[speech_audio] seq="));
  Serial.print(plan.seq);
  Serial.print(F(" queued_ms="));
  Serial.print(plan.queuedAtMs);
  Serial.print(F(" intent="));
  Serial.print(speechIntentName(plan.intent));
  Serial.print(F(" source="));
  Serial.print(promptSourceName(plan.promptSource));
  Serial.print(F(" prompt_id="));
  Serial.print(plan.promptId);
  Serial.print(F(" prompt_wav="));
  Serial.print(plan.promptWavPath);
  Serial.print(F(" prompt_sidecar="));
  Serial.print(plan.promptSidecarPath);
  Serial.print(F(" prompt_chars="));
  Serial.print(plan.promptChars);
  Serial.print(F(" earcon="));
  Serial.print(speechEarconName(plan.earcon));
  Serial.print(F(" earcon_delay_ms="));
  Serial.print(plan.earconDelayMs);
  Serial.print(F(" earcon_samples="));
  Serial.print(plan.earconRender.samplesWritten);
  Serial.print(F(" earcon_peak="));
  Serial.print(plan.earconRender.peakAbs);
  Serial.print(F(" earcon_checksum="));
  Serial.println(plan.earconRender.checksum, HEX);
}

void printAudioOutPlayback(const AudioOutPlaybackRequest& request) {
  Serial.print(F("[audio_out] seq="));
  Serial.print(request.seq);
  Serial.print(F(" source="));
  Serial.print(audioOutSourceName(request.source));
  Serial.print(F(" prompt_id="));
  Serial.print(request.promptId);
  Serial.print(F(" wav="));
  Serial.print(request.wavPath);
  Serial.print(F(" sidecar="));
  Serial.print(request.sidecarPath);
  Serial.print(F(" earcon_samples="));
  Serial.print(request.earconSamples);
  Serial.print(F(" sidecar_frames="));
  Serial.print(gAudioOut.telemetry().sidecarFrames);
  Serial.print(F(" sidecar_frame_ms="));
  Serial.print(gAudioOut.telemetry().sidecarFrameMs);
  Serial.print(F(" playback_ms="));
  Serial.print(gAudioOut.telemetry().playbackDurationMs);
  Serial.print(F(" hw_ready="));
  Serial.print(gAudioOut.telemetry().hardwareReady ? 1 : 0);
  Serial.print(F(" hw_playing="));
  Serial.print(gAudioOut.telemetry().hardwarePlaybackActive ? 1 : 0);
  Serial.print(F(" hw_starts="));
  Serial.print(gAudioOut.telemetry().hardwareStarts);
  Serial.print(F(" duck_on_barge_in="));
  Serial.println(request.duckOnBargeIn ? 1 : 0);
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
  if (control.hasBridge) {
    Serial.print(F(" bridge_line=\""));
    Serial.print(control.bridge.controlLine);
    Serial.print(F("\""));
  }
  if (control.hasBridgeUpload) {
    Serial.print(F(" bridge_uplink_action="));
    Serial.print(bridgeUploadActionName(control.bridgeUpload.action));
    Serial.print(F(" bridge_uplink_seq="));
    Serial.print(control.bridgeUpload.seq);
    Serial.print(F(" bridge_uplink_bytes="));
    Serial.print(control.bridgeUpload.bytes);
    Serial.print(F(" bridge_uplink_wake="));
    Serial.print(control.bridgeUpload.wakeGateOpen ? 1 : 0);
  }
  if (control.hasBridgeTextTurn) {
    Serial.print(F(" bridge_text_seq="));
    Serial.print(control.bridgeTextTurn.seq);
    Serial.print(F(" bridge_text=\""));
    Serial.print(control.bridgeTextTurn.text);
    Serial.print(F("\""));
  }
  if (control.hasSpeakerTest) {
    Serial.print(F(" speaker_test=1"));
  }
  if (control.hasMicCueTest) {
    Serial.print(F(" mic_cue_test=1"));
  }
  if (control.hasPairingControl) {
    Serial.print(F(" pairing_action="));
    Serial.print(control.pairing.clear ? F("clear") : F("set"));
    if (!control.pairing.clear) {
      Serial.print(F(" pairing_code="));
      Serial.print(control.pairing.code);
    }
  }
  if (control.hasPairingTicket) {
    Serial.print(F(" pairing_ticket=1"));
    Serial.print(F(" ticket_bridge_host="));
    Serial.print(control.pairingTicket.bridgeHost);
    Serial.print(F(" ticket_bridge_port="));
    Serial.print(control.pairingTicket.bridgePort);
    Serial.print(F(" ticket_bridge_path="));
    Serial.print(control.pairingTicket.bridgePath);
    Serial.print(F(" ticket_endpoint_id="));
    Serial.print(control.pairingTicket.endpointId);
    Serial.print(F(" ticket_fingerprint_set="));
    Serial.print(control.pairingTicket.fingerprint[0] != '\0' ? 1 : 0);
  }
  if (control.hasWiFiProvisioning) {
    Serial.print(F(" wifi_action="));
    Serial.print(control.wifi.clear ? F("clear") : F("set"));
    if (!control.wifi.clear) {
      Serial.print(F(" wifi_ssid_set="));
      Serial.print(control.wifi.ssid[0] != '\0' ? 1 : 0);
      Serial.print(F(" wifi_host="));
      Serial.print(control.wifi.bridgeHost);
      Serial.print(F(" wifi_port="));
      Serial.print(control.wifi.bridgePort);
      Serial.print(F(" wifi_path="));
      Serial.print(control.wifi.bridgePath);
    }
  }
  Serial.print(F(" at_ms="));
  Serial.println(control.hasEvent ? control.event.timestampMs : millis());
}

void printBridgeUplinkResult(BenchBridgeUploadAction action,
                             bool accepted,
                             uint32_t seq,
                             uint16_t bytes,
                             uint32_t nowMs) {
  const BridgeAudioUplinkTelemetry& uplink = gBridgeAudioUplink.telemetry();
  Serial.print(F("[bridge_uplink] action="));
  Serial.print(bridgeUploadActionName(action));
  Serial.print(F(" result="));
  Serial.print(accepted ? F("accepted") : F("rejected"));
  Serial.print(F(" seq="));
  Serial.print(seq);
  Serial.print(F(" bytes="));
  Serial.print(bytes);
  Serial.print(F(" active="));
  Serial.print(uplink.active ? 1 : 0);
  Serial.print(F(" chunks="));
  Serial.print(uplink.chunksQueued);
  Serial.print(F(" queued_bytes="));
  Serial.print(uplink.bytesQueued);
  Serial.print(F(" gate_blocks="));
  Serial.print(uplink.gateBlocks);
  Serial.print(F(" queue_failures="));
  Serial.print(uplink.queueFailures);
  Serial.print(F(" errors="));
  Serial.print(uplink.errors);
  Serial.print(F(" error=\""));
  Serial.print(uplink.lastError);
  Serial.print(F("\" at_ms="));
  Serial.println(nowMs);
}

void handleBridgeUplinkBench(const BenchBridgeUpload& upload, uint32_t nowMs) {
  bool accepted = false;
  uint16_t bytes = upload.bytes;
  uint8_t payload[512] = {};

  switch (upload.action) {
    case BenchBridgeUploadAction::Start:
      accepted = gBridgeAudioUplink.beginTurn(upload.seq, nowMs, upload.wakeGateOpen);
      break;
    case BenchBridgeUploadAction::Chunk:
      if (bytes > sizeof(payload)) {
        bytes = sizeof(payload);
      }
      if ((bytes & 1u) != 0) {
        bytes--;
      }
      for (uint16_t i = 0; i < bytes; ++i) {
        payload[i] = static_cast<uint8_t>((upload.seq + i) & 0xffu);
      }
      accepted = gBridgeAudioUplink.submitPcmBytes(upload.seq, payload, bytes, nowMs);
      break;
    case BenchBridgeUploadAction::End:
      accepted = gBridgeAudioUplink.endTurn(upload.seq, nowMs);
      break;
    case BenchBridgeUploadAction::Abort:
      gBridgeAudioUplink.abort(nowMs, "bench_audio_uplink_abort");
      accepted = true;
      bytes = 0;
      break;
    case BenchBridgeUploadAction::None:
      accepted = false;
      bytes = 0;
      break;
  }

  printBridgeUplinkResult(upload.action, accepted, upload.seq, bytes, nowMs);
}

void printBridgeTextTurnResult(const BenchBridgeTextTurn& turn,
                               bool accepted,
                               uint32_t nowMs,
                               const char* error) {
  Serial.print(F("[bridge_text_turn] result="));
  Serial.print(accepted ? F("accepted") : F("rejected"));
  Serial.print(F(" seq="));
  Serial.print(turn.seq);
  Serial.print(F(" text=\""));
  Serial.print(turn.text);
  Serial.print(F("\" network_state="));
  Serial.print(bridgeNetworkStateName(gBridgeNetworkSession.telemetry().state));
  Serial.print(F(" error=\""));
  Serial.print(error == nullptr ? "" : error);
  Serial.print(F("\" at_ms="));
  Serial.println(nowMs);
}

void handleBridgeTextTurnBench(const BenchBridgeTextTurn& turn, uint32_t nowMs) {
  char text[96] = {};
  const char* sourceText = turn.text[0] != '\0' ? turn.text : "hello stackchan";
  strncpy(text, sourceText, sizeof(text) - 1u);
  text[sizeof(text) - 1u] = '\0';
  for (size_t i = 0; text[i] != '\0'; ++i) {
    if (text[i] == '"' || text[i] == '\\') {
      text[i] = '\'';
    }
  }

  char frame[kBridgeEndpointControlResponseMax] = {};
  const int written = snprintf(frame,
                               sizeof(frame),
                               "{\"type\":\"utterance_end\",\"seq\":%lu,\"text\":\"%s\"}",
                               static_cast<unsigned long>(turn.seq),
                               text);
  const bool accepted = written > 0 && static_cast<size_t>(written) < sizeof(frame) &&
                        gBridgeNetworkSession.queueTextFrame(frame);
  const char* error = accepted ? "" : gBridgeNetworkSession.writer().telemetry().lastError;
  printBridgeTextTurnResult(turn, accepted, nowMs, error);
}

void copyRuntimeString(char* out, size_t outSize, const char* value) {
  if (out == nullptr || outSize == 0) {
    return;
  }
  out[0] = '\0';
  if (value == nullptr) {
    return;
  }
  strncpy(out, value, outSize - 1u);
  out[outSize - 1u] = '\0';
}

void restartBridgeWiFi(const BridgeWiFiProvisioningConfig& config, uint32_t nowMs) {
  gBridgeNetworkSession.stop(nowMs);
  gBridgeWiFi.begin(config, nowMs);
  gBridgeNetworkSession.begin(gBridge, gBridgeSocket, gBridgeWiFi.networkSessionConfig(), nowMs);
  gBridgeNetworkSession.attachEndpointControl(&gBridgeEndpointControl);
}

BridgeWiFiProvisioningConfig runtimeBridgeWiFiConfig() {
  BridgeWiFiProvisioningConfig config;
  config.enabled = true;
  config.ssid = gRuntimeWiFiSsid;
  config.password = gRuntimeWiFiPassword;
  config.bridgeHost = gRuntimeBridgeHost;
  config.bridgePort = gRuntimeBridgePort;
  config.bridgePath = gRuntimeBridgePath;
  return config;
}

BridgeWiFiProvisioningConfig activeBridgeWiFiConfig() {
  if (gRuntimeWiFiSsid[0] != '\0' || gRuntimeBridgeHost[0] != '\0') {
    return runtimeBridgeWiFiConfig();
  }
  return BridgeWiFiProvisioningConfig {};
}

void restartBridgeNetworkSession(uint32_t nowMs) {
  gBridgeNetworkSession.stop(nowMs);
  gBridgeNetworkSession.begin(gBridge, gBridgeSocket, gBridgeWiFi.networkSessionConfig(), nowMs);
  gBridgeNetworkSession.attachEndpointControl(&gBridgeEndpointControl);
}

void noteBridgeRecovery(const char* reason, uint32_t nowMs) {
  gBridgeRecovery.lastRecoveryMs = nowMs;
  gBridgeRecovery.lastReason = reason != nullptr ? reason : "";
  gBridgeRecovery.wifiOfflineSinceMs = 0;
  gBridgeRecovery.bridgeOfflineSinceMs = 0;
  gBridgeRecovery.scheduledRecoveryMs = 0;
  Serial.print(F("[recovery] action=bridge_recover reason="));
  Serial.print(gBridgeRecovery.lastReason);
  Serial.print(F(" wifi_restarts="));
  Serial.print(gBridgeRecovery.wifiRestarts);
  Serial.print(F(" bridge_restarts="));
  Serial.print(gBridgeRecovery.bridgeRestarts);
  Serial.print(F(" at_ms="));
  Serial.println(nowMs);
}

void recoverBridgeWiFi(const char* reason, uint32_t nowMs) {
  gBridgeRecovery.wifiRestarts++;
  restartBridgeWiFi(activeBridgeWiFiConfig(), nowMs);
  noteBridgeRecovery(reason, nowMs);
}

void recoverBridgeNetwork(const char* reason, uint32_t nowMs) {
  gBridgeRecovery.bridgeRestarts++;
  restartBridgeNetworkSession(nowMs);
  noteBridgeRecovery(reason, nowMs);
}

void requestBridgeReboot(const char* reason, uint32_t nowMs) {
#if defined(ARDUINO_ARCH_ESP32)
  if (gBridgeRecovery.scheduledRebootMs == 0) {
    gBridgeRecovery.rebootRequests++;
    gBridgeRecovery.scheduledRebootMs = nowMs + STACKCHAN_REMOTE_REBOOT_DELAY_MS;
    gBridgeRecovery.lastReason = reason != nullptr ? reason : "";
    Serial.print(F("[recovery] action=reboot_scheduled reason="));
    Serial.print(gBridgeRecovery.lastReason);
    Serial.print(F(" at_ms="));
    Serial.println(nowMs);
  }
#else
  (void)reason;
  (void)nowMs;
#endif
}

void serviceBridgeRecovery(uint32_t nowMs) {
#if defined(ARDUINO_ARCH_ESP32) && STACKCHAN_REMOTE_RECOVERY_ENABLE != 0
  if (gBridgeRecovery.scheduledRebootMs != 0 &&
      static_cast<int32_t>(nowMs - gBridgeRecovery.scheduledRebootMs) >= 0) {
    Serial.print(F("[recovery] action=reboot_now reason="));
    Serial.print(gBridgeRecovery.lastReason);
    Serial.print(F(" at_ms="));
    Serial.println(nowMs);
    delay(20);
    ESP.restart();
    return;
  }

  if (gBridgeRecovery.scheduledRecoveryMs != 0 &&
      static_cast<int32_t>(nowMs - gBridgeRecovery.scheduledRecoveryMs) >= 0) {
    gBridgeRecovery.recoveryRequested = false;
    recoverBridgeWiFi("remote_recover", nowMs);
    return;
  }

  const BridgeWiFiProvisioningTelemetry& wifi = gBridgeWiFi.telemetry();
  const BridgeNetworkSessionTelemetry& network = gBridgeNetworkSession.telemetry();
  if (!wifi.ready || !wifi.configured) {
    gBridgeRecovery.recoveryRequested = false;
    gBridgeRecovery.scheduledRecoveryMs = 0;
    gBridgeRecovery.wifiOfflineSinceMs = 0;
    gBridgeRecovery.bridgeOfflineSinceMs = 0;
    return;
  }

  const bool cooldownElapsed = gBridgeRecovery.lastRecoveryMs == 0 ||
                               nowMs - gBridgeRecovery.lastRecoveryMs >= STACKCHAN_RECOVERY_RESTART_COOLDOWN_MS;
  if (gBridgeRecovery.recoveryRequested) {
    if (gBridgeRecovery.scheduledRecoveryMs == 0) {
      gBridgeRecovery.scheduledRecoveryMs = nowMs + STACKCHAN_REMOTE_RECOVERY_DELAY_MS;
    }
  }

  if (!wifi.connected) {
    if (gBridgeRecovery.wifiOfflineSinceMs == 0) {
      gBridgeRecovery.wifiOfflineSinceMs = nowMs;
    }
    gBridgeRecovery.bridgeOfflineSinceMs = 0;
    const uint32_t offlineMs = nowMs - gBridgeRecovery.wifiOfflineSinceMs;
    if (offlineMs >= STACKCHAN_RECOVERY_REBOOT_MS) {
      requestBridgeReboot("wifi_offline_timeout", nowMs);
      return;
    }
    if (offlineMs >= STACKCHAN_RECOVERY_WIFI_RESTART_MS && cooldownElapsed) {
      recoverBridgeWiFi("wifi_offline_timeout", nowMs);
    }
    return;
  }

  gBridgeRecovery.wifiOfflineSinceMs = 0;
  if (network.state != BridgeNetworkSessionState::Connected) {
    if (gBridgeRecovery.bridgeOfflineSinceMs == 0) {
      gBridgeRecovery.bridgeOfflineSinceMs = nowMs;
    }
    const uint32_t offlineMs = nowMs - gBridgeRecovery.bridgeOfflineSinceMs;
    if (offlineMs >= STACKCHAN_RECOVERY_REBOOT_MS) {
      requestBridgeReboot("bridge_offline_timeout", nowMs);
      return;
    }
    if (offlineMs >= STACKCHAN_RECOVERY_BRIDGE_RESTART_MS && cooldownElapsed) {
      recoverBridgeNetwork("bridge_offline_timeout", nowMs);
    }
    return;
  }

  gBridgeRecovery.bridgeOfflineSinceMs = 0;
#else
  (void)nowMs;
#endif
}

BridgeWiFiProvisioningRecord runtimeBridgeWiFiRecord() {
  BridgeWiFiProvisioningRecord record;
  record.enabled = true;
  copyRuntimeString(record.ssid, sizeof(record.ssid), gRuntimeWiFiSsid);
  copyRuntimeString(record.password, sizeof(record.password), gRuntimeWiFiPassword);
  copyRuntimeString(record.bridgeHost, sizeof(record.bridgeHost), gRuntimeBridgeHost);
  record.bridgePort = gRuntimeBridgePort;
  copyRuntimeString(record.bridgePath, sizeof(record.bridgePath), gRuntimeBridgePath);
  return record;
}

BridgeWiFiProvisioningConfig storedBridgeWiFiConfigOrDefault(uint32_t nowMs) {
#if STACKCHAN_ENABLE_WIFI_BRIDGE != 0
  if (STACKCHAN_WIFI_SSID[0] != '\0' && STACKCHAN_BRIDGE_HOST[0] != '\0') {
    BridgeWiFiProvisioningRecord ignoredRecord;
    gBridgeWiFiStore.load(ignoredRecord, nowMs);
    return BridgeWiFiProvisioningConfig {};
  }
#endif
  BridgeWiFiProvisioningRecord record;
  if (!gBridgeWiFiStore.load(record, nowMs) || !record.enabled) {
    return BridgeWiFiProvisioningConfig {};
  }
  copyRuntimeString(gRuntimeWiFiSsid, sizeof(gRuntimeWiFiSsid), record.ssid);
  copyRuntimeString(gRuntimeWiFiPassword, sizeof(gRuntimeWiFiPassword), record.password);
  copyRuntimeString(gRuntimeBridgeHost, sizeof(gRuntimeBridgeHost), record.bridgeHost);
  copyRuntimeString(gRuntimeBridgePath, sizeof(gRuntimeBridgePath),
                    record.bridgePath[0] != '\0' ? record.bridgePath : "/bridge");
  gRuntimeBridgePort = record.bridgePort == 0 ? STACKCHAN_BRIDGE_PORT : record.bridgePort;
  return runtimeBridgeWiFiConfig();
}

void handleWiFiProvisioningControl(const BenchWiFiProvisioningControl& wifi, uint32_t nowMs) {
  BridgeWiFiProvisioningConfig config;
  const char* action = "set";
  bool persisted = false;
  if (wifi.clear) {
    action = "clear";
    gRuntimeWiFiSsid[0] = '\0';
    gRuntimeWiFiPassword[0] = '\0';
    gRuntimeBridgeHost[0] = '\0';
    copyRuntimeString(gRuntimeBridgePath, sizeof(gRuntimeBridgePath), "/bridge");
    gRuntimeBridgePort = STACKCHAN_BRIDGE_PORT;
    persisted = gBridgeWiFiStore.clear(nowMs);
    config = BridgeWiFiProvisioningConfig {};
  } else {
    copyRuntimeString(gRuntimeWiFiSsid, sizeof(gRuntimeWiFiSsid), wifi.ssid);
    copyRuntimeString(gRuntimeWiFiPassword, sizeof(gRuntimeWiFiPassword), wifi.password);
    copyRuntimeString(gRuntimeBridgeHost, sizeof(gRuntimeBridgeHost), wifi.bridgeHost);
    copyRuntimeString(gRuntimeBridgePath, sizeof(gRuntimeBridgePath),
                      wifi.bridgePath[0] != '\0' ? wifi.bridgePath : "/bridge");
    gRuntimeBridgePort = wifi.bridgePort == 0 ? STACKCHAN_BRIDGE_PORT : wifi.bridgePort;

    persisted = gBridgeWiFiStore.save(runtimeBridgeWiFiRecord(), nowMs);
    config = runtimeBridgeWiFiConfig();
  }

  restartBridgeWiFi(config, nowMs);
  const BridgeWiFiProvisioningTelemetry& telemetry = gBridgeWiFi.telemetry();
  const BridgeWiFiProvisioningStoreTelemetry& store = gBridgeWiFiStore.telemetry();
  const BridgeNetworkSessionTelemetry& network = gBridgeNetworkSession.telemetry();
  Serial.print(F("[wifi] action="));
  Serial.print(action);
  Serial.print(F(" result="));
  Serial.print(telemetry.configured ? F("configured") : F("not_configured"));
  Serial.print(F(" persisted="));
  Serial.print(persisted ? 1 : 0);
  Serial.print(F(" store_ready="));
  Serial.print(store.ready ? 1 : 0);
  Serial.print(F(" store_has_record="));
  Serial.print(store.hasRecord ? 1 : 0);
  Serial.print(F(" store_saves="));
  Serial.print(store.saves);
  Serial.print(F(" store_clears="));
  Serial.print(store.clears);
  Serial.print(F(" store_errors="));
  Serial.print(store.parseErrors + store.writeErrors + store.rejected);
  Serial.print(F(" enabled="));
  Serial.print(config.enabled ? 1 : 0);
  Serial.print(F(" ssid_set="));
  Serial.print(config.ssid != nullptr && config.ssid[0] != '\0' ? 1 : 0);
  Serial.print(F(" host="));
  Serial.print(config.bridgeHost != nullptr ? config.bridgeHost : "");
  Serial.print(F(" port="));
  Serial.print(config.bridgePort);
  Serial.print(F(" path="));
  Serial.print(config.bridgePath != nullptr ? config.bridgePath : "");
  Serial.print(F(" attempts="));
  Serial.print(telemetry.beginAttempts);
  Serial.print(F(" network_state="));
  Serial.print(bridgeNetworkStateName(network.state));
  Serial.print(F(" error=\""));
  Serial.print(telemetry.lastError);
  Serial.print(F("\" at_ms="));
  Serial.println(nowMs);
}

void handlePairingControl(const BenchPairingControl& pairing, uint32_t nowMs) {
  const bool accepted = pairing.clear ? true : gBridgeEndpointControl.setRequiredPairingCode(pairing.code);
  if (pairing.clear) {
    gBridgeEndpointControl.clearRequiredPairingCode();
  }
  Serial.print(F("[pairing] action="));
  Serial.print(pairing.clear ? F("clear") : F("set"));
  Serial.print(F(" result="));
  Serial.print(accepted ? F("accepted") : F("rejected"));
  Serial.print(F(" required="));
  Serial.print(gBridgeEndpointControl.pairingCodeRequired() ? 1 : 0);
  Serial.print(F(" code="));
  Serial.print(gBridgeEndpointControl.requiredPairingCode());
  Serial.print(F(" at_ms="));
  Serial.println(nowMs);
}

void handlePairingTicketControl(const BenchPairingTicketControl& ticket, uint32_t nowMs) {
  const bool pairingAccepted = gBridgeEndpointControl.setRequiredPairingCode(ticket.code);
  bool bridgeUpdated = false;
  bool persisted = false;
  bool ssidAvailable = false;

  if (ticket.bridgeHost[0] != '\0') {
    const char* ssid = gRuntimeWiFiSsid[0] != '\0' ? gRuntimeWiFiSsid : STACKCHAN_WIFI_SSID;
    const char* password =
        gRuntimeWiFiSsid[0] != '\0' ? gRuntimeWiFiPassword : STACKCHAN_WIFI_PASSWORD;
    ssidAvailable = ssid != nullptr && ssid[0] != '\0';
    if (ssidAvailable) {
      copyRuntimeString(gRuntimeWiFiSsid, sizeof(gRuntimeWiFiSsid), ssid);
      copyRuntimeString(gRuntimeWiFiPassword, sizeof(gRuntimeWiFiPassword), password);
      copyRuntimeString(gRuntimeBridgeHost, sizeof(gRuntimeBridgeHost), ticket.bridgeHost);
      copyRuntimeString(gRuntimeBridgePath, sizeof(gRuntimeBridgePath),
                        ticket.bridgePath[0] != '\0' ? ticket.bridgePath : "/bridge");
      gRuntimeBridgePort = ticket.bridgePort == 0 ? STACKCHAN_BRIDGE_PORT : ticket.bridgePort;
      persisted = gBridgeWiFiStore.save(runtimeBridgeWiFiRecord(), nowMs);
      restartBridgeWiFi(runtimeBridgeWiFiConfig(), nowMs);
      bridgeUpdated = true;
    }
  }

  const BridgeWiFiProvisioningStoreTelemetry& store = gBridgeWiFiStore.telemetry();
  Serial.print(F("[pairing_ticket] result="));
  Serial.print(pairingAccepted ? F("accepted") : F("rejected"));
  Serial.print(F(" pairing_required="));
  Serial.print(gBridgeEndpointControl.pairingCodeRequired() ? 1 : 0);
  Serial.print(F(" code="));
  Serial.print(gBridgeEndpointControl.requiredPairingCode());
  Serial.print(F(" bridge_url_applied="));
  Serial.print(bridgeUpdated ? 1 : 0);
  Serial.print(F(" bridge_ssid_available="));
  Serial.print(ssidAvailable ? 1 : 0);
  Serial.print(F(" persisted="));
  Serial.print(persisted ? 1 : 0);
  Serial.print(F(" store_has_record="));
  Serial.print(store.hasRecord ? 1 : 0);
  Serial.print(F(" host="));
  Serial.print(ticket.bridgeHost);
  Serial.print(F(" port="));
  Serial.print(ticket.bridgePort);
  Serial.print(F(" path="));
  Serial.print(ticket.bridgePath);
  Serial.print(F(" endpoint_id="));
  Serial.print(ticket.endpointId);
  Serial.print(F(" fingerprint_set="));
  Serial.print(ticket.fingerprint[0] != '\0' ? 1 : 0);
  Serial.print(F(" at_ms="));
  Serial.println(nowMs);
}

void submitCapturedAudioWindowToBridgeUplink(uint32_t nowMs) {
  gBridgeWakeGate.update(nowMs);
  const BridgeAudioUplinkTelemetry& uplink = gBridgeAudioUplink.telemetry();
  if (!uplink.active) {
    return;
  }

  const int16_t* samples = gAudioCapture.lastPcmWindow();
  const uint16_t sampleCount = gAudioCapture.lastPcmSampleCount();
  if (samples == nullptr || sampleCount == 0) {
    return;
  }

  gBridgeAudioUplink.submitPcmChunk(uplink.lastSeq, samples, sampleCount, nowMs);
}

void playMicActivationCueIfNeeded() {
#if STACKCHAN_HAS_MWW_WAKE_PROBE && STACKCHAN_MWW_DEDICATED_WAKE_CAPTURE
  // Dedicated wake capture owns cue ordering before it opens the uplink.
  return;
#endif
#if STACKCHAN_ENABLE_BRIDGE_AUDIO_UPLINK
  static uint32_t sLastUplinkTurnsStarted = 0;
  const BridgeWakeGateTelemetry& wakeGate = gBridgeWakeGate.telemetry();
  if (wakeGate.turnsStarted == sLastUplinkTurnsStarted) {
    return;
  }
  sLastUplinkTurnsStarted = wakeGate.turnsStarted;
  const uint32_t cueMs = millis();
  gBodyFeedback.notifyMicActivated(cueMs);
#if STACKCHAN_ENABLE_MIC_ACTIVATION_CUE
  suppressWakeMwwDetections(cueMs, 900);
  const bool accepted = gSpeakerSink.playMicActivationTone();
#if STACKCHAN_ENABLE_WAKE_SERIAL_LOGS
  Serial.print(F("[mic] activation_tone=1 accepted="));
  Serial.print(accepted ? 1 : 0);
  Serial.print(F(" turns="));
  Serial.print(wakeGate.turnsStarted);
  Serial.print(F(" at_ms="));
  Serial.println(cueMs);
#else
  (void)accepted;
#endif
#endif
#endif
}

float bodyFeedbackPowerScale() {
#if defined(ARDUINO_ARCH_ESP32)
  if (gMotionPowerSuppressed || (gPowerVbusValid && gPowerVbusMv > 0 && gPowerVbusMv < 4550) ||
      (gChipTemperatureValid && gChipTemperatureC >= 68.0f)) {
    return 0.25f;
  }
  if ((gPowerVbusValid && gPowerVbusMv > 0 && gPowerVbusMv < 4700) ||
      (gChipTemperatureValid && gChipTemperatureC >= 64.0f)) {
    return 0.55f;
  }
#endif
  return 1.0f;
}

bool bodyFeedbackProtected() {
  return gPowerCoordinator.decision().mode == PowerOperatingMode::Protected ||
         bodyFeedbackPowerScale() <= 0.25f;
}

#if defined(ARDUINO_ARCH_ESP32)
OtaPreflightInput collectLanOtaPreflight(void*) {
  const uint32_t nowMs = millis();
  samplePowerTelemetry(nowMs, true);
  const BridgeAudioDownlinkTelemetry& downlink = gBridgeAudioDownlink.telemetry();
  const AudioOutTelemetry& audioOut = gAudioOut.telemetry();
  const BridgeClientTelemetry& bridge = gBridge.telemetry();
  const BridgeWakeGateTelemetry& wake = gBridgeWakeGate.telemetry();
  const ServoPowerTelemetry servo = gServo.powerTelemetry();

  OtaPreflightInput input;
  input.powerTelemetryValid =
      gPowerTelemetryValid && gPowerVbusValid && gPowerPmicVbusPresentValid;
  input.externalPowerPresent = gPowerPmicVbusPresent;
  input.vbusMv = gPowerVbusMv;
  input.motionRequested = gMotionRequested;
  input.motionEnabled = gActuation.isEnabled();
  input.servoRailEnabled = servo.railEnabled;
  input.servoTorqueEnabled = servo.torqueEnabled;
  input.audioActive = downlink.active || downlink.playbackActive || bridge.audioStreamActive ||
                      audioOut.playbackActive || audioOut.hardwarePlaybackActive ||
                      gSpeakerSink.speakerPowerActive() || gSpeakerSink.speakerRunning();
  input.wakeTurnActive = wake.turnActive;
#if STACKCHAN_HAS_MWW_WAKE_PROBE && STACKCHAN_ENABLE_BRIDGE_AUDIO_UPLINK && STACKCHAN_MWW_DEDICATED_WAKE_CAPTURE
  input.wakeTurnActive = input.wakeTurnActive ||
                         gWakeCueSequence.phase() != WakeCueSequencePhase::Idle;
#endif
  input.freeHeapBytes = ESP.getFreeHeap();
  input.currentAppConfirmed = gLanOtaServer.telemetry().currentAppConfirmed;
  return input;
}

void serviceLanOta(uint32_t nowMs) {
  const DisplayTelemetry& display = gDisplay.telemetry();

  OtaHealthInput health;
  health.runtimeReady = gFrameQueue != nullptr && gSpeechQueue != nullptr &&
                        gFaceControlQueue != nullptr && gMotionControlQueue != nullptr;
  health.displayReady = display.ready && display.windowFps >= 15.0f &&
                        display.windowMaxFrameUs <= STACKCHAN_OTA_HEALTH_MAX_FRAME_US;
  health.tasksReady = gIntentTaskHandle != nullptr && gMotionTaskHandle != nullptr &&
                      gFaceTaskHandle != nullptr;
  health.wifiReady = gBridgeWiFi.isConnected();
  health.powerSafe = gPowerTelemetryValid && gPowerVbusValid &&
                     gPowerPmicVbusPresentValid && gPowerPmicVbusPresent &&
                     gPowerVbusMv >= STACKCHAN_OTA_HEALTH_MIN_VBUS_MV;
  health.heapSafe = ESP.getFreeHeap() >= STACKCHAN_OTA_MIN_FREE_HEAP_BYTES;
  gLanOtaServer.updateHealth(health, nowMs);
  gLanOtaServer.poll(gBridgeWiFi.isConnected(), nowMs);

  static bool wakePauseHeld = false;
  const bool uploadActive = gLanOtaServer.telemetry().uploadActive;
  if (uploadActive && !wakePauseHeld) {
    suppressWakeMwwDetections(nowMs, 30000);
    wakePauseHeld = requestWakeMwwAudioPause(nowMs, 700);
  } else if (!uploadActive && wakePauseHeld) {
    releaseWakeMwwAudioPause(nowMs);
    wakePauseHeld = false;
  }
}
#endif

void printBridgeOutput(const BridgeClientOutput& output, uint32_t nowMs) {
#if !STACKCHAN_ENABLE_BRIDGE_SERIAL_LOGS
  (void)output;
  (void)nowMs;
  return;
#else
  Serial.print(F("[bridge] type="));
  Serial.print(bridgeOutputTypeName(output.type));
  Serial.print(F(" state="));
  Serial.print(bridgeStateName(gBridge.telemetry().state));
  Serial.print(F(" seq="));
  uint32_t seq = output.response.seq != 0 ? output.response.seq : output.audio.seq;
  if (seq == 0) {
    seq = output.stream.seq;
  }
  if (seq == 0) {
    seq = output.streamChunk.seq;
  }
  Serial.print(seq);
  Serial.print(F(" at_ms="));
  Serial.print(nowMs);
  if (output.type == BridgeClientOutputType::Event ||
      output.type == BridgeClientOutputType::ResponseStart ||
      output.type == BridgeClientOutputType::ResponseEnd ||
      output.type == BridgeClientOutputType::Error) {
    Serial.print(F(" event="));
    Serial.print(eventTypeName(output.event.type));
  }
  if (output.type == BridgeClientOutputType::ResponseStart) {
    Serial.print(F(" intent="));
    Serial.print(speechIntentName(output.response.intent));
    Serial.print(F(" text=\""));
    Serial.print(output.response.text);
    Serial.print(F("\""));
  }
  if (output.type == BridgeClientOutputType::AudioFrame) {
    Serial.print(F(" env="));
    Serial.print(output.audio.envelope, 2);
    Serial.print(F(" viseme="));
    Serial.print(speechVisemeName(toSpeechViseme(output.audio.viseme)));
    Serial.print(F(" duration_ms="));
    Serial.print(output.audio.durationMs);
    Serial.print(F(" final="));
    Serial.print(output.audio.finalChunk ? 1 : 0);
  }
  if (output.type == BridgeClientOutputType::AudioStreamStart ||
      output.type == BridgeClientOutputType::AudioStreamEnd) {
    Serial.print(F(" format="));
    Serial.print(output.stream.format);
    Serial.print(F(" sample_rate="));
    Serial.print(output.stream.sampleRate);
    Serial.print(F(" audio_bytes="));
    Serial.print(output.stream.audioBytes);
    Serial.print(F(" chunk_bytes="));
    Serial.print(output.stream.chunkBytes);
    Serial.print(F(" chunks="));
    Serial.print(output.stream.chunks);
  }
  if (output.type == BridgeClientOutputType::AudioStreamChunk) {
    Serial.print(F(" chunk_index="));
    Serial.print(output.streamChunk.index);
    Serial.print(F(" chunk_bytes="));
    Serial.print(output.streamChunk.bytes);
    Serial.print(F(" payload_bytes="));
    Serial.print(output.streamChunk.payloadBytes);
    Serial.print(F(" received_bytes="));
    Serial.print(output.streamChunk.receivedBytes);
    Serial.print(F(" checksum="));
    Serial.print(output.streamChunk.checksum, HEX);
    Serial.print(F(" final="));
    Serial.print(output.streamChunk.finalChunk ? 1 : 0);
  }
  if (output.type == BridgeClientOutputType::SessionReady) {
    Serial.print(F(" session="));
    Serial.print(output.sessionId);
  }
  if (output.type == BridgeClientOutputType::Error) {
    Serial.print(F(" code="));
    Serial.print(output.error);
  }
  Serial.println();
#endif
}

const __FlashStringHelper* endpointControlResultName(BridgeEndpointControlResult result) {
  switch (result) {
    case BridgeEndpointControlResult::Handled:
      return F("handled");
    case BridgeEndpointControlResult::Rejected:
      return F("rejected");
    case BridgeEndpointControlResult::Ignored:
    default:
      return F("ignored");
  }
}

bool handleEndpointControlLine(const char* line, uint32_t nowMs) {
  gBridgeEndpointResponse[0] = '\0';
  const BridgeEndpointControlResult result = gBridgeEndpointControl.submitControlLine(
      line, gBridgeEndpointResponse, sizeof(gBridgeEndpointResponse), nowMs);
  if (result == BridgeEndpointControlResult::Ignored) {
    return false;
  }

  Serial.print(F("[endpoint] result="));
  Serial.print(endpointControlResultName(result));
  Serial.print(F(" at_ms="));
  Serial.print(nowMs);
  Serial.print(F(" response="));
  Serial.print(gBridgeEndpointResponse);
  Serial.println();
  return true;
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

void printVisionTelemetry(const RobotEvent& event, uint32_t frameMs) {
  const uint32_t latencyMs = frameMs >= event.timestampMs ? frameMs - event.timestampMs : 0;
  Serial.print(F("[vision] event="));
  Serial.print(eventTypeName(event.type));
  Serial.print(F(" detect_ms="));
  Serial.print(event.timestampMs);
  Serial.print(F(" frame_ms="));
  Serial.print(frameMs);
  Serial.print(F(" latency_ms="));
  Serial.print(latencyMs);
  if (event.hasPayload) {
    Serial.print(F(" x="));
    Serial.print(event.x, 2);
    Serial.print(F(" y="));
    Serial.print(event.y, 2);
    Serial.print(F(" size="));
    Serial.print(event.z, 2);
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

void publishAudioOutSpeechFrame(uint32_t nowMs) {
  if (gSpeechQueue == nullptr) {
    return;
  }

  AudioOutSpeechFrame frame;
  if (!gAudioOut.pollSpeechFrame(nowMs, &frame)) {
    return;
  }

  FaceSpeechInput input;
  input.clear = frame.clear;
  input.envelope = frame.envelope;
  input.viseme = toSpeechViseme(frame.viseme);
  input.timestampMs = frame.timestampMs;
  input.durationMs = frame.clear ? 0 : frame.durationMs;
  xQueueOverwrite(gSpeechQueue, &input);
}

void publishBridgeSpeechFrame(const BridgeAudioChunk& audio, uint32_t nowMs) {
  if (gSpeechQueue == nullptr) {
    return;
  }

  FaceSpeechInput input;
  input.clear = audio.finalChunk && audio.envelope <= 0.01f;
  input.envelope = audio.envelope;
  input.viseme = toSpeechViseme(audio.viseme);
  input.timestampMs = nowMs;
  input.durationMs = audio.finalChunk ? 80 : audio.durationMs;
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

bool publishMotionControl(const BenchControl& control) {
  if (gMotionControlQueue == nullptr || !control.hasMotionEnable) {
    return false;
  }
#if defined(ARDUINO_ARCH_ESP32)
  const LanOtaTelemetry& ota = gLanOtaServer.telemetry();
  if (control.motionEnabled && (ota.uploadActive || ota.healthPending || ota.rebootPending)) {
    return false;
  }
#endif

  MotionControlInput input;
  input.hasMotionEnable = true;
  input.motionEnabled = control.motionEnabled;
  xQueueOverwrite(gMotionControlQueue, &input);
  return true;
}

void requestMotionSafetyHold(const RobotEvent& event) {
  if (gMotionControlQueue == nullptr ||
      (event.type != EventType::PickedUp && event.type != EventType::Shaken)) {
    return;
  }
  MotionControlInput input;
  input.hasMotionEnable = true;
  input.motionEnabled = false;
  xQueueOverwrite(gMotionControlQueue, &input);
  Serial.print(F("[imu] motion_safety_hold=1 event="));
  Serial.print(eventTypeName(event.type));
  Serial.print(F(" at_ms="));
  Serial.println(event.timestampMs);
}

void handleBridgeOutput(const BridgeClientOutput& output, uint32_t nowMs) {
  printBridgeOutput(output, nowMs);

  if (output.type == BridgeClientOutputType::Event ||
      output.type == BridgeClientOutputType::ResponseEnd ||
      output.type == BridgeClientOutputType::Error) {
    gIntent.applyEvent(output.event, bridgeModeForEvent(output.event.type));
    gBridgeWakeGate.applyEvent(output.event, nowMs);
    if (output.event.type == EventType::UserSpeaking) {
      gAudioOut.duck(nowMs);
    }
  }

  if (output.type == BridgeClientOutputType::ResponseStart) {
    gIntent.applyEvent(output.event, CharacterMode::Speak);
    gIntent.startResponseGesture(output.response.gesture, output.response.seq, nowMs);
    gBridgeWakeGate.applyEvent(output.event, nowMs);
    gAudioOut.cancel();
    gBridgeLocalSpeechSuppressedUntilMs = nowMs + 120000u;
    strncpy(gBridgeSpeechText, output.response.text, sizeof(gBridgeSpeechText) - 1);
    gBridgeSpeechText[sizeof(gBridgeSpeechText) - 1] = '\0';

    gPendingBridgeSpeechCue.intent = output.response.intent;
    gPendingBridgeSpeechCue.text = gBridgeSpeechText;
    gPendingBridgeSpeechCue.priority = 250;
    gPendingBridgeSpeechCue.earcon = earconForIntent(output.response.intent);
    gPendingBridgeSpeechCue.earconDelayMs = 40;
    gBridgeSpeechCuePending = true;
    gBridgeResponseHadAudioStream = false;
  }

  if (output.type == BridgeClientOutputType::AudioFrame) {
    publishBridgeSpeechFrame(output.audio, nowMs);
  }

  if (output.type == BridgeClientOutputType::AudioStreamStart) {
    gBridgeResponseHadAudioStream = true;
    gAudioOut.cancel();
    gBridgeLocalSpeechSuppressedUntilMs = nowMs + 120000u;
    gBridgeAudioDownlink.start(output.stream, nowMs);
  }
  if (output.type == BridgeClientOutputType::AudioStreamChunk) {
    gBridgeAudioDownlink.submitChunk(output.streamChunk, nowMs);
  }
  if (output.type == BridgeClientOutputType::AudioStreamEnd) {
    gBridgeAudioDownlink.end(output.stream, nowMs);
  }
  if (output.type == BridgeClientOutputType::Error ||
      output.type == BridgeClientOutputType::ResponseEnd) {
    if (output.type == BridgeClientOutputType::ResponseEnd &&
        gBridgeSpeechCuePending && !gBridgeResponseHadAudioStream) {
#if STACKCHAN_ENABLE_WIFI_BRIDGE
      gBridgeLocalSpeechSuppressedUntilMs = nowMs + 750u;
#else
      gBridgeLocalSpeechSuppressedUntilMs = 0;
      gIntent.queueSpeechCue(gPendingBridgeSpeechCue, nowMs);
#endif
    } else if (output.type == BridgeClientOutputType::ResponseEnd && gBridgeResponseHadAudioStream) {
      gBridgeLocalSpeechSuppressedUntilMs = nowMs + 750u;
    } else {
      gBridgeLocalSpeechSuppressedUntilMs = 0;
    }
    gBridgeSpeechCuePending = false;
    gBridgeResponseHadAudioStream = false;
    gBridgeAudioDownlink.abort(nowMs);
  }
}

void pollBridgeOutputs(uint32_t nowMs) {
  gBridge.update(nowMs);
  BridgeClientOutput output;
  while (gBridge.poll(&output)) {
    handleBridgeOutput(output, nowMs);
  }
}

void printWiFiBridgeStatus(const char* source, uint32_t nowMs) {
  const BridgeWiFiProvisioningTelemetry& wifi = gBridgeWiFi.telemetry();
  const BridgeNetworkSessionTelemetry& network = gBridgeNetworkSession.telemetry();
  Serial.print(F("[wifi] source="));
  Serial.print(source == nullptr ? "" : source);
  Serial.print(F(" ready="));
  Serial.print(wifi.ready ? 1 : 0);
  Serial.print(F(" enabled="));
  Serial.print(STACKCHAN_ENABLE_WIFI_BRIDGE != 0 ? 1 : 0);
  Serial.print(F(" configured="));
  Serial.print(wifi.configured ? 1 : 0);
  Serial.print(F(" connecting="));
  Serial.print(wifi.connecting ? 1 : 0);
  Serial.print(F(" connected="));
  Serial.print(wifi.connected ? 1 : 0);
  Serial.print(F(" attempts="));
  Serial.print(wifi.beginAttempts);
  Serial.print(F(" failures="));
  Serial.print(wifi.connectFailures);
  Serial.print(F(" status="));
  Serial.print(wifi.status);
#if defined(ARDUINO_ARCH_ESP32)
  Serial.print(F(" local_ip="));
  Serial.print(WiFi.localIP());
  Serial.print(F(" gateway="));
  Serial.print(WiFi.gatewayIP());
#endif
  Serial.print(F(" network_state="));
  Serial.print(bridgeNetworkStateName(network.state));
  Serial.print(F(" connect_failures="));
  Serial.print(network.connectFailures);
  Serial.print(F(" handshakes_sent="));
  Serial.print(network.handshakesSent);
  Serial.print(F(" handshakes="));
  Serial.print(network.handshakesAccepted);
  Serial.print(F(" handshakes_failed="));
  Serial.print(network.handshakesFailed);
  Serial.print(F(" error=\""));
  Serial.print(wifi.lastError);
  Serial.print(F("\" network_error=\""));
  Serial.print(network.lastError);
  Serial.print(F("\" at_ms="));
  Serial.println(nowMs);
}

void updateBridgeNetwork(uint32_t nowMs) {
  struct BridgeNetworkUpdateGuard {
    explicit BridgeNetworkUpdateGuard(bool& activeFlag) : active(activeFlag) {
      active = true;
    }
    ~BridgeNetworkUpdateGuard() {
      active = false;
    }
    bool& active;
  };
  static bool updateActive = false;
  if (updateActive) {
    return;
  }
  BridgeNetworkUpdateGuard updateGuard(updateActive);
  static bool lastReady = false;
  static bool lastConfigured = false;
  static bool lastConnected = false;
  static bool lastConnecting = false;
  static uint32_t lastAttempts = 0;
  static uint32_t lastFailures = 0;
  static int lastStatus = -1;
  static uint32_t lastReportMs = 0;
  static uint32_t lastHeartbeatMs = 0;
  constexpr uint32_t kBridgeHeartbeatIntervalMs = 5000;

  gBridgeWiFi.update(nowMs);
  serviceBridgeRecovery(nowMs);
  serviceBridgeAudioTransportSafety(nowMs);
  const BridgeWiFiProvisioningTelemetry& wifi = gBridgeWiFi.telemetry();
  const bool changed = wifi.ready != lastReady || wifi.configured != lastConfigured ||
                       wifi.connected != lastConnected || wifi.connecting != lastConnecting ||
                       wifi.beginAttempts != lastAttempts || wifi.connectFailures != lastFailures ||
                       wifi.status != lastStatus;
  const bool periodicReportDue =
#if STACKCHAN_ENABLE_PERIODIC_SERIAL_TELEMETRY
      (lastReportMs == 0 || nowMs - lastReportMs >= 10000);
#else
      false;
#endif
  if (changed || periodicReportDue) {
    printWiFiBridgeStatus("update", nowMs);
    lastReady = wifi.ready;
    lastConfigured = wifi.configured;
    lastConnected = wifi.connected;
    lastConnecting = wifi.connecting;
    lastAttempts = wifi.beginAttempts;
    lastFailures = wifi.connectFailures;
    lastStatus = wifi.status;
    lastReportMs = nowMs;
  }
  if (!wifi.ready || !wifi.configured) {
    lastHeartbeatMs = 0;
    return;
  }

  if (!gBridgeWiFi.isConnected()) {
    lastHeartbeatMs = 0;
    const BridgeNetworkSessionState state = gBridgeNetworkSession.telemetry().state;
    if (state == BridgeNetworkSessionState::Connecting ||
        state == BridgeNetworkSessionState::Handshaking ||
        state == BridgeNetworkSessionState::Connected) {
      gBridgeNetworkSession.stop(nowMs);
    }
    serviceBridgeAudioTransportSafety(nowMs);
    return;
  }

  gBridgeNetworkSession.update(nowMs);
  serviceBridgeAudioTransportSafety(nowMs);

  const BridgeNetworkSessionTelemetry& network = gBridgeNetworkSession.telemetry();
  if (network.state != BridgeNetworkSessionState::Connected) {
    lastHeartbeatMs = 0;
    return;
  }

  const BridgeSocketWriterTelemetry& writer = gBridgeNetworkSession.writer().telemetry();
  if (!writer.frameBuffered && !writer.textFrameQueued && !writer.binaryFrameQueued &&
      (lastHeartbeatMs == 0 || nowMs - lastHeartbeatMs >= kBridgeHeartbeatIntervalMs)) {
    char heartbeat[896] = {};
    char chipTempJson[96] = {};
    char embodimentJson[384] = {};
#if defined(ARDUINO_ARCH_ESP32)
    sampleChipTemperature(nowMs, false);
    formatChipTemperatureJson(chipTempJson, sizeof(chipTempJson));
#endif
    RobotFrame embodimentFrame = makeNeutralFrame();
    if (gFrameQueue != nullptr) {
      xQueuePeek(gFrameQueue, &embodimentFrame, 0);
    }
    const ImuAdapterTelemetry& imu = gImu.telemetry();
    const CameraAdapterTelemetry& camera = gCamera.telemetry();
    const BodyPeripheralTelemetry& body = gBodyPeripheral.telemetry();
    const bool cameraTargetFresh = camera.lastSize > 0.0f &&
                                   nowMs - camera.lastEventMs < 3000;
    snprintf(
        embodimentJson,
        sizeof(embodimentJson),
        ",\"robot_mode\":%u,\"emotion_arousal\":%.2f,\"emotion_valence\":%.2f,"
        "\"emotion_focus\":%.2f,\"emotion_fatigue\":%.2f,\"external_power\":%d,"
        "\"battery_percent\":%ld,\"charging_state\":%ld,\"motion_enabled\":%d,"
        "\"speaker_active\":%d,\"imu_picked_up\":%d,\"imu_gravity_x\":%.2f,"
        "\"imu_gravity_y\":%.2f,\"imu_gravity_z\":%.2f,\"touch_ready\":%d,"
        "\"camera_enabled\":%d,\"camera_active\":%d,\"camera_target_fresh\":%d",
        static_cast<unsigned>(embodimentFrame.mode),
        static_cast<double>(embodimentFrame.emotion.arousal),
        static_cast<double>(embodimentFrame.emotion.valence),
        static_cast<double>(embodimentFrame.emotion.focus),
        static_cast<double>(embodimentFrame.emotion.fatigue),
        gPowerPmicVbusPresentValid && gPowerPmicVbusPresent ? 1 : 0,
        static_cast<long>(gPowerBatteryLevel),
        static_cast<long>(gPowerChargingState),
        gActuation.isEnabled() ? 1 : 0,
        gSpeakerSink.speakerRunning() ? 1 : 0,
        imu.pickedUp ? 1 : 0,
        static_cast<double>(imu.gravityX),
        static_cast<double>(imu.gravityY),
        static_cast<double>(imu.gravityZ),
        body.touchReady ? 1 : 0,
        STACKCHAN_ENABLE_CAMERA ? 1 : 0,
        camera.active ? 1 : 0,
        cameraTargetFresh ? 1 : 0);
#if STACKCHAN_HAS_MWW_WAKE_PROBE
    snprintf(
        heartbeat,
        sizeof(heartbeat),
        "{\"type\":\"heartbeat\",\"wake_task\":%d,\"wake_mic\":%d,"
        "\"wake_record_ok\":%lu,\"wake_detections\":%lu,\"wake_events\":%lu,"
        "\"wake_peak\":%lu,\"wake_mean\":%lu,\"wake_peak_max\":%lu,"
        "\"mww_last\":%lu,\"mww_max\":%lu,\"mww_avg\":%lu,\"mww_max_avg\":%lu,"
        "\"mww_cutoff\":%lu,\"mww_inferences\":%lu,\"mww_features\":%lu%s%s}",
        gWakeSrProbe.taskStarted ? 1 : 0,
        gWakeSrProbe.micReady ? 1 : 0,
        static_cast<unsigned long>(gWakeSrProbe.recordOk),
        static_cast<unsigned long>(gWakeSrProbe.wakeDetections),
        static_cast<unsigned long>(gWakeSrProbe.wakeEventsApplied),
        static_cast<unsigned long>(gWakeSrProbe.audioPeak),
        static_cast<unsigned long>(gWakeSrProbe.audioMeanAbs),
        static_cast<unsigned long>(gWakeSrProbe.audioPeakMax),
        static_cast<unsigned long>(gWakeSrProbe.mwwLastProbability),
        static_cast<unsigned long>(gWakeSrProbe.mwwMaxProbability),
        static_cast<unsigned long>(gWakeSrProbe.mwwAverageProbability),
        static_cast<unsigned long>(gWakeSrProbe.mwwMaxAverageProbability),
        static_cast<unsigned long>(gWakeSrProbe.mwwProbabilityCutoff),
        static_cast<unsigned long>(gWakeSrProbe.mwwInferences),
        static_cast<unsigned long>(gWakeSrProbe.mwwFeatures),
        chipTempJson,
        embodimentJson);
#else
    snprintf(
        heartbeat,
        sizeof(heartbeat),
        "{\"type\":\"heartbeat\"%s%s}",
        chipTempJson,
        embodimentJson);
#endif
    if (gBridgeNetworkSession.queueTextFrame(heartbeat)) {
      lastHeartbeatMs = nowMs;
      gBridgeNetworkSession.update(nowMs);
    }
  }
}

void serveBridgeLeanStatusJson(WiFiClient& client,
                               const char* schema,
                               const char* requestTarget,
                               bool speakerToneRequest,
                               bool micToneRequest,
                               bool wakeResetRequest,
                               bool motionControlRequest,
                               bool motionControlTargetEnabled,
                               bool motionControlRequestAccepted,
                               bool toneRequestAccepted) {
  const BridgeWiFiProvisioningTelemetry& wifi = gBridgeWiFi.telemetry();
  const BridgeNetworkSessionTelemetry& network = gBridgeNetworkSession.telemetry();
  const BridgeClientTelemetry& bridge = gBridge.telemetry();
  const BridgeAudioUplinkTelemetry& uplink = gBridgeAudioUplink.telemetry();
  const DisplayTelemetry& display = gDisplay.telemetry();
#if defined(ARDUINO_ARCH_ESP32)
  const LanOtaTelemetry& ota = gLanOtaServer.telemetry();
#endif
#if STACKCHAN_HAS_MWW_WAKE_PROBE && STACKCHAN_ENABLE_BRIDGE_AUDIO_UPLINK && STACKCHAN_MWW_DEDICATED_WAKE_CAPTURE
  const WakeCueSequenceTelemetry& wakeCue = gWakeCueSequence.telemetry();
#endif
  const ActuationTelemetry motion = gActuation.telemetry();
  const GazeTrackerTelemetry& gaze = gIntent.gazeTelemetry();
  const PowerCoordinatorTelemetry powerCoordinator = gPowerCoordinator.telemetry();
  const PowerFloorTelemetry powerFloor = gPowerFloorTracker.telemetry();
  const ServoPowerTelemetry servoPower = gServo.powerTelemetry();
#if STACKCHAN_ENABLE_POWER_FORENSICS
  const PmicPowerForensicsTelemetry pmicForensics = gPmicPowerForensics.telemetry();
#endif
#if defined(ARDUINO_ARCH_ESP32)
  sampleChipTemperature(millis(), false);
  samplePowerTelemetry(millis(), true);
#endif
  const bool recoveryRequest =
      strcmp(requestTarget, "/recover") == 0 || strcmp(requestTarget, "/bridge-recover") == 0 ||
      strcmp(requestTarget, "/wifi-recover") == 0;
  const bool rebootRequest =
      strcmp(requestTarget, "/reboot") == 0 || strcmp(requestTarget, "/restart") == 0 ||
      strcmp(requestTarget, "/reset") == 0;
  const bool audioStopRequest =
      strcmp(requestTarget, "/audio-stop") == 0 || strcmp(requestTarget, "/playback-stop") == 0;

  static char body[20480];
  constexpr size_t kDebugJsonTailReserve = 96;
  size_t len = 0;
  bool bodyTruncated = false;
  auto append = [&](const char* format, ...) {
    if (bodyTruncated || len >= sizeof(body) - kDebugJsonTailReserve) {
      bodyTruncated = true;
      return;
    }
    const size_t appendStart = len;
    va_list args;
    va_start(args, format);
    const int written = vsnprintf(body + len, sizeof(body) - len, format, args);
    va_end(args);
    if (written <= 0) {
      return;
    }
    const size_t remaining = sizeof(body) - len;
    const size_t used = static_cast<size_t>(written);
    if (used >= remaining || used + kDebugJsonTailReserve >= remaining) {
      body[appendStart] = '\0';
      bodyTruncated = true;
      return;
    }
    len += used;
  };

  append("{\"schema\":\"%s\"", schema);
  append(",\"wifi_connected\":%s", wifi.connected ? "true" : "false");
  append(",\"debug_request\":\"%s\"", requestTarget);
  append(",\"debug_port\":%lu", static_cast<unsigned long>(STACKCHAN_BRIDGE_DEBUG_PORT));
#if defined(ARDUINO_ARCH_ESP32)
  append(",\"uptime_ms\":%lu", static_cast<unsigned long>(millis()));
  append(",\"boot_count\":%lu", static_cast<unsigned long>(gRtcBootCount));
  append(",\"reset_reason\":\"%s\"", resetReasonName(gBootResetReason));
  append(",\"reset_reason_code\":%d", static_cast<int>(gBootResetReason));
#if STACKCHAN_ENABLE_POWER_FORENSICS
  append(",\"power_forensics_schema\":\"axp2101-v2\"");
  append(",\"power_forensics_enabled\":%s", pmicForensics.enabled ? "true" : "false");
  append(",\"power_forensics_irq_enable_mask\":%lu",
         static_cast<unsigned long>(kPmicForensicsIrqEnableMask));
  append(",\"power_forensics_irq_enable_succeeded\":%s",
         pmicForensics.irqEnableSucceeded ? "true" : "false");
  append(",\"power_forensics_boot_status_valid\":%s",
         pmicForensics.bootStatusValid ? "true" : "false");
  append(",\"power_forensics_boot_event_mask\":%lu",
         static_cast<unsigned long>(pmicForensics.bootEventMask));
  append(",\"power_forensics_boot_irq0\":%u",
         static_cast<unsigned>(pmicForensics.bootEventMask & 0xFFu));
  append(",\"power_forensics_boot_irq1\":%u",
         static_cast<unsigned>((pmicForensics.bootEventMask >> 8u) & 0xFFu));
  append(",\"power_forensics_boot_irq2\":%u",
         static_cast<unsigned>((pmicForensics.bootEventMask >> 16u) & 0xFFu));
  append(",\"power_forensics_boot_event\":\"%s\"",
         pmicPowerEventName(pmicForensics.bootEventMask));
  append(",\"power_forensics_boot_protective\":%s",
         pmicPowerEventIsProtective(pmicForensics.bootEventMask) ? "true" : "false");
  append(",\"power_forensics_runtime_event_polls\":%lu",
         static_cast<unsigned long>(pmicForensics.runtimeEventPolls));
  append(",\"power_forensics_runtime_protective_event_polls\":%lu",
         static_cast<unsigned long>(pmicForensics.runtimeProtectiveEventPolls));
  append(",\"power_forensics_ignored_event_polls\":%lu",
         static_cast<unsigned long>(pmicForensics.ignoredEventPolls));
  append(",\"power_forensics_last_ignored_event_mask\":%lu",
         static_cast<unsigned long>(pmicForensics.lastIgnoredEventMask));
  append(",\"power_forensics_last_ignored_event\":\"%s\"",
         pmicPowerEventName(pmicForensics.lastIgnoredEventMask));
  append(",\"power_forensics_read_failures\":%lu",
         static_cast<unsigned long>(pmicForensics.readFailures));
  append(",\"power_forensics_clear_failures\":%lu",
         static_cast<unsigned long>(pmicForensics.clearFailures));
  append(",\"power_forensics_last_event_mask\":%lu",
         static_cast<unsigned long>(pmicForensics.lastEventMask));
  append(",\"power_forensics_last_event\":\"%s\"",
         pmicPowerEventName(pmicForensics.lastEventMask));
  append(",\"power_forensics_last_event_at_ms\":%lu",
         static_cast<unsigned long>(pmicForensics.lastEventAtMs));
  append(",\"power_forensics_last_protective_event_mask\":%lu",
         static_cast<unsigned long>(pmicForensics.lastProtectiveEventMask));
  append(",\"power_forensics_last_protective_event\":\"%s\"",
         pmicPowerEventName(pmicForensics.lastProtectiveEventMask));
  append(",\"power_forensics_last_protective_event_at_ms\":%lu",
         static_cast<unsigned long>(pmicForensics.lastProtectiveEventAtMs));
  append(",\"power_forensics_vbus_remove_events\":%lu",
         static_cast<unsigned long>(pmicForensics.vbusRemoveEvents));
  append(",\"power_forensics_battery_remove_events\":%lu",
         static_cast<unsigned long>(pmicForensics.batteryRemoveEvents));
  append(",\"power_forensics_warning_level1_events\":%lu",
         static_cast<unsigned long>(pmicForensics.warningLevel1Events));
  append(",\"power_forensics_warning_level2_events\":%lu",
         static_cast<unsigned long>(pmicForensics.warningLevel2Events));
  append(",\"power_forensics_battery_temperature_events\":%lu",
         static_cast<unsigned long>(pmicForensics.batteryTemperatureEvents));
  append(",\"power_forensics_charge_temperature_events\":%lu",
         static_cast<unsigned long>(pmicForensics.chargeTemperatureEvents));
  append(",\"power_forensics_gauge_watchdog_events\":%lu",
         static_cast<unsigned long>(pmicForensics.gaugeWatchdogEvents));
  append(",\"power_forensics_battery_overvoltage_events\":%lu",
         static_cast<unsigned long>(pmicForensics.batteryOverVoltageEvents));
  append(",\"power_forensics_battery_overvoltage_last_at_ms\":%lu",
         static_cast<unsigned long>(pmicForensics.batteryOverVoltageLastAtMs));
  append(",\"power_forensics_charger_timer_events\":%lu",
         static_cast<unsigned long>(pmicForensics.chargerTimerEvents));
  append(",\"power_forensics_die_overtemperature_events\":%lu",
         static_cast<unsigned long>(pmicForensics.dieOverTemperatureEvents));
  append(",\"power_forensics_batfet_overcurrent_events\":%lu",
         static_cast<unsigned long>(pmicForensics.batfetOverCurrentEvents));
  append(",\"power_forensics_ldo_overcurrent_events\":%lu",
         static_cast<unsigned long>(pmicForensics.ldoOverCurrentEvents));
  append(",\"power_forensics_watchdog_expire_events\":%lu",
         static_cast<unsigned long>(pmicForensics.watchdogExpireEvents));
  append(",\"power_forensics_power_key_long_press_events\":%lu",
         static_cast<unsigned long>(pmicForensics.powerKeyLongPressEvents));
  if (pmicForensics.lastEventMask != 0) {
    const PmicPowerEventContext& context = pmicForensics.lastContext;
    append(",\"power_forensics_last_vbus_valid\":%s", context.vbusValid ? "true" : "false");
    append(",\"power_forensics_last_vbus_mv\":%d", context.vbusMv);
    append(",\"power_forensics_last_battery_valid\":%s",
           context.batteryValid ? "true" : "false");
    append(",\"power_forensics_last_battery_mv\":%d", context.batteryMv);
    append(",\"power_forensics_last_chip_temp_valid\":%s",
           context.chipTemperatureValid ? "true" : "false");
    append(",\"power_forensics_last_pmic_temp_valid\":%s",
           context.pmicTemperatureValid ? "true" : "false");
    append(",\"power_forensics_last_body_power_valid\":%s",
           context.bodyPowerValid ? "true" : "false");
    append(",\"power_forensics_last_pmic_vbus_present\":%s",
           context.pmicVbusPresent ? "true" : "false");
    append(",\"power_forensics_last_pmic_battery_present\":%s",
           context.pmicBatteryPresent ? "true" : "false");
    append(",\"power_forensics_last_motion_requested\":%s",
           context.motionRequested ? "true" : "false");
    append(",\"power_forensics_last_servo_rail_enabled\":%s",
           context.servoRailEnabled ? "true" : "false");
    append(",\"power_forensics_last_servo_torque_enabled\":%s",
           context.servoTorqueEnabled ? "true" : "false");
    append(",\"power_forensics_last_speaker_power_active\":%s",
           context.speakerPowerActive ? "true" : "false");
    append(",\"power_forensics_last_chip_temp_c\":%.1f",
           static_cast<double>(context.chipTemperatureDeciC) / 10.0);
    append(",\"power_forensics_last_pmic_temp_c\":%.1f",
           static_cast<double>(context.pmicTemperatureDeciC) / 10.0);
    append(",\"power_forensics_last_body_bus_mv\":%d", context.bodyBusMv);
    append(",\"power_forensics_last_body_current_ma\":%d", context.bodyCurrentMa);
    append(",\"power_forensics_last_heap_free\":%lu",
           static_cast<unsigned long>(context.heapFree));
  }
  auto appendPowerForensicsContext = [&](const char* prefix,
                                         const PmicPowerEventContext& context) {
    append(",\"power_forensics_%s_vbus_valid\":%s",
           prefix,
           context.vbusValid ? "true" : "false");
    append(",\"power_forensics_%s_vbus_mv\":%d", prefix, context.vbusMv);
    append(",\"power_forensics_%s_battery_valid\":%s",
           prefix,
           context.batteryValid ? "true" : "false");
    append(",\"power_forensics_%s_battery_mv\":%d", prefix, context.batteryMv);
    append(",\"power_forensics_%s_chip_temp_valid\":%s",
           prefix,
           context.chipTemperatureValid ? "true" : "false");
    append(",\"power_forensics_%s_pmic_temp_valid\":%s",
           prefix,
           context.pmicTemperatureValid ? "true" : "false");
    append(",\"power_forensics_%s_body_power_valid\":%s",
           prefix,
           context.bodyPowerValid ? "true" : "false");
    append(",\"power_forensics_%s_pmic_vbus_present\":%s",
           prefix,
           context.pmicVbusPresent ? "true" : "false");
    append(",\"power_forensics_%s_pmic_battery_present\":%s",
           prefix,
           context.pmicBatteryPresent ? "true" : "false");
    append(",\"power_forensics_%s_motion_requested\":%s",
           prefix,
           context.motionRequested ? "true" : "false");
    append(",\"power_forensics_%s_servo_rail_enabled\":%s",
           prefix,
           context.servoRailEnabled ? "true" : "false");
    append(",\"power_forensics_%s_servo_torque_enabled\":%s",
           prefix,
           context.servoTorqueEnabled ? "true" : "false");
    append(",\"power_forensics_%s_speaker_power_active\":%s",
           prefix,
           context.speakerPowerActive ? "true" : "false");
    append(",\"power_forensics_%s_chip_temp_c\":%.1f",
           prefix,
           static_cast<double>(context.chipTemperatureDeciC) / 10.0);
    append(",\"power_forensics_%s_pmic_temp_c\":%.1f",
           prefix,
           static_cast<double>(context.pmicTemperatureDeciC) / 10.0);
    append(",\"power_forensics_%s_body_bus_mv\":%d", prefix, context.bodyBusMv);
    append(",\"power_forensics_%s_body_current_ma\":%d", prefix, context.bodyCurrentMa);
    append(",\"power_forensics_%s_heap_free\":%lu",
           prefix,
           static_cast<unsigned long>(context.heapFree));
  };
  if (pmicForensics.lastProtectiveEventMask != 0) {
    appendPowerForensicsContext("last_protective", pmicForensics.lastProtectiveContext);
  }
  if (pmicForensics.batteryOverVoltageEvents != 0) {
    appendPowerForensicsContext("battery_overvoltage_last",
                                pmicForensics.batteryOverVoltageLastContext);
  }
#endif
  append(",\"heap_free\":%lu", static_cast<unsigned long>(ESP.getFreeHeap()));
  append(",\"heap_min_free\":%lu", static_cast<unsigned long>(ESP.getMinFreeHeap()));
  if (gChipTemperatureValid) {
    append(",\"chip_temp_c\":%.1f", static_cast<double>(gChipTemperatureC));
    append(",\"chip_temp_max_c\":%.1f", static_cast<double>(gChipTemperatureMaxC));
  } else {
    append(",\"chip_temp_c\":null");
    append(",\"chip_temp_max_c\":null");
  }
  append(",\"chip_temp_samples\":%lu", static_cast<unsigned long>(gChipTemperatureSamples));
  append(",\"chip_temp_read_failures\":%lu", static_cast<unsigned long>(gChipTemperatureReadFailures));
  append(",\"power_telemetry_valid\":%s", gPowerTelemetryValid ? "true" : "false");
  append(",\"power_vbus_valid\":%s", gPowerVbusValid ? "true" : "false");
  if (gPowerVbusValid) {
    append(",\"power_vbus_mv\":%d", gPowerVbusMv);
    append(",\"power_vbus_min_mv\":%d", gPowerVbusMinMv);
    append(",\"power_vbus_max_mv\":%d", gPowerVbusMaxMv);
  } else {
    append(",\"power_vbus_mv\":null");
    append(",\"power_vbus_min_mv\":null");
    append(",\"power_vbus_max_mv\":null");
  }
  append(",\"power_vbus_rejected_samples\":%lu",
         static_cast<unsigned long>(gPowerVbusRejectedSamples));
  append(",\"power_vbus_last_rejected_mv\":%d", gPowerVbusLastRejectedMv);
  append(",\"power_pmic_vbus_present_valid\":%s", gPowerPmicVbusPresentValid ? "true" : "false");
  if (gPowerPmicVbusPresentValid) {
    append(",\"power_pmic_vbus_present\":%s", gPowerPmicVbusPresent ? "true" : "false");
  } else {
    append(",\"power_pmic_vbus_present\":null");
  }
  append(",\"power_pmic_vbus_present_samples\":%lu",
         static_cast<unsigned long>(gPowerPmicVbusPresentSamples));
  append(",\"power_pmic_vbus_absent_samples\":%lu",
         static_cast<unsigned long>(gPowerPmicVbusAbsentSamples));
  append(",\"power_pmic_vbus_transitions\":%lu",
         static_cast<unsigned long>(gPowerPmicVbusTransitions));
  append(",\"power_pmic_vbus_loss_entries\":%lu",
         static_cast<unsigned long>(gPowerPmicVbusLossEntries));
  append(",\"power_pmic_vbus_last_transition_ms\":%lu",
         static_cast<unsigned long>(gPowerPmicVbusLastTransitionMs));
  if (gPowerPmicBatteryPresentValid) {
    append(",\"power_pmic_battery_present\":%s", gPowerPmicBatteryPresent ? "true" : "false");
  } else {
    append(",\"power_pmic_battery_present\":null");
  }
  if (gPowerPmicTemperatureValid) {
    append(",\"power_pmic_temp_c\":%.1f", static_cast<double>(gPowerPmicTemperatureC));
    append(",\"power_pmic_temp_max_c\":%.1f", static_cast<double>(gPowerPmicTemperatureMaxC));
  } else {
    append(",\"power_pmic_temp_c\":null");
    append(",\"power_pmic_temp_max_c\":null");
  }
  append(",\"power_pmic_input_state_valid\":%s", gPowerPmicInputStateValid ? "true" : "false");
  append(",\"compiled_enable_pmic_input_telemetry\":%d",
         STACKCHAN_ENABLE_PMIC_INPUT_TELEMETRY);
  append(",\"power_pmic_status1_raw\":%u", static_cast<unsigned>(gPowerPmicStatus1Raw));
  append(",\"power_pmic_status2_raw\":%u", static_cast<unsigned>(gPowerPmicStatus2Raw));
  append(",\"power_pmic_input_current_limited\":%s",
         gPowerPmicInputCurrentLimited ? "true" : "false");
  append(",\"power_pmic_input_current_limit_samples\":%lu",
         static_cast<unsigned long>(gPowerPmicInputCurrentLimitSamples));
  append(",\"power_pmic_input_current_limit_entries\":%lu",
         static_cast<unsigned long>(gPowerPmicInputCurrentLimitEntries));
  append(",\"power_pmic_vindpm_active\":%s", gPowerPmicVindpmActive ? "true" : "false");
  append(",\"power_pmic_vindpm_samples\":%lu",
         static_cast<unsigned long>(gPowerPmicVindpmSamples));
  append(",\"power_pmic_vindpm_entries\":%lu",
         static_cast<unsigned long>(gPowerPmicVindpmEntries));
  append(",\"power_pmic_battery_direction\":\"%s\"",
         axp2101BatteryDirectionName(gPowerPmicStatus2Raw));
  append(",\"power_pmic_charge_status\":%u", static_cast<unsigned>(gPowerPmicChargeStatus));
  append(",\"power_pmic_battery_supplement_samples\":%lu",
         static_cast<unsigned long>(gPowerPmicBatterySupplementSamples));
  append(",\"power_pmic_battery_supplement_entries\":%lu",
         static_cast<unsigned long>(gPowerPmicBatterySupplementEntries));
  append(",\"power_pmic_input_state_read_failures\":%lu",
         static_cast<unsigned long>(gPowerPmicInputStateReadFailures));
  append(",\"power_pmic_config_valid\":%s", gPowerPmicConfigValid ? "true" : "false");
  append(",\"power_pmic_min_system_config_mv\":%u",
         static_cast<unsigned>(3200 + (gPowerPmicMinSystemRaw & 0x07) * 100));
  append(",\"power_pmic_vindpm_target_mv\":%u",
         static_cast<unsigned>(STACKCHAN_PMIC_VINDPM_MV));
  append(",\"power_pmic_vindpm_configured\":%s",
         gPowerPmicVindpmConfigured ? "true" : "false");
  append(",\"power_pmic_vindpm_config_mv\":%u",
         static_cast<unsigned>(axp2101VindpmMvFromRegister(gPowerPmicVindpmRaw)));
  append(",\"power_pmic_input_current_limit_config_ma\":%u",
         static_cast<unsigned>(axp2101InputCurrentLimitMaFromRegister(
             gPowerPmicInputCurrentLimitRaw)));
  append(",\"power_pmic_config_read_failures\":%lu",
         static_cast<unsigned long>(gPowerPmicConfigReadFailures));
  append(",\"power_vsys_valid\":%s", gPowerVsysValid ? "true" : "false");
  if (gPowerVsysValid) {
    append(",\"power_vsys_mv\":%d", gPowerVsysMv);
    append(",\"power_vsys_min_mv\":%d", gPowerVsysMinMv);
    append(",\"power_vsys_max_mv\":%d", gPowerVsysMaxMv);
  } else {
    append(",\"power_vsys_mv\":null");
    append(",\"power_vsys_min_mv\":null");
    append(",\"power_vsys_max_mv\":null");
  }
  append(",\"power_vsys_samples\":%lu", static_cast<unsigned long>(gPowerVsysSamples));
  append(",\"power_vsys_read_failures\":%lu",
         static_cast<unsigned long>(gPowerVsysReadFailures));
  append(",\"power_battery_valid\":%s", gPowerBatteryValid ? "true" : "false");
  if (gPowerBatteryValid) {
    append(",\"power_battery_mv\":%d", gPowerBatteryMv);
    append(",\"power_battery_min_mv\":%d", gPowerBatteryMinMv);
    append(",\"power_battery_max_mv\":%d", gPowerBatteryMaxMv);
  } else {
    append(",\"power_battery_mv\":null");
    append(",\"power_battery_min_mv\":null");
    append(",\"power_battery_max_mv\":null");
  }
  append(",\"power_battery_rejected_samples\":%lu",
         static_cast<unsigned long>(gPowerBatteryRejectedSamples));
  append(",\"power_battery_last_rejected_mv\":%d", gPowerBatteryLastRejectedMv);
  if (gPowerBatteryLevel >= 0) {
    append(",\"power_battery_level\":%ld", static_cast<long>(gPowerBatteryLevel));
  } else {
    append(",\"power_battery_level\":null");
  }
  if (gPowerChargingState >= 0 && gPowerChargingState <= 2) {
    append(",\"power_charging_state\":%ld", static_cast<long>(gPowerChargingState));
  } else {
    append(",\"power_charging_state\":null");
  }
  append(",\"power_samples\":%lu", static_cast<unsigned long>(gPowerTelemetrySamples));
  append(",\"power_read_failures\":%lu", static_cast<unsigned long>(gPowerTelemetryReadFailures));
  append(",\"power_vbus_hard_floor_mv\":%u", static_cast<unsigned>(powerFloor.hardFloorMv));
  append(",\"power_vbus_floor_valid_samples\":%lu",
         static_cast<unsigned long>(powerFloor.validSamples));
  append(",\"power_vbus_floor_min_mv\":%d", powerFloor.minVbusMv);
  append(",\"power_vbus_hard_floor_samples\":%lu",
         static_cast<unsigned long>(powerFloor.hardFloorSamples));
  append(",\"power_vbus_hard_floor_confirmed_samples\":%lu",
         static_cast<unsigned long>(powerFloor.hardFloorConfirmedSamples));
  append(",\"power_vbus_hard_floor_unconfirmed_samples\":%lu",
         static_cast<unsigned long>(powerFloor.hardFloorUnconfirmedSamples));
  append(",\"power_vbus_hard_floor_entries\":%lu",
         static_cast<unsigned long>(powerFloor.hardFloorEntries));
  append(",\"power_vbus_hard_floor_consecutive_samples\":%lu",
         static_cast<unsigned long>(powerFloor.consecutiveHardFloorSamples));
  append(",\"power_vbus_hard_floor_max_consecutive_samples\":%lu",
         static_cast<unsigned long>(powerFloor.maxConsecutiveHardFloorSamples));
  append(",\"power_vbus_hard_floor_last_at_ms\":%lu",
         static_cast<unsigned long>(powerFloor.lastHardFloorAtMs));
  append(",\"power_vbus_hard_floor_last_mv\":%d", powerFloor.lastHardFloorVbusMv);
  append(",\"power_vbus_hard_floor_last_confirm_mv\":%d",
         powerFloor.lastHardFloorConfirmVbusMv);
  append(",\"power_vbus_hard_floor_last_battery_mv\":%d",
         powerFloor.lastHardFloorBatteryMv);
  append(",\"power_vbus_hard_floor_last_confirm_battery_mv\":%d",
         powerFloor.lastHardFloorConfirmBatteryMv);
  append(",\"power_vbus_hard_floor_last_body_power_valid\":%s",
         powerFloor.lastHardFloorBodyPowerValid ? "true" : "false");
  append(",\"power_vbus_hard_floor_last_body_bus_v\":%.3f",
         static_cast<double>(powerFloor.lastHardFloorBodyBusV));
  append(",\"power_vbus_hard_floor_last_body_current_ma\":%.1f",
         static_cast<double>(powerFloor.lastHardFloorBodyCurrentMa));
  append(",\"power_vbus_hard_floor_last_motion_requested\":%s",
         powerFloor.lastHardFloorMotionRequested ? "true" : "false");
  append(",\"power_vbus_hard_floor_last_servo_rail_enabled\":%s",
         powerFloor.lastHardFloorServoRailEnabled ? "true" : "false");
  append(",\"power_vbus_hard_floor_last_servo_torque_enabled\":%s",
         powerFloor.lastHardFloorServoTorqueEnabled ? "true" : "false");
  append(",\"power_vbus_hard_floor_last_speaker_power_active\":%s",
         powerFloor.lastHardFloorSpeakerPowerActive ? "true" : "false");
  append(",\"power_vbus_hard_floor_last_pmic_input_current_limited\":%s",
         powerFloor.lastHardFloorPmicInputCurrentLimited ? "true" : "false");
  append(",\"power_vbus_hard_floor_last_pmic_vindpm_active\":%s",
         powerFloor.lastHardFloorPmicVindpmActive ? "true" : "false");
  append(",\"power_vbus_hard_floor_last_pmic_battery_discharging\":%s",
         powerFloor.lastHardFloorPmicBatteryDischarging ? "true" : "false");
  append(",\"power_vbus_hard_floor_last_pmic_vsys_valid\":%s",
         powerFloor.lastHardFloorPmicVsysValid ? "true" : "false");
  append(",\"power_vbus_hard_floor_last_pmic_vsys_mv\":%d",
         powerFloor.lastHardFloorPmicVsysMv);
  append(",\"power_base_input_mode\":%s", gBaseInputModeConfigured ? "true" : "false");
  append(",\"power_external_output_enabled\":%s", gExternalOutputEnabled ? "true" : "false");
  append(",\"power_charge_configured\":%s", gBatteryChargeConfigured ? "true" : "false");
  append(",\"power_charge_current_ma\":%u", static_cast<unsigned>(gAppliedChargeCurrentMa));
  append(",\"power_charge_current_max_ma\":%u", static_cast<unsigned>(STACKCHAN_CHARGE_CURRENT_MA));
  append(",\"power_charge_current_low_input_ma\":%u",
         static_cast<unsigned>(STACKCHAN_LOW_INPUT_CHARGE_CURRENT_MA));
  append(",\"power_charge_current_transitions\":%lu",
         static_cast<unsigned long>(gChargeCurrentTransitions));
  append(",\"power_charge_current_last_change_ms\":%lu",
         static_cast<unsigned long>(gChargeCurrentLastChangeMs));
  append(",\"body_power_monitor_ready\":%s", gBodyPowerMonitorReady ? "true" : "false");
  append(",\"body_power_telemetry_valid\":%s", gBodyPowerTelemetryValid ? "true" : "false");
  if (gBodyPowerTelemetryValid) {
    append(",\"body_power_bus_v\":%.3f", static_cast<double>(gBodyPowerBusV));
    append(",\"body_power_bus_min_v\":%.3f", static_cast<double>(gBodyPowerBusMinV));
    append(",\"body_power_bus_max_v\":%.3f", static_cast<double>(gBodyPowerBusMaxV));
    append(",\"body_power_current_ma\":%.1f", static_cast<double>(gBodyPowerCurrentMa));
    append(",\"body_power_current_min_ma\":%.1f", static_cast<double>(gBodyPowerCurrentMinMa));
    append(",\"body_power_current_max_ma\":%.1f", static_cast<double>(gBodyPowerCurrentMaxMa));
    append(",\"body_power_mw\":%.1f", static_cast<double>(gBodyPowerMw));
    append(",\"body_battery_current_ma\":%.1f", static_cast<double>(gBodyPowerCurrentMa));
    append(",\"body_battery_current_positive_means\":\"battery_to_system\"");
    append(",\"body_battery_power_flow\":\"%s\"",
           gBodyPowerCurrentMa > 15.0f
               ? "battery_to_system"
               : (gBodyPowerCurrentMa < -15.0f ? "system_to_battery" : "idle"));
  } else {
    append(",\"body_power_bus_v\":null");
    append(",\"body_power_bus_min_v\":null");
    append(",\"body_power_bus_max_v\":null");
    append(",\"body_power_current_ma\":null");
    append(",\"body_power_current_min_ma\":null");
    append(",\"body_power_current_max_ma\":null");
    append(",\"body_power_mw\":null");
    append(",\"body_battery_current_ma\":null");
    append(",\"body_battery_current_positive_means\":\"battery_to_system\"");
    append(",\"body_battery_power_flow\":\"unknown\"");
  }
  append(",\"body_power_samples\":%lu", static_cast<unsigned long>(gBodyPowerTelemetrySamples));
  append(",\"body_power_read_failures\":%lu", static_cast<unsigned long>(gBodyPowerTelemetryReadFailures));
#endif
  append(",\"power_mode\":\"%s\"", powerOperatingModeName(powerCoordinator.mode));
  append(",\"power_reason\":\"%s\"", powerCoordinator.reason != nullptr ? powerCoordinator.reason : "");
  append(",\"power_motion_requested\":%s", powerCoordinator.motionRequested ? "true" : "false");
  append(",\"power_motion_allowed\":%s", powerCoordinator.motionAllowed ? "true" : "false");
  append(",\"power_servo_rail_allowed\":%s", powerCoordinator.servoRailAllowed ? "true" : "false");
  append(",\"power_charge_current_desired_ma\":%u",
         static_cast<unsigned>(powerCoordinator.chargeCurrentMa));
  append(",\"power_charge_derated\":%s", powerCoordinator.chargeDerated ? "true" : "false");
  append(",\"power_charge_derate_reason\":\"%s\"",
         powerCoordinator.chargeDerateReason != nullptr ? powerCoordinator.chargeDerateReason : "");
  append(",\"power_charge_derate_hold_active\":%s",
         powerCoordinator.chargeDerateHoldActive ? "true" : "false");
  append(",\"power_charge_derate_hold_ms\":%lu",
         static_cast<unsigned long>(powerCoordinator.chargeDerateHoldMs));
  append(",\"power_charge_derate_hold_remaining_ms\":%lu",
         static_cast<unsigned long>(powerCoordinator.chargeDerateHoldRemainingMs));
  append(",\"power_charge_derate_last_load_ms\":%lu",
         static_cast<unsigned long>(powerCoordinator.chargeDerateLastLoadMs));
  append(",\"power_charge_derate_entries\":%lu",
         static_cast<unsigned long>(powerCoordinator.chargeDerateEntries));
  append(",\"power_transitions\":%lu", static_cast<unsigned long>(powerCoordinator.transitions));
  append(",\"power_motion_grants\":%lu", static_cast<unsigned long>(powerCoordinator.motionGrantEntries));
  append(",\"power_motion_blocks\":%lu", static_cast<unsigned long>(powerCoordinator.motionBlockEntries));
  append(",\"power_last_transition_ms\":%lu", static_cast<unsigned long>(powerCoordinator.lastTransitionMs));
  append(",\"compiled_enable_servos\":%d", STACKCHAN_SERVO_HARDWARE_ENABLE ? 1 : 0);
  const CameraAdapterTelemetry& camera = gCamera.telemetry();
  append(",\"compiled_enable_camera\":%d", STACKCHAN_ENABLE_CAMERA ? 1 : 0);
  append(",\"compiled_enable_camera_host_vision\":%d",
         STACKCHAN_ENABLE_CAMERA_HOST_VISION ? 1 : 0);
  append(",\"camera_ready\":%s", camera.ready ? "true" : "false");
  append(",\"camera_active\":%s", camera.active ? "true" : "false");
  append(",\"camera_capture_ready\":%s", camera.captureReady ? "true" : "false");
  append(",\"camera_init_attempts\":%lu", static_cast<unsigned long>(camera.initAttempts));
  append(",\"camera_init_failures\":%lu", static_cast<unsigned long>(camera.initFailures));
  append(",\"camera_last_init_error\":%ld", static_cast<long>(camera.lastInitError));
  append(",\"camera_sensor_pid\":%u", static_cast<unsigned>(camera.sensorPid));
  append(",\"camera_horizontal_mirror_configured\":%s",
         camera.horizontalMirrorConfigured ? "true" : "false");
  append(",\"camera_vertical_flip_configured\":%s",
         camera.verticalFlipConfigured ? "true" : "false");
  append(",\"camera_orientation_failures\":%lu",
         static_cast<unsigned long>(camera.orientationFailures));
  append(",\"camera_frames_captured\":%lu", static_cast<unsigned long>(camera.framesCaptured));
  append(",\"camera_capture_failures\":%lu", static_cast<unsigned long>(camera.captureFailures));
  append(",\"camera_last_capture_us\":%lu", static_cast<unsigned long>(camera.lastCaptureUs));
  append(",\"camera_max_capture_us\":%lu", static_cast<unsigned long>(camera.maxCaptureUs));
  append(",\"camera_last_frame_bytes\":%lu", static_cast<unsigned long>(camera.lastFrameBytes));
  append(",\"camera_last_frame_width\":%u", camera.lastFrameWidth);
  append(",\"camera_last_frame_height\":%u", camera.lastFrameHeight);
  append(",\"camera_last_frame_checksum\":%lu",
         static_cast<unsigned long>(camera.lastFrameChecksum));
  append(",\"camera_host_frame_requests\":%lu",
         static_cast<unsigned long>(camera.hostFrameRequests));
  append(",\"camera_host_frame_failures\":%lu",
         static_cast<unsigned long>(camera.hostFrameFailures));
  append(",\"camera_host_capture_failures\":%lu",
         static_cast<unsigned long>(camera.hostCaptureFailures));
  append(",\"camera_host_response_write_attempts\":%lu",
         static_cast<unsigned long>(camera.hostResponseWriteAttempts));
  append(",\"camera_host_response_write_successes\":%lu",
         static_cast<unsigned long>(camera.hostResponseWriteSuccesses));
  append(",\"camera_host_response_write_failures\":%lu",
         static_cast<unsigned long>(camera.hostResponseWriteFailures));
  append(",\"camera_host_response_write_consecutive_failures\":%lu",
         static_cast<unsigned long>(camera.hostResponseWriteConsecutiveFailures));
  append(",\"camera_host_response_write_max_consecutive_failures\":%lu",
         static_cast<unsigned long>(camera.hostResponseWriteMaxConsecutiveFailures));
  append(",\"camera_host_target_updates\":%lu",
         static_cast<unsigned long>(camera.hostTargetUpdates));
  append(",\"camera_host_auth_failures\":%lu",
         static_cast<unsigned long>(camera.hostAuthFailures));
  append(",\"camera_events\":%lu", static_cast<unsigned long>(camera.eventsPublished));
  append(",\"camera_face_batches\":%lu", static_cast<unsigned long>(camera.faceBatches));
  append(",\"camera_faces_observed\":%lu", static_cast<unsigned long>(camera.facesObserved));
  append(",\"camera_sound_direction_updates\":%lu",
         static_cast<unsigned long>(camera.soundDirectionUpdates));
  append(",\"camera_sound_direction_last_ms\":%lu",
         static_cast<unsigned long>(camera.lastSoundDirectionMs));
  append(",\"camera_sound_azimuth_norm\":%.3f",
         static_cast<double>(camera.lastSoundAzimuthNorm));
  append(",\"camera_sound_direction_strength\":%.3f",
         static_cast<double>(camera.lastSoundStrength));
  append(",\"camera_audio_matched_selections\":%lu",
         static_cast<unsigned long>(camera.audioMatchedSelections));
  append(",\"camera_reply_held_selections\":%lu",
         static_cast<unsigned long>(camera.replyHeldSelections));
  append(",\"camera_face_hold_selections\":%lu",
         static_cast<unsigned long>(camera.faceHoldSelections));
  append(",\"camera_target_valid\":%s", camera.targetValid ? "true" : "false");
  append(",\"camera_target_audio_matched\":%s",
         camera.targetAudioMatched ? "true" : "false");
  append(",\"camera_target_held_for_reply\":%s",
         camera.targetHeldForReply ? "true" : "false");
  append(",\"camera_target_x\":%.3f", static_cast<double>(camera.targetX));
  append(",\"camera_target_y\":%.3f", static_cast<double>(camera.targetY));
  append(",\"camera_target_size\":%.3f", static_cast<double>(camera.targetSize));
  append(",\"camera_target_confidence\":%.3f",
         static_cast<double>(camera.targetConfidence));
  append(",\"camera_target_audio_direction_error\":%.3f",
         static_cast<double>(camera.targetAudioDirectionError));
  append(",\"camera_target_selected_at_ms\":%lu",
         static_cast<unsigned long>(camera.targetSelectedAtMs));
  const ImuAdapterTelemetry& imu = gImu.telemetry();
  append(",\"compiled_enable_imu\":%d", STACKCHAN_ENABLE_IMU ? 1 : 0);
  append(",\"imu_ready\":%s", imu.ready ? "true" : "false");
  append(",\"imu_calibrated\":%s", imu.calibrated ? "true" : "false");
  append(",\"imu_picked_up\":%s", imu.pickedUp ? "true" : "false");
  append(",\"imu_self_motion_filtered\":%s", imu.selfMotionFiltered ? "true" : "false");
  append(",\"imu_samples\":%lu", static_cast<unsigned long>(imu.samples));
  append(",\"imu_read_retries\":%lu", static_cast<unsigned long>(imu.readRetries));
  append(",\"imu_read_recoveries\":%lu", static_cast<unsigned long>(imu.readRecoveries));
  append(",\"imu_read_exhaustions\":%lu", static_cast<unsigned long>(imu.readExhaustions));
  append(",\"imu_read_exhaustion_recoveries\":%lu",
         static_cast<unsigned long>(imu.readExhaustionRecoveries));
  append(",\"imu_read_exhaustions_consecutive\":%lu",
         static_cast<unsigned long>(imu.consecutiveReadExhaustions));
  append(",\"imu_read_exhaustions_max_consecutive\":%lu",
         static_cast<unsigned long>(imu.maxConsecutiveReadExhaustions));
  append(",\"imu_read_failures\":%lu", static_cast<unsigned long>(imu.readFailures));
  append(",\"imu_events\":%lu", static_cast<unsigned long>(imu.eventsPublished));
  append(",\"imu_self_motion_events\":%lu", static_cast<unsigned long>(imu.selfMotionEvents));
  append(",\"imu_external_events\":%lu", static_cast<unsigned long>(imu.externalEvents));
  append(",\"imu_self_motion_samples\":%lu", static_cast<unsigned long>(imu.selfMotionSamples));
  append(",\"imu_pickup_events\":%lu", static_cast<unsigned long>(imu.pickupEvents));
  append(",\"imu_putdown_events\":%lu", static_cast<unsigned long>(imu.putdownEvents));
  append(",\"imu_shake_events\":%lu", static_cast<unsigned long>(imu.shakeEvents));
  append(",\"imu_tilt_events\":%lu", static_cast<unsigned long>(imu.tiltEvents));
  append(",\"imu_last_event_type\":%u", static_cast<unsigned>(imu.lastEventType));
  append(",\"imu_last_event_ms\":%lu", static_cast<unsigned long>(imu.lastEventMs));
  append(",\"imu_last_event_self_motion\":%s", imu.lastEventSelfMotion ? "true" : "false");
  append(",\"imu_last_event_strength\":%.3f", static_cast<double>(imu.lastEventStrength));
  append(",\"imu_last_event_jerk\":%.3f", static_cast<double>(imu.lastEventJerk));
  append(",\"imu_last_event_accel_norm\":%.3f", static_cast<double>(imu.lastEventAccelNorm));
  append(",\"imu_last_event_gyro_norm\":%.3f", static_cast<double>(imu.lastEventGyroNorm));
  append(",\"imu_accel_norm\":%.3f", static_cast<double>(imu.accelNorm));
  append(",\"imu_gyro_norm\":%.3f", static_cast<double>(imu.gyroNorm));
  append(",\"imu_gravity_x\":%.3f", static_cast<double>(imu.gravityX));
  append(",\"imu_gravity_y\":%.3f", static_cast<double>(imu.gravityY));
  append(",\"imu_gravity_z\":%.3f", static_cast<double>(imu.gravityZ));
  const BodyPeripheralTelemetry& bodyPeripheral = gBodyPeripheral.telemetry();
  const BodyFeedbackTelemetry& bodyFeedback = gBodyFeedback.telemetry();
  append(",\"compiled_enable_body_rgb\":%d", STACKCHAN_ENABLE_BODY_RGB ? 1 : 0);
  append(",\"compiled_enable_body_touch\":%d", STACKCHAN_ENABLE_BODY_TOUCH ? 1 : 0);
  append(",\"body_rgb_ready\":%s", bodyPeripheral.rgbReady ? "true" : "false");
  append(",\"body_rgb_frames\":%lu", static_cast<unsigned long>(bodyPeripheral.rgbFrames));
  append(",\"body_rgb_write_retries\":%lu",
         static_cast<unsigned long>(bodyPeripheral.rgbWriteRetries));
  append(",\"body_rgb_write_recoveries\":%lu",
         static_cast<unsigned long>(bodyPeripheral.rgbWriteRecoveries));
  append(",\"body_rgb_write_failures\":%lu",
         static_cast<unsigned long>(bodyPeripheral.rgbWriteFailures));
  append(",\"body_rgb_rendered_frames\":%lu",
         static_cast<unsigned long>(bodyFeedback.renderedFrames));
  append(",\"body_rgb_mode_transitions\":%lu",
         static_cast<unsigned long>(bodyFeedback.modeTransitions));
  append(",\"body_rgb_transition_active\":%s",
         bodyFeedback.transitionActive ? "true" : "false");
  append(",\"body_rgb_last_channel_step\":%u", bodyFeedback.lastChannelStep);
  append(",\"body_rgb_max_channel_step\":%u", bodyFeedback.maxChannelStep);
  append(",\"body_touch_ready\":%s", bodyPeripheral.touchReady ? "true" : "false");
  append(",\"body_touch_samples\":%lu", static_cast<unsigned long>(bodyPeripheral.touchSamples));
  append(",\"body_touch_read_failures\":%lu",
         static_cast<unsigned long>(bodyPeripheral.touchReadFailures));
  append(",\"body_touch_events\":%lu", static_cast<unsigned long>(bodyPeripheral.touchEvents));
  append(",\"body_touch_last_raw\":%u", bodyPeripheral.lastTouchRaw);
  append(",\"body_touch_last_zone\":%u", static_cast<unsigned>(bodyPeripheral.lastZone));
  append(",\"body_touch_last_gesture\":%u", static_cast<unsigned>(bodyPeripheral.lastGesture));
  append(",\"body_touch_last_event_ms\":%lu",
         static_cast<unsigned long>(bodyPeripheral.lastTouchEventMs));
  append(",\"body_touch_front_events\":%lu",
         static_cast<unsigned long>(bodyPeripheral.touchFrontEvents));
  append(",\"body_touch_middle_events\":%lu",
         static_cast<unsigned long>(bodyPeripheral.touchMiddleEvents));
  append(",\"body_touch_back_events\":%lu",
         static_cast<unsigned long>(bodyPeripheral.touchBackEvents));
  append(",\"body_touch_tap_events\":%lu",
         static_cast<unsigned long>(bodyPeripheral.touchTapEvents));
  append(",\"body_touch_hold_events\":%lu",
         static_cast<unsigned long>(bodyPeripheral.touchHoldEvents));
  append(",\"body_touch_swipe_forward_events\":%lu",
         static_cast<unsigned long>(bodyPeripheral.touchSwipeForwardEvents));
  append(",\"body_touch_swipe_backward_events\":%lu",
         static_cast<unsigned long>(bodyPeripheral.touchSwipeBackwardEvents));
  append(",\"motion_requested\":%s", gMotionRequested ? "true" : "false");
  append(",\"motion_enabled\":%s", gActuation.isEnabled() ? "true" : "false");
  append(",\"servo_power_allowed\":%s", servoPower.powerAllowed ? "true" : "false");
  append(",\"servo_rail_enabled\":%s", servoPower.railEnabled ? "true" : "false");
  append(",\"servo_torque_enabled\":%s", servoPower.torqueEnabled ? "true" : "false");
  append(",\"servo_rail_enable_entries\":%lu", static_cast<unsigned long>(servoPower.railEnableEntries));
  append(",\"servo_rail_disable_entries\":%lu", static_cast<unsigned long>(servoPower.railDisableEntries));
  append(",\"servo_rail_write_failures\":%lu", static_cast<unsigned long>(servoPower.railWriteFailures));
  append(",\"servo_power_denied_writes\":%lu", static_cast<unsigned long>(servoPower.powerDeniedWrites));
  append(",\"servo_attach_attempts\":%lu", static_cast<unsigned long>(servoPower.attachAttempts));
  append(",\"servo_attach_failures\":%lu", static_cast<unsigned long>(servoPower.attachFailures));
  append(",\"servo_ping_attempts\":%lu", static_cast<unsigned long>(servoPower.pingAttempts));
  append(",\"servo_ping_failures\":%lu", static_cast<unsigned long>(servoPower.pingFailures));
  append(",\"servo_last_ping_yaw\":%d", servoPower.lastPingYaw);
  append(",\"servo_last_ping_pitch\":%d", servoPower.lastPingPitch);
  append(",\"servo_last_error\":\"%s\"",
         servoPower.lastError != nullptr ? servoPower.lastError : "");
  append(",\"servo_power_on_settle_ms\":%lu",
         static_cast<unsigned long>(STACKCHAN_SERVO_POWER_ON_SETTLE_MS));
  append(",\"motion_actuator_ready\":%s", motion.actuatorReady ? "true" : "false");
  append(",\"motion_last_reason\":\"%s\"", motion.lastReason != nullptr ? motion.lastReason : "");
  append(",\"motion_enabled_at_ms\":%lu", static_cast<unsigned long>(motion.enabledAtMs));
  append(",\"motion_last_update_ms\":%lu", static_cast<unsigned long>(motion.lastUpdateMs));
  append(",\"motion_last_write_ms\":%lu", static_cast<unsigned long>(motion.lastActuatorWriteMs));
  append(",\"motion_last_pitch_command_deg\":%.3f", static_cast<double>(motion.lastPitchCommandDeg));
  append(",\"motion_last_yaw_command_deg\":%.3f", static_cast<double>(motion.lastYawCommandDeg));
  append(",\"motion_enable_requests\":%lu", static_cast<unsigned long>(motion.enableRequests));
  append(",\"motion_disable_requests\":%lu", static_cast<unsigned long>(motion.disableRequests));
  append(",\"motion_enable_failures\":%lu", static_cast<unsigned long>(motion.enableFailures));
  append(",\"motion_session_refreshes\":%lu", static_cast<unsigned long>(motion.sessionRefreshes));
  append(",\"motion_session_refreshed_at_ms\":%lu",
         static_cast<unsigned long>(motion.sessionRefreshedAtMs));
  append(",\"motion_session_timeouts\":%lu", static_cast<unsigned long>(motion.sessionTimeouts));
  append(",\"motion_stop_calls\":%lu", static_cast<unsigned long>(motion.stopCalls));
  append(",\"motion_session_timeout_ms\":%lu", static_cast<unsigned long>(STACKCHAN_MOTION_SESSION_TIMEOUT_MS));
  append(",\"motion_duty_active_ms\":%lu", static_cast<unsigned long>(STACKCHAN_MOTION_DUTY_ACTIVE_MS));
  append(",\"motion_duty_rest_ms\":%lu", static_cast<unsigned long>(STACKCHAN_MOTION_DUTY_REST_MS));
  append(",\"motion_duty_resting\":%s", motion.dutyResting ? "true" : "false");
  append(",\"motion_duty_cycle_start_ms\":%lu", static_cast<unsigned long>(motion.dutyCycleStartMs));
  append(",\"motion_duty_rest_entries\":%lu", static_cast<unsigned long>(motion.dutyRestEntries));
  append(",\"motion_duty_rest_total_ms\":%lu", static_cast<unsigned long>(motion.dutyRestMs));
  append(",\"motion_output_suppressed\":%s", motion.outputSuppressed ? "true" : "false");
  append(",\"camera_gaze_tracking\":%s", gaze.tracking ? "true" : "false");
  append(",\"camera_gaze_motion_output_active\":%s", gaze.motionOutputActive ? "true" : "false");
  append(",\"camera_gaze_presence\":%.3f", static_cast<double>(gaze.presence));
  append(",\"camera_gaze_yaw_offset_deg\":%.3f", static_cast<double>(gaze.yawOffsetDeg));
  append(",\"camera_gaze_pitch_offset_deg\":%.3f", static_cast<double>(gaze.pitchOffsetDeg));
  append(",\"motion_self_motion_active\":%s", motion.selfMotionActive ? "true" : "false");
  append(",\"motion_self_motion_until_ms\":%lu",
         static_cast<unsigned long>(motion.selfMotionUntilMs));
  append(",\"motion_output_suppress_entries\":%lu",
         static_cast<unsigned long>(motion.outputSuppressEntries));
  append(",\"motion_output_suppress_total_ms\":%lu",
         static_cast<unsigned long>(motion.outputSuppressMs));
  append(",\"motion_audio_load_shed_cooldown_ms\":%lu",
         static_cast<unsigned long>(STACKCHAN_MOTION_AUDIO_LOAD_SHED_COOLDOWN_MS));
  append(",\"motion_audio_playback_active\":%s",
         gMotionAudioPlaybackActive ? "true" : "false");
  append(",\"motion_audio_preempt_active\":%s",
         gMotionAudioPreemptActive ? "true" : "false");
  append(",\"motion_audio_cooldown_tail_active\":%s",
         gMotionAudioPreemptionGate.cooldownTailActive() ? "true" : "false");
  append(",\"motion_audio_microphone_cooldown_clears\":%lu",
         static_cast<unsigned long>(gMotionAudioPreemptionGate.microphoneCooldownClears()));
#if defined(ARDUINO_ARCH_ESP32)
  append(",\"motion_thermal_suppressed\":%s", gMotionThermalSuppressed ? "true" : "false");
  append(",\"motion_thermal_suppress_entries\":%lu",
         static_cast<unsigned long>(gMotionThermalSuppressEntries));
  append(",\"motion_thermal_load_shed_c\":%d", STACKCHAN_MOTION_THERMAL_LOAD_SHED_C);
  append(",\"motion_thermal_resume_c\":%d", STACKCHAN_MOTION_THERMAL_RESUME_C);
  append(",\"motion_power_suppressed\":%s", gMotionPowerSuppressed ? "true" : "false");
  append(",\"motion_power_suppress_entries\":%lu",
         static_cast<unsigned long>(gMotionPowerSuppressEntries));
  append(",\"motion_power_suppressed_at_ms\":%lu",
         static_cast<unsigned long>(gMotionPowerSuppressedAtMs));
  append(",\"motion_power_load_shed_mv\":%d", STACKCHAN_MOTION_POWER_LOAD_SHED_MV);
  append(",\"motion_power_resume_mv\":%d", STACKCHAN_MOTION_POWER_RESUME_MV);
  append(",\"motion_power_hard_floor_mv\":%d", STACKCHAN_MOTION_POWER_HARD_FLOOR_MV);
  append(",\"motion_power_charge_backed_current_ma\":%d",
         STACKCHAN_MOTION_POWER_CHARGE_BACKED_CURRENT_MA);
  append(",\"motion_power_charge_backed\":%s", gMotionPowerChargeBacked ? "true" : "false");
  append(",\"motion_power_charge_backed_samples\":%lu",
         static_cast<unsigned long>(gMotionPowerChargeBackedSamples));
  append(",\"motion_power_min_suppress_ms\":%lu",
         static_cast<unsigned long>(STACKCHAN_MOTION_POWER_MIN_SUPPRESS_MS));
#endif
  append(",\"motion_enabled_at_boot\":%d", STACKCHAN_MOTION_ENABLED_AT_BOOT ? 1 : 0);
  append(",\"debug_tone_request\":%s", (speakerToneRequest || micToneRequest) ? "true" : "false");
  append(",\"debug_tone_accepted\":%s", toneRequestAccepted ? "true" : "false");
  append(",\"debug_wake_reset_request\":%s", wakeResetRequest ? "true" : "false");
  append(",\"debug_motion_request\":%s", motionControlRequest ? "true" : "false");
  append(",\"debug_motion_target_enabled\":%s", motionControlTargetEnabled ? "true" : "false");
  append(",\"debug_motion_accepted\":%s", motionControlRequestAccepted ? "true" : "false");
  append(",\"debug_recovery_request\":%s", recoveryRequest ? "true" : "false");
  append(",\"debug_recovery_accepted\":%s",
         (recoveryRequest && STACKCHAN_REMOTE_RECOVERY_ENABLE != 0) ? "true" : "false");
  append(",\"debug_reboot_request\":%s", rebootRequest ? "true" : "false");
  append(",\"debug_reboot_accepted\":%s",
         (rebootRequest && STACKCHAN_REMOTE_RECOVERY_ENABLE != 0) ? "true" : "false");
  append(",\"debug_audio_stop_request\":%s", audioStopRequest ? "true" : "false");
  append(",\"recovery_enabled\":%d", STACKCHAN_REMOTE_RECOVERY_ENABLE ? 1 : 0);
  append(",\"recovery_requested\":%s", gBridgeRecovery.recoveryRequested ? "true" : "false");
  append(",\"recovery_reboot_requested\":%s", gBridgeRecovery.rebootRequested ? "true" : "false");
  append(",\"recovery_wifi_offline_since_ms\":%lu",
         static_cast<unsigned long>(gBridgeRecovery.wifiOfflineSinceMs));
  append(",\"recovery_bridge_offline_since_ms\":%lu",
         static_cast<unsigned long>(gBridgeRecovery.bridgeOfflineSinceMs));
  append(",\"recovery_last_recovery_ms\":%lu", static_cast<unsigned long>(gBridgeRecovery.lastRecoveryMs));
  append(",\"recovery_scheduled_recovery_ms\":%lu",
         static_cast<unsigned long>(gBridgeRecovery.scheduledRecoveryMs));
  append(",\"recovery_scheduled_reboot_ms\":%lu",
         static_cast<unsigned long>(gBridgeRecovery.scheduledRebootMs));
  append(",\"recovery_wifi_restarts\":%lu", static_cast<unsigned long>(gBridgeRecovery.wifiRestarts));
  append(",\"recovery_bridge_restarts\":%lu", static_cast<unsigned long>(gBridgeRecovery.bridgeRestarts));
  append(",\"recovery_reboot_requests\":%lu", static_cast<unsigned long>(gBridgeRecovery.rebootRequests));
  append(",\"recovery_last_reason\":\"%s\"", gBridgeRecovery.lastReason);
  append(",\"compiled_enable_speaker\":%d", STACKCHAN_ENABLE_SPEAKER ? 1 : 0);
  append(",\"compiled_enable_mic_capture\":%d", STACKCHAN_ENABLE_MIC_CAPTURE ? 1 : 0);
  append(",\"compiled_enable_bridge_audio_uplink\":%d", STACKCHAN_ENABLE_BRIDGE_AUDIO_UPLINK ? 1 : 0);
  append(",\"network_state\":\"%s\"", bridgeNetworkStateName(network.state));
  append(",\"network_error\":\"%s\"", network.lastError);
  append(",\"network_config_source\":\"%s\"",
         gRuntimeBridgeHost[0] != '\0'
             ? "persisted_or_runtime"
             : (STACKCHAN_BRIDGE_HOST[0] != '\0' ? "compiled" : "unconfigured"));
  append(",\"network_bridge_port\":%u",
         static_cast<unsigned int>(gRuntimeBridgeHost[0] != '\0' ? gRuntimeBridgePort
                                                                  : STACKCHAN_BRIDGE_PORT));
  append(",\"network_tcp_connect_attempts\":%lu",
         static_cast<unsigned long>(gBridgeSocket.connectAttempts()));
  append(",\"network_tcp_connect_last_result\":%d", gBridgeSocket.lastConnectResult());
  append(",\"network_tcp_connect_last_errno\":%d", gBridgeSocket.lastConnectErrno());
  append(",\"network_tcp_connect_last_duration_ms\":%lu",
         static_cast<unsigned long>(gBridgeSocket.lastConnectDurationMs()));
  append(",\"network_tcp_connect_max_duration_ms\":%lu",
         static_cast<unsigned long>(gBridgeSocket.maxConnectDurationMs()));
  append(",\"bridge_state\":\"%s\"", bridgeStateName(bridge.state));
  append(",\"bridge_uplink_ready\":%s", uplink.ready ? "true" : "false");
  append(",\"bridge_uplink_enabled\":%s", uplink.enabled ? "true" : "false");
  append(",\"bridge_uplink_active\":%s", uplink.active ? "true" : "false");
  append(",\"bridge_uplink_turns\":%lu", static_cast<unsigned long>(uplink.turnsStarted));
  append(",\"bridge_uplink_chunks\":%lu", static_cast<unsigned long>(uplink.chunksQueued));
  append(",\"bridge_uplink_bytes\":%lu", static_cast<unsigned long>(uplink.bytesQueued));
  append(",\"bridge_uplink_errors\":%lu", static_cast<unsigned long>(uplink.errors));
  append(",\"bridge_uplink_queue_failures\":%lu", static_cast<unsigned long>(uplink.queueFailures));
  append(",\"bridge_uplink_last_error\":\"%s\"", uplink.lastError);
#if STACKCHAN_HAS_MWW_WAKE_PROBE && STACKCHAN_ENABLE_BRIDGE_AUDIO_UPLINK && STACKCHAN_MWW_WAKE_DRIVES_AUDIO_UPLINK
  append(",\"mww_uplink_pending\":%s", gWakeMwwUplinkPendingReady ? "true" : "false");
  append(",\"mww_uplink_queued\":%lu", static_cast<unsigned long>(gWakeMwwUplinkQueued));
  append(",\"mww_uplink_dropped\":%lu", static_cast<unsigned long>(gWakeMwwUplinkDropped));
  append(",\"mww_uplink_submitted\":%lu", static_cast<unsigned long>(gWakeMwwUplinkSubmitted));
  append(",\"mww_uplink_submit_failed\":%lu", static_cast<unsigned long>(gWakeMwwUplinkSubmitFailed));
#endif
  append(",\"audio_stream_active\":%s", bridge.audioStreamActive ? "true" : "false");
  append(",\"bridge_downlink_playback_starts\":%lu", static_cast<unsigned long>(gBridgeAudioDownlink.telemetry().playbackStarts));
  append(",\"bridge_downlink_playback_chunks\":%lu", static_cast<unsigned long>(gBridgeAudioDownlink.telemetry().playbackChunks));
  append(",\"bridge_downlink_playback_bytes\":%lu", static_cast<unsigned long>(gBridgeAudioDownlink.telemetry().playbackBytes));
  append(",\"bridge_downlink_playback_stops\":%lu", static_cast<unsigned long>(gBridgeAudioDownlink.telemetry().playbackStops));
  append(",\"bridge_downlink_playback_errors\":%lu", static_cast<unsigned long>(gBridgeAudioDownlink.telemetry().playbackErrors));
  append(",\"bridge_audio_safety_stops\":%lu", static_cast<unsigned long>(gBridgeAudioSafetyStops));
  append(",\"bridge_audio_disconnect_stops\":%lu", static_cast<unsigned long>(gBridgeAudioDisconnectStops));
  append(",\"bridge_audio_watchdog_stops\":%lu", static_cast<unsigned long>(gBridgeAudioWatchdogStops));
  append(",\"bridge_audio_remote_stop_requests\":%lu",
         static_cast<unsigned long>(gBridgeAudioRemoteStopRequests));
  append(",\"bridge_audio_last_safety_stop_ms\":%lu",
         static_cast<unsigned long>(gBridgeAudioLastSafetyStopMs));
  append(",\"bridge_audio_last_safety_stop_reason\":\"%s\"",
         bridgeAudioSafetyStopReasonName(gBridgeAudioLastSafetyStopReason));
  append(",\"speaker_volume\":%lu", static_cast<unsigned long>(gSpeakerSink.speakerVolume()));
  append(",\"speaker_enabled\":%s", gSpeakerSink.speakerEnabled() ? "true" : "false");
  append(",\"speaker_running\":%s", gSpeakerSink.speakerRunning() ? "true" : "false");
  append(",\"speaker_power_active\":%s",
         gSpeakerSink.speakerPowerActive() ? "true" : "false");
  append(",\"speaker_channel_state\":%lu",
         static_cast<unsigned long>(gSpeakerSink.speakerChannelState()));
  append(",\"speaker_power_up_entries\":%lu",
         static_cast<unsigned long>(gSpeakerSink.speakerPowerUpEntries()));
  append(",\"speaker_power_down_entries\":%lu",
         static_cast<unsigned long>(gSpeakerSink.speakerPowerDownEntries()));
  append(",\"speaker_stream_play_raw_ok\":%lu", static_cast<unsigned long>(gSpeakerSink.streamPlayRawOk()));
  append(",\"speaker_stream_play_raw_failed\":%lu", static_cast<unsigned long>(gSpeakerSink.streamPlayRawFailed()));
  append(",\"speaker_stream_chunked\":%lu", static_cast<unsigned long>(gSpeakerSink.streamPlaybackChunked()));
  append(",\"speaker_stream_first_chunk_delay_ms\":%lu", static_cast<unsigned long>(gSpeakerSink.streamLastFirstChunkDelayMs()));
  append(",\"speaker_stream_queued_audio_ms\":%lu", static_cast<unsigned long>(gSpeakerSink.streamLastQueuedAudioMs()));
  append(",\"speaker_stream_queue_wait_max_us\":%lu", static_cast<unsigned long>(gSpeakerSink.streamQueueWaitMaxUs()));
  append(",\"speaker_stream_release_deferrals\":%lu", static_cast<unsigned long>(gSpeakerSink.streamReleaseDeferrals()));
  append(",\"speaker_stream_forced_stops\":%lu", static_cast<unsigned long>(gSpeakerSink.streamForcedStops()));
  append(",\"speaker_stream_orphan_stops\":%lu", static_cast<unsigned long>(gSpeakerSink.streamOrphanStops()));
  append(",\"speaker_tone_ok\":%lu", static_cast<unsigned long>(gSpeakerSink.diagnosticToneOk()));
  append(",\"speaker_tone_failed\":%lu", static_cast<unsigned long>(gSpeakerSink.diagnosticToneFailed()));
  append(",\"display_window_max_frame_us\":%lu", static_cast<unsigned long>(display.windowMaxFrameUs));
  append(",\"display_window_slow_frames\":%lu", static_cast<unsigned long>(display.windowSlowFrames));
  append(",\"display_last_dirty_pixels\":%lu", static_cast<unsigned long>(display.lastDirtyPixels));
  append(",\"display_window_max_dirty_pixels\":%lu",
         static_cast<unsigned long>(display.windowMaxDirtyPixels));
  append(",\"display_window_max_frame_dirty_pixels\":%lu",
         static_cast<unsigned long>(display.windowMaxFrameDirtyPixels));
  append(",\"display_last_dirty_regions\":%u", static_cast<unsigned>(display.lastDirtyRegions));
  append(",\"display_window_fps\":%.2f", static_cast<double>(display.windowFps));
#if defined(ARDUINO_ARCH_ESP32)
  append(",\"ota_enabled\":%s", ota.enabled ? "true" : "false");
  append(",\"ota_token_configured\":%s", ota.tokenConfigured ? "true" : "false");
  append(",\"ota_server_started\":%s", ota.serverStarted ? "true" : "false");
  append(",\"ota_upload_active\":%s", ota.uploadActive ? "true" : "false");
  append(",\"ota_reboot_pending\":%s", ota.rebootPending ? "true" : "false");
  append(",\"ota_health_pending\":%s", ota.healthPending ? "true" : "false");
  append(",\"ota_min_free_heap_bytes\":%lu",
         static_cast<unsigned long>(STACKCHAN_OTA_MIN_FREE_HEAP_BYTES));
  append(",\"ota_health_min_vbus_mv\":%u",
         static_cast<unsigned>(STACKCHAN_OTA_HEALTH_MIN_VBUS_MV));
  append(",\"ota_health_max_frame_us\":%lu",
         static_cast<unsigned long>(STACKCHAN_OTA_HEALTH_MAX_FRAME_US));
  append(",\"ota_current_app_confirmed\":%s", ota.currentAppConfirmed ? "true" : "false");
  append(",\"ota_bootloader_rollback_enabled\":%s",
         ota.bootloaderRollbackEnabled ? "true" : "false");
  append(",\"ota_software_rollback_only\":%s", ota.softwareRollbackOnly ? "true" : "false");
  append(",\"ota_phase\":\"%s\"", otaPersistentPhaseName(ota.persistentPhase));
  append(",\"ota_running_partition\":\"%s\"", ota.runningPartition);
  append(",\"ota_previous_partition\":\"%s\"", ota.previousPartition);
  append(",\"ota_target_partition\":\"%s\"", ota.targetPartition);
  append(",\"ota_expected_sha256\":\"%s\"", ota.expectedSha256);
  append(",\"ota_last_preflight\":\"%s\"", otaPreflightResultName(ota.lastPreflight));
  append(",\"ota_uploads_completed\":%lu", static_cast<unsigned long>(ota.uploadsCompleted));
  append(",\"ota_uploads_aborted\":%lu", static_cast<unsigned long>(ota.uploadsAborted));
  append(",\"ota_health_confirmations\":%lu",
         static_cast<unsigned long>(ota.healthConfirmations));
  append(",\"ota_rollback_requests\":%lu", static_cast<unsigned long>(ota.rollbackRequests));
  append(",\"ota_health_samples\":%lu", static_cast<unsigned long>(ota.healthSamples));
  append(",\"ota_health_unhealthy_samples\":%lu",
         static_cast<unsigned long>(ota.healthUnhealthySamples));
  append(",\"ota_health_last_failure_mask\":%lu",
         static_cast<unsigned long>(ota.healthLastFailureMask));
  append(",\"ota_health_failure_mask_seen\":%lu",
         static_cast<unsigned long>(ota.healthFailureMaskSeen));
  append(",\"ota_rollback_result_code\":%ld", static_cast<long>(ota.rollbackResultCode));
  append(",\"ota_last_error\":\"%s\"", ota.lastError);
#endif
  append(",\"sr_wake_enabled\":%s", gWakeSrProbe.enabled ? "true" : "false");
  append(",\"sr_wake_compiled\":%s", gWakeSrProbe.compiled ? "true" : "false");
  append(",\"sr_wake_mww_enabled\":%s", gWakeSrProbe.mwwEnabled ? "true" : "false");
  append(",\"sr_wake_mww_compiled\":%s", gWakeSrProbe.mwwCompiled ? "true" : "false");
  append(",\"sr_wake_task_started\":%s", gWakeSrProbe.taskStarted ? "true" : "false");
  append(",\"sr_wake_mic_ready\":%s", gWakeSrProbe.micReady ? "true" : "false");
  append(",\"sr_wake_audio_pause_requested\":%s", gWakeSrProbe.audioPauseRequested ? "true" : "false");
  append(",\"sr_wake_audio_paused\":%s", gWakeSrProbe.audioPaused ? "true" : "false");
  append(",\"sr_wake_audio_pause_requests\":%lu", static_cast<unsigned long>(gWakeSrProbe.audioPauseRequests));
  append(",\"sr_wake_audio_pause_enters\":%lu", static_cast<unsigned long>(gWakeSrProbe.audioPauseEnters));
  append(",\"sr_wake_audio_resume_requests\":%lu", static_cast<unsigned long>(gWakeSrProbe.audioResumeRequests));
  append(",\"sr_wake_audio_resumes\":%lu", static_cast<unsigned long>(gWakeSrProbe.audioResumes));
  append(",\"sr_wake_audio_pause_failures\":%lu", static_cast<unsigned long>(gWakeSrProbe.audioPauseFailures));
#if STACKCHAN_HAS_MWW_WAKE_PROBE && STACKCHAN_ENABLE_BRIDGE_AUDIO_UPLINK && STACKCHAN_MWW_DEDICATED_WAKE_CAPTURE
  append(",\"wake_cue_phase\":\"%s\"", wakeCueSequencePhaseName(wakeCue.phase));
  append(",\"wake_cue_detections\":%lu", static_cast<unsigned long>(wakeCue.detections));
  append(",\"wake_cue_rejected_detections\":%lu",
         static_cast<unsigned long>(wakeCue.rejectedDetections));
  append(",\"wake_cue_rgb_commits\":%lu", static_cast<unsigned long>(wakeCue.rgbCommits));
  append(",\"wake_cue_starts\":%lu", static_cast<unsigned long>(wakeCue.cueStarts));
  append(",\"wake_cue_completions\":%lu", static_cast<unsigned long>(wakeCue.cueCompletions));
  append(",\"wake_cue_failures\":%lu", static_cast<unsigned long>(wakeCue.cueFailures));
  append(",\"wake_cue_timeouts\":%lu", static_cast<unsigned long>(wakeCue.cueTimeouts));
  append(",\"wake_cue_audio_pause_handoffs\":%lu",
         static_cast<unsigned long>(wakeCue.audioPauseHandoffs));
  append(",\"wake_cue_captures_started\":%lu",
         static_cast<unsigned long>(wakeCue.capturesStarted));
  append(",\"wake_cue_captures_completed\":%lu",
         static_cast<unsigned long>(wakeCue.capturesCompleted));
  append(",\"wake_cue_captures_failed\":%lu",
         static_cast<unsigned long>(wakeCue.capturesFailed));
  append(",\"wake_capture_incremental_active\":%s",
         gWakeMwwDedicatedCapture.active ? "true" : "false");
  append(",\"wake_capture_chunks_attempted\":%u",
         static_cast<unsigned>(gWakeMwwDedicatedCapture.chunksAttempted));
  append(",\"wake_capture_chunks_submitted\":%u",
         static_cast<unsigned>(gWakeMwwDedicatedCapture.chunksSubmitted));
  append(",\"wake_capture_service_calls\":%lu",
         static_cast<unsigned long>(gWakeMwwDedicatedCapture.serviceCalls));
  append(",\"wake_capture_max_service_us\":%lu",
         static_cast<unsigned long>(gWakeMwwDedicatedCapture.maxServiceUs));
  append(",\"wake_cue_aborts\":%lu", static_cast<unsigned long>(wakeCue.aborts));
  append(",\"wake_cue_ordering_violations\":%lu",
         static_cast<unsigned long>(wakeCue.orderingViolations));
  append(",\"wake_cue_last_detection_ms\":%lu",
         static_cast<unsigned long>(wakeCue.lastDetectionMs));
  append(",\"wake_cue_last_rgb_commit_ms\":%lu",
         static_cast<unsigned long>(wakeCue.lastRgbCommitMs));
  append(",\"wake_cue_last_audio_paused_ms\":%lu",
         static_cast<unsigned long>(wakeCue.lastAudioPausedMs));
  append(",\"wake_cue_last_start_ms\":%lu",
         static_cast<unsigned long>(wakeCue.lastCueStartMs));
  append(",\"wake_cue_last_end_ms\":%lu", static_cast<unsigned long>(wakeCue.lastCueEndMs));
  append(",\"wake_cue_last_capture_start_ms\":%lu",
         static_cast<unsigned long>(wakeCue.lastCaptureStartMs));
  append(",\"wake_cue_last_capture_end_ms\":%lu",
         static_cast<unsigned long>(wakeCue.lastCaptureEndMs));
  append(",\"wake_cue_last_detection_to_start_ms\":%lu",
         static_cast<unsigned long>(wakeCue.lastCueStartMs >= wakeCue.lastDetectionMs
                                        ? wakeCue.lastCueStartMs - wakeCue.lastDetectionMs
                                        : 0));
  append(",\"wake_cue_last_playback_ms\":%lu",
         static_cast<unsigned long>(wakeCue.lastCueEndMs >= wakeCue.lastCueStartMs
                                        ? wakeCue.lastCueEndMs - wakeCue.lastCueStartMs
                                        : 0));
  append(",\"wake_cue_last_end_to_capture_ms\":%lu",
         static_cast<unsigned long>(wakeCue.lastCaptureStartMs >= wakeCue.lastCueEndMs
                                        ? wakeCue.lastCaptureStartMs - wakeCue.lastCueEndMs
                                        : 0));
  append(",\"wake_cue_last_postcue_preroll_samples\":%lu",
         static_cast<unsigned long>(wakeCue.lastPostCuePreRollSamples));
#endif
  append(",\"sr_wake_sr_ready\":%s", gWakeSrProbe.srReady ? "true" : "false");
  append(",\"sr_wake_record_ok\":%lu", static_cast<unsigned long>(gWakeSrProbe.recordOk));
  append(",\"sr_wake_record_drops\":%lu", static_cast<unsigned long>(gWakeSrProbe.recordDrops));
  append(",\"sr_wake_audio_peak\":%d", gWakeSrProbe.audioPeak);
  append(",\"sr_wake_audio_mean_abs\":%d", gWakeSrProbe.audioMeanAbs);
  append(",\"sr_wake_audio_clips\":%lu", static_cast<unsigned long>(gWakeSrProbe.audioClips));
  append(",\"sr_wake_stereo_direction_estimates\":%lu",
         static_cast<unsigned long>(gWakeSrProbe.stereoDirectionEstimates));
  append(",\"sr_wake_stereo_direction_rejected\":%lu",
         static_cast<unsigned long>(gWakeSrProbe.stereoDirectionRejected));
  append(",\"sr_wake_stereo_direction_azimuth_norm\":%.3f",
         static_cast<double>(gWakeSrProbe.stereoDirectionLastAzimuthNorm));
  append(",\"sr_wake_stereo_direction_confidence\":%.3f",
         static_cast<double>(gWakeSrProbe.stereoDirectionLastConfidence));
  append(",\"sr_wake_stereo_direction_correlation\":%.3f",
         static_cast<double>(gWakeSrProbe.stereoDirectionLastCorrelation));
  append(",\"sr_wake_stereo_direction_lag_samples\":%ld",
         static_cast<long>(gWakeSrProbe.stereoDirectionLastLagSamples));
  append(",\"sr_wake_mww_detections\":%lu", static_cast<unsigned long>(gWakeSrProbe.mwwDetections));
  append(",\"sr_wake_mww_last_probability\":%d", gWakeSrProbe.mwwLastProbability);
  append(",\"sr_wake_mww_max_probability\":%d", gWakeSrProbe.mwwMaxProbability);
  append(",\"sr_wake_mww_average_probability\":%d", gWakeSrProbe.mwwAverageProbability);
  append(",\"sr_wake_mww_max_average_probability\":%d", gWakeSrProbe.mwwMaxAverageProbability);
  append(",\"sr_wake_mww_probability_cutoff\":%d", gWakeSrProbe.mwwProbabilityCutoff);
  append(",\"sr_wake_mww_sliding_window\":%d", gWakeSrProbe.mwwSlidingWindowSize);
  append(",\"sr_wake_mww_last_detection_probability\":%d", gWakeSrProbe.mwwLastDetectionProbability);
  append(",\"sr_wake_mww_last_detection_average_probability\":%d", gWakeSrProbe.mwwLastDetectionAverageProbability);
  append(",\"sr_wake_mww_max_detection_average_probability\":%d", gWakeSrProbe.mwwMaxDetectionAverageProbability);
  append(",\"sr_wake_mww_arenas_zero_initialized\":%s",
         gWakeSrProbe.mwwArenasZeroInitialized ? "true" : "false");
  append(",\"sr_wake_detections\":%lu", static_cast<unsigned long>(gWakeSrProbe.wakeDetections));
  append(",\"sr_wake_events_applied\":%lu", static_cast<unsigned long>(gWakeSrProbe.wakeEventsApplied));
  append(",\"sr_wake_model\":\"%s\"", gWakeSrProbe.modelName);
  append(",\"sr_wake_error\":\"%s\",\"debug_response_truncated\":false}\r\n",
         gWakeSrProbe.lastError);
  if (bodyTruncated) {
    const int tailLen = snprintf(body + len,
                                 sizeof(body) - len,
                                 ",\"debug_response_truncated\":true}\r\n");
    if (tailLen > 0 && static_cast<size_t>(tailLen) < sizeof(body) - len) {
      len += static_cast<size_t>(tailLen);
    }
  }

  char header[128] = {};
  const int headerLen = snprintf(
      header,
      sizeof(header),
      "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: %u\r\nConnection: close\r\n\r\n",
      static_cast<unsigned>(len));
  if (headerLen > 0) {
    client.write(reinterpret_cast<const uint8_t*>(header), static_cast<size_t>(headerLen));
  }
  client.write(reinterpret_cast<const uint8_t*>(body), len);
  delay(1);
  client.stop();
}

#if defined(ARDUINO_ARCH_ESP32) && STACKCHAN_ENABLE_CAMERA_HOST_VISION
bool writeHttpBody(WiFiClient& client, const uint8_t* data, size_t length) {
  size_t offset = 0;
  const uint32_t deadlineMs = millis() + 3000;
  while (offset < length && client.connected() &&
         static_cast<int32_t>(deadlineMs - millis()) > 0) {
    const size_t written = client.write(data + offset, length - offset);
    if (written == 0) {
      delay(1);
      continue;
    }
    offset += written;
    taskYIELD();
  }
  return offset == length;
}

void serveCameraHostText(WiFiClient& client, int statusCode, const char* statusText,
                         const char* body) {
  const size_t bodyLength = strlen(body);
  client.printf("HTTP/1.1 %d %s\r\nContent-Type: application/json\r\n"
                "Cache-Control: no-store\r\nContent-Length: %u\r\nConnection: close\r\n\r\n",
                statusCode,
                statusText,
                static_cast<unsigned>(bodyLength));
  writeHttpBody(client, reinterpret_cast<const uint8_t*>(body), bodyLength);
  delay(1);
  client.stop();
}

void serveCameraGrayFrame(WiFiClient& client, const char* requestTarget) {
  char pairingCode[7] = {};
  if (!parseCameraHostPairingCode(
          requestTarget, "/camera-gray.pgm", pairingCode, sizeof(pairingCode)) ||
      !gBridgeEndpointControl.authorizesPairedRequest(pairingCode)) {
    gCamera.noteHostAuthFailure();
    serveCameraHostText(client, 403, "Forbidden", "{\"ok\":false,\"error\":\"pairing_required\"}\n");
    return;
  }

  constexpr size_t kGrayCapacity = 160u * 120u;
  static uint8_t* gray = nullptr;
  if (gray == nullptr) {
    gray = static_cast<uint8_t*>(
        heap_caps_malloc(kGrayCapacity, MALLOC_CAP_SPIRAM | MALLOC_CAP_8BIT));
  }
  CameraGrayFrame frame;
  if (gray == nullptr || !gCamera.captureGray160(gray, kGrayCapacity, &frame, millis())) {
    serveCameraHostText(client, 503, "Service Unavailable",
                        "{\"ok\":false,\"error\":\"camera_capture_failed\"}\n");
    return;
  }

  char pgmHeader[32] = {};
  const int pgmHeaderLength = snprintf(pgmHeader,
                                       sizeof(pgmHeader),
                                       "P5\n%u %u\n255\n",
                                       static_cast<unsigned>(frame.width),
                                       static_cast<unsigned>(frame.height));
  if (pgmHeaderLength <= 0 || static_cast<size_t>(pgmHeaderLength) >= sizeof(pgmHeader)) {
    serveCameraHostText(client, 500, "Internal Server Error",
                        "{\"ok\":false,\"error\":\"pgm_header_failed\"}\n");
    return;
  }
  const size_t contentLength = static_cast<size_t>(pgmHeaderLength) + frame.length;
  client.printf("HTTP/1.1 200 OK\r\nContent-Type: image/x-portable-graymap\r\n"
                "Cache-Control: no-store\r\nContent-Length: %u\r\nConnection: close\r\n\r\n",
                static_cast<unsigned>(contentLength));
  const bool headerWritten = writeHttpBody(client,
                                           reinterpret_cast<const uint8_t*>(pgmHeader),
                                           static_cast<size_t>(pgmHeaderLength));
  const bool frameWritten = headerWritten && writeHttpBody(client, gray, frame.length);
  gCamera.noteHostFrameResponse(frameWritten);
  delay(1);
  client.stop();
}

void serveCameraVisionTarget(WiFiClient& client, const char* requestTarget) {
  CameraHostVisionTarget target;
  if (!parseCameraHostVisionTarget(requestTarget, &target)) {
    serveCameraHostText(client, 400, "Bad Request",
                        "{\"ok\":false,\"error\":\"invalid_target\"}\n");
    return;
  }
  if (!gBridgeEndpointControl.authorizesPairedRequest(target.pairingCode)) {
    gCamera.noteHostAuthFailure();
    serveCameraHostText(client, 403, "Forbidden", "{\"ok\":false,\"error\":\"pairing_required\"}\n");
    return;
  }
  gCamera.noteHostTargetUpdate();
  if (target.faceCount == 0) {
    gCamera.submitFaceLost(millis(), 1.0f);
  } else {
    gCamera.submitFaces(target.faces, target.faceCount, millis());
  }
  serveCameraHostText(client, 200, "OK", "{\"ok\":true}\n");
}
#endif

void pollBridgeDebugServer(uint32_t nowMs) {
#if defined(ARDUINO_ARCH_ESP32)
  if (!gBridgeWiFi.isConnected()) {
    return;
  }
  if (!gBridgeDebugServerStarted) {
    gBridgeDebugServer.begin();
    gBridgeDebugServerStarted = true;
  }

  WiFiClient client = gBridgeDebugServer.available();
  if (!client) {
    return;
  }
  client.setTimeout(100);
  uint32_t requestStartMs = millis();
  char requestLine[256] = {};
  size_t requestLineLen = 0;
  bool firstLineComplete = false;
  while (client.connected() && requestStartMs != 0 &&
         millis() - requestStartMs < STACKCHAN_BRIDGE_DEBUG_REQUEST_TIMEOUT_MS) {
    while (client.available() > 0) {
      const char ch = static_cast<char>(client.read());
      if (!firstLineComplete && ch != '\r' && ch != '\n' && requestLineLen < sizeof(requestLine) - 1u) {
        requestLine[requestLineLen++] = ch;
        requestLine[requestLineLen] = '\0';
      }
      if (ch == '\n') {
        firstLineComplete = true;
        requestStartMs = 0;
      }
    }
    if (requestStartMs != 0) {
      delay(1);
    }
  }

  char requestTarget[224] = "/";
  const char* firstSpace = strchr(requestLine, ' ');
  if (firstSpace != nullptr) {
    const char* targetStart = firstSpace + 1;
    const char* secondSpace = strchr(targetStart, ' ');
    const size_t targetLen =
        secondSpace != nullptr ? static_cast<size_t>(secondSpace - targetStart) : strlen(targetStart);
    const size_t copyLen = targetLen < sizeof(requestTarget) - 1u ? targetLen : sizeof(requestTarget) - 1u;
    memcpy(requestTarget, targetStart, copyLen);
  requestTarget[copyLen] = '\0';
  }
#if STACKCHAN_ENABLE_CAMERA_HOST_VISION
  if (strncmp(requestTarget, "/camera-gray.pgm?", 17) == 0) {
    serveCameraGrayFrame(client, requestTarget);
    return;
  }
  if (strncmp(requestTarget, "/vision-target?", 15) == 0) {
    serveCameraVisionTarget(client, requestTarget);
    return;
  }
#endif
  const bool speakerToneRequest =
      strcmp(requestTarget, "/tone") == 0 || strcmp(requestTarget, "/speaker-test") == 0;
  const bool micToneSoftRequest =
      strcmp(requestTarget, "/mic-tone") == 0 || strcmp(requestTarget, "/mic-tone-soft") == 0;
  const bool micToneTapRequest = strcmp(requestTarget, "/mic-tone-tap") == 0;
  const bool micToneOldRequest = strcmp(requestTarget, "/mic-tone-old") == 0;
  const bool micToneRequest = micToneSoftRequest || micToneTapRequest || micToneOldRequest;
  const bool wakeResetRequest = strcmp(requestTarget, "/wake-reset") == 0;
  const bool audioStopRequest =
      strcmp(requestTarget, "/audio-stop") == 0 || strcmp(requestTarget, "/playback-stop") == 0;
  const bool motionEnableRequest =
      strcmp(requestTarget, "/motion-resume") == 0 || strcmp(requestTarget, "/motion-on") == 0 ||
      strcmp(requestTarget, "/servos-on") == 0;
  const bool motionDisableRequest =
      strcmp(requestTarget, "/motion-stop") == 0 || strcmp(requestTarget, "/motion-off") == 0 ||
      strcmp(requestTarget, "/servos-off") == 0;
  const bool motionControlRequest = motionEnableRequest || motionDisableRequest;
  const bool recoveryRequest =
      strcmp(requestTarget, "/recover") == 0 || strcmp(requestTarget, "/bridge-recover") == 0 ||
      strcmp(requestTarget, "/wifi-recover") == 0;
  const bool rebootRequest =
      strcmp(requestTarget, "/reboot") == 0 || strcmp(requestTarget, "/restart") == 0 ||
      strcmp(requestTarget, "/reset") == 0;
  const LanOtaTelemetry& ota = gLanOtaServer.telemetry();
  const bool otaBusy = ota.uploadActive || ota.rebootPending;
  bool toneRequestAccepted = false;
  bool motionControlRequestAccepted = false;
  if (speakerToneRequest && !otaBusy) {
    suppressWakeMwwDetections(millis(), 900);
    toneRequestAccepted = gSpeakerSink.playDiagnosticTone();
  } else if (micToneSoftRequest && !otaBusy) {
    suppressWakeMwwDetections(millis(), 900);
    toneRequestAccepted = gSpeakerSink.playMicActivationTone();
  } else if (micToneTapRequest && !otaBusy) {
    suppressWakeMwwDetections(millis(), 900);
    toneRequestAccepted = gSpeakerSink.playMicActivationTap();
  } else if (micToneOldRequest && !otaBusy) {
    suppressWakeMwwDetections(millis(), 900);
    toneRequestAccepted = gSpeakerSink.playLegacyMicActivationTone();
  }
#if STACKCHAN_HAS_MWW_WAKE_PROBE
  if (wakeResetRequest) {
    gWakeMwwResetRequested = true;
  }
#endif
  if (audioStopRequest) {
    gBridgeAudioRemoteStopRequests++;
    stopBridgeAudioRuntime(nowMs, BridgeAudioSafetyStopReason::RemoteRequest);
  }
  if (motionControlRequest) {
    BenchControl control;
    control.hasMotionEnable = true;
    control.motionEnabled = motionEnableRequest;
    motionControlRequestAccepted = publishMotionControl(control);
  }
#if defined(ARDUINO_ARCH_ESP32) && STACKCHAN_REMOTE_RECOVERY_ENABLE != 0
  if (recoveryRequest) {
    gBridgeRecovery.recoveryRequested = true;
    gBridgeRecovery.scheduledRecoveryMs = millis() + STACKCHAN_REMOTE_RECOVERY_DELAY_MS;
    gBridgeRecovery.lastReason = "remote_recover";
  }
  if (rebootRequest) {
    gBridgeRecovery.rebootRequested = true;
    requestBridgeReboot("remote_reboot", millis());
  }
#endif
#if STACKCHAN_HAS_MWW_WAKE_PROBE
  if (strcmp(requestTarget, "/wake.wav") == 0 || strcmp(requestTarget, "/wake-pcm.wav") == 0) {
    serveWakeMwwPcmWav(client);
    client.flush();
    delay(1);
    client.stop();
    return;
  }
#endif
  if (strcmp(requestTarget, "/debug") == 0) {
    serveBridgeLeanStatusJson(
        client,
        "stackchan.bridge-debug.v1",
        requestTarget,
        speakerToneRequest,
        micToneRequest,
        wakeResetRequest,
        motionControlRequest,
        motionEnableRequest,
        motionControlRequestAccepted,
        toneRequestAccepted);
    return;
  }

  serveBridgeLeanStatusJson(
      client,
      "stackchan.bridge-status.v1",
      requestTarget,
      speakerToneRequest,
      micToneRequest,
      wakeResetRequest,
      motionControlRequest,
      motionEnableRequest,
      motionControlRequestAccepted,
      toneRequestAccepted);
  return;
#endif
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
      const bool renewActiveSession = input.motionEnabled && gMotionRequested && gActuation.isEnabled();
      gMotionRequested = input.motionEnabled;
      if (renewActiveSession) {
        const bool refreshed = gActuation.refreshSession();
        Serial.print(F("[motion] session_refreshed="));
        Serial.println(refreshed ? 1 : 0);
      }
      Serial.print(F("[motion] requested="));
      Serial.println(gMotionRequested ? 1 : 0);
    }
  }
}

bool shouldSuppressMotionForAudio(uint32_t nowMs) {
#if STACKCHAN_MOTION_AUDIO_LOAD_SHED_COOLDOWN_MS > 0
  const BridgeAudioUplinkTelemetry& uplink = gBridgeAudioUplink.telemetry();
  const BridgeAudioDownlinkTelemetry& downlink = gBridgeAudioDownlink.telemetry();
  const BridgeWakeGateTelemetry& wakeGate = gBridgeWakeGate.telemetry();
  const BridgeClientTelemetry& bridge = gBridge.telemetry();
  const AudioOutTelemetry& audioOut = gAudioOut.telemetry();
  const bool bridgeBusy =
      bridge.state == BridgeClientState::Listening ||
      bridge.state == BridgeClientState::Thinking ||
      bridge.state == BridgeClientState::Responding ||
      gBridge.hasPendingOutput();
  MotionAudioActivity activity;
  activity.microphoneCaptureActive = uplink.active;
  activity.wakeTurnActive = wakeGate.turnActive;
  activity.bridgeConversationBusy = bridgeBusy;
  activity.pendingBridgeOutput = gBridge.hasPendingOutput();
  activity.downlinkActive = downlink.active;
  activity.downlinkPlaybackActive = downlink.playbackActive;
  activity.bridgeAudioStreamActive = bridge.audioStreamActive;
  activity.audioOutputPlaybackActive = audioOut.playbackActive || audioOut.hardwarePlaybackActive;
  activity.speakerPowerActive = gSpeakerSink.speakerPowerActive() != 0;
  activity.speakerRunning = gSpeakerSink.speakerRunning() != 0;
  gMotionAudioPreemptActive = gMotionAudioPreemptionGate.update(
      activity, nowMs, STACKCHAN_MOTION_AUDIO_LOAD_SHED_COOLDOWN_MS);
  gMotionAudioPlaybackActive = gMotionAudioPreemptionGate.audioLoadActive();
  return gMotionAudioPreemptActive;
#else
  (void)nowMs;
  gMotionAudioPreemptionGate.reset();
  gMotionAudioPlaybackActive = false;
  gMotionAudioPreemptActive = false;
  return false;
#endif
}

bool shouldSuppressMotionForThermal(uint32_t nowMs) {
#if defined(ARDUINO_ARCH_ESP32) && STACKCHAN_MOTION_THERMAL_LOAD_SHED_C > 0
  sampleChipTemperature(nowMs, false);
  const float loadShedC = static_cast<float>(STACKCHAN_MOTION_THERMAL_LOAD_SHED_C);
  const float resumeC = STACKCHAN_MOTION_THERMAL_RESUME_C > 0
                            ? static_cast<float>(STACKCHAN_MOTION_THERMAL_RESUME_C)
                            : loadShedC - 5.0f;
  if (!gChipTemperatureValid) {
    return gMotionThermalSuppressed;
  }
  if (gMotionThermalSuppressed) {
    if (gChipTemperatureC <= resumeC) {
      gMotionThermalSuppressed = false;
      Serial.println(F("[motion] thermal_load_shed=0"));
    }
    return gMotionThermalSuppressed;
  }
  if (gChipTemperatureC >= loadShedC) {
    gMotionThermalSuppressed = true;
    ++gMotionThermalSuppressEntries;
    Serial.print(F("[motion] thermal_load_shed=1 chip_temp_c="));
    Serial.println(gChipTemperatureC, 1);
  }
  return gMotionThermalSuppressed;
#else
  (void)nowMs;
  return false;
#endif
}

bool shouldSuppressMotionForPower(uint32_t nowMs) {
#if defined(ARDUINO_ARCH_ESP32) && STACKCHAN_MOTION_POWER_LOAD_SHED_MV > 0
  samplePowerTelemetry(nowMs, false);
  const int32_t loadShedMv = STACKCHAN_MOTION_POWER_LOAD_SHED_MV;
  const int32_t resumeMv = STACKCHAN_MOTION_POWER_RESUME_MV > 0
                               ? STACKCHAN_MOTION_POWER_RESUME_MV
                               : loadShedMv + 100;
  const int32_t hardFloorMv = STACKCHAN_MOTION_POWER_HARD_FLOOR_MV > 0
                                  ? STACKCHAN_MOTION_POWER_HARD_FLOOR_MV
                                  : loadShedMv;
  const uint32_t minSuppressMs = STACKCHAN_MOTION_POWER_MIN_SUPPRESS_MS;
  const uint32_t bodySampleMaxAgeMs =
      STACKCHAN_BODY_POWER_TELEMETRY_PERIOD_MS > 0
          ? static_cast<uint32_t>(STACKCHAN_BODY_POWER_TELEMETRY_PERIOD_MS) * 4u
          : 1000u;
  const bool bodySampleFresh =
      gBodyPowerTelemetryValid && gBodyPowerTelemetryLastReadMs != 0 &&
      nowMs - gBodyPowerTelemetryLastReadMs <= bodySampleMaxAgeMs;
  const bool chargeBacked =
      STACKCHAN_MOTION_POWER_CHARGE_BACKED_CURRENT_MA > 0 && bodySampleFresh &&
      gBodyPowerCurrentMa <= -static_cast<float>(STACKCHAN_MOTION_POWER_CHARGE_BACKED_CURRENT_MA);
  gMotionPowerChargeBacked = chargeBacked;
  if (chargeBacked) {
    ++gMotionPowerChargeBackedSamples;
  }
  if (!gPowerVbusValid || gPowerVbusMv < 0) {
    if (!gMotionPowerSuppressed) {
      gMotionPowerSuppressed = true;
      gMotionPowerSuppressedAtMs = nowMs;
      ++gMotionPowerSuppressEntries;
      Serial.println(F("[motion] power_load_shed=1 reason=vbus_invalid"));
    }
    return true;
  }
  const int32_t effectiveLoadShedMv = chargeBacked ? hardFloorMv : loadShedMv;
  const int32_t effectiveResumeMv = chargeBacked ? loadShedMv : resumeMv;
  if (gMotionPowerSuppressed) {
    const bool heldLongEnough =
        gMotionPowerSuppressedAtMs == 0 || nowMs - gMotionPowerSuppressedAtMs >= minSuppressMs;
    if (heldLongEnough && static_cast<int32_t>(gPowerVbusMv) >= effectiveResumeMv) {
      gMotionPowerSuppressed = false;
      Serial.print(F("[motion] power_load_shed=0 vbus_mv="));
      Serial.print(gPowerVbusMv);
      Serial.print(F(" charge_backed="));
      Serial.println(chargeBacked ? 1 : 0);
    }
    return gMotionPowerSuppressed;
  }
  if (static_cast<int32_t>(gPowerVbusMv) <= effectiveLoadShedMv) {
    gMotionPowerSuppressed = true;
    gMotionPowerSuppressedAtMs = nowMs;
    ++gMotionPowerSuppressEntries;
    Serial.print(F("[motion] power_load_shed=1 vbus_mv="));
    Serial.print(gPowerVbusMv);
    Serial.print(F(" effective_floor_mv="));
    Serial.print(effectiveLoadShedMv);
    Serial.print(F(" charge_backed="));
    Serial.println(chargeBacked ? 1 : 0);
  }
  return gMotionPowerSuppressed;
#else
  (void)nowMs;
  return false;
#endif
}

void MotionTask(void* pv) {
  (void)pv;
  RobotFrame target = makeNeutralFrame();
  TickType_t wake = xTaskGetTickCount();

  while (true) {
    target = readLatestFrame(target);
    applyMotionControlInput();
    const uint32_t nowMs = millis();
    const bool thermalSuppressed = shouldSuppressMotionForThermal(nowMs);
    const bool powerSuppressed = shouldSuppressMotionForPower(nowMs);
    const bool audioSuppressed = shouldSuppressMotionForAudio(nowMs);

    PowerCoordinatorInput powerInput;
    powerInput.motionRequested = gMotionRequested;
    powerInput.audioBusy = audioSuppressed;
    powerInput.thermalBlocked = thermalSuppressed;
    powerInput.supplyBlocked = powerSuppressed;
    const PowerCoordinatorDecision powerDecision = gPowerCoordinator.update(powerInput, nowMs);

    if (!gMotionRequested) {
      if (gActuation.isEnabled()) {
        gActuation.setEnabled(false);
      }
      gServo.setPowerAllowed(false);
    } else if (powerDecision.motionAllowed) {
      gServo.setPowerAllowed(true);
      if (!gActuation.isEnabled()) {
        gActuation.setEnabled(true);
      }
      if (gActuation.isEnabled()) {
        gActuation.setOutputSuppressed(false, powerDecision.reason);
      } else {
        gMotionRequested = false;
        gServo.setPowerAllowed(false);
      }
    } else {
      if (gActuation.isEnabled()) {
        gActuation.setOutputSuppressed(true, powerDecision.reason);
      }
      gServo.setPowerAllowed(false);
    }

    const bool enabledBeforeUpdate = gActuation.isEnabled();
    gActuation.update(target, micros());
    if (enabledBeforeUpdate && !gActuation.isEnabled()) {
      gMotionRequested = false;
      gServo.setPowerAllowed(false);
    }
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
  Serial.println(F("[task] intent started core=1 priority=3"));
  TickType_t wake = xTaskGetTickCount();
  uint32_t lastSpeechSeq = 0;
  RobotEvent pendingAudioEvents[4];
  uint8_t pendingAudioEventCount = 0;

  while (true) {
    const uint32_t loopMs = millis();
    gBridgeEndpointControl.update(loopMs);
    drainWakeMwwUplinkQueue(loopMs);
    gBridgeWakeGate.update(loopMs);
    updateBridgeNetwork(loopMs);
#if defined(ARDUINO_ARCH_ESP32)
    serviceLanOta(loopMs);
    if (gLanOtaServer.telemetry().uploadActive) {
      vTaskDelayUntil(&wake, pdMS_TO_TICKS(gConfig.timing.intentPeriodMs));
      continue;
    }
#endif
    pollBridgeOutputs(loopMs);
    pollBridgeDebugServer(loopMs);
    ensureWakeSrStarted(loopMs);
    pollWakeSrProbe(loopMs);
    pollWakeSrDirect(loopMs);
    pollWakeSrAfeLite(loopMs);
    pollWakeMwwProbe(loopMs);
#if STACKCHAN_CAMERA_CAPTURE_PROBE_ONLY
    gCamera.serviceCaptureProbe(loopMs);
#endif

    AudioReflexEvent audioEvents[3];
    const uint32_t audioWindowsBefore = gAudioCapture.telemetry().windowsCaptured;
    const uint8_t audioEventCount = gAudioCapture.poll(loopMs, audioEvents, 3);
    if (gAudioCapture.telemetry().windowsCaptured != audioWindowsBefore) {
      submitCapturedAudioWindowToBridgeUplink(loopMs);
    }
    for (uint8_t i = 0; i < audioEventCount; ++i) {
      if (!audioEvents[i].valid) {
        continue;
      }
      gIntent.applyEvent(audioEvents[i].event, audioEvents[i].mode);
      if (audioEvents[i].event.type == EventType::SoundDirection && audioEvents[i].event.hasPayload) {
        gCamera.submitSoundDirection(
            audioEvents[i].event.x, audioEvents[i].event.strength, audioEvents[i].event.timestampMs);
      }
      if (pendingAudioEventCount < 4) {
        pendingAudioEvents[pendingAudioEventCount++] = audioEvents[i].event;
      }
      gBridgeWakeGate.applyEvent(audioEvents[i].event, loopMs);
      if (audioEvents[i].event.type == EventType::UserSpeaking) {
        gAudioOut.duck(loopMs);
      }
    }

#if STACKCHAN_HAS_MWW_WAKE_PROBE && STACKCHAN_ENABLE_CAMERA && STACKCHAN_MWW_WAKE_RECORD_STEREO
    WakeMwwStereoDirectionPending stereoDirection;
    if (takeWakeMwwStereoDirection(&stereoDirection)) {
      gCamera.submitSoundDirection(stereoDirection.azimuthNorm,
                                   stereoDirection.confidence,
                                   stereoDirection.capturedAtMs);
    }
#endif

    RobotEvent cameraEvent;
    while (gCamera.poll(&cameraEvent)) {
      gIntent.applyEvent(cameraEvent, visionModeForEvent(cameraEvent.type));
      printVisionTelemetry(cameraEvent, millis());
    }

    const ActuationTelemetry motionTelemetry = gActuation.telemetry();
    RobotEvent imuEvent;
    if (gImu.poll(loopMs, motionTelemetry.selfMotionActive, &imuEvent)) {
      gIntent.applyEvent(imuEvent, imuModeForEvent(imuEvent.type));
      requestMotionSafetyHold(imuEvent);
    }

    BenchControl control;
    while (gSensors.poll(&control)) {
      if (control.hasEvent) {
        gIntent.applyEvent(control.event, control.mode);
        if (control.event.type == EventType::SoundDirection && control.event.hasPayload) {
          gCamera.submitSoundDirection(
              control.event.x, control.event.strength, control.event.timestampMs);
        }
        gBridgeWakeGate.applyEvent(control.event, millis());
        if (isAudioTelemetryEvent(control.event.type)) {
          if (pendingAudioEventCount < 4) {
            pendingAudioEvents[pendingAudioEventCount++] = control.event;
          }
        }
        if (control.event.type == EventType::UserSpeaking) {
          gAudioOut.duck(millis());
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
#if !STACKCHAN_ENABLE_WIFI_BRIDGE
        gIntent.queueSpeechCue(control.speechCue, millis());
#endif
      }
      if (control.hasBridge) {
        const uint32_t nowMs = millis();
        if (!handleEndpointControlLine(control.bridge.controlLine, nowMs)) {
          gBridge.submitControlLine(control.bridge.controlLine, nowMs);
        }
      }
      if (control.hasBridgeUpload) {
        handleBridgeUplinkBench(control.bridgeUpload, millis());
      }
      if (control.hasBridgeTextTurn) {
        handleBridgeTextTurnBench(control.bridgeTextTurn, millis());
      }
      if (control.hasPairingTicket) {
        handlePairingTicketControl(control.pairingTicket, millis());
      } else if (control.hasPairingControl) {
        handlePairingControl(control.pairing, millis());
      }
      if (control.hasWiFiProvisioning) {
        handleWiFiProvisioningControl(control.wifi, millis());
      }
      if (control.hasSpeakerTest) {
        const bool speakerOk = gSpeakerSink.playDiagnosticTone();
        Serial.print(F("[speaker] test=1 accepted="));
        Serial.print(speakerOk ? 1 : 0);
        Serial.print(F(" volume="));
        Serial.print(gSpeakerSink.speakerVolume());
        Serial.print(F(" channel_state="));
        Serial.print(gSpeakerSink.speakerChannelState());
        Serial.print(F(" at_ms="));
        Serial.println(millis());
      }
      if (control.hasMicCueTest) {
        const uint32_t cueMs = millis();
        suppressWakeMwwDetections(cueMs, 900);
        const bool cueOk = gSpeakerSink.playMicActivationTone();
        Serial.print(F("[speaker] mic_cue=1 accepted="));
        Serial.print(cueOk ? 1 : 0);
        Serial.print(F(" volume="));
        Serial.print(gSpeakerSink.speakerVolume());
        Serial.print(F(" channel_state="));
        Serial.print(gSpeakerSink.speakerChannelState());
        Serial.print(F(" at_ms="));
        Serial.println(cueMs);
      }
      publishSpeechInput(control);
      if (control.speech.clear || (control.hasDemoEnable && !control.demoEnabled)) {
        gAudioOut.cancel();
      }
      publishFaceControl(control);
      publishMotionControl(control);
      pollBridgeOutputs(millis());
      printBenchControl(control);
    }

    RobotEvent bodyTouchEvent;
    BodyTouchInteraction bodyTouchInteraction;
    if (gBodyPeripheral.pollTouch(loopMs, &bodyTouchEvent, &bodyTouchInteraction)) {
      gIntent.applyEvent(bodyTouchEvent, CharacterMode::React);
      gBodyFeedback.notifyTouch(
          bodyTouchInteraction.zone, bodyTouchEvent.strength, bodyTouchEvent.timestampMs);
    }
    pollBridgeOutputs(millis());
    playMicActivationCueIfNeeded();
    const uint32_t speakerNowMs = millis();
    gSpeakerSink.service(speakerNowMs);
    if (gSpeakerSink.takeStreamWatchdogStop()) {
      stopBridgeAudioRuntime(speakerNowMs, BridgeAudioSafetyStopReason::StreamWatchdog);
    }
#if STACKCHAN_HAS_MWW_WAKE_PROBE && STACKCHAN_ENABLE_BRIDGE_AUDIO_UPLINK && STACKCHAN_MWW_DEDICATED_WAKE_CAPTURE
    serviceDedicatedWakeCapture(millis());
#endif

    const ServoPowerTelemetry intentServoPower = gServo.powerTelemetry();
    gIntent.setMotionOutputActive(
        gActuation.isEnabled() && !gActuation.outputSuppressed() && intentServoPower.railEnabled,
        millis());
    RobotFrame frame = gIntent.update(millis());
    gCamera.setRobotSpeaking(frame.mode == CharacterMode::Speak, frame.timestampMs);
    const FaceSpeechTelemetry& faceSpeech = gFace.speechTelemetry();
    const BodyRgbFrame bodyRgb = gBodyFeedback.render(
        frame, faceSpeech.envelope, frame.timestampMs, bodyFeedbackPowerScale(), bodyFeedbackProtected());
    gBodyPeripheral.writeRgb(bodyRgb, frame.timestampMs);
#if STACKCHAN_HAS_MWW_WAKE_PROBE && STACKCHAN_ENABLE_BRIDGE_AUDIO_UPLINK && STACKCHAN_MWW_DEDICATED_WAKE_CAPTURE
    if (gWakeCueSequence.phase() == WakeCueSequencePhase::AwaitingRgbCommit) {
      gWakeCueSequence.noteRgbCommitted(frame.timestampMs);
    }
#endif
    for (uint8_t i = 0; i < pendingAudioEventCount; ++i) {
      printAudioTelemetry(pendingAudioEvents[i], frame.timestampMs);
    }
    pendingAudioEventCount = 0;
    if (frame.speechSeq != 0 && frame.speechSeq != lastSpeechSeq && frame.speech.shouldSpeak()) {
      lastSpeechSeq = frame.speechSeq;
#if STACKCHAN_ENABLE_WIFI_BRIDGE
      gAudioOut.cancel();
#else
      if (gBridgeLocalSpeechSuppressedUntilMs != 0 &&
          static_cast<int32_t>(frame.timestampMs - gBridgeLocalSpeechSuppressedUntilMs) < 0) {
        gAudioOut.cancel();
      } else {
        printSpeechCue(frame.speech, frame.speechSeq, frame.timestampMs);
        if (gSpeechAdapter.handleCue(frame.speech, frame.speechSeq, frame.emotion, frame.timestampMs)) {
        printSpeechPlayback(gSpeechAdapter.lastPlan());
        printAudioOutPlayback(gAudioOut.lastRequest());
        }
      }
#endif
    }
    publishAudioOutSpeechFrame(frame.timestampMs);
    publishFrame(frame);
    vTaskDelayUntil(&wake, pdMS_TO_TICKS(gConfig.timing.intentPeriodMs));
  }
}

}  // namespace

#if !defined(PIO_UNIT_TESTING) && !defined(UNIT_TEST)
void setup() {
#if defined(ARDUINO_ARCH_ESP32)
  gBootResetReason = esp_reset_reason();
  ++gRtcBootCount;
#endif
  auto cfg = M5.config();
  cfg.serial_baudrate = 115200;
  if (STACKCHAN_BASE_USB_POWER_INPUT) {
    cfg.output_power = false;
  }
#if STACKCHAN_ENABLE_POWER_FORENSICS
  // The candidate owns AXP2101 IRQ polling so M5.update() cannot clear power-key evidence first.
  cfg.pmic_button = false;
#endif
  M5.begin(cfg);
#if STACKCHAN_ENABLE_POWER_FORENSICS && defined(CONFIG_IDF_TARGET_ESP32S3)
  initializePmicPowerForensics();
#endif
  M5.Log.setLogLevel(m5::log_target_serial, ESP_LOG_INFO);
  M5.Log.setEnableColor(m5::log_target_serial, false);
  delay(200);
#if defined(ARDUINO_ARCH_ESP32)
  initializeManagedPowerHardware(millis());
  sampleChipTemperature(millis(), true);
  samplePowerTelemetry(millis(), true);
#endif
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
  gCamera.begin();
  gImu.begin(millis());
  gBodyPeripheral.begin(millis());
  gAudioOut.begin(STACKCHAN_ENABLE_SPEAKER != 0, STACKCHAN_ENABLE_SPEAKER != 0 ? &gSpeakerSink : nullptr);
  const bool bridgeAudioPlaybackEnabled =
      (STACKCHAN_ENABLE_SPEAKER != 0) && (STACKCHAN_ENABLE_BRIDGE_AUDIO_DOWNLINK_PLAYBACK != 0);
  gBridgeAudioDownlink.begin(bridgeAudioPlaybackEnabled, bridgeAudioPlaybackEnabled ? &gSpeakerSink : nullptr);
  gSpeechAdapter.begin(false, &gAudioOut);
  BridgeClientConfig bridgeConfig;
  bridgeConfig.responseTimeoutMs = 120000;
  gBridge.begin(bridgeConfig);
  const uint32_t bootMs = millis();
  gBodyFeedback.begin(bootMs);
  gBridgeEndpointRegistry.begin();
  gBridgeEndpointStore.begin(gBridgeEndpointStoreBackend);
  gBridgeEndpointStore.load(gBridgeEndpointRegistry, bootMs);
  gBridgeWiFiStore.begin(gBridgeWiFiStoreBackend);
  BridgeEndpointControlConfig endpointControlConfig;
  endpointControlConfig.requiredPairingCode = STACKCHAN_PAIRING_SHORT_CODE;
  gBridgeEndpointControl.begin(gBridgeEndpointRegistry, endpointControlConfig);
  gBridgeEndpointControl.attachStore(&gBridgeEndpointStore);
  gAudioCapture.begin(AudioCaptureConfig {}, &gAudioCaptureSource);
  gBridgeWiFi.begin(storedBridgeWiFiConfigOrDefault(bootMs), bootMs);
  gBridgeNetworkSession.begin(gBridge, gBridgeSocket, gBridgeWiFi.networkSessionConfig(), bootMs);
  gBridgeNetworkSession.attachEndpointControl(&gBridgeEndpointControl);
  gBridgeAudioUplink.begin(BridgeAudioUplinkConfig {}, &gBridgeNetworkSession);
  gBridgeWakeGate.begin(BridgeWakeGateConfig {}, &gBridgeAudioUplink);
  gServo.setPowerAllowed(STACKCHAN_MOTION_ENABLED_AT_BOOT != 0);
  gActuation.begin(&gServo);
  gFace.begin(&gDisplay, gConfig.face);
  gIntent.begin();
#if defined(ARDUINO_ARCH_ESP32)
  LanOtaConfig otaConfig;
  otaConfig.tokenSha256 = STACKCHAN_OTA_TOKEN_SHA256;
  otaConfig.preflightLimits.minimumVbusMv = STACKCHAN_OTA_MIN_VBUS_MV;
  otaConfig.preflightLimits.minimumFreeHeapBytes = STACKCHAN_OTA_MIN_FREE_HEAP_BYTES;
  gLanOtaServer.begin(otaConfig, collectLanOtaPreflight, nullptr, bootMs);
#endif
  printHeartbeat();
  printSystemTelemetry();
  printRuntimeStatus();
  printWiFiBridgeStatus("boot", bootMs);

  publishFrame(makeNeutralFrame());

  const BaseType_t intentOk = xTaskCreatePinnedToCore(
      IntentTask, "IntentTask", 8192, nullptr, STACKCHAN_INTENT_TASK_PRIORITY, &gIntentTaskHandle, 1);
  const BaseType_t motionOk = xTaskCreatePinnedToCore(
      MotionTask, "MotionTask", 4096, nullptr, STACKCHAN_MOTION_TASK_PRIORITY, &gMotionTaskHandle, 1);
  const BaseType_t faceOk = xTaskCreatePinnedToCore(
      FaceTask, "FaceTask", 4096, nullptr, STACKCHAN_FACE_TASK_PRIORITY, &gFaceTaskHandle, 1);

  if (motionOk != pdPASS || faceOk != pdPASS || intentOk != pdPASS) {
    Serial.println(F("[fatal] task creation failed"));
    Serial.print(F("[fatal] motion_ok="));
    Serial.print(motionOk);
    Serial.print(F(" face_ok="));
    Serial.print(faceOk);
    Serial.print(F(" intent_ok="));
    Serial.println(intentOk);
    abort();
  }
}

void loop() {
  static uint32_t lastHeartbeatMs = 0;
  const uint32_t nowMs = millis();
#if defined(ARDUINO_ARCH_ESP32)
  samplePowerTelemetry(nowMs, false);
  applyManagedChargeCurrent(nowMs);
#endif
  updateBridgeNetwork(nowMs);
  pollBridgeOutputs(nowMs);
  pollBridgeDebugServer(nowMs);
  ensureWakeSrStarted(nowMs);
#if STACKCHAN_ENABLE_PERIODIC_SERIAL_TELEMETRY
  if (lastHeartbeatMs == 0 || nowMs - lastHeartbeatMs >= 10000) {
    lastHeartbeatMs = nowMs;
    printHeartbeat();
    printSystemTelemetry();
    printRuntimeStatus();
  }
#else
  (void)lastHeartbeatMs;
#endif
  vTaskDelay(pdMS_TO_TICKS(1000));
}
#endif
