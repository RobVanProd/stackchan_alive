# Device Bring-Up

Use this when the Stack-chan hardware arrives.

## Preflight

1. Confirm battery is charged or USB-C power is stable.
2. Keep the body clear; do not force the yaw or pitch axes while powered.
3. Start an evidence packet for the release under test from the source checkout:

```powershell
.\tools\start_hardware_evidence.cmd -ReleaseTag <version> -PackageZip output\release\stackchan_alive_<version>.zip -Port COM3 -Operator "Your Name" -DeviceId STACKCHAN-001
```

This copies the release ZIP into the packet and writes `logs/package_verify.log`, which is required for promotion.
It also creates `BENCH_STATUS.md/json`, `NEXT_STEPS.md`, plus runnable `RUN_DISPLAY_ONLY.cmd`, `RUN_SPEECH_MOUTH_DEMO.cmd`, `RUN_SERVO_CALIBRATION.cmd`, `RUN_SOAK_MONITOR.cmd`, `RUN_PACKAGE_VERIFY.cmd`, `RUN_PROGRESS_CHECK.cmd`, and `RUN_EVIDENCE_VERIFY.cmd` files in the evidence packet.
Open `BENCH_STATUS.md` first for the current next action, then `NEXT_STEPS.md` for the full bench run order and hard stops before servo motion, audio review, and consumer promotion.

Use this one-step preparation helper instead when you want package verification, display-flash dry-run, and evidence packet creation together:

```powershell
.\tools\prepare_device_arrival.cmd -ReleaseTag <version> -PackageZip output\release\stackchan_alive_<version>.zip -Port COM3 -Operator "Your Name" -DeviceId STACKCHAN-001
```

If you only have the extracted release ZIP, run the same helper from inside the extracted folder:

```powershell
.\tools\prepare_device_arrival.cmd -Port COM3 -Operator "Your Name" -DeviceId STACKCHAN-001
```

4. Check the exact release-binary flash command without touching the device:

```powershell
.\tools\flash_release_firmware.cmd -PackageZip output\release\stackchan_alive_<version>.zip -Firmware display_only -DryRun -Monitor -Port COM3
```

5. Flash the display-only binary from the verified release package first:

```powershell
.\tools\flash_release_firmware.cmd -PackageZip output\release\stackchan_alive_<version>.zip -Firmware display_only -Monitor -Port COM3
```

Expected result: the CoreS3 display shows the procedural face and serial logs include dry-run servo mode.
Display telemetry should print about every 5 seconds with `frame_ms_avg`, `frame_ms_max`, `fps_window`, `frame_budget_us=33333`, and `slow_frames`.
Face animator telemetry should also print about every 5 seconds with `[face]`, `blink_count`, `saccade_count`, `gesture_active`, `speech_active`, and `speech_env`.
Speech cue telemetry should print `[speech]` lines with `seq`, `intent`, `earcon`, `earcon_delay_ms`, and `text` whenever the persona emits a new cue.
Heartbeat telemetry should include `[system]`, `heap_free`, `heap_min`, and task stack high-water marks for loop, motion, face, and intent tasks.

The firmware also accepts deterministic serial bench controls at `115200` baud. Send one command per line to force a mode/event and verify face transitions plus `[speech]` cue telemetry without waiting for the random demo scheduler:

```text
mode listen
mode think
mode speak
mode idle
event touch
event response
event speech_end
speech 0.8 ah
speech 0.5 oh
speech 0.7 ee 900
speech clear
status
help
```

An optional strength value in `[0.0, 1.0]` may follow mode/event commands, for example `mode listen 0.75`. Speech commands use `speech <envelope> <ah|oh|ee|neutral> [duration_ms]`; the duration defaults to 600 ms and is clamped to 50-2000 ms. Send `status`, `telemetry`, or `health` to print immediate `[heartbeat]` and `[system]` telemetry without waiting for the periodic heartbeat. Send `help` or `?` to print the command summary on serial. Each accepted command logs `[control] command=... mode=... event=... strength=... at_ms=...` and holds off demo events briefly so the commanded state remains observable.

The same bench path also listens to CoreS3 inputs: screen tap = React/UserTouched, screen hold = Listen/UserNear, BtnA = Listen, BtnB = Think, and BtnC = Speak. These input events log the same `[control]` telemetry as serial commands.

To quickly exercise the speech-reactive mouth path after display-only firmware is running, use the host helper:

```powershell
.\tools\send_speech_mouth_demo.cmd -Port COM3
```

To drive that same mouth path from an actual WAV envelope, generate a sidecar and stream it:

```powershell
.\tools\generate_speech_envelope_sidecar.cmd -InputWav output\voice_auditions\rvc_base\final\stackchan_rvc_bright_robot.wav -OutputJson output\speech\bright_robot.speech_envelope.json
.\tools\verify_speech_envelope_sidecar.cmd -Path output\speech\bright_robot.speech_envelope.json
.\tools\send_speech_mouth_demo.cmd -Port COM3 -SidecarPath output\speech\bright_robot.speech_envelope.json
```

The generated evidence packet also includes required `RUN_SPEECH_MOUTH_DEMO.cmd` evidence, which captures streamed envelope commands and any immediate device readback to `logs\speech_mouth_demo_serial.log`.

For review streams or long bench recordings where the face should be calmer in the background, set `STACKCHAN_REDUCED_MOTION=1` in the active PlatformIO environment. The firmware logs `[face] reduced_motion=1` at startup and keeps blink/saccade/breathing behavior active with reduced amplitude.

You can also toggle this at runtime from the serial monitor without reflashing:

```text
reduced on
reduced off
motion reduced on
motion reduced off
```

The command logs `[control] command=reduced_motion_on reduced_motion=1` or `[control] command=reduced_motion_off reduced_motion=0`, then the face task applies the change and logs the new `[face] reduced_motion=` state.
Those reduced-motion command lines count as display bench-control telemetry in the evidence checks, but they do not replace the required photo, video, speaker audio, or strict hardware logs.

## Servo Enable Gate

Servos are disabled by default in `platformio.ini`:

```ini
-D STACKCHAN_ENABLE_SERVOS=0
```

Use the default display-only environment first:

```powershell
.\tools\flash_release_firmware.cmd -PackageZip output\release\stackchan_alive_<version>.zip -Firmware display_only -Monitor -Port COM3
```

Check the servo upload command without touching the device:

```powershell
.\tools\flash_release_firmware.cmd -PackageZip output\release\stackchan_alive_<version>.zip -Firmware servo_calibration -ConfirmServoRisk -DryRun -Monitor -Port COM3
```

Only use the servo calibration environment after the display-only build runs and the body is on a clear surface:

```powershell
.\tools\flash_release_firmware.cmd -PackageZip output\release\stackchan_alive_<version>.zip -Firmware servo_calibration -ConfirmServoRisk -Monitor -Port COM3
```

For development builds from source, use `tools/flash_device.cmd`; for release evidence, use `tools/flash_release_firmware.cmd` so the tested device matches the verified package.

The initial hardware mapping assumes CoreS3 M5 SCS servos on pins `1` and `2`, matching the upstream `stackchan-arduino` default for CoreS3. If the hardware behaves differently, stop and update `StackChanServoAdapter` before further testing.

Save serial logs, photos, and calibration notes into the evidence packet created during preflight.
When using the generated `RUN_*.cmd` files, display, servo, and soak serial output is written directly under the packet's `logs/` folder.
Run `RUN_PROGRESS_CHECK.cmd` during testing to refresh `BENCH_STATUS.md/json` and list missing fields, logs, serial markers, checklist items, media evidence, and calibration placeholders before the strict promotion verifier is run.
If the packet is handed to someone else, send `BENCH_STATUS.md`, `NEXT_STEPS.md`, and `ROLLOUT_STATUS.md` together so they can see the next action and the current gate state without reading every packet file.

## First Hardware Tests

1. Watch serial output for boot, display, and servo messages.
2. Confirm pitch moves gently around center.
3. Confirm yaw behavior before trusting absolute yaw.
4. If yaw rotates continuously or hunts, set yaw mode to disabled in the motion target path and continue with display plus pitch only.
5. Run for 10 minutes and watch for resets, task stalls, jitter, heat, repeated nonzero `slow_frames` in display telemetry, a flat `[face]` line that never increments `blink_count` or `saccade_count`, or steadily falling `heap_min` / stack high-water margins.

## Rollout Criteria

- `pio run` succeeds from a clean checkout.
- Display-only firmware runs without resets.
- Servo-enabled firmware passes a supervised 10-minute burn-in.
- Yaw mode is classified as angle, velocity, or disabled.
- Calibration values are written to `data/calibration.yaml`.
- No high-level intent code writes directly to servos or display.
