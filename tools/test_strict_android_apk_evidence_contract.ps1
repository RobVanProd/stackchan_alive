param()

$ErrorActionPreference = "Stop"

$repoRoot = Resolve-Path (Join-Path $PSScriptRoot "..")
$verifyScript = Join-Path $PSScriptRoot "verify_hardware_evidence.ps1"
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

  $root = Join-Path ([System.IO.Path]::GetTempPath()) ("stackchan-strict-apk-contract-" + [guid]::NewGuid().ToString("N"))
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

function Invoke-StrictContractCheck {
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
      -AndroidApkEvidenceContractSelfTest 2>&1
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
    [object]$ApkInstallReport,
    [string]$Needle
  )

  $root = New-TestEvidenceRoot -ApkInstallReport $ApkInstallReport
  $result = Invoke-StrictContractCheck -EvidenceRoot $root
  if ([int]$result.exitCode -eq 0) {
    throw "Expected strict verifier contract case '$Name' to fail."
  }
  if ([string]$result.text -notlike "*$Needle*") {
    throw "Expected strict verifier contract case '$Name' to mention '$Needle'. Output:`n$($result.text)"
  }
  Write-Host "[ok] exercised $Name"
}

try {
  Set-Location $repoRoot

  $badHashReport = New-ApkInstallReport
  $badHashReport.apkSha256 = "abc123"
  Assert-ContractFailsWith -Name "invalid APK hash" -ApkInstallReport $badHashReport -Needle "missing a valid apkSha256"

  $missingCommitReport = New-ApkInstallReport
  $missingCommitReport.sourceCommit = ""
  Assert-ContractFailsWith -Name "missing source commit" -ApkInstallReport $missingCommitReport -Needle "missing a full sourceCommit SHA"

  $missingVersionReport = New-ApkInstallReport
  $missingVersionReport.versionName = ""
  Assert-ContractFailsWith -Name "missing installed version" -ApkInstallReport $missingVersionReport -Needle "missing installed versionName/versionCode"

  $validReport = New-ApkInstallReport
  $validRoot = New-TestEvidenceRoot -ApkInstallReport $validReport
  $validResult = Invoke-StrictContractCheck -EvidenceRoot $validRoot
  if ([int]$validResult.exitCode -ne 0) {
    throw "Expected valid strict verifier contract case to pass. Output:`n$($validResult.text)"
  }
  if ([string]$validResult.text -notlike "*Android APK strict evidence contract verified*") {
    throw "Valid strict verifier contract case did not report success. Output:`n$($validResult.text)"
  }
  Write-Host "[ok] exercised valid APK install evidence"

  Write-Host "Strict Android APK evidence contract tests passed."
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
