#include "io/ConversationReplyWindow.hpp"

namespace stackchan {
namespace {
constexpr uint32_t kMaxOpenDelayMs = 2000;
constexpr uint32_t kMinWindowMs = 1000;
constexpr uint32_t kMaxWindowMs = 30000;
}

bool ConversationReplyWindow::schedule(const ConversationReplyWindowRequest& request,
                                       uint32_t nowMs) {
  ++telemetry_.requests;
  if (telemetry_.pending || request.seq == 0 || request.openAfterMs > kMaxOpenDelayMs ||
      request.windowMs < kMinWindowMs || request.windowMs > kMaxWindowMs) {
    ++telemetry_.rejected;
    return false;
  }
  telemetry_.pending = true;
  telemetry_.seq = request.seq;
  telemetry_.opensAtMs = nowMs + request.openAfterMs;
  telemetry_.expiresAtMs = telemetry_.opensAtMs + request.windowMs;
  return true;
}

bool ConversationReplyWindow::due(uint32_t nowMs) const {
  return telemetry_.pending && static_cast<int32_t>(nowMs - telemetry_.opensAtMs) >= 0 &&
         !expired(nowMs);
}

bool ConversationReplyWindow::expired(uint32_t nowMs) const {
  return telemetry_.pending && static_cast<int32_t>(nowMs - telemetry_.expiresAtMs) >= 0;
}

bool ConversationReplyWindow::markStarted(uint32_t nowMs) {
  if (!due(nowMs)) {
    return false;
  }
  ++telemetry_.started;
  clearPending();
  return true;
}

bool ConversationReplyWindow::markExpired(uint32_t nowMs) {
  if (!expired(nowMs)) {
    return false;
  }
  ++telemetry_.expired;
  clearPending();
  return true;
}

void ConversationReplyWindow::cancel(uint32_t nowMs) {
  (void)nowMs;
  if (telemetry_.pending) {
    ++telemetry_.cancelled;
  }
  clearPending();
}

void ConversationReplyWindow::clearPending() {
  telemetry_.pending = false;
  telemetry_.seq = 0;
  telemetry_.opensAtMs = 0;
  telemetry_.expiresAtMs = 0;
}

}  // namespace stackchan
