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

If you already ran `tools\share_release.cmd` and `tools\verify_share_release.cmd`, the packet also includes `HOSTED_MEDIA_REFERENCE.md` plus `share/` copies of the verified Cloudflare/share page reports. Use that hosted page as the remote review reference for the expected image, video, face GIFs, and voice samples while collecting real-device evidence.

## 2. Verify Package And Flash Display-Only

```powershell
.\RUN_PACKAGE_VERIFY.cmd
.\RUN_DISPLAY_ONLY.cmd
```

Expected evidence:

- `logs/package_verify.log`
- `HOSTED_MEDIA_REFERENCE.md` if a verified share was available
- display-only serial log
- photo or video showing the procedural face
- observation note that servos stayed in dry-run mode
- `AUDIO_REVIEW.md` started with the sample you plan to play later

Hard stop if:

- the display is blank or corrupted
- the device resets repeatedly
- serial output has no boot marker
- any servo moves during display-only firmware

Import the display photo or video into the packet:

```powershell
.\RUN_ADD_MEDIA.cmd -Type Photo C:\path\stackchan-face.jpg
```

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
- `RVC_LEAD_AUDITION.md` reviewed so the exact lead sample and voice settings are known
- `RUN_PLAY_LEAD_VOICE.cmd` used as the playback aid when routing audio to the target speaker path
- `AUDIO_REVIEW.md` completed
- real-device speaker recording saved under `audio/`
- audio sample is intelligible through the device speaker
- no clipping, distortion, playback dropout, or excessive delay

The evidence packet copies the current lead RVC audition into `reference_audio/`. For this prerelease direction, the lead is `RVC Bright Robot` with pitch 2, index 0.62, RMS mix 0.72, and protect 0.28. This remains review-only voice evidence; production voice-source provenance is still required before consumer rollout.

Import the speaker recording into the packet. Use `-Type Audio` for phone videos of the speaker so `.mp4` or `.mov` files are stored under `audio/`:

```powershell
.\RUN_PLAY_LEAD_VOICE.cmd
.\RUN_ADD_MEDIA.cmd -Type Audio C:\path\stackchan-speaker.wav
```

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
