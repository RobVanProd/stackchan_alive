param(
  [string]$Version,
  [string]$PackageRoot,
  [string]$ZipPath,
  [string]$ExpectedCommit,
  [switch]$AllowDirtyPackage
)

$ErrorActionPreference = "Stop"

$repoRoot = Resolve-Path (Join-Path $PSScriptRoot "..")
Set-Location $repoRoot

if ([string]::IsNullOrWhiteSpace($Version)) {
  $Version = (git describe --tags --always --dirty).Trim()
}

if ([string]::IsNullOrWhiteSpace($ExpectedCommit)) {
  $ExpectedCommit = (git rev-parse HEAD).Trim()
}

$cleanupDir = $null

if (-not [string]::IsNullOrWhiteSpace($ZipPath)) {
  if (-not (Test-Path -LiteralPath $ZipPath)) {
    throw "Missing release ZIP: $ZipPath"
  }

  $tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) "stackchan-release-verify"
  $cleanupDir = Join-Path $tempRoot ([System.Guid]::NewGuid().ToString("N"))
  New-Item -ItemType Directory -Force -Path $cleanupDir | Out-Null
  Expand-Archive -LiteralPath $ZipPath -DestinationPath $cleanupDir
  $PackageRoot = $cleanupDir
}

if ([string]::IsNullOrWhiteSpace($PackageRoot)) {
  $PackageRoot = Join-Path $repoRoot "output/release/$Version"
}

if (-not (Test-Path -LiteralPath $PackageRoot)) {
  throw "Missing package directory: $PackageRoot"
}

$packageRootPath = (Resolve-Path $PackageRoot).Path

function Join-PackagePath {
  param([string]$RelativePath)
  return Join-Path $packageRootPath ($RelativePath -replace "/", "\")
}

function Assert-File {
  param(
    [string]$RelativePath,
    [int64]$MinBytes = 1
  )

  $path = Join-PackagePath $RelativePath
  if (-not (Test-Path -LiteralPath $path)) {
    throw "Missing required package file: $RelativePath"
  }

  $item = Get-Item -LiteralPath $path
  if ($item.Length -lt $MinBytes) {
    throw "Package file is too small: $RelativePath ($($item.Length) bytes)"
  }
}

function Assert-Bytes {
  param(
    [string]$RelativePath,
    [byte[]]$Expected,
    [int]$Offset = 0
  )

  $path = Join-PackagePath $RelativePath
  $bytes = [System.IO.File]::ReadAllBytes($path)
  if ($bytes.Length -lt ($Offset + $Expected.Length)) {
    throw "Package file is too small for signature check: $RelativePath"
  }

  for ($i = 0; $i -lt $Expected.Length; $i++) {
    if ($bytes[$Offset + $i] -ne $Expected[$i]) {
      throw "Invalid file signature: $RelativePath"
    }
  }
}

$requiredFiles = @(
  "DEPENDENCIES.md",
  "RELEASE_NOTES.md",
  "SHA256SUMS.txt",
  "release_manifest.json",
  "docs/DEVICE_BRINGUP.md",
  "docs/PRODUCTION_READINESS.md",
  "docs/README.md",
  "docs/RELEASE_PROCESS.md",
  "docs/ROLLOUT_CHECKLIST.md",
  "firmware/display_only/bootloader.bin",
  "firmware/display_only/firmware.bin",
  "firmware/display_only/firmware.elf",
  "firmware/display_only/partitions.bin",
  "firmware/servo_calibration/bootloader.bin",
  "firmware/servo_calibration/firmware.bin",
  "firmware/servo_calibration/firmware.elf",
  "firmware/servo_calibration/partitions.bin",
  "media/stackchan_alive_preview.gif",
  "media/stackchan_alive_preview.mp4",
  "media/stackchan_alive_preview.png",
  "tools/flash_device.cmd",
  "tools/flash_device.ps1",
  "tools/publish_release.cmd",
  "tools/publish_release.ps1",
  "tools/run_device_preflight.cmd",
  "tools/run_device_preflight.ps1",
  "tools/start_hardware_evidence.cmd",
  "tools/start_hardware_evidence.ps1",
  "tools/verify_hardware_evidence.cmd",
  "tools/verify_hardware_evidence.ps1",
  "tools/verify_published_release.cmd",
  "tools/verify_published_release.ps1",
  "tools/verify_release_package.cmd",
  "tools/verify_release_package.ps1",
  "provenance/firmware.yml",
  "provenance/platformio.ini",
  "provenance/release.yml",
  "provenance/requirements-preview.txt"
)

foreach ($file in $requiredFiles) {
  Assert-File $file
}

Assert-File "firmware/display_only/firmware.bin" 100000
Assert-File "firmware/servo_calibration/firmware.bin" 100000
Assert-File "media/stackchan_alive_preview.png" 1000
Assert-File "media/stackchan_alive_preview.gif" 1000
Assert-File "media/stackchan_alive_preview.mp4" 1000

Assert-Bytes "media/stackchan_alive_preview.png" ([byte[]](0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a))
Assert-Bytes "media/stackchan_alive_preview.gif" ([byte[]](0x47, 0x49, 0x46, 0x38))
Assert-Bytes "media/stackchan_alive_preview.mp4" ([byte[]](0x66, 0x74, 0x79, 0x70)) 4

$manifestPath = Join-PackagePath "release_manifest.json"
$manifest = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json

if ($manifest.version -ne $Version) {
  throw "Manifest version mismatch: expected $Version, got $($manifest.version)"
}

if ($manifest.commit -ne $ExpectedCommit) {
  throw "Manifest commit mismatch: expected $ExpectedCommit, got $($manifest.commit)"
}

if ($manifest.board -ne "m5stack-cores3") {
  throw "Manifest board mismatch: $($manifest.board)"
}

if ($manifest.defaultEnvironment -ne "stackchan") {
  throw "Manifest defaultEnvironment mismatch: $($manifest.defaultEnvironment)"
}

$envs = @($manifest.includedEnvironments)
if (-not ($envs -contains "stackchan") -or -not ($envs -contains "stackchan_servo_calibration")) {
  throw "Manifest missing expected environments"
}

if ($manifest.status -notmatch "hardware validation pending") {
  throw "Manifest status must state that hardware validation is pending"
}

if ($manifest.dirty -and -not $AllowDirtyPackage) {
  throw "Release package manifest reports a dirty source worktree"
}

if ($manifest.dependencyReport -ne "DEPENDENCIES.md") {
  throw "Manifest dependencyReport mismatch: $($manifest.dependencyReport)"
}

foreach ($file in @($manifest.includedTools)) {
  Assert-File $file
}

foreach ($file in @($manifest.provenanceFiles)) {
  Assert-File $file
}

$dependenciesText = Get-Content -LiteralPath (Join-PackagePath "DEPENDENCIES.md") -Raw
$dependencyPatterns = @(
  "PlatformIO Core",
  "pillow==12.2.0",
  "imageio==2.37.3",
  "imageio-ffmpeg==0.6.0",
  "stackchan-arduino",
  "b7b98f5",
  "SCServo",
  "ee6ee4a"
)

foreach ($pattern in $dependencyPatterns) {
  if ($dependenciesText -notmatch [regex]::Escape($pattern)) {
    throw "DEPENDENCIES.md missing expected text: $pattern"
  }
}

$releaseNotes = Get-Content -LiteralPath (Join-PackagePath "RELEASE_NOTES.md") -Raw
if ($releaseNotes -notmatch [regex]::Escape($ExpectedCommit)) {
  throw "RELEASE_NOTES.md missing expected commit"
}
if ($releaseNotes -notmatch "Hardware validation is still required") {
  throw "RELEASE_NOTES.md must state that hardware validation is still required"
}

$hashPath = Join-PackagePath "SHA256SUMS.txt"
$hashLines = Get-Content -LiteralPath $hashPath | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
$seen = @{}

foreach ($line in $hashLines) {
  if ($line -notmatch "^([a-f0-9]{64})  (.+)$") {
    throw "Invalid SHA256SUMS line: $line"
  }

  $expectedHash = $Matches[1]
  $relativePath = $Matches[2]
  $filePath = Join-PackagePath $relativePath

  if (-not (Test-Path -LiteralPath $filePath)) {
    throw "SHA256SUMS references missing file: $relativePath"
  }

  if ($seen.ContainsKey($relativePath)) {
    throw "SHA256SUMS contains duplicate entry: $relativePath"
  }

  $seen[$relativePath] = $true
  $actualHash = (Get-FileHash -Algorithm SHA256 -LiteralPath $filePath).Hash.ToLowerInvariant()
  if ($actualHash -ne $expectedHash) {
    throw "SHA256 mismatch for $relativePath"
  }
}

$packagedFiles = Get-ChildItem -LiteralPath $packageRootPath -File -Recurse |
  ForEach-Object { $_.FullName.Substring($packageRootPath.Length + 1).Replace("\", "/") } |
  Where-Object { $_ -ne "SHA256SUMS.txt" }

foreach ($file in $packagedFiles) {
  if (-not $seen.ContainsKey($file)) {
    throw "SHA256SUMS missing entry for $file"
  }
}

foreach ($file in $seen.Keys) {
  if ($packagedFiles -notcontains $file) {
    throw "SHA256SUMS has extra entry for $file"
  }
}

Write-Host "Release package verified:"
Write-Host $packageRootPath

if ($cleanupDir) {
  $resolvedCleanup = (Resolve-Path $cleanupDir).Path
  $resolvedTempRoot = (Resolve-Path $tempRoot).Path
  if (-not $resolvedCleanup.StartsWith($resolvedTempRoot, [System.StringComparison]::OrdinalIgnoreCase)) {
    throw "Refusing to clean unexpected verification directory: $resolvedCleanup"
  }
  Remove-Item -LiteralPath $resolvedCleanup -Recurse -Force
}
