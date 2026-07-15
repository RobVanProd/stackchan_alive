#include "io/SensorAdapter.hpp"

#include <ctype.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "io/SpeechPromptBank.hpp"
#include "persona/CommandMap.hpp"

#if defined(ARDUINO_ARCH_ESP32)
#include <M5Unified.h>
#endif

namespace stackchan {

namespace {

struct ModeCommand {
  const char* name;
  CharacterMode mode;
  EventType event;
  const char* command;
};

struct EventCommand {
  const char* name;
  CharacterMode mode;
  EventType event;
  const char* command;
};

constexpr ModeCommand kModeCommands[] = {
    {"boot", CharacterMode::Boot, EventType::Boot, "mode_boot"},
    {"idle", CharacterMode::Idle, EventType::IdleTimeout, "mode_idle"},
    {"attend", CharacterMode::Attend, EventType::FaceDetected, "mode_attend"},
    {"near", CharacterMode::Attend, EventType::UserNear, "mode_attend"},
    {"listen", CharacterMode::Listen, EventType::WakeWord, "mode_listen"},
    {"think", CharacterMode::Think, EventType::ThinkingStarted, "mode_think"},
    {"thinking", CharacterMode::Think, EventType::ThinkingStarted, "mode_think"},
    {"speak", CharacterMode::Speak, EventType::ResponseStarted, "mode_speak"},
    {"talk", CharacterMode::Speak, EventType::ResponseStarted, "mode_speak"},
    {"react", CharacterMode::React, EventType::UserTouched, "mode_react"},
    {"sleep", CharacterMode::Sleep, EventType::IdleTimeout, "mode_sleep"},
    {"error", CharacterMode::Error, EventType::Error, "mode_error"},
};

constexpr EventCommand kEventCommands[] = {
    {"boot", CharacterMode::Boot, EventType::Boot, "event_boot"},
    {"face", CharacterMode::Attend, EventType::FaceDetected, "event_face"},
    {"detected", CharacterMode::Attend, EventType::FaceDetected, "event_face"},
    {"facelost", CharacterMode::Idle, EventType::FaceLost, "event_face_lost"},
    {"face_lost", CharacterMode::Idle, EventType::FaceLost, "event_face_lost"},
    {"near", CharacterMode::Attend, EventType::UserNear, "event_near"},
    {"touch", CharacterMode::React, EventType::UserTouched, "event_touch"},
    {"touched", CharacterMode::React, EventType::UserTouched, "event_touch"},
    {"wake", CharacterMode::Listen, EventType::WakeWord, "event_wake"},
    {"listen", CharacterMode::Listen, EventType::WakeWord, "event_wake"},
    {"speaking", CharacterMode::Listen, EventType::UserSpeaking, "event_user_speaking"},
    {"user_speaking", CharacterMode::Listen, EventType::UserSpeaking, "event_user_speaking"},
    {"speech_end", CharacterMode::Idle, EventType::SpeechEnded, "event_speech_end"},
    {"speechended", CharacterMode::Idle, EventType::SpeechEnded, "event_speech_end"},
    {"think", CharacterMode::Think, EventType::ThinkingStarted, "event_think"},
    {"thinking", CharacterMode::Think, EventType::ThinkingStarted, "event_think"},
    {"response", CharacterMode::Speak, EventType::ResponseStarted, "event_response"},
    {"response_start", CharacterMode::Speak, EventType::ResponseStarted, "event_response"},
    {"speak", CharacterMode::Speak, EventType::ResponseStarted, "event_response"},
    {"response_end", CharacterMode::Idle, EventType::ResponseEnded, "event_response_end"},
    {"idle", CharacterMode::Idle, EventType::IdleTimeout, "event_idle"},
    {"timeout", CharacterMode::Idle, EventType::IdleTimeout, "event_idle"},
    {"error", CharacterMode::Error, EventType::Error, "event_error"},
};

bool isHelpToken(const char* token) {
  return strcmp(token, "help") == 0 || strcmp(token, "?") == 0;
}

bool fillHelp(BenchControl* controlOut) {
  BenchControl parsed;
  parsed.wantsHelp = true;
  parsed.command = "help";
  *controlOut = parsed;
  return true;
}

bool fillStatus(BenchControl* controlOut) {
  BenchControl parsed;
  parsed.wantsStatus = true;
  parsed.command = "status";
  *controlOut = parsed;
  return true;
}

bool equalsIgnoreCase(const char* left, const char* right) {
  if (left == nullptr || right == nullptr) {
    return false;
  }
  while (*left != '\0' && *right != '\0') {
    const char a = static_cast<char>(tolower(static_cast<unsigned char>(*left)));
    const char b = static_cast<char>(tolower(static_cast<unsigned char>(*right)));
    if (a != b) {
      return false;
    }
    ++left;
    ++right;
  }
  return *left == '\0' && *right == '\0';
}

bool startsWithIgnoreCase(const char* value, const char* prefix) {
  if (value == nullptr || prefix == nullptr) {
    return false;
  }
  while (*prefix != '\0') {
    if (*value == '\0') {
      return false;
    }
    const char a = static_cast<char>(tolower(static_cast<unsigned char>(*value)));
    const char b = static_cast<char>(tolower(static_cast<unsigned char>(*prefix)));
    if (a != b) {
      return false;
    }
    ++value;
    ++prefix;
  }
  return true;
}

void copyBounded(char* out, size_t outSize, const char* value) {
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

bool parsePortToken(const char* token, uint16_t* portOut) {
  if (token == nullptr || portOut == nullptr || token[0] == '\0') {
    return false;
  }

  char* end = nullptr;
  const unsigned long parsed = strtoul(token, &end, 10);
  if (end == token || *end != '\0' || parsed == 0 || parsed > 65535ul) {
    return false;
  }
  *portOut = static_cast<uint16_t>(parsed);
  return true;
}

bool splitKeyValue(char* token, char** keyOut, char** valueOut) {
  if (token == nullptr || keyOut == nullptr || valueOut == nullptr) {
    return false;
  }
  char* separator = strchr(token, '=');
  if (separator == nullptr) {
    separator = strchr(token, ':');
  }
  if (separator == nullptr || separator == token || separator[1] == '\0') {
    return false;
  }
  *separator = '\0';
  *keyOut = token;
  *valueOut = separator + 1;
  return true;
}

bool tokenizeQuoted(char* text, char** tokens, uint8_t maxTokens, uint8_t* tokenCountOut) {
  if (text == nullptr || tokens == nullptr || tokenCountOut == nullptr) {
    return false;
  }

  uint8_t tokenCount = 0;
  char* read = text;
  char* write = text;
  while (*read != '\0') {
    while (*read == ' ' || *read == '\t' || *read == '\r' || *read == '\n') {
      ++read;
    }
    if (*read == '\0') {
      break;
    }
    if (tokenCount >= maxTokens) {
      return false;
    }

    tokens[tokenCount++] = write;
    char quote = '\0';
    while (*read != '\0') {
      const char ch = *read;
      if (quote != '\0') {
        if (ch == '\\' && read[1] != '\0') {
          *write++ = read[1];
          read += 2;
          continue;
        }
        if (ch == quote) {
          quote = '\0';
          ++read;
          continue;
        }
        *write++ = ch;
        ++read;
        continue;
      }

      if (ch == ' ' || ch == '\t' || ch == '\r' || ch == '\n') {
        ++read;
        break;
      }
      if (ch == '"' || ch == '\'') {
        quote = ch;
        ++read;
        continue;
      }
      if (ch == '\\' && read[1] != '\0') {
        *write++ = read[1];
        read += 2;
        continue;
      }
      *write++ = ch;
      ++read;
    }
    if (quote != '\0') {
      return false;
    }
    *write++ = '\0';
  }

  *tokenCountOut = tokenCount;
  return true;
}

int hexValue(char ch) {
  if (ch >= '0' && ch <= '9') {
    return ch - '0';
  }
  if (ch >= 'a' && ch <= 'f') {
    return 10 + (ch - 'a');
  }
  if (ch >= 'A' && ch <= 'F') {
    return 10 + (ch - 'A');
  }
  return -1;
}

bool urlDecode(char* out, size_t outSize, const char* value, size_t valueLen) {
  if (out == nullptr || outSize == 0 || value == nullptr) {
    return false;
  }
  size_t outLen = 0;
  for (size_t i = 0; i < valueLen; ++i) {
    if (outLen + 1u >= outSize) {
      return false;
    }
    if (value[i] == '%') {
      if (i + 2u >= valueLen) {
        return false;
      }
      const int high = hexValue(value[i + 1u]);
      const int low = hexValue(value[i + 2u]);
      if (high < 0 || low < 0) {
        return false;
      }
      out[outLen++] = static_cast<char>((high << 4) | low);
      i += 2u;
    } else if (value[i] == '+') {
      out[outLen++] = ' ';
    } else {
      out[outLen++] = value[i];
    }
  }
  out[outLen] = '\0';
  return true;
}

bool parseBridgeUrl(const char* url, BenchWiFiProvisioningControl* wifi) {
  if (url == nullptr || wifi == nullptr) {
    return false;
  }
  const char* cursor = nullptr;
  if (startsWithIgnoreCase(url, "ws://")) {
    cursor = url + 5;
    wifi->useTls = false;
    wifi->bridgePort = 8765;
  } else if (startsWithIgnoreCase(url, "wss://")) {
    cursor = url + 6;
    wifi->useTls = true;
    wifi->bridgePort = 443;
  } else {
    return false;
  }

  char host[sizeof(wifi->bridgeHost)] = {};
  size_t hostLen = 0;
  while (cursor[hostLen] != '\0' && cursor[hostLen] != ':' && cursor[hostLen] != '/' &&
         hostLen + 1u < sizeof(host)) {
    host[hostLen] = cursor[hostLen];
    ++hostLen;
  }
  if (cursor[hostLen] != '\0' && cursor[hostLen] != ':' && cursor[hostLen] != '/') {
    return false;
  }
  host[hostLen] = '\0';
  if (host[0] == '\0') {
    return false;
  }
  bool numericHost = true;
  for (size_t i = 0; host[i] != '\0'; ++i) {
    if (!isdigit(static_cast<unsigned char>(host[i])) && host[i] != '.') {
      numericHost = false;
      break;
    }
  }
  if (wifi->useTls && numericHost) {
    return false;
  }
  copyBounded(wifi->bridgeHost, sizeof(wifi->bridgeHost), host);
  cursor += hostLen;

  if (*cursor == ':') {
    ++cursor;
    char port[8] = {};
    size_t portLen = 0;
    while (isdigit(static_cast<unsigned char>(cursor[portLen])) && portLen + 1u < sizeof(port)) {
      port[portLen] = cursor[portLen];
      ++portLen;
    }
    port[portLen] = '\0';
    if (!parsePortToken(port, &wifi->bridgePort)) {
      return false;
    }
    cursor += portLen;
  }

  if (*cursor == '/') {
    copyBounded(wifi->bridgePath, sizeof(wifi->bridgePath), cursor);
  } else if (*cursor != '\0') {
    return false;
  }
  return true;
}

bool parsePairingTicketBridgeUrl(const char* url, BenchPairingTicketControl* ticket) {
  if (ticket == nullptr) {
    return false;
  }
  BenchWiFiProvisioningControl wifi;
  if (!parseBridgeUrl(url, &wifi)) {
    return false;
  }
  copyBounded(ticket->bridgeHost, sizeof(ticket->bridgeHost), wifi.bridgeHost);
  ticket->useTls = wifi.useTls;
  ticket->bridgePort = wifi.bridgePort;
  copyBounded(ticket->bridgePath, sizeof(ticket->bridgePath), wifi.bridgePath);
  return true;
}

bool queryValue(const char* payload, const char* key, char* out, size_t outSize) {
  if (payload == nullptr || key == nullptr || out == nullptr || outSize == 0) {
    return false;
  }
  out[0] = '\0';
  const char* cursor = strchr(payload, '?');
  if (cursor == nullptr) {
    return false;
  }
  ++cursor;
  const size_t keyLen = strlen(key);
  while (*cursor != '\0') {
    const char* itemEnd = strchr(cursor, '&');
    if (itemEnd == nullptr) {
      itemEnd = cursor + strlen(cursor);
    }
    const char* equals = static_cast<const char*>(memchr(cursor, '=', static_cast<size_t>(itemEnd - cursor)));
    if (equals != nullptr && static_cast<size_t>(equals - cursor) == keyLen &&
        strncmp(cursor, key, keyLen) == 0) {
      return urlDecode(out, outSize, equals + 1, static_cast<size_t>(itemEnd - equals - 1));
    }
    cursor = *itemEnd == '&' ? itemEnd + 1 : itemEnd;
  }
  return false;
}

void normalizePairingTicketCode(char* code) {
  if (code == nullptr) {
    return;
  }
  for (size_t i = 0; code[i] != '\0'; ++i) {
    code[i] = static_cast<char>(tolower(static_cast<unsigned char>(code[i])));
  }
}

const char* pairingTicketPayloadFromLine(const char* line) {
  if (line == nullptr) {
    return nullptr;
  }
  while (*line == ' ' || *line == '\t') {
    ++line;
  }
  if (startsWithIgnoreCase(line, "stackchan://pair?")) {
    return line;
  }

  const char* cursor = line;
  if (startsWithIgnoreCase(cursor, "pairing")) {
    cursor += 7;
  } else if (startsWithIgnoreCase(cursor, "pair")) {
    cursor += 4;
  } else if (startsWithIgnoreCase(cursor, "setup")) {
    cursor += 5;
  } else {
    return nullptr;
  }
  while (*cursor == ' ' || *cursor == '\t') {
    ++cursor;
  }
  if (startsWithIgnoreCase(cursor, "ticket")) {
    cursor += 6;
  } else if (startsWithIgnoreCase(cursor, "qr")) {
    cursor += 2;
  } else if (startsWithIgnoreCase(cursor, "scan")) {
    cursor += 4;
  }
  while (*cursor == ' ' || *cursor == '\t') {
    ++cursor;
  }
  return startsWithIgnoreCase(cursor, "stackchan://pair?") ? cursor : nullptr;
}

bool fillPairingTicketControlRaw(const char* line, BenchControl* controlOut) {
  if (controlOut == nullptr) {
    return false;
  }
  const char* payload = pairingTicketPayloadFromLine(line);
  if (payload == nullptr) {
    return false;
  }

  BenchControl parsed;
  parsed.hasPairingTicket = true;
  parsed.hasPairingControl = true;
  parsed.command = "pairing_ticket";

  char bridgeUrl[96] = {};
  if (!queryValue(payload, "bridge", bridgeUrl, sizeof(bridgeUrl)) ||
      !parsePairingTicketBridgeUrl(bridgeUrl, &parsed.pairingTicket)) {
    return false;
  }
  if (!queryValue(payload, "code", parsed.pairingTicket.code, sizeof(parsed.pairingTicket.code)) ||
      strlen(parsed.pairingTicket.code) != 6) {
    return false;
  }
  normalizePairingTicketCode(parsed.pairingTicket.code);
  copyBounded(parsed.pairing.code, sizeof(parsed.pairing.code), parsed.pairingTicket.code);
  queryValue(payload, "endpoint_id", parsed.pairingTicket.endpointId, sizeof(parsed.pairingTicket.endpointId));
  queryValue(payload, "fingerprint", parsed.pairingTicket.fingerprint, sizeof(parsed.pairingTicket.fingerprint));

  *controlOut = parsed;
  return true;
}

bool fillWiFiProvisioningControlRaw(const char* line, BenchControl* controlOut) {
  if (line == nullptr || controlOut == nullptr) {
    return false;
  }

  char copy[192] = {};
  copyBounded(copy, sizeof(copy), line);
  char* allTokens[15] = {};
  uint8_t allTokenCount = 0;
  if (!tokenizeQuoted(copy, allTokens, 15, &allTokenCount)) {
    return false;
  }
  char* first = allTokenCount >= 1 ? allTokens[0] : nullptr;
  if (first == nullptr ||
      (!equalsIgnoreCase(first, "wifi") && !equalsIgnoreCase(first, "bridgewifi") &&
       !equalsIgnoreCase(first, "bridge_wifi"))) {
    return false;
  }

  BenchControl parsed;
  parsed.hasWiFiProvisioning = true;
  parsed.command = "wifi_provision";

  char* tokens[14] = {};
  const uint8_t tokenCount = static_cast<uint8_t>(allTokenCount - 1u);
  for (uint8_t i = 0; i < tokenCount; ++i) {
    tokens[i] = allTokens[i + 1u];
  }

  if (tokenCount == 0) {
    return false;
  }

  if (equalsIgnoreCase(tokens[0], "status") || equalsIgnoreCase(tokens[0], "show")) {
    parsed.wifi.action = BenchWiFiProvisioningAction::Status;
    *controlOut = parsed;
    return true;
  }

  if (equalsIgnoreCase(tokens[0], "use") || equalsIgnoreCase(tokens[0], "select") ||
      equalsIgnoreCase(tokens[0], "mode")) {
    if (tokenCount != 2 || !parseBridgeWiFiProfile(tokens[1], &parsed.wifi.profile)) {
      return false;
    }
    parsed.wifi.action = BenchWiFiProvisioningAction::UseProfile;
    *controlOut = parsed;
    return true;
  }

  if (equalsIgnoreCase(tokens[0], "clear") || equalsIgnoreCase(tokens[0], "off") ||
      equalsIgnoreCase(tokens[0], "disable") || equalsIgnoreCase(tokens[0], "reset")) {
    parsed.wifi.clear = true;
    parsed.wifi.action = BenchWiFiProvisioningAction::ClearAll;
    if (tokenCount == 2) {
      if (!parseBridgeWiFiProfile(tokens[1], &parsed.wifi.profile)) {
        return false;
      }
      parsed.wifi.action = BenchWiFiProvisioningAction::ClearProfile;
    } else if (tokenCount != 1) {
      return false;
    }
    *controlOut = parsed;
    return true;
  }

  uint8_t index = 0;
  if (equalsIgnoreCase(tokens[0], "set") || equalsIgnoreCase(tokens[0], "connect") ||
      equalsIgnoreCase(tokens[0], "bridge")) {
    index = 1;
    if (index < tokenCount && parseBridgeWiFiProfile(tokens[index], &parsed.wifi.profile)) {
      ++index;
    }
  } else if (parseBridgeWiFiProfile(tokens[0], &parsed.wifi.profile)) {
    index = 1;
    if (index < tokenCount && (equalsIgnoreCase(tokens[index], "set") ||
                               equalsIgnoreCase(tokens[index], "connect"))) {
      ++index;
    }
  }

  bool hasSsid = false;
  bool hasHost = false;
  while (index < tokenCount) {
    char* key = tokens[index];
    char* value = (index + 1u < tokenCount) ? tokens[index + 1u] : nullptr;
    char* splitKey = nullptr;
    char* splitValue = nullptr;
    bool consumedPair = false;
    if (splitKeyValue(key, &splitKey, &splitValue)) {
      key = splitKey;
      value = splitValue;
      consumedPair = true;
    }

    if (equalsIgnoreCase(key, "ssid") || equalsIgnoreCase(key, "network")) {
      if (value == nullptr || value[0] == '\0') {
        return false;
      }
      copyBounded(parsed.wifi.ssid, sizeof(parsed.wifi.ssid), value);
      hasSsid = true;
      index = static_cast<uint8_t>(index + (consumedPair ? 1u : 2u));
      continue;
    }
    if (equalsIgnoreCase(key, "pass") || equalsIgnoreCase(key, "password") ||
        equalsIgnoreCase(key, "psk")) {
      if (value == nullptr) {
        return false;
      }
      copyBounded(parsed.wifi.password, sizeof(parsed.wifi.password), value);
      index = static_cast<uint8_t>(index + (consumedPair ? 1u : 2u));
      continue;
    }
    if (equalsIgnoreCase(key, "host") || equalsIgnoreCase(key, "bridge_host")) {
      if (value == nullptr || value[0] == '\0') {
        return false;
      }
      copyBounded(parsed.wifi.bridgeHost, sizeof(parsed.wifi.bridgeHost), value);
      hasHost = true;
      index = static_cast<uint8_t>(index + (consumedPair ? 1u : 2u));
      continue;
    }
    if (equalsIgnoreCase(key, "url") || equalsIgnoreCase(key, "bridge_url")) {
      if (value == nullptr || !parseBridgeUrl(value, &parsed.wifi)) {
        return false;
      }
      hasHost = true;
      index = static_cast<uint8_t>(index + (consumedPair ? 1u : 2u));
      continue;
    }
    if (equalsIgnoreCase(key, "access_id") || equalsIgnoreCase(key, "client_id") ||
        equalsIgnoreCase(key, "cf_access_id")) {
      if (value == nullptr || value[0] == '\0') {
        return false;
      }
      copyBounded(parsed.wifi.accessClientId, sizeof(parsed.wifi.accessClientId), value);
      index = static_cast<uint8_t>(index + (consumedPair ? 1u : 2u));
      continue;
    }
    if (equalsIgnoreCase(key, "access_secret") || equalsIgnoreCase(key, "client_secret") ||
        equalsIgnoreCase(key, "cf_access_secret")) {
      if (value == nullptr || value[0] == '\0') {
        return false;
      }
      copyBounded(parsed.wifi.accessClientSecret, sizeof(parsed.wifi.accessClientSecret), value);
      index = static_cast<uint8_t>(index + (consumedPair ? 1u : 2u));
      continue;
    }
    if (equalsIgnoreCase(key, "port")) {
      if (value == nullptr || !parsePortToken(value, &parsed.wifi.bridgePort)) {
        return false;
      }
      index = static_cast<uint8_t>(index + (consumedPair ? 1u : 2u));
      continue;
    }
    if (equalsIgnoreCase(key, "path")) {
      if (value == nullptr || value[0] != '/') {
        return false;
      }
      copyBounded(parsed.wifi.bridgePath, sizeof(parsed.wifi.bridgePath), value);
      index = static_cast<uint8_t>(index + (consumedPair ? 1u : 2u));
      continue;
    }
    if (startsWithIgnoreCase(key, "ws://") || startsWithIgnoreCase(key, "wss://")) {
      if (!parseBridgeUrl(key, &parsed.wifi)) {
        return false;
      }
      hasHost = true;
      ++index;
      continue;
    }
    return false;
  }

  if (!hasSsid || !hasHost) {
    return false;
  }
  const bool accessPairComplete =
      (parsed.wifi.accessClientId[0] == '\0') == (parsed.wifi.accessClientSecret[0] == '\0');
  if (!accessPairComplete ||
      (parsed.wifi.profile == BridgeWiFiProfileId::Away &&
       (!parsed.wifi.useTls || parsed.wifi.accessClientId[0] == '\0'))) {
    return false;
  }
  *controlOut = parsed;
  return true;
}

void normalizeLine(const char* line, char* out, size_t outSize) {
  if (outSize == 0) {
    return;
  }

  size_t i = 0;
  for (; line != nullptr && line[i] != '\0' && i + 1 < outSize; ++i) {
    char ch = static_cast<char>(tolower(static_cast<unsigned char>(line[i])));
    if (ch == '=' || ch == ':' || ch == ',' || ch == '\r' || ch == '\n') {
      ch = ' ';
    } else if (ch == '-') {
      const char next = static_cast<char>(line[i + 1]);
      if (!isdigit(static_cast<unsigned char>(next)) && next != '.') {
        ch = '_';
      }
    }
    out[i] = ch;
  }
  out[i] = '\0';
}

bool parseStrength(const char* token, float* strengthOut) {
  if (token == nullptr || token[0] == '\0') {
    return false;
  }

  char* end = nullptr;
  const float parsed = strtof(token, &end);
  if (end == token) {
    return false;
  }
  *strengthOut = constrain(parsed, 0.0f, 1.0f);
  return true;
}

bool parseDurationMs(const char* token, uint16_t* durationOut) {
  if (token == nullptr || token[0] == '\0') {
    return false;
  }

  char* end = nullptr;
  const long parsed = strtol(token, &end, 10);
  if (end == token) {
    return false;
  }
  *durationOut = static_cast<uint16_t>(constrain(parsed, 50L, 2000L));
  return true;
}

bool parseLux(const char* token, float* luxOut) {
  if (token == nullptr || token[0] == '\0') {
    return false;
  }

  char* end = nullptr;
  const float parsed = strtof(token, &end);
  if (end == token) {
    return false;
  }
  *luxOut = constrain(parsed, 0.0f, 2000.0f);
  return true;
}

bool parseHour(const char* token, uint8_t* hourOut) {
  if (token == nullptr || token[0] == '\0') {
    return false;
  }

  char* end = nullptr;
  const long parsed = strtol(token, &end, 10);
  if (end == token || parsed < 0 || parsed > 23) {
    return false;
  }
  *hourOut = static_cast<uint8_t>(parsed);
  return true;
}

bool parsePayloadValue(const char* token, float* valueOut) {
  if (token == nullptr || token[0] == '\0') {
    return false;
  }

  char* end = nullptr;
  const float parsed = strtof(token, &end);
  if (end == token) {
    return false;
  }
  *valueOut = constrain(parsed, -1.0f, 1.0f);
  return true;
}

bool parseAzimuthDeg(const char* token, float* valueOut) {
  if (token == nullptr || token[0] == '\0') {
    return false;
  }

  char* end = nullptr;
  const float parsed = strtof(token, &end);
  if (end == token) {
    return false;
  }
  *valueOut = constrain(parsed, -90.0f, 90.0f);
  return true;
}

bool parseViseme(const char* token, BenchSpeechViseme* visemeOut) {
  if (token == nullptr || token[0] == '\0') {
    return false;
  }

  if (strcmp(token, "ah") == 0 || strcmp(token, "a") == 0 || strcmp(token, "open") == 0) {
    *visemeOut = BenchSpeechViseme::Ah;
    return true;
  }
  if (strcmp(token, "oh") == 0 || strcmp(token, "o") == 0 || strcmp(token, "round") == 0) {
    *visemeOut = BenchSpeechViseme::Oh;
    return true;
  }
  if (strcmp(token, "ee") == 0 || strcmp(token, "e") == 0 || strcmp(token, "wide") == 0) {
    *visemeOut = BenchSpeechViseme::Ee;
    return true;
  }
  if (strcmp(token, "neutral") == 0 || strcmp(token, "n") == 0 || strcmp(token, "rest") == 0) {
    *visemeOut = BenchSpeechViseme::Neutral;
    return true;
  }
  return false;
}

bool parseSpeechIntentToken(const char* token, SpeechIntent* intentOut) {
  if (token == nullptr || intentOut == nullptr) {
    return false;
  }
  if (strcmp(token, "boot") == 0 || strcmp(token, "awake") == 0) {
    *intentOut = SpeechIntent::Boot;
    return true;
  }
  if (strcmp(token, "idle") == 0 || strcmp(token, "curiosity") == 0) {
    *intentOut = SpeechIntent::Idle;
    return true;
  }
  if (strcmp(token, "attend") == 0 || strcmp(token, "attention") == 0) {
    *intentOut = SpeechIntent::Attend;
    return true;
  }
  if (strcmp(token, "listen") == 0 || strcmp(token, "wake") == 0) {
    *intentOut = SpeechIntent::Listen;
    return true;
  }
  if (strcmp(token, "think") == 0 || strcmp(token, "thinking") == 0) {
    *intentOut = SpeechIntent::Think;
    return true;
  }
  if (strcmp(token, "speak") == 0 || strcmp(token, "talk") == 0 || strcmp(token, "response") == 0) {
    *intentOut = SpeechIntent::Speak;
    return true;
  }
  if (strcmp(token, "react") == 0 || strcmp(token, "display") == 0) {
    *intentOut = SpeechIntent::React;
    return true;
  }
  if (strcmp(token, "happy") == 0 || strcmp(token, "joy") == 0) {
    *intentOut = SpeechIntent::Happy;
    return true;
  }
  if (strcmp(token, "concern") == 0 || strcmp(token, "worried") == 0) {
    *intentOut = SpeechIntent::Concern;
    return true;
  }
  if (strcmp(token, "sleep") == 0 || strcmp(token, "sleepy") == 0) {
    *intentOut = SpeechIntent::Sleep;
    return true;
  }
  if (strcmp(token, "error") == 0 || strcmp(token, "problem") == 0) {
    *intentOut = SpeechIntent::Error;
    return true;
  }
  if (strcmp(token, "safety") == 0 || strcmp(token, "safe") == 0) {
    *intentOut = SpeechIntent::Safety;
    return true;
  }
  return false;
}

SpeechEarcon earconForSpeechIntent(SpeechIntent intent) {
  switch (intent) {
    case SpeechIntent::Boot:
    case SpeechIntent::Listen:
      return SpeechEarcon::Wake;
    case SpeechIntent::Idle:
    case SpeechIntent::Think:
      return SpeechEarcon::Think;
    case SpeechIntent::Attend:
    case SpeechIntent::Speak:
    case SpeechIntent::React:
      return SpeechEarcon::Confirm;
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
    case SpeechIntent::None:
      break;
  }
  return SpeechEarcon::None;
}

bool fillSpeechIntentCue(char** tokens, uint8_t tokenCount, BenchControl* controlOut) {
  if (tokens == nullptr || tokenCount == 0 || tokens[0] == nullptr) {
    return false;
  }

  SpeechIntent intent = SpeechIntent::None;
  if (!parseSpeechIntentToken(tokens[0], &intent)) {
    return false;
  }

  const SpeechPromptAsset& asset = SpeechPromptBank::find(intent);
  if (asset.source == PromptSource::None || asset.transcript[0] == '\0') {
    return false;
  }

  BenchControl parsed;
  parsed.hasSpeechCue = true;
  parsed.speechCue.intent = intent;
  parsed.speechCue.text = asset.transcript;
  parsed.speechCue.priority = 240;
  parsed.speechCue.earcon = earconForSpeechIntent(intent);
  parsed.speechCue.earconDelayMs = 60;
  parsed.command = "speak_intent";
  *controlOut = parsed;
  return true;
}

bool fillAudioEvent(const char* first, char** tokens, uint8_t tokenCount, uint32_t nowMs, BenchControl* controlOut) {
  BenchControl parsed;
  parsed.hasEvent = true;
  parsed.event.timestampMs = nowMs;
  parsed.event.strength = 1.0f;

  if (strcmp(first, "sound") == 0 || strcmp(first, "audio") == 0 ||
      strcmp(first, "voice") == 0) {
    float azimuthDeg = 0.0f;
    float level = 0.65f;
    bool hasDirection = false;

    if (tokenCount >= 1 && parseAzimuthDeg(tokens[0], &azimuthDeg)) {
      hasDirection = true;
      if (tokenCount >= 2) {
        parseStrength(tokens[1], &level);
      }
    }

    for (uint8_t i = 0; i + 1 < tokenCount; ++i) {
      if (strcmp(tokens[i], "dir") == 0 || strcmp(tokens[i], "direction") == 0 ||
          strcmp(tokens[i], "az") == 0 || strcmp(tokens[i], "azimuth") == 0 ||
          strcmp(tokens[i], "deg") == 0) {
        hasDirection = parseAzimuthDeg(tokens[i + 1], &azimuthDeg) || hasDirection;
      } else if (strcmp(tokens[i], "level") == 0 || strcmp(tokens[i], "strength") == 0 ||
                 strcmp(tokens[i], "energy") == 0) {
        parseStrength(tokens[i + 1], &level);
      }
    }

    if (!hasDirection) {
      return false;
    }

    parsed.mode = CharacterMode::Attend;
    parsed.event.type = EventType::SoundDirection;
    parsed.event.strength = level;
    parsed.event.hasPayload = true;
    parsed.event.x = azimuthDeg / 90.0f;
    parsed.event.z = level;
    parsed.command = "sound_direction";
    *controlOut = parsed;
    return true;
  }

  if (strcmp(first, "noise") == 0 || strcmp(first, "loud") == 0 ||
      strcmp(first, "bang") == 0 || strcmp(first, "clap") == 0) {
    float level = 1.0f;
    if (tokenCount >= 1) {
      parseStrength(tokens[0], &level);
    }
    for (uint8_t i = 0; i + 1 < tokenCount; ++i) {
      if (strcmp(tokens[i], "level") == 0 || strcmp(tokens[i], "strength") == 0 ||
          strcmp(tokens[i], "energy") == 0) {
        parseStrength(tokens[i + 1], &level);
      }
    }
    parsed.mode = CharacterMode::React;
    parsed.event.type = EventType::LoudNoise;
    parsed.event.strength = level;
    parsed.event.hasPayload = true;
    parsed.event.z = level;
    parsed.command = "loud_noise";
    *controlOut = parsed;
    return true;
  }

  return false;
}

bool fillAmbient(const char* first, char** tokens, uint8_t tokenCount, BenchControl* controlOut) {
  float lux = 0.0f;
  uint8_t hour = 12;
  bool hasLux = false;
  bool hasHour = false;

  if ((strcmp(first, "ambient") == 0 || strcmp(first, "light") == 0 ||
       strcmp(first, "lux") == 0 || strcmp(first, "amb") == 0) &&
      tokenCount >= 2 && parseLux(tokens[0], &lux) && parseHour(tokens[1], &hour)) {
    hasLux = true;
    hasHour = true;
  }

  for (uint8_t i = 0; i + 1 < tokenCount; ++i) {
    if (strcmp(tokens[i], "lux") == 0 || strcmp(tokens[i], "amb") == 0 || strcmp(tokens[i], "ambient") == 0) {
      hasLux = parseLux(tokens[i + 1], &lux) || hasLux;
    } else if (strcmp(tokens[i], "hour") == 0 || strcmp(tokens[i], "time") == 0) {
      hasHour = parseHour(tokens[i + 1], &hour) || hasHour;
    }
  }

  if (!hasLux || !hasHour) {
    return false;
  }

  BenchControl parsed;
  parsed.hasAmbient = true;
  parsed.ambient.lux = lux;
  parsed.ambient.hourOfDay = hour;
  parsed.command = "ambient_context";
  *controlOut = parsed;
  return true;
}

bool fillCircadian(char** tokens, uint8_t tokenCount, BenchControl* controlOut) {
  uint8_t hour = 12;
  bool hasHour = false;

  if (tokenCount >= 1) {
    hasHour = parseHour(tokens[0], &hour);
  }

  for (uint8_t i = 0; i + 1 < tokenCount; ++i) {
    if (strcmp(tokens[i], "hour") == 0 || strcmp(tokens[i], "time") == 0 ||
        strcmp(tokens[i], "clock") == 0) {
      hasHour = parseHour(tokens[i + 1], &hour) || hasHour;
    }
  }

  if (!hasHour) {
    return false;
  }

  BenchControl parsed;
  parsed.hasCircadian = true;
  parsed.hourOfDay = hour;
  parsed.command = "circadian_context";
  *controlOut = parsed;
  return true;
}

bool fillCommandEvent(char** tokens, uint8_t tokenCount, uint32_t nowMs, BenchControl* controlOut) {
  if (tokens == nullptr || tokenCount == 0 || tokens[0] == nullptr) {
    return false;
  }

  const SpokenCommandId commandId = CommandMap::fromToken(tokens[0]);
  const CommandMapResult action = CommandMap::map(commandId, nowMs);
  if (!action.valid) {
    return false;
  }

  BenchControl parsed;
  parsed.mode = action.mode;
  parsed.hasEvent = action.hasEvent;
  parsed.event = action.event;
  parsed.hasMotionEnable = action.hasMotionEnable;
  parsed.motionEnabled = action.motionEnabled;
  parsed.hasSpeechCue = action.hasSpeechCue;
  parsed.speechCue = action.speechCue;
  parsed.command = action.command;
  *controlOut = parsed;
  return true;
}

void copyBridgeLine(BenchControl* controlOut, const char* line) {
  BenchControl parsed;
  parsed.hasBridge = true;
  parsed.command = "bridge_control";
  strncpy(parsed.bridge.controlLine, line, sizeof(parsed.bridge.controlLine) - 1);
  parsed.bridge.controlLine[sizeof(parsed.bridge.controlLine) - 1] = '\0';
  *controlOut = parsed;
}

const char* bridgeIntentToken(SpeechIntent intent) {
  switch (intent) {
    case SpeechIntent::Boot:
      return "boot";
    case SpeechIntent::Idle:
      return "idle";
    case SpeechIntent::Attend:
      return "attend";
    case SpeechIntent::Listen:
      return "listen";
    case SpeechIntent::Think:
      return "think";
    case SpeechIntent::Speak:
      return "speak";
    case SpeechIntent::React:
      return "react";
    case SpeechIntent::Happy:
      return "happy";
    case SpeechIntent::Concern:
      return "concern";
    case SpeechIntent::Sleep:
      return "sleep";
    case SpeechIntent::Safety:
      return "safety";
    case SpeechIntent::Error:
      return "error";
    case SpeechIntent::None:
      break;
  }
  return "speak";
}

const char* bridgeVisemeToken(BenchSpeechViseme viseme) {
  switch (viseme) {
    case BenchSpeechViseme::Ah:
      return "ah";
    case BenchSpeechViseme::Oh:
      return "oh";
    case BenchSpeechViseme::Ee:
      return "ee";
    case BenchSpeechViseme::Neutral:
      return "neutral";
  }
  return "neutral";
}

bool parseUintToken(const char* token, uint32_t* valueOut) {
  if (token == nullptr || valueOut == nullptr || token[0] == '\0') {
    return false;
  }

  char* end = nullptr;
  const unsigned long parsed = strtoul(token, &end, 10);
  if (end == token) {
    return false;
  }
  *valueOut = static_cast<uint32_t>(parsed);
  return true;
}

bool parseUplinkWakeToken(const char* token, bool* wakeGateOpenOut) {
  if (token == nullptr || wakeGateOpenOut == nullptr) {
    return false;
  }
  if (strcmp(token, "wake") == 0 || strcmp(token, "open") == 0 ||
      strcmp(token, "gated") == 0 || strcmp(token, "allowed") == 0 ||
      strcmp(token, "1") == 0 || strcmp(token, "true") == 0) {
    *wakeGateOpenOut = true;
    return true;
  }
  if (strcmp(token, "closed") == 0 || strcmp(token, "blocked") == 0 ||
      strcmp(token, "nowake") == 0 || strcmp(token, "no_wake") == 0 ||
      strcmp(token, "0") == 0 || strcmp(token, "false") == 0) {
    *wakeGateOpenOut = false;
    return true;
  }
  return false;
}

void appendTextToken(char* out, size_t outSize, const char* token) {
  if (out == nullptr || outSize == 0 || token == nullptr || token[0] == '\0') {
    return;
  }

  const size_t used = strlen(out);
  if (used + 1 >= outSize) {
    return;
  }
  if (used > 0) {
    out[used] = ' ';
    out[used + 1] = '\0';
  }
  strncat(out, token, outSize - strlen(out) - 1);
}

bool fillBridgeUpload(char** tokens, uint8_t tokenCount, BenchControl* controlOut) {
  if (tokens == nullptr || tokenCount == 0 || tokens[0] == nullptr) {
    return false;
  }

  BenchControl parsed;
  parsed.hasBridgeUpload = true;
  parsed.command = "bridge_uplink";
  parsed.bridgeUpload.seq = 1;
  parsed.bridgeUpload.bytes = 160;
  parsed.bridgeUpload.wakeGateOpen = true;

  if (strcmp(tokens[0], "start") == 0 || strcmp(tokens[0], "begin") == 0 ||
      strcmp(tokens[0], "wake") == 0) {
    parsed.bridgeUpload.action = BenchBridgeUploadAction::Start;
    if (tokenCount >= 2) {
      parseUintToken(tokens[1], &parsed.bridgeUpload.seq);
    }
    for (uint8_t i = 1; i < tokenCount; ++i) {
      parseUplinkWakeToken(tokens[i], &parsed.bridgeUpload.wakeGateOpen);
    }
    *controlOut = parsed;
    return true;
  }

  if (strcmp(tokens[0], "chunk") == 0 || strcmp(tokens[0], "audio") == 0 ||
      strcmp(tokens[0], "pcm") == 0 || strcmp(tokens[0], "bytes") == 0) {
    parsed.bridgeUpload.action = BenchBridgeUploadAction::Chunk;
    if (tokenCount >= 2) {
      parseUintToken(tokens[1], &parsed.bridgeUpload.seq);
    }
    uint32_t bytes = parsed.bridgeUpload.bytes;
    if (tokenCount >= 3 && parseUintToken(tokens[2], &bytes)) {
      parsed.bridgeUpload.bytes = static_cast<uint16_t>(constrain(static_cast<long>(bytes), 2L, 512L));
      if ((parsed.bridgeUpload.bytes & 1u) != 0) {
        parsed.bridgeUpload.bytes++;
      }
    }
    *controlOut = parsed;
    return true;
  }

  if (strcmp(tokens[0], "end") == 0 || strcmp(tokens[0], "done") == 0 ||
      strcmp(tokens[0], "finish") == 0) {
    parsed.bridgeUpload.action = BenchBridgeUploadAction::End;
    if (tokenCount >= 2) {
      parseUintToken(tokens[1], &parsed.bridgeUpload.seq);
    }
    *controlOut = parsed;
    return true;
  }

  if (strcmp(tokens[0], "abort") == 0 || strcmp(tokens[0], "cancel") == 0 ||
      strcmp(tokens[0], "stop") == 0) {
    parsed.bridgeUpload.action = BenchBridgeUploadAction::Abort;
    *controlOut = parsed;
    return true;
  }

  return false;
}

bool fillBridgeTextTurn(char** tokens, uint8_t tokenCount, BenchControl* controlOut) {
  if (tokens == nullptr || tokenCount == 0 || tokens[0] == nullptr || controlOut == nullptr) {
    return false;
  }

  uint8_t textStart = 0;
  if (strcmp(tokens[0], "turn") == 0 || strcmp(tokens[0], "text") == 0 ||
      strcmp(tokens[0], "ask") == 0 || strcmp(tokens[0], "say") == 0) {
    textStart = 1;
  }

  BenchControl parsed;
  parsed.hasBridgeTextTurn = true;
  parsed.command = "bridge_text_turn";
  parsed.bridgeTextTurn.seq = millis();

  if (textStart < tokenCount && parseUintToken(tokens[textStart], &parsed.bridgeTextTurn.seq)) {
    textStart++;
  }

  for (uint8_t i = textStart; i < tokenCount; ++i) {
    appendTextToken(parsed.bridgeTextTurn.text, sizeof(parsed.bridgeTextTurn.text), tokens[i]);
  }
  if (parsed.bridgeTextTurn.text[0] == '\0') {
    strncpy(parsed.bridgeTextTurn.text, "hello stackchan", sizeof(parsed.bridgeTextTurn.text) - 1);
  }

  *controlOut = parsed;
  return true;
}

bool fillPairingControl(const char* first, char** tokens, uint8_t tokenCount, BenchControl* controlOut) {
  if (controlOut == nullptr) {
    return false;
  }

  const char* action = tokenCount >= 1 ? tokens[0] : "";
  const char* code = tokenCount >= 2 ? tokens[1] : nullptr;
  if (strcmp(first, "pair") == 0 && tokenCount >= 1 &&
      strcmp(action, "code") != 0 && strcmp(action, "set") != 0 &&
      strcmp(action, "require") != 0 && strcmp(action, "clear") != 0 &&
      strcmp(action, "off") != 0 && strcmp(action, "none") != 0 &&
      strcmp(action, "ticket") != 0 && strcmp(action, "qr") != 0 &&
      strcmp(action, "scan") != 0) {
    code = action;
    action = "code";
  }

  BenchControl parsed;
  parsed.hasPairingControl = true;
  parsed.command = "pairing_code";
  if (strcmp(action, "clear") == 0 || strcmp(action, "off") == 0 ||
      strcmp(action, "none") == 0 || strcmp(action, "disable") == 0) {
    parsed.pairing.clear = true;
    *controlOut = parsed;
    return true;
  }
  if ((strcmp(action, "code") == 0 || strcmp(action, "set") == 0 ||
       strcmp(action, "require") == 0) &&
      code != nullptr && strlen(code) == 6) {
    strncpy(parsed.pairing.code, code, sizeof(parsed.pairing.code) - 1);
    parsed.pairing.code[sizeof(parsed.pairing.code) - 1] = '\0';
    *controlOut = parsed;
    return true;
  }
  return false;
}

bool fillBridgeControl(char** tokens, uint8_t tokenCount, BenchControl* controlOut) {
  if (tokens == nullptr || tokenCount == 0 || tokens[0] == nullptr) {
    return false;
  }

  char line[192] = {};
  if (strcmp(tokens[0], "hello") == 0 || strcmp(tokens[0], "connect") == 0) {
    const char* session = tokenCount >= 2 ? tokens[1] : "bench";
    snprintf(line, sizeof(line), "{\"type\":\"hello\",\"session\":\"%s\"}", session);
    copyBridgeLine(controlOut, line);
    return true;
  }

  if (strcmp(tokens[0], "listen") == 0 || strcmp(tokens[0], "listening") == 0) {
    snprintf(line, sizeof(line), "{\"type\":\"listening\"}");
    copyBridgeLine(controlOut, line);
    return true;
  }

  if (strcmp(tokens[0], "think") == 0 || strcmp(tokens[0], "thinking") == 0) {
    uint32_t seq = 1;
    if (tokenCount >= 2) {
      parseUintToken(tokens[1], &seq);
    }
    snprintf(line, sizeof(line), "{\"type\":\"thinking\",\"seq\":%lu}", static_cast<unsigned long>(seq));
    copyBridgeLine(controlOut, line);
    return true;
  }

  if (strcmp(tokens[0], "response") == 0 || strcmp(tokens[0], "response_start") == 0 ||
      strcmp(tokens[0], "say") == 0) {
    SpeechIntent intent = SpeechIntent::Speak;
    uint8_t textStart = 1;
    if (tokenCount >= 2 && parseSpeechIntentToken(tokens[1], &intent)) {
      textStart = 2;
    }
    uint32_t seq = 1;
    if (textStart < tokenCount && parseUintToken(tokens[textStart], &seq)) {
      textStart++;
    }

    char text[80] = {};
    for (uint8_t i = textStart; i < tokenCount; ++i) {
      appendTextToken(text, sizeof(text), tokens[i]);
    }
    if (text[0] == '\0') {
      strncpy(text, "hello i am awake", sizeof(text) - 1);
    }

    snprintf(line,
             sizeof(line),
             "{\"type\":\"response_start\",\"seq\":%lu,\"intent\":\"%s\",\"arousal\":0.55,\"valence\":0.60,\"text\":\"%s\"}",
             static_cast<unsigned long>(seq),
             bridgeIntentToken(intent),
             text);
    copyBridgeLine(controlOut, line);
    return true;
  }

  if (strcmp(tokens[0], "audio") == 0 || strcmp(tokens[0], "mouth") == 0) {
    if (tokenCount < 2) {
      return false;
    }
    float envelope = 0.0f;
    if (!parseStrength(tokens[1], &envelope)) {
      return false;
    }
    BenchSpeechViseme viseme = BenchSpeechViseme::Ah;
    if (tokenCount >= 3 && !parseViseme(tokens[2], &viseme)) {
      return false;
    }
    uint16_t durationMs = 20;
    if (tokenCount >= 4) {
      parseDurationMs(tokens[3], &durationMs);
      durationMs = static_cast<uint16_t>(constrain(static_cast<long>(durationMs), 10L, 200L));
    }
    const bool finalChunk = tokenCount >= 5 &&
                            (strcmp(tokens[4], "final") == 0 || strcmp(tokens[4], "end") == 0 ||
                             strcmp(tokens[4], "true") == 0 || strcmp(tokens[4], "1") == 0);
    snprintf(line,
             sizeof(line),
             "{\"type\":\"audio\",\"seq\":1,\"env\":%.2f,\"viseme\":\"%s\",\"duration_ms\":%u,\"final\":%s}",
             envelope,
             bridgeVisemeToken(viseme),
             durationMs,
             finalChunk ? "true" : "false");
    copyBridgeLine(controlOut, line);
    return true;
  }

  if (strcmp(tokens[0], "end") == 0 || strcmp(tokens[0], "response_end") == 0 ||
      strcmp(tokens[0], "done") == 0) {
    uint32_t seq = 1;
    if (tokenCount >= 2) {
      parseUintToken(tokens[1], &seq);
    }
    snprintf(line, sizeof(line), "{\"type\":\"response_end\",\"seq\":%lu}", static_cast<unsigned long>(seq));
    copyBridgeLine(controlOut, line);
    return true;
  }

  if (strcmp(tokens[0], "heartbeat") == 0 || strcmp(tokens[0], "ping") == 0) {
    snprintf(line, sizeof(line), "{\"type\":\"heartbeat\"}");
    copyBridgeLine(controlOut, line);
    return true;
  }

  if (strcmp(tokens[0], "error") == 0 || strcmp(tokens[0], "fail") == 0) {
    const char* code = tokenCount >= 2 ? tokens[1] : "bench_error";
    snprintf(line, sizeof(line), "{\"type\":\"error\",\"code\":\"%s\"}", code);
    copyBridgeLine(controlOut, line);
    return true;
  }

  return false;
}

bool fillVisionEvent(const char* first, char** tokens, uint8_t tokenCount, uint32_t nowMs, BenchControl* controlOut) {
  BenchControl parsed;
  parsed.hasEvent = true;
  parsed.event.timestampMs = nowMs;
  parsed.event.strength = 1.0f;

  if (strcmp(first, "facelost") == 0 || strcmp(first, "face_lost") == 0 ||
      strcmp(first, "lostface") == 0) {
    parsed.mode = CharacterMode::Idle;
    parsed.event.type = EventType::FaceLost;
    parsed.command = "face_lost";
    *controlOut = parsed;
    return true;
  }

  if (strcmp(first, "facepos") != 0 && strcmp(first, "face_pos") != 0) {
    return false;
  }

  bool hasX = false;
  bool hasY = false;
  bool hasSize = false;
  float size = 0.55f;

  if (tokenCount >= 3 && parsePayloadValue(tokens[0], &parsed.event.x) &&
      parsePayloadValue(tokens[1], &parsed.event.y) && parseStrength(tokens[2], &size)) {
    hasX = true;
    hasY = true;
    hasSize = true;
  }

  for (uint8_t i = 0; i + 1 < tokenCount; ++i) {
    if (strcmp(tokens[i], "x") == 0) {
      hasX = parsePayloadValue(tokens[i + 1], &parsed.event.x) || hasX;
    } else if (strcmp(tokens[i], "y") == 0) {
      hasY = parsePayloadValue(tokens[i + 1], &parsed.event.y) || hasY;
    } else if (strcmp(tokens[i], "s") == 0 || strcmp(tokens[i], "size") == 0 ||
               strcmp(tokens[i], "z") == 0) {
      hasSize = parseStrength(tokens[i + 1], &size) || hasSize;
    } else if (strcmp(tokens[i], "strength") == 0) {
      parseStrength(tokens[i + 1], &parsed.event.strength);
    }
  }

  if (!hasX || !hasY || !hasSize) {
    return false;
  }

  parsed.mode = CharacterMode::Attend;
  parsed.event.type = EventType::FaceDetected;
  parsed.event.hasPayload = true;
  parsed.event.z = size;
  parsed.command = "face_position";
  *controlOut = parsed;
  return true;
}

bool fillPhysicalEvent(const char* first, char** tokens, uint8_t tokenCount, uint32_t nowMs, BenchControl* controlOut) {
  BenchControl parsed;
  parsed.hasEvent = true;
  parsed.event.timestampMs = nowMs;
  parsed.event.strength = 1.0f;

  if (strcmp(first, "touch") == 0 || strcmp(first, "touched") == 0 ||
      strcmp(first, "poke") == 0 || strcmp(first, "pat") == 0) {
    if (strcmp(first, "poke") == 0) {
      parsed.event.strength = 1.0f;
      parsed.event.hasPayload = true;
      parsed.event.y = 0.0f;
    } else if (strcmp(first, "pat") == 0) {
      parsed.event.strength = 0.65f;
      parsed.event.hasPayload = true;
      parsed.event.y = -0.75f;
    }

    if (tokenCount >= 1 && tokens[0] != nullptr) {
      if (strcmp(tokens[0], "cheek") == 0 || strcmp(tokens[0], "right_cheek") == 0) {
        parsed.event.hasPayload = true;
        parsed.event.x = 0.55f;
        parsed.event.y = 0.55f;
      } else if (strcmp(tokens[0], "left_cheek") == 0) {
        parsed.event.hasPayload = true;
        parsed.event.x = -0.55f;
        parsed.event.y = 0.55f;
      } else if (strcmp(tokens[0], "forehead") == 0 || strcmp(tokens[0], "head") == 0) {
        parsed.event.hasPayload = true;
        parsed.event.x = 0.0f;
        parsed.event.y = -0.75f;
      } else if (strcmp(tokens[0], "poke") == 0) {
        parsed.event.strength = 1.0f;
      } else if (tokenCount >= 2 && parsePayloadValue(tokens[0], &parsed.event.x) &&
                 parsePayloadValue(tokens[1], &parsed.event.y)) {
        parsed.event.hasPayload = true;
        if (tokenCount >= 3) {
          parseStrength(tokens[2], &parsed.event.strength);
        }
      } else {
        return false;
      }
    }

    parsed.mode = CharacterMode::React;
    parsed.event.type = EventType::UserTouched;
    parsed.command = parsed.event.hasPayload ? "touch_payload" : "event_touch";
    *controlOut = parsed;
    return true;
  }

  if (strcmp(first, "proximity") == 0 || strcmp(first, "prox") == 0) {
    if (tokenCount >= 1 && !parseStrength(tokens[0], &parsed.event.strength)) {
      return false;
    }
    parsed.mode = CharacterMode::Attend;
    parsed.event.type = EventType::UserNear;
    parsed.event.hasPayload = true;
    parsed.event.z = parsed.event.strength;
    parsed.command = "proximity_near";
    *controlOut = parsed;
    return true;
  }

  if (strcmp(first, "pickup") == 0 || strcmp(first, "pickedup") == 0 ||
      strcmp(first, "picked_up") == 0 || strcmp(first, "lift") == 0 ||
      strcmp(first, "lifted") == 0) {
    if (tokenCount >= 1) {
      parseStrength(tokens[0], &parsed.event.strength);
    }
    parsed.mode = CharacterMode::React;
    parsed.event.type = EventType::PickedUp;
    parsed.event.hasPayload = true;
    parsed.event.z = 1.0f;
    parsed.command = "event_picked_up";
    *controlOut = parsed;
    return true;
  }

  if (strcmp(first, "shake") == 0 || strcmp(first, "shaken") == 0) {
    if (tokenCount >= 1) {
      parseStrength(tokens[0], &parsed.event.strength);
    }
    parsed.mode = CharacterMode::Error;
    parsed.event.type = EventType::Shaken;
    parsed.event.hasPayload = true;
    parsed.event.z = parsed.event.strength;
    parsed.hasMotionEnable = true;
    parsed.motionEnabled = false;
    parsed.command = "event_shaken_hold";
    *controlOut = parsed;
    return true;
  }

  if (strcmp(first, "putdown") == 0 || strcmp(first, "put_down") == 0 ||
      strcmp(first, "settled") == 0) {
    parsed.mode = CharacterMode::Attend;
    parsed.event.type = EventType::PutDown;
    parsed.event.hasPayload = true;
    parsed.event.z = 0.0f;
    parsed.hasMotionEnable = true;
    parsed.motionEnabled = true;
    parsed.command = "event_put_down_resume";
    *controlOut = parsed;
    return true;
  }

  if (strcmp(first, "tilt") == 0 || strcmp(first, "tilted") == 0) {
    bool hasX = false;
    bool hasY = false;
    bool hasZ = false;
    if (tokenCount >= 3 && parsePayloadValue(tokens[0], &parsed.event.x) &&
        parsePayloadValue(tokens[1], &parsed.event.y) &&
        parsePayloadValue(tokens[2], &parsed.event.z)) {
      hasX = true;
      hasY = true;
      hasZ = true;
    }
    for (uint8_t i = 0; i + 1 < tokenCount; ++i) {
      if (strcmp(tokens[i], "x") == 0) {
        hasX = parsePayloadValue(tokens[i + 1], &parsed.event.x) || hasX;
      } else if (strcmp(tokens[i], "y") == 0) {
        hasY = parsePayloadValue(tokens[i + 1], &parsed.event.y) || hasY;
      } else if (strcmp(tokens[i], "z") == 0) {
        hasZ = parsePayloadValue(tokens[i + 1], &parsed.event.z) || hasZ;
      } else if (strcmp(tokens[i], "strength") == 0 || strcmp(tokens[i], "level") == 0) {
        parseStrength(tokens[i + 1], &parsed.event.strength);
      }
    }
    if (!hasX || !hasY || !hasZ) {
      return false;
    }
    parsed.mode = CharacterMode::React;
    parsed.event.type = EventType::Tilted;
    parsed.event.hasPayload = true;
    parsed.command = "event_tilted";
    *controlOut = parsed;
    return true;
  }

  return false;
}

bool parseOnOff(const char* token, bool* valueOut) {
  if (token == nullptr || token[0] == '\0') {
    return false;
  }

  if (strcmp(token, "on") == 0 || strcmp(token, "1") == 0 || strcmp(token, "true") == 0 ||
      strcmp(token, "yes") == 0 || strcmp(token, "reduced") == 0 ||
      strcmp(token, "resume") == 0 || strcmp(token, "start") == 0 ||
      strcmp(token, "enable") == 0 || strcmp(token, "enabled") == 0) {
    *valueOut = true;
    return true;
  }
  if (strcmp(token, "off") == 0 || strcmp(token, "0") == 0 || strcmp(token, "false") == 0 ||
      strcmp(token, "no") == 0 || strcmp(token, "full") == 0 || strcmp(token, "normal") == 0 ||
      strcmp(token, "stop") == 0 || strcmp(token, "halt") == 0 ||
      strcmp(token, "pause") == 0 || strcmp(token, "paused") == 0 ||
      strcmp(token, "disable") == 0 || strcmp(token, "disabled") == 0) {
    *valueOut = false;
    return true;
  }
  return false;
}

bool fillReducedMotion(const char* valueToken, BenchControl* controlOut) {
  bool enabled = false;
  if (!parseOnOff(valueToken, &enabled)) {
    return false;
  }

  BenchControl parsed;
  parsed.hasReducedMotion = true;
  parsed.reducedMotion = enabled;
  parsed.command = enabled ? "reduced_motion_on" : "reduced_motion_off";
  *controlOut = parsed;
  return true;
}

bool fillMotionEnable(const char* valueToken, BenchControl* controlOut) {
  bool enabled = true;
  if (!parseOnOff(valueToken, &enabled)) {
    return false;
  }

  BenchControl parsed;
  parsed.hasMotionEnable = true;
  parsed.motionEnabled = enabled;
  parsed.command = enabled ? "motion_resume" : "motion_stop";
  *controlOut = parsed;
  return true;
}

bool fillDemoEnable(const char* valueToken, BenchControl* controlOut) {
  bool enabled = true;
  if (!parseOnOff(valueToken, &enabled)) {
    return false;
  }

  BenchControl parsed;
  parsed.hasDemoEnable = true;
  parsed.demoEnabled = enabled;
  parsed.command = enabled ? "demo_on" : "demo_off";
  *controlOut = parsed;
  return true;
}

bool fillSafeStop(BenchControl* controlOut) {
  BenchControl parsed;
  parsed.hasReducedMotion = true;
  parsed.hasMotionEnable = true;
  parsed.hasDemoEnable = true;
  parsed.hasSpeech = true;
  parsed.reducedMotion = true;
  parsed.motionEnabled = false;
  parsed.demoEnabled = false;
  parsed.speech.clear = true;
  parsed.speech.envelope = 0.0f;
  parsed.speech.viseme = BenchSpeechViseme::Neutral;
  parsed.command = "safe_stop";
  *controlOut = parsed;
  return true;
}

bool fillSafeResume(BenchControl* controlOut) {
  BenchControl parsed;
  parsed.hasReducedMotion = true;
  parsed.hasMotionEnable = true;
  parsed.hasDemoEnable = true;
  parsed.hasSpeech = true;
  parsed.reducedMotion = false;
  parsed.motionEnabled = true;
  parsed.demoEnabled = true;
  parsed.speech.clear = true;
  parsed.speech.envelope = 0.0f;
  parsed.speech.viseme = BenchSpeechViseme::Neutral;
  parsed.command = "safe_resume";
  *controlOut = parsed;
  return true;
}

bool fillSpeakerTest(BenchControl* controlOut) {
  BenchControl parsed;
  parsed.hasSpeakerTest = true;
  parsed.command = "speaker_test";
  *controlOut = parsed;
  return true;
}

bool fillMicCueTest(BenchControl* controlOut) {
  BenchControl parsed;
  parsed.hasMicCueTest = true;
  parsed.command = "mic_cue_test";
  *controlOut = parsed;
  return true;
}

bool fillFromMode(const char* token, uint32_t nowMs, float strength, BenchControl* controlOut) {
  for (const ModeCommand& command : kModeCommands) {
    if (strcmp(token, command.name) != 0) {
      continue;
    }

    controlOut->mode = command.mode;
    controlOut->event.type = command.event;
    controlOut->event.timestampMs = nowMs;
    controlOut->event.strength = strength;
    controlOut->hasEvent = true;
    controlOut->command = command.command;
    return true;
  }
  return false;
}

bool fillFromEvent(const char* token, uint32_t nowMs, float strength, BenchControl* controlOut) {
  for (const EventCommand& command : kEventCommands) {
    if (strcmp(token, command.name) != 0) {
      continue;
    }

    controlOut->mode = command.mode;
    controlOut->event.type = command.event;
    controlOut->event.timestampMs = nowMs;
    controlOut->event.strength = strength;
    controlOut->hasEvent = true;
    controlOut->command = command.command;
    return true;
  }
  return false;
}

bool fillFromSpeech(char* envelopeToken, char* visemeToken, char* durationToken, uint32_t nowMs, BenchControl* controlOut) {
  if (envelopeToken == nullptr) {
    return false;
  }

  BenchControl parsed;
  parsed.hasSpeech = true;
  parsed.hasEvent = true;
  parsed.mode = CharacterMode::Speak;
  parsed.event.type = EventType::ResponseStarted;
  parsed.event.timestampMs = nowMs;
  parsed.event.strength = 1.0f;
  parsed.command = "speech_env";

  if (strcmp(envelopeToken, "clear") == 0 || strcmp(envelopeToken, "off") == 0 || strcmp(envelopeToken, "stop") == 0) {
    parsed.mode = CharacterMode::Idle;
    parsed.event.type = EventType::SpeechEnded;
    parsed.speech.clear = true;
    parsed.speech.envelope = 0.0f;
    parsed.speech.viseme = BenchSpeechViseme::Neutral;
    parsed.command = "speech_clear";
    *controlOut = parsed;
    return true;
  }

  float envelope = 0.0f;
  if (!parseStrength(envelopeToken, &envelope)) {
    return false;
  }

  BenchSpeechViseme viseme = BenchSpeechViseme::Ah;
  uint16_t durationMs = 600;
  if (visemeToken != nullptr && !parseViseme(visemeToken, &viseme)) {
    if (!parseDurationMs(visemeToken, &durationMs)) {
      return false;
    }
    visemeToken = nullptr;
  }
  parseDurationMs(durationToken, &durationMs);

  parsed.speech.envelope = envelope;
  parsed.speech.viseme = viseme;
  parsed.speech.durationMs = durationMs;
  *controlOut = parsed;
  return true;
}

void fillHardwareEvent(CharacterMode mode, EventType eventType, uint32_t nowMs, const char* command, BenchControl* controlOut) {
  BenchControl parsed;
  parsed.hasEvent = true;
  parsed.mode = mode;
  parsed.event.type = eventType;
  parsed.event.timestampMs = nowMs;
  parsed.event.strength = 1.0f;
  parsed.command = command;
  *controlOut = parsed;
}

}  // namespace

bool parseBenchControlLine(const char* line, uint32_t nowMs, BenchControl* controlOut) {
  if (line == nullptr || controlOut == nullptr) {
    return false;
  }

  if (fillPairingTicketControlRaw(line, controlOut)) {
    return true;
  }

  if (fillWiFiProvisioningControlRaw(line, controlOut)) {
    return true;
  }

  char normalized[192] = {};
  normalizeLine(line, normalized, sizeof(normalized));

  char* first = strtok(normalized, " \t");
  if (first == nullptr) {
    return false;
  }
  if (isHelpToken(first)) {
    return fillHelp(controlOut);
  }
  if (strcmp(first, "status") == 0 || strcmp(first, "telemetry") == 0 || strcmp(first, "health") == 0) {
    return fillStatus(controlOut);
  }

  char* tokens[12] = {};
  uint8_t tokenCount = 0;
  while (tokenCount < 12) {
    char* tokenPart = strtok(nullptr, " \t");
    if (tokenPart == nullptr) {
      break;
    }
    tokens[tokenCount++] = tokenPart;
  }

  char* second = tokenCount >= 1 ? tokens[0] : nullptr;
  char* third = tokenCount >= 2 ? tokens[1] : nullptr;
  char* fourth = tokenCount >= 3 ? tokens[2] : nullptr;

  bool forceMode = false;
  bool forceEvent = false;
  bool forceSpeech = false;
  const char* token = first;
  const char* strengthToken = second;

  if (strcmp(first, "mode") == 0 || strcmp(first, "m") == 0) {
    forceMode = true;
    token = second;
    strengthToken = third;
  } else if (strcmp(first, "event") == 0 || strcmp(first, "e") == 0) {
    forceEvent = true;
    token = second;
    strengthToken = third;
  } else if (strcmp(first, "speech") == 0 || strcmp(first, "mouth") == 0 || strcmp(first, "env") == 0) {
    forceSpeech = true;
  }

  if (forceSpeech) {
    return fillFromSpeech(second, third, fourth, nowMs, controlOut);
  }

  char** ambientTokens = tokens;
  const uint8_t ambientTokenCount = tokenCount;
  if (strcmp(first, "ambient") == 0 || strcmp(first, "light") == 0 ||
      strcmp(first, "lux") == 0 || strcmp(first, "amb") == 0) {
    return fillAmbient(first, ambientTokens, ambientTokenCount, controlOut);
  }
  if (strcmp(first, "time") == 0 || strcmp(first, "hour") == 0 ||
      strcmp(first, "clock") == 0 || strcmp(first, "circadian") == 0) {
    return fillCircadian(ambientTokens, ambientTokenCount, controlOut);
  }
  if (strcmp(first, "command") == 0 || strcmp(first, "cmd") == 0 ||
      strcmp(first, "multinet") == 0 || strcmp(first, "phrase") == 0) {
    return fillCommandEvent(ambientTokens, ambientTokenCount, nowMs, controlOut);
  }
  if (strcmp(first, "uplink") == 0 || strcmp(first, "micupload") == 0 ||
      strcmp(first, "upload") == 0) {
    return fillBridgeUpload(ambientTokens, ambientTokenCount, controlOut);
  }
  if (strcmp(first, "brain") == 0 || strcmp(first, "pcbrain") == 0 ||
      strcmp(first, "pc_brain") == 0) {
    return fillBridgeTextTurn(ambientTokens, ambientTokenCount, controlOut);
  }
  if (strcmp(first, "pairing") == 0 || strcmp(first, "pair") == 0) {
    return fillPairingControl(first, ambientTokens, ambientTokenCount, controlOut);
  }
  if ((strcmp(first, "bridge") == 0 || strcmp(first, "conversation") == 0 ||
       strcmp(first, "conv") == 0) &&
      second != nullptr &&
      (strcmp(second, "upload") == 0 || strcmp(second, "uplink") == 0 ||
       strcmp(second, "mic") == 0)) {
    return fillBridgeUpload(&ambientTokens[1], ambientTokenCount - 1u, controlOut);
  }
  if ((strcmp(first, "bridge") == 0 || strcmp(first, "conversation") == 0 ||
       strcmp(first, "conv") == 0) &&
      second != nullptr &&
      (strcmp(second, "turn") == 0 || strcmp(second, "text") == 0 ||
       strcmp(second, "ask") == 0 || strcmp(second, "brain") == 0)) {
    return fillBridgeTextTurn(&ambientTokens[1], ambientTokenCount - 1u, controlOut);
  }
  if (strcmp(first, "bridge") == 0 || strcmp(first, "conversation") == 0 ||
      strcmp(first, "conv") == 0) {
    return fillBridgeControl(ambientTokens, ambientTokenCount, controlOut);
  }
  if (strcmp(first, "speak") == 0 || strcmp(first, "say") == 0 ||
      strcmp(first, "speechcue") == 0 || strcmp(first, "cue") == 0) {
    if (fillSpeechIntentCue(ambientTokens, ambientTokenCount, controlOut)) {
      return true;
    }
    float ignoredStrength = 0.0f;
    if (strcmp(first, "speak") != 0 || (second != nullptr && !parseStrength(second, &ignoredStrength))) {
      return false;
    }
  }
  if (strcmp(first, "facepos") == 0 || strcmp(first, "face_pos") == 0 ||
      strcmp(first, "facelost") == 0 ||
      strcmp(first, "face_lost") == 0 || strcmp(first, "lostface") == 0) {
    return fillVisionEvent(first, ambientTokens, ambientTokenCount, nowMs, controlOut);
  }
  if (strcmp(first, "sound") == 0 || strcmp(first, "audio") == 0 ||
      strcmp(first, "voice") == 0 || strcmp(first, "noise") == 0 ||
      strcmp(first, "loud") == 0 || strcmp(first, "bang") == 0 ||
      strcmp(first, "clap") == 0) {
    return fillAudioEvent(first, ambientTokens, ambientTokenCount, nowMs, controlOut);
  }
  if (strcmp(first, "touch") == 0 || strcmp(first, "touched") == 0 ||
      strcmp(first, "poke") == 0 || strcmp(first, "pat") == 0 ||
      strcmp(first, "proximity") == 0 || strcmp(first, "prox") == 0 ||
      strcmp(first, "pickup") == 0 || strcmp(first, "pickedup") == 0 ||
      strcmp(first, "picked_up") == 0 || strcmp(first, "lift") == 0 ||
      strcmp(first, "lifted") == 0 || strcmp(first, "shake") == 0 ||
      strcmp(first, "shaken") == 0 || strcmp(first, "putdown") == 0 ||
      strcmp(first, "put_down") == 0 || strcmp(first, "settled") == 0 ||
      strcmp(first, "tilt") == 0 || strcmp(first, "tilted") == 0) {
    return fillPhysicalEvent(first, ambientTokens, ambientTokenCount, nowMs, controlOut);
  }

  if (strcmp(first, "reduced") == 0 || strcmp(first, "reduced_motion") == 0 ||
      strcmp(first, "reducedmotion") == 0 || strcmp(first, "calm") == 0) {
    return fillReducedMotion(second, controlOut);
  }
  if (strcmp(first, "motion") == 0 && second != nullptr &&
      (strcmp(second, "reduced") == 0 || strcmp(second, "reduced_motion") == 0 ||
       strcmp(second, "reducedmotion") == 0)) {
    return fillReducedMotion(third, controlOut);
  }
  if ((strcmp(first, "motion") == 0 || strcmp(first, "servo") == 0 || strcmp(first, "servos") == 0) &&
      second != nullptr &&
      (strcmp(second, "stop") == 0 || strcmp(second, "off") == 0 || strcmp(second, "disable") == 0 ||
       strcmp(second, "disabled") == 0 || strcmp(second, "resume") == 0 || strcmp(second, "on") == 0 ||
       strcmp(second, "enable") == 0 || strcmp(second, "enabled") == 0)) {
    return fillMotionEnable(second, controlOut);
  }
  if (strcmp(first, "stop") == 0 || strcmp(first, "halt") == 0 || strcmp(first, "freeze") == 0) {
    return fillMotionEnable("off", controlOut);
  }
  if (strcmp(first, "resume") == 0) {
    return fillMotionEnable("on", controlOut);
  }
  if (strcmp(first, "demo") == 0 && second != nullptr) {
    return fillDemoEnable(second, controlOut);
  }
  if ((strcmp(first, "speaker") == 0 || strcmp(first, "audio") == 0) &&
      second != nullptr &&
      (strcmp(second, "cue") == 0 || strcmp(second, "soft") == 0 || strcmp(second, "mic") == 0)) {
    return fillMicCueTest(controlOut);
  }
  if ((strcmp(first, "mic") == 0 || strcmp(first, "microphone") == 0) &&
      second != nullptr &&
      (strcmp(second, "cue") == 0 || strcmp(second, "tone") == 0 || strcmp(second, "test") == 0)) {
    return fillMicCueTest(controlOut);
  }
  if (strcmp(first, "cue") == 0 && (second == nullptr || strcmp(second, "soft") == 0)) {
    return fillMicCueTest(controlOut);
  }
  if ((strcmp(first, "speaker") == 0 || strcmp(first, "audio") == 0) &&
      second != nullptr &&
      (strcmp(second, "test") == 0 || strcmp(second, "beep") == 0 || strcmp(second, "tone") == 0)) {
    return fillSpeakerTest(controlOut);
  }
  if (strcmp(first, "beep") == 0 || strcmp(first, "tone") == 0) {
    return fillSpeakerTest(controlOut);
  }
  if (strcmp(first, "panic") == 0 || strcmp(first, "estop") == 0 ||
      strcmp(first, "e_stop") == 0 || strcmp(first, "all_stop") == 0 ||
      strcmp(first, "safestop") == 0 ||
      (strcmp(first, "safe") == 0 && (second == nullptr || strcmp(second, "stop") == 0)) ||
      (strcmp(first, "all") == 0 && second != nullptr && strcmp(second, "stop") == 0)) {
    return fillSafeStop(controlOut);
  }
  if (strcmp(first, "restore") == 0 || strcmp(first, "recover") == 0 || strcmp(first, "normal") == 0 ||
      strcmp(first, "safe_resume") == 0 || strcmp(first, "saferesume") == 0 ||
      (strcmp(first, "safe") == 0 && second != nullptr &&
       (strcmp(second, "resume") == 0 || strcmp(second, "normal") == 0 ||
        strcmp(second, "restore") == 0)) ||
      (strcmp(first, "all") == 0 && second != nullptr && strcmp(second, "resume") == 0)) {
    return fillSafeResume(controlOut);
  }

  if (token == nullptr || isHelpToken(token)) {
    return false;
  }

  float strength = 1.0f;
  parseStrength(strengthToken, &strength);

  BenchControl parsed;
  if (forceMode) {
    if (!fillFromMode(token, nowMs, strength, &parsed)) {
      return false;
    }
  } else if (forceEvent) {
    if (!fillFromEvent(token, nowMs, strength, &parsed)) {
      return false;
    }
  } else if (!fillFromMode(token, nowMs, strength, &parsed) &&
             !fillFromEvent(token, nowMs, strength, &parsed)) {
    return false;
  }

  *controlOut = parsed;
  return true;
}

void SensorAdapter::printHelp() const {
#if defined(ARDUINO_ARCH_ESP32)
  Serial.println(F("[control] help: status"));
  Serial.println(F("[control] help: mode listen|think|speak|idle|sleep|error [strength]"));
  Serial.println(F("[control] help: event wake|touch|response|speech_end|idle|error [strength]"));
  Serial.println(F("[control] help: speech <0.0-1.0> <ah|oh|ee|neutral> [duration_ms]; speech clear"));
  Serial.println(F("[control] help: ambient <lux> <hour>; ambient lux <lux> hour <0-23>"));
  Serial.println(F("[control] help: time <0-23>; circadian hour <0-23>"));
  Serial.println(F("[control] help: command <1-5|go_to_sleep|wake_up|look_at_me|stop_moving|how_do_you_feel>"));
  Serial.println(F("[control] help: speak <boot|idle|attend|listen|think|speak|react|happy|concern|sleep|error|safety>"));
  Serial.println(F("[control] help: bridge hello|listening|thinking|response|audio|end|error"));
  Serial.println(F("[control] help: uplink start <seq> [wake|closed]; uplink chunk <seq> [bytes]; uplink end <seq>; uplink abort"));
  Serial.println(F("[control] help: pairing code <ABC123>; pairing clear; pair ticket <stackchan://pair?...>"));
  Serial.println(F("[control] help: wifi set ssid \"<name>\" pass \"<password>\" host <ip> port <8765> path </bridge>; wifi set ssid \"<name>\" url <ws://host:port/bridge>; wifi clear; saved to robot flash without echoing password"));
  Serial.println(F("[control] help: facepos x=<..> y=<..> s=<..>; facelost"));
  Serial.println(F("[control] help: sound dir=<deg> level=<0.0-1.0>; noise level=<0.0-1.0>"));
  Serial.println(F("[control] help: touch cheek|forehead|<x> <y> [strength]; proximity <0.0-1.0>"));
  Serial.println(F("[control] help: pickup [strength]; shake [strength]; putdown; tilt <x> <y> <z>"));
  Serial.println(F("[control] help: reduced on|off; motion reduced on|off"));
  Serial.println(F("[control] help: motion stop|resume; servos off|on"));
  Serial.println(F("[control] help: demo off|on"));
  Serial.println(F("[control] help: mic cue; speaker cue; speaker test|beep"));
  Serial.println(F("[control] help: safe stop|panic; safe resume|restore"));
  Serial.println(F("[control] help: CoreS3 inputs: tap=react hold=listen BtnA=listen BtnB=think BtnC=speak"));
#endif
}

bool SensorAdapter::begin() {
  lineLength_ = 0;
  line_[0] = '\0';
#if defined(ARDUINO_ARCH_ESP32)
  printHelp();
#endif
  return true;
}

bool SensorAdapter::poll(BenchControl* controlOut) {
  if (controlOut == nullptr) {
    return false;
  }

#if defined(ARDUINO_ARCH_ESP32)
  M5.update();

  while (Serial.available() > 0) {
    const char ch = static_cast<char>(Serial.read());
    if (ch == '\r') {
      continue;
    }

    if (ch == '\n') {
      line_[lineLength_] = '\0';
      lineLength_ = 0;

      if (parseBenchControlLine(line_, millis(), controlOut)) {
        if (controlOut->wantsHelp) {
          printHelp();
          line_[0] = '\0';
          continue;
        }
        return true;
      }

      if (line_[0] != '\0') {
        Serial.print(F("[control] ignored command=\""));
        Serial.print(line_);
        Serial.println(F("\""));
      }
      line_[0] = '\0';
      continue;
    }

    if (lineLength_ + 1 < sizeof(line_)) {
      line_[lineLength_++] = ch;
    } else {
      lineLength_ = 0;
      line_[0] = '\0';
      Serial.println(F("[control] ignored overlong command"));
    }
  }

  const uint32_t nowMs = millis();
  if (M5.BtnA.wasClicked()) {
    fillHardwareEvent(CharacterMode::Listen, EventType::WakeWord, nowMs, "button_a_listen", controlOut);
    return true;
  }
  if (M5.BtnB.wasClicked()) {
    fillHardwareEvent(CharacterMode::Think, EventType::ThinkingStarted, nowMs, "button_b_think", controlOut);
    return true;
  }
  if (M5.BtnC.wasClicked()) {
    fillHardwareEvent(CharacterMode::Speak, EventType::ResponseStarted, nowMs, "button_c_speak", controlOut);
    return true;
  }

  if (M5.Touch.isEnabled() && M5.Touch.getCount() > 0) {
    const auto detail = M5.Touch.getDetail(0);
    if (detail.wasClicked()) {
      fillHardwareEvent(CharacterMode::React, EventType::UserTouched, nowMs, "touch_click_react", controlOut);
      return true;
    }
    if (detail.wasHold()) {
      fillHardwareEvent(CharacterMode::Listen, EventType::UserNear, nowMs, "touch_hold_listen", controlOut);
      return true;
    }
  }
#endif

  return false;
}

}  // namespace stackchan
