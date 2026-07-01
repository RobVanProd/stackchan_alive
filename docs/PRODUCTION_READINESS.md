# Production Readiness

Current status: device-ready scaffold, not hardware-certified.

## Proven Now

- Firmware builds for `m5stack-cores3`.
- Display-only and servo-calibration firmware variants are separate PlatformIO environments.
- Runtime dependency pins are declared in `platformio.ini`; release packages record resolved transitive versions.
- Release packages include dependency provenance and copied build inputs.
- GitHub Actions builds firmware on push and pull request.
- Native host tests execute mood, spring, and expression logic without hardware.
- Motion and face tasks read the same latest frame snapshot.
- Servo output is disabled by default until hardware calibration.
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

Until those are done, this repository is production-shaped and test-ready, but not field-proven.
