# Stackchan Arrival-Day Runbook

Use this when the physical Stackchan device arrives. Keep this release as a device-ready prerelease until every evidence gate below is complete.

## 0. Bench Setup

- Clear the work area around the body and servos.
- Keep display-only firmware first; do not start servo calibration first.
- Use a stable USB-C power source.
- Have a camera ready for display, speaker, and motion evidence.
- Know the serial port, for example `COM3`.

## 1. Create The Evidence Packet

From the extracted release folder:

```powershell
.\tools\prepare_device_arrival.cmd -Port COM3 -Operator "Your Name" -DeviceId STACKCHAN-001
```

Open the newest folder under `output\hardware-evidence\`. Run every command below from that packet folder unless noted otherwise.

## 2. Verify Package And Flash Display-Only

```powershell
.\RUN_PACKAGE_VERIFY.cmd
.\RUN_DISPLAY_ONLY.cmd
```

Expected evidence:

- `logs/package_verify.log`
- display-only serial log
- photo or video showing the procedural face
- observation note that servos stayed in dry-run mode
- `AUDIO_REVIEW.md` started with the sample you plan to play later

Hard stop if:

- the display is blank or corrupted
- the device resets repeatedly
- serial output has no boot marker
- any servo moves during display-only firmware

## 3. Supervised Servo Calibration

Only continue after display-only passes and the body is clear.

```powershell
.\RUN_SERVO_CALIBRATION.cmd
```

Expected evidence:

- servo-calibration serial log
- yaw classification: angle, velocity, or disabled
- pitch behavior note
- updated calibration notes if the physical center differs
- short video showing controlled motion

Hard stop if:

- yaw spins continuously
- pitch binds, chatters, or hits a mechanical limit
- any motion continues after the command stops
- the body tips, snags, or heats noticeably

## 4. Mixed-Mode Soak

```powershell
.\RUN_SOAK_MONITOR.cmd
```

Expected evidence:

- 30-minute soak log with heartbeat markers
- no repeated resets
- no task stalls
- face remains responsive
- `AUDIO_REVIEW.md` completed
- real-device speaker recording saved under `audio/`
- audio sample is intelligible through the device speaker
- no clipping, distortion, playback dropout, or excessive delay

## 5. Progress Check Before Promotion

Run this repeatedly while collecting evidence:

```powershell
.\RUN_PROGRESS_CHECK.cmd
```

Do not run the strict verifier until the progress check is clean or only lists intentionally deferred gates.

## 6. Strict Evidence Verification

```powershell
.\RUN_EVIDENCE_VERIFY.cmd
```

This must pass before calling the package hardware-validated.

## 7. Consumer Promotion Gate

Only after strict evidence verification passes:

```powershell
.\RUN_CONSUMER_PROMOTION_CHECK.cmd
```

This still requires:

- successful GitHub Actions status, unless an explicit account-block exception is recorded
- completed production voice-source provenance
- completed `AUDIO_REVIEW.md` with real-device speaker evidence

## Current Release Limits

- Current hosted samples are review-only Stackchan Spark Synth samples.
- Production voice source remains pending.
- GitHub Actions may be externally blocked by account billing or spending-limit state.
- No consumer rollout until hardware evidence, production voice provenance, and CI/account state are resolved.
