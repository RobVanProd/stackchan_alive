# Bot-Local Wake Architecture

Status: selected next candidate on 2026-07-07 after the ESP-SR physical probe.

## Goal

Wake detection must live on the robot side of the system, but it must not damage the
smooth face baseline. The face renderer and bridge runtime are now treated as the protected
baseline. Any wake layer that causes visible flicker, frame drops, black screen behavior, or
bridge stalls is rejected even if it detects the wake phrase.

## Decision

Use an offloaded local ASR module over UART as the next bot-local wake candidate.

Current build-only candidate:

```powershell
pio run -e stackchan_wifi_asr_unit
```

Do not flash this until the ASR hardware is connected and an operator is watching the face.
The live robot should stay on `stackchan_wifi` until then.

## Why ESP-SR Is Rejected For Now

The first physical CoreS3 wake probe used ESP-SR WakeNet on the robot and listened for
`Hi Stack Chan`. It proved wake detection, but failed the visual gate:

- `[sr_wake] event=wake_word applied=1` appeared.
- `sr_wake_detections` reached `3`.
- Quiet display telemetry regressed to roughly `85-102 ms` per frame, about `11.6-11.8 fps`.
- The robot was rolled back to `stackchan_wifi`.

Espressif's benchmark lists WakeNet9 at about `3.0 ms` per 32 ms frame for two channels on
an ESP32-S3-Korvo V4.0 reference setup, but this firmware integration also had M5Unified,
Arduino, Wi-Fi bridge, debug telemetry, display rendering, PSRAM pressure, and shared board
runtime contention. The measured robot result is the gate that matters.

Evidence:

- `output/hardware-evidence/bot-local-wake-sr/20260707-013728/BOT_LOCAL_WAKE_SR_RESULT.md`
- `docs/BOT_LOCAL_WAKE_SR_PROBE.md`

## Next Candidate: UART ASR Offload

The M5Stack Unit ASR is an offline speech recognition unit built around a CI-03T module. The
vendor docs describe offline wake/command recognition, UART communication, default
`115200 8N1`, custom wake words/commands, and a command response format compatible with the
M5Unit-ASR Arduino library:

```text
AA 55 ID 55 AA
```

That is a better fit for this robot because speech recognition runs on the ASR module, while
the CoreS3 firmware only reads a few UART bytes. The face CPU, display task, bridge task, and
PSRAM should stay close to the known-good `stackchan_wifi` behavior.

Recommended ASR firmware setup:

- Add a wake phrase that matches how the operator naturally calls the robot, for example
  `Hey Stackchan`.
- Optionally add `Hi Stack Chan` too if we want compatibility with the factory phrasing.
- Configure the ASR unit to emit `AA 55 <wake-id> 55 AA` when the wake phrase is recognized.
- For first hardware discovery, `STACKCHAN_ASR_WAKE_COMMAND_ID=0` accepts any valid ASR frame
  as wake. For the final build, set this to the actual wake command ID or keep the ASR unit
  firmware scoped so only wake-like commands emit frames.

## Firmware Integration

Implemented build candidate:

- `src/io/AsrWakeSerialAdapter.hpp`
- `src/io/AsrWakeSerialAdapter.cpp`
- `platformio.ini` environment: `stackchan_wifi_asr_unit`

Default candidate flags:

```ini
-D STACKCHAN_ENABLE_ASR_UNIT_WAKE=1
-D STACKCHAN_ASR_UART_BAUD=115200
-D STACKCHAN_ASR_UART_RX_PIN=18
-D STACKCHAN_ASR_UART_TX_PIN=17
-D STACKCHAN_ASR_WAKE_COMMAND_ID=0
```

Runtime markers:

```text
[asr_wake] ready=1 type=uart baud=115200 rx=18 tx=17 wake_command_id=0
[wake] source=asr_unit_uart event=wake_word applied=1 count=1 command_id=<id> at_ms=<ms>
```

Debug/status fields:

- `asr_wake_enabled`
- `asr_wake_ready`
- `asr_wake_hw_ready`
- `asr_wake_bytes`
- `asr_wake_frames`
- `asr_wake_bad_frames`
- `asr_wake_ignored_frames`
- `asr_wake_events`
- `asr_wake_last_command_id`
- `asr_wake_last_wake_ms`

## Validation Order

1. Keep the robot on `stackchan_wifi` while preparing the ASR hardware.
2. Configure and bench-test the ASR module by itself.
3. Wire the ASR module UART to the CoreS3. The candidate firmware defaults to CoreS3 host
   RX `GPIO18`, TX `GPIO17`; confirm cable orientation before flashing.
4. Build `stackchan_wifi_asr_unit`.
5. Flash only with explicit operator approval and rollback ready.
6. Confirm the face is still visually smooth before speaking the wake phrase.
7. Say the configured phrase and watch for the UART wake marker.
8. Check debug telemetry and display frame timing. Any flicker or large frame regression is
   a failed gate.
9. Roll back immediately if the face or bridge regresses:

```powershell
pio run -e stackchan_wifi -t upload --upload-port COM4
```

## Mic Activation Tone

The low tone should mark the point where a mic uplink turn actually opens, not merely that a
wake phrase was heard. The existing tone path fires from `BridgeWakeGate` turn starts when
bridge audio uplink is enabled. Keep the ASR wake-only candidate quiet for first hardware
bring-up, then re-enable the tone with the later ASR-plus-uplink candidate.

## References

- ESP-SR WakeNet docs: https://docs.espressif.com/projects/esp-sr/en/latest/esp32s3/wake_word_engine/README.html
- ESP-SR ESP32-S3 benchmark: https://docs.espressif.com/projects/esp-sr/en/latest/esp32s3/benchmark/README.html
- M5Stack Unit ASR docs: https://docs.m5stack.com/en/unit/Unit%20ASR
- M5Stack ASR firmware guide: https://docs.m5stack.com/en/guide/offline_voice/module_asr/firmware
