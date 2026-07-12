#include "power/PowerCoordinator.hpp"

#include <string.h>

namespace stackchan {

const char* powerOperatingModeName(PowerOperatingMode mode) {
  switch (mode) {
    case PowerOperatingMode::Boot:
      return "boot";
    case PowerOperatingMode::Idle:
      return "idle";
    case PowerOperatingMode::AudioPriority:
      return "audio_priority";
    case PowerOperatingMode::Motion:
      return "motion";
    case PowerOperatingMode::Protected:
      return "protected";
  }
  return "unknown";
}

bool shouldPreemptMotionForAudio(const MotionAudioActivity& activity) {
  return activity.downlinkActive || activity.downlinkPlaybackActive ||
         activity.bridgeAudioStreamActive || activity.audioOutputPlaybackActive ||
         activity.speakerPowerActive || activity.speakerRunning;
}

void MotionAudioPreemptionGate::reset() {
  audioLoadActive_ = false;
  preemptActive_ = false;
  cooldownTailActive_ = false;
  hasRecentAudioLoad_ = false;
  lastAudioLoadMs_ = 0;
  microphoneCooldownClears_ = 0;
}

bool MotionAudioPreemptionGate::update(const MotionAudioActivity& activity,
                                       uint32_t nowMs,
                                       uint32_t cooldownMs) {
  audioLoadActive_ = shouldPreemptMotionForAudio(activity);
  if (audioLoadActive_) {
    hasRecentAudioLoad_ = true;
    lastAudioLoadMs_ = nowMs;
    cooldownTailActive_ = false;
    preemptActive_ = true;
    return true;
  }

  // The wake cue completes before microphone capture starts. Listening is a
  // safe boundary at which a stale cue tail must no longer hold the servos off.
  if (activity.microphoneCaptureActive) {
    if (hasRecentAudioLoad_) {
      ++microphoneCooldownClears_;
    }
    hasRecentAudioLoad_ = false;
    cooldownTailActive_ = false;
    preemptActive_ = false;
    return false;
  }

  cooldownTailActive_ = hasRecentAudioLoad_ && cooldownMs > 0 &&
                        nowMs - lastAudioLoadMs_ < cooldownMs;
  if (!cooldownTailActive_) {
    hasRecentAudioLoad_ = false;
  }
  preemptActive_ = cooldownTailActive_;
  return preemptActive_;
}

void PowerFloorTracker::begin(uint16_t hardFloorMv) {
  telemetry_ = {};
  telemetry_.hardFloorMv = hardFloorMv;
  telemetry_.minVbusMv = -1;
  telemetry_.lastHardFloorVbusMv = -1;
  telemetry_.lastHardFloorConfirmVbusMv = -1;
  telemetry_.lastHardFloorBatteryMv = -1;
  telemetry_.lastHardFloorConfirmBatteryMv = -1;
}

bool PowerFloorTracker::update(const PowerFloorSample& sample, uint32_t nowMs) {
  if (!sample.vbusValid || sample.vbusMv < 0) {
    telemetry_.consecutiveHardFloorSamples = 0;
    return false;
  }

  ++telemetry_.validSamples;
  if (telemetry_.minVbusMv < 0 || sample.vbusMv < telemetry_.minVbusMv) {
    telemetry_.minVbusMv = sample.vbusMv;
  }
  if (telemetry_.hardFloorMv == 0 || sample.vbusMv >= telemetry_.hardFloorMv) {
    telemetry_.consecutiveHardFloorSamples = 0;
    return false;
  }

  const bool entered = telemetry_.consecutiveHardFloorSamples == 0;
  if (entered) {
    ++telemetry_.hardFloorEntries;
  }
  ++telemetry_.hardFloorSamples;
  ++telemetry_.consecutiveHardFloorSamples;
  if (telemetry_.consecutiveHardFloorSamples > telemetry_.maxConsecutiveHardFloorSamples) {
    telemetry_.maxConsecutiveHardFloorSamples = telemetry_.consecutiveHardFloorSamples;
  }
  if (sample.confirmVbusValid && sample.confirmVbusMv >= 0 &&
      sample.confirmVbusMv < telemetry_.hardFloorMv) {
    ++telemetry_.hardFloorConfirmedSamples;
  } else {
    ++telemetry_.hardFloorUnconfirmedSamples;
  }

  telemetry_.lastHardFloorAtMs = nowMs;
  telemetry_.lastHardFloorVbusMv = sample.vbusMv;
  telemetry_.lastHardFloorConfirmVbusMv =
      sample.confirmVbusValid ? sample.confirmVbusMv : -1;
  telemetry_.lastHardFloorBatteryMv = sample.batteryValid ? sample.batteryMv : -1;
  telemetry_.lastHardFloorConfirmBatteryMv =
      sample.confirmBatteryValid ? sample.confirmBatteryMv : -1;
  telemetry_.lastHardFloorBodyPowerValid = sample.bodyPowerValid;
  telemetry_.lastHardFloorBodyBusV = sample.bodyBusV;
  telemetry_.lastHardFloorBodyCurrentMa = sample.bodyCurrentMa;
  telemetry_.lastHardFloorMotionRequested = sample.motionRequested;
  telemetry_.lastHardFloorServoRailEnabled = sample.servoRailEnabled;
  telemetry_.lastHardFloorServoTorqueEnabled = sample.servoTorqueEnabled;
  telemetry_.lastHardFloorSpeakerPowerActive = sample.speakerPowerActive;
  return entered;
}

void PowerCoordinator::begin(bool baseInputMode,
                             uint16_t maxChargeCurrentMa,
                             uint32_t nowMs,
                             uint16_t deratedChargeCurrentMa,
                             uint32_t chargeDerateHoldMs) {
  begun_ = true;
  baseInputMode_ = baseInputMode;
  maxChargeCurrentMa_ = maxChargeCurrentMa;
  deratedChargeCurrentMa_ = deratedChargeCurrentMa < maxChargeCurrentMa
                                ? deratedChargeCurrentMa
                                : maxChargeCurrentMa;
  chargeDerateHoldMs_ = chargeDerateHoldMs;
  chargeDerateLastLoadMs_ = nowMs;
  chargeDerateHoldActive_ = false;
  transitions_ = 0;
  chargeDerateEntries_ = 0;
  motionGrantEntries_ = 0;
  motionBlockEntries_ = 0;
  lastTransitionMs_ = nowMs;
  decision_ = {};
  decision_.mode = PowerOperatingMode::Idle;
  decision_.wifiSleepAllowed = true;
  decision_.chargeCurrentMa = maxChargeCurrentMa_;
  decision_.reason = "idle";
}

PowerCoordinatorDecision PowerCoordinator::update(const PowerCoordinatorInput& input, uint32_t nowMs) {
  if (!begun_) {
    begin(false, 0, nowMs);
  }

  const bool managedLoadActive = input.motionRequested || input.audioBusy;
  if (managedLoadActive) {
    chargeDerateLastLoadMs_ = nowMs;
    chargeDerateHoldActive_ = chargeDerateHoldMs_ > 0;
  } else if (chargeDerateHoldActive_ && nowMs - chargeDerateLastLoadMs_ >= chargeDerateHoldMs_) {
    chargeDerateHoldActive_ = false;
  }

  PowerCoordinatorDecision next;
  next.chargeDerateHoldActive = chargeDerateHoldActive_;
  if (chargeDerateHoldActive_) {
    const uint32_t elapsedMs = nowMs - chargeDerateLastLoadMs_;
    next.chargeDerateHoldRemainingMs = elapsedMs < chargeDerateHoldMs_
                                           ? chargeDerateHoldMs_ - elapsedMs
                                           : 0;
  }
  const bool chargeDerateRequested = input.thermalBlocked || input.supplyBlocked ||
                                     managedLoadActive || chargeDerateHoldActive_;
  next.chargeDerated = baseInputMode_ && chargeDerateRequested && deratedChargeCurrentMa_ > 0 &&
                       deratedChargeCurrentMa_ < maxChargeCurrentMa_;
  next.chargeCurrentMa = next.chargeDerated ? deratedChargeCurrentMa_ : maxChargeCurrentMa_;
  if (next.chargeDerated) {
    if (input.thermalBlocked) {
      next.chargeDerateReason = "thermal_protection";
    } else if (input.supplyBlocked) {
      next.chargeDerateReason = "supply_protection";
    } else if (input.audioBusy) {
      next.chargeDerateReason = "audio_active";
    } else if (input.motionRequested) {
      next.chargeDerateReason = "motion_session";
    } else {
      next.chargeDerateReason = "post_load_hold";
    }
  }
  if (input.thermalBlocked) {
    next.mode = PowerOperatingMode::Protected;
    next.reason = "thermal_load_shed";
  } else if (input.supplyBlocked) {
    next.mode = PowerOperatingMode::Protected;
    next.reason = "power_load_shed";
  } else if (input.audioBusy) {
    next.mode = PowerOperatingMode::AudioPriority;
    next.reason = "audio_priority";
  } else if (input.motionRequested) {
    next.mode = PowerOperatingMode::Motion;
    next.motionAllowed = true;
    next.servoRailAllowed = true;
    next.reason = "motion_granted";
  } else {
    next.mode = PowerOperatingMode::Idle;
    next.wifiSleepAllowed = true;
    next.reason = "idle";
  }

  applyDecision(next, input.motionRequested, nowMs);
  return decision_;
}

void PowerCoordinator::applyDecision(const PowerCoordinatorDecision& next,
                                     bool motionRequested,
                                     uint32_t nowMs) {
  const bool reasonChanged = next.reason == nullptr || decision_.reason == nullptr
                                 ? next.reason != decision_.reason
                                 : strcmp(next.reason, decision_.reason) != 0;
  const bool chargeDerateReasonChanged =
      next.chargeDerateReason == nullptr || decision_.chargeDerateReason == nullptr
          ? next.chargeDerateReason != decision_.chargeDerateReason
          : strcmp(next.chargeDerateReason, decision_.chargeDerateReason) != 0;
  const bool changed = next.mode != decision_.mode || next.motionAllowed != decision_.motionAllowed ||
                       next.servoRailAllowed != decision_.servoRailAllowed ||
                       next.wifiSleepAllowed != decision_.wifiSleepAllowed ||
                       next.chargeCurrentMa != decision_.chargeCurrentMa ||
                       next.chargeDerated != decision_.chargeDerated ||
                       next.chargeDerateHoldActive != decision_.chargeDerateHoldActive ||
                       chargeDerateReasonChanged || reasonChanged;
  const bool wasAllowed = decision_.motionAllowed;
  const bool wasChargeDerated = decision_.chargeDerated;
  const bool wasBlocked = motionRequested_ && !decision_.motionAllowed;
  const bool isBlocked = motionRequested && !next.motionAllowed;

  if (changed) {
    ++transitions_;
    lastTransitionMs_ = nowMs;
  }
  if (!wasAllowed && next.motionAllowed) {
    ++motionGrantEntries_;
  }
  if (!wasChargeDerated && next.chargeDerated) {
    ++chargeDerateEntries_;
  }
  if (!wasBlocked && isBlocked) {
    ++motionBlockEntries_;
  }

  motionRequested_ = motionRequested;
  decision_ = next;
}

PowerCoordinatorTelemetry PowerCoordinator::telemetry() const {
  PowerCoordinatorTelemetry telemetry;
  telemetry.mode = decision_.mode;
  telemetry.baseInputMode = baseInputMode_;
  telemetry.chargeCurrentMa = decision_.chargeCurrentMa;
  telemetry.maxChargeCurrentMa = maxChargeCurrentMa_;
  telemetry.deratedChargeCurrentMa = deratedChargeCurrentMa_;
  telemetry.chargeDerated = decision_.chargeDerated;
  telemetry.chargeDerateHoldActive = decision_.chargeDerateHoldActive;
  telemetry.chargeDerateHoldMs = chargeDerateHoldMs_;
  telemetry.chargeDerateHoldRemainingMs = decision_.chargeDerateHoldRemainingMs;
  telemetry.chargeDerateLastLoadMs = chargeDerateLastLoadMs_;
  telemetry.chargeDerateReason = decision_.chargeDerateReason;
  telemetry.motionRequested = motionRequested_;
  telemetry.motionAllowed = decision_.motionAllowed;
  telemetry.servoRailAllowed = decision_.servoRailAllowed;
  telemetry.wifiSleepAllowed = decision_.wifiSleepAllowed;
  telemetry.transitions = transitions_;
  telemetry.chargeDerateEntries = chargeDerateEntries_;
  telemetry.motionGrantEntries = motionGrantEntries_;
  telemetry.motionBlockEntries = motionBlockEntries_;
  telemetry.lastTransitionMs = lastTransitionMs_;
  telemetry.reason = decision_.reason;
  return telemetry;
}

}  // namespace stackchan
