# LAN OTA

Stackchan's optional LAN OTA service accepts a complete firmware image on a dedicated HTTP port, verifies an operator token and the image SHA-256, writes only the inactive OTA application slot, and reboots into a bounded health-validation period. It is disabled unless a valid token is supplied at build time.

This is an operator feature for a trusted private LAN. HTTP does not encrypt the bearer token or firmware in transit. Do not expose port `8790` through a router, tunnel, public reverse proxy, or untrusted Wi-Fi network.

## Build Secret

Set a unique random token in the build process environment. It must be 32 to 128 printable ASCII bytes without spaces. Do not put it in `platformio.ini`, a response file, source control, an issue, or a build log.

```powershell
$env:STACKCHAN_OTA_TOKEN = '<unique-random-token>'
pio run -e stackchan_release_forensics
Remove-Item Env:STACKCHAN_OTA_TOKEN
```

`tools/platformio_apply_ota_env.py` validates the token and supplies only `STACKCHAN_OTA_TOKEN_SHA256` to the compiler. The raw token is not part of the firmware or persisted OTA telemetry. `STACKCHAN_OTA_PORT` may override the default port and is restricted to `1024..65535`; the uploader must use the same port.

## Upload

Keep Stackchan on stable external power, clear its moving parts, and stop active voice or wake interactions. Use the firmware binary produced for the same board and partition layout already installed on the device.

```powershell
$env:STACKCHAN_OTA_TOKEN = '<same-token-used-for-the-device-build>'
.\tools\upload_lan_ota.ps1 `
  -Device stackchan.local `
  -Firmware .pio\build\stackchan_release_forensics\firmware.bin `
  -ConfirmUpload
Remove-Item Env:STACKCHAN_OTA_TOKEN
```

The uploader accepts only a hostname or IPv4 address resolving entirely to private, link-local, or loopback addresses. It computes the local SHA-256, checks that the device is confirmed and idle, uploads with bounded timeouts, and waits for `confirmed`, `rolled_back`, or `failed`. `-SkipHealthWait` returns after the device accepts the image; use it only when another operator is watching OTA status.

## HTTP Contract

The service listens separately from the debug server, on port `8790` by default.

- `GET /status` returns non-secret `stackchan.lan-ota.v1` state. It is intentionally unauthenticated so an operator can observe reboot, validation, and rollback without resending the token.
- `POST /firmware` requires `Authorization: Bearer <token>`, `X-Stackchan-SHA256: <64 lowercase-or-uppercase hex characters>`, `Content-Type: application/octet-stream`, and an exact `Content-Length`.
- Chunked transfer encoding, oversized headers, empty images, images larger than the inactive slot, concurrent requests, and incomplete bodies are rejected.
- Authentication compares SHA-256 digests in constant time. Image bytes are streamed through SHA-256 and `Update`; `Update.end()` is called only after the digest matches.

Status includes the running, previous, and target partition labels; expected image SHA-256; persistent phase; last preflight result; last error; health-pending state; and the active rollback mode. It never includes the bearer token or its configured digest.

## Device Preflight

The runtime supplies current hardware state immediately before `Update.begin()`. Upload is rejected unless all conditions hold:

- Power telemetry is valid, external power is present, and VBUS is at least `4550 mV`. Post-boot health still enforces the `4400 mV` absolute floor.
- Motion is neither requested nor enabled, servo rail and torque are off, and the body is physically clear under the normal operator procedure.
- Audio playback/capture and the wake turn are inactive.
- Free internal heap is at least `65536` bytes.
- The running application is already confirmed.

These checks are a final device-side gate, not a substitute for an operator watching the physical unit.

## Partitions And Model Data

The server obtains its destination from `esp_ota_get_next_update_partition()` and accepts it only when it is a different `ota_0` or `ota_1` application partition with enough capacity. It invokes Arduino `Update` with `U_FLASH`; it does not use filesystem update modes or raw partition writes.

No partition CSV is changed by this feature. In layouts such as `partitions_esp_sr_16.csv`, the `model` FAT data partition at `0x800000` is outside both OTA app slots and is never selected or written. Changing partition layouts remains a serial-flash operation and must not be attempted through LAN OTA.

## Validation And Rollback

Before activation, namespace `stack_ota` in NVS records the previous app partition, target app partition, expected SHA-256, image size, and phase. After reboot, the target must maintain runtime, display, task, Wi-Fi, power, and heap health continuously for 30 seconds. An unhealthy sample resets the stable window. Failure to establish health within 120 seconds requests rollback.

The implementation checks `CONFIG_BOOTLOADER_APP_ROLLBACK_ENABLE` at compile time. Do not infer that setting from the framework version: `/status` reports `bootloader_rollback_enabled` and `software_rollback_only`, and the running firmware is the authority.

With bootloader rollback enabled, the application confirms a pending image with `esp_ota_mark_app_valid_cancel_rollback()` or rejects it with `esp_ota_mark_app_invalid_rollback_and_reboot()`. This is the preferred mode and covers boot attempts governed by the ESP-IDF bootloader policy.

Without bootloader rollback, Stackchan can only set the recorded previous OTA slot as the next boot target after its application health code runs. This software fallback does **not** protect against a crash, hang, or power failure before `setup()` and health handling execute. Telemetry labels this mode honestly; do not treat it as equivalent to bootloader rollback.

## Recovery

If the uploader loses contact, query `http://<device>:8790/status` from the same trusted LAN. Do not immediately retry while `upload_active` or `health_pending` is true. A `rolled_back` phase means the prior app is running. A persistent `rollback_requested` or unreachable device requires serial recovery and inspection of the installed partition table; never erase or rewrite the model partition as an OTA recovery step.
