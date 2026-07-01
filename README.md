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
.\tools\package_release.cmd -Version <version>
```

The package includes firmware binaries, preview media, docs, checksums, dependency provenance, a machine-readable dependency lock, and copied build inputs.
By default the package command refuses to run from a dirty source worktree so the manifest commit matches the code and configuration; regenerated preview media is treated as a release artifact.

Verify the package before sharing or publishing, or include it in the preflight:

```powershell
.\tools\verify_release_package.cmd -Version <version> -ZipPath output\release\stackchan_alive_<version>.zip
.\tools\run_device_preflight.cmd -PackageZip output\release\stackchan_alive_<version>.zip
```

Flash the exact display-only firmware binary from a verified release package:

```powershell
.\tools\flash_release_firmware.cmd -PackageZip output\release\stackchan_alive_<version>.zip -Firmware display_only -Monitor
```

Publish a verified prerelease manually when GitHub Actions is unavailable:

```powershell
.\tools\publish_release.cmd -Version <version> -CreateTag -PushTag
```

Audit the published GitHub release assets:

```powershell
.\tools\verify_published_release.cmd -Version <version>
```

Stage a local handoff page for the ZIP, image, and video, optionally with a Cloudflare tunnel:

```powershell
.\tools\share_release.cmd -Version <version>
.\tools\share_release.cmd -Version <version> -CloudflareTunnel
.\tools\share_release.cmd -Version <version> -CloudflareTunnel -DownloadCloudflared
```

When `cloudflared` is available, the tunnel command prints the public `trycloudflare.com` URL. `-DownloadCloudflared` places a local copy under `output\tools` when `cloudflared` is not installed on PATH.

Start a device-arrival evidence packet:

```powershell
.\tools\start_hardware_evidence.cmd -ReleaseTag <version> -PackageZip output\release\stackchan_alive_<version>.zip -Port COM3
```

When `-PackageZip` is provided, the evidence packet copies the ZIP and writes `logs/package_verify.log`. The hardware evidence verifier requires that package proof by default before promotion.
The packet also writes `RUN_*.cmd` files for the exact flash, soak, package verification, and evidence verification commands for that release and port.

To run the package verification, display-flash dry-run, and evidence packet creation in one no-hardware-safe step:

```powershell
.\tools\prepare_device_arrival.cmd -ReleaseTag <version> -PackageZip output\release\stackchan_alive_<version>.zip -Port COM3
```

If you only have the extracted release ZIP, run the same helper from inside the extracted folder:

```powershell
.\tools\prepare_device_arrival.cmd -Port COM3
```

Release ZIPs include `QUICKSTART.md` at the package root with the arrival-day operator flow.

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
