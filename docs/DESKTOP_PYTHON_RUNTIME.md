# Desktop Managed Python Runtime

The desktop companion can run PC Brain Mode with either a configured/system Python
interpreter or a managed runtime shipped beside the app. V1 release installers should ship
the managed runtime so PC Brain Mode does not depend on the user's PATH.

## Payload Layout

Place the runtime in one of these app-relative folders:

- `python-runtime/`
- `runtime/python/`

`STACKCHAN_BRAIN_PYTHON_RUNTIME` may point to the same layout during lab validation.

Each runtime folder must contain:

- `stackchan-python-runtime.json`
- A platform Python executable:
  - Windows: `python.exe` or `python/python.exe`
  - Linux/macOS: `bin/python3`, `bin/python`, `python3`, or `python`

Manifest template:

```json
{
  "schema": "stackchan.desktop-python-runtime.v1",
  "pythonVersion": "3.12.x",
  "platform": "windows|linux|macos",
  "source": "managed-runtime-build-name-or-url",
  "sha256": "<runtime-archive-or-folder-hash>",
  "license": "Python Software Foundation License Version 2 or approved equivalent",
  "builtAt": "YYYY-MM-DDTHH:MM:SSZ"
}
```

## Preparing A Payload

Use the prep helper to turn an already installed Python 3.10+ runtime into the folder
layout expected by desktop packaging:

```powershell
.\tools\prepare_desktop_python_runtime.ps1 -SourcePython <python.exe-or-python3> -RuntimeRoot output\desktop-python-runtime\windows -SourceName "python-3.12.x-windows" -Force
```

The helper:

- locates and probes a Python 3.10+ executable,
- copies the containing runtime folder into the requested `RuntimeRoot`,
- writes `stackchan-python-runtime.json`,
- records a deterministic SHA-256 over the copied runtime payload, and
- invokes `tools/check_desktop_python_runtime_payload.ps1` before reporting `ready`.

Run a source-only preflight without copying files:

```powershell
.\tools\prepare_desktop_python_runtime.ps1 -DryRun -Json
```

Prepare one payload per desktop platform before release packaging. A Windows runtime only
validates the Windows installer; macOS and Linux installers need their own platform-native
runtime folders and manifests.

## Desktop Packaging

Release builds can package the managed runtime by pointing Gradle at a validated runtime
root:

```powershell
cd companion
.\gradlew.bat :app-desktop:packageDistributionForCurrentOS -Pstackchan.desktop.pythonRuntimeRoot=<path>
```

CI or release scripts can use `STACKCHAN_DESKTOP_PYTHON_RUNTIME_ROOT=<path>` instead of the
Gradle property. When either value is present, `:app-desktop:processResources` first runs
`validateDesktopPythonRuntimePayload`, which invokes
`tools/check_desktop_python_runtime_payload.ps1`, then copies the runtime into packaged app
resources as `python-runtime/`. If the runtime is missing a manifest, executable, or Python
3.10+ probe, the desktop package build fails before an installer is produced.

## Validation

Run:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\tools\check_desktop_python_runtime_payload.ps1 -RuntimeRoot <path> -Json
```

The checker verifies that the manifest is present, declares
`stackchan.desktop-python-runtime.v1`, exposes the expected provenance fields, and that the
platform Python executable runs `--version` with Python 3.10 or newer. It also rejects
placeholder SHA-256 values, requires `platform` to match the current package host, and
requires the manifest `pythonVersion` major/minor to match the executable's reported
version.

Run the checker contract before relying on the payload gate in a release package:

```powershell
.\tools\test_desktop_python_runtime_payload_contract.cmd
```

The contract proves placeholder hashes, platform mismatches, and stale `pythonVersion`
manifests fail while a minimal valid runtime payload reports `ready`.

After the native installer task finishes, bind the installer to the exact processed runtime
resource that Gradle copied:

```powershell
$extractRoot = Join-Path $env:TEMP "stackchan-package-extraction-windows-<unique-id>"
.\tools\export_desktop_package_evidence.ps1 -Platform windows -PackagePath <msi> -RuntimePrepareJsonPath <windows-prepare.json> -ProcessedRuntimeRoot companion\app-desktop\build\resources\main\python-runtime -PackageExtractionRoot $extractRoot -Version <tag> -Commit <commit> -RequireInstallerPayload -Json
```

Use `linux` with the DEB and `macos` with the DMG on their native runners. The exporter writes
`stackchan.desktop-package-evidence.v1`, records the package SHA-256 and processed runtime SHA-256,
then natively extracts the MSI, DEB, or DMG and opens its packaged `app-desktop-*.jar`. It hashes
`python-runtime/` directly from that installer application JAR, validates its runtime manifest and
Python executable, and requires the packaged bridge, provenance, and voice-proof resources. The
report fails when installer content differs from the validated prepare report or Gradle resources.
`tools/test_desktop_package_evidence_contract.ps1` covers extension, platform, processed-runtime,
and installer-runtime tampering failures. Public release evidence requires one ready native report
for every desktop platform and matches each report back to exactly one published package.
Keep the Windows extraction root short; MSI administrative extraction can still encounter the
legacy Windows path limit when both the checkout and destination are deeply nested. CI uses
`RUNNER_TEMP`, and omitting `-PackageExtractionRoot` creates a unique short temporary root.

The desktop app exports this state under `brain_service.python_runtime.managed_runtime` in
diagnostics and C6 brain-supervisor evidence.

## Desktop V1 Evidence Bundle

After Windows, macOS, and Linux runtime payloads are prepared and checked, copy those
checker JSON outputs into the desktop aggregate evidence packet together with C6
supervisor/GUI evidence, package artifact hashes, PC Brain deploy audio proof, quiet-soak
proof, production voice-source readiness, and `DESKTOP_V1_REVIEW.md`:

```powershell
.\tools\check_desktop_v1_evidence_bundle.cmd -EvidenceRoot output\desktop-v1-evidence\latest -WriteTemplate
.\tools\check_desktop_v1_evidence_bundle.cmd -EvidenceRoot output\desktop-v1-evidence\latest -RequireReady -Json
```

The aggregate checker reports `desktop-v1-evidence-ready` only when those release evidence
items all describe the same desktop v1 candidate.

The desktop bundle is then consumed by the final companion aggregate gate:

```powershell
.\tools\check_companion_v1_evidence_bundle.cmd -EvidenceRoot output\companion-v1-evidence\latest -RequireReady -Json
```
