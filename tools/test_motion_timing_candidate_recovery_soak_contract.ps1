$ErrorActionPreference = "Stop"

$RepoRoot = Resolve-Path (Join-Path $PSScriptRoot "..")
Set-Location $RepoRoot

function Convert-OutputJson {
  param($Output)
  return ($Output | ConvertFrom-Json)
}

$tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("stackchan-motion-recovery-soak-" + [guid]::NewGuid().ToString("N"))
$fakeFirmware = Join-Path $tempRoot "firmware.bin"

try {
  New-Item -ItemType Directory -Force -Path $tempRoot | Out-Null
  Set-Content -LiteralPath $fakeFirmware -Value "fake firmware for contract test" -Encoding ASCII

  $refusalOutput = & "tools\start_motion_timing_candidate_recovery_soak.ps1" `
    -EvidenceRoot (Join-Path $tempRoot "refusal") `
    -CandidateFirmwarePath $fakeFirmware `
    -DryRun `
    -Json
  if ($?) {
    throw "Expected missing safety confirmations to fail."
  }
  $refusal = Convert-OutputJson $refusalOutput
  if ($refusal.status -ne "motion-timing-candidate-recovery-not-run") {
    throw "Expected not-run refusal, got $($refusal.status)."
  }
  foreach ($id in @("operator-present", "body-clear", "servo-risk-confirmed")) {
    $step = @($refusal.steps | Where-Object { $_.id -eq $id })[0]
    if ($null -eq $step -or $step.status -ne "fail") {
      throw "Expected $id to fail without explicit confirmation."
    }
  }

  $dryRunOutput = & "tools\start_motion_timing_candidate_recovery_soak.ps1" `
    -EvidenceRoot (Join-Path $tempRoot "dry-run") `
    -CandidateFirmwarePath $fakeFirmware `
    -OperatorPresent `
    -BodyClear `
    -ConfirmServoRisk `
    -DryRun `
    -Json
  if (-not $?) {
    throw "Expected dry-run to pass: $dryRunOutput"
  }
  $dryRun = Convert-OutputJson $dryRunOutput
  if ($dryRun.status -ne "motion-timing-candidate-recovery-dry-run-ready") {
    throw "Expected dry-run-ready, got $($dryRun.status)."
  }
  foreach ($id in @("operator-present", "body-clear", "servo-risk-confirmed", "candidate-firmware")) {
    $step = @($dryRun.steps | Where-Object { $_.id -eq $id })[0]
    if ($null -eq $step -or $step.status -ne "pass") {
      throw "Expected $id to pass in dry-run."
    }
  }
  foreach ($id in @("robot-debug", "motion-telemetry", "strict-soak-launch")) {
    $step = @($dryRun.steps | Where-Object { $_.id -eq $id })[0]
    if ($null -eq $step -or $step.status -ne "pending") {
      throw "Expected $id to be pending in dry-run."
    }
  }

  $flashDryRunOutput = & "tools\start_motion_timing_candidate_recovery_soak.ps1" `
    -EvidenceRoot (Join-Path $tempRoot "flash-dry-run") `
    -CandidateFirmwarePath $fakeFirmware `
    -OperatorPresent `
    -BodyClear `
    -ConfirmServoRisk `
    -FlashCandidate `
    -DryRun `
    -Json
  if (-not $?) {
    throw "Expected flash dry-run to pass: $flashDryRunOutput"
  }
  $flashDryRun = Convert-OutputJson $flashDryRunOutput
  $flashStep = @($flashDryRun.steps | Where-Object { $_.id -eq "flash-candidate" })[0]
  if ($null -eq $flashStep -or $flashStep.status -ne "pass") {
    throw "Expected flash-candidate to pass in dry-run."
  }
  $flashLog = Get-Content -LiteralPath $flashDryRun.flashLogPath -Raw
  if ($flashLog -notmatch "Dry run: platformio run -e stackchan_wake_mww_uplink_servos_m5_voiceout --target upload") {
    throw "Expected flash log to contain the guarded candidate upload command."
  }

  $previousErrorActionPreference = $ErrorActionPreference
  $ErrorActionPreference = "Continue"
  $servoRefusalOutput = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File "tools\flash_device.ps1" `
    -Environment stackchan_wake_mww_uplink_servos_m5_voiceout `
    -DryRun 2>&1
  $servoRefusalExitCode = $LASTEXITCODE
  $ErrorActionPreference = $previousErrorActionPreference
  if ($servoRefusalExitCode -eq 0) {
    throw "Expected flash_device to reject servo firmware without -ConfirmServoRisk."
  }
  if (($servoRefusalOutput | Out-String) -notmatch "Refusing to flash stackchan_wake_mww_uplink_servos_m5_voiceout firmware without -ConfirmServoRisk") {
    throw "Expected flash_device refusal to mention ConfirmServoRisk."
  }

  $previousErrorActionPreference = $ErrorActionPreference
  $ErrorActionPreference = "Continue"
  $soakRefusalOutput = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File "tools\start_warm_rocm_full_system_soak.ps1" `
    -EvidenceRoot (Join-Path $tempRoot "warm-refusal") `
    -SkipWorkerRestart `
    -SkipBridgeRestart `
    -NoSerial 2>&1
  $soakRefusalExitCode = $LASTEXITCODE
  $ErrorActionPreference = $previousErrorActionPreference
  if ($soakRefusalExitCode -eq 0) {
    throw "Expected warm ROCm soak launcher to reject missing safety confirmations."
  }
  if (($soakRefusalOutput | Out-String) -notmatch "Refusing to start servo-enabled warm ROCm soak without -OperatorPresent -BodyClear -ConfirmServoRisk") {
    throw "Expected warm ROCm soak refusal to mention all safety confirmations."
  }
} finally {
  Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Host "Motion timing candidate recovery soak contract tests passed."
