# Production Readiness

Current status: device-ready scaffold, not hardware-certified.

## Proven Now

- Firmware builds for `m5stack-cores3`.
- Display-only and servo-calibration firmware variants are separate PlatformIO environments.
- Runtime dependency pins are declared in `platformio.ini`; release packages record resolved transitive versions.
- Release packages include dependency provenance, a machine-readable dependency lock, copied build inputs, and a dependency audit that flags duplicate resolved package names or upstream Git requirements that were not directly pinned by this project.
- Release packages can be verified locally before publication, and published release assets can be re-audited after upload.
- Release packages include flash, verification, and hardware evidence-capture helpers.
- Release packages include a binary flasher that writes the exact packaged display-only or servo-calibration firmware.
- Release packages include a manual GitHub publish helper that verifies the uploaded ZIP when GitHub Actions cannot run.
- Published release assets can be audited against the local package by size, SHA256 digest, and downloaded-ZIP verification.
- A local release handoff page can serve the ZIP, preview image, and preview video, with optional Cloudflare tunnel exposure.
- Hardware evidence packets can be verified before release promotion, including proof that the tested ZIP was copied and package-verified.
- Hardware evidence verification rejects completed observation records that report reset loops, missing face display, missing dry-run servo log, missing firmware boot/heartbeat serial markers, heat/brownout, short soak duration, failed power-cycle recovery, invalid calibration ranges, placeholder-only media evidence, header-only media files, or implausibly small media files.
- No-hardware preflight checks can validate toolchain availability, dependency pins, flash-helper safety gates, preview media, hardware evidence verifier gates, tests, builds, and an optional release ZIP before device flashing.
- Release package verification rejects direct Git dependencies without refs and resolved Git dependencies without SHA evidence.
- Release packaging refuses dirty source worktrees by default.
- GitHub Actions workflows are configured for firmware and release checks, but account billing/spending-limit status must allow jobs to start before they can be used as rollout evidence.
- Native host tests execute mood, spring, and expression logic without hardware.
- Motion and face tasks read the same latest frame snapshot.
- Servo output is disabled by default until hardware calibration.
- Servo-enabled flashing requires an explicit `-ConfirmServoRisk` operator acknowledgment.
- Display rendering uses the M5 display backend, not a stub.
- Preview media can be generated without hardware.

## Not Proven Until Device Arrives

- Actual yaw mode and feedback behavior.
- Servo pin mapping on the specific body revision.
- Mechanical limits under load.
- Long-running thermal and power behavior.
- Camera, mic, touch, and proximity integration.

## Consumer Rollout Gate

Do not call this consumer-ready until the physical device passes:

1. Display-only flash and 10-minute idle run.
2. Servo-enabled supervised motion test.
3. Yaw classification and calibration.
4. 30-minute mixed idle/listen/speak soak.
5. Recovery test after USB power cycle.
6. Documented firmware version and calibration values.
7. Hardware evidence packet with the tested release ZIP and successful `logs/package_verify.log`.

Until those are done, this repository is production-shaped and test-ready, but not field-proven.
