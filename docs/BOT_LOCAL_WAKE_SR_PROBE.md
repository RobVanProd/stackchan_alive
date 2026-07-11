# Bot-Local Wake SR Probe

Status: physically tested on 2026-07-07, wake detected, rejected for face performance, rolled
back to `stackchan_wifi`.

This was the first wake-word path after the face-flicker rollback. The goal was to prove
that wake detection could live on the CoreS3 robot before layering robot mic uplink, bridge
audio, speaker cues, or servo motion back on top.

## Physical Result

The probe proved the WakeNet path can detect the phrase, but it failed the smooth-face gate.

Observed after flashing `stackchan_wake_sr_probe`:

- Firmware and `srmodels.bin` model partition flashed successfully.
- Runtime reported `sr_wake_enabled=1`, `sr_wake_compiled=1`, `sr_wake_task_started=1`,
  `sr_wake_mic_ready=1`, and `sr_wake_sr_ready=1`.
- Saying `Hi Stack Chan` produced `[sr_wake] event=wake_word applied=1`.
- `sr_wake_detections` reached `3`.
- Quiet display telemetry regressed to roughly `85-102 ms` per frame, about `11.6-11.8 fps`.

Decision:

- Rolled back to `stackchan_wifi`.
- Do not keep this probe on the robot.
- Do not repeat this same integration as the next physical step.
- Treat ESP-SR as wake-functional, but too expensive in this firmware shape.

Evidence:

- `output/hardware-evidence/bot-local-wake-sr/20260707-013728/BOT_LOCAL_WAKE_SR_RESULT.md`

## Decision

Use ESP-SR WakeNet/AFE on the robot for the first bot-local wake probe.

Why:

- ESP-SR is Espressif's speech-recognition stack for ESP32-S3 and includes WakeNet, AFE,
  VAD, and MultiNet.
- The official StackChan documentation says the factory unit wakes to `Hi, StackChan`.
- The ESP-SR model registry includes a `Hi, Stack Chan` wake model.
- The 74th `ESP-SR-For-M5Unified` wrapper provides an M5Unified/CoreS3-friendly path and
  PlatformIO example for the `HiStackChanWakeUpWord` model.

References:

- ESP-SR component registry: https://components.espressif.com/components/espressif/esp-sr
- ESP-SR WakeNet docs: https://docs.espressif.com/projects/esp-sr/en/latest/esp32s3/wake_word_engine/README.html
- ESP-SR AFE docs: https://docs.espressif.com/projects/esp-sr/en/latest/esp32s3/audio_front_end/README.html
- M5Stack StackChan docs: https://docs.m5stack.com/en/StackChan
- ESP-SR-For-M5Unified: https://github.com/74th/ESP-SR-For-M5Unified
- M5 CoreS3 mic docs: https://docs.m5stack.com/en/arduino/m5cores3/mic

## Probe Firmware

Environment, for reference only:

```powershell
pio run -e stackchan_wake_sr_probe
```

Important feature flags:

- `STACKCHAN_ENABLE_WIFI_BRIDGE=1`
- `STACKCHAN_ENABLE_SR_WAKE_PROBE=1`
- `STACKCHAN_ENABLE_SERVOS=0`
- `STACKCHAN_ENABLE_SPEAKER=0`
- `STACKCHAN_ENABLE_MIC_CAPTURE=0`
- `STACKCHAN_ENABLE_BRIDGE_AUDIO_UPLINK=0`

This keeps the known-good face and bridge architecture alive while the wake probe runs on
core 0 at low priority. The face task remains on the existing runtime path.

The wake phrase for this probe is:

```text
Hi Stack Chan
```

Do not validate this probe by saying `Hey Stackchan`; that is not the model loaded by the
first ESP-SR probe.

## Model Partition

The probe uses `partitions_esp_sr_16.csv`, which reserves a flash model partition at
`0x800000`.

On upload, `tools/flash_srmodels.py` also flashes `srmodels.bin` to that partition. The
script searches:

- `srmodels.bin`
- `data/srmodels.bin`
- `output/research/ESP-SR-For-M5Unified/examples/HiStackChanWakeUpWord_platformio/srmodels.bin`

## Physical Validation

Do this only with the robot on USB and the smooth-face rollback firmware ready.

Flash command used during the failed visual-performance probe:

```powershell
pio run -e stackchan_wake_sr_probe -t upload --upload-port COM4
```

Serial success markers:

```text
[sr_wake] ready=1 phrase="Hi Stack Chan" mode=wake_only task_core=0
sr_wake_enabled=1
sr_wake_compiled=1
sr_wake_task_started=1
sr_wake_mic_ready=1
sr_wake_sr_ready=1
```

During the test, `sr_wake_record_ok` should increase. After saying `Hi Stack Chan`, expect:

```text
[sr_wake] event=wake_word applied=1
sr_wake_detections=1
sr_wake_events_applied=1
```

Acceptance criteria:

- Face stays smooth with no flicker.
- Serial/debug remains responsive.
- Wake detection increments only when the phrase is spoken.
- No audio uplink starts in this probe.
- No servo motion occurs.

Rollback, already performed after the failed performance gate:

```powershell
pio run -e stackchan_wifi -t upload --upload-port COM4
```

## Next Layer After Wake Proof

This ESP-SR probe is not the wake layer to build on next. Use the ASR UART offload path in
`docs/BOT_LOCAL_WAKE_ARCHITECTURE.md` instead.

The satisfying low mic-activation tone should wait until the wake implementation no longer
hurts the face and the mic uplink turn actually opens. Keep that as a later supervised build
because M5Unified mic and speaker use shared board audio resources, and the first goal
remains proving wake without reintroducing face flicker or audio contention.
