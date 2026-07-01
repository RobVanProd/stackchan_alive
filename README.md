# Stackchan

Procedural character runtime for Stack-chan on ESP32-S3/CoreS3-class hardware.

The initial design source is in [docs/stackchan_procedural_runtime_design.pdf](docs/stackchan_procedural_runtime_design.pdf).

## Shape

- `persona/`: emotion, intent, and frame snapshots.
- `motion/`: springs, blink/saccade timing, actuator ownership, and safety limits.
- `face/`: expression-to-geometry mapping and display rendering boundary.
- `io/`: board, servo, display, and sensor adapters.

Only the motion task writes servos. Higher-level code publishes `RobotFrame` snapshots through a single-slot FreeRTOS queue.

## Build

This project is set up for PlatformIO:

```powershell
pio run
```

Servos are disabled by default with `STACKCHAN_ENABLE_SERVOS=0`. The display should run first; only use `stackchan_servo_calibration` after following [docs/DEVICE_BRINGUP.md](docs/DEVICE_BRINGUP.md).

```powershell
pio run -e stackchan
pio run -e stackchan_servo_calibration
```

Run host logic tests and embedded test-firmware compile checks:

```powershell
pio test -e native_logic
pio test -e stackchan --without-uploading --without-testing
```

Run the no-hardware device preflight before flashing or handing off a package:

```powershell
.\tools\run_device_preflight.cmd
```

The preflight checks tool availability, dependency pins, flash-helper safety gates, tests, and both firmware builds.

Create an auditable prerelease package:

```powershell
.\tools\package_release.cmd -Version v0.1.2-device-ready
```

The package includes firmware binaries, preview media, docs, checksums, dependency provenance, and copied build inputs.
By default the package command refuses to run from a dirty source worktree so the manifest commit matches the code and configuration; regenerated preview media is treated as a release artifact.

Verify the package before sharing or publishing, or include it in the preflight:

```powershell
.\tools\verify_release_package.cmd -Version v0.1.2-device-ready -ZipPath output\release\stackchan_alive_v0.1.2-device-ready.zip
.\tools\run_device_preflight.cmd -PackageZip output\release\stackchan_alive_v0.1.2-device-ready.zip
```

Publish a verified prerelease manually when GitHub Actions is unavailable:

```powershell
.\tools\publish_release.cmd -Version v0.1.2-device-ready -CreateTag -PushTag
```

Audit the published GitHub release assets:

```powershell
.\tools\verify_published_release.cmd -Version v0.1.2-device-ready
```

Start a device-arrival evidence packet:

```powershell
.\tools\start_hardware_evidence.cmd -ReleaseTag v0.1.2-device-ready -PackageZip output\release\stackchan_alive_v0.1.2-device-ready.zip -Port COM3
```

When `-PackageZip` is provided, the evidence packet copies the ZIP and writes `logs/package_verify.log`. The hardware evidence verifier requires that package proof by default before promotion.

Verify the completed hardware evidence before promotion:

```powershell
.\tools\verify_hardware_evidence.cmd -EvidenceRoot output\hardware-evidence\<packet-folder>
```

## Preview Media

Generate a hardware-free preview image, GIF, and MP4:

```powershell
python -m pip install -r requirements-preview.txt
python tools/render_preview.py
```

Outputs are written to `docs/media/`.

## Readiness

See [docs/PRODUCTION_READINESS.md](docs/PRODUCTION_READINESS.md) for the current proof level and the hardware gates required before consumer rollout.

Release packaging is documented in [docs/RELEASE_PROCESS.md](docs/RELEASE_PROCESS.md).
Hardware rollout tracking is in [docs/ROLLOUT_CHECKLIST.md](docs/ROLLOUT_CHECKLIST.md).
