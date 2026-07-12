#pragma once

#include <stdint.h>

namespace stackchan {

struct ConversationReplyWindowRequest {
  uint32_t seq = 0;
  uint32_t openAfterMs = 0;
  uint32_t windowMs = 0;
};

struct ConversationReplyWindowTelemetry {
  bool pending = false;
  uint32_t requests = 0;
  uint32_t rejected = 0;
  uint32_t started = 0;
  uint32_t expired = 0;
  uint32_t cancelled = 0;
  uint32_t seq = 0;
  uint32_t opensAtMs = 0;
  uint32_t expiresAtMs = 0;
};

class ConversationReplyWindow {
 public:
  bool schedule(const ConversationReplyWindowRequest& request, uint32_t nowMs);
  bool due(uint32_t nowMs) const;
  bool expired(uint32_t nowMs) const;
  bool markStarted(uint32_t nowMs);
  bool markExpired(uint32_t nowMs);
  void cancel(uint32_t nowMs);

  const ConversationReplyWindowTelemetry& telemetry() const { return telemetry_; }

 private:
  void clearPending();

  ConversationReplyWindowTelemetry telemetry_;
};

}  // namespace stackchan
