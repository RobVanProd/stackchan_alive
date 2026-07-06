param()

$ErrorActionPreference = "Stop"

$repoRoot = Resolve-Path (Join-Path $PSScriptRoot "..")
$checkScript = Join-Path $PSScriptRoot "check_android_play_store_evidence.ps1"
$createdRoots = New-Object System.Collections.Generic.List[string]

function New-TempEvidenceRoot {
  $root = Join-Path ([System.IO.Path]::GetTempPath()) ("stackchan-play-store-contract-" + [guid]::NewGuid().ToString("N"))
  $createdRoots.Add($root) | Out-Null
  New-Item -ItemType Directory -Force -Path $root | Out-Null
  return $root
}

function Write-JsonFile {
  param(
    [string]$Path,
    [object]$Value
  )

  $dir = Split-Path -Parent $Path
  if (-not [string]::IsNullOrWhiteSpace($dir)) {
    New-Item -ItemType Directory -Force -Path $dir | Out-Null
  }

  $Value | ConvertTo-Json -Depth 10 | Set-Content -Path $Path -Encoding UTF8
}

function Write-TestImage {
  param([string]$Path)

  $dir = Split-Path -Parent $Path
  if (-not [string]::IsNullOrWhiteSpace($dir)) {
    New-Item -ItemType Directory -Force -Path $dir | Out-Null
  }

  $bytes = New-Object byte[] 2048
  $signature = [byte[]](0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a)
  [Array]::Copy($signature, 0, $bytes, 0, $signature.Length)
  [System.IO.File]::WriteAllBytes($Path, $bytes)
}

function Invoke-PlayStoreEvidenceCheck {
  param(
    [string]$EvidenceRoot,
    [switch]$WriteTemplate
  )

  $powerShellExe = (Get-Process -Id $PID).Path
  $arguments = @(
    "-NoProfile",
    "-ExecutionPolicy",
    "Bypass",
    "-File",
    $checkScript,
    "-EvidenceRoot",
    $EvidenceRoot,
    "-Json"
  )
  if ($WriteTemplate) {
    $arguments += "-WriteTemplate"
  }

  $oldErrorActionPreference = $ErrorActionPreference
  $ErrorActionPreference = "Continue"
  try {
    $output = & $powerShellExe @arguments 2>&1
    $exitCode = $LASTEXITCODE
  } finally {
    $ErrorActionPreference = $oldErrorActionPreference
  }

  $text = ($output | Out-String).Trim()
  $report = $null
  if (-not [string]::IsNullOrWhiteSpace($text)) {
    $report = $text | ConvertFrom-Json
  }

  return [pscustomobject]@{
    exitCode = $exitCode
    text = $text
    report = $report
  }
}

function Assert-CheckStatus {
  param(
    [object]$Report,
    [string]$Id,
    [string]$Status
  )

  $check = @($Report.checks | Where-Object { $_.id -eq $Id })
  if ($check.Count -ne 1) {
    throw "Expected exactly one check with id '$Id'."
  }
  if ($check[0].status -ne $Status) {
    throw "Expected check '$Id' to be '$Status', got '$($check[0].status)'. Detail: $($check[0].detail)"
  }
}

function New-CompletePlayEvidence {
  return [ordered]@{
    schema = "stackchan.android-play-store-evidence.v1"
    status = "internal-testing-ready"
    applicationId = "dev.stackchan.companion"
    versionName = "1.0.0"
    versionCode = 1
    sourceCommit = ("b" * 40)
    releaseAabSha256 = ("a" * 64)
    playSigningEnabled = $true
    privacyPolicyUrl = "https://stackchan.example/privacy"
    privacyPolicySourcePath = "docs/ANDROID_PLAY_PRIVACY_POLICY.md"
    track = "internal"
    uploadStatus = "uploaded"
    internalTestingInstallStatus = "installed"
    playConsoleReleaseName = "Stackchan Companion 1.0.0"
    testerGroup = "internal-testers"
    uploadedAtUtc = "2026-07-06T00:00:00Z"
    screenshots = @(
      [ordered]@{ id = "phone-pairing-setup"; required = $true; path = "screenshots/phone-pairing-setup.png"; device = "Pixel 8"; androidVersion = "16"; appVersion = "1.0.0"; sourceCommit = ("b" * 40); notes = "Guided setup with pairing short code, QR ticket, and saved robot controls." },
      [ordered]@{ id = "phone-live-dashboard"; required = $true; path = "screenshots/phone-live-dashboard.png"; device = "Pixel 8"; androidVersion = "16"; appVersion = "1.0.0"; sourceCommit = ("b" * 40); notes = "Connected dashboard with square Stack-chan face preview and honest telemetry labels." },
      [ordered]@{ id = "phone-brain-model"; required = $true; path = "screenshots/phone-brain-model.png"; device = "Pixel 8"; androidVersion = "16"; appVersion = "1.0.0"; sourceCommit = ("b" * 40); notes = "Gemma-4-E2B download, load, eject, checksum, and model settings controls." },
      [ordered]@{ id = "phone-personas-diagnostics"; required = $true; path = "screenshots/phone-personas-diagnostics.png"; device = "Pixel 8"; androidVersion = "16"; appVersion = "1.0.0"; sourceCommit = ("b" * 40); notes = "Persona import/export and diagnostics export without private values visible." }
    )
    dataSafetyReviewPath = "DATA_SAFETY_REVIEW.md"
    policyReviewPath = "POLICY_REVIEW.md"
    notes = "Contract-test complete Play internal testing packet."
  }
}

try {
  Set-Location $repoRoot

  $templateRoot = New-TempEvidenceRoot
  $templateResult = Invoke-PlayStoreEvidenceCheck -EvidenceRoot $templateRoot -WriteTemplate
  if ([int]$templateResult.exitCode -eq 0) {
    throw "Expected placeholder Play evidence template to fail readiness."
  }
  if ($templateResult.report.status -ne "pending-play-store-evidence") {
    throw "Expected placeholder template status pending-play-store-evidence, got $($templateResult.report.status)."
  }
  foreach ($id in @("evidence-status", "source-commit", "release-aab-sha", "play-signing", "privacy-policy-url", "upload-status", "internal-install", "play-console-release", "tester-group", "uploaded-at-utc", "screenshots")) {
    Assert-CheckStatus -Report $templateResult.report -Id $id -Status "fail"
  }
  Write-Host "[ok] placeholder Play Store template is rejected"

  $completeRoot = New-TempEvidenceRoot
  New-Item -ItemType Directory -Force -Path (Join-Path $completeRoot "screenshots") | Out-Null
  foreach ($name in @("phone-pairing-setup", "phone-live-dashboard", "phone-brain-model", "phone-personas-diagnostics")) {
    Write-TestImage -Path (Join-Path $completeRoot "screenshots/$name.png")
  }
  Write-JsonFile -Path (Join-Path $completeRoot "PLAY_STORE_EVIDENCE.json") -Value (New-CompletePlayEvidence)
  @"
# Data Safety Review

Reviewer: Contract Test
Review date: 2026-07-06
Source commit: $("b" * 40)
App version: 1.0.0
Decision: pass

The uploaded internal testing build uses local-only robot networking, does not store raw
microphone audio, redacts diagnostics exports, and keeps saved robot data on device.
"@ | Set-Content -Path (Join-Path $completeRoot "DATA_SAFETY_REVIEW.md") -Encoding UTF8
  @"
# Policy Review

Reviewer: Contract Test
Review date: 2026-07-06
Source commit: $("b" * 40)
App version: 1.0.0
Decision: pass

Foreground service, notification, local-network discovery, battery optimization, and
microphone permission claims match the final internal testing build behavior.
The app uses the connectedDevice foreground-service type for the local bridge,
records microphone denial without submitting a transcript, and keeps local-network
pairing evidence tied to the final internal testing build.
"@ | Set-Content -Path (Join-Path $completeRoot "POLICY_REVIEW.md") -Encoding UTF8

  $completeResult = Invoke-PlayStoreEvidenceCheck -EvidenceRoot $completeRoot
  if ([int]$completeResult.exitCode -ne 0) {
    throw "Expected complete Play Store evidence to pass. Output:`n$($completeResult.text)"
  }
  if ($completeResult.report.status -ne "play-internal-testing-ready") {
    throw "Expected complete packet status play-internal-testing-ready, got $($completeResult.report.status)."
  }
  if ($completeResult.report.applicationId -ne "dev.stackchan.companion" -or $completeResult.report.versionName -ne "1.0.0" -or [string]$completeResult.report.versionCode -ne "1" -or $completeResult.report.releaseAabSha256 -ne ("a" * 64)) {
    throw "Expected complete Play Store evidence check report to emit applicationId, versionName, versionCode, and releaseAabSha256."
  }
  foreach ($id in @("schema", "evidence-status", "app-version", "source-commit", "release-aab-sha", "play-signing", "privacy-policy-url", "upload-status", "internal-install", "play-console-release", "tester-group", "uploaded-at-utc", "screenshots", "data-safety", "policy-review")) {
    Assert-CheckStatus -Report $completeResult.report -Id $id -Status "pass"
  }
  Write-Host "[ok] complete Play Store internal testing packet is accepted"

  $pendingStatusRoot = New-TempEvidenceRoot
  New-Item -ItemType Directory -Force -Path (Join-Path $pendingStatusRoot "screenshots") | Out-Null
  foreach ($name in @("phone-pairing-setup", "phone-live-dashboard", "phone-brain-model", "phone-personas-diagnostics")) {
    Write-TestImage -Path (Join-Path $pendingStatusRoot "screenshots/$name.png")
  }
  $pendingStatusEvidence = New-CompletePlayEvidence
  $pendingStatusEvidence.status = "pending"
  Write-JsonFile -Path (Join-Path $pendingStatusRoot "PLAY_STORE_EVIDENCE.json") -Value $pendingStatusEvidence
  Copy-Item -Path (Join-Path $completeRoot "DATA_SAFETY_REVIEW.md") -Destination (Join-Path $pendingStatusRoot "DATA_SAFETY_REVIEW.md")
  Copy-Item -Path (Join-Path $completeRoot "POLICY_REVIEW.md") -Destination (Join-Path $pendingStatusRoot "POLICY_REVIEW.md")
  $pendingStatusResult = Invoke-PlayStoreEvidenceCheck -EvidenceRoot $pendingStatusRoot
  if ([int]$pendingStatusResult.exitCode -eq 0) {
    throw "Expected pending Play evidence packet status to fail."
  }
  Assert-CheckStatus -Report $pendingStatusResult.report -Id "evidence-status" -Status "fail"
  Write-Host "[ok] pending Play evidence packet status is rejected"

  $releaseIdentityMissingRoot = New-TempEvidenceRoot
  New-Item -ItemType Directory -Force -Path (Join-Path $releaseIdentityMissingRoot "screenshots") | Out-Null
  foreach ($name in @("phone-pairing-setup", "phone-live-dashboard", "phone-brain-model", "phone-personas-diagnostics")) {
    Write-TestImage -Path (Join-Path $releaseIdentityMissingRoot "screenshots/$name.png")
  }
  $releaseIdentityMissingEvidence = New-CompletePlayEvidence
  $releaseIdentityMissingEvidence.playConsoleReleaseName = "Stackchan Companion"
  $releaseIdentityMissingEvidence.testerGroup = ""
  $releaseIdentityMissingEvidence.uploadedAtUtc = "July 6 2026"
  Write-JsonFile -Path (Join-Path $releaseIdentityMissingRoot "PLAY_STORE_EVIDENCE.json") -Value $releaseIdentityMissingEvidence
  Copy-Item -Path (Join-Path $completeRoot "DATA_SAFETY_REVIEW.md") -Destination (Join-Path $releaseIdentityMissingRoot "DATA_SAFETY_REVIEW.md")
  Copy-Item -Path (Join-Path $completeRoot "POLICY_REVIEW.md") -Destination (Join-Path $releaseIdentityMissingRoot "POLICY_REVIEW.md")
  $releaseIdentityMissingResult = Invoke-PlayStoreEvidenceCheck -EvidenceRoot $releaseIdentityMissingRoot
  if ([int]$releaseIdentityMissingResult.exitCode -eq 0) {
    throw "Expected missing Play release identity fields to fail."
  }
  Assert-CheckStatus -Report $releaseIdentityMissingResult.report -Id "play-console-release" -Status "fail"
  Assert-CheckStatus -Report $releaseIdentityMissingResult.report -Id "tester-group" -Status "fail"
  Assert-CheckStatus -Report $releaseIdentityMissingResult.report -Id "uploaded-at-utc" -Status "fail"
  Write-Host "[ok] incomplete Play release identity fields are rejected"

  $screenshotCommitMismatchRoot = New-TempEvidenceRoot
  New-Item -ItemType Directory -Force -Path (Join-Path $screenshotCommitMismatchRoot "screenshots") | Out-Null
  foreach ($name in @("phone-pairing-setup", "phone-live-dashboard", "phone-brain-model", "phone-personas-diagnostics")) {
    Write-TestImage -Path (Join-Path $screenshotCommitMismatchRoot "screenshots/$name.png")
  }
  $screenshotCommitMismatchEvidence = New-CompletePlayEvidence
  $screenshotCommitMismatchEvidence.screenshots[0].sourceCommit = "c" * 40
  Write-JsonFile -Path (Join-Path $screenshotCommitMismatchRoot "PLAY_STORE_EVIDENCE.json") -Value $screenshotCommitMismatchEvidence
  Copy-Item -Path (Join-Path $completeRoot "DATA_SAFETY_REVIEW.md") -Destination (Join-Path $screenshotCommitMismatchRoot "DATA_SAFETY_REVIEW.md")
  Copy-Item -Path (Join-Path $completeRoot "POLICY_REVIEW.md") -Destination (Join-Path $screenshotCommitMismatchRoot "POLICY_REVIEW.md")
  $screenshotCommitMismatchResult = Invoke-PlayStoreEvidenceCheck -EvidenceRoot $screenshotCommitMismatchRoot
  if ([int]$screenshotCommitMismatchResult.exitCode -eq 0) {
    throw "Expected mismatched Play screenshot source commit to fail."
  }
  Assert-CheckStatus -Report $screenshotCommitMismatchResult.report -Id "screenshots" -Status "fail"
  Write-Host "[ok] mismatched Play screenshot source commit is rejected"

  $screenshotVersionMismatchRoot = New-TempEvidenceRoot
  New-Item -ItemType Directory -Force -Path (Join-Path $screenshotVersionMismatchRoot "screenshots") | Out-Null
  foreach ($name in @("phone-pairing-setup", "phone-live-dashboard", "phone-brain-model", "phone-personas-diagnostics")) {
    Write-TestImage -Path (Join-Path $screenshotVersionMismatchRoot "screenshots/$name.png")
  }
  $screenshotVersionMismatchEvidence = New-CompletePlayEvidence
  $screenshotVersionMismatchEvidence.screenshots[0].appVersion = "9.9.9"
  Write-JsonFile -Path (Join-Path $screenshotVersionMismatchRoot "PLAY_STORE_EVIDENCE.json") -Value $screenshotVersionMismatchEvidence
  Copy-Item -Path (Join-Path $completeRoot "DATA_SAFETY_REVIEW.md") -Destination (Join-Path $screenshotVersionMismatchRoot "DATA_SAFETY_REVIEW.md")
  Copy-Item -Path (Join-Path $completeRoot "POLICY_REVIEW.md") -Destination (Join-Path $screenshotVersionMismatchRoot "POLICY_REVIEW.md")
  $screenshotVersionMismatchResult = Invoke-PlayStoreEvidenceCheck -EvidenceRoot $screenshotVersionMismatchRoot
  if ([int]$screenshotVersionMismatchResult.exitCode -eq 0) {
    throw "Expected mismatched Play screenshot app version to fail."
  }
  Assert-CheckStatus -Report $screenshotVersionMismatchResult.report -Id "screenshots" -Status "fail"
  Write-Host "[ok] mismatched Play screenshot app version is rejected"

  $reviewCommitMismatchRoot = New-TempEvidenceRoot
  New-Item -ItemType Directory -Force -Path (Join-Path $reviewCommitMismatchRoot "screenshots") | Out-Null
  foreach ($name in @("phone-pairing-setup", "phone-live-dashboard", "phone-brain-model", "phone-personas-diagnostics")) {
    Write-TestImage -Path (Join-Path $reviewCommitMismatchRoot "screenshots/$name.png")
  }
  Write-JsonFile -Path (Join-Path $reviewCommitMismatchRoot "PLAY_STORE_EVIDENCE.json") -Value (New-CompletePlayEvidence)
  @"
# Data Safety Review

Reviewer: Contract Test
Review date: 2026-07-06
Source commit: $("c" * 40)
App version: 1.0.0
Decision: pass

This deliberately mismatches the source commit to prove the review cannot be reused
from a different uploaded build.
"@ | Set-Content -Path (Join-Path $reviewCommitMismatchRoot "DATA_SAFETY_REVIEW.md") -Encoding UTF8
  Copy-Item -Path (Join-Path $completeRoot "POLICY_REVIEW.md") -Destination (Join-Path $reviewCommitMismatchRoot "POLICY_REVIEW.md")
  $reviewCommitMismatchResult = Invoke-PlayStoreEvidenceCheck -EvidenceRoot $reviewCommitMismatchRoot
  if ([int]$reviewCommitMismatchResult.exitCode -eq 0) {
    throw "Expected mismatched Play data-safety review source commit to fail."
  }
  Assert-CheckStatus -Report $reviewCommitMismatchResult.report -Id "data-safety" -Status "fail"
  Write-Host "[ok] mismatched Play data-safety review source commit is rejected"

  $reviewDecisionMissingRoot = New-TempEvidenceRoot
  New-Item -ItemType Directory -Force -Path (Join-Path $reviewDecisionMissingRoot "screenshots") | Out-Null
  foreach ($name in @("phone-pairing-setup", "phone-live-dashboard", "phone-brain-model", "phone-personas-diagnostics")) {
    Write-TestImage -Path (Join-Path $reviewDecisionMissingRoot "screenshots/$name.png")
  }
  Write-JsonFile -Path (Join-Path $reviewDecisionMissingRoot "PLAY_STORE_EVIDENCE.json") -Value (New-CompletePlayEvidence)
  Copy-Item -Path (Join-Path $completeRoot "DATA_SAFETY_REVIEW.md") -Destination (Join-Path $reviewDecisionMissingRoot "DATA_SAFETY_REVIEW.md")
  @"
# Policy Review

Reviewer: Contract Test
Review date: 2026-07-06
Source commit: $("b" * 40)
App version: 1.0.0
Decision: pending

This deliberately withholds policy approval for the uploaded build.
"@ | Set-Content -Path (Join-Path $reviewDecisionMissingRoot "POLICY_REVIEW.md") -Encoding UTF8
  $reviewDecisionMissingResult = Invoke-PlayStoreEvidenceCheck -EvidenceRoot $reviewDecisionMissingRoot
  if ([int]$reviewDecisionMissingResult.exitCode -eq 0) {
    throw "Expected non-pass Play policy review decision to fail."
  }
  Assert-CheckStatus -Report $reviewDecisionMissingResult.report -Id "policy-review" -Status "fail"
  Write-Host "[ok] non-pass Play policy review decision is rejected"

  Write-Host "Android Play Store evidence contract tests passed."
} finally {
  foreach ($root in $createdRoots) {
    if ([string]::IsNullOrWhiteSpace($root)) {
      continue
    }
    $resolvedRoot = Resolve-Path -LiteralPath $root -ErrorAction SilentlyContinue
    if ($null -ne $resolvedRoot -and $resolvedRoot.Path.StartsWith([System.IO.Path]::GetTempPath(), [System.StringComparison]::OrdinalIgnoreCase)) {
      Remove-Item -LiteralPath $resolvedRoot.Path -Recurse -Force
    }
  }
}

exit 0
