#include "io/BridgeWakeGate.hpp"

#include <string.h>

namespace stackchan {

bool BridgeWakeGate::begin(const BridgeWakeGateConfig& config, BridgeAudioUplink* uplink) {
  config_ = config;
  uplink_ = uplink;
  telemetry_ = BridgeWakeGateTelemetry {};
  telemetry_.enabled = config_.enabled;
  telemetry_.speechStartsTurn = config_.speechStartsTurn;
  telemetry_.ready = true;
  nextSeq_ = config_.firstSeq == 0 ? 1 : config_.firstSeq;

  if (!config_.enabled) {
    copyError("bridge_wake_gate_disabled");
    return true;
  }
  if (config_.gateOpenMs == 0 || config_.maxTurnMs == 0) {
    telemetry_.ready = false;
    copyError("bridge_wake_gate_bad_config");
    return false;
  }
  if (uplink_ == nullptr) {
    telemetry_.ready = false;
    copyError("bridge_wake_gate_uplink_missing");
    return false;
  }

  telemetry_.lastError[0] = '\0';
  return true;
}

void BridgeWakeGate::reset() {
  telemetry_ = BridgeWakeGateTelemetry {};
  telemetry_.enabled = config_.enabled;
  telemetry_.speechStartsTurn = config_.speechStartsTurn;
  telemetry_.ready = config_.enabled ? uplink_ != nullptr : true;
  nextSeq_ = config_.firstSeq == 0 ? 1 : config_.firstSeq;
  if (!config_.enabled) {
    copyError("bridge_wake_gate_disabled");
  }
}

void BridgeWakeGate::applyEvent(const RobotEvent& event, uint32_t nowMs) {
  if (!telemetry_.ready || !config_.enabled) {
    return;
  }

  update(nowMs);

  switch (event.type) {
    case EventType::WakeWord:
      openGate(nowMs);
      startTurnIfPossible(nowMs);
      break;
    case EventType::UserSpeaking:
      if (!isGateOpen(nowMs) && config_.speechStartsTurn) {
        openGate(nowMs);
        startTurnIfPossible(nowMs);
      } else if (isGateOpen(nowMs)) {
        renewGate(nowMs);
      }
      break;
    case EventType::SpeechEnded:
    case EventType::ResponseStarted:
    case EventType::ResponseEnded:
      completeTurn(nowMs, "bridge_wake_gate_event_end");
      expireGate(nowMs);
      break;
    case EventType::Error:
      abortTurn(nowMs, "bridge_wake_gate_event_error");
      expireGate(nowMs);
      break;
    default:
      break;
  }
}

void BridgeWakeGate::update(uint32_t nowMs) {
  if (!telemetry_.ready || !config_.enabled) {
    return;
  }
  serviceTerminal(nowMs);
  if (telemetry_.turnActive && uplink_ != nullptr &&
      !uplink_->telemetry().active && !uplink_->telemetry().terminalPending &&
      uplink_->telemetry().lastTerminal != BridgeAudioTerminalKind::None) {
    settleTerminal(BridgeAudioTerminalServiceResult::Queued);
  }
  if (telemetry_.gateOpen && nowMs >= telemetry_.closeAtMs) {
    abortTurn(nowMs, "bridge_wake_gate_timeout");
    expireGate(nowMs);
  }
  if (telemetry_.turnActive &&
      nowMs - telemetry_.turnStartedAtMs >= config_.maxTurnMs) {
    abortTurn(nowMs, "bridge_wake_gate_max_turn");
    expireGate(nowMs);
  }
}

void BridgeWakeGate::cancelActiveTurn(uint32_t nowMs, const char* reason) {
  if (!telemetry_.ready || !config_.enabled) {
    return;
  }
  abortTurn(nowMs, reason != nullptr ? reason : "bridge_wake_gate_cancelled");
  expireGate(nowMs);
}

bool BridgeWakeGate::isGateOpen(uint32_t nowMs) const {
  return telemetry_.ready && config_.enabled && telemetry_.gateOpen &&
         nowMs < telemetry_.closeAtMs;
}

void BridgeWakeGate::openGate(uint32_t nowMs) {
  telemetry_.gateOpen = true;
  telemetry_.gatesOpened++;
  telemetry_.openedAtMs = nowMs;
  telemetry_.closeAtMs = nowMs + config_.gateOpenMs;
  telemetry_.lastError[0] = '\0';
}

void BridgeWakeGate::renewGate(uint32_t nowMs) {
  telemetry_.closeAtMs = nowMs + config_.gateOpenMs;
}

void BridgeWakeGate::expireGate(uint32_t nowMs) {
  if (!telemetry_.gateOpen) {
    return;
  }
  telemetry_.gateOpen = false;
  telemetry_.gatesExpired++;
  telemetry_.closeAtMs = nowMs;
}

void BridgeWakeGate::startTurnIfPossible(uint32_t nowMs) {
  if (telemetry_.turnActive || uplink_ == nullptr) {
    return;
  }
  if (!uplinkReadyForTurn()) {
    telemetry_.suppressedStarts++;
    copyError("bridge_wake_gate_uplink_unavailable");
    return;
  }

  const uint32_t seq = nextSeq_++;
  if (!uplink_->beginTurn(seq, nowMs, isGateOpen(nowMs))) {
    telemetry_.beginFailures++;
    copyError(uplink_->telemetry().lastError);
    return;
  }

  telemetry_.turnActive = true;
  telemetry_.turnsStarted++;
  telemetry_.lastSeq = seq;
  telemetry_.turnStartedAtMs = nowMs;
  telemetry_.lastError[0] = '\0';
}

void BridgeWakeGate::completeTurn(uint32_t nowMs, const char* reason) {
  (void)reason;
  if (!telemetry_.turnActive || uplink_ == nullptr) {
    return;
  }

  if (uplink_->telemetry().active) {
    if (!uplink_->endTurn(telemetry_.lastSeq, nowMs)) {
      telemetry_.endFailures++;
      copyError(uplink_->telemetry().lastError);
      return;
    }
  }

  if (uplink_->telemetry().terminalPending) {
    copyError("bridge_wake_gate_terminal_pending");
    return;
  }

  settleTerminal(BridgeAudioTerminalServiceResult::Queued);
}

void BridgeWakeGate::abortTurn(uint32_t nowMs, const char* reason) {
  if (!telemetry_.turnActive || uplink_ == nullptr) {
    return;
  }
  uplink_->abort(nowMs, reason);
  if (uplink_->telemetry().terminalPending) {
    copyError("bridge_wake_gate_terminal_pending");
    return;
  }
  settleTerminal(BridgeAudioTerminalServiceResult::Queued);
}

void BridgeWakeGate::serviceTerminal(uint32_t nowMs) {
  if (!telemetry_.turnActive || uplink_ == nullptr ||
      !uplink_->telemetry().terminalPending) {
    return;
  }
  const BridgeAudioTerminalServiceResult result = uplink_->servicePendingTerminal(nowMs);
  if (result == BridgeAudioTerminalServiceResult::Pending) {
    telemetry_.terminalRetries++;
    copyError("bridge_wake_gate_terminal_pending");
    return;
  }
  if (result == BridgeAudioTerminalServiceResult::FailedClosed) {
    telemetry_.terminalTimeouts++;
    telemetry_.endFailures++;
  }
  if (result == BridgeAudioTerminalServiceResult::Queued ||
      result == BridgeAudioTerminalServiceResult::FailedClosed) {
    settleTerminal(result);
  }
}

void BridgeWakeGate::settleTerminal(BridgeAudioTerminalServiceResult result) {
  const bool completed = result == BridgeAudioTerminalServiceResult::Queued &&
                         uplink_ != nullptr &&
                         uplink_->telemetry().lastTerminal == BridgeAudioTerminalKind::End;
  if (completed) {
    telemetry_.turnsCompleted++;
    telemetry_.lastError[0] = '\0';
  } else {
    telemetry_.turnsAborted++;
    copyError(uplink_ != nullptr ? uplink_->telemetry().lastError
                                 : "bridge_wake_gate_terminal_failed");
  }

  telemetry_.turnActive = false;
}

bool BridgeWakeGate::uplinkReadyForTurn() const {
  if (uplink_ == nullptr) {
    return false;
  }
  const BridgeAudioUplinkTelemetry& uplink = uplink_->telemetry();
  return uplink.ready && uplink.enabled && !uplink.active && !uplink.terminalPending;
}

void BridgeWakeGate::copyError(const char* reason) {
  if (reason == nullptr) {
    telemetry_.lastError[0] = '\0';
    return;
  }
  const size_t length = strlen(reason);
  const size_t copyLength = length < (sizeof(telemetry_.lastError) - 1u)
                                ? length
                                : (sizeof(telemetry_.lastError) - 1u);
  memcpy(telemetry_.lastError, reason, copyLength);
  telemetry_.lastError[copyLength] = '\0';
}

}  // namespace stackchan
