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
It also creates runnable `RUN_DISPLAY_ONLY.cmd`, `RUN_SERVO_CALIBRATION.cmd`, `RUN_SOAK_MONITOR.cmd`, `RUN_PACKAGE_VERIFY.cmd`, `RUN_PROGRESS_CHECK.cmd`, and `RUN_EVIDENCE_VERIFY.cmd` files in the evidence packet.

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
Run `RUN_PROGRESS_CHECK.cmd` during testing to list missing fields, logs, serial markers, checklist items, media evidence, and calibration placeholders before the strict promotion verifier is run.

## First Hardware Tests

1. Watch serial output for boot, display, and servo messages.
2. Confirm pitch moves gently around center.
3. Confirm yaw behavior before trusting absolute yaw.
4. If yaw rotates continuously or hunts, set yaw mode to disabled in the motion target path and continue with display plus pitch only.
5. Run for 10 minutes and watch for resets, task stalls, jitter, or heat.

## Rollout Criteria

- `pio run` succeeds from a clean checkout.
- Display-only firmware runs without resets.
- Servo-enabled firmware passes a supervised 10-minute burn-in.
- Yaw mode is classified as angle, velocity, or disabled.
- Calibration values are written to `data/calibration.yaml`.
- No high-level intent code writes directly to servos or display.
