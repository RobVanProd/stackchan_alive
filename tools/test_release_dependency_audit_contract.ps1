$ErrorActionPreference = "Stop"
$RepoRoot = Resolve-Path (Join-Path $PSScriptRoot "..")
$source = Get-Content -LiteralPath (Join-Path $RepoRoot "tools\verify_release_package.ps1") -Raw

$required = @(
  '$knownPinnedM5UnifiedWithTransitiveCopy',
  '$duplicate.environment -in @("stackchan", "stackchan_servo_calibration")',
  '$duplicate.count -eq 2',
  '$duplicateEntries.Count -eq 2',
  '$duplicateVersions[0] -eq "0.2.17"',
  '$duplicateVersions[1] -eq "0.2.19"',
  '$_.required -eq "M5Stack/M5Unified @ 0.2.17"',
  '$_.required -eq "M5Stack/M5Unified @ ^0.2.5"',
  '-not $knownPinnedM5UnifiedWithTransitiveCopy'
)

foreach ($fragment in $required) {
  if (-not $source.Contains($fragment)) {
    throw "Release dependency audit contract missing fragment: $fragment"
  }
}

Write-Output "Release dependency audit contract verified."
