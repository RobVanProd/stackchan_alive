$ErrorActionPreference = "Stop"

$RepoRoot = Resolve-Path (Join-Path $PSScriptRoot "..")
Set-Location $RepoRoot

function New-TextFile {
  param([string]$Path, [string]$Text = "ok")
  New-Item -ItemType Directory -Force -Path (Split-Path $Path -Parent) | Out-Null
  Set-Content -LiteralPath $Path -Value $Text -Encoding UTF8
}

function New-ArchiveFromStage {
  param([string]$Stage, [string]$ZipPath)
  if (Test-Path -LiteralPath $ZipPath) {
    Remove-Item -LiteralPath $ZipPath -Force
  }
  Compress-Archive -Path (Join-Path $Stage "*") -DestinationPath $ZipPath -CompressionLevel Optimal
}

$tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("stackchan-current-lead-repro-" + [guid]::NewGuid().ToString("N"))
$warmStage = Join-Path $tempRoot "warm-stage"
$candidateStage = Join-Path $tempRoot "candidate-stage"
$warmZip = Join-Path $tempRoot "stackchan-full-online-warm-rocm-lead-20260708-101400.zip"
$candidateZip = Join-Path $tempRoot "stackchan-motion-timing-fix-candidate-20260708-101400.zip"
$reportDir = Join-Path $tempRoot "report"
$watchPath = Join-Path $tempRoot "progress.json"
$soakPath = Join-Path $tempRoot "summary.json"

try {
  $warmEntries = @(
    "bridge/lan_service.py",
    "bridge/lan_smoke.py",
    "bridge/rvc_tts_client.py",
    "bridge/rvc_worker_service.py",
    "bridge/test_lan_service.py",
    "bridge/test_lan_smoke.py",
    "docs/BRIDGE_PROTOCOL.md",
    "docs/FIRST_DEPLOY_STATUS.md",
    "docs/ARRIVAL_DAY_RUNBOOK.md",
    "firmware/firmware.bin",
    "tools/start_rvc_worker.ps1",
    "tools/start_warm_rocm_full_system_soak.ps1",
    "tools/start_motion_timing_candidate_recovery_soak.ps1",
    "tools/finalize_interrupted_full_system_soak.ps1",
    "tools/finalize_interrupted_full_system_soak.cmd",
    "tools/check_full_system_soak_evidence.ps1",
    "tools/test_motion_timing_candidate_recovery_soak_contract.ps1",
    "logs/test-motion-timing-candidate-recovery-soak-contract.log",
    "CURRENT_LEAD.md",
    "CURRENT_LEAD_MANIFEST.json"
  )
  foreach ($entry in $warmEntries) {
    New-TextFile -Path (Join-Path $warmStage $entry)
  }

  $candidateEntries = @(
    "docs/FIRST_DEPLOY_STATUS.md",
    "docs/ARRIVAL_DAY_RUNBOOK.md",
    "firmware/firmware.bin",
    "src/motion/ActuationEngine.cpp",
    "src/motion/ActuationEngine.hpp",
    "src/main.cpp",
    "tools/start_warm_rocm_full_system_soak.ps1",
    "tools/start_motion_timing_candidate_recovery_soak.ps1",
    "tools/finalize_interrupted_full_system_soak.ps1",
    "tools/finalize_interrupted_full_system_soak.cmd",
    "tools/test_motion_timing_candidate_recovery_soak_contract.ps1",
    "logs/test-motion-timing-candidate-recovery-soak-contract.log",
    "CANDIDATE_STATUS.md",
    "CANDIDATE_MANIFEST.json"
  )
  foreach ($entry in $candidateEntries) {
    New-TextFile -Path (Join-Path $candidateStage $entry)
  }

  New-ArchiveFromStage -Stage $warmStage -ZipPath $warmZip
  New-ArchiveFromStage -Stage $candidateStage -ZipPath $candidateZip

  New-TextFile -Path $watchPath -Text (@{
      schema = "stackchan.full-system-soak-progress.v1"
      records = 3
      failedPolls = 3
      motionRefreshes = 0
    } | ConvertTo-Json -Depth 4)
  New-TextFile -Path $soakPath -Text (@{
      schema = "stackchan.full-system-soak-summary.v1"
      status = "pass"
      durationSeconds = 28800
      issues = @()
    } | ConvertTo-Json -Depth 4)

  $okOutput = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File "tools\check_current_lead_reproducibility.ps1" `
    -WarmArchivePath $warmZip `
    -CandidateArchivePath $candidateZip `
    -ReportDir $reportDir `
    -PassiveWatchProgressPath $watchPath `
    -SoakSummaryPath $soakPath `
    -SkipLive `
    -Json
  if ($LASTEXITCODE -ne 0) {
    throw "Expected reproducibility checker to pass artifact contract: $okOutput"
  }
  $ok = $okOutput | ConvertFrom-Json
  if ($ok.status -ne "current-lead-reproducible-pending-soak") {
    throw "Expected pending-soak with -SkipLive, got $($ok.status)."
  }
  foreach ($id in @("warm-entries", "candidate-entries", "passive-watch-no-motion", "strict-soak-summary")) {
    $check = @($ok.checks | Where-Object { $_.id -eq $id })[0]
    if ($null -eq $check -or $check.status -ne "pass") {
      throw "Expected $id to pass."
    }
  }

  $badWarmStage = Join-Path $tempRoot "bad-warm-stage"
  Copy-Item -LiteralPath $warmStage -Destination $badWarmStage -Recurse
  Remove-Item -LiteralPath (Join-Path $badWarmStage "tools\start_motion_timing_candidate_recovery_soak.ps1") -Force
  $badWarmZip = Join-Path $tempRoot "bad-warm.zip"
  New-ArchiveFromStage -Stage $badWarmStage -ZipPath $badWarmZip

  $badOutput = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File "tools\check_current_lead_reproducibility.ps1" `
    -WarmArchivePath $badWarmZip `
    -CandidateArchivePath $candidateZip `
    -ReportDir (Join-Path $tempRoot "bad-report") `
    -PassiveWatchProgressPath $watchPath `
    -SoakSummaryPath $soakPath `
    -SkipLive `
    -Json
  if ($LASTEXITCODE -eq 0) {
    throw "Expected missing warm archive entry to fail."
  }
  $bad = $badOutput | ConvertFrom-Json
  $badCheck = @($bad.checks | Where-Object { $_.id -eq "warm-entries" })[0]
  if ($null -eq $badCheck -or $badCheck.status -ne "fail") {
    throw "Expected warm-entries to fail for missing recovery wrapper."
  }
} finally {
  Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Host "Current lead reproducibility contract tests passed."
