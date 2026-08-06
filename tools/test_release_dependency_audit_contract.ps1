$ErrorActionPreference = "Stop"
$RepoRoot = Resolve-Path (Join-Path $PSScriptRoot "..")
$source = Get-Content -LiteralPath (Join-Path $RepoRoot "tools\verify_release_package.ps1") -Raw

$required = @(
  'Assert-StackchanSingleResolvedPackageVersion',
  '-Name "M5GFX" -ExpectedVersion "0.2.24"',
  '-Name "M5Unified" -ExpectedVersion "0.2.17"',
  '$knownLegacyScServo',
  '-not $knownLegacyScServo'
)

$forbidden = @(
  '$knownPinnedM5GfxWithTransitiveCopy',
  '$knownPinnedM5UnifiedWithTransitiveCopy',
  '$duplicateVersions[1] -eq "0.2.26"',
  '$duplicateVersions[1] -eq "0.2.19"'
)

foreach ($fragment in $required) {
  if (-not $source.Contains($fragment)) {
    throw "Release dependency audit contract missing fragment: $fragment"
  }
}

foreach ($fragment in $forbidden) {
  if ($source.Contains($fragment)) {
    throw "Release dependency audit contract retains a rejected M5 duplicate policy: $fragment"
  }
}

Write-Output "Release dependency audit contract verified."
