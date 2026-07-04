param()

$ErrorActionPreference = "Stop"

$repoRoot = Resolve-Path (Join-Path $PSScriptRoot "..")
$rolloutScript = Join-Path $PSScriptRoot "export_rollout_status.ps1"
$createdRoots = New-Object System.Collections.Generic.List[string]
$testCommit = "c" * 40
$testVersion = "contract-test"

function New-TempRoot {
  param([string]$Prefix)

  $root = Join-Path ([System.IO.Path]::GetTempPath()) ($Prefix + "-" + [guid]::NewGuid().ToString("N"))
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
  $Value | ConvertTo-Json -Depth 8 | Set-Content -Path $Path -Encoding UTF8
}

function New-TestPackageRoot {
  $root = New-TempRoot -Prefix "stackchan-rollout-package-contract"

  Write-JsonFile -Path (Join-Path $root "release_manifest.json") -Value ([ordered]@{
      version = $testVersion
      commit = $testCommit
    })
  Write-JsonFile -Path (Join-Path $root "readiness_report.json") -Value ([ordered]@{
      schema = "stackchan.readiness-report.v1"
      version = $testVersion
      commit = $testCommit
      consumerRollout = "blocked-pending-hardware-validation"
    })
  Write-JsonFile -Path (Join-Path $root "github_actions_status.json") -Value ([ordered]@{
      schema = "stackchan.github-actions-status.v1"
      version = $testVersion
      commit = $testCommit
      status = "success"
      missingRequiredWorkflows = @()
    })
  Write-JsonFile -Path (Join-Path $root "voice_source_status.json") -Value ([ordered]@{
      schema = "stackchan.voice-source-status.v1"
      status = "blocked-pending-production-voice-source"
      blockedGateCount = 1
    })
  Write-JsonFile -Path (Join-Path $root "rvc_voice_base_status.json") -Value ([ordered]@{
      schema = "stackchan.rvc-voice-base-status.v1"
      status = "candidate-pending-rights-review"
      consumerApproved = $false
      distributionApproved = $false
      blockedGateCount = 1
      failedGateCount = 0
    })

  return $root
}

function New-ApkInstallReport {
  return [pscustomobject][ordered]@{
    schema = "stackchan.android-apk-install.v1"
    status = "installed"
    apkSha256 = ("a" * 64)
    sourceCommit = ("b" * 40)
    versionName = "1.0.0"
    versionCode = "100"
  }
}

function New-ValidProbeReports {
  return [ordered]@{
    companion = [ordered]@{
      schema = "stackchan.android-companion-probe.v1"
      status = "pass"
      issues = @()
    }
    soak = [ordered]@{
      schema = "stackchan.android-companion-soak.v1"
      status = "pass"
      issues = @()
    }
    udp = [ordered]@{
      schema = "stackchan.android-udp-beacon-probe.v1"
      status = "pass"
      issues = @()
    }
    logcat = [ordered]@{
      schema = "stackchan.android-companion-logcat.v1"
      status = "captured"
      issues = @()
    }
  }
}

function New-TestEvidenceRoot {
  param(
    [object]$ApkInstallReport,
    [object]$ProbeReports = $null
  )

  $root = New-TempRoot -Prefix "stackchan-rollout-evidence-contract"
  New-Item -ItemType Directory -Force -Path (Join-Path $root "android/apk-install") | Out-Null

  $companionReportPath = ""
  $soakReportPath = ""
  $udpReportPath = ""
  $logcatReportPath = ""
  if ($null -ne $ProbeReports) {
    $companionReportPath = "android/companion-probe/android_companion_probe.json"
    $soakReportPath = "android/screen-off-soak/android_companion_soak.json"
    $udpReportPath = "android/udp-beacon-probe/android_udp_beacon_probe.json"
    $logcatReportPath = "android/logcat/android_companion_logcat.json"
    Write-JsonFile -Path (Join-Path $root $companionReportPath) -Value $ProbeReports.companion
    Write-JsonFile -Path (Join-Path $root $soakReportPath) -Value $ProbeReports.soak
    Write-JsonFile -Path (Join-Path $root $udpReportPath) -Value $ProbeReports.udp
    Write-JsonFile -Path (Join-Path $root $logcatReportPath) -Value $ProbeReports.logcat
  }

  Write-JsonFile -Path (Join-Path $root "metadata.json") -Value ([ordered]@{
      releaseTag = $testVersion
      commit = $testCommit
      androidCompanionProbes = [ordered]@{
        apkInstallReport = "android/apk-install/android_apk_install.json"
        companionProbeReport = $companionReportPath
        screenOffSoakReport = $soakReportPath
        udpBeaconProbeReport = $udpReportPath
        logcatReport = $logcatReportPath
      }
    })
  Write-JsonFile -Path (Join-Path $root "android/apk-install/android_apk_install.json") -Value $ApkInstallReport

  return $root
}

function Invoke-RolloutStatus {
  param(
    [string]$PackageRoot,
    [string]$EvidenceRoot
  )

  $outDir = New-TempRoot -Prefix "stackchan-rollout-out-contract"
  $powerShellExe = (Get-Process -Id $PID).Path
  $output = & $powerShellExe `
    -NoProfile `
    -ExecutionPolicy Bypass `
    -File $rolloutScript `
    -Version $testVersion `
    -ExpectedCommit $testCommit `
    -PackageRoot $PackageRoot `
    -EvidenceRoot $EvidenceRoot `
    -OutDir $outDir 2>&1

  if ($LASTEXITCODE -ne 0 -and $LASTEXITCODE -ne 2) {
    throw "Rollout status export exited with $LASTEXITCODE.`n$($output | Out-String)"
  }

  $reportPath = Join-Path $outDir "ROLLOUT_STATUS.json"
  if (-not (Test-Path -LiteralPath $reportPath)) {
    throw "Rollout status export did not write $reportPath.`n$($output | Out-String)"
  }

  return Get-Content -LiteralPath $reportPath -Raw | ConvertFrom-Json
}

function Get-AndroidCompanionGate {
  param([object]$Report)

  $matches = @($Report.gates | Where-Object { [string]$_.gate -eq "android-companion-probes" })
  if ($matches.Count -ne 1) {
    throw "Expected one android-companion-probes gate, found $($matches.Count)."
  }
  return $matches[0]
}

function Assert-AndroidGate {
  param(
    [object]$Report,
    [string]$ExpectedStatus,
    [string]$EvidenceNeedle
  )

  $gate = Get-AndroidCompanionGate -Report $Report
  if ([string]$gate.status -ne $ExpectedStatus) {
    throw "Expected android-companion-probes status '$ExpectedStatus', got '$($gate.status)'. Evidence: $($gate.evidence)"
  }
  if ([string]$gate.evidence -notlike "*$EvidenceNeedle*") {
    throw "Expected android-companion-probes evidence containing '$EvidenceNeedle'. Evidence: $($gate.evidence)"
  }
}

function Invoke-RolloutCase {
  param(
    [string]$Name,
    [object]$ApkInstallReport,
    [object]$ProbeReports = $null
  )

  $packageRoot = New-TestPackageRoot
  $evidenceRoot = New-TestEvidenceRoot -ApkInstallReport $ApkInstallReport -ProbeReports $ProbeReports
  $report = Invoke-RolloutStatus -PackageRoot $packageRoot -EvidenceRoot $evidenceRoot
  Write-Host "[ok] exercised $Name"
  return $report
}

try {
  Set-Location $repoRoot

  $badHashReport = New-ApkInstallReport
  $badHashReport.apkSha256 = "abc123"
  $badHashResult = Invoke-RolloutCase -Name "invalid APK hash" -ApkInstallReport $badHashReport
  Assert-AndroidGate -Report $badHashResult -ExpectedStatus "blocked" -EvidenceNeedle "missing a valid apkSha256"

  $missingCommitReport = New-ApkInstallReport
  $missingCommitReport.sourceCommit = ""
  $missingCommitResult = Invoke-RolloutCase -Name "missing source commit" -ApkInstallReport $missingCommitReport
  Assert-AndroidGate -Report $missingCommitResult -ExpectedStatus "blocked" -EvidenceNeedle "missing a full sourceCommit SHA"

  $missingVersionReport = New-ApkInstallReport
  $missingVersionReport.versionCode = ""
  $missingVersionResult = Invoke-RolloutCase -Name "missing installed version" -ApkInstallReport $missingVersionReport
  Assert-AndroidGate -Report $missingVersionResult -ExpectedStatus "blocked" -EvidenceNeedle "missing installed versionName/versionCode"

  $validReport = New-ApkInstallReport
  $validResult = Invoke-RolloutCase -Name "valid APK install evidence" -ApkInstallReport $validReport
  Assert-AndroidGate -Report $validResult -ExpectedStatus "pass" -EvidenceNeedle "Android APK install evidence status installed"

  $companionSchemaMismatchReports = New-ValidProbeReports
  $companionSchemaMismatchReports.companion.schema = "stackchan.unexpected.v1"
  $companionSchemaMismatchResult = Invoke-RolloutCase -Name "companion schema mismatch" -ApkInstallReport (New-ApkInstallReport) -ProbeReports $companionSchemaMismatchReports
  Assert-AndroidGate -Report $companionSchemaMismatchResult -ExpectedStatus "blocked" -EvidenceNeedle "Android companion bridge probe schema mismatch"

  $udpFailureReports = New-ValidProbeReports
  $udpFailureReports.udp.status = "fail"
  $udpFailureReports.udp.issues = @("timed out waiting for UDP beacon")
  $udpFailureResult = Invoke-RolloutCase -Name "UDP beacon failure status" -ApkInstallReport (New-ApkInstallReport) -ProbeReports $udpFailureReports
  Assert-AndroidGate -Report $udpFailureResult -ExpectedStatus "blocked" -EvidenceNeedle "Android UDP beacon probe status fail"

  $soakFailureReports = New-ValidProbeReports
  $soakFailureReports.soak.status = "fail"
  $soakFailureReports.soak.issues = @("failed samples 1 exceeded max failures 0")
  $soakFailureResult = Invoke-RolloutCase -Name "screen-off soak failure status" -ApkInstallReport (New-ApkInstallReport) -ProbeReports $soakFailureReports
  Assert-AndroidGate -Report $soakFailureResult -ExpectedStatus "blocked" -EvidenceNeedle "Android screen-off soak status fail"

  $logcatFailureReports = New-ValidProbeReports
  $logcatFailureReports.logcat.status = "failed"
  $logcatFailureReports.logcat.issues = @("CompanionBridgeService not observed")
  $logcatFailureResult = Invoke-RolloutCase -Name "logcat failure status" -ApkInstallReport (New-ApkInstallReport) -ProbeReports $logcatFailureReports
  Assert-AndroidGate -Report $logcatFailureResult -ExpectedStatus "blocked" -EvidenceNeedle "Android companion logcat capture status failed"

  $validProbeReports = New-ValidProbeReports
  $validProbeResult = Invoke-RolloutCase -Name "valid Android probe reports" -ApkInstallReport (New-ApkInstallReport) -ProbeReports $validProbeReports
  Assert-AndroidGate -Report $validProbeResult -ExpectedStatus "pass" -EvidenceNeedle "Android companion bridge probe status pass"
  Assert-AndroidGate -Report $validProbeResult -ExpectedStatus "pass" -EvidenceNeedle "Android screen-off soak status pass"
  Assert-AndroidGate -Report $validProbeResult -ExpectedStatus "pass" -EvidenceNeedle "Android UDP beacon probe status pass"
  Assert-AndroidGate -Report $validProbeResult -ExpectedStatus "pass" -EvidenceNeedle "Android companion logcat capture status captured"

  Write-Host "Android rollout status evidence contract tests passed."
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
