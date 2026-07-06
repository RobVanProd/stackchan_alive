param()

$ErrorActionPreference = "Stop"

$repoRoot = Resolve-Path (Join-Path $PSScriptRoot "..")
$checkScript = Join-Path $PSScriptRoot "check_desktop_v1_evidence_bundle.ps1"
$createdRoots = New-Object System.Collections.Generic.List[string]

function New-TempEvidenceRoot {
  $root = Join-Path ([System.IO.Path]::GetTempPath()) ("stackchan-desktop-v1-bundle-contract-" + [guid]::NewGuid().ToString("N"))
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

function Invoke-DesktopV1BundleCheck {
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
    [string]$Status
  )

  Write-JsonFile -Path $Path -Value ([ordered]@{
      schema = $Schema
      status = $Status
      passed = 1
      failed = 0
      pending = 0
      checks = @()
    })
}

function Write-C6Report {
  param(
    [string]$Path,
    [string]$Schema
  )

  Write-JsonFile -Path $Path -Value ([ordered]@{
      schema = $Schema
      generated_at = "2026-07-06T00:00:00Z"
      overall_ok = $true
      start_ok = $true
      first_turn_ok = $true
      restart_ok = $true
      second_turn_ok = $true
      diagnostics_export_ok = $true
    })
}

try {
  Set-Location $repoRoot

  $templateRoot = New-TempEvidenceRoot
  $templateResult = Invoke-DesktopV1BundleCheck -EvidenceRoot $templateRoot -WriteTemplate
  if ($templateResult.report.status -ne "pending-desktop-v1-evidence-bundle") {
    throw "Expected placeholder bundle to be pending, got $($templateResult.report.status)."
  }
  foreach ($id in @("source-commit", "hardware-evidence", "runtime-payload-status", "pc-brain-lab-status", "artifact-windows", "runtime-windows", "desktop-v1-review")) {
    Assert-CheckStatus -Report $templateResult.report -Id $id -Status "pending"
  }
  Write-Host "[ok] placeholder Desktop v1 evidence bundle is pending"

  $readyRoot = New-TempEvidenceRoot
  $sourceCommit = "c" * 40
  $reports = [ordered]@{
    companionReadinessReport = "reports/companion_v1_readiness.json"
    c6BrainSupervisorSmokeReport = "reports/BRAIN_SUPERVISOR_SMOKE.json"
    c6GuiRehearsalReport = "reports/GUI_REHEARSAL.json"
    windowsRuntimePayloadReport = "reports/desktop_runtime_windows.json"
    macosRuntimePayloadReport = "reports/desktop_runtime_macos.json"
    linuxRuntimePayloadReport = "reports/desktop_runtime_linux.json"
    pcBrainDeployCheckReport = "reports/pc_brain_deploy_check.json"
    pcBrainQuietSoakCheckReport = "reports/pc_brain_quiet_soak_check.json"
    voiceSourceReadinessReport = "reports/voice_source_readiness.json"
  }
  Write-JsonFile -Path (Join-Path $readyRoot "DESKTOP_V1_EVIDENCE_BUNDLE.json") -Value ([ordered]@{
      schema = "stackchan.desktop-v1-evidence-bundle.v1"
      status = "ready"
      sourceCommit = $sourceCommit
      releaseBuild = "desktop Windows MSI / macOS DMG / Linux DEB"
      hardwareEvidenceStatus = "verified"
      hardwareEvidenceRoot = "output/hardware-evidence/contract"
      desktopRuntimePayloadStatus = "ready"
      pcBrainLabStatus = "ready"
      artifacts = [ordered]@{
        windowsMsi = [ordered]@{ path = "artifacts/stackchan-companion.msi"; sha256 = ("a" * 64) }
        macosDmg = [ordered]@{ path = "artifacts/stackchan-companion.dmg"; sha256 = ("b" * 64) }
        linuxDeb = [ordered]@{ path = "artifacts/stackchan-companion.deb"; sha256 = ("c" * 64) }
      }
      reports = $reports
      reviewPath = "DESKTOP_V1_REVIEW.md"
    })
  Write-StatusReport -Path (Join-Path $readyRoot $reports.companionReadinessReport) -Schema "stackchan.companion-v1-readiness.v1" -Status "source-ready-pending-hardware"
  Write-C6Report -Path (Join-Path $readyRoot $reports.c6BrainSupervisorSmokeReport) -Schema "stackchan.companion.c6-brain-supervisor-smoke.v1"
  Write-C6Report -Path (Join-Path $readyRoot $reports.c6GuiRehearsalReport) -Schema "stackchan.companion.c6-gui-rehearsal.v1"
  Write-StatusReport -Path (Join-Path $readyRoot $reports.windowsRuntimePayloadReport) -Schema "stackchan.desktop-python-runtime-payload.v1" -Status "ready"
  Write-StatusReport -Path (Join-Path $readyRoot $reports.macosRuntimePayloadReport) -Schema "stackchan.desktop-python-runtime-payload.v1" -Status "ready"
  Write-StatusReport -Path (Join-Path $readyRoot $reports.linuxRuntimePayloadReport) -Schema "stackchan.desktop-python-runtime-payload.v1" -Status "ready"
  Write-StatusReport -Path (Join-Path $readyRoot $reports.pcBrainDeployCheckReport) -Schema "stackchan.pc-brain-deploy-evidence-check.v1" -Status "pc-brain-deploy-ready"
  Write-StatusReport -Path (Join-Path $readyRoot $reports.pcBrainQuietSoakCheckReport) -Schema "stackchan.pc-brain-quiet-soak-evidence-check.v1" -Status "pc-brain-quiet-soak-ready"
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
# Desktop V1 Review

- Reviewer: Contract Test
- Review date: 2026-07-06
- Source commit: $sourceCommit
- Overall desktop v1 decision: pass
- Desktop package artifact decision: pass
- Managed Python runtime decision: pass
- C6 GUI/supervisor evidence decision: pass
- PC Brain deploy audio decision: pass
- PC Brain quiet-soak decision: pass
- Physical robot evidence decision: pass
- Production voice-source decision: pass
"@ | Set-Content -Path (Join-Path $readyRoot "DESKTOP_V1_REVIEW.md") -Encoding UTF8

  $readyResult = Invoke-DesktopV1BundleCheck -EvidenceRoot $readyRoot -RequireReady
  if ([int]$readyResult.exitCode -ne 0) {
    throw "Expected complete Desktop v1 evidence bundle to pass. Output:`n$($readyResult.text)"
  }
  if ($readyResult.report.status -ne "desktop-v1-evidence-ready") {
    throw "Expected desktop-v1-evidence-ready, got $($readyResult.report.status)."
  }
  foreach ($id in @("artifact-windows", "artifact-macos", "artifact-linux", "companion-readiness", "c6-brain-supervisor", "c6-gui-rehearsal", "runtime-windows", "runtime-macos", "runtime-linux", "pc-brain-deploy", "pc-brain-quiet-soak", "voice-source-ready", "voice-source-commit-match", "desktop-v1-review")) {
    Assert-CheckStatus -Report $readyResult.report -Id $id -Status "pass"
  }
  Write-Host "[ok] complete Desktop v1 evidence bundle is accepted"

  $mismatchRoot = New-TempEvidenceRoot
  Copy-Item -Path (Join-Path $readyRoot "*") -Destination $mismatchRoot -Recurse -Force
  @"
# Desktop V1 Review

- Reviewer: Contract Test
- Review date: 2026-07-06
- Source commit: $("d" * 40)
- Overall desktop v1 decision: pass
- Desktop package artifact decision: pass
- Managed Python runtime decision: pass
- C6 GUI/supervisor evidence decision: pass
- PC Brain deploy audio decision: pass
- PC Brain quiet-soak decision: pass
- Physical robot evidence decision: pass
- Production voice-source decision: pass
"@ | Set-Content -Path (Join-Path $mismatchRoot "DESKTOP_V1_REVIEW.md") -Encoding UTF8
  $mismatchResult = Invoke-DesktopV1BundleCheck -EvidenceRoot $mismatchRoot
  if ([int]$mismatchResult.exitCode -eq 0) {
    throw "Expected mismatched Desktop v1 review source commit to fail."
  }
  Assert-CheckStatus -Report $mismatchResult.report -Id "desktop-v1-review" -Status "fail"
  Write-Host "[ok] mismatched Desktop v1 review source commit is rejected"

  $voiceMismatchRoot = New-TempEvidenceRoot
  Copy-Item -Path (Join-Path $readyRoot "*") -Destination $voiceMismatchRoot -Recurse -Force
  Write-JsonFile -Path (Join-Path $voiceMismatchRoot $reports.voiceSourceReadinessReport) -Value ([ordered]@{
      schema = "stackchan.voice-source-readiness.v1"
      status = "production-voice-source-ready"
      sourceCommit = ("d" * 40)
      passed = 1
      failed = 0
      pending = 0
      checks = @()
    })
  $voiceMismatchResult = Invoke-DesktopV1BundleCheck -EvidenceRoot $voiceMismatchRoot
  if ([int]$voiceMismatchResult.exitCode -eq 0) {
    throw "Expected mismatched Desktop v1 voice-source commit to fail."
  }
  Assert-CheckStatus -Report $voiceMismatchResult.report -Id "voice-source-commit-match" -Status "fail"
  Write-Host "[ok] mismatched Desktop v1 voice-source commit is rejected"

  Write-Host "Desktop v1 evidence bundle contract tests passed."
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
