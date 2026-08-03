$ErrorActionPreference = "Stop"

. (Join-Path $PSScriptRoot "firmware_reproducibility_failure.ps1")

$packageText = Get-Content -LiteralPath (Join-Path $PSScriptRoot 'package_release.ps1') -Raw
foreach ($required in @(
  'Save-StackchanFirmwareReproducibilityFailureEvidence',
  'The complete detached worktree remains attached',
  'full-failed-worktree-retained-attached'
)) {
  if (-not (($packageText + "`n" + (Get-Content -LiteralPath `
      (Join-Path $PSScriptRoot 'firmware_reproducibility_failure.ps1') -Raw)).Contains($required))) {
    throw "Production failed-build preservation wiring is missing: $required"
  }
}
if ($packageText.Contains('$failureEvidence.partialBuildPreserved') -or
    $packageText.Contains('Update-StackchanFirmwareReproducibilityFailureEvidence')) {
  throw 'Production failed-build catch still permits partial-copy cleanup of the failed worktree'
}

$root = Join-Path ([System.IO.Path]::GetTempPath()) (
  "stackchan-repro-failure-contract-" + [guid]::NewGuid().ToString("N"))
$cacheRoot = Join-Path $root "cache"
$sourceRoot = Join-Path $root "source"
$failureRoot = Join-Path $root "failure"
try {
  New-Item -ItemType Directory -Force -Path `
    (Join-Path $cacheRoot "cycle-a/logs"), `
    (Join-Path $cacheRoot "cycle-b/stackchan"), `
    (Join-Path $sourceRoot ".pio/build/stackchan"), `
    (Join-Path $sourceRoot ".pio/libdeps/stackchan/private-generated-library"), `
    (Join-Path $sourceRoot "generated/persona") | Out-Null
  Set-Content -LiteralPath (Join-Path $cacheRoot "cycle-a/logs/stackchan-build.log") -Value "compiler failed" -Encoding UTF8
  Set-Content -LiteralPath (Join-Path $cacheRoot "cycle-b/stackchan/firmware.bin") -Value "prior snapshot" -Encoding UTF8
  Set-Content -LiteralPath (Join-Path $sourceRoot ".pio/build/stackchan/partial.o") -Value "partial object" -Encoding UTF8
  Set-Content -LiteralPath (Join-Path $sourceRoot ".pio/libdeps/stackchan/private-generated-library/state.txt") -Value "libdeps state" -Encoding UTF8
  Set-Content -LiteralPath (Join-Path $sourceRoot "generated/persona/failure.wav") -Value "generated state" -Encoding UTF8
  try {
    throw "simulated compiler failure"
  } catch {
    $failure = $_
  }
  $evidence = Save-StackchanFirmwareReproducibilityFailureEvidence `
    -FailureRoot $failureRoot `
    -BuildCacheRoot $cacheRoot `
    -ActiveSourceRoot $sourceRoot `
    -WorktreeStillAttached $true `
    -Failure $failure `
    -SourceCommit ("a" * 40) `
    -SourceEpoch "1700000000"

  foreach ($required in @(
    "build-cache-and-snapshots/cycle-a/logs/stackchan-build.log",
    "build-cache-and-snapshots/cycle-b/stackchan/firmware.bin",
    "FAILURE_EVIDENCE.json"
  )) {
    if (-not (Test-Path -LiteralPath (Join-Path $failureRoot $required) -PathType Leaf)) {
      throw "Failure evidence contract lost required file: $required"
    }
  }
  if (Test-Path -LiteralPath $cacheRoot) {
    throw "Failure evidence contract must move, not duplicate, the exact build cache"
  }
  foreach ($retained in @(
    ".pio/build/stackchan/partial.o",
    ".pio/libdeps/stackchan/private-generated-library/state.txt",
    "generated/persona/failure.wav"
  )) {
    if (-not (Test-Path -LiteralPath (Join-Path $sourceRoot $retained) -PathType Leaf)) {
      throw "Failure evidence contract lost complete worktree state: $retained"
    }
  }
  if ($evidence.fullWorktreePreserved -ne $true -or
      $evidence.worktreeStillAttached -ne $true -or
      $evidence.preservationPolicy -ne "full-failed-worktree-retained-attached") {
    throw "Failure evidence contract did not record complete attached-worktree retention"
  }
} finally {
  if (Test-Path -LiteralPath $root) {
    [System.IO.Directory]::Delete($root, $true)
  }
}

Write-Host "Firmware reproducibility failed-build retention contract passed."
