param()

$ErrorActionPreference = "Stop"

$repoRoot = Resolve-Path (Join-Path $PSScriptRoot "..")
$checkScript = Join-Path $PSScriptRoot "check_android_screen_off_soak_evidence.ps1"
$createdRoots = New-Object System.Collections.Generic.List[string]
$sourceCommit = "abcdef1234567890abcdef1234567890abcdef12"

function New-TempEvidenceRoot {
  $root = Join-Path ([System.IO.Path]::GetTempPath()) ("stackchan-android-soak-contract-" + [guid]::NewGuid().ToString("N"))
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

function Invoke-SoakEvidenceCheck {
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
    "-SoakJsonPath",
    (Join-Path $EvidenceRoot "android_companion_soak.json"),
    "-SoakMarkdownPath",
    (Join-Path $EvidenceRoot "ANDROID_COMPANION_SOAK.md"),
    "-ReviewPath",
    (Join-Path $EvidenceRoot "ANDROID_SCREEN_OFF_SOAK_REVIEW.md"),
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

function New-ReadySoakReport {
  param(
    [double]$DurationSeconds = 600.0,
    [switch]$UnstableEndpoint
  )

  $secondEndpoint = if ($UnstableEndpoint) { "android-contract-node-2" } else { "android-contract-node" }
  return [ordered]@{
    schema = "stackchan.android-companion-soak.v1"
    status = "pass"
    requested_duration_seconds = $DurationSeconds
    interval_seconds = 30.0
    max_failures = 0
    failed_count = 0
    success_rate = 1.0
    sample_count = 3
    samples = @(
      [ordered]@{ index = 1; status = "pass"; endpoint_kind = "android"; endpoint_id = "android-contract-node" },
      [ordered]@{ index = 2; status = "pass"; endpoint_kind = "android"; endpoint_id = "android-contract-node" },
      [ordered]@{ index = 3; status = "pass"; endpoint_kind = "android"; endpoint_id = $secondEndpoint }
    )
  }
}

function Write-ReadySoakEvidence {
  param(
    [string]$Root,
    [string]$ReviewSourceCommit = $sourceCommit,
    [double]$DurationSeconds = 600.0,
    [switch]$UnstableEndpoint
  )

  Write-JsonFile -Path (Join-Path $Root "android_companion_soak.json") -Value (New-ReadySoakReport -DurationSeconds $DurationSeconds -UnstableEndpoint:$UnstableEndpoint)

  @'
# Android Companion Screen-Off Soak

- Status: `pass`
- Failed: `0`

If the service stops, run RUN_ANDROID_LOGCAT_CAPTURE.cmd.
'@ | Set-Content -Path (Join-Path $Root "ANDROID_COMPANION_SOAK.md") -Encoding UTF8

  @"
# Android Screen-Off Soak Evidence Review

- Reviewer: Contract Test
- Review date: 2026-07-06
- Support decision: pass
- Android device: Pixel contract
- Android version: 15
- App version: 1.0.0
- Source commit: $ReviewSourceCommit
- Soak JSON path: android_companion_soak.json
- Soak summary path: ANDROID_COMPANION_SOAK.md
- Screen-off decision: pass
- Heartbeat continuity decision: pass
- Wake-lock release decision: pass
- Foreground-service decision: pass
- Reopen identity decision: pass
"@ | Set-Content -Path (Join-Path $Root "ANDROID_SCREEN_OFF_SOAK_REVIEW.md") -Encoding UTF8
}

try {
  Set-Location $repoRoot

  $readyRoot = New-TempEvidenceRoot
  Write-ReadySoakEvidence -Root $readyRoot
  $readyResult = Invoke-SoakEvidenceCheck -EvidenceRoot $readyRoot -RequireReady
  if ([int]$readyResult.exitCode -ne 0) {
    throw "Expected complete Android screen-off soak evidence to pass. Output:`n$($readyResult.text)"
  }
  if ($readyResult.report.status -ne "android-screen-off-soak-ready" -or $readyResult.report.sourceCommit -ne $sourceCommit -or $readyResult.report.expectedSourceCommit -ne $sourceCommit) {
    throw "Expected android-screen-off-soak-ready with matching sourceCommit and expectedSourceCommit."
  }
  foreach ($id in @("schema", "status", "duration", "interval", "max-failures", "failed-count", "success-rate", "sample-count", "android-samples", "stable-endpoint", "soak-summary-markers", "soak-review", "soak-review-source-commit-match")) {
    Assert-CheckStatus -Report $readyResult.report -Id $id -Status "pass"
  }
  Write-Host "[ok] complete Android screen-off soak evidence is accepted"

  $shortDurationRoot = New-TempEvidenceRoot
  Write-ReadySoakEvidence -Root $shortDurationRoot -DurationSeconds 300.0
  $shortDurationResult = Invoke-SoakEvidenceCheck -EvidenceRoot $shortDurationRoot -RequireReady
  if ([int]$shortDurationResult.exitCode -eq 0) {
    throw "Expected short Android screen-off soak duration to fail."
  }
  Assert-CheckStatus -Report $shortDurationResult.report -Id "duration" -Status "fail"
  Write-Host "[ok] short Android screen-off soak duration is rejected"

  $unstableEndpointRoot = New-TempEvidenceRoot
  Write-ReadySoakEvidence -Root $unstableEndpointRoot -UnstableEndpoint
  $unstableEndpointResult = Invoke-SoakEvidenceCheck -EvidenceRoot $unstableEndpointRoot
  if ($unstableEndpointResult.report.status -ne "pending-android-screen-off-soak-evidence") {
    throw "Expected unstable Android endpoint identity to keep soak evidence pending, got $($unstableEndpointResult.report.status)."
  }
  Assert-CheckStatus -Report $unstableEndpointResult.report -Id "stable-endpoint" -Status "pending"
  Write-Host "[ok] unstable Android screen-off endpoint identity remains pending"

  $staleReviewRoot = New-TempEvidenceRoot
  Write-ReadySoakEvidence -Root $staleReviewRoot -ReviewSourceCommit ("b" * 40)
  $staleReviewResult = Invoke-SoakEvidenceCheck -EvidenceRoot $staleReviewRoot -RequireReady
  if ([int]$staleReviewResult.exitCode -eq 0) {
    throw "Expected stale Android screen-off soak review source commit to fail."
  }
  Assert-CheckStatus -Report $staleReviewResult.report -Id "soak-review-source-commit-match" -Status "fail"
  Write-Host "[ok] stale Android screen-off soak review source commit is rejected"

  Write-Host "Android screen-off soak evidence contract tests passed."
} finally {
  foreach ($root in $createdRoots) {
    if (Test-Path -LiteralPath $root) {
      Remove-Item -LiteralPath $root -Recurse -Force
    }
  }
}
