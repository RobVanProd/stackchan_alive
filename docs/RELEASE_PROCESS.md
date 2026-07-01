# Release Process

This project can produce a pre-device review release now and a hardware-validated release later.

## Local Package

```powershell
.\tools\package_release.cmd -Version v0.1.0-device-ready
```

The package is written under `output/release/<version>/` and includes firmware binaries, preview media, readiness docs, dependency provenance, copied build inputs, and SHA256 checksums.
The package command refuses a dirty source worktree by default so code and configuration match the manifest commit. Regenerated preview media is treated as a release artifact.

Verify the package before sharing it:

```powershell
.\tools\verify_release_package.cmd -Version v0.1.0-device-ready -ZipPath output\release\stackchan_alive_v0.1.0-device-ready.zip
```

## GitHub Release

For validated releases, push a tag:

```powershell
git tag v0.1.0-device-ready
git push origin v0.1.0-device-ready
```

The release workflow builds both firmware variants, runs native logic tests, compile-checks the embedded test firmware, renders preview media, creates and verifies an auditable package, and attaches the package plus individual preview and firmware files to a GitHub release.

Use prerelease tags until the physical device has passed the rollout gates in `docs/PRODUCTION_READINESS.md`.

The hardware rollout checklist lives in `docs/ROLLOUT_CHECKLIST.md`.
