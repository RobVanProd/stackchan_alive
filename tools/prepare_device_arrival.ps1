param(
  [string]$ReleaseTag = "",
  [string]$PackageZip = "",
  [string]$PackageRoot = "",
  [string]$ExpectedCommit = "",
  [string]$Port = "",
  [string]$Operator = "",
  [string]$DeviceId = "",
  [string]$ShareRoot = "",
  [switch]$AllowIncompleteMetadata,
  [switch]$AllowDirtyPackage,
  [string]$ToolchainAllowlistPath = "",
  [string]$GitExecutable = "",
  [string]$PythonExecutable = "",
  [string]$PlatformioExecutable = "",
  [string]$LegacyCoreDir = "",
  [string]$ReleaseCoreDir = ""
)

$ErrorActionPreference = "Stop"

$repoRoot = Resolve-Path (Join-Path $PSScriptRoot "..")
Set-Location $repoRoot

if (-not [string]::IsNullOrWhiteSpace($PackageZip) -and
    -not [string]::IsNullOrWhiteSpace($PackageRoot)) {
  throw "Pass only one of -PackageZip or -PackageRoot."
}

if ([string]::IsNullOrWhiteSpace($ReleaseTag)) {
  if (-not [string]::IsNullOrWhiteSpace($PackageZip)) {
    $zipName = [System.IO.Path]::GetFileName($PackageZip)
    if ($zipName -notmatch "^stackchan_alive_(.+)\.zip$") {
      throw "Pass -ReleaseTag when -PackageZip does not match stackchan_alive_<version>.zip"
    }
    $ReleaseTag = $Matches[1]
  } else {
    $ReleaseTag = (& git -c core.hooksPath=NUL -c core.fsmonitor=false `
      -c maintenance.auto=false -c core.untrackedCache=false `
      describe --tags --always 2>$null | Out-String).Trim()
  }
}
if ([string]::IsNullOrWhiteSpace($ReleaseTag)) {
  throw "Pass -ReleaseTag because it could not be resolved from trusted Git state."
}

if ([string]::IsNullOrWhiteSpace($ExpectedCommit)) {
  $ExpectedCommit = (& git -c core.hooksPath=NUL -c core.fsmonitor=false `
    -c maintenance.auto=false -c core.untrackedCache=false `
    rev-parse HEAD 2>$null | Out-String).Trim()
}
if ([string]::IsNullOrWhiteSpace($ExpectedCommit)) {
  throw "Pass -ExpectedCommit because it could not be resolved from trusted Git state."
}

if ([string]::IsNullOrWhiteSpace($PackageZip) -and [string]::IsNullOrWhiteSpace($PackageRoot)) {
  if (Test-Path -LiteralPath (Join-Path $repoRoot "release_manifest.json") -PathType Leaf) {
    $PackageRoot = $repoRoot
  } else {
    $PackageZip = Join-Path $repoRoot "output/release/stackchan_alive_$ReleaseTag.zip"
  }
}

if (-not [string]::IsNullOrWhiteSpace($PackageZip) -and -not (Test-Path -LiteralPath $PackageZip)) {
  throw "Missing package ZIP: $PackageZip"
}

if (-not [string]::IsNullOrWhiteSpace($PackageRoot) -and -not (Test-Path -LiteralPath $PackageRoot)) {
  throw "Missing package root: $PackageRoot"
}

$commit = $ExpectedCommit.ToLowerInvariant()

if (-not $AllowIncompleteMetadata) {
  $missingMetadata = @()
  if ([string]::IsNullOrWhiteSpace($Port)) { $missingMetadata += "-Port" }
  if ([string]::IsNullOrWhiteSpace($Operator)) { $missingMetadata += "-Operator" }
  if ([string]::IsNullOrWhiteSpace($DeviceId)) { $missingMetadata += "-DeviceId" }
  if ($missingMetadata.Count -gt 0) {
    throw "Missing hardware evidence metadata: $($missingMetadata -join ', '). Pass these values for promotion-ready evidence, or use -AllowIncompleteMetadata for diagnostic-only packets."
  }
}

Write-Host "Preparing Stackchan device-arrival packet"
Write-Host "Release: $ReleaseTag"
Write-Host "Commit:  $commit"
if (-not [string]::IsNullOrWhiteSpace($PackageZip)) {
  Write-Host "Package: $PackageZip"
} else {
  Write-Host "Package root: $PackageRoot"
}
if (-not [string]::IsNullOrWhiteSpace($Port)) {
  Write-Host "Port:    $Port"
}

Write-Host ""
Write-Host "==> Verify release package"
$verifyScript = Join-Path $PSScriptRoot "verify_release_package.ps1"
$releaseToolchainArguments = @{
  ToolchainAllowlistPath = $ToolchainAllowlistPath
  GitExecutable = $GitExecutable
  PythonExecutable = $PythonExecutable
  PlatformioExecutable = $PlatformioExecutable
  LegacyCoreDir = $LegacyCoreDir
  ReleaseCoreDir = $ReleaseCoreDir
}
if (-not [string]::IsNullOrWhiteSpace($PackageZip)) {
  if ($AllowDirtyPackage) {
    & $verifyScript -Version $ReleaseTag -ZipPath $PackageZip -ExpectedCommit $commit `
      -AllowDirtyPackage -RequireReleaseEligible @releaseToolchainArguments
  } else {
    & $verifyScript -Version $ReleaseTag -ZipPath $PackageZip -ExpectedCommit $commit `
      -RequireReleaseEligible @releaseToolchainArguments
  }
} else {
  if ($AllowDirtyPackage) {
    & $verifyScript -Version $ReleaseTag -PackageRoot $PackageRoot -ExpectedCommit $commit `
      -AllowDirtyPackage -RequireReleaseEligible @releaseToolchainArguments
  } else {
    & $verifyScript -Version $ReleaseTag -PackageRoot $PackageRoot -ExpectedCommit $commit `
      -RequireReleaseEligible @releaseToolchainArguments
  }
}
if ($LASTEXITCODE -ne 0) {
  throw "Operational release package verification failed before device-arrival preparation."
}

Write-Host ""
Write-Host "==> Dry-run display-only release flash"
$flashScript = Join-Path $PSScriptRoot "flash_release_firmware.ps1"
if (-not [string]::IsNullOrWhiteSpace($PackageZip)) {
  if ($AllowDirtyPackage) {
    & $flashScript -PackageZip $PackageZip -Firmware display_only -Version $ReleaseTag `
      -ExpectedCommit $commit -DryRun -Monitor -Port $Port -AllowDirtyPackage `
      @releaseToolchainArguments
  } else {
    & $flashScript -PackageZip $PackageZip -Firmware display_only -Version $ReleaseTag `
      -ExpectedCommit $commit -DryRun -Monitor -Port $Port @releaseToolchainArguments
  }
} else {
  if ($AllowDirtyPackage) {
    & $flashScript -PackageRoot $PackageRoot -Firmware display_only -Version $ReleaseTag -ExpectedCommit $commit -DryRun -Monitor -Port $Port -AllowDirtyPackage @releaseToolchainArguments
  } else {
    & $flashScript -PackageRoot $PackageRoot -Firmware display_only -Version $ReleaseTag -ExpectedCommit $commit -DryRun -Monitor -Port $Port @releaseToolchainArguments
  }
}

Write-Host ""
Write-Host "==> Create hardware evidence packet"
$evidenceScript = Join-Path $PSScriptRoot "start_hardware_evidence.ps1"
$metadataArgs = @{} + $releaseToolchainArguments
if ($AllowIncompleteMetadata) {
  $metadataArgs["AllowIncompleteMetadata"] = $true
}
if (-not [string]::IsNullOrWhiteSpace($ShareRoot)) {
  $metadataArgs["ShareRoot"] = $ShareRoot
}
if (-not [string]::IsNullOrWhiteSpace($PackageZip)) {
  if ($AllowDirtyPackage) {
    $evidenceOutput = & $evidenceScript -ReleaseTag $ReleaseTag -PackageZip $PackageZip `
      -ExpectedCommit $commit -Port $Port -Operator $Operator -DeviceId $DeviceId `
      -AllowDirtyPackage @metadataArgs
  } else {
    $evidenceOutput = & $evidenceScript -ReleaseTag $ReleaseTag -PackageZip $PackageZip `
      -ExpectedCommit $commit -Port $Port -Operator $Operator -DeviceId $DeviceId @metadataArgs
  }
} else {
  if ($AllowDirtyPackage) {
    $evidenceOutput = & $evidenceScript -ReleaseTag $ReleaseTag -PackageRoot $PackageRoot `
      -ExpectedCommit $commit -Port $Port -Operator $Operator -DeviceId $DeviceId `
      -AllowDirtyPackage @metadataArgs
  } else {
    $evidenceOutput = & $evidenceScript -ReleaseTag $ReleaseTag -PackageRoot $PackageRoot `
      -ExpectedCommit $commit -Port $Port -Operator $Operator -DeviceId $DeviceId @metadataArgs
  }
}
$evidenceOutput | Write-Host
$evidenceRoot = ($evidenceOutput | Select-Object -Last 1).Trim()

if (-not (Test-Path -LiteralPath $evidenceRoot)) {
  throw "Could not locate generated evidence packet from output: $evidenceRoot"
}

Write-Host ""
Write-Host "Device-arrival packet ready:"
Write-Host $evidenceRoot
Write-Host ""
Write-Host "When the device is connected, run these from the evidence packet:"
Write-Host "  .\RUN_DISPLAY_ONLY.cmd"
Write-Host "  .\RUN_BRIDGE_REPLAY.cmd"
Write-Host "  .\RUN_ANDROID_APK_INSTALL.cmd -ApkPath <path-to-apk> -SourceCommit <git-commit>"
Write-Host "  .\RUN_ANDROID_UDP_BEACON_PROBE.cmd"
Write-Host "  .\RUN_ANDROID_COMPANION_PROBE.cmd -Url ws://<phone-lan-ip>:8765/bridge"
Write-Host "  .\RUN_ANDROID_SCREEN_OFF_SOAK.cmd -Url ws://<phone-lan-ip>:8765/bridge"
Write-Host "  .\RUN_ANDROID_LOGCAT_CAPTURE.cmd  # only after Android service failures"
Write-Host "  .\RUN_SERVO_CALIBRATION.cmd"
Write-Host "  .\RUN_SOAK_MONITOR.cmd"
Write-Host "  .\RUN_ADD_MEDIA.cmd -Type Photo C:\path\stackchan-face.jpg"
Write-Host "  .\RUN_ADD_MEDIA.cmd -Type Audio C:\path\stackchan-speaker.wav"
Write-Host "  .\RUN_PROGRESS_CHECK.cmd"
Write-Host "  .\RUN_ROLLOUT_STATUS.cmd"
Write-Host "  .\RUN_EVIDENCE_VERIFY.cmd"
