param()

$ErrorActionPreference = "Stop"
$repoRoot = Resolve-Path (Join-Path $PSScriptRoot "..")
$checker = Join-Path $PSScriptRoot "check_companion_release_version.ps1"
$tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("stackchan-companion-version-" + [guid]::NewGuid().ToString("N"))

function Invoke-Checker {
  param([string]$Root, [string]$ExpectedVersion)
  $output = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $checker -Root $Root -ExpectedVersion $ExpectedVersion -Json 2>&1 | Out-String
  return [ordered]@{ exitCode = $LASTEXITCODE; output = $output }
}

try {
  $current = Invoke-Checker $repoRoot "v1.0.0"
  if ($current.exitCode -ne 0) { throw "Current companion version contract failed: $($current.output)" }
  Write-Host "[ok] current companion declarations match v1.0.0"

  $wrongTag = Invoke-Checker $repoRoot "v9.9.9"
  if ($wrongTag.exitCode -eq 0 -or $wrongTag.output -notmatch "Tag/version mismatch") {
    throw "Expected a mismatched release tag to fail."
  }
  Write-Host "[ok] mismatched release tag is rejected"

  $relativeFiles = @(
    "companion/build.gradle.kts",
    "companion/app-android/build.gradle.kts",
    "companion/app-desktop/build.gradle.kts",
    "companion/core/src/commonMain/kotlin/dev/stackchan/companion/core/CompanionIdentity.kt"
  )
  foreach ($relativeFile in $relativeFiles) {
    $destination = Join-Path $tempRoot $relativeFile
    New-Item -ItemType Directory -Force -Path (Split-Path -Parent $destination) | Out-Null
    Copy-Item -LiteralPath (Join-Path $repoRoot $relativeFile) -Destination $destination
  }
  $desktopPath = Join-Path $tempRoot "companion/app-desktop/build.gradle.kts"
  (Get-Content -LiteralPath $desktopPath -Raw).Replace('packageVersion = "1.0.0"', 'packageVersion = "1.0.1"') |
    Set-Content -LiteralPath $desktopPath -Encoding UTF8
  $drift = Invoke-Checker $tempRoot "v1.0.0"
  if ($drift.exitCode -eq 0 -or $drift.output -notmatch "declarations disagree") {
    throw "Expected cross-platform version drift to fail."
  }
  Write-Host "[ok] cross-platform version drift is rejected"
} finally {
  if (Test-Path -LiteralPath $tempRoot) {
    Remove-Item -LiteralPath $tempRoot -Recurse -Force
  }
}

Write-Host "Companion release version contract tests passed"
