# Device Bring-Up

Use this when the Stack-chan hardware arrives.

## Preflight

1. Confirm battery is charged or USB-C power is stable.
2. Keep the body clear; do not force the yaw or pitch axes while powered.
3. Start an evidence packet for the release under test:

```powershell
.\tools\start_hardware_evidence.cmd -ReleaseTag v0.1.4-device-ready -PackageZip output\release\stackchan_alive_v0.1.4-device-ready.zip -Port COM3
```

This copies the release ZIP into the packet and writes `logs/package_verify.log`, which is required for promotion.

4. Build once with servos disabled:

```powershell
pio run
```

5. Flash the display-only build first:

```powershell
pio run --target upload
pio device monitor --baud 115200
```

Expected result: the CoreS3 display shows the procedural face and serial logs include dry-run servo mode.

## Servo Enable Gate

Servos are disabled by default in `platformio.ini`:

```ini
-D STACKCHAN_ENABLE_SERVOS=0
```

Use the default display-only environment first:

```powershell
.\tools\flash_device.cmd -Environment stackchan -Monitor
```

Check the servo upload command without touching the device:

```powershell
.\tools\flash_device.cmd -Environment stackchan_servo_calibration -ConfirmServoRisk -DryRun -Monitor
```

Only use the servo calibration environment after the display-only build runs and the body is on a clear surface:

```powershell
.\tools\flash_device.cmd -Environment stackchan_servo_calibration -ConfirmServoRisk -Monitor
```

The initial hardware mapping assumes CoreS3 M5 SCS servos on pins `1` and `2`, matching the upstream `stackchan-arduino` default for CoreS3. If the hardware behaves differently, stop and update `StackChanServoAdapter` before further testing.

Save serial logs, photos, and calibration notes into the evidence packet created during preflight.

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
