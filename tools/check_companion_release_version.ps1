param(
  [string]$Root = "",
  [string]$ExpectedVersion = "",
  [switch]$Json
)

$ErrorActionPreference = "Stop"

if ([string]::IsNullOrWhiteSpace($Root)) {
  $Root = Resolve-Path (Join-Path $PSScriptRoot "..")
} else {
  $Root = Resolve-Path $Root
}

function Read-SingleMatch {
  param(
    [string]$RelativePath,
    [string]$Pattern,
    [string]$Label
  )

  $path = Join-Path $Root $RelativePath
  if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
    throw "$Label source is missing: $RelativePath"
  }
  $matches = [regex]::Matches((Get-Content -LiteralPath $path -Raw), $Pattern)
  if ($matches.Count -ne 1) {
    throw "Expected exactly one $Label declaration in $RelativePath; found $($matches.Count)."
  }
  return [string]$matches[0].Groups[1].Value
}

$versions = [ordered]@{
  gradleProject = Read-SingleMatch "companion/build.gradle.kts" '(?m)^\s*version\s*=\s*"([^"]+)"\s*$' "Gradle project version"
  android = Read-SingleMatch "companion/app-android/build.gradle.kts" '(?m)^\s*versionName\s*=\s*"([^"]+)"\s*$' "Android versionName"
  desktop = Read-SingleMatch "companion/app-desktop/build.gradle.kts" '(?m)^\s*packageVersion\s*=\s*"([^"]+)"\s*$' "desktop packageVersion"
  protocolIdentity = Read-SingleMatch "companion/core/src/commonMain/kotlin/dev/stackchan/companion/core/CompanionIdentity.kt" '(?m)^\s*const\s+val\s+appVersion\s*=\s*"([^"]+)"\s*$' "protocol appVersion"
}
$versionCodeText = Read-SingleMatch "companion/app-android/build.gradle.kts" '(?m)^\s*versionCode\s*=\s*([1-9]\d*)\s*$' "Android versionCode"
$normalizedExpected = $ExpectedVersion.Trim()
if ($normalizedExpected.StartsWith("v")) {
  $normalizedExpected = $normalizedExpected.Substring(1)
}

$issues = @()
$distinctVersions = @($versions.Values | Select-Object -Unique)
if ($distinctVersions.Count -ne 1) {
  $issues += "Companion version declarations disagree: " + (($versions.GetEnumerator() | ForEach-Object { "$($_.Key)=$($_.Value)" }) -join ", ")
}
$actualVersion = [string]$versions.gradleProject
if ($actualVersion -notmatch '^\d+\.\d+\.\d+(?:[-+][0-9A-Za-z.-]+)?$') {
  $issues += "Companion version is not semantic version syntax: $actualVersion"
}
if (-not [string]::IsNullOrWhiteSpace($normalizedExpected) -and $actualVersion -ne $normalizedExpected) {
  $issues += "Tag/version mismatch: expected $normalizedExpected from $ExpectedVersion, got $actualVersion."
}

$status = if ($issues.Count -eq 0) { "ready" } else { "blocked-version-mismatch" }
$report = [ordered]@{
  schema = "stackchan.companion-release-version.v1"
  status = $status
  expectedVersion = $normalizedExpected
  actualVersion = $actualVersion
  versionCode = [int]$versionCodeText
  declarations = $versions
  issues = @($issues)
}

if ($Json) {
  $report | ConvertTo-Json -Depth 5
} else {
  Write-Host "Companion release version: $status"
  Write-Host "Version: $actualVersion  Android versionCode: $versionCodeText"
  foreach ($issue in $issues) { Write-Host "- $issue" }
}

if ($issues.Count -gt 0) {
  exit 1
}
