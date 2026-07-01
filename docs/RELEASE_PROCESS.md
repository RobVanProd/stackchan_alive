# Release Process

This project can produce a pre-device review release now and a hardware-validated release later.

## Local Package

```powershell
.\tools\package_release.cmd -Version v0.1.0-device-ready
```

The package is written under `output/release/<version>/` and includes firmware binaries, preview media, readiness docs, dependency provenance, copied build inputs, and SHA256 checksums.
The package command refuses a dirty source worktree by default so code and configuration match the manifest commit. Regenerated preview media is treated as a release artifact.
Release packages also include flash, evidence-capture, and package-verification helper scripts under `tools/`.

Before flashing or publishing, run the no-hardware preflight:

```powershell
.\tools\run_device_preflight.cmd
```

The preflight also checks that servo-calibration flashing is blocked unless `-ConfirmServoRisk` is present and that dry-run upload commands render correctly.

Verify the package before sharing it:

```powershell
.\tools\verify_release_package.cmd -Version v0.1.0-device-ready -ZipPath output\release\stackchan_alive_v0.1.0-device-ready.zip
.\tools\run_device_preflight.cmd -PackageZip output\release\stackchan_alive_v0.1.0-device-ready.zip
```

Create a hardware evidence packet when testing a physical device:

```powershell
.\tools\start_hardware_evidence.cmd -ReleaseTag v0.1.0-device-ready -PackageZip output\release\stackchan_alive_v0.1.0-device-ready.zip -Port COM3
```

Packet creation copies the tested ZIP and records `logs/package_verify.log`. Promotion evidence must include that successful package-verification transcript unless the verifier is run with `-AllowMissingPackage` for a diagnostic-only packet.

Before promoting a prerelease, verify the completed hardware evidence packet:

```powershell
.\tools\verify_hardware_evidence.cmd -EvidenceRoot output\hardware-evidence\<packet-folder>
```

## GitHub Release

For validated releases, push a tag:

```powershell
git tag v0.1.0-device-ready
git push origin v0.1.0-device-ready
```

The release workflow builds both firmware variants, runs native logic tests, compile-checks the embedded test firmware, renders preview media, creates and verifies an auditable package, and attaches the package plus individual preview and firmware files to a GitHub release.

If GitHub Actions cannot run, publish the already verified package with the manual release helper:

```powershell
.\tools\publish_release.cmd -Version v0.1.0-device-ready -CreateTag -PushTag
```

The manual helper verifies the local ZIP, uploads the same assets as the workflow, downloads the GitHub-hosted ZIP, and verifies that remote copy against the tag commit.

Use prerelease tags until the physical device has passed the rollout gates in `docs/PRODUCTION_READINESS.md`.

The hardware rollout checklist lives in `docs/ROLLOUT_CHECKLIST.md`.
