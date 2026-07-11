#include "io/LanOtaServer.hpp"

#include <cstdio>
#include <cstdlib>
#include <cstring>

#if defined(ARDUINO_ARCH_ESP32) && STACKCHAN_ENABLE_LAN_OTA
#include <Update.h>
#include <esp_ota_ops.h>
#include <esp_partition.h>
#include <esp_system.h>
#include <sdkconfig.h>
#include <strings.h>
#endif

namespace stackchan {

const char* otaPersistentPhaseName(OtaPersistentPhase phase) {
  switch (phase) {
    case OtaPersistentPhase::None:
      return "none";
    case OtaPersistentPhase::Staged:
      return "staged";
    case OtaPersistentPhase::Testing:
      return "testing";
    case OtaPersistentPhase::Confirmed:
      return "confirmed";
    case OtaPersistentPhase::RollbackRequested:
      return "rollback_requested";
    case OtaPersistentPhase::RolledBack:
      return "rolled_back";
    case OtaPersistentPhase::Failed:
      return "failed";
  }
  return "unknown";
}

#if defined(ARDUINO_ARCH_ESP32) && STACKCHAN_ENABLE_LAN_OTA
namespace {
constexpr const char* kOtaPreferencesNamespace = "stack_ota";
constexpr const char* kPhaseKey = "phase";
constexpr const char* kPreviousKey = "previous";
constexpr const char* kTargetKey = "target";
constexpr const char* kSha256Key = "sha256";
constexpr const char* kSizeKey = "size";
constexpr const char* kFirmwarePath = "/firmware";
constexpr const char* kStatusPath = "/status";

#if defined(CONFIG_BOOTLOADER_APP_ROLLBACK_ENABLE) && CONFIG_BOOTLOADER_APP_ROLLBACK_ENABLE
constexpr bool kBootloaderRollbackEnabled = true;
#else
constexpr bool kBootloaderRollbackEnabled = false;
#endif

void copyBounded(char* out, size_t outSize, const char* value) {
  if (out == nullptr || outSize == 0) {
    return;
  }
  if (value == nullptr) {
    out[0] = '\0';
    return;
  }
  const size_t length = std::strlen(value);
  const size_t copyLength = length < outSize - 1u ? length : outSize - 1u;
  std::memcpy(out, value, copyLength);
  out[copyLength] = '\0';
}

bool parseUnsignedSize(const char* value, size_t* result) {
  if (value == nullptr || result == nullptr || value[0] == '\0' || value[0] == '-') {
    return false;
  }
  char* end = nullptr;
  const unsigned long parsed = std::strtoul(value, &end, 10);
  if (end == value || *end != '\0' || parsed == 0) {
    return false;
  }
  *result = static_cast<size_t>(parsed);
  return true;
}

const char* trimHeaderValue(char* value) {
  if (value == nullptr) {
    return "";
  }
  while (*value == ' ' || *value == '\t') {
    ++value;
  }
  char* end = value + std::strlen(value);
  while (end > value && (end[-1] == ' ' || end[-1] == '\t')) {
    *--end = '\0';
  }
  return value;
}
}  // namespace

LanOtaServer::LanOtaServer(uint16_t port) : server_(port) {}

bool LanOtaServer::begin(const LanOtaConfig& config,
                         OtaPreflightProvider preflightProvider,
                         void* preflightContext,
                         uint32_t nowMs) {
  config_ = config;
  if (config_.bytesPerPoll == 0) {
    config_.bytesPerPoll = kIoBufferSize;
  }
  preflightProvider_ = preflightProvider;
  preflightContext_ = preflightContext;
  telemetry_ = LanOtaTelemetry {};
  telemetry_.bootloaderRollbackEnabled = kBootloaderRollbackEnabled;
  telemetry_.softwareRollbackOnly = !kBootloaderRollbackEnabled;
  telemetry_.tokenConfigured = decodeSha256Hex(config_.tokenSha256, configuredTokenHash_);
  preferencesReady_ = preferences_.begin(kOtaPreferencesNamespace, false);
  telemetry_.ready = preferencesReady_;
  if (preferencesReady_) {
    loadPersistentRecord();
    reconcileBootState(nowMs);
  }
  telemetry_.enabled = telemetry_.ready && telemetry_.tokenConfigured &&
                       preflightProvider_ != nullptr && validateInactivePartition(1);
  if (!telemetry_.tokenConfigured) {
    setError("token_not_configured");
  } else if (!preferencesReady_) {
    setError("state_store_unavailable");
  } else if (preflightProvider_ == nullptr) {
    setError("preflight_provider_missing");
  } else if (!telemetry_.enabled) {
    setError("inactive_ota_partition_missing");
  } else {
    setError("none");
  }
  return telemetry_.enabled;
}

void LanOtaServer::poll(bool networkReady, uint32_t nowMs) {
  if (telemetry_.rebootPending && static_cast<int32_t>(nowMs - rebootAtMs_) >= 0) {
    esp_restart();
  }
  if (!telemetry_.enabled) {
    return;
  }
  if (!networkReady) {
    if (requestState_ != RequestState::Idle) {
      abortUpload("network_lost", 503, nowMs);
    }
    if (telemetry_.serverStarted) {
      server_.end();
      telemetry_.serverStarted = false;
    }
    return;
  }
  if (!telemetry_.serverStarted) {
    server_.begin();
    telemetry_.serverStarted = true;
  }

  if (requestState_ == RequestState::Idle) {
    acceptClient(nowMs);
  }
  if (requestState_ == RequestState::Headers) {
    readHeaders(nowMs);
  } else if (requestState_ == RequestState::Body) {
    readBody(nowMs);
  }
  if (requestState_ != RequestState::Idle &&
      nowMs - requestLastActivityMs_ >= config_.requestTimeoutMs) {
    abortUpload("request_timeout", 408, nowMs);
  }
}

void LanOtaServer::updateHealth(const OtaHealthInput& input, uint32_t nowMs) {
  if (!telemetry_.healthPending) {
    return;
  }
  const OtaHealthDecision decision = healthPolicy_.update(
      input, nowMs, config_.healthStableWindowMs, config_.healthTimeoutMs);
  telemetry_.healthStartedAtMs = healthPolicy_.startedAtMs();
  telemetry_.healthySinceMs = healthPolicy_.healthySinceMs();
  if (decision == OtaHealthDecision::Waiting) {
    return;
  }
  if (decision == OtaHealthDecision::Confirm) {
    bool confirmed = true;
    if (kBootloaderRollbackEnabled && runningAppPendingVerify_) {
      confirmed = esp_ota_mark_app_valid_cancel_rollback() == ESP_OK;
    }
    if (!confirmed) {
      setError("health_confirmation_failed");
      telemetry_.rollbackFailures++;
      return;
    }
    telemetry_.healthPending = false;
    telemetry_.currentAppConfirmed = true;
    telemetry_.healthConfirmations++;
    runningAppPendingVerify_ = false;
    record_.phase = OtaPersistentPhase::Confirmed;
    const bool stateSaved = !telemetry_.persistentRecordPresent || savePersistentRecord();
    copyRecordToTelemetry();
    setError(stateSaved ? "none" : "state_write_failed");
    return;
  }

  telemetry_.rollbackRequests++;
  record_.phase = OtaPersistentPhase::RollbackRequested;
  savePersistentRecord();
  copyRecordToTelemetry();
  if (kBootloaderRollbackEnabled && runningAppPendingVerify_) {
    const esp_err_t result = esp_ota_mark_app_invalid_rollback_and_reboot();
    if (result != ESP_OK) {
      telemetry_.rollbackFailures++;
      setError("bootloader_rollback_failed");
    }
    return;
  }
  if (!requestSoftwareRollback(nowMs)) {
    telemetry_.rollbackFailures++;
    setError("software_rollback_failed");
  }
}

void LanOtaServer::acceptClient(uint32_t nowMs) {
  WiFiClient candidate = server_.accept();
  if (!candidate) {
    return;
  }
  client_ = candidate;
  client_.setTimeout(100);
  requestState_ = RequestState::Headers;
  headerLength_ = 0;
  contentLength_ = 0;
  bodyReceived_ = 0;
  requestLastActivityMs_ = nowMs;
  telemetry_.connections++;
  telemetry_.lastActivityMs = nowMs;
}

void LanOtaServer::readHeaders(uint32_t nowMs) {
  while (client_.available() > 0 && headerLength_ + 1u < sizeof(header_)) {
    const int value = client_.read();
    if (value < 0) {
      break;
    }
    header_[headerLength_++] = static_cast<char>(value);
    header_[headerLength_] = '\0';
    requestLastActivityMs_ = nowMs;
    telemetry_.lastActivityMs = nowMs;
    if (headerLength_ >= 4 &&
        std::memcmp(header_ + headerLength_ - 4, "\r\n\r\n", 4) == 0) {
      parseHeadersAndBeginBody(nowMs);
      return;
    }
  }
  if (headerLength_ + 1u >= sizeof(header_)) {
    telemetry_.headerFailures++;
    abortUpload("headers_too_large", 431, nowMs);
  } else if (!client_.connected() && client_.available() == 0) {
    abortUpload("headers_disconnected", 400, nowMs);
  }
}

bool LanOtaServer::parseHeadersAndBeginBody(uint32_t nowMs) {
  char method[8] = {};
  char path[32] = {};
  char authorization[160] = {};
  char expectedSha256[65] = {};
  char contentType[48] = {};
  char contentLengthText[24] = {};
  bool transferEncodingSeen = false;

  char* save = nullptr;
  char* line = strtok_r(header_, "\r\n", &save);
  if (line == nullptr || std::sscanf(line, "%7s %31s", method, path) != 2) {
    telemetry_.headerFailures++;
    abortUpload("request_line_invalid", 400, nowMs);
    return false;
  }
  while ((line = strtok_r(nullptr, "\r\n", &save)) != nullptr) {
    char* separator = std::strchr(line, ':');
    if (separator == nullptr) {
      continue;
    }
    *separator = '\0';
    const char* value = trimHeaderValue(separator + 1);
    if (strcasecmp(line, "Authorization") == 0) {
      copyBounded(authorization, sizeof(authorization), value);
    } else if (strcasecmp(line, "X-Stackchan-SHA256") == 0) {
      copyBounded(expectedSha256, sizeof(expectedSha256), value);
    } else if (strcasecmp(line, "Content-Length") == 0) {
      copyBounded(contentLengthText, sizeof(contentLengthText), value);
    } else if (strcasecmp(line, "Content-Type") == 0) {
      copyBounded(contentType, sizeof(contentType), value);
    } else if (strcasecmp(line, "Transfer-Encoding") == 0) {
      transferEncodingSeen = true;
    }
  }

  if (std::strcmp(method, "GET") == 0 && std::strcmp(path, kStatusPath) == 0) {
    telemetry_.statusRequests++;
    std::memset(header_, 0, sizeof(header_));
    sendStatus();
    closeClient();
    return true;
  }
  telemetry_.uploadRequests++;
  if (std::strcmp(method, "POST") != 0 || std::strcmp(path, kFirmwarePath) != 0) {
    telemetry_.headerFailures++;
    abortUpload("route_not_found", 404, nowMs);
    return false;
  }
  if (std::strncmp(authorization, "Bearer ", 7) != 0 || !authorizeToken(authorization + 7)) {
    telemetry_.authFailures++;
    std::memset(authorization, 0, sizeof(authorization));
    abortUpload("unauthorized", 401, nowMs);
    return false;
  }
  std::memset(authorization, 0, sizeof(authorization));
  telemetry_.authorizedUploads++;
  if (!decodeSha256Hex(expectedSha256, expectedImageHash_)) {
    telemetry_.headerFailures++;
    abortUpload("sha256_header_invalid", 400, nowMs);
    return false;
  }
  if (!parseUnsignedSize(contentLengthText, &contentLength_) || transferEncodingSeen ||
      strcasecmp(contentType, "application/octet-stream") != 0) {
    telemetry_.headerFailures++;
    abortUpload("content_headers_invalid", 400, nowMs);
    return false;
  }
  if (!validateInactivePartition(contentLength_)) {
    abortUpload("inactive_partition_unavailable", 409, nowMs);
    return false;
  }

  OtaPreflightInput preflight = preflightProvider_(preflightContext_);
  preflight.currentAppConfirmed = preflight.currentAppConfirmed && !telemetry_.healthPending;
  telemetry_.lastPreflight = evaluateOtaPreflight(preflight, config_.preflightLimits);
  if (telemetry_.lastPreflight != OtaPreflightResult::Ready) {
    telemetry_.preflightFailures++;
    abortUpload(otaPreflightResultName(telemetry_.lastPreflight), 409, nowMs);
    return false;
  }

  const esp_partition_t* target = static_cast<const esp_partition_t*>(updatePartition_);
  if (!Update.begin(contentLength_, U_FLASH, -1, LOW, target->label)) {
    telemetry_.updateFailures++;
    abortUpload("update_begin_failed", 500, nowMs);
    return false;
  }
  updateBegun_ = true;
  uploadSha256_.begin();
  copyBounded(record_.previousPartition, sizeof(record_.previousPartition), telemetry_.runningPartition);
  copyBounded(record_.targetPartition, sizeof(record_.targetPartition), target->label);
  copyBounded(record_.expectedSha256, sizeof(record_.expectedSha256), expectedSha256);
  record_.imageSize = static_cast<uint32_t>(contentLength_);
  record_.phase = OtaPersistentPhase::Staged;
  copyRecordToTelemetry();
  std::memset(header_, 0, sizeof(header_));
  requestState_ = RequestState::Body;
  telemetry_.uploadActive = true;
  telemetry_.uploadsStarted++;
  setError("none");
  return true;
}

void LanOtaServer::readBody(uint32_t nowMs) {
  size_t pollBytes = 0;
  while (client_.available() > 0 && bodyReceived_ < contentLength_ &&
         pollBytes < config_.bytesPerPoll) {
    const size_t remaining = contentLength_ - bodyReceived_;
    const size_t budget = config_.bytesPerPoll - pollBytes;
    const size_t request = remaining < sizeof(ioBuffer_) ? remaining : sizeof(ioBuffer_);
    const size_t boundedRequest = request < budget ? request : budget;
    const int received = client_.read(ioBuffer_, boundedRequest);
    if (received <= 0) {
      break;
    }
    uploadSha256_.add(ioBuffer_, static_cast<size_t>(received));
    const size_t written = Update.write(ioBuffer_, static_cast<size_t>(received));
    if (written != static_cast<size_t>(received)) {
      telemetry_.updateFailures++;
      abortUpload("update_write_failed", 500, nowMs);
      return;
    }
    bodyReceived_ += static_cast<size_t>(received);
    pollBytes += static_cast<size_t>(received);
    telemetry_.bytesReceived = static_cast<uint32_t>(bodyReceived_);
    telemetry_.lastActivityMs = nowMs;
    requestLastActivityMs_ = nowMs;
  }
  std::memset(ioBuffer_, 0, sizeof(ioBuffer_));
  if (bodyReceived_ == contentLength_) {
    finishUpload(nowMs);
  } else if (!client_.connected() && client_.available() == 0) {
    abortUpload("body_disconnected", 400, nowMs);
  }
}

void LanOtaServer::finishUpload(uint32_t nowMs) {
  uint8_t actualHash[32] = {};
  uploadSha256_.calculate();
  uploadSha256_.getBytes(actualHash);
  if (!constantTimeEqual(actualHash, expectedImageHash_, sizeof(actualHash))) {
    telemetry_.sha256Failures++;
    std::memset(actualHash, 0, sizeof(actualHash));
    abortUpload("sha256_mismatch", 422, nowMs);
    return;
  }
  std::memset(actualHash, 0, sizeof(actualHash));
  if (!savePersistentRecord()) {
    abortUpload("state_write_failed", 500, nowMs);
    return;
  }
  if (!Update.end(false)) {
    telemetry_.updateFailures++;
    record_.phase = OtaPersistentPhase::Failed;
    savePersistentRecord();
    copyRecordToTelemetry();
    abortUpload("update_finalize_failed", 500, nowMs);
    return;
  }
  updateBegun_ = false;
  telemetry_.uploadActive = false;
  telemetry_.uploadsCompleted++;
  telemetry_.bytesReceived = static_cast<uint32_t>(bodyReceived_);
  char response[256] = {};
  std::snprintf(response,
                sizeof(response),
                "{\"ok\":true,\"status\":\"staged\",\"target\":\"%s\","
                "\"sha256\":\"%s\",\"rebooting\":true}\n",
                record_.targetPartition,
                record_.expectedSha256);
  sendJson(202, "Accepted", response);
  closeClient();
  scheduleReboot(nowMs);
}

void LanOtaServer::abortUpload(const char* reason, int httpStatus, uint32_t nowMs) {
  if (updateBegun_) {
    Update.abort();
    updateBegun_ = false;
  }
  if (telemetry_.uploadActive || requestState_ == RequestState::Body) {
    telemetry_.uploadsAborted++;
  }
  telemetry_.uploadActive = false;
  telemetry_.lastActivityMs = nowMs;
  setError(reason);
  char body[160] = {};
  std::snprintf(body, sizeof(body), "{\"ok\":false,\"error\":\"%s\"}\n", reason);
  const char* statusText = httpStatus == 400 ? "Bad Request" :
                           httpStatus == 401 ? "Unauthorized" :
                           httpStatus == 404 ? "Not Found" :
                           httpStatus == 408 ? "Request Timeout" :
                           httpStatus == 409 ? "Conflict" :
                           httpStatus == 422 ? "Unprocessable Content" :
                           httpStatus == 431 ? "Request Header Fields Too Large" :
                           httpStatus == 503 ? "Service Unavailable" : "Internal Server Error";
  sendJson(httpStatus, statusText, body);
  closeClient();
}

void LanOtaServer::closeClient() {
  if (client_) {
    client_.clear();
    client_.stop();
  }
  requestState_ = RequestState::Idle;
  headerLength_ = 0;
  contentLength_ = 0;
  bodyReceived_ = 0;
  updatePartition_ = nullptr;
  std::memset(header_, 0, sizeof(header_));
  std::memset(expectedImageHash_, 0, sizeof(expectedImageHash_));
}

void LanOtaServer::sendJson(int statusCode, const char* statusText, const char* body) {
  if (!client_) {
    return;
  }
  const size_t length = body != nullptr ? std::strlen(body) : 0;
  client_.printf("HTTP/1.1 %d %s\r\nContent-Type: application/json\r\n"
                 "Cache-Control: no-store\r\nContent-Length: %u\r\nConnection: close\r\n\r\n",
                 statusCode,
                 statusText,
                 static_cast<unsigned>(length));
  if (length > 0) {
    client_.write(reinterpret_cast<const uint8_t*>(body), length);
  }
}

void LanOtaServer::sendStatus() {
  char body[768] = {};
  std::snprintf(
      body,
      sizeof(body),
      "{\"schema\":\"stackchan.lan-ota.v1\",\"enabled\":%s,\"upload_active\":%s,"
      "\"health_pending\":%s,\"current_app_confirmed\":%s,"
      "\"bootloader_rollback_enabled\":%s,\"software_rollback_only\":%s,"
      "\"phase\":\"%s\",\"running_partition\":\"%s\","
      "\"previous_partition\":\"%s\",\"target_partition\":\"%s\","
      "\"expected_sha256\":\"%s\",\"last_preflight\":\"%s\","
      "\"last_error\":\"%s\"}\n",
      telemetry_.enabled ? "true" : "false",
      telemetry_.uploadActive ? "true" : "false",
      telemetry_.healthPending ? "true" : "false",
      telemetry_.currentAppConfirmed ? "true" : "false",
      telemetry_.bootloaderRollbackEnabled ? "true" : "false",
      telemetry_.softwareRollbackOnly ? "true" : "false",
      otaPersistentPhaseName(telemetry_.persistentPhase),
      telemetry_.runningPartition,
      telemetry_.previousPartition,
      telemetry_.targetPartition,
      telemetry_.expectedSha256,
      otaPreflightResultName(telemetry_.lastPreflight),
      telemetry_.lastError);
  sendJson(200, "OK", body);
}

bool LanOtaServer::authorizeToken(const char* token) const {
  if (token == nullptr) {
    return false;
  }
  const size_t length = std::strlen(token);
  if (length < 32 || length > 128) {
    return false;
  }
  SHA256Builder tokenHash;
  tokenHash.begin();
  tokenHash.add(reinterpret_cast<const uint8_t*>(token), length);
  tokenHash.calculate();
  uint8_t actual[32] = {};
  tokenHash.getBytes(actual);
  const bool equal = constantTimeEqual(actual, configuredTokenHash_, sizeof(actual));
  std::memset(actual, 0, sizeof(actual));
  return equal;
}

bool LanOtaServer::validateInactivePartition(size_t contentLength) {
  const esp_partition_t* running = esp_ota_get_running_partition();
  const esp_partition_t* target = esp_ota_get_next_update_partition(nullptr);
  if (running != nullptr) {
    copyBounded(telemetry_.runningPartition, sizeof(telemetry_.runningPartition), running->label);
  }
  if (running == nullptr || target == nullptr || target == running ||
      target->type != ESP_PARTITION_TYPE_APP ||
      (target->subtype != ESP_PARTITION_SUBTYPE_APP_OTA_0 &&
       target->subtype != ESP_PARTITION_SUBTYPE_APP_OTA_1) ||
      contentLength == 0 || contentLength > target->size) {
    updatePartition_ = nullptr;
    return false;
  }
  updatePartition_ = target;
  return true;
}

bool LanOtaServer::loadPersistentRecord() {
  record_ = PersistentRecord {};
  if (!preferencesReady_ || !preferences_.isKey(kPhaseKey)) {
    telemetry_.persistentRecordPresent = false;
    return true;
  }
  const uint8_t phase = preferences_.getUChar(kPhaseKey, 0);
  record_.phase = phase <= static_cast<uint8_t>(OtaPersistentPhase::Failed)
                      ? static_cast<OtaPersistentPhase>(phase)
                      : OtaPersistentPhase::Failed;
  record_.imageSize = preferences_.getUInt(kSizeKey, 0);
  preferences_.getString(kPreviousKey, "").toCharArray(
      record_.previousPartition, sizeof(record_.previousPartition));
  preferences_.getString(kTargetKey, "").toCharArray(
      record_.targetPartition, sizeof(record_.targetPartition));
  preferences_.getString(kSha256Key, "").toCharArray(
      record_.expectedSha256, sizeof(record_.expectedSha256));
  if (record_.phase != OtaPersistentPhase::None &&
      (record_.previousPartition[0] == '\0' || record_.targetPartition[0] == '\0' ||
       record_.imageSize == 0 || !isValidSha256Hex(record_.expectedSha256))) {
    record_.phase = OtaPersistentPhase::Failed;
  }
  telemetry_.persistentRecordPresent = record_.phase != OtaPersistentPhase::None;
  copyRecordToTelemetry();
  return true;
}

bool LanOtaServer::savePersistentRecord() {
  if (!preferencesReady_) {
    return false;
  }
  const bool ok = preferences_.putUChar(kPhaseKey, static_cast<uint8_t>(record_.phase)) == 1 &&
                  preferences_.putUInt(kSizeKey, record_.imageSize) == sizeof(uint32_t) &&
                  preferences_.putString(kPreviousKey, record_.previousPartition) > 0 &&
                  preferences_.putString(kTargetKey, record_.targetPartition) > 0 &&
                  preferences_.putString(kSha256Key, record_.expectedSha256) > 0;
  if (!ok) {
    telemetry_.stateWriteFailures++;
    return false;
  }
  telemetry_.persistentRecordPresent = true;
  copyRecordToTelemetry();
  return true;
}

void LanOtaServer::reconcileBootState(uint32_t nowMs) {
  const esp_partition_t* running = esp_ota_get_running_partition();
  if (running == nullptr) {
    setError("running_partition_missing");
    return;
  }
  copyBounded(telemetry_.runningPartition, sizeof(telemetry_.runningPartition), running->label);
  esp_ota_img_states_t state = ESP_OTA_IMG_UNDEFINED;
  runningAppPendingVerify_ =
      esp_ota_get_state_partition(running, &state) == ESP_OK && state == ESP_OTA_IMG_PENDING_VERIFY;
  telemetry_.currentAppConfirmed = !runningAppPendingVerify_;

  const bool runningTarget = record_.targetPartition[0] != '\0' &&
                             std::strcmp(record_.targetPartition, running->label) == 0;
  const bool runningPrevious = record_.previousPartition[0] != '\0' &&
                               std::strcmp(record_.previousPartition, running->label) == 0;
  const bool stagedOrTesting = record_.phase == OtaPersistentPhase::Staged ||
                               record_.phase == OtaPersistentPhase::Testing;
  if (runningPrevious && (stagedOrTesting || record_.phase == OtaPersistentPhase::RollbackRequested)) {
    record_.phase = OtaPersistentPhase::RolledBack;
    savePersistentRecord();
    telemetry_.healthPending = false;
    telemetry_.currentAppConfirmed = true;
  } else if (runningTarget && stagedOrTesting) {
    record_.phase = OtaPersistentPhase::Testing;
    savePersistentRecord();
    telemetry_.healthPending = true;
    telemetry_.currentAppConfirmed = false;
    healthPolicy_.begin(nowMs);
  } else if (runningAppPendingVerify_) {
    telemetry_.persistentRecordMissingForPendingApp = !runningTarget;
    telemetry_.healthPending = true;
    healthPolicy_.begin(nowMs);
  }
  copyRecordToTelemetry();
}

void LanOtaServer::copyRecordToTelemetry() {
  telemetry_.persistentPhase = record_.phase;
  copyBounded(telemetry_.previousPartition,
              sizeof(telemetry_.previousPartition),
              record_.previousPartition);
  copyBounded(telemetry_.targetPartition,
              sizeof(telemetry_.targetPartition),
              record_.targetPartition);
  copyBounded(telemetry_.expectedSha256,
              sizeof(telemetry_.expectedSha256),
              record_.expectedSha256);
}

void LanOtaServer::setError(const char* error) {
  copyBounded(telemetry_.lastError, sizeof(telemetry_.lastError), error);
}

void LanOtaServer::scheduleReboot(uint32_t nowMs) {
  telemetry_.rebootPending = true;
  rebootAtMs_ = nowMs + 1000;
}

bool LanOtaServer::requestSoftwareRollback(uint32_t nowMs) {
  if (record_.previousPartition[0] == '\0') {
    return false;
  }
  const esp_partition_t* previous = esp_partition_find_first(
      ESP_PARTITION_TYPE_APP, ESP_PARTITION_SUBTYPE_ANY, record_.previousPartition);
  if (previous == nullptr || previous == esp_ota_get_running_partition() ||
      (previous->subtype != ESP_PARTITION_SUBTYPE_APP_OTA_0 &&
       previous->subtype != ESP_PARTITION_SUBTYPE_APP_OTA_1) ||
      esp_ota_set_boot_partition(previous) != ESP_OK) {
    return false;
  }
  scheduleReboot(nowMs);
  return true;
}

#endif

}  // namespace stackchan
