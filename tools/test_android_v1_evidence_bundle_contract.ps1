param()

$ErrorActionPreference = "Stop"

$repoRoot = Resolve-Path (Join-Path $PSScriptRoot "..")
$checkScript = Join-Path $PSScriptRoot "check_android_v1_evidence_bundle.ps1"
$createdRoots = New-Object System.Collections.Generic.List[string]

function New-TempEvidenceRoot {
  $root = Join-Path ([System.IO.Path]::GetTempPath()) ("stackchan-android-v1-bundle-contract-" + [guid]::NewGuid().ToString("N"))
  $createdRoots.Add($root) | Out-Null
  New-Item -ItemType Directory -Force -Path (Join-Path $root "reports") | Out-Null
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

function Invoke-AndroidV1BundleCheck {
  param(
    [string]$EvidenceRoot,
    [switch]$WriteTemplate,
    [switch]$RequireReady
  )

  $powerShellExe = (Get-Process -Id $PID).Path
  $arguments = @("-NoProfile", "-ExecutionPolicy", "Bypass", "-File", $checkScript, "-EvidenceRoot", $EvidenceRoot, "-Json")
  if ($WriteTemplate) {
    $arguments += "-WriteTemplate"
  }
  if ($RequireReady) {
    $arguments += "-RequireReady"
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
  $report = if ([string]::IsNullOrWhiteSpace($text)) { $null } else { $text | ConvertFrom-Json }
  return [pscustomobject]@{ exitCode = $exitCode; text = $text; report = $report }
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

function Write-StatusReport {
  param(
    [string]$Path,
    [string]$Schema,
    [string]$Status,
    [string]$SourceCommit = "",
    [string]$ApplicationId = "",
    [string]$VersionName = "",
    [string]$VersionCode = "",
    [string]$ReleaseAabSha256 = "",
    [string]$BenchmarkProfile = "",
    [string]$BenchmarkRecommendedProfile = "",
    [object]$BenchmarkMedianMs = $null,
    [object]$BenchmarkMedianTokensPerSec = $null
  )

  $report = [ordered]@{
    schema = $Schema
    status = $Status
    passed = 1
    failed = 0
    pending = 0
    checks = @()
  }
  if (-not [string]::IsNullOrWhiteSpace($SourceCommit)) {
    $report.sourceCommit = $SourceCommit
  }
  if (-not [string]::IsNullOrWhiteSpace($ApplicationId)) {
    $report.applicationId = $ApplicationId
  }
  if (-not [string]::IsNullOrWhiteSpace($VersionName)) {
    $report.versionName = $VersionName
  }
  if (-not [string]::IsNullOrWhiteSpace($VersionCode)) {
    $report.versionCode = $VersionCode
  }
  if (-not [string]::IsNullOrWhiteSpace($ReleaseAabSha256)) {
    $report.releaseAabSha256 = $ReleaseAabSha256
  }
  if (-not [string]::IsNullOrWhiteSpace($BenchmarkProfile)) {
    $report.benchmarkProfile = $BenchmarkProfile
  }
  if (-not [string]::IsNullOrWhiteSpace($BenchmarkRecommendedProfile)) {
    $report.benchmarkRecommendedProfile = $BenchmarkRecommendedProfile
  }
  if ($null -ne $BenchmarkMedianMs) {
    $report.benchmarkMedianMs = $BenchmarkMedianMs
  }
  if ($null -ne $BenchmarkMedianTokensPerSec) {
    $report.benchmarkMedianTokensPerSec = $BenchmarkMedianTokensPerSec
  }
  Write-JsonFile -Path $Path -Value $report
}

try {
  Set-Location $repoRoot

  $templateRoot = New-TempEvidenceRoot
  $templateResult = Invoke-AndroidV1BundleCheck -EvidenceRoot $templateRoot -WriteTemplate
  if ($templateResult.report.status -ne "pending-android-v1-evidence-bundle") {
    throw "Expected placeholder bundle to be pending, got $($templateResult.report.status)."
  }
  foreach ($id in @("source-commit", "hardware-evidence", "dashboard-evidence", "apk-install", "diagnostics-ready", "android-v1-review")) {
    Assert-CheckStatus -Report $templateResult.report -Id $id -Status "pending"
  }
  Write-Host "[ok] placeholder Android v1 evidence bundle is pending"

  $readyRoot = New-TempEvidenceRoot
  $sourceCommit = "b" * 40
  $releaseAabSha = "c" * 64
  $requiredScreenshotIds = @("phone-pairing-setup", "phone-live-dashboard", "phone-brain-model", "phone-personas-diagnostics")
  New-Item -ItemType Directory -Force -Path (Join-Path $readyRoot "screenshots") | Out-Null
  foreach ($name in $requiredScreenshotIds) {
    Write-TestImage -Path (Join-Path $readyRoot "screenshots/$name.png")
  }
  $reports = [ordered]@{
    apkInstallReport = "reports/android_apk_install.json"
    companionReadinessReport = "reports/companion_v1_readiness.json"
    diagnosticsCheckReport = "reports/android_diagnostics_check.json"
    speechCheckReport = "reports/android_speech_check.json"
    controlsCheckReport = "reports/android_controls_check.json"
    pairingCheckReport = "reports/android_pairing_check.json"
    wifiCheckReport = "reports/android_wifi_check.json"
    gemmaCheckReport = "reports/android_gemma_check.json"
    screenOffSoakCheckReport = "reports/android_screen_off_soak_check.json"
    playStoreCheckReport = "reports/android_play_store_check.json"
  }
  Write-JsonFile -Path (Join-Path $readyRoot "ANDROID_V1_EVIDENCE_BUNDLE.json") -Value ([ordered]@{
      schema = "stackchan.android-v1-evidence-bundle.v1"
      status = "ready"
      sourceCommit = $sourceCommit
      targetPhone = "Pixel 8 / Android 16"
      releaseBuild = "app-android-release.apk / app-android-release.aab"
      hardwareEvidenceStatus = "verified"
      hardwareEvidenceRoot = "output/hardware-evidence/contract"
      androidDashboardEvidenceStatus = "verified"
      androidDashboardEvidenceRoot = "screenshots"
      androidDashboardMedia = @(
        [ordered]@{ id = "phone-pairing-setup"; path = "screenshots/phone-pairing-setup.png"; sourceCommit = $sourceCommit; notes = "Guided setup with pairing short code, QR ticket, and saved robot controls." },
        [ordered]@{ id = "phone-live-dashboard"; path = "screenshots/phone-live-dashboard.png"; sourceCommit = $sourceCommit; notes = "Connected dashboard with square Stack-chan face preview and honest telemetry labels." },
        [ordered]@{ id = "phone-brain-model"; path = "screenshots/phone-brain-model.png"; sourceCommit = $sourceCommit; notes = "Gemma-4-E2B download, load, eject, checksum, and model settings controls." },
        [ordered]@{ id = "phone-personas-diagnostics"; path = "screenshots/phone-personas-diagnostics.png"; sourceCommit = $sourceCommit; notes = "Persona import/export and diagnostics export without private values visible." }
      )
      reports = $reports
      reviewPath = "ANDROID_V1_REVIEW.md"
      requiredScreenshotIds = $requiredScreenshotIds
    })
  Write-JsonFile -Path (Join-Path $readyRoot $reports.apkInstallReport) -Value ([ordered]@{
      schema = "stackchan.android-apk-install.v1"
      status = "installed"
      packageName = "dev.stackchan.companion"
      apkSha256 = ("a" * 64)
      sourceCommit = $sourceCommit
      versionName = "1.0.0"
      versionCode = "1"
    })
  Write-StatusReport -Path (Join-Path $readyRoot $reports.companionReadinessReport) -Schema "stackchan.companion-v1-readiness.v1" -Status "source-ready-pending-hardware" -SourceCommit $sourceCommit
  Write-StatusReport -Path (Join-Path $readyRoot $reports.diagnosticsCheckReport) -Schema "stackchan.android-diagnostics-export-evidence.v1" -Status "android-diagnostics-export-ready" -SourceCommit $sourceCommit
  Write-StatusReport -Path (Join-Path $readyRoot $reports.speechCheckReport) -Schema "stackchan.android-speech-evidence.v1" -Status "android-speech-ready" -SourceCommit $sourceCommit
  Write-StatusReport -Path (Join-Path $readyRoot $reports.controlsCheckReport) -Schema "stackchan.android-controls-evidence.v1" -Status "android-controls-ready" -SourceCommit $sourceCommit
  Write-StatusReport -Path (Join-Path $readyRoot $reports.pairingCheckReport) -Schema "stackchan.android-pairing-evidence.v1" -Status "android-pairing-ready" -SourceCommit $sourceCommit
  Write-StatusReport -Path (Join-Path $readyRoot $reports.wifiCheckReport) -Schema "stackchan.android-wifi-evidence.v1" -Status "android-wifi-ready" -SourceCommit $sourceCommit
  Write-StatusReport -Path (Join-Path $readyRoot $reports.gemmaCheckReport) -Schema "stackchan.android-gemma-evidence.v1" -Status "android-gemma-real-device-ready" -SourceCommit $sourceCommit -BenchmarkProfile "gemma4-e2b-litert-lm" -BenchmarkRecommendedProfile "gemma4-e2b-litert-lm" -BenchmarkMedianMs 1200.0 -BenchmarkMedianTokensPerSec 8.5
  Write-StatusReport -Path (Join-Path $readyRoot $reports.screenOffSoakCheckReport) -Schema "stackchan.android-screen-off-soak-evidence.v1" -Status "android-screen-off-soak-ready" -SourceCommit $sourceCommit
  Write-StatusReport -Path (Join-Path $readyRoot $reports.playStoreCheckReport) -Schema "stackchan.android-play-store-evidence-check.v1" -Status "play-internal-testing-ready" -SourceCommit $sourceCommit -ApplicationId "dev.stackchan.companion" -VersionName "1.0.0" -VersionCode "1" -ReleaseAabSha256 $releaseAabSha
  @"
# Android V1 Review

- Reviewer: Contract Test
- Review date: 2026-07-06
- Source commit: $sourceCommit
- Overall Android v1 decision: pass
- Target phone install decision: pass
- Connected dashboard media decision: pass
- Physical robot pairing decision: pass
- Push-to-talk/STT decision: pass
- Settings and handoff decision: pass
- Wi-Fi provisioning decision: pass
- Mobile Gemma decision: pass
- Screen-off bridge soak decision: pass
- Play internal testing decision: pass
"@ | Set-Content -Path (Join-Path $readyRoot "ANDROID_V1_REVIEW.md") -Encoding UTF8

  $readyResult = Invoke-AndroidV1BundleCheck -EvidenceRoot $readyRoot -RequireReady
  if ([int]$readyResult.exitCode -ne 0) {
    throw "Expected complete Android v1 evidence bundle to pass. Output:`n$($readyResult.text)"
  }
  if ($readyResult.report.status -ne "android-v1-evidence-ready") {
    throw "Expected android-v1-evidence-ready, got $($readyResult.report.status)."
  }
  if ($readyResult.report.sourceCommit -ne $sourceCommit) {
    throw "Expected Android v1 bundle check report sourceCommit to match fixture commit."
  }
  if ($readyResult.report.applicationId -ne "dev.stackchan.companion" -or $readyResult.report.apkSha256 -ne ("a" * 64) -or $readyResult.report.versionName -ne "1.0.0" -or [string]$readyResult.report.versionCode -ne "1" -or $readyResult.report.releaseAabSha256 -ne $releaseAabSha) {
    throw "Expected Android v1 bundle check report to emit applicationId, APK hash, version identity, and release AAB hash."
  }
  if ($readyResult.report.gemmaBenchmarkProfile -ne "gemma4-e2b-litert-lm" -or [double]$readyResult.report.gemmaBenchmarkMedianMs -ne 1200.0 -or [double]$readyResult.report.gemmaBenchmarkMedianTokensPerSec -ne 8.5) {
    throw "Expected Android v1 bundle check report to emit Gemma benchmark profile and speed evidence."
  }
  if (@($readyResult.report.androidDashboardMediaIds).Count -ne 4 -or "phone-live-dashboard" -notin @($readyResult.report.androidDashboardMediaIds)) {
    throw "Expected Android v1 bundle check report to emit dashboard media IDs."
  }
  foreach ($id in @("hardware-evidence", "dashboard-evidence", "apk-install", "companion-readiness", "diagnostics-ready", "speech-ready", "controls-ready", "pairing-ready", "wifi-ready", "gemma-ready", "gemma-benchmark-profile", "gemma-benchmark-speed", "screen-off-soak-ready", "play-store-ready", "companion-readiness-source-commit-match", "apk-install-source-commit-match", "diagnostics-source-commit-match", "speech-source-commit-match", "controls-source-commit-match", "pairing-source-commit-match", "wifi-source-commit-match", "gemma-source-commit-match", "screen-off-soak-source-commit-match", "play-store-source-commit-match", "apk-install-application-id-match", "play-store-application-id-match", "play-store-version-name-match", "play-store-version-code-match", "android-v1-review")) {
    Assert-CheckStatus -Report $readyResult.report -Id $id -Status "pass"
  }
  Write-Host "[ok] complete Android v1 evidence bundle is accepted"

  $dashboardMissingMediaRoot = New-TempEvidenceRoot
  Copy-Item -Path (Join-Path $readyRoot "*") -Destination $dashboardMissingMediaRoot -Recurse -Force
  $dashboardMissingMediaBundlePath = Join-Path $dashboardMissingMediaRoot "ANDROID_V1_EVIDENCE_BUNDLE.json"
  $dashboardMissingMediaBundle = Get-Content -LiteralPath $dashboardMissingMediaBundlePath -Raw | ConvertFrom-Json
  $dashboardMissingMediaBundle.PSObject.Properties.Remove("androidDashboardMedia")
  Write-JsonFile -Path $dashboardMissingMediaBundlePath -Value $dashboardMissingMediaBundle
  $dashboardMissingMediaResult = Invoke-AndroidV1BundleCheck -EvidenceRoot $dashboardMissingMediaRoot
  if ([int]$dashboardMissingMediaResult.exitCode -eq 0) {
    throw "Expected Android v1 dashboard evidence without media entries to fail."
  }
  Assert-CheckStatus -Report $dashboardMissingMediaResult.report -Id "dashboard-evidence" -Status "fail"
  Write-Host "[ok] Android v1 dashboard verified status without media is rejected"

  $dashboardCommitMismatchRoot = New-TempEvidenceRoot
  Copy-Item -Path (Join-Path $readyRoot "*") -Destination $dashboardCommitMismatchRoot -Recurse -Force
  $dashboardCommitMismatchBundlePath = Join-Path $dashboardCommitMismatchRoot "ANDROID_V1_EVIDENCE_BUNDLE.json"
  $dashboardCommitMismatchBundle = Get-Content -LiteralPath $dashboardCommitMismatchBundlePath -Raw | ConvertFrom-Json
  $dashboardCommitMismatchBundle.androidDashboardMedia[0].sourceCommit = "e" * 40
  Write-JsonFile -Path $dashboardCommitMismatchBundlePath -Value $dashboardCommitMismatchBundle
  $dashboardCommitMismatchResult = Invoke-AndroidV1BundleCheck -EvidenceRoot $dashboardCommitMismatchRoot
  if ([int]$dashboardCommitMismatchResult.exitCode -eq 0) {
    throw "Expected Android v1 dashboard media source commit mismatch to fail."
  }
  Assert-CheckStatus -Report $dashboardCommitMismatchResult.report -Id "dashboard-evidence" -Status "fail"
  Write-Host "[ok] Android v1 dashboard media source commit mismatch is rejected"

  $readinessMismatchRoot = New-TempEvidenceRoot
  Copy-Item -Path (Join-Path $readyRoot "*") -Destination $readinessMismatchRoot -Recurse -Force
  Write-StatusReport -Path (Join-Path $readinessMismatchRoot $reports.companionReadinessReport) -Schema "stackchan.companion-v1-readiness.v1" -Status "source-ready-pending-hardware" -SourceCommit ("e" * 40)
  $readinessMismatchResult = Invoke-AndroidV1BundleCheck -EvidenceRoot $readinessMismatchRoot
  if ([int]$readinessMismatchResult.exitCode -eq 0) {
    throw "Expected mismatched Android v1 companion readiness source commit to fail."
  }
  Assert-CheckStatus -Report $readinessMismatchResult.report -Id "companion-readiness-source-commit-match" -Status "fail"
  Write-Host "[ok] mismatched Android v1 companion readiness source commit is rejected"

  $speechMismatchRoot = New-TempEvidenceRoot
  Copy-Item -Path (Join-Path $readyRoot "*") -Destination $speechMismatchRoot -Recurse -Force
  Write-StatusReport -Path (Join-Path $speechMismatchRoot $reports.speechCheckReport) -Schema "stackchan.android-speech-evidence.v1" -Status "android-speech-ready" -SourceCommit ("e" * 40)
  $speechMismatchResult = Invoke-AndroidV1BundleCheck -EvidenceRoot $speechMismatchRoot
  if ([int]$speechMismatchResult.exitCode -eq 0) {
    throw "Expected mismatched speech source commit to fail."
  }
  Assert-CheckStatus -Report $speechMismatchResult.report -Id "speech-source-commit-match" -Status "fail"
  Write-Host "[ok] mismatched Android v1 speech source commit is rejected"

  $gemmaMissingBenchmarkRoot = New-TempEvidenceRoot
  Copy-Item -Path (Join-Path $readyRoot "*") -Destination $gemmaMissingBenchmarkRoot -Recurse -Force
  Write-StatusReport -Path (Join-Path $gemmaMissingBenchmarkRoot $reports.gemmaCheckReport) -Schema "stackchan.android-gemma-evidence.v1" -Status "android-gemma-real-device-ready" -SourceCommit $sourceCommit
  $gemmaMissingBenchmarkResult = Invoke-AndroidV1BundleCheck -EvidenceRoot $gemmaMissingBenchmarkRoot
  if ([int]$gemmaMissingBenchmarkResult.exitCode -eq 0) {
    throw "Expected Android v1 Gemma report without benchmark fields to fail."
  }
  Assert-CheckStatus -Report $gemmaMissingBenchmarkResult.report -Id "gemma-benchmark-profile" -Status "fail"
  Assert-CheckStatus -Report $gemmaMissingBenchmarkResult.report -Id "gemma-benchmark-speed" -Status "fail"
  Write-Host "[ok] Android v1 Gemma report without benchmark fields is rejected"

  $gemmaSlowBenchmarkRoot = New-TempEvidenceRoot
  Copy-Item -Path (Join-Path $readyRoot "*") -Destination $gemmaSlowBenchmarkRoot -Recurse -Force
  Write-StatusReport -Path (Join-Path $gemmaSlowBenchmarkRoot $reports.gemmaCheckReport) -Schema "stackchan.android-gemma-evidence.v1" -Status "android-gemma-real-device-ready" -SourceCommit $sourceCommit -BenchmarkProfile "gemma4-e2b-litert-lm" -BenchmarkRecommendedProfile "gemma4-e2b-litert-lm" -BenchmarkMedianMs 2600.0 -BenchmarkMedianTokensPerSec 4.5
  $gemmaSlowBenchmarkResult = Invoke-AndroidV1BundleCheck -EvidenceRoot $gemmaSlowBenchmarkRoot
  if ([int]$gemmaSlowBenchmarkResult.exitCode -eq 0) {
    throw "Expected Android v1 Gemma report with slow benchmark fields to fail."
  }
  Assert-CheckStatus -Report $gemmaSlowBenchmarkResult.report -Id "gemma-benchmark-profile" -Status "pass"
  Assert-CheckStatus -Report $gemmaSlowBenchmarkResult.report -Id "gemma-benchmark-speed" -Status "fail"
  Write-Host "[ok] Android v1 Gemma report with slow benchmark fields is rejected"

  $mismatchRoot = New-TempEvidenceRoot
  Copy-Item -Path (Join-Path $readyRoot "*") -Destination $mismatchRoot -Recurse -Force
  Write-StatusReport -Path (Join-Path $mismatchRoot $reports.playStoreCheckReport) -Schema "stackchan.android-play-store-evidence-check.v1" -Status "play-internal-testing-ready" -SourceCommit ("d" * 40)
  $mismatchResult = Invoke-AndroidV1BundleCheck -EvidenceRoot $mismatchRoot
  if ([int]$mismatchResult.exitCode -eq 0) {
    throw "Expected mismatched Play Store source commit to fail."
  }
  Assert-CheckStatus -Report $mismatchResult.report -Id "play-store-source-commit-match" -Status "fail"
  Write-Host "[ok] mismatched Android v1 Play Store source commit is rejected"

  $apkPackageMismatchRoot = New-TempEvidenceRoot
  Copy-Item -Path (Join-Path $readyRoot "*") -Destination $apkPackageMismatchRoot -Recurse -Force
  $apkPackageMismatchPath = Join-Path $apkPackageMismatchRoot $reports.apkInstallReport
  $apkPackageMismatchReport = Get-Content -LiteralPath $apkPackageMismatchPath -Raw | ConvertFrom-Json
  $apkPackageMismatchReport.packageName = "dev.stackchan.wrong"
  Write-JsonFile -Path $apkPackageMismatchPath -Value $apkPackageMismatchReport
  $apkPackageMismatchResult = Invoke-AndroidV1BundleCheck -EvidenceRoot $apkPackageMismatchRoot
  if ([int]$apkPackageMismatchResult.exitCode -eq 0) {
    throw "Expected mismatched Android v1 APK install packageName to fail."
  }
  Assert-CheckStatus -Report $apkPackageMismatchResult.report -Id "apk-install-application-id-match" -Status "fail"
  Write-Host "[ok] mismatched Android v1 APK install packageName is rejected"

  $playApplicationIdMismatchRoot = New-TempEvidenceRoot
  Copy-Item -Path (Join-Path $readyRoot "*") -Destination $playApplicationIdMismatchRoot -Recurse -Force
  $playApplicationIdMismatchPath = Join-Path $playApplicationIdMismatchRoot $reports.playStoreCheckReport
  $playApplicationIdMismatchReport = Get-Content -LiteralPath $playApplicationIdMismatchPath -Raw | ConvertFrom-Json
  $playApplicationIdMismatchReport.applicationId = "dev.stackchan.wrong"
  Write-JsonFile -Path $playApplicationIdMismatchPath -Value $playApplicationIdMismatchReport
  $playApplicationIdMismatchResult = Invoke-AndroidV1BundleCheck -EvidenceRoot $playApplicationIdMismatchRoot
  if ([int]$playApplicationIdMismatchResult.exitCode -eq 0) {
    throw "Expected mismatched Android v1 Play Store applicationId to fail."
  }
  Assert-CheckStatus -Report $playApplicationIdMismatchResult.report -Id "play-store-application-id-match" -Status "fail"
  Write-Host "[ok] mismatched Android v1 Play Store applicationId is rejected"

  $playVersionMismatchRoot = New-TempEvidenceRoot
  Copy-Item -Path (Join-Path $readyRoot "*") -Destination $playVersionMismatchRoot -Recurse -Force
  Write-StatusReport -Path (Join-Path $playVersionMismatchRoot $reports.playStoreCheckReport) -Schema "stackchan.android-play-store-evidence-check.v1" -Status "play-internal-testing-ready" -SourceCommit $sourceCommit -VersionName "9.9.9" -VersionCode "99"
  $playVersionMismatchResult = Invoke-AndroidV1BundleCheck -EvidenceRoot $playVersionMismatchRoot
  if ([int]$playVersionMismatchResult.exitCode -eq 0) {
    throw "Expected mismatched Android v1 Play Store version identity to fail."
  }
  Assert-CheckStatus -Report $playVersionMismatchResult.report -Id "play-store-version-name-match" -Status "fail"
  Assert-CheckStatus -Report $playVersionMismatchResult.report -Id "play-store-version-code-match" -Status "fail"
  Write-Host "[ok] mismatched Android v1 Play Store version identity is rejected"

  $reviewMismatchRoot = New-TempEvidenceRoot
  Copy-Item -Path (Join-Path $readyRoot "*") -Destination $reviewMismatchRoot -Recurse -Force
  @"
# Android V1 Review

- Reviewer: Contract Test
- Review date: 2026-07-06
- Source commit: $("e" * 40)
- Overall Android v1 decision: pass
- Target phone install decision: pass
- Connected dashboard media decision: pass
- Physical robot pairing decision: pass
- Push-to-talk/STT decision: pass
- Settings and handoff decision: pass
- Wi-Fi provisioning decision: pass
- Mobile Gemma decision: pass
- Screen-off bridge soak decision: pass
- Play internal testing decision: pass
"@ | Set-Content -Path (Join-Path $reviewMismatchRoot "ANDROID_V1_REVIEW.md") -Encoding UTF8
  $reviewMismatchResult = Invoke-AndroidV1BundleCheck -EvidenceRoot $reviewMismatchRoot
  if ([int]$reviewMismatchResult.exitCode -eq 0) {
    throw "Expected mismatched Android v1 review source commit to fail."
  }
  Assert-CheckStatus -Report $reviewMismatchResult.report -Id "android-v1-review" -Status "fail"
  Write-Host "[ok] mismatched Android v1 review source commit is rejected"

  Write-Host "Android v1 evidence bundle contract tests passed."
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
