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
platform Python executable runs `--version` with Python 3.10 or newer.

The desktop app exports this state under `brain_service.python_runtime.managed_runtime` in
diagnostics and C6 brain-supervisor evidence.
