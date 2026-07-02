# Rollout Checklist

Use this as the arrival-day test record. Do not promote a release from prerelease until every gate has explicit evidence.

When completing `OBSERVATIONS.md`, use promotion-verifiable values: `Result: pass`, reset/heat/brownout/stall/jitter observed fields as `no`, `Procedural face visible: yes`, `Dry-run servo log observed: yes`, `Yaw classification: angle`, `velocity`, or `disabled`, soak `Duration` of at least `30 minutes`, and `USB power-cycle recovery: pass`.
Promotion evidence must include at least one real photo or video under `photos/`: `.png`, `.jpg`, `.jpeg`, `.gif`, `.mp4`, `.mov`, or `.webm`. Text placeholders do not count.
Promotion evidence must include `AUDIO_REVIEW.md` plus at least one real-device speaker recording under `audio/`: `.wav`, `.mp3`, `.m4a`, `.aac`, `.mp4`, `.mov`, or `.webm`. Text placeholders or generated source WAVs alone do not count as target-speaker evidence.
Use `RUN_ADD_MEDIA.cmd` from the generated evidence packet to import phone photos, videos, and speaker recordings. It validates file headers, copies files into `photos/` or `audio/`, and records hashes in `media_manifest.json`.
Serial logs must include firmware markers: display-only boot `mode=display_only`, servo-calibration boot `mode=servo_calibration`, display renderer ready, servo dry-run or hardware-enable line, display telemetry with `fps_window` plus `slow_frames`, face animator telemetry with `blink_count` plus `saccade_count`, runtime health telemetry with `heap_free` plus task stack high-water marks, and soak heartbeat `[heartbeat] stackchan_alive ... uptime_ms=...`.

## Build Evidence

- [ ] `pio run -e stackchan` passes.
- [ ] `pio run -e stackchan_servo_calibration` passes.
- [ ] `pio test -e native_logic` passes.
- [ ] `pio test -e stackchan --without-uploading --without-testing` passes.
- [ ] `tools/run_device_preflight.ps1` passes.
- [ ] GitHub Actions `Firmware` workflow is green on `main`.
- [ ] Release package ZIP contains firmware, media, docs, manifest, dependency provenance, `dependency_lock.json`, copied build inputs, and checksums.
- [ ] `tools/verify_release_package.ps1` passes for the release ZIP.
- [ ] Production voice-source provenance is completed and no longer marked pending.
- [ ] `tools/flash_release_firmware.ps1 -PackageZip <zip> -Firmware display_only -DryRun -Monitor` passes for the release ZIP.
- [ ] Hardware evidence packet created with `tools/start_hardware_evidence.ps1`.
- [ ] Evidence packet includes the tested ZIP and `logs/package_verify.log`, or records a verified extracted package root.
- [ ] Photo/video and speaker recordings imported with `RUN_ADD_MEDIA.cmd`, producing `media_manifest.json`.
- [ ] Evidence packet includes completed `AUDIO_REVIEW.md` and a real-device speaker recording under `audio/`.
- [ ] `RUN_PROGRESS_CHECK.cmd` has no remaining missing evidence items.
- [ ] If testing from an extracted release package, `tools/prepare_device_arrival.ps1 -Port <COM> -Operator <name> -DeviceId <id>` passes from inside that package root.

## Display-Only Flash

Command:

```powershell
.\tools\flash_release_firmware.cmd -PackageZip output\release\stackchan_alive_<version>.zip -Firmware display_only -Monitor
```

Pass criteria:

- [ ] Device boots without reset loop.
- [ ] Display shows the procedural face.
- [ ] Serial log includes dry-run servo mode.
- [ ] Display telemetry includes `fps_window`, `frame_budget_us=33333`, and no repeated nonzero `slow_frames`.
- [ ] Face telemetry includes `[face]`, `blink_count`, `saccade_count`, `gesture_active`, `speech_active`, and `speech_env`.
- [ ] System telemetry includes `[system]`, `heap_free`, `heap_min`, `stack_loop_hwm`, `stack_motion_hwm`, `stack_face_hwm`, and `stack_intent_hwm`.
- [ ] 10-minute idle run completes without resets.

## Servo Calibration Flash

Command:

```powershell
.\tools\flash_release_firmware.cmd -PackageZip output\release\stackchan_alive_<version>.zip -Firmware servo_calibration -ConfirmServoRisk -Monitor
```

Pass criteria:

- [ ] Pitch stays inside safe mechanical range.
- [ ] Yaw behavior is classified as angle, velocity, or disabled.
- [ ] No uncontrolled continuous yaw motion.
- [ ] No overheating or brownout during 10-minute supervised run.
- [ ] Calibration values are recorded in `data/calibration.yaml`.

## Soak Test

- [ ] 30-minute mixed idle/listen/think/speak run.
- [ ] USB power-cycle recovery test.
- [ ] Serial logs saved.
- [ ] Display telemetry remains near 30 fps cadence with no sustained frame-budget misses.
- [ ] Face telemetry remains active during soak, with blink and saccade counters present in the serial log.
- [ ] System telemetry remains present during soak, with no obvious heap leak or exhausted task stack margin.
- [ ] Photo or video evidence saved under `photos/`.
- [ ] `RVC_LEAD_AUDITION.md` reviewed and `RUN_PLAY_LEAD_VOICE.cmd` used for the selected lead voice speaker check.
- [ ] Speaker recording saved under `audio/` and `AUDIO_REVIEW.md` marks intelligible audio, no clipping/distortion, adequate volume, and no playback dropout.
- [ ] Firmware version and release tag recorded.

## Promotion Gate

Only after all checks pass:

- [ ] `tools/verify_hardware_evidence.ps1` passes for the completed evidence packet.
- [ ] `tools/verify_consumer_promotion.ps1` passes for the release package and evidence packet.
- [ ] Create a hardware-validated release tag.
- [ ] Mark GitHub release as non-prerelease.
- [ ] Attach updated release notes with test evidence.
