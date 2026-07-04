param()

$ErrorActionPreference = "Stop"

$repoRoot = Resolve-Path (Join-Path $PSScriptRoot "..")
$checkScript = Join-Path $PSScriptRoot "check_hardware_evidence_progress.ps1"
$createdRoots = New-Object System.Collections.Generic.List[string]

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

function New-ValidReports {
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
  param([object]$Reports)

  $root = Join-Path ([System.IO.Path]::GetTempPath()) ("stackchan-progress-probe-contract-" + [guid]::NewGuid().ToString("N"))
  $createdRoots.Add($root) | Out-Null

  Write-JsonFile -Path (Join-Path $root "android/companion-probe/android_companion_probe.json") -Value $Reports.companion
  Write-JsonFile -Path (Join-Path $root "android/screen-off-soak/android_companion_soak.json") -Value $Reports.soak
  Write-JsonFile -Path (Join-Path $root "android/udp-beacon-probe/android_udp_beacon_probe.json") -Value $Reports.udp
  Write-JsonFile -Path (Join-Path $root "android/logcat/android_companion_logcat.json") -Value $Reports.logcat
  Write-JsonFile -Path (Join-Path $root "metadata.json") -Value ([ordered]@{
      androidCompanionProbes = [ordered]@{
        apkInstallReport = ""
        companionProbeReport = "android/companion-probe/android_companion_probe.json"
        screenOffSoakReport = "android/screen-off-soak/android_companion_soak.json"
        udpBeaconProbeReport = "android/udp-beacon-probe/android_udp_beacon_probe.json"
        logcatReport = "android/logcat/android_companion_logcat.json"
      }
    })

  return $root
}

function Invoke-ProgressCheck {
  param([string]$EvidenceRoot)

  $reportPath = Join-Path $EvidenceRoot "BENCH_STATUS.json"
  $powerShellExe = (Get-Process -Id $PID).Path
  $output = & $powerShellExe `
    -NoProfile `
    -ExecutionPolicy Bypass `
    -File $checkScript `
    -EvidenceRoot $EvidenceRoot `
    -ReportPath $reportPath 2>&1
  $exitCode = $LASTEXITCODE

  if ($exitCode -ne 0 -and $exitCode -ne 2) {
    throw "Progress check exited with $exitCode.`n$($output | Out-String)"
  }
  if (-not (Test-Path -LiteralPath $reportPath)) {
    throw "Progress check did not write $reportPath.`n$($output | Out-String)"
  }

  return Get-Content -LiteralPath $reportPath -Raw | ConvertFrom-Json
}

function Assert-ReportHasFinding {
  param(
    [object]$Report,
    [string]$Needle
  )

  $matches = @($Report.findings | Where-Object { [string]$_ -like "*$Needle*" })
  if ($matches.Count -eq 0) {
    throw "Expected finding containing '$Needle'. Findings:`n$($Report.findings | Out-String)"
  }
}

function Assert-ReportLacksFinding {
  param(
    [object]$Report,
    [string]$Needle
  )

  $matches = @($Report.findings | Where-Object { [string]$_ -like "*$Needle*" })
  if ($matches.Count -gt 0) {
    throw "Unexpected finding containing '$Needle'. Findings:`n$($Report.findings | Out-String)"
  }
}

function Assert-ReportHasPass {
  param(
    [object]$Report,
    [string]$Needle
  )

  $matches = @($Report.passes | Where-Object { [string]$_ -like "*$Needle*" })
  if ($matches.Count -eq 0) {
    throw "Expected passing signal containing '$Needle'. Passes:`n$($Report.passes | Out-String)"
  }
}

function Invoke-ProgressCase {
  param(
    [string]$Name,
    [object]$Reports
  )

  $root = New-TestEvidenceRoot -Reports $Reports
  $report = Invoke-ProgressCheck -EvidenceRoot $root
  Write-Host "[ok] exercised $Name"
  return $report
}

try {
  Set-Location $repoRoot

  $schemaMismatchReports = New-ValidReports
  $schemaMismatchReports.companion.schema = "stackchan.unexpected.v1"
  $schemaMismatchResult = Invoke-ProgressCase -Name "companion schema mismatch" -Reports $schemaMismatchReports
  Assert-ReportHasFinding -Report $schemaMismatchResult -Needle "Android companion bridge probe report schema mismatch"

  $udpFailureReports = New-ValidReports
  $udpFailureReports.udp.status = "fail"
  $udpFailureReports.udp.issues = @("timed out waiting for UDP beacon")
  $udpFailureResult = Invoke-ProgressCase -Name "UDP beacon failure status" -Reports $udpFailureReports
  Assert-ReportHasFinding -Report $udpFailureResult -Needle "Android UDP beacon probe report did not pass"

  $soakFailureReports = New-ValidReports
  $soakFailureReports.soak.status = "fail"
  $soakFailureReports.soak.issues = @("failed samples 1 exceeded max failures 0")
  $soakFailureResult = Invoke-ProgressCase -Name "screen-off soak failure status" -Reports $soakFailureReports
  Assert-ReportHasFinding -Report $soakFailureResult -Needle "Android screen-off soak report did not pass"

  $logcatFailureReports = New-ValidReports
  $logcatFailureReports.logcat.status = "failed"
  $logcatFailureReports.logcat.issues = @("CompanionBridgeService not observed")
  $logcatFailureResult = Invoke-ProgressCase -Name "logcat failure status" -Reports $logcatFailureReports
  Assert-ReportHasFinding -Report $logcatFailureResult -Needle "Android companion logcat capture report did not pass"

  $validReports = New-ValidReports
  $validResult = Invoke-ProgressCase -Name "valid Android probe reports" -Reports $validReports
  Assert-ReportHasPass -Report $validResult -Needle "Android companion bridge probe report status: pass"
  Assert-ReportHasPass -Report $validResult -Needle "Android screen-off soak report status: pass"
  Assert-ReportHasPass -Report $validResult -Needle "Android UDP beacon probe report status: pass"
  Assert-ReportHasPass -Report $validResult -Needle "Android companion logcat capture report status: captured"
  Assert-ReportLacksFinding -Report $validResult -Needle "Android companion bridge probe report schema mismatch"
  Assert-ReportLacksFinding -Report $validResult -Needle "Android screen-off soak report did not pass"
  Assert-ReportLacksFinding -Report $validResult -Needle "Android UDP beacon probe report did not pass"
  Assert-ReportLacksFinding -Report $validResult -Needle "Android companion logcat capture report did not pass"

  Write-Host "Android probe evidence progress contract tests passed."
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
