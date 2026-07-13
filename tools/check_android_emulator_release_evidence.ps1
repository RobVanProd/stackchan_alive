param(
  [Parameter(Mandatory = $true)]
  [string]$EvidencePath,
  [Parameter(Mandatory = $true)]
  [string]$ReleaseApkPath,
  [string]$ExpectedPackageName = "dev.stackchan.companion",
  [int]$MinApiLevel = 35,
  [switch]$Json
)

$ErrorActionPreference = "Stop"
$issues = New-Object System.Collections.Generic.List[string]
$evidence = $null
$releaseApkSha256 = ""
$resolvedEvidencePath = ""
$resolvedReleaseApkPath = ""

if ($MinApiLevel -lt 1) {
  throw "MinApiLevel must be positive."
}

if (-not (Test-Path -LiteralPath $EvidencePath -PathType Leaf)) {
  $issues.Add("emulator evidence JSON is missing: $EvidencePath")
} else {
  $resolvedEvidencePath = [string](Resolve-Path -LiteralPath $EvidencePath)
  try {
    $evidence = Get-Content -Raw -LiteralPath $resolvedEvidencePath | ConvertFrom-Json
  } catch {
    $issues.Add("emulator evidence JSON could not be parsed")
  }
}

if (-not (Test-Path -LiteralPath $ReleaseApkPath -PathType Leaf)) {
  $issues.Add("release APK is missing: $ReleaseApkPath")
} else {
  $resolvedReleaseApkPath = [string](Resolve-Path -LiteralPath $ReleaseApkPath)
  $releaseApkSha256 = (Get-FileHash -Algorithm SHA256 -LiteralPath $resolvedReleaseApkPath).Hash.ToLowerInvariant()
}

$summary = [ordered]@{
  schema = ""
  status = ""
  capturedUtc = ""
  model = ""
  apiLevel = ""
  packageName = ""
  versionName = ""
  versionCode = ""
  apkSha256 = ""
  mainActivityResumed = $false
  bridgeServicePresent = $false
  fatalProcessMatches = $null
  scope = ""
  substitutesForPhysicalEvidence = $null
}

if ($null -ne $evidence) {
  foreach ($name in @("schema", "status", "capturedUtc", "model", "apiLevel", "packageName", "versionName", "versionCode", "apkSha256", "scope")) {
    $summary[$name] = [string]$evidence.$name
  }
  $mainActivityResumed = $evidence.mainActivityResumed -is [bool] -and $evidence.mainActivityResumed -eq $true
  $bridgeServicePresent = $evidence.bridgeServicePresent -is [bool] -and $evidence.bridgeServicePresent -eq $true
  $doesNotSubstituteForPhysicalEvidence = $evidence.substitutesForPhysicalEvidence -is [bool] -and $evidence.substitutesForPhysicalEvidence -eq $false
  $summary.mainActivityResumed = $mainActivityResumed
  $summary.bridgeServicePresent = $bridgeServicePresent
  $summary.fatalProcessMatches = $evidence.fatalProcessMatches
  $summary.substitutesForPhysicalEvidence = $evidence.substitutesForPhysicalEvidence

  if ([string]$evidence.schema -ne "stackchan.android-emulator-launch-smoke.v1") {
    $issues.Add("unexpected emulator evidence schema '$($evidence.schema)'")
  }
  if ([string]$evidence.status -ne "pass") {
    $issues.Add("emulator smoke status is '$($evidence.status)', expected 'pass'")
  }
  if ([string]$evidence.packageName -ne $ExpectedPackageName) {
    $issues.Add("emulator package '$($evidence.packageName)' does not match '$ExpectedPackageName'")
  }

  $apiLevel = 0
  if (-not [int]::TryParse([string]$evidence.apiLevel, [ref]$apiLevel) -or $apiLevel -lt $MinApiLevel) {
    $issues.Add("emulator API '$($evidence.apiLevel)' is below required API $MinApiLevel")
  }
  if ([string]::IsNullOrWhiteSpace([string]$evidence.versionName) -or [string]::IsNullOrWhiteSpace([string]$evidence.versionCode)) {
    $issues.Add("emulator package version identity is incomplete")
  }
  if (-not $mainActivityResumed) {
    $issues.Add("MainActivity was not resumed in emulator evidence")
  }
  if (-not $bridgeServicePresent) {
    $issues.Add("CompanionBridgeService was not present in emulator evidence")
  }

  $fatalMatches = -1
  if (-not [int]::TryParse([string]$evidence.fatalProcessMatches, [ref]$fatalMatches) -or $fatalMatches -ne 0) {
    $issues.Add("emulator evidence fatalProcessMatches must be zero")
  }
  if ([string]$evidence.scope -ne "emulator-install-launch-service-smoke-only") {
    $issues.Add("emulator evidence scope is not the bounded launch-smoke scope")
  }
  if (-not $doesNotSubstituteForPhysicalEvidence) {
    $issues.Add("emulator evidence must explicitly set substitutesForPhysicalEvidence=false")
  }
  if (@($evidence.issues).Count -ne 0) {
    $issues.Add("emulator evidence contains reported issues")
  }

  $evidenceApkSha256 = ([string]$evidence.apkSha256).ToLowerInvariant()
  if ($evidenceApkSha256 -notmatch '^[0-9a-f]{64}$') {
    $issues.Add("emulator evidence APK SHA-256 is missing or malformed")
  } elseif (-not [string]::IsNullOrWhiteSpace($releaseApkSha256) -and $evidenceApkSha256 -ne $releaseApkSha256) {
    $issues.Add("emulator evidence APK SHA-256 does not match the release APK")
  }
}

$status = if ($issues.Count -eq 0) { "ready" } elseif ($null -eq $evidence -or [string]::IsNullOrWhiteSpace($resolvedReleaseApkPath)) { "pending" } else { "not-ready" }
$report = [ordered]@{
  schema = "stackchan.android-emulator-release-evidence-check.v1"
  status = $status
  evidencePath = $resolvedEvidencePath
  releaseApkPath = $resolvedReleaseApkPath
  releaseApkSha256 = $releaseApkSha256
  evidence = $summary
  issues = @($issues)
}

if ($Json) {
  $report | ConvertTo-Json -Depth 6
} else {
  Write-Host "Android emulator release evidence: $status"
  Write-Host "Release APK SHA-256: $releaseApkSha256"
  foreach ($issue in $issues) {
    Write-Host "Issue: $issue"
  }
}

if ($status -ne "ready") {
  exit 2
}
