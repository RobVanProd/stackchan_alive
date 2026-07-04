#include "io/BridgeEndpointRegistry.hpp"

#include <cstring>

namespace stackchan {

bool BridgeEndpointRegistry::begin(const BridgeEndpointRegistryConfig& config) {
  config_ = config;
  telemetry_ = BridgeEndpointRegistryTelemetry {};
  count_ = 0;
  activeOwnerIndex_ = -1;
  for (size_t i = 0; i < kBridgeEndpointMax; ++i) {
    endpoints_[i] = BridgeEndpointRecord {};
  }
  telemetry_.ready = config_.ownerHeartbeatTimeoutMs > 0;
  refreshTelemetry();
  return telemetry_.ready;
}

bool BridgeEndpointRegistry::upsertEndpoint(const BridgeEndpointRecord& endpoint, uint32_t nowMs) {
  if (!telemetry_.ready || !isValidId(endpoint.endpointId)) {
    telemetry_.rejected++;
    return false;
  }

  int index = findIndex(endpoint.endpointId);
  if (index < 0) {
    if (count_ >= kBridgeEndpointMax) {
      telemetry_.rejected++;
      return false;
    }
    index = static_cast<int>(count_);
    count_++;
  }

  BridgeEndpointRecord& target = endpoints_[index];
  copyBounded(target.endpointId, sizeof(target.endpointId), endpoint.endpointId);
  copyBounded(target.endpointName, sizeof(target.endpointName), endpoint.endpointName);
  copyBounded(target.publicKeyFingerprint,
              sizeof(target.publicKeyFingerprint),
              endpoint.publicKeyFingerprint);
  target.kind = endpoint.kind;
  target.priority = endpoint.priority;
  target.trusted = true;
  target.autoConnect = endpoint.autoConnect;
  target.capabilities = endpoint.capabilities;
  target.lastSeenMs = nowMs;
  target.lastHeartbeatMs = nowMs;
  telemetry_.upserts++;
  telemetry_.lastChangeMs = nowMs;
  refreshTelemetry();
  return true;
}

bool BridgeEndpointRegistry::forgetEndpoint(const char* endpointId, uint32_t nowMs) {
  if (!telemetry_.ready || !isValidId(endpointId)) {
    telemetry_.rejected++;
    return false;
  }

  const int index = findIndex(endpointId);
  if (index < 0) {
    telemetry_.rejected++;
    return false;
  }

  if (activeOwnerIndex_ == index) {
    releaseOwnerIndex(nowMs);
  } else if (activeOwnerIndex_ > index) {
    activeOwnerIndex_--;
  }

  for (size_t i = static_cast<size_t>(index); i + 1u < count_; ++i) {
    endpoints_[i] = endpoints_[i + 1u];
  }
  endpoints_[count_ - 1u] = BridgeEndpointRecord {};
  count_--;
  telemetry_.forgotten++;
  telemetry_.lastChangeMs = nowMs;
  update(nowMs);
  refreshTelemetry();
  return true;
}

bool BridgeEndpointRegistry::markHeartbeat(const char* endpointId, uint32_t nowMs) {
  const int index = findIndex(endpointId);
  if (!telemetry_.ready || index < 0 || !endpoints_[index].trusted) {
    telemetry_.rejected++;
    return false;
  }
  endpoints_[index].lastSeenMs = nowMs;
  endpoints_[index].lastHeartbeatMs = nowMs;
  telemetry_.heartbeats++;
  telemetry_.lastChangeMs = nowMs;
  refreshTelemetry();
  return true;
}

bool BridgeEndpointRegistry::markDisconnected(const char* endpointId, uint32_t nowMs) {
  const int index = findIndex(endpointId);
  if (!telemetry_.ready || index < 0 || !endpoints_[index].trusted) {
    telemetry_.rejected++;
    return false;
  }
  endpoints_[index].lastHeartbeatMs = 0;
  endpoints_[index].lastSeenMs = nowMs;
  if (activeOwnerIndex_ == index) {
    releaseOwnerIndex(nowMs);
    update(nowMs);
  }
  telemetry_.lastChangeMs = nowMs;
  refreshTelemetry();
  return true;
}

bool BridgeEndpointRegistry::claimOwner(const char* endpointId, uint32_t nowMs, bool explicitSelection) {
  const int index = findIndex(endpointId);
  if (!telemetry_.ready || index < 0 || !endpoints_[index].trusted) {
    telemetry_.rejected++;
    return false;
  }
  endpoints_[index].lastSeenMs = nowMs;
  endpoints_[index].lastHeartbeatMs = nowMs;
  if (explicitSelection) {
    telemetry_.explicitClaims++;
  } else if (activeOwnerIndex_ >= 0 && isHealthy(endpoints_[activeOwnerIndex_], nowMs) &&
             activeOwnerIndex_ != index) {
    refreshTelemetry();
    return false;
  }
  setOwnerIndex(index, nowMs);
  return true;
}

bool BridgeEndpointRegistry::releaseOwner(const char* endpointId, uint32_t nowMs) {
  if (!telemetry_.ready || !isValidId(endpointId)) {
    telemetry_.rejected++;
    return false;
  }
  if (activeOwnerIndex_ < 0 || !idsEqual(endpoints_[activeOwnerIndex_].endpointId, endpointId)) {
    telemetry_.rejected++;
    return false;
  }
  endpoints_[activeOwnerIndex_].lastSeenMs = nowMs;
  endpoints_[activeOwnerIndex_].lastHeartbeatMs = 0;
  releaseOwnerIndex(nowMs);
  update(nowMs);
  refreshTelemetry();
  return true;
}

bool BridgeEndpointRegistry::updateCapabilities(const char* endpointId,
                                                uint32_t capabilities,
                                                uint32_t nowMs) {
  const int index = findIndex(endpointId);
  if (!telemetry_.ready || index < 0 || !endpoints_[index].trusted) {
    telemetry_.rejected++;
    return false;
  }
  endpoints_[index].capabilities = capabilities;
  endpoints_[index].lastSeenMs = nowMs;
  telemetry_.lastChangeMs = nowMs;
  refreshTelemetry();
  return true;
}

void BridgeEndpointRegistry::update(uint32_t nowMs) {
  if (!telemetry_.ready) {
    return;
  }

  if (activeOwnerIndex_ >= 0 && isHealthy(endpoints_[activeOwnerIndex_], nowMs)) {
    refreshTelemetry();
    return;
  }

  if (activeOwnerIndex_ >= 0) {
    telemetry_.ownerExpirations++;
    releaseOwnerIndex(nowMs);
  }

  const int nextOwner = chooseBestHealthyOwner(nowMs);
  if (nextOwner >= 0) {
    setOwnerIndex(nextOwner, nowMs);
  } else {
    refreshTelemetry();
  }
}

const BridgeEndpointRecord* BridgeEndpointRegistry::endpointAt(size_t index) const {
  if (index >= count_) {
    return nullptr;
  }
  return &endpoints_[index];
}

const BridgeEndpointRecord* BridgeEndpointRegistry::findEndpoint(const char* endpointId) const {
  const int index = findIndex(endpointId);
  if (index < 0) {
    return nullptr;
  }
  return &endpoints_[index];
}

const BridgeEndpointRecord* BridgeEndpointRegistry::activeOwner() const {
  if (activeOwnerIndex_ < 0) {
    return nullptr;
  }
  return &endpoints_[activeOwnerIndex_];
}

bool BridgeEndpointRegistry::isActiveOwner(const char* endpointId) const {
  return activeOwnerIndex_ >= 0 && idsEqual(endpoints_[activeOwnerIndex_].endpointId, endpointId);
}

bool BridgeEndpointRegistry::isTrusted(const char* endpointId) const {
  const BridgeEndpointRecord* endpoint = findEndpoint(endpointId);
  return endpoint != nullptr && endpoint->trusted;
}

bool BridgeEndpointRegistry::isValidId(const char* endpointId) {
  return endpointId != nullptr && endpointId[0] != '\0';
}

bool BridgeEndpointRegistry::idsEqual(const char* left, const char* right) {
  return left != nullptr && right != nullptr && std::strncmp(left, right, kBridgeEndpointIdMax) == 0;
}

void BridgeEndpointRegistry::copyBounded(char* out, size_t outSize, const char* value) {
  if (out == nullptr || outSize == 0) {
    return;
  }
  if (value == nullptr) {
    out[0] = '\0';
    return;
  }
  const size_t sourceLen = std::strlen(value);
  const size_t copyLen = sourceLen < (outSize - 1u) ? sourceLen : (outSize - 1u);
  std::memcpy(out, value, copyLen);
  out[copyLen] = '\0';
}

bool BridgeEndpointRegistry::isHealthy(const BridgeEndpointRecord& endpoint, uint32_t nowMs) const {
  if (!endpoint.trusted || endpoint.lastHeartbeatMs == 0) {
    return false;
  }
  return nowMs - endpoint.lastHeartbeatMs <= config_.ownerHeartbeatTimeoutMs;
}

int BridgeEndpointRegistry::findIndex(const char* endpointId) const {
  if (!isValidId(endpointId)) {
    return -1;
  }
  for (size_t i = 0; i < count_; ++i) {
    if (idsEqual(endpoints_[i].endpointId, endpointId)) {
      return static_cast<int>(i);
    }
  }
  return -1;
}

int BridgeEndpointRegistry::chooseBestHealthyOwner(uint32_t nowMs) const {
  int best = -1;
  for (size_t i = 0; i < count_; ++i) {
    const BridgeEndpointRecord& candidate = endpoints_[i];
    if (!candidate.autoConnect || !isHealthy(candidate, nowMs)) {
      continue;
    }
    if (best < 0) {
      best = static_cast<int>(i);
      continue;
    }
    const BridgeEndpointRecord& current = endpoints_[best];
    if (candidate.priority > current.priority ||
        (candidate.priority == current.priority && candidate.lastSeenMs > current.lastSeenMs)) {
      best = static_cast<int>(i);
    }
  }
  return best;
}

void BridgeEndpointRegistry::setOwnerIndex(int index, uint32_t nowMs) {
  if (index < 0 || static_cast<size_t>(index) >= count_) {
    releaseOwnerIndex(nowMs);
    return;
  }
  if (activeOwnerIndex_ != index) {
    activeOwnerIndex_ = index;
    telemetry_.ownerChanges++;
  }
  telemetry_.lastChangeMs = nowMs;
  refreshTelemetry();
}

void BridgeEndpointRegistry::releaseOwnerIndex(uint32_t nowMs) {
  if (activeOwnerIndex_ >= 0) {
    activeOwnerIndex_ = -1;
    telemetry_.releases++;
    telemetry_.ownerChanges++;
    telemetry_.lastChangeMs = nowMs;
  }
  refreshTelemetry();
}

void BridgeEndpointRegistry::refreshTelemetry() {
  telemetry_.trustedCount = static_cast<uint8_t>(count_);
  telemetry_.activeOwnerIndex = static_cast<int8_t>(activeOwnerIndex_);
}

}  // namespace stackchan
