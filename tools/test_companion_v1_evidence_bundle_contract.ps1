param()

$ErrorActionPreference = "Stop"

$repoRoot = Resolve-Path (Join-Path $PSScriptRoot "..")
$checkScript = Join-Path $PSScriptRoot "check_companion_v1_evidence_bundle.ps1"
$createdRoots = New-Object System.Collections.Generic.List[string]

function New-TempEvidenceRoot {
  $root = Join-Path ([System.IO.Path]::GetTempPath()) ("stackchan-companion-v1-bundle-contract-" + [guid]::NewGuid().ToString("N"))
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

function Invoke-CompanionV1BundleCheck {
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
    [string]$Commit = "",
    [string]$SourceCommit = "",
    [string]$Version = "",
    [string]$EvidenceRoot = "",
    [string]$ReleaseApkSha256 = "",
    [string]$ReleaseAabSha256 = "",
    [string]$WindowsMsiSha256 = "",
    [string]$MacosDmgSha256 = "",
    [string]$LinuxDebSha256 = ""
  )

  $report = [ordered]@{
    schema = $Schema
    status = $Status
    passed = 1
    failed = 0
    pending = 0
    checks = @()
  }
  if (-not [string]::IsNullOrWhiteSpace($Commit)) {
    $report.commit = $Commit
  }
  if (-not [string]::IsNullOrWhiteSpace($SourceCommit)) {
    $report.sourceCommit = $SourceCommit
  }
  if (-not [string]::IsNullOrWhiteSpace($Version)) {
    $report.version = $Version
  }
  if (-not [string]::IsNullOrWhiteSpace($EvidenceRoot)) {
    $report.evidenceRoot = $EvidenceRoot
    $report.evidence = [ordered]@{
      metadata = [ordered]@{
        commit = $Commit
      }
    }
  }
  $artifactGroups = @()
  if (-not [string]::IsNullOrWhiteSpace($ReleaseApkSha256) -or -not [string]::IsNullOrWhiteSpace($ReleaseAabSha256)) {
    $androidEntries = @()
    if (-not [string]::IsNullOrWhiteSpace($ReleaseApkSha256)) {
      $androidEntries += [ordered]@{
        name = "app-android-release.apk"
        path = "companion/app-android/build/outputs/apk/release/app-android-release.apk"
        bytes = 123456
        sha256 = $ReleaseApkSha256
      }
    }
    if (-not [string]::IsNullOrWhiteSpace($ReleaseAabSha256)) {
      $androidEntries += [ordered]@{
        name = "app-android-release.aab"
        path = "companion/app-android/build/outputs/bundle/release/app-android-release.aab"
        bytes = 123456
        sha256 = $ReleaseAabSha256
      }
    }
    $artifactGroups += [ordered]@{
        kind = "android-apk"
        root = "companion/app-android/build/outputs"
        entries = @($androidEntries)
      }
  }
  if (-not [string]::IsNullOrWhiteSpace($WindowsMsiSha256) -or -not [string]::IsNullOrWhiteSpace($MacosDmgSha256) -or -not [string]::IsNullOrWhiteSpace($LinuxDebSha256)) {
    $artifactGroups += [ordered]@{
      kind = "desktop-package"
      root = "output/companion/desktop"
      entries = @(
        [ordered]@{ name = "stackchan-companion.msi"; path = "output/companion/desktop/stackchan-companion.msi"; bytes = 123456; sha256 = $WindowsMsiSha256 },
        [ordered]@{ name = "stackchan-companion.dmg"; path = "output/companion/desktop/stackchan-companion.dmg"; bytes = 123456; sha256 = $MacosDmgSha256 },
        [ordered]@{ name = "stackchan-companion.deb"; path = "output/companion/desktop/stackchan-companion.deb"; bytes = 123456; sha256 = $LinuxDebSha256 }
      )
    }
  }
  if ($artifactGroups.Count -gt 0) {
    $report.artifacts = @($artifactGroups)
  }
  if ($Schema -eq "stackchan.companion-release-evidence.v1") {
    $report.packageEvidence = [ordered]@{
      status = "present"
      root = "output/release/v1.0.0"
      files = @(
        [ordered]@{ path = "release_manifest.json"; bytes = 1234; sha256 = "1" * 64 },
        [ordered]@{ path = "release_assets.json"; bytes = 1234; sha256 = "2" * 64 },
        [ordered]@{ path = "COMPANION_RELEASE_EVIDENCE.json"; bytes = 1234; sha256 = "3" * 64 },
        [ordered]@{ path = "docs/COMPANION_CROSS_PLATFORM_PLAN.md"; bytes = 1234; sha256 = "4" * 64 }
      )
    }
  }
  Write-JsonFile -Path $Path -Value $report
}

try {
  Set-Location $repoRoot

  $templateRoot = New-TempEvidenceRoot
  $templateResult = Invoke-CompanionV1BundleCheck -EvidenceRoot $templateRoot -WriteTemplate
  if ($templateResult.report.status -ne "pending-companion-v1-evidence-bundle") {
    throw "Expected placeholder bundle to be pending, got $($templateResult.report.status)."
  }
  foreach ($id in @("source-commit", "release-package", "hardware-evidence", "android-v1-status", "desktop-v1-status", "companion-v1-review")) {
    Assert-CheckStatus -Report $templateResult.report -Id $id -Status "pending"
  }
  Write-Host "[ok] placeholder Companion v1 evidence bundle is pending"

  $readyRoot = New-TempEvidenceRoot
  $sourceCommit = "d" * 40
  $releaseVersion = "v1.0.0"
  $releaseApkSha = "9" * 64
  $releaseAabSha = "a" * 64
  $windowsMsiSha = "b" * 64
  $macosDmgSha = "c" * 64
  $linuxDebSha = "d" * 64
  $releaseZipPath = Join-Path $readyRoot "artifacts/stackchan_alive_v1.0.0.zip"
  New-Item -ItemType Directory -Force -Path (Split-Path -Parent $releaseZipPath) | Out-Null
  Set-Content -Path $releaseZipPath -Value "contract release zip" -Encoding UTF8
  $releaseZipSha = (Get-FileHash -Algorithm SHA256 -LiteralPath $releaseZipPath).Hash.ToLowerInvariant()
  $hardwareEvidenceRoot = Join-Path $readyRoot "hardware-evidence/contract"
  New-Item -ItemType Directory -Force -Path $hardwareEvidenceRoot | Out-Null
  $reports = [ordered]@{
    companionReadinessReport = "reports/companion_v1_readiness.json"
    companionReleaseEvidenceReport = "reports/COMPANION_RELEASE_EVIDENCE.json"
    githubActionsStatusReport = "reports/github_actions_status.json"
    rolloutStatusReport = "reports/ROLLOUT_STATUS.json"
    androidV1BundleReport = "reports/android_v1_bundle_check.json"
    desktopV1BundleReport = "reports/desktop_v1_bundle_check.json"
    voiceSourceReadinessReport = "reports/voice_source_readiness.json"
  }
  Write-JsonFile -Path (Join-Path $readyRoot "COMPANION_V1_EVIDENCE_BUNDLE.json") -Value ([ordered]@{
      schema = "stackchan.companion-v1-evidence-bundle.v1"
      status = "ready"
      sourceCommit = $sourceCommit
      releaseVersion = $releaseVersion
      releasePackage = [ordered]@{
        path = "artifacts/stackchan_alive_v1.0.0.zip"
        sha256 = $releaseZipSha
      }
      hardwareEvidenceStatus = "verified"
      hardwareEvidenceRoot = $hardwareEvidenceRoot
      androidV1Status = "ready"
      desktopV1Status = "ready"
      reports = $reports
      reviewPath = "COMPANION_V1_REVIEW.md"
    })
  Write-StatusReport -Path (Join-Path $readyRoot $reports.companionReadinessReport) -Schema "stackchan.companion-v1-readiness.v1" -Status "source-ready-pending-hardware" -SourceCommit $sourceCommit
  Write-StatusReport -Path (Join-Path $readyRoot $reports.companionReleaseEvidenceReport) -Schema "stackchan.companion-release-evidence.v1" -Status "complete" -Commit $sourceCommit -Version $releaseVersion -ReleaseApkSha256 $releaseApkSha -ReleaseAabSha256 $releaseAabSha -WindowsMsiSha256 $windowsMsiSha -MacosDmgSha256 $macosDmgSha -LinuxDebSha256 $linuxDebSha
  Write-StatusReport -Path (Join-Path $readyRoot $reports.githubActionsStatusReport) -Schema "stackchan.github-actions-status.v1" -Status "success" -Commit $sourceCommit -Version $releaseVersion
  Write-StatusReport -Path (Join-Path $readyRoot $reports.rolloutStatusReport) -Schema "stackchan.rollout-status.v1" -Status "consumer-promotion-ready" -Commit $sourceCommit -Version $releaseVersion -EvidenceRoot $hardwareEvidenceRoot
  Write-JsonFile -Path (Join-Path $readyRoot $reports.androidV1BundleReport) -Value ([ordered]@{
      schema = "stackchan.android-v1-evidence-bundle-check.v1"
      status = "android-v1-evidence-ready"
      sourceCommit = $sourceCommit
      applicationId = "dev.stackchan.companion"
      apkSha256 = $releaseApkSha
      versionName = "1.0.0"
      versionCode = "1"
      releaseAabSha256 = $releaseAabSha
      passed = 1
      failed = 0
      pending = 0
      checks = @()
    })
  Write-JsonFile -Path (Join-Path $readyRoot $reports.desktopV1BundleReport) -Value ([ordered]@{
      schema = "stackchan.desktop-v1-evidence-bundle-check.v1"
      status = "desktop-v1-evidence-ready"
      sourceCommit = $sourceCommit
      windowsMsiSha256 = $windowsMsiSha
      macosDmgSha256 = $macosDmgSha
      linuxDebSha256 = $linuxDebSha
      passed = 1
      failed = 0
      pending = 0
      checks = @()
    })
  Write-JsonFile -Path (Join-Path $readyRoot $reports.voiceSourceReadinessReport) -Value ([ordered]@{
      schema = "stackchan.voice-source-readiness.v1"
      status = "production-voice-source-ready"
      sourceCommit = $sourceCommit
      passed = 1
      failed = 0
      pending = 0
      checks = @()
    })
  @"
# Companion V1 Review

- Reviewer: Contract Test
- Review date: 2026-07-06
- Source commit: $sourceCommit
- Release version: $releaseVersion
- Overall companion v1 decision: pass
- Source/readiness decision: pass
- Release package decision: pass
- GitHub Actions decision: pass
- Android v1 decision: pass
- Desktop v1 decision: pass
- Physical robot evidence decision: pass
- Production voice-source decision: pass
- Play distribution decision: pass
"@ | Set-Content -Path (Join-Path $readyRoot "COMPANION_V1_REVIEW.md") -Encoding UTF8

  $readyResult = Invoke-CompanionV1BundleCheck -EvidenceRoot $readyRoot -RequireReady
  if ([int]$readyResult.exitCode -ne 0) {
    throw "Expected complete Companion v1 evidence bundle to pass. Output:`n$($readyResult.text)"
  }
  if ($readyResult.report.status -ne "companion-v1-evidence-ready") {
    throw "Expected companion-v1-evidence-ready, got $($readyResult.report.status)."
  }
  if ($readyResult.report.sourceCommit -ne $sourceCommit -or $readyResult.report.releaseVersion -ne $releaseVersion) {
    throw "Expected Companion v1 bundle check report to emit sourceCommit and releaseVersion."
  }
  foreach ($id in @("release-package", "hardware-evidence", "android-v1-status", "desktop-v1-status", "companion-readiness", "companion-release-evidence", "github-actions", "rollout-status", "android-v1-bundle", "desktop-v1-bundle", "voice-source-ready", "companion-readiness-commit-match", "release-evidence-commit-match", "github-actions-commit-match", "rollout-status-commit-match", "android-v1-commit-match", "desktop-v1-commit-match", "release-evidence-version-match", "github-actions-version-match", "rollout-status-version-match", "voice-source-commit-match", "android-v1-application-id-match", "android-v1-version-name-match", "android-v1-version-code-match", "android-v1-release-apk-hash-match", "android-v1-release-aab-hash-match", "desktop-v1-artifact-hashes-match", "release-package-evidence-present", "rollout-hardware-root-match", "rollout-hardware-commit-match", "companion-v1-review")) {
    Assert-CheckStatus -Report $readyResult.report -Id $id -Status "pass"
  }
  Write-Host "[ok] complete Companion v1 evidence bundle is accepted"

  $releaseHashMismatchRoot = New-TempEvidenceRoot
  Copy-Item -Path (Join-Path $readyRoot "*") -Destination $releaseHashMismatchRoot -Recurse -Force
  $releaseHashMismatchBundlePath = Join-Path $releaseHashMismatchRoot "COMPANION_V1_EVIDENCE_BUNDLE.json"
  $releaseHashMismatchBundle = Get-Content -LiteralPath $releaseHashMismatchBundlePath -Raw | ConvertFrom-Json
  $releaseHashMismatchBundle.releasePackage.sha256 = "e" * 64
  Write-JsonFile -Path $releaseHashMismatchBundlePath -Value $releaseHashMismatchBundle
  $releaseHashMismatchResult = Invoke-CompanionV1BundleCheck -EvidenceRoot $releaseHashMismatchRoot
  if ([int]$releaseHashMismatchResult.exitCode -eq 0) {
    throw "Expected mismatched Companion v1 release ZIP hash to fail."
  }
  Assert-CheckStatus -Report $releaseHashMismatchResult.report -Id "release-package" -Status "fail"
  Write-Host "[ok] mismatched Companion v1 release ZIP hash is rejected"

  $releasePackageEvidenceMissingRoot = New-TempEvidenceRoot
  Copy-Item -Path (Join-Path $readyRoot "*") -Destination $releasePackageEvidenceMissingRoot -Recurse -Force
  $releasePackageEvidenceMissingPath = Join-Path $releasePackageEvidenceMissingRoot $reports.companionReleaseEvidenceReport
  $releasePackageEvidenceMissingReport = Get-Content -LiteralPath $releasePackageEvidenceMissingPath -Raw | ConvertFrom-Json
  $releasePackageEvidenceMissingReport.packageEvidence.status = "not-provided"
  $releasePackageEvidenceMissingReport.packageEvidence.files = @()
  Write-JsonFile -Path $releasePackageEvidenceMissingPath -Value $releasePackageEvidenceMissingReport
  $releasePackageEvidenceMissingResult = Invoke-CompanionV1BundleCheck -EvidenceRoot $releasePackageEvidenceMissingRoot
  if ([int]$releasePackageEvidenceMissingResult.exitCode -eq 0) {
    throw "Expected missing Companion v1 release package evidence to fail."
  }
  Assert-CheckStatus -Report $releasePackageEvidenceMissingResult.report -Id "release-package-evidence-present" -Status "fail"
  Write-Host "[ok] missing Companion v1 release package evidence is rejected"

  $readinessMismatchRoot = New-TempEvidenceRoot
  Copy-Item -Path (Join-Path $readyRoot "*") -Destination $readinessMismatchRoot -Recurse -Force
  Write-StatusReport -Path (Join-Path $readinessMismatchRoot $reports.companionReadinessReport) -Schema "stackchan.companion-v1-readiness.v1" -Status "source-ready-pending-hardware" -SourceCommit ("e" * 40)
  $readinessMismatchResult = Invoke-CompanionV1BundleCheck -EvidenceRoot $readinessMismatchRoot
  if ([int]$readinessMismatchResult.exitCode -eq 0) {
    throw "Expected mismatched Companion v1 source-readiness commit to fail."
  }
  Assert-CheckStatus -Report $readinessMismatchResult.report -Id "companion-readiness-commit-match" -Status "fail"
  Write-Host "[ok] mismatched Companion v1 source-readiness commit is rejected"

  $hardwareRootMismatchRoot = New-TempEvidenceRoot
  Copy-Item -Path (Join-Path $readyRoot "*") -Destination $hardwareRootMismatchRoot -Recurse -Force
  Write-StatusReport -Path (Join-Path $hardwareRootMismatchRoot $reports.rolloutStatusReport) -Schema "stackchan.rollout-status.v1" -Status "consumer-promotion-ready" -Commit $sourceCommit -Version $releaseVersion -EvidenceRoot (Join-Path $hardwareRootMismatchRoot "hardware-evidence/other")
  $hardwareRootMismatchResult = Invoke-CompanionV1BundleCheck -EvidenceRoot $hardwareRootMismatchRoot
  if ([int]$hardwareRootMismatchResult.exitCode -eq 0) {
    throw "Expected mismatched Companion v1 hardware evidence root to fail."
  }
  Assert-CheckStatus -Report $hardwareRootMismatchResult.report -Id "rollout-hardware-root-match" -Status "fail"
  Write-Host "[ok] mismatched Companion v1 hardware evidence root is rejected"

  $hardwareCommitMismatchRoot = New-TempEvidenceRoot
  Copy-Item -Path (Join-Path $readyRoot "*") -Destination $hardwareCommitMismatchRoot -Recurse -Force
  Write-StatusReport -Path (Join-Path $hardwareCommitMismatchRoot $reports.rolloutStatusReport) -Schema "stackchan.rollout-status.v1" -Status "consumer-promotion-ready" -Commit ("e" * 40) -Version $releaseVersion -EvidenceRoot $hardwareEvidenceRoot
  $hardwareCommitMismatchResult = Invoke-CompanionV1BundleCheck -EvidenceRoot $hardwareCommitMismatchRoot
  if ([int]$hardwareCommitMismatchResult.exitCode -eq 0) {
    throw "Expected mismatched Companion v1 hardware evidence commit to fail."
  }
  Assert-CheckStatus -Report $hardwareCommitMismatchResult.report -Id "rollout-hardware-commit-match" -Status "fail"
  Write-Host "[ok] mismatched Companion v1 hardware evidence commit is rejected"

  $mismatchRoot = New-TempEvidenceRoot
  Copy-Item -Path (Join-Path $readyRoot "*") -Destination $mismatchRoot -Recurse -Force
  Write-StatusReport -Path (Join-Path $mismatchRoot $reports.githubActionsStatusReport) -Schema "stackchan.github-actions-status.v1" -Status "success" -Commit ("e" * 40) -Version $releaseVersion
  $mismatchResult = Invoke-CompanionV1BundleCheck -EvidenceRoot $mismatchRoot
  if ([int]$mismatchResult.exitCode -eq 0) {
    throw "Expected mismatched GitHub Actions commit to fail."
  }
  Assert-CheckStatus -Report $mismatchResult.report -Id "github-actions-commit-match" -Status "fail"
  Write-Host "[ok] mismatched Companion v1 report commit is rejected"

  $androidMismatchRoot = New-TempEvidenceRoot
  Copy-Item -Path (Join-Path $readyRoot "*") -Destination $androidMismatchRoot -Recurse -Force
  Write-JsonFile -Path (Join-Path $androidMismatchRoot $reports.androidV1BundleReport) -Value ([ordered]@{
      schema = "stackchan.android-v1-evidence-bundle-check.v1"
      status = "android-v1-evidence-ready"
      sourceCommit = ("e" * 40)
      passed = 1
      failed = 0
      pending = 0
      checks = @()
    })
  $androidMismatchResult = Invoke-CompanionV1BundleCheck -EvidenceRoot $androidMismatchRoot
  if ([int]$androidMismatchResult.exitCode -eq 0) {
    throw "Expected mismatched Companion v1 Android bundle commit to fail."
  }
  Assert-CheckStatus -Report $androidMismatchResult.report -Id "android-v1-commit-match" -Status "fail"
  Write-Host "[ok] mismatched Companion v1 Android bundle commit is rejected"

  $androidApplicationIdMismatchRoot = New-TempEvidenceRoot
  Copy-Item -Path (Join-Path $readyRoot "*") -Destination $androidApplicationIdMismatchRoot -Recurse -Force
  $androidApplicationIdMismatchReportPath = Join-Path $androidApplicationIdMismatchRoot $reports.androidV1BundleReport
  $androidApplicationIdMismatchReport = Get-Content -LiteralPath $androidApplicationIdMismatchReportPath -Raw | ConvertFrom-Json
  $androidApplicationIdMismatchReport.applicationId = "dev.stackchan.wrong"
  Write-JsonFile -Path $androidApplicationIdMismatchReportPath -Value $androidApplicationIdMismatchReport
  $androidApplicationIdMismatchResult = Invoke-CompanionV1BundleCheck -EvidenceRoot $androidApplicationIdMismatchRoot
  if ([int]$androidApplicationIdMismatchResult.exitCode -eq 0) {
    throw "Expected mismatched Companion v1 Android applicationId to fail."
  }
  Assert-CheckStatus -Report $androidApplicationIdMismatchResult.report -Id "android-v1-application-id-match" -Status "fail"
  Write-Host "[ok] mismatched Companion v1 Android applicationId is rejected"

  $androidVersionMismatchRoot = New-TempEvidenceRoot
  Copy-Item -Path (Join-Path $readyRoot "*") -Destination $androidVersionMismatchRoot -Recurse -Force
  $androidVersionMismatchReportPath = Join-Path $androidVersionMismatchRoot $reports.androidV1BundleReport
  $androidVersionMismatchReport = Get-Content -LiteralPath $androidVersionMismatchReportPath -Raw | ConvertFrom-Json
  $androidVersionMismatchReport.versionName = "9.9.9"
  Write-JsonFile -Path $androidVersionMismatchReportPath -Value $androidVersionMismatchReport
  $androidVersionMismatchResult = Invoke-CompanionV1BundleCheck -EvidenceRoot $androidVersionMismatchRoot
  if ([int]$androidVersionMismatchResult.exitCode -eq 0) {
    throw "Expected mismatched Companion v1 Android versionName to fail."
  }
  Assert-CheckStatus -Report $androidVersionMismatchResult.report -Id "android-v1-version-name-match" -Status "fail"
  Write-Host "[ok] mismatched Companion v1 Android app version is rejected"

  $androidVersionCodeMismatchRoot = New-TempEvidenceRoot
  Copy-Item -Path (Join-Path $readyRoot "*") -Destination $androidVersionCodeMismatchRoot -Recurse -Force
  $androidVersionCodeMismatchReportPath = Join-Path $androidVersionCodeMismatchRoot $reports.androidV1BundleReport
  $androidVersionCodeMismatchReport = Get-Content -LiteralPath $androidVersionCodeMismatchReportPath -Raw | ConvertFrom-Json
  $androidVersionCodeMismatchReport.versionCode = "999"
  Write-JsonFile -Path $androidVersionCodeMismatchReportPath -Value $androidVersionCodeMismatchReport
  $androidVersionCodeMismatchResult = Invoke-CompanionV1BundleCheck -EvidenceRoot $androidVersionCodeMismatchRoot
  if ([int]$androidVersionCodeMismatchResult.exitCode -eq 0) {
    throw "Expected mismatched Companion v1 Android versionCode to fail."
  }
  Assert-CheckStatus -Report $androidVersionCodeMismatchResult.report -Id "android-v1-version-code-match" -Status "fail"
  Write-Host "[ok] mismatched Companion v1 Android app versionCode is rejected"

  $androidApkHashMismatchRoot = New-TempEvidenceRoot
  Copy-Item -Path (Join-Path $readyRoot "*") -Destination $androidApkHashMismatchRoot -Recurse -Force
  $androidApkHashMismatchReportPath = Join-Path $androidApkHashMismatchRoot $reports.androidV1BundleReport
  $androidApkHashMismatchReport = Get-Content -LiteralPath $androidApkHashMismatchReportPath -Raw | ConvertFrom-Json
  $androidApkHashMismatchReport.apkSha256 = "e" * 64
  Write-JsonFile -Path $androidApkHashMismatchReportPath -Value $androidApkHashMismatchReport
  $androidApkHashMismatchResult = Invoke-CompanionV1BundleCheck -EvidenceRoot $androidApkHashMismatchRoot
  if ([int]$androidApkHashMismatchResult.exitCode -eq 0) {
    throw "Expected mismatched Companion v1 Android release APK hash to fail."
  }
  Assert-CheckStatus -Report $androidApkHashMismatchResult.report -Id "android-v1-release-apk-hash-match" -Status "fail"
  Write-Host "[ok] mismatched Companion v1 Android release APK hash is rejected"

  $androidAabHashMismatchRoot = New-TempEvidenceRoot
  Copy-Item -Path (Join-Path $readyRoot "*") -Destination $androidAabHashMismatchRoot -Recurse -Force
  $androidAabHashMismatchReportPath = Join-Path $androidAabHashMismatchRoot $reports.androidV1BundleReport
  $androidAabHashMismatchReport = Get-Content -LiteralPath $androidAabHashMismatchReportPath -Raw | ConvertFrom-Json
  $androidAabHashMismatchReport.releaseAabSha256 = "e" * 64
  Write-JsonFile -Path $androidAabHashMismatchReportPath -Value $androidAabHashMismatchReport
  $androidAabHashMismatchResult = Invoke-CompanionV1BundleCheck -EvidenceRoot $androidAabHashMismatchRoot
  if ([int]$androidAabHashMismatchResult.exitCode -eq 0) {
    throw "Expected mismatched Companion v1 Android release AAB hash to fail."
  }
  Assert-CheckStatus -Report $androidAabHashMismatchResult.report -Id "android-v1-release-aab-hash-match" -Status "fail"
  Write-Host "[ok] mismatched Companion v1 Android release AAB hash is rejected"

  $desktopHashMismatchRoot = New-TempEvidenceRoot
  Copy-Item -Path (Join-Path $readyRoot "*") -Destination $desktopHashMismatchRoot -Recurse -Force
  $desktopHashMismatchReportPath = Join-Path $desktopHashMismatchRoot $reports.desktopV1BundleReport
  $desktopHashMismatchReport = Get-Content -LiteralPath $desktopHashMismatchReportPath -Raw | ConvertFrom-Json
  $desktopHashMismatchReport.windowsMsiSha256 = "e" * 64
  Write-JsonFile -Path $desktopHashMismatchReportPath -Value $desktopHashMismatchReport
  $desktopHashMismatchResult = Invoke-CompanionV1BundleCheck -EvidenceRoot $desktopHashMismatchRoot
  if ([int]$desktopHashMismatchResult.exitCode -eq 0) {
    throw "Expected mismatched Companion v1 Desktop package hash to fail."
  }
  Assert-CheckStatus -Report $desktopHashMismatchResult.report -Id "desktop-v1-artifact-hashes-match" -Status "fail"
  Write-Host "[ok] mismatched Companion v1 Desktop package hash is rejected"

  $desktopMismatchRoot = New-TempEvidenceRoot
  Copy-Item -Path (Join-Path $readyRoot "*") -Destination $desktopMismatchRoot -Recurse -Force
  Write-JsonFile -Path (Join-Path $desktopMismatchRoot $reports.desktopV1BundleReport) -Value ([ordered]@{
      schema = "stackchan.desktop-v1-evidence-bundle-check.v1"
      status = "desktop-v1-evidence-ready"
      sourceCommit = ("e" * 40)
      passed = 1
      failed = 0
      pending = 0
      checks = @()
    })
  $desktopMismatchResult = Invoke-CompanionV1BundleCheck -EvidenceRoot $desktopMismatchRoot
  if ([int]$desktopMismatchResult.exitCode -eq 0) {
    throw "Expected mismatched Companion v1 Desktop bundle commit to fail."
  }
  Assert-CheckStatus -Report $desktopMismatchResult.report -Id "desktop-v1-commit-match" -Status "fail"
  Write-Host "[ok] mismatched Companion v1 Desktop bundle commit is rejected"

  $voiceMismatchRoot = New-TempEvidenceRoot
  Copy-Item -Path (Join-Path $readyRoot "*") -Destination $voiceMismatchRoot -Recurse -Force
  Write-JsonFile -Path (Join-Path $voiceMismatchRoot $reports.voiceSourceReadinessReport) -Value ([ordered]@{
      schema = "stackchan.voice-source-readiness.v1"
      status = "production-voice-source-ready"
      sourceCommit = ("e" * 40)
      passed = 1
      failed = 0
      pending = 0
      checks = @()
    })
  $voiceMismatchResult = Invoke-CompanionV1BundleCheck -EvidenceRoot $voiceMismatchRoot
  if ([int]$voiceMismatchResult.exitCode -eq 0) {
    throw "Expected mismatched Companion v1 voice-source commit to fail."
  }
  Assert-CheckStatus -Report $voiceMismatchResult.report -Id "voice-source-commit-match" -Status "fail"
  Write-Host "[ok] mismatched Companion v1 voice-source commit is rejected"

  $reviewCommitMismatchRoot = New-TempEvidenceRoot
  Copy-Item -Path (Join-Path $readyRoot "*") -Destination $reviewCommitMismatchRoot -Recurse -Force
  @"
# Companion V1 Review

- Reviewer: Contract Test
- Review date: 2026-07-06
- Source commit: $("e" * 40)
- Release version: $releaseVersion
- Overall companion v1 decision: pass
- Source/readiness decision: pass
- Release package decision: pass
- GitHub Actions decision: pass
- Android v1 decision: pass
- Desktop v1 decision: pass
- Physical robot evidence decision: pass
- Production voice-source decision: pass
- Play distribution decision: pass
"@ | Set-Content -Path (Join-Path $reviewCommitMismatchRoot "COMPANION_V1_REVIEW.md") -Encoding UTF8
  $reviewCommitMismatchResult = Invoke-CompanionV1BundleCheck -EvidenceRoot $reviewCommitMismatchRoot
  if ([int]$reviewCommitMismatchResult.exitCode -eq 0) {
    throw "Expected mismatched Companion v1 review source commit to fail."
  }
  Assert-CheckStatus -Report $reviewCommitMismatchResult.report -Id "companion-v1-review" -Status "fail"
  Write-Host "[ok] mismatched Companion v1 review source commit is rejected"

  $reviewVersionMismatchRoot = New-TempEvidenceRoot
  Copy-Item -Path (Join-Path $readyRoot "*") -Destination $reviewVersionMismatchRoot -Recurse -Force
  @"
# Companion V1 Review

- Reviewer: Contract Test
- Review date: 2026-07-06
- Source commit: $sourceCommit
- Release version: v9.9.9
- Overall companion v1 decision: pass
- Source/readiness decision: pass
- Release package decision: pass
- GitHub Actions decision: pass
- Android v1 decision: pass
- Desktop v1 decision: pass
- Physical robot evidence decision: pass
- Production voice-source decision: pass
- Play distribution decision: pass
"@ | Set-Content -Path (Join-Path $reviewVersionMismatchRoot "COMPANION_V1_REVIEW.md") -Encoding UTF8
  $reviewVersionMismatchResult = Invoke-CompanionV1BundleCheck -EvidenceRoot $reviewVersionMismatchRoot
  if ([int]$reviewVersionMismatchResult.exitCode -eq 0) {
    throw "Expected mismatched Companion v1 review release version to fail."
  }
  Assert-CheckStatus -Report $reviewVersionMismatchResult.report -Id "companion-v1-review" -Status "fail"
  Write-Host "[ok] mismatched Companion v1 review release version is rejected"

  Write-Host "Companion v1 evidence bundle contract tests passed."
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
