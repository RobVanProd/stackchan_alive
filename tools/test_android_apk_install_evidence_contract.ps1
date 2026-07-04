param()

$ErrorActionPreference = "Stop"

$repoRoot = Resolve-Path (Join-Path $PSScriptRoot "..")
$checkScript = Join-Path $PSScriptRoot "check_hardware_evidence_progress.ps1"
$createdRoots = New-Object System.Collections.Generic.List[string]

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

function New-TestEvidenceRoot {
  param([object]$ApkInstallReport)

  $root = Join-Path ([System.IO.Path]::GetTempPath()) ("stackchan-apk-install-contract-" + [guid]::NewGuid().ToString("N"))
  $createdRoots.Add($root) | Out-Null

  New-Item -ItemType Directory -Force -Path (Join-Path $root "android/apk-install") | Out-Null

  $metadata = [ordered]@{
    androidCompanionProbes = [ordered]@{
      apkInstallReport = "android/apk-install/android_apk_install.json"
      companionProbeReport = ""
      udpBeaconProbeReport = ""
      logcatReport = ""
    }
  }

  $metadata |
    ConvertTo-Json -Depth 6 |
    Set-Content -Path (Join-Path $root "metadata.json") -Encoding UTF8

  $ApkInstallReport |
    ConvertTo-Json -Depth 6 |
    Set-Content -Path (Join-Path $root "android/apk-install/android_apk_install.json") -Encoding UTF8

  return $root
}

function Invoke-ProgressCheck {
  param([string]$EvidenceRoot)

  $reportPath = Join-Path $EvidenceRoot "BENCH_STATUS.json"
  $powerShellExe = (Get-Process -Id $PID).Path
  $output = & $powerShellExe -NoProfile -ExecutionPolicy Bypass -File $checkScript -EvidenceRoot $EvidenceRoot -ReportPath $reportPath 2>&1
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

function Invoke-ApkInstallCase {
  param(
    [string]$Name,
    [object]$ApkInstallReport
  )

  $root = New-TestEvidenceRoot -ApkInstallReport $ApkInstallReport
  $report = Invoke-ProgressCheck -EvidenceRoot $root
  Write-Host "[ok] exercised $Name"
  return $report
}

try {
  Set-Location $repoRoot

  $badHashReport = New-ApkInstallReport
  $badHashReport.apkSha256 = "abc123"
  $badHashResult = Invoke-ApkInstallCase -Name "invalid APK hash" -ApkInstallReport $badHashReport
  Assert-ReportHasFinding -Report $badHashResult -Needle "missing a valid apkSha256"

  $missingCommitReport = New-ApkInstallReport
  $missingCommitReport.sourceCommit = ""
  $missingCommitResult = Invoke-ApkInstallCase -Name "missing source commit" -ApkInstallReport $missingCommitReport
  Assert-ReportHasFinding -Report $missingCommitResult -Needle "missing a full sourceCommit SHA"

  $missingVersionReport = New-ApkInstallReport
  $missingVersionReport.versionName = ""
  $missingVersionResult = Invoke-ApkInstallCase -Name "missing installed version" -ApkInstallReport $missingVersionReport
  Assert-ReportHasFinding -Report $missingVersionResult -Needle "missing installed versionName/versionCode"

  $validReport = New-ApkInstallReport
  $validResult = Invoke-ApkInstallCase -Name "valid APK install evidence" -ApkInstallReport $validReport
  Assert-ReportHasPass -Report $validResult -Needle "Android APK install evidence report status: installed"
  Assert-ReportLacksFinding -Report $validResult -Needle "missing a valid apkSha256"
  Assert-ReportLacksFinding -Report $validResult -Needle "missing a full sourceCommit SHA"
  Assert-ReportLacksFinding -Report $validResult -Needle "missing installed versionName/versionCode"

  Write-Host "Android APK install evidence contract tests passed."
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
