param(
  [string]$ReleaseTag = "",
  [string]$PackageZip = "",
  [string]$PackageRoot = "",
  [string]$Port = "",
  [string]$Operator = "",
  [string]$DeviceId = "",
  [switch]$AllowIncompleteMetadata,
  [switch]$AllowDirtyPackage
)

$ErrorActionPreference = "Stop"

$repoRoot = Resolve-Path (Join-Path $PSScriptRoot "..")
Set-Location $repoRoot

function Invoke-GitText {
  param([string[]]$Arguments)

  try {
    $output = & git @Arguments 2>$null
  } catch {
    return ""
  }
  if ($LASTEXITCODE -ne 0) {
    return ""
  }
  return ($output | Out-String).Trim()
}

function Get-ManifestFromPackageRoot {
  param([string]$RootPath)

  if ([string]::IsNullOrWhiteSpace($RootPath)) {
    return $null
  }

  $manifestPath = Join-Path $RootPath "release_manifest.json"
  if (-not (Test-Path -LiteralPath $manifestPath)) {
    return $null
  }

  return Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json
}

function Get-ManifestFromPackageZip {
  param([string]$ZipPath)

  if ([string]::IsNullOrWhiteSpace($ZipPath) -or -not (Test-Path -LiteralPath $ZipPath)) {
    return $null
  }

  $tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) "stackchan-arrival-manifest"
  $extractDir = Join-Path $tempRoot ([System.Guid]::NewGuid().ToString("N"))
  New-Item -ItemType Directory -Force -Path $extractDir | Out-Null
  try {
    Expand-Archive -LiteralPath $ZipPath -DestinationPath $extractDir
    return Get-ManifestFromPackageRoot $extractDir
  } finally {
    if (Test-Path -LiteralPath $extractDir) {
      Remove-Item -LiteralPath $extractDir -Recurse -Force
    }
  }
}

$rootManifest = Get-ManifestFromPackageRoot $repoRoot

if ([string]::IsNullOrWhiteSpace($ReleaseTag)) {
  if ($null -ne $rootManifest) {
    $ReleaseTag = [string]$rootManifest.version
  } else {
    $ReleaseTag = Invoke-GitText @("describe", "--tags", "--always", "--dirty")
  }
}

if ([string]::IsNullOrWhiteSpace($PackageZip) -and [string]::IsNullOrWhiteSpace($PackageRoot) -and $null -ne $rootManifest) {
  $PackageRoot = $repoRoot
}

if ([string]::IsNullOrWhiteSpace($PackageZip) -and [string]::IsNullOrWhiteSpace($PackageRoot)) {
  $PackageZip = Join-Path $repoRoot "output/release/stackchan_alive_$ReleaseTag.zip"
}

if (-not [string]::IsNullOrWhiteSpace($PackageZip) -and -not (Test-Path -LiteralPath $PackageZip)) {
  throw "Missing package ZIP: $PackageZip"
}

if (-not [string]::IsNullOrWhiteSpace($PackageRoot) -and -not (Test-Path -LiteralPath $PackageRoot)) {
  throw "Missing package root: $PackageRoot"
}

$packageManifest = $rootManifest
if ($null -eq $packageManifest -and -not [string]::IsNullOrWhiteSpace($PackageZip)) {
  $packageManifest = Get-ManifestFromPackageZip $PackageZip
}
if ($null -eq $packageManifest -and -not [string]::IsNullOrWhiteSpace($PackageRoot)) {
  $packageManifest = Get-ManifestFromPackageRoot $PackageRoot
}

if ([string]::IsNullOrWhiteSpace($ReleaseTag) -and $null -ne $packageManifest) {
  $ReleaseTag = [string]$packageManifest.version
}

$commit = ""
if ($null -ne $packageManifest) {
  $commit = [string]$packageManifest.commit
}
if ([string]::IsNullOrWhiteSpace($commit)) {
  $commit = Invoke-GitText @("rev-parse", "HEAD")
}
if ([string]::IsNullOrWhiteSpace($commit)) {
  throw "Could not determine release commit from git or package manifest."
}

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
if (-not [string]::IsNullOrWhiteSpace($PackageZip)) {
  if ($AllowDirtyPackage) {
    & $verifyScript -Version $ReleaseTag -ZipPath $PackageZip -ExpectedCommit $commit -AllowDirtyPackage
  } else {
    & $verifyScript -Version $ReleaseTag -ZipPath $PackageZip -ExpectedCommit $commit
  }
} else {
  if ($AllowDirtyPackage) {
    & $verifyScript -Version $ReleaseTag -PackageRoot $PackageRoot -ExpectedCommit $commit -AllowDirtyPackage
  } else {
    & $verifyScript -Version $ReleaseTag -PackageRoot $PackageRoot -ExpectedCommit $commit
  }
}

Write-Host ""
Write-Host "==> Dry-run display-only release flash"
$flashScript = Join-Path $PSScriptRoot "flash_release_firmware.ps1"
if (-not [string]::IsNullOrWhiteSpace($PackageZip)) {
  if ($AllowDirtyPackage) {
    & $flashScript -PackageZip $PackageZip -Firmware display_only -DryRun -Monitor -Port $Port -AllowDirtyPackage
  } else {
    & $flashScript -PackageZip $PackageZip -Firmware display_only -DryRun -Monitor -Port $Port
  }
} else {
  if ($AllowDirtyPackage) {
    & $flashScript -PackageRoot $PackageRoot -Firmware display_only -Version $ReleaseTag -ExpectedCommit $commit -DryRun -Monitor -Port $Port -AllowDirtyPackage
  } else {
    & $flashScript -PackageRoot $PackageRoot -Firmware display_only -Version $ReleaseTag -ExpectedCommit $commit -DryRun -Monitor -Port $Port
  }
}

Write-Host ""
Write-Host "==> Create hardware evidence packet"
$evidenceScript = Join-Path $PSScriptRoot "start_hardware_evidence.ps1"
$metadataArgs = @{}
if ($AllowIncompleteMetadata) {
  $metadataArgs["AllowIncompleteMetadata"] = $true
}
if (-not [string]::IsNullOrWhiteSpace($PackageZip)) {
  if ($AllowDirtyPackage) {
    $evidenceOutput = & $evidenceScript -ReleaseTag $ReleaseTag -PackageZip $PackageZip -Port $Port -Operator $Operator -DeviceId $DeviceId -AllowDirtyPackage @metadataArgs
  } else {
    $evidenceOutput = & $evidenceScript -ReleaseTag $ReleaseTag -PackageZip $PackageZip -Port $Port -Operator $Operator -DeviceId $DeviceId @metadataArgs
  }
} else {
  if ($AllowDirtyPackage) {
    $evidenceOutput = & $evidenceScript -ReleaseTag $ReleaseTag -PackageRoot $PackageRoot -Port $Port -Operator $Operator -DeviceId $DeviceId -AllowDirtyPackage @metadataArgs
  } else {
    $evidenceOutput = & $evidenceScript -ReleaseTag $ReleaseTag -PackageRoot $PackageRoot -Port $Port -Operator $Operator -DeviceId $DeviceId @metadataArgs
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
Write-Host "  .\RUN_SERVO_CALIBRATION.cmd"
Write-Host "  .\RUN_SOAK_MONITOR.cmd"
Write-Host "  .\RUN_ADD_MEDIA.cmd -Type Photo C:\path\stackchan-face.jpg"
Write-Host "  .\RUN_ADD_MEDIA.cmd -Type Audio C:\path\stackchan-speaker.wav"
Write-Host "  .\RUN_PROGRESS_CHECK.cmd"
Write-Host "  .\RUN_EVIDENCE_VERIFY.cmd"
