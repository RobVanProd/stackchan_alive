# Release Process

This project can produce a pre-device review release now and a hardware-validated release later.

## Local Package

```powershell
.\tools\package_release.cmd -Version v0.1.0-device-ready
```

The package is written under `output/release/<version>/` and includes firmware binaries, preview media, readiness docs, and SHA256 checksums.

## GitHub Release

For validated releases, push a tag:

```powershell
git tag v0.1.0-device-ready
git push origin v0.1.0-device-ready
```

The release workflow builds firmware, compile-checks the test firmware, renders preview media, creates a package, and attaches the package plus individual preview and firmware files to a GitHub release.

Use prerelease tags until the physical device has passed the rollout gates in `docs/PRODUCTION_READINESS.md`.
