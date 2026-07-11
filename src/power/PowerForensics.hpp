#pragma once

#include <cstdint>

namespace stackchan {

constexpr uint32_t kPmicIrqBatteryUnderTemperature = 1u << 0;
constexpr uint32_t kPmicIrqBatteryOverTemperature = 1u << 1;
constexpr uint32_t kPmicIrqChargeUnderTemperature = 1u << 2;
constexpr uint32_t kPmicIrqChargeOverTemperature = 1u << 3;
constexpr uint32_t kPmicIrqGaugeNewSoc = 1u << 4;
constexpr uint32_t kPmicIrqGaugeWatchdog = 1u << 5;
constexpr uint32_t kPmicIrqWarningLevel1 = 1u << 6;
constexpr uint32_t kPmicIrqWarningLevel2 = 1u << 7;
constexpr uint32_t kPmicIrqPowerKeyPositiveEdge = 1u << 8;
constexpr uint32_t kPmicIrqPowerKeyNegativeEdge = 1u << 9;
constexpr uint32_t kPmicIrqPowerKeyLongPress = 1u << 10;
constexpr uint32_t kPmicIrqPowerKeyShortPress = 1u << 11;
constexpr uint32_t kPmicIrqBatteryRemove = 1u << 12;
constexpr uint32_t kPmicIrqBatteryInsert = 1u << 13;
constexpr uint32_t kPmicIrqVbusRemove = 1u << 14;
constexpr uint32_t kPmicIrqVbusInsert = 1u << 15;
constexpr uint32_t kPmicIrqBatteryOverVoltage = 1u << 16;
constexpr uint32_t kPmicIrqChargerTimer = 1u << 17;
constexpr uint32_t kPmicIrqDieOverTemperature = 1u << 18;
constexpr uint32_t kPmicIrqChargeStart = 1u << 19;
constexpr uint32_t kPmicIrqChargeDone = 1u << 20;
constexpr uint32_t kPmicIrqBatfetOverCurrent = 1u << 21;
constexpr uint32_t kPmicIrqLdoOverCurrent = 1u << 22;
constexpr uint32_t kPmicIrqWatchdogExpire = 1u << 23;

// Avoid the noisy SOC and normal charger transition IRQs while retaining every
// protection, source transition, battery transition, and power-key event.
constexpr uint32_t kPmicForensicsIrqEnableMask = 0xE7FFEFu;
constexpr uint32_t kPmicProtectiveEventMask =
    kPmicIrqBatteryUnderTemperature | kPmicIrqBatteryOverTemperature |
    kPmicIrqChargeUnderTemperature | kPmicIrqChargeOverTemperature |
    kPmicIrqGaugeWatchdog | kPmicIrqWarningLevel1 | kPmicIrqWarningLevel2 |
    kPmicIrqBatteryOverVoltage | kPmicIrqChargerTimer | kPmicIrqDieOverTemperature |
    kPmicIrqBatfetOverCurrent | kPmicIrqLdoOverCurrent | kPmicIrqWatchdogExpire;

struct PmicPowerEventContext {
  int16_t vbusMv = -1;
  int16_t batteryMv = -1;
  int16_t chipTemperatureDeciC = 0;
  int16_t pmicTemperatureDeciC = 0;
  int16_t bodyBusMv = 0;
  int16_t bodyCurrentMa = 0;
  uint32_t heapFree = 0;
  bool vbusValid = false;
  bool batteryValid = false;
  bool chipTemperatureValid = false;
  bool pmicTemperatureValid = false;
  bool bodyPowerValid = false;
  bool pmicVbusPresent = false;
  bool pmicBatteryPresent = false;
  bool motionRequested = false;
  bool servoRailEnabled = false;
  bool servoTorqueEnabled = false;
  bool speakerPowerActive = false;
};

struct PmicPowerForensicsTelemetry {
  bool enabled = false;
  bool irqEnableAttempted = false;
  bool irqEnableSucceeded = false;
  bool bootStatusValid = false;
  uint32_t bootEventMask = 0;
  uint32_t runtimeEventPolls = 0;
  uint32_t runtimeProtectiveEventPolls = 0;
  uint32_t ignoredEventPolls = 0;
  uint32_t lastIgnoredEventMask = 0;
  uint32_t readFailures = 0;
  uint32_t clearFailures = 0;
  uint32_t lastEventMask = 0;
  uint32_t lastEventAtMs = 0;
  uint32_t vbusRemoveEvents = 0;
  uint32_t batteryRemoveEvents = 0;
  uint32_t warningLevel1Events = 0;
  uint32_t warningLevel2Events = 0;
  uint32_t batteryTemperatureEvents = 0;
  uint32_t chargeTemperatureEvents = 0;
  uint32_t gaugeWatchdogEvents = 0;
  uint32_t batteryOverVoltageEvents = 0;
  uint32_t chargerTimerEvents = 0;
  uint32_t dieOverTemperatureEvents = 0;
  uint32_t batfetOverCurrentEvents = 0;
  uint32_t ldoOverCurrentEvents = 0;
  uint32_t watchdogExpireEvents = 0;
  uint32_t powerKeyLongPressEvents = 0;
  PmicPowerEventContext lastContext;
};

class PmicPowerForensics {
 public:
  void begin(bool bootStatusValid, uint32_t bootEventMask);
  void setIrqEnableResult(bool attempted, bool succeeded);
  void noteReadFailure();
  void noteClearFailure();
  void recordIgnoredRuntimeEvent(uint32_t eventMask);
  bool recordRuntimeEvent(uint32_t eventMask,
                          uint32_t nowMs,
                          const PmicPowerEventContext& context);

  PmicPowerForensicsTelemetry telemetry() const {
    return telemetry_;
  }

 private:
  PmicPowerForensicsTelemetry telemetry_;
};

const char* pmicPowerEventName(uint32_t eventMask);
bool pmicPowerEventIsProtective(uint32_t eventMask);

}  // namespace stackchan
