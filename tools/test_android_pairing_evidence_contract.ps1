param()

$ErrorActionPreference = "Stop"

$repoRoot = Resolve-Path (Join-Path $PSScriptRoot "..")
$checkScript = Join-Path $PSScriptRoot "check_android_pairing_evidence.ps1"
$createdRoots = New-Object System.Collections.Generic.List[string]
$sourceCommit = "abcdef1234567890abcdef1234567890abcdef12"

function New-TempEvidenceRoot {
  $root = Join-Path ([System.IO.Path]::GetTempPath()) ("stackchan-android-pairing-contract-" + [guid]::NewGuid().ToString("N"))
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

function Invoke-PairingEvidenceCheck {
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
    (Join-Path $EvidenceRoot "robot_pairing_serial.log"),
    "-PairingMediaPath",
    (Join-Path $EvidenceRoot "android_pairing_setup.jpg"),
    "-ReviewPath",
    (Join-Path $EvidenceRoot "ANDROID_PAIRING_REVIEW.md"),
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
    endpoint = [ordered]@{
      endpoint_kind = "android"
      endpoint_id = "android-contract-node"
    }
    pairing = [ordered]@{
      pairing_code_present = $true
      pairing_qr_scheme = "stackchan://pair"
      password_redacted = $true
    }
    bridge = [ordered]@{
      robot_socket_connected = $true
    }
    robot = [ordered]@{
      connected = $true
      device_id = "stackchan-contract"
    }
  }
}

function Write-ReadyPairingEvidence {
  param(
    [string]$Root,
    [string]$ReviewSourceCommit = $sourceCommit,
    [switch]$MissingWrongCode,
    [switch]$BadEndpoint
  )

  $diagnostics = New-ReadyDiagnostics
  if ($BadEndpoint) {
    $diagnostics.endpoint.endpoint_kind = "desktop"
  }
  Write-JsonFile -Path (Join-Path $Root "ANDROID_DIAGNOSTICS_EXPORT.json") -Value $diagnostics

  "pairing setup media" | Set-Content -Path (Join-Path $Root "android_pairing_setup.jpg") -Encoding UTF8
  $wrongCodeMarker = if ($MissingWrongCode) { "" } else { "pairing_code_mismatch`n" }
  @"
$wrongCodeMarker stackchan://pair?code=ABC123&bridge=ws://192.168.1.42:8765/bridge
pairing_code ABC123
bridge_url_applied ws://192.168.1.42:8765/bridge
endpoint_hello
endpoint_hello_result accepted=1
trusted_endpoints_result android-contract-node
"@ | Set-Content -Path (Join-Path $Root "robot_pairing_serial.log") -Encoding UTF8

  @"
# Android Pairing Evidence Review

- Reviewer: Contract Test
- Review date: 2026-07-06
- Support decision: pass
- Android device: Pixel contract
- Android version: 15
- App version: 1.0.0
- Source commit: $ReviewSourceCommit
- Diagnostics export path: ANDROID_DIAGNOSTICS_EXPORT.json
- Robot pairing log path: robot_pairing_serial.log
- Pairing media path: android_pairing_setup.jpg
- Setup media decision: pass
- Wrong-code rejection decision: pass
- QR ticket/manual code decision: pass
- Trusted endpoint decision: pass
- Password privacy decision: pass
"@ | Set-Content -Path (Join-Path $Root "ANDROID_PAIRING_REVIEW.md") -Encoding UTF8
}

try {
  Set-Location $repoRoot

  $readyRoot = New-TempEvidenceRoot
  Write-ReadyPairingEvidence -Root $readyRoot
  $readyResult = Invoke-PairingEvidenceCheck -EvidenceRoot $readyRoot -RequireReady
  if ([int]$readyResult.exitCode -ne 0) {
    throw "Expected complete Android pairing evidence to pass. Output:`n$($readyResult.text)"
  }
  if ($readyResult.report.status -ne "android-pairing-ready" -or $readyResult.report.sourceCommit -ne $sourceCommit -or $readyResult.report.expectedSourceCommit -ne $sourceCommit) {
    throw "Expected android-pairing-ready with matching sourceCommit and expectedSourceCommit."
  }
  foreach ($id in @("android-endpoint", "pairing-code-present", "pairing-qr-scheme", "password-redacted", "robot-connected", "pairing-media", "wrong-code-rejection", "qr-ticket-entry", "trusted-endpoint-acceptance", "robot-log-password-privacy", "pairing-review", "pairing-review-source-commit-match")) {
    Assert-CheckStatus -Report $readyResult.report -Id $id -Status "pass"
  }
  Write-Host "[ok] complete Android pairing evidence is accepted"

  $missingWrongCodeRoot = New-TempEvidenceRoot
  Write-ReadyPairingEvidence -Root $missingWrongCodeRoot -MissingWrongCode
  $missingWrongCodeResult = Invoke-PairingEvidenceCheck -EvidenceRoot $missingWrongCodeRoot
  if ($missingWrongCodeResult.report.status -ne "pending-android-pairing-evidence") {
    throw "Expected missing wrong-code rejection to keep pairing evidence pending, got $($missingWrongCodeResult.report.status)."
  }
  Assert-CheckStatus -Report $missingWrongCodeResult.report -Id "wrong-code-rejection" -Status "pending"
  Write-Host "[ok] missing Android pairing wrong-code rejection remains pending"

  $badEndpointRoot = New-TempEvidenceRoot
  Write-ReadyPairingEvidence -Root $badEndpointRoot -BadEndpoint
  $badEndpointResult = Invoke-PairingEvidenceCheck -EvidenceRoot $badEndpointRoot -RequireReady
  if ([int]$badEndpointResult.exitCode -eq 0) {
    throw "Expected Android pairing evidence with non-Android endpoint identity to fail."
  }
  Assert-CheckStatus -Report $badEndpointResult.report -Id "android-endpoint" -Status "fail"
  Write-Host "[ok] Android pairing non-Android endpoint identity is rejected"

  $staleReviewRoot = New-TempEvidenceRoot
  Write-ReadyPairingEvidence -Root $staleReviewRoot -ReviewSourceCommit ("b" * 40)
  $staleReviewResult = Invoke-PairingEvidenceCheck -EvidenceRoot $staleReviewRoot -RequireReady
  if ([int]$staleReviewResult.exitCode -eq 0) {
    throw "Expected stale Android pairing review source commit to fail."
  }
  Assert-CheckStatus -Report $staleReviewResult.report -Id "pairing-review-source-commit-match" -Status "fail"
  Write-Host "[ok] stale Android pairing review source commit is rejected"

  Write-Host "Android pairing evidence contract tests passed."
} finally {
  foreach ($root in $createdRoots) {
    if (Test-Path -LiteralPath $root) {
      Remove-Item -LiteralPath $root -Recurse -Force
    }
  }
}
