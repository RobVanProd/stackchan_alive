# Rollout Checklist

Use this as the arrival-day test record. Do not promote a release from prerelease until every gate has explicit evidence.

## Build Evidence

- [ ] `pio run -e stackchan` passes.
- [ ] `pio run -e stackchan_servo_calibration` passes.
- [ ] `pio test -e native_logic` passes.
- [ ] `pio test -e stackchan --without-uploading --without-testing` passes.
- [ ] `tools/run_device_preflight.ps1` passes.
- [ ] GitHub Actions `Firmware` workflow is green on `main`.
- [ ] Release package ZIP contains firmware, media, docs, manifest, dependency provenance, `dependency_lock.json`, copied build inputs, and checksums.
- [ ] `tools/verify_release_package.ps1` passes for the release ZIP.
- [ ] `tools/flash_release_firmware.ps1 -PackageZip <zip> -Firmware display_only -DryRun -Monitor` passes for the release ZIP.
- [ ] Hardware evidence packet created with `tools/start_hardware_evidence.ps1`.
- [ ] Evidence packet includes the tested ZIP and `logs/package_verify.log`, or records a verified extracted package root.
- [ ] If testing from an extracted release package, `tools/prepare_device_arrival.ps1 -Port <COM>` passes from inside that package root.

## Display-Only Flash

Command:

```powershell
.\tools\flash_release_firmware.cmd -PackageZip output\release\stackchan_alive_<version>.zip -Firmware display_only -Monitor
```

Pass criteria:

- [ ] Device boots without reset loop.
- [ ] Display shows the procedural face.
- [ ] Serial log includes dry-run servo mode.
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
- [ ] Firmware version and release tag recorded.

## Promotion Gate

Only after all checks pass:

- [ ] `tools/verify_hardware_evidence.ps1` passes for the completed evidence packet.
- [ ] Create a hardware-validated release tag.
- [ ] Mark GitHub release as non-prerelease.
- [ ] Attach updated release notes with test evidence.
