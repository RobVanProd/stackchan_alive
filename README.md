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

The preflight checks tool availability, dependency pins, flash-helper safety gates, local-share evidence capture, tests, and both firmware builds.

Create an auditable prerelease package:

```powershell
.\tools\package_release.cmd -Version <version>
```

The package includes firmware binaries, preview media, an expression QA sheet, docs, checksums, dependency provenance, a machine-readable dependency lock, readiness reports, and copied build inputs.
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
.\tools\publish_release.cmd -Version <version> -CreateTag -PushCurrentBranch -PushTag
```

Audit the published GitHub release assets:

```powershell
.\tools\verify_published_release.cmd -Version <version>
```

Export a concise post-publish audit that verifies the release, refreshes GitHub Actions status, and summarizes remaining rollout blockers. Add `-UploadToRelease` to attach `RELEASE_AUDIT.md/json` to the GitHub release:

```powershell
.\tools\audit_published_release.cmd -Version <version>
```

Stage a local handoff page for the ZIP, ZIP SHA256 sidecar, preview image, expression sheet, and video, optionally with a Cloudflare tunnel:

```powershell
.\tools\share_release.cmd -Version <version>
.\tools\share_release.cmd -Version <version> -OpenLocal
.\tools\share_release.cmd -Version <version> -Lan
.\tools\share_release.cmd -Version <version> -CloudflareTunnel
.\tools\share_release.cmd -Version <version> -CloudflareTunnel -DownloadCloudflared
```

Use `-OpenLocal` to open the host-only page on this Windows machine after the readiness probe passes. Use `-Lan` when another device on the same Wi-Fi/LAN needs to open the page; it binds to all interfaces, probes the server through loopback, and prints ranked same-network URL candidates while avoiding common virtual adapters. For this Windows machine, use the printed host-only URL or run `output\share\<version>\OPEN_LOCAL_SHARE.cmd`. The share folder also writes `LAN_TROUBLESHOOTING.md` and `share_probe_report.json` with adapter metadata and host-side reachability probes for each candidate.
When `cloudflared` is available, the tunnel command prints the public `trycloudflare.com` URL and writes it to `output\share\<version>\PUBLIC_URL.txt`. Local-only shares are still first-class: `verify_share_release.cmd` records the verified URL in `share_verification_report.json`, and the evidence packet writes `share\VERIFIED_URL.txt` even when no public tunnel exists. `-DownloadCloudflared` places a local copy under `output\tools` when `cloudflared` is not installed on PATH.
From an extracted release package, `.\tools\share_release.cmd -CloudflareTunnel -DownloadCloudflared` infers the release version from `release_manifest.json`.
The share folder also includes `share_status.json` with `loopbackUrl`, `localUrl`, `lanUrls`, LAN diagnostics, host probe results, `OPEN_LOCAL_SHARE.cmd`, plus `STOP_SHARING.cmd` for stopping the local server and tunnel. To clean up every share server started by this repo, run `.\tools\stop_share.cmd -All`; it only stops processes that still match share metadata under `output\share`.
Verify the active local or Cloudflare share before sending it:

```powershell
.\tools\verify_share_release.cmd -Version <version> -RequirePublicUrl
```

Omit `-RequirePublicUrl` when the reviewer is on the same machine or LAN and you intentionally want to pin a local verified share.

Start a device-arrival evidence packet:

```powershell
.\tools\start_hardware_evidence.cmd -ReleaseTag <version> -PackageZip output\release\stackchan_alive_<version>.zip -Port COM3 -Operator "Your Name" -DeviceId STACKCHAN-001
```

When `-PackageZip` is provided, the evidence packet copies the ZIP and writes `logs/package_verify.log`. The hardware evidence verifier requires that package proof by default before promotion.
The packet also writes `BENCH_STATUS.md/json` plus `RUN_*.cmd` files for the exact flash, soak, package verification, progress summary, and evidence verification commands for that release and port.

To run the package verification, display-flash dry-run, and evidence packet creation in one no-hardware-safe step:

```powershell
.\tools\prepare_device_arrival.cmd -ReleaseTag <version> -PackageZip output\release\stackchan_alive_<version>.zip -Port COM3 -Operator "Your Name" -DeviceId STACKCHAN-001
```

If you only have the extracted release ZIP, run the same helper from inside the extracted folder:

```powershell
.\tools\prepare_device_arrival.cmd -Port COM3 -Operator "Your Name" -DeviceId STACKCHAN-001
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
The generator also writes `stackchan_alive_expression_sheet.png`, a six-pose visual QA sheet for idle, listen, think, happy, concern, and sleep expressions.

## Readiness

See [docs/PRODUCTION_READINESS.md](docs/PRODUCTION_READINESS.md) for the current proof level and the hardware gates required before consumer rollout.

Voice and personality direction is defined in [docs/VOICE_PERSONALITY.md](docs/VOICE_PERSONALITY.md), with the machine-readable profile in [data/voice_persona.yaml](data/voice_persona.yaml). Prototype Stackchan Spark audition samples are generated under `docs/media/voice/` with `tools/render_voice_samples.cmd`; run `tools/open_voice_audition.cmd` to open the local MP3 audition page. The current review-only RVC MP3 direction is checked in under `media/voice/rvc/`; open `media/voice/rvc/RVC_AUDITION.html` directly or run `tools/open_voice_audition.cmd -Rvc`. To audition every checked-in MP3 from one local page, run `tools/open_voice_audition.cmd -All`.

Release packaging is documented in [docs/RELEASE_PROCESS.md](docs/RELEASE_PROCESS.md).
Hardware rollout tracking is in [docs/ROLLOUT_CHECKLIST.md](docs/ROLLOUT_CHECKLIST.md).
