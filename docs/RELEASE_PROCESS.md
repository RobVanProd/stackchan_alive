# Release Process

This project can produce a pre-device review release now and a hardware-validated release later.

## Local Package

```powershell
.\tools\package_release.cmd -Version <version>
```

The package is written under `output/release/<version>/` and includes firmware binaries, preview media, readiness docs, dependency provenance, a machine-readable dependency lock, copied build inputs, flash helpers, and SHA256 checksums.
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

Dry-run the release-binary flasher before connecting hardware:

```powershell
.\tools\flash_release_firmware.cmd -PackageZip output\release\stackchan_alive_<version>.zip -Firmware display_only -DryRun -Monitor -Port COM3
```

Create a hardware evidence packet when testing a physical device:

```powershell
.\tools\start_hardware_evidence.cmd -ReleaseTag <version> -PackageZip output\release\stackchan_alive_<version>.zip -Port COM3
```

Packet creation copies the tested ZIP and records `logs/package_verify.log`. Promotion evidence must include that successful package-verification transcript unless the verifier is run with `-AllowMissingPackage` for a diagnostic-only packet.
The packet also includes generated `RUN_*.cmd` files for display flashing, servo calibration flashing, soak logging, package verification, and final evidence verification.

To prepare the release for arrival-day testing in one no-hardware-safe step:

```powershell
.\tools\prepare_device_arrival.cmd -ReleaseTag <version> -PackageZip output\release\stackchan_alive_<version>.zip -Port COM3
```

If you only have an extracted release ZIP, run the same helper from inside the extracted package folder:

```powershell
.\tools\prepare_device_arrival.cmd -Port COM3
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

The release workflow builds both firmware variants, runs native logic tests, compile-checks the embedded test firmware, renders preview media, creates and verifies an auditable package, and attaches the package plus individual preview and firmware files to a GitHub release.

If GitHub Actions cannot run, publish the already verified package with the manual release helper:

```powershell
.\tools\publish_release.cmd -Version <version> -CreateTag -PushTag
```

The manual helper verifies the local ZIP, uploads the same assets as the workflow, downloads the GitHub-hosted ZIP, and verifies that remote copy against the tag commit.

Audit an existing GitHub release after publication:

```powershell
.\tools\verify_published_release.cmd -Version <version>
```

The published-release verifier checks the uploaded asset set, compares asset sizes and SHA256 digests against the local package, downloads the GitHub ZIP, and runs the package verifier on that downloaded copy.

Stage a local handoff page with direct links to the ZIP, image, video, GIF, release notes, and checksums:

```powershell
.\tools\share_release.cmd -Version <version>
```

If `cloudflared` is installed, add `-CloudflareTunnel` to start a tunnel for remote review. The script writes the static share folder under `output/share/<version>/`.
When the quick tunnel URL is available, the script prints the public `trycloudflare.com` URL and keeps the local server plus tunnel running in hidden background processes.

Use prerelease tags until the physical device has passed the rollout gates in `docs/PRODUCTION_READINESS.md`.

The hardware rollout checklist lives in `docs/ROLLOUT_CHECKLIST.md`.
