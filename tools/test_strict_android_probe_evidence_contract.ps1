param()

$ErrorActionPreference = "Stop"

$repoRoot = Resolve-Path (Join-Path $PSScriptRoot "..")
$verifyScript = Join-Path $PSScriptRoot "verify_hardware_evidence.ps1"
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

  $root = Join-Path ([System.IO.Path]::GetTempPath()) ("stackchan-strict-probe-contract-" + [guid]::NewGuid().ToString("N"))
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

function Invoke-StrictProbeContractCheck {
  param([string]$EvidenceRoot)

  $powerShellExe = (Get-Process -Id $PID).Path
  $oldErrorActionPreference = $ErrorActionPreference
  $ErrorActionPreference = "Continue"
  try {
    $output = & $powerShellExe `
      -NoProfile `
      -ExecutionPolicy Bypass `
      -File $verifyScript `
      -EvidenceRoot $EvidenceRoot `
      -AndroidProbeEvidenceContractSelfTest 2>&1
    $exitCode = $LASTEXITCODE
  } finally {
    $ErrorActionPreference = $oldErrorActionPreference
  }

  return [pscustomobject]@{
    exitCode = $exitCode
    text = ($output | Out-String).TrimEnd()
  }
}

function Assert-ContractFailsWith {
  param(
    [string]$Name,
    [object]$Reports,
    [string]$Needle
  )

  $root = New-TestEvidenceRoot -Reports $Reports
  $result = Invoke-StrictProbeContractCheck -EvidenceRoot $root
  if ([int]$result.exitCode -eq 0) {
    throw "Expected strict Android probe verifier contract case '$Name' to fail."
  }
  if ([string]$result.text -notlike "*$Needle*") {
    throw "Expected strict Android probe verifier contract case '$Name' to mention '$Needle'. Output:`n$($result.text)"
  }
  Write-Host "[ok] exercised $Name"
}

try {
  Set-Location $repoRoot

  $schemaMismatchReports = New-ValidReports
  $schemaMismatchReports.companion.schema = "stackchan.unexpected.v1"
  Assert-ContractFailsWith -Name "companion schema mismatch" -Reports $schemaMismatchReports -Needle "Android companion bridge probe schema mismatch"

  $udpFailureReports = New-ValidReports
  $udpFailureReports.udp.status = "fail"
  $udpFailureReports.udp.issues = @("timed out waiting for UDP beacon")
  Assert-ContractFailsWith -Name "UDP beacon failure status" -Reports $udpFailureReports -Needle "Android UDP beacon probe status is not accepted"

  $soakFailureReports = New-ValidReports
  $soakFailureReports.soak.status = "fail"
  $soakFailureReports.soak.issues = @("failed samples 1 exceeded max failures 0")
  Assert-ContractFailsWith -Name "screen-off soak failure status" -Reports $soakFailureReports -Needle "Android screen-off soak status is not accepted"

  $logcatFailureReports = New-ValidReports
  $logcatFailureReports.logcat.status = "failed"
  $logcatFailureReports.logcat.issues = @("CompanionBridgeService not observed")
  Assert-ContractFailsWith -Name "logcat failure status" -Reports $logcatFailureReports -Needle "Android companion logcat capture status is not accepted"

  $validReports = New-ValidReports
  $validRoot = New-TestEvidenceRoot -Reports $validReports
  $validResult = Invoke-StrictProbeContractCheck -EvidenceRoot $validRoot
  if ([int]$validResult.exitCode -ne 0) {
    throw "Expected valid strict Android probe verifier contract case to pass. Output:`n$($validResult.text)"
  }
  if ([string]$validResult.text -notlike "*Android probe strict evidence contract verified*") {
    throw "Valid strict Android probe verifier contract case did not report success. Output:`n$($validResult.text)"
  }
  Write-Host "[ok] exercised valid Android probe reports"

  Write-Host "Strict Android probe evidence contract tests passed."
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
