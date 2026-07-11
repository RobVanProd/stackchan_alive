#include "power/PowerForensics.hpp"

namespace stackchan {

const char* pmicPowerEventName(uint32_t eventMask) {
  if (eventMask & kPmicIrqBatfetOverCurrent) {
    return "batfet_overcurrent";
  }
  if (eventMask & kPmicIrqLdoOverCurrent) {
    return "ldo_overcurrent";
  }
  if (eventMask & kPmicIrqDieOverTemperature) {
    return "die_overtemperature";
  }
  if (eventMask & kPmicIrqWatchdogExpire) {
    return "pmic_watchdog_expire";
  }
  if (eventMask & kPmicIrqBatteryOverVoltage) {
    return "battery_overvoltage";
  }
  if (eventMask & kPmicIrqChargerTimer) {
    return "charger_timer_expire";
  }
  if (eventMask & kPmicIrqBatteryOverTemperature) {
    return "battery_overtemperature";
  }
  if (eventMask & kPmicIrqBatteryUnderTemperature) {
    return "battery_undertemperature";
  }
  if (eventMask & kPmicIrqChargeOverTemperature) {
    return "charge_overtemperature";
  }
  if (eventMask & kPmicIrqChargeUnderTemperature) {
    return "charge_undertemperature";
  }
  if (eventMask & kPmicIrqWarningLevel2) {
    return "soc_warning_level2";
  }
  if (eventMask & kPmicIrqWarningLevel1) {
    return "soc_warning_level1";
  }
  if (eventMask & kPmicIrqGaugeWatchdog) {
    return "gauge_watchdog_timeout";
  }
  if (eventMask & kPmicIrqBatteryRemove) {
    return "battery_remove";
  }
  if (eventMask & kPmicIrqVbusRemove) {
    return "vbus_remove";
  }
  if (eventMask & kPmicIrqPowerKeyLongPress) {
    return "power_key_long_press";
  }
  if (eventMask & kPmicIrqPowerKeyShortPress) {
    return "power_key_short_press";
  }
  if (eventMask & kPmicIrqPowerKeyNegativeEdge) {
    return "power_key_negative_edge";
  }
  if (eventMask & kPmicIrqPowerKeyPositiveEdge) {
    return "power_key_positive_edge";
  }
  if (eventMask & kPmicIrqBatteryInsert) {
    return "battery_insert";
  }
  if (eventMask & kPmicIrqVbusInsert) {
    return "vbus_insert";
  }
  if (eventMask & kPmicIrqChargeDone) {
    return "charge_done";
  }
  if (eventMask & kPmicIrqChargeStart) {
    return "charge_start";
  }
  if (eventMask & kPmicIrqGaugeNewSoc) {
    return "gauge_new_soc";
  }
  return eventMask == 0 ? "none" : "unknown";
}

bool pmicPowerEventIsProtective(uint32_t eventMask) {
  return (eventMask & kPmicProtectiveEventMask) != 0;
}

void PmicPowerForensics::begin(bool bootStatusValid, uint32_t bootEventMask) {
  telemetry_ = PmicPowerForensicsTelemetry{};
  telemetry_.enabled = true;
  telemetry_.bootStatusValid = bootStatusValid;
  telemetry_.bootEventMask = bootStatusValid ? bootEventMask & 0x00FFFFFFu : 0;
}

void PmicPowerForensics::setIrqEnableResult(bool attempted, bool succeeded) {
  telemetry_.irqEnableAttempted = attempted;
  telemetry_.irqEnableSucceeded = attempted && succeeded;
}

void PmicPowerForensics::noteReadFailure() {
  ++telemetry_.readFailures;
}

void PmicPowerForensics::noteClearFailure() {
  ++telemetry_.clearFailures;
}

void PmicPowerForensics::recordIgnoredRuntimeEvent(uint32_t eventMask) {
  eventMask &= 0x00FFFFFFu;
  if (eventMask == 0) {
    return;
  }
  ++telemetry_.ignoredEventPolls;
  telemetry_.lastIgnoredEventMask = eventMask;
}

bool PmicPowerForensics::recordRuntimeEvent(uint32_t eventMask,
                                           uint32_t nowMs,
                                           const PmicPowerEventContext& context) {
  eventMask &= 0x00FFFFFFu;
  if (eventMask == 0) {
    return false;
  }

  ++telemetry_.runtimeEventPolls;
  if (pmicPowerEventIsProtective(eventMask)) {
    ++telemetry_.runtimeProtectiveEventPolls;
  }
  telemetry_.lastEventMask = eventMask;
  telemetry_.lastEventAtMs = nowMs;
  telemetry_.lastContext = context;

  telemetry_.vbusRemoveEvents += (eventMask & kPmicIrqVbusRemove) != 0;
  telemetry_.batteryRemoveEvents += (eventMask & kPmicIrqBatteryRemove) != 0;
  telemetry_.warningLevel1Events += (eventMask & kPmicIrqWarningLevel1) != 0;
  telemetry_.warningLevel2Events += (eventMask & kPmicIrqWarningLevel2) != 0;
  telemetry_.batteryTemperatureEvents +=
      (eventMask & (kPmicIrqBatteryUnderTemperature | kPmicIrqBatteryOverTemperature)) != 0;
  telemetry_.chargeTemperatureEvents +=
      (eventMask & (kPmicIrqChargeUnderTemperature | kPmicIrqChargeOverTemperature)) != 0;
  telemetry_.gaugeWatchdogEvents += (eventMask & kPmicIrqGaugeWatchdog) != 0;
  telemetry_.batteryOverVoltageEvents += (eventMask & kPmicIrqBatteryOverVoltage) != 0;
  telemetry_.chargerTimerEvents += (eventMask & kPmicIrqChargerTimer) != 0;
  telemetry_.dieOverTemperatureEvents += (eventMask & kPmicIrqDieOverTemperature) != 0;
  telemetry_.batfetOverCurrentEvents += (eventMask & kPmicIrqBatfetOverCurrent) != 0;
  telemetry_.ldoOverCurrentEvents += (eventMask & kPmicIrqLdoOverCurrent) != 0;
  telemetry_.watchdogExpireEvents += (eventMask & kPmicIrqWatchdogExpire) != 0;
  telemetry_.powerKeyLongPressEvents += (eventMask & kPmicIrqPowerKeyLongPress) != 0;
  return true;
}

}  // namespace stackchan
