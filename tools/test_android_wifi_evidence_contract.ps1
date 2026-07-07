param()

$ErrorActionPreference = "Stop"

$repoRoot = Resolve-Path (Join-Path $PSScriptRoot "..")
$checkScript = Join-Path $PSScriptRoot "check_android_wifi_evidence.ps1"
$createdRoots = New-Object System.Collections.Generic.List[string]
$sourceCommit = "abcdef1234567890abcdef1234567890abcdef12"

function New-TempEvidenceRoot {
  $root = Join-Path ([System.IO.Path]::GetTempPath()) ("stackchan-android-wifi-contract-" + [guid]::NewGuid().ToString("N"))
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

function Invoke-WifiEvidenceCheck {
  param(
    [string]$EvidenceRoot,
    [string]$ExpectedSourceCommit = $sourceCommit,
    [switch]$RequireReady
  )

  $powerShellExe = (Get-Process -Id $PID).Path
  $arguments = @(
    "-NoProfile",
    "-ExecutionPolicy",
    "Bypass",
    "-File",
    $checkScript,
    "-DiagnosticsExportPath",
    (Join-Path $EvidenceRoot "ANDROID_DIAGNOSTICS_EXPORT.json"),
    "-RobotLogPath",
    (Join-Path $EvidenceRoot "robot_wifi_serial.log"),
    "-ReviewPath",
    (Join-Path $EvidenceRoot "ANDROID_WIFI_REVIEW.md"),
    "-SourceCommit",
    $ExpectedSourceCommit,
    "-Json"
  )
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

function New-ReadyDiagnostics {
  return [ordered]@{
    schema = "stackchan.android.diagnostics-export.v1"
    pairing = [ordered]@{
      wifi_provisioning_command_template = 'wifi set ssid "<network-name>" pass "<network-password>" url "ws://192.168.1.42:8765/bridge"'
      wifi_clear_command = "wifi clear"
      password_redacted = $true
    }
    bridge = [ordered]@{
      primary_bridge_url = "ws://192.168.1.42:8765/bridge"
      robot_socket_connected = $true
    }
    robot = [ordered]@{
      connected = $true
    }
  }
}

function Write-ReadyWifiEvidence {
  param(
    [string]$Root,
    [string]$ReviewSourceCommit = $sourceCommit,
    [switch]$MissingReload,
    [switch]$PasswordLeak
  )

  Write-JsonFile -Path (Join-Path $Root "ANDROID_DIAGNOSTICS_EXPORT.json") -Value (New-ReadyDiagnostics)

  $reloadMarker = if ($MissingReload) { "" } else { "bridge_wifi_store_loads=2 bridge_wifi_store_has_record=1`n" }
  $passwordMarker = if ($PasswordLeak) { 'pass="super-secret-network-key"' } else { "" }
  @"
[wifi] persisted=1 store_has_record=1 enabled=1 ssid_set=1
$reloadMarker wifi clear
store_has_record=0
$passwordMarker
"@ | Set-Content -Path (Join-Path $Root "robot_wifi_serial.log") -Encoding UTF8

  @"
# Android Wi-Fi Provisioning Evidence Review

- Reviewer: Contract Test
- Review date: 2026-07-06
- Support decision: pass
- Android device: Pixel contract
- Android version: 15
- App version: 1.0.0
- Source commit: $ReviewSourceCommit
- Diagnostics export path: ANDROID_DIAGNOSTICS_EXPORT.json
- Robot Wi-Fi log path: robot_wifi_serial.log
- Wi-Fi command decision: pass
- Persistence decision: pass
- Power-cycle reload decision: pass
- Clear command decision: pass
- Password privacy decision: pass
"@ | Set-Content -Path (Join-Path $Root "ANDROID_WIFI_REVIEW.md") -Encoding UTF8
}

try {
  Set-Location $repoRoot

  $readyRoot = New-TempEvidenceRoot
  Write-ReadyWifiEvidence -Root $readyRoot
  $readyResult = Invoke-WifiEvidenceCheck -EvidenceRoot $readyRoot -RequireReady
  if ([int]$readyResult.exitCode -ne 0) {
    throw "Expected complete Android Wi-Fi evidence to pass. Output:`n$($readyResult.text)"
  }
  if ($readyResult.report.status -ne "android-wifi-ready" -or $readyResult.report.sourceCommit -ne $sourceCommit -or $readyResult.report.expectedSourceCommit -ne $sourceCommit) {
    throw "Expected android-wifi-ready with matching sourceCommit and expectedSourceCommit."
  }
  foreach ($id in @("wifi-command-template", "wifi-clear-command", "diagnostics-password-redacted", "bridge-url-present", "robot-connected", "wifi-set-result", "wifi-reload-result", "wifi-clear-result", "robot-log-password-privacy", "wifi-review", "wifi-review-source-commit-match")) {
    Assert-CheckStatus -Report $readyResult.report -Id $id -Status "pass"
  }
  Write-Host "[ok] complete Android Wi-Fi evidence is accepted"

  $missingReloadRoot = New-TempEvidenceRoot
  Write-ReadyWifiEvidence -Root $missingReloadRoot -MissingReload
  $missingReloadResult = Invoke-WifiEvidenceCheck -EvidenceRoot $missingReloadRoot
  if ($missingReloadResult.report.status -ne "pending-android-wifi-evidence") {
    throw "Expected missing Wi-Fi reload proof to keep evidence pending, got $($missingReloadResult.report.status)."
  }
  Assert-CheckStatus -Report $missingReloadResult.report -Id "wifi-reload-result" -Status "pending"
  Write-Host "[ok] missing Android Wi-Fi reload proof remains pending"

  $passwordLeakRoot = New-TempEvidenceRoot
  Write-ReadyWifiEvidence -Root $passwordLeakRoot -PasswordLeak
  $passwordLeakResult = Invoke-WifiEvidenceCheck -EvidenceRoot $passwordLeakRoot -RequireReady
  if ([int]$passwordLeakResult.exitCode -eq 0) {
    throw "Expected Android Wi-Fi evidence with password leakage to fail."
  }
  Assert-CheckStatus -Report $passwordLeakResult.report -Id "robot-log-password-privacy" -Status "fail"
  Write-Host "[ok] Android Wi-Fi robot log password leak is rejected"

  $staleReviewRoot = New-TempEvidenceRoot
  Write-ReadyWifiEvidence -Root $staleReviewRoot -ReviewSourceCommit ("b" * 40)
  $staleReviewResult = Invoke-WifiEvidenceCheck -EvidenceRoot $staleReviewRoot -RequireReady
  if ([int]$staleReviewResult.exitCode -eq 0) {
    throw "Expected stale Android Wi-Fi review source commit to fail."
  }
  Assert-CheckStatus -Report $staleReviewResult.report -Id "wifi-review-source-commit-match" -Status "fail"
  Write-Host "[ok] stale Android Wi-Fi review source commit is rejected"

  Write-Host "Android Wi-Fi evidence contract tests passed."
} finally {
  foreach ($root in $createdRoots) {
    if (Test-Path -LiteralPath $root) {
      Remove-Item -LiteralPath $root -Recurse -Force
    }
  }
}
