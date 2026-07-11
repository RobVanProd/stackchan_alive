#if defined(STACKCHAN_SD_PROVISIONER) && STACKCHAN_SD_PROVISIONER

#include <Arduino.h>
#include <M5Unified.h>
#include <SD.h>
#include <SPI.h>
#include <ff.h>
#include <sd_diskio.h>

namespace {

constexpr uint8_t kSdCsPin = 4;
constexpr uint32_t kSdFrequencyHz = 25000000;
constexpr uint64_t kMinExpectedBytes = 58ULL * 1000ULL * 1000ULL * 1000ULL;
constexpr uint64_t kMaxExpectedBytes = 70ULL * 1000ULL * 1000ULL * 1000ULL;
constexpr const char* kConfirmPhrase = "FORMAT STACKCHAN 64GB ERASE MOVIES";
constexpr uint32_t kConfirmationTimeoutMs = 60000;

const char* cardTypeName(sdcard_type_t type) {
  switch (type) {
    case CARD_MMC:
      return "MMC";
    case CARD_SD:
      return "SDSC";
    case CARD_SDHC:
      return "SDHC_OR_SDXC";
    case CARD_NONE:
      return "NONE";
    default:
      return "UNKNOWN";
  }
}

bool readConfirmation(uint32_t deadlineMs) {
  char line[64] = {};
  size_t length = 0;
  while (static_cast<int32_t>(deadlineMs - millis()) > 0) {
    while (Serial.available() > 0) {
      const char ch = static_cast<char>(Serial.read());
      if (ch == '\r') continue;
      if (ch == '\n') {
        line[length] = '\0';
        return strcmp(line, kConfirmPhrase) == 0;
      }
      if (length + 1 < sizeof(line)) line[length++] = ch;
    }
    delay(5);
  }
  return false;
}

bool formatAndVerify(uint8_t drive) {
  char driveName[3] = {static_cast<char>('0' + drive), ':', '\0'};
  BYTE* work = static_cast<BYTE*>(malloc(FF_MAX_SS));
  if (work == nullptr) {
    Serial.println("[sd-provisioner] result=failed reason=work_buffer_allocation");
    return false;
  }
  const MKFS_PARM options = {FM_FAT32, 0, 0, 0, 0};
  const FRESULT formatted = f_mkfs(driveName, &options, work, FF_MAX_SS);
  free(work);
  if (formatted != FR_OK) {
    Serial.print("[sd-provisioner] result=failed reason=f_mkfs code=");
    Serial.println(static_cast<int>(formatted));
    return false;
  }

  sdcard_uninit(drive);
  if (!SD.begin(kSdCsPin, SPI, kSdFrequencyHz, "/sd", 5, false)) {
    Serial.println("[sd-provisioner] result=failed reason=remount");
    return false;
  }
  File marker = SD.open("/STACKCHAN_SD_READY.txt", FILE_WRITE);
  if (!marker) {
    Serial.println("[sd-provisioner] result=failed reason=verify_open");
    return false;
  }
  marker.println("Stackchan Alive optional storage");
  marker.close();
  marker = SD.open("/STACKCHAN_SD_READY.txt", FILE_READ);
  const bool verified = marker && marker.available() > 0;
  marker.close();
  Serial.print("[sd-provisioner] result=");
  Serial.print(verified ? "success" : "failed");
  Serial.print(" filesystem=FAT32 capacity_bytes=");
  Serial.println(static_cast<unsigned long long>(SD.cardSize()));
  return verified;
}

}  // namespace

void setup() {
  auto config = M5.config();
  config.serial_baudrate = 115200;
  M5.begin(config);
  Serial.println("[sd-provisioner] armed=1 destructive=1");
  Serial.println("[sd-provisioner] normal Stackchan firmware is not running");

  if (!SPI.begin()) {
    Serial.println("[sd-provisioner] result=refused reason=spi_init");
    return;
  }
  const uint8_t drive = sdcard_init(kSdCsPin, &SPI, kSdFrequencyHz);
  if (drive == 0xFF) {
    Serial.println("[sd-provisioner] result=refused reason=card_init");
    return;
  }
  const uint64_t capacityBytes =
      static_cast<uint64_t>(sdcard_num_sectors(drive)) * sdcard_sector_size(drive);
  Serial.print("[sd-provisioner] drive=");
  Serial.print(drive);
  Serial.print(" card_type=");
  Serial.print(cardTypeName(sdcard_type(drive)));
  Serial.print(" sectors=");
  Serial.print(sdcard_num_sectors(drive));
  Serial.print(" sector_bytes=");
  Serial.print(sdcard_sector_size(drive));
  Serial.print(" capacity_bytes=");
  Serial.println(static_cast<unsigned long long>(capacityBytes));

  if (capacityBytes < kMinExpectedBytes || capacityBytes > kMaxExpectedBytes) {
    Serial.println("[sd-provisioner] result=refused reason=capacity_not_64gb");
    sdcard_uninit(drive);
    return;
  }
  Serial.print("[sd-provisioner] type exact phrase within 60 seconds: ");
  Serial.println(kConfirmPhrase);
  if (!readConfirmation(millis() + kConfirmationTimeoutMs)) {
    Serial.println("[sd-provisioner] result=refused reason=confirmation_missing");
    sdcard_uninit(drive);
    return;
  }
  Serial.println("[sd-provisioner] confirmation=accepted formatting=1");
  formatAndVerify(drive);
}

void loop() {
  delay(1000);
}

#endif
