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
    [string]$Status
  )

  Write-JsonFile -Path $Path -Value ([ordered]@{
      schema = $Schema
      status = $Status
      passed = 1
      failed = 0
      pending = 0
      checks = @()
    })
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
      sourceCommit = ("b" * 40)
      targetPhone = "Pixel 8 / Android 16"
      releaseBuild = "app-android-release.apk / app-android-release.aab"
      hardwareEvidenceStatus = "verified"
      hardwareEvidenceRoot = "output/hardware-evidence/contract"
      androidDashboardEvidenceStatus = "verified"
      reports = $reports
      reviewPath = "ANDROID_V1_REVIEW.md"
      requiredScreenshotIds = @("phone-pairing-setup", "phone-live-dashboard", "phone-brain-model", "phone-personas-diagnostics")
    })
  Write-JsonFile -Path (Join-Path $readyRoot $reports.apkInstallReport) -Value ([ordered]@{
      schema = "stackchan.android-apk-install.v1"
      status = "installed"
      apkSha256 = ("a" * 64)
      sourceCommit = ("b" * 40)
      versionName = "1.0.0"
      versionCode = "1"
    })
  Write-StatusReport -Path (Join-Path $readyRoot $reports.companionReadinessReport) -Schema "stackchan.companion-v1-readiness.v1" -Status "source-ready-pending-hardware"
  Write-StatusReport -Path (Join-Path $readyRoot $reports.diagnosticsCheckReport) -Schema "stackchan.android-diagnostics-export-evidence.v1" -Status "android-diagnostics-export-ready"
  Write-StatusReport -Path (Join-Path $readyRoot $reports.speechCheckReport) -Schema "stackchan.android-speech-evidence.v1" -Status "android-speech-ready"
  Write-StatusReport -Path (Join-Path $readyRoot $reports.controlsCheckReport) -Schema "stackchan.android-controls-evidence.v1" -Status "android-controls-ready"
  Write-StatusReport -Path (Join-Path $readyRoot $reports.pairingCheckReport) -Schema "stackchan.android-pairing-evidence.v1" -Status "android-pairing-ready"
  Write-StatusReport -Path (Join-Path $readyRoot $reports.wifiCheckReport) -Schema "stackchan.android-wifi-evidence.v1" -Status "android-wifi-ready"
  Write-StatusReport -Path (Join-Path $readyRoot $reports.gemmaCheckReport) -Schema "stackchan.android-gemma-evidence.v1" -Status "android-gemma-real-device-ready"
  Write-StatusReport -Path (Join-Path $readyRoot $reports.screenOffSoakCheckReport) -Schema "stackchan.android-screen-off-soak-evidence.v1" -Status "android-screen-off-soak-ready"
  Write-StatusReport -Path (Join-Path $readyRoot $reports.playStoreCheckReport) -Schema "stackchan.android-play-store-evidence-check.v1" -Status "play-internal-testing-ready"
  @"
# Android V1 Review

- Reviewer: Contract Test
- Review date: 2026-07-06
- Overall Android v1 decision: pass
- Target phone install decision: pass
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
  foreach ($id in @("apk-install", "companion-readiness", "diagnostics-ready", "speech-ready", "controls-ready", "pairing-ready", "wifi-ready", "gemma-ready", "screen-off-soak-ready", "play-store-ready", "android-v1-review")) {
    Assert-CheckStatus -Report $readyResult.report -Id $id -Status "pass"
  }
  Write-Host "[ok] complete Android v1 evidence bundle is accepted"

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
