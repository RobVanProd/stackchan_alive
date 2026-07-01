param(
  [string]$ReleaseTag = "",
  [string]$PackageZip = "",
  [string]$Port = "",
  [string]$Operator = "",
  [string]$DeviceId = "",
  [switch]$AllowDirtyPackage
)

$ErrorActionPreference = "Stop"

$repoRoot = Resolve-Path (Join-Path $PSScriptRoot "..")
Set-Location $repoRoot

if ([string]::IsNullOrWhiteSpace($ReleaseTag)) {
  $ReleaseTag = (git describe --tags --always --dirty).Trim()
}

if ([string]::IsNullOrWhiteSpace($PackageZip)) {
  $PackageZip = Join-Path $repoRoot "output/release/stackchan_alive_$ReleaseTag.zip"
}

if (-not (Test-Path -LiteralPath $PackageZip)) {
  throw "Missing package ZIP: $PackageZip"
}

$commit = (git rev-parse HEAD).Trim()

Write-Host "Preparing Stackchan device-arrival packet"
Write-Host "Release: $ReleaseTag"
Write-Host "Commit:  $commit"
Write-Host "Package: $PackageZip"
if (-not [string]::IsNullOrWhiteSpace($Port)) {
  Write-Host "Port:    $Port"
}

Write-Host ""
Write-Host "==> Verify release package"
$verifyScript = Join-Path $PSScriptRoot "verify_release_package.ps1"
if ($AllowDirtyPackage) {
  & $verifyScript -Version $ReleaseTag -ZipPath $PackageZip -ExpectedCommit $commit -AllowDirtyPackage
} else {
  & $verifyScript -Version $ReleaseTag -ZipPath $PackageZip -ExpectedCommit $commit
}

Write-Host ""
Write-Host "==> Dry-run display-only release flash"
$flashScript = Join-Path $PSScriptRoot "flash_release_firmware.ps1"
if ($AllowDirtyPackage) {
  & $flashScript -PackageZip $PackageZip -Firmware display_only -DryRun -Monitor -Port $Port -AllowDirtyPackage
} else {
  & $flashScript -PackageZip $PackageZip -Firmware display_only -DryRun -Monitor -Port $Port
}

Write-Host ""
Write-Host "==> Create hardware evidence packet"
$evidenceScript = Join-Path $PSScriptRoot "start_hardware_evidence.ps1"
if ($AllowDirtyPackage) {
  $evidenceOutput = & $evidenceScript -ReleaseTag $ReleaseTag -PackageZip $PackageZip -Port $Port -Operator $Operator -DeviceId $DeviceId -AllowDirtyPackage
} else {
  $evidenceOutput = & $evidenceScript -ReleaseTag $ReleaseTag -PackageZip $PackageZip -Port $Port -Operator $Operator -DeviceId $DeviceId
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
Write-Host "  .\RUN_SERVO_CALIBRATION.cmd"
Write-Host "  .\RUN_SOAK_MONITOR.cmd"
Write-Host "  .\RUN_EVIDENCE_VERIFY.cmd"
