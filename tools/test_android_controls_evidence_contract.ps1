param()

$ErrorActionPreference = "Stop"

$repoRoot = Resolve-Path (Join-Path $PSScriptRoot "..")
$checkScript = Join-Path $PSScriptRoot "check_android_controls_evidence.ps1"
$createdRoots = New-Object System.Collections.Generic.List[string]
$sourceCommit = "abcdef1234567890abcdef1234567890abcdef12"

function New-TempEvidenceRoot {
  $root = Join-Path ([System.IO.Path]::GetTempPath()) ("stackchan-android-controls-contract-" + [guid]::NewGuid().ToString("N"))
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

function Invoke-ControlsEvidenceCheck {
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
    (Join-Path $EvidenceRoot "robot_controls_serial.log"),
    "-ReviewPath",
    (Join-Path $EvidenceRoot "ANDROID_CONTROLS_REVIEW.md"),
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
    bridge = [ordered]@{
      robot_socket_connected = $true
      active_brain_owner = "android-contract-node"
    }
    robot = [ordered]@{
      connected = $true
      device_id = "stackchan-contract"
      firmware_version = "contract-fw"
    }
    endpoint = [ordered]@{
      endpoint_kind = "android"
      endpoint_id = "android-contract-node"
    }
    privacy = [ordered]@{
      raw_audio_retention = "none"
    }
  }
}

function Write-ReadyControlsEvidence {
  param(
    [string]$Root,
    [string]$ReviewSourceCommit = $sourceCommit,
    [switch]$MissingHelloGate,
    [switch]$BadEndpoint
  )

  $diagnostics = New-ReadyDiagnostics
  if ($BadEndpoint) {
    $diagnostics.endpoint.endpoint_kind = "desktop"
  }
  Write-JsonFile -Path (Join-Path $Root "ANDROID_DIAGNOSTICS_EXPORT.json") -Value $diagnostics

  $helloMarker = if ($MissingHelloGate) { "" } else { "robot_hello_required`n" }
  @"
$helloMarker settings_set
settings_result
claim_brain
owner_status active_brain_owner=android-contract-node
release_brain
"@ | Set-Content -Path (Join-Path $Root "robot_controls_serial.log") -Encoding UTF8

  @"
# Android Protected Controls Evidence Review

- Reviewer: Contract Test
- Review date: 2026-07-06
- Support decision: pass
- Android device: Pixel contract
- Android version: 15
- App version: 1.0.0
- Source commit: $ReviewSourceCommit
- Diagnostics export path: ANDROID_DIAGNOSTICS_EXPORT.json
- Robot control log path: robot_controls_serial.log
- Settings write decision: pass
- Claim brain decision: pass
- Release brain decision: pass
- Robot hello gate decision: pass
- Privacy decision: pass
"@ | Set-Content -Path (Join-Path $Root "ANDROID_CONTROLS_REVIEW.md") -Encoding UTF8
}

try {
  Set-Location $repoRoot

  $readyRoot = New-TempEvidenceRoot
  Write-ReadyControlsEvidence -Root $readyRoot
  $readyResult = Invoke-ControlsEvidenceCheck -EvidenceRoot $readyRoot -RequireReady
  if ([int]$readyResult.exitCode -ne 0) {
    throw "Expected complete Android controls evidence to pass. Output:`n$($readyResult.text)"
  }
  if ($readyResult.report.status -ne "android-controls-ready" -or $readyResult.report.sourceCommit -ne $sourceCommit -or $readyResult.report.expectedSourceCommit -ne $sourceCommit) {
    throw "Expected android-controls-ready with matching sourceCommit and expectedSourceCommit."
  }
  foreach ($id in @("robot-connected", "robot-identity", "android-endpoint", "active-brain-owner", "raw-audio-retention", "robot-controls-round-trip", "robot-hello-gate", "controls-review", "controls-review-source-commit-match")) {
    Assert-CheckStatus -Report $readyResult.report -Id $id -Status "pass"
  }
  Write-Host "[ok] complete Android controls evidence is accepted"

  $missingHelloRoot = New-TempEvidenceRoot
  Write-ReadyControlsEvidence -Root $missingHelloRoot -MissingHelloGate
  $missingHelloResult = Invoke-ControlsEvidenceCheck -EvidenceRoot $missingHelloRoot
  if ($missingHelloResult.report.status -ne "pending-android-controls-evidence") {
    throw "Expected missing robot hello gate to keep controls evidence pending, got $($missingHelloResult.report.status)."
  }
  Assert-CheckStatus -Report $missingHelloResult.report -Id "robot-hello-gate" -Status "pending"
  Write-Host "[ok] missing Android controls robot hello gate remains pending"

  $badEndpointRoot = New-TempEvidenceRoot
  Write-ReadyControlsEvidence -Root $badEndpointRoot -BadEndpoint
  $badEndpointResult = Invoke-ControlsEvidenceCheck -EvidenceRoot $badEndpointRoot -RequireReady
  if ([int]$badEndpointResult.exitCode -eq 0) {
    throw "Expected Android controls evidence with non-Android endpoint identity to fail."
  }
  Assert-CheckStatus -Report $badEndpointResult.report -Id "android-endpoint" -Status "fail"
  Write-Host "[ok] Android controls non-Android endpoint identity is rejected"

  $staleReviewRoot = New-TempEvidenceRoot
  Write-ReadyControlsEvidence -Root $staleReviewRoot -ReviewSourceCommit ("b" * 40)
  $staleReviewResult = Invoke-ControlsEvidenceCheck -EvidenceRoot $staleReviewRoot -RequireReady
  if ([int]$staleReviewResult.exitCode -eq 0) {
    throw "Expected stale Android controls review source commit to fail."
  }
  Assert-CheckStatus -Report $staleReviewResult.report -Id "controls-review-source-commit-match" -Status "fail"
  Write-Host "[ok] stale Android controls review source commit is rejected"

  Write-Host "Android controls evidence contract tests passed."
} finally {
  foreach ($root in $createdRoots) {
    if (Test-Path -LiteralPath $root) {
      Remove-Item -LiteralPath $root -Recurse -Force
    }
  }
}
