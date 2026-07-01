# Release Process

This project can produce a pre-device review release now and a hardware-validated release later.

## Local Package

```powershell
.\tools\package_release.cmd -Version <version>
```

The package is written under `output/release/<version>/` and includes firmware binaries, preview media, an expression QA sheet, a root `QUICKSTART.md`, readiness docs, generated readiness reports, the voice/personality profile, dependency provenance, a machine-readable dependency lock, a dependency audit, copied build inputs, flash helpers, a manifest that names the readiness/media/voice artifacts, and SHA256 checksums.
The package command refuses a dirty source worktree by default so code and configuration match the manifest commit. Regenerated preview media is treated as a release artifact.
Release packages also include flash, evidence-capture, and package-verification helper scripts under `tools/`. Use `tools/flash_release_firmware.cmd` to flash the exact binaries from a verified ZIP instead of rebuilding during arrival-day testing.

Before flashing or publishing, run the no-hardware preflight:

```powershell
.\tools\run_device_preflight.cmd
```

The preflight also checks that servo-calibration flashing is blocked unless `-ConfirmServoRisk` is present and that dry-run upload commands render correctly.

Verify the package before sharing it:

```powershell
.\tools\verify_release_package.cmd -Version <version> -ZipPath output\release\stackchan_alive_<version>.zip
.\tools\run_device_preflight.cmd -PackageZip output\release\stackchan_alive_<version>.zip
```

The package verifier rejects direct Git dependencies without refs and resolved Git dependencies without SHA evidence. Known upstream transitive declarations, such as the current `stackchan-arduino` `SCServo` Git dependency, must be recorded in `dependency_lock.json` instead of being hidden in console output.

Dry-run the release-binary flasher before connecting hardware:

```powershell
.\tools\flash_release_firmware.cmd -PackageZip output\release\stackchan_alive_<version>.zip -Firmware display_only -DryRun -Monitor -Port COM3
```

Create a hardware evidence packet when testing a physical device:

```powershell
.\tools\start_hardware_evidence.cmd -ReleaseTag <version> -PackageZip output\release\stackchan_alive_<version>.zip -Port COM3 -Operator "Your Name" -DeviceId STACKCHAN-001
```

Packet creation copies the tested ZIP and records `logs/package_verify.log`. Promotion evidence must include that successful package-verification transcript unless the verifier is run with `-AllowMissingPackage` for a diagnostic-only packet.
The packet also includes generated `RUN_*.cmd` files for display flashing, servo calibration flashing, soak logging, package verification, and final evidence verification.

To prepare the release for arrival-day testing in one no-hardware-safe step:

```powershell
.\tools\prepare_device_arrival.cmd -ReleaseTag <version> -PackageZip output\release\stackchan_alive_<version>.zip -Port COM3 -Operator "Your Name" -DeviceId STACKCHAN-001
```

If you only have an extracted release ZIP, run the same helper from inside the extracted package folder:

```powershell
.\tools\prepare_device_arrival.cmd -Port COM3 -Operator "Your Name" -DeviceId STACKCHAN-001
```

Before promoting a prerelease, verify the completed hardware evidence packet:

```powershell
.\tools\verify_hardware_evidence.cmd -EvidenceRoot output\hardware-evidence\<packet-folder>
```

## GitHub Release

For validated releases, push a tag:

```powershell
git tag <version>
git push origin <version>
```

The release workflow builds both firmware variants, runs native logic tests, compile-checks the embedded test firmware, renders preview media, creates and verifies an auditable package, and attaches the package, ZIP SHA256 sidecar, individual preview media, expression-sheet, and firmware files to a GitHub release.

If GitHub Actions cannot run, publish the already verified package with the manual release helper:

```powershell
.\tools\publish_release.cmd -Version <version> -CreateTag -PushTag
```

The manual helper verifies the local ZIP, uploads the same assets as the workflow, downloads the GitHub-hosted ZIP plus ZIP SHA256 sidecar, and verifies that remote copy against the tag commit.

Audit an existing GitHub release after publication:

```powershell
.\tools\verify_published_release.cmd -Version <version>
```

The published-release verifier checks the uploaded asset set, compares asset sizes and SHA256 digests against the local package, confirms the remote GitHub tag resolves to the expected package commit, downloads the GitHub ZIP plus ZIP SHA256 sidecar, validates the sidecar against the downloaded ZIP, and runs the package verifier on that downloaded copy.

Stage a local handoff page with direct links to the ZIP, ZIP SHA256 sidecar, image, expression sheet, video, GIF, release notes, readiness report, and checksums:

```powershell
.\tools\share_release.cmd -Version <version>
```

If `cloudflared` is installed, add `-CloudflareTunnel` to start a tunnel for remote review. The script writes the static share folder under `output/share/<version>/`.
If `cloudflared` is not installed, add `-DownloadCloudflared` to place a local copy under `output/tools/` before starting the tunnel.
From an extracted release package, `tools/share_release.cmd` can infer the version from `release_manifest.json` and creates a temporary ZIP under `output/share/<version>/`.
When the quick tunnel URL is available, the script prints the public `trycloudflare.com` URL, writes it to `output/share/<version>/PUBLIC_URL.txt`, writes process and URL state to `share_status.json`, and keeps the local server plus tunnel running in hidden background processes.
Run `tools/verify_share_release.cmd -Version <version> -RequirePublicUrl` before sending the URL; it checks the handoff page plus the preview PNG, expression sheet, MP4, GIF, readiness report, readiness JSON, ZIP, ZIP SHA256 sidecar, and package checksums over HTTP.
Run `output/share/<version>/STOP_SHARING.cmd` or `tools/stop_share.cmd -Version <version>` to stop the local server and tunnel.

Use prerelease tags until the physical device has passed the rollout gates in `docs/PRODUCTION_READINESS.md`.

The hardware rollout checklist lives in `docs/ROLLOUT_CHECKLIST.md`.
