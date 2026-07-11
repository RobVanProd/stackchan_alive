#pragma once

#include <stddef.h>
#include <stdint.h>

#include "io/OtaPolicy.hpp"

#ifndef STACKCHAN_ENABLE_LAN_OTA
#define STACKCHAN_ENABLE_LAN_OTA 0
#endif

#if defined(ARDUINO_ARCH_ESP32) && STACKCHAN_ENABLE_LAN_OTA
#include <Preferences.h>
#include <WiFiClient.h>
#include <WiFiServer.h>
#include <SHA2Builder.h>
#endif

namespace stackchan {

enum class OtaPersistentPhase : uint8_t {
  None = 0,
  Staged,
  Testing,
  Confirmed,
  RollbackRequested,
  RolledBack,
  Failed,
};

const char* otaPersistentPhaseName(OtaPersistentPhase phase);

struct LanOtaConfig {
  const char* tokenSha256 = "";
  uint32_t requestTimeoutMs = 10000;
  uint32_t healthStableWindowMs = 30000;
  uint32_t healthTimeoutMs = 120000;
  size_t bytesPerPoll = 16384;
  OtaPreflightLimits preflightLimits;
};

struct LanOtaTelemetry {
  bool ready = false;
  bool enabled = false;
  bool tokenConfigured = false;
  bool serverStarted = false;
  bool uploadActive = false;
  bool rebootPending = false;
  bool healthPending = false;
  bool currentAppConfirmed = true;
  bool bootloaderRollbackEnabled = false;
  bool softwareRollbackOnly = true;
  bool persistentRecordPresent = false;
  bool persistentRecordMissingForPendingApp = false;
  OtaPersistentPhase persistentPhase = OtaPersistentPhase::None;
  OtaPreflightResult lastPreflight = OtaPreflightResult::Ready;
  uint32_t connections = 0;
  uint32_t statusRequests = 0;
  uint32_t uploadRequests = 0;
  uint32_t authorizedUploads = 0;
  uint32_t authFailures = 0;
  uint32_t headerFailures = 0;
  uint32_t preflightFailures = 0;
  uint32_t uploadsStarted = 0;
  uint32_t uploadsCompleted = 0;
  uint32_t uploadsAborted = 0;
  uint32_t bytesReceived = 0;
  uint32_t sha256Failures = 0;
  uint32_t updateFailures = 0;
  uint32_t stateWriteFailures = 0;
  uint32_t healthConfirmations = 0;
  uint32_t rollbackRequests = 0;
  uint32_t rollbackFailures = 0;
  uint32_t lastActivityMs = 0;
  uint32_t healthStartedAtMs = 0;
  uint32_t healthySinceMs = 0;
  char runningPartition[17] = {};
  char previousPartition[17] = {};
  char targetPartition[17] = {};
  char expectedSha256[65] = {};
  char lastError[48] = {};
};

using OtaPreflightProvider = OtaPreflightInput (*)(void* context);

#if defined(ARDUINO_ARCH_ESP32) && STACKCHAN_ENABLE_LAN_OTA
class LanOtaServer {
 public:
  explicit LanOtaServer(uint16_t port = 8790);

  bool begin(const LanOtaConfig& config,
             OtaPreflightProvider preflightProvider,
             void* preflightContext,
             uint32_t nowMs);
  void poll(bool networkReady, uint32_t nowMs);
  void updateHealth(const OtaHealthInput& input, uint32_t nowMs);

  const LanOtaTelemetry& telemetry() const {
    return telemetry_;
  }

 private:
  enum class RequestState : uint8_t {
    Idle = 0,
    Headers,
    Body,
  };

  struct PersistentRecord {
    OtaPersistentPhase phase = OtaPersistentPhase::None;
    uint32_t imageSize = 0;
    char previousPartition[17] = {};
    char targetPartition[17] = {};
    char expectedSha256[65] = {};
  };

  static constexpr size_t kHeaderCapacity = 2048;
  static constexpr size_t kIoBufferSize = 4096;

  void acceptClient(uint32_t nowMs);
  void readHeaders(uint32_t nowMs);
  bool parseHeadersAndBeginBody(uint32_t nowMs);
  void readBody(uint32_t nowMs);
  void finishUpload(uint32_t nowMs);
  void abortUpload(const char* reason, int httpStatus, uint32_t nowMs);
  void closeClient();
  void sendJson(int statusCode, const char* statusText, const char* body);
  void sendStatus();
  bool authorizeToken(const char* token) const;
  bool validateInactivePartition(size_t contentLength);
  bool loadPersistentRecord();
  bool savePersistentRecord();
  void reconcileBootState(uint32_t nowMs);
  void copyRecordToTelemetry();
  void setError(const char* error);
  void scheduleReboot(uint32_t nowMs);
  bool requestSoftwareRollback(uint32_t nowMs);

  WiFiServer server_;
  WiFiClient client_;
  Preferences preferences_;
  LanOtaConfig config_;
  OtaPreflightProvider preflightProvider_ = nullptr;
  void* preflightContext_ = nullptr;
  RequestState requestState_ = RequestState::Idle;
  LanOtaTelemetry telemetry_;
  PersistentRecord record_;
  OtaHealthPolicy healthPolicy_;
  SHA256Builder uploadSha256_;
  uint8_t configuredTokenHash_[32] = {};
  uint8_t expectedImageHash_[32] = {};
  uint8_t ioBuffer_[kIoBufferSize] = {};
  char header_[kHeaderCapacity] = {};
  size_t headerLength_ = 0;
  size_t contentLength_ = 0;
  size_t bodyReceived_ = 0;
  uint32_t requestLastActivityMs_ = 0;
  uint32_t rebootAtMs_ = 0;
  bool preferencesReady_ = false;
  bool updateBegun_ = false;
  bool runningAppPendingVerify_ = false;
  const void* updatePartition_ = nullptr;
};
#else
class LanOtaServer {
 public:
  explicit LanOtaServer(uint16_t = 8790) {}

  bool begin(const LanOtaConfig&,
             OtaPreflightProvider,
             void*,
             uint32_t) {
    telemetry_ = LanOtaTelemetry {};
    return false;
  }

  void poll(bool, uint32_t) {}
  void updateHealth(const OtaHealthInput&, uint32_t) {}

  const LanOtaTelemetry& telemetry() const {
    return telemetry_;
  }

 private:
  LanOtaTelemetry telemetry_;
};
#endif

}  // namespace stackchan
