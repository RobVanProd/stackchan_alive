param()

$ErrorActionPreference = "Stop"
$checkerPath = Join-Path $PSScriptRoot "check_android_emulator_release_evidence.ps1"
$powerShellExe = (Get-Process -Id $PID).Path
$temporaryDirectory = Join-Path ([System.IO.Path]::GetTempPath()) ("stackchan-emulator-evidence-contract-" + [guid]::NewGuid().ToString("N"))
$apkPath = Join-Path $temporaryDirectory "app-android-release.apk"
$evidencePath = Join-Path $temporaryDirectory "android_emulator_launch_smoke.json"
$passCount = 0

function Write-ContractEvidence {
  param(
    [string]$Status = "pass",
    [string]$PackageName = "dev.stackchan.companion",
    [string]$ApiLevel = "35",
    [bool]$MainActivityResumed = $true,
    [bool]$BridgeServicePresent = $true,
    [int]$FatalProcessMatches = 0,
    [bool]$SubstitutesForPhysicalEvidence = $false,
    [string]$ApkSha256 = ""
  )

  if ([string]::IsNullOrWhiteSpace($ApkSha256)) {
    $ApkSha256 = (Get-FileHash -Algorithm SHA256 -LiteralPath $apkPath).Hash.ToLowerInvariant()
  }
  [ordered]@{
    schema = "stackchan.android-emulator-launch-smoke.v1"
    status = $Status
    capturedUtc = "2026-07-13T12:00:00Z"
    serial = "emulator-5554"
    model = "Android ATD built for x86_64"
    apiLevel = $ApiLevel
    packageName = $PackageName
    versionName = "1.0.0"
    versionCode = "1"
    apkFileName = "app-android-release.apk"
    apkSizeBytes = (Get-Item -LiteralPath $apkPath).Length
    apkSha256 = $ApkSha256
    processId = "1234"
    launchState = "COLD"
    totalTimeMs = 400
    mainActivityResumed = $MainActivityResumed
    bridgeServicePresent = $BridgeServicePresent
    fatalProcessMatches = $FatalProcessMatches
    notificationPermissionPregranted = $true
    scope = "emulator-install-launch-service-smoke-only"
    substitutesForPhysicalEvidence = $SubstitutesForPhysicalEvidence
    issues = @()
  } | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $evidencePath -Encoding UTF8
}

function Invoke-Checker {
  $arguments = @(
    "-NoProfile",
    "-File", $checkerPath,
    "-EvidencePath", $evidencePath,
    "-ReleaseApkPath", $apkPath,
    "-Json"
  )
  $oldErrorActionPreference = $ErrorActionPreference
  $ErrorActionPreference = "Continue"
  try {
    $output = @(& $powerShellExe @arguments 2>&1)
    $exitCode = $LASTEXITCODE
  } finally {
    $ErrorActionPreference = $oldErrorActionPreference
  }
  $text = ($output | Out-String).Trim()
  try {
    $report = $text | ConvertFrom-Json
  } catch {
    throw "Emulator evidence checker output was not valid JSON: $text"
  }
  return [pscustomobject]@{ exitCode = $exitCode; report = $report }
}

function Assert-Case {
  param(
    [string]$Name,
    [int]$ExpectedExitCode,
    [string]$ExpectedStatus,
    [string]$IssuePattern = ""
  )

  $result = Invoke-Checker
  if ($result.exitCode -ne $ExpectedExitCode) {
    throw "$Name returned exit code $($result.exitCode); expected $ExpectedExitCode."
  }
  if ($result.report.status -ne $ExpectedStatus) {
    throw "$Name returned status '$($result.report.status)'; expected '$ExpectedStatus'."
  }
  if (-not [string]::IsNullOrWhiteSpace($IssuePattern) -and (@($result.report.issues) -join "`n") -notmatch [regex]::Escape($IssuePattern)) {
    throw "$Name did not report expected issue '$IssuePattern'."
  }
  $script:passCount++
  Write-Host "[PASS] $Name"
}

try {
  New-Item -ItemType Directory -Force -Path $temporaryDirectory | Out-Null
  [System.IO.File]::WriteAllBytes($apkPath, [byte[]](1..64))

  Write-ContractEvidence
  Assert-Case -Name "matching release APK evidence" -ExpectedExitCode 0 -ExpectedStatus "ready"

  Write-ContractEvidence -ApkSha256 ("0" * 64)
  Assert-Case -Name "stale APK hash is rejected" -ExpectedExitCode 2 -ExpectedStatus "not-ready" -IssuePattern "does not match the release APK"

  Write-ContractEvidence -ApiLevel "34"
  Assert-Case -Name "old emulator API is rejected" -ExpectedExitCode 2 -ExpectedStatus "not-ready" -IssuePattern "below required API 35"

  Write-ContractEvidence -Status "fail"
  Assert-Case -Name "failed launch smoke is rejected" -ExpectedExitCode 2 -ExpectedStatus "not-ready" -IssuePattern "expected 'pass'"

  Write-ContractEvidence -MainActivityResumed $false
  Assert-Case -Name "non-resumed activity is rejected" -ExpectedExitCode 2 -ExpectedStatus "not-ready" -IssuePattern "MainActivity was not resumed"

  Write-ContractEvidence -BridgeServicePresent $false
  Assert-Case -Name "missing bridge service is rejected" -ExpectedExitCode 2 -ExpectedStatus "not-ready" -IssuePattern "CompanionBridgeService was not present"

  Write-ContractEvidence -FatalProcessMatches 1
  Assert-Case -Name "fatal process match is rejected" -ExpectedExitCode 2 -ExpectedStatus "not-ready" -IssuePattern "must be zero"

  Write-ContractEvidence -SubstitutesForPhysicalEvidence $true
  Assert-Case -Name "physical-evidence substitution is rejected" -ExpectedExitCode 2 -ExpectedStatus "not-ready" -IssuePattern "substitutesForPhysicalEvidence=false"

  Write-ContractEvidence -PackageName "dev.example.wrong"
  Assert-Case -Name "wrong package identity is rejected" -ExpectedExitCode 2 -ExpectedStatus "not-ready" -IssuePattern "does not match"

} finally {
  Remove-Item -LiteralPath $temporaryDirectory -Recurse -Force -ErrorAction SilentlyContinue
}

if ($passCount -ne 9) {
  throw "Android emulator release evidence contract did not execute all cases."
}
Write-Host "Android emulator release evidence contract: 9/9 passed"
exit 0
