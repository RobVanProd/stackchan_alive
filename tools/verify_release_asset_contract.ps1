param(
  [string]$Version,
  [string]$PackageRoot = "",
  [string]$ZipPath = "",
  [string]$ZipSidecarPath = "",
  [switch]$SkipExternalFiles
)

$ErrorActionPreference = "Stop"

$repoRoot = Resolve-Path (Join-Path $PSScriptRoot "..")
. (Join-Path $PSScriptRoot "release_asset_contract.ps1")

if ([string]::IsNullOrWhiteSpace($Version)) {
  $Version = (git -C $repoRoot describe --tags --always --dirty).Trim()
}

if ([string]::IsNullOrWhiteSpace($PackageRoot)) {
  $PackageRoot = Join-Path $repoRoot "output/release/$Version"
}

if ([string]::IsNullOrWhiteSpace($ZipPath)) {
  $ZipPath = Join-Path $repoRoot "output/release/stackchan_alive_$Version.zip"
}

if ([string]::IsNullOrWhiteSpace($ZipSidecarPath)) {
  $ZipSidecarPath = "$ZipPath.sha256"
}

if (-not (Test-Path -LiteralPath $PackageRoot)) {
  throw "Missing package root for release asset contract verification: $PackageRoot"
}

$packageRootPath = (Resolve-Path $PackageRoot).Path
$packageRootPrefix = $packageRootPath.TrimEnd("\", "/") + [System.IO.Path]::DirectorySeparatorChar

function Get-PackageRelativePath {
  param([string]$Path)

  if ([string]::IsNullOrWhiteSpace($Path)) {
    return ""
  }

  $absolutePath = [System.IO.Path]::GetFullPath($Path)
  if (-not $absolutePath.StartsWith($packageRootPrefix, [System.StringComparison]::OrdinalIgnoreCase)) {
    return ""
  }

  return $absolutePath.Substring($packageRootPrefix.Length).Replace("\", "/")
}

function Assert-AssetEntrySet {
  param(
    [object[]]$Entries,
    [int]$ExpectedCount,
    [string]$Label
  )

  if (@($Entries).Count -ne $ExpectedCount) {
    throw "$Label release asset contract count mismatch: expected $ExpectedCount, got $(@($Entries).Count)"
  }

  $duplicates = @($Entries | Group-Object Name | Where-Object { $_.Count -gt 1 })
  if ($duplicates.Count -gt 0) {
    throw "$Label release asset contract has duplicate asset names: $(@($duplicates | ForEach-Object { $_.Name }) -join ', ')"
  }

  foreach ($entry in $Entries) {
    if ([string]::IsNullOrWhiteSpace([string]$entry.Name)) {
      throw "$Label release asset contract contains an entry with an empty Name."
    }
    if ([string]::IsNullOrWhiteSpace([string]$entry.Path)) {
      throw "$Label release asset contract contains an entry with an empty Path for $($entry.Name)."
    }
    if (@("base", "final", "audit") -notcontains [string]$entry.Phase) {
      throw "$Label release asset contract contains invalid phase '$($entry.Phase)' for $($entry.Name)."
    }
  }
}

$baseEntries = Get-ReleaseBaseAssetEntries -Version $Version -PackageRoot $packageRootPath -ZipPath $ZipPath -ZipSidecarPath $ZipSidecarPath
$finalEntries = Get-ReleaseFinalAssetEntries -Version $Version -PackageRoot $packageRootPath -ZipPath $ZipPath -ZipSidecarPath $ZipSidecarPath

Assert-AssetEntrySet -Entries $baseEntries -ExpectedCount 33 -Label "Base"
Assert-AssetEntrySet -Entries $finalEntries -ExpectedCount 35 -Label "Final"

$manifestPath = Join-Path $packageRootPath "release_manifest.json"
if (-not (Test-Path -LiteralPath $manifestPath)) {
  throw "Missing release manifest for asset contract verification: release_manifest.json"
}

$manifest = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json
$manifestMediaArtifacts = @($manifest.mediaArtifacts)

foreach ($entry in $finalEntries) {
  $relativePath = Get-PackageRelativePath -Path $entry.Path
  if ([string]::IsNullOrWhiteSpace($relativePath)) {
    if (-not $SkipExternalFiles -and -not (Test-Path -LiteralPath $entry.Path)) {
      throw "Release asset contract external file is missing for $($entry.Name): $($entry.Path)"
    }
    continue
  }

  if (-not (Test-Path -LiteralPath $entry.Path)) {
    throw "Release asset contract package file is missing for $($entry.Name): $relativePath"
  }

  if ($relativePath -like "media/*" -and $manifestMediaArtifacts -notcontains $relativePath) {
    throw "Release asset contract media file is not declared in release_manifest.json mediaArtifacts: $relativePath"
  }
}

foreach ($requiredAssetName in @(
  "stackchan_alive_$Version.zip",
  "stackchan_alive_$Version.zip.sha256",
  "GITHUB_ACTIONS_STATUS.md",
  "github_actions_status.json",
  "firmware-display-only.bin",
  "firmware-servo-calibration.bin",
  "bootloader.bin",
  "partitions.bin",
  "stackchan_spark_audition_bright_robot_greeting.mp3",
  "stackchan_spark_thinking.mp3",
  "stackchan_rvc_bright_robot.mp3",
  "stackchan_rvc_thinking_neutral.mp3",
  "stackchan_rvc_safety_neutral.mp3"
)) {
  if (@($finalEntries | Where-Object { $_.Name -eq $requiredAssetName }).Count -ne 1) {
    throw "Release asset contract missing required release asset: $requiredAssetName"
  }
}

Write-Host "Release asset contract verified:"
Write-Host $packageRootPath
