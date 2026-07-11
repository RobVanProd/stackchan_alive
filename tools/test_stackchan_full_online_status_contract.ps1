$ErrorActionPreference = "Stop"

$RepoRoot = Resolve-Path (Join-Path $PSScriptRoot "..")
Set-Location $RepoRoot

function Write-Json {
  param([string]$Path, $Object)
  $Object | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $Path -Encoding UTF8
}

$tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("stackchan-full-online-status-" + [guid]::NewGuid().ToString("N"))
$flashPath = Join-Path $tempRoot "FULL_ONLINE_FLASH_READINESS.json"
$validationPath = Join-Path $tempRoot "FULL_ONLINE_VALIDATION_CHECK.json"
$supervisedPath = Join-Path $tempRoot "FULL_ONLINE_SUPERVISED_FLASH.json"
$resumePath = Join-Path $tempRoot "FULL_ONLINE_PHYSICAL_VALIDATION_RESUME.json"
$nextActionsPath = Join-Path $tempRoot "FULL_ONLINE_NEXT_ACTIONS.md"
$bodyClearPath = Join-Path $tempRoot "BODY_CLEAR_ATTESTATION.json"
$debugPath = Join-Path $tempRoot "debug.json"
$reportRoot = Join-Path $tempRoot "status"

try {
  New-Item -ItemType Directory -Force -Path $tempRoot | Out-Null
  Write-Json $flashPath ([ordered]@{
      schema = "stackchan.full-online-flash-readiness.v1"
      status = "full-online-flash-ready"
      readyToFlash = $true
      generatedAt = ([datetimeoffset]::Now.ToString("o"))
      failed = 0
      pending = 1
    })
  Write-Json $validationPath ([ordered]@{
      schema = "stackchan.full-online-validation-check.v1"
      status = "full-online-validation-pending-evidence"
      machineReady = $true
      failed = 0
      pending = 16
    })
  Write-Json $supervisedPath ([ordered]@{
      schema = "stackchan.full-online-supervised-flash.v1"
      status = "full-online-supervised-flash-dry-run-ready"
      dryRun = $true
      failed = 0
      pending = 1
    })
  Write-Json $resumePath ([ordered]@{
      schema = "stackchan.full-online-physical-validation-resume.v1"
      status = "full-online-physical-validation-resume-dry-run-ready"
      dryRun = $true
      failed = 0
      pending = 1
    })
  "# next actions" | Set-Content -LiteralPath $nextActionsPath -Encoding UTF8
  Write-Json $bodyClearPath ([ordered]@{
      schema = "stackchan.body-clear-attestation.v1"
      generatedAt = ([datetimeoffset]::Now.ToString("o"))
      operator = "Rob"
      note = "Body clear confirmed before leaving."
      stillRequiresLiveOperatorConfirmation = $true
    })
  Write-Json $debugPath ([ordered]@{
      schema = "stackchan.bridge-debug.v1"
      network_state = "connected"
      bridge_state = "ready"
      network_error = ""
      speaker_volume = 150
      audio_stream_active = $false
      bridge_downlink_playback_errors = 0
      speaker_stream_play_raw_failed = 0
    })

  $pendingOutput = & "tools\check_stackchan_full_online_status.ps1" `
    -FlashReadinessPath $flashPath `
    -ValidationPath $validationPath `
    -SupervisedFlashPath $supervisedPath `
    -PhysicalValidationResumePath $resumePath `
    -NextActionsPath $nextActionsPath `
    -BodyClearAttestationPath $bodyClearPath `
    -DebugJsonPath $debugPath `
    -ReportDir $reportRoot `
    -Json
  if (-not $?) {
    throw "Expected pending status check to exit 0: $pendingOutput"
  }
  $pending = $pendingOutput | ConvertFrom-Json
  if ($pending.status -ne "stackchan-full-online-ready-for-supervised-flash") {
    throw "Expected ready-for-supervised-flash, got $($pending.status)."
  }
  if ($pending.readyForSupervisedFlash -ne $true -or $pending.physicalValidated -ne $false) {
    throw "Expected readyForSupervisedFlash=true and physicalValidated=false."
  }
  if ($pending.nextAction -ne "run-supervised-full-online-flash" -or $pending.nextCommand -notmatch "flash_full_online_when_ready.cmd") {
    throw "Expected supervised flash next action, got action=$($pending.nextAction) command=$($pending.nextCommand)."
  }
  if ($pending.bodyClearAttested -ne $true) {
    throw "Expected bodyClearAttested=true."
  }
  $pendingBriefPath = Join-Path $reportRoot "STACKCHAN_FULL_ONLINE_OPERATOR_BRIEF.md"
  if (-not (Test-Path -LiteralPath $pendingBriefPath -PathType Leaf)) {
    throw "Expected operator brief for pending state."
  }
  $pendingBrief = Get-Content -LiteralPath $pendingBriefPath -Raw
  foreach ($snippet in @("Ready for supervised flash", "Physical validation complete", "Next action", "Body clear attested", "Max report age minutes", "Do not flash unless Rob is present", "flash_full_online_when_ready.cmd")) {
    if ($pendingBrief -notmatch [regex]::Escape($snippet)) {
      throw "Expected operator brief to mention $snippet."
    }
  }

  Write-Json $flashPath ([ordered]@{
      schema = "stackchan.full-online-flash-readiness.v1"
      status = "full-online-flash-ready"
      readyToFlash = $true
      generatedAt = ([datetimeoffset]::Now.AddHours(-3).ToString("o"))
      failed = 0
      pending = 1
    })
  $staleOutput = & "tools\check_stackchan_full_online_status.ps1" `
    -FlashReadinessPath $flashPath `
    -ValidationPath $validationPath `
    -SupervisedFlashPath $supervisedPath `
    -PhysicalValidationResumePath $resumePath `
    -NextActionsPath $nextActionsPath `
    -BodyClearAttestationPath $bodyClearPath `
    -DebugJsonPath $debugPath `
    -ReportDir $reportRoot `
    -MaxReportAgeMinutes 60 `
    -Json
  if ($?) {
    throw "Expected stale flash readiness to fail."
  }
  $stale = $staleOutput | ConvertFrom-Json
  if ($stale.status -ne "stackchan-full-online-not-ready") {
    throw "Expected stale report to be not-ready, got $($stale.status)."
  }
  if ($stale.nextAction -ne "resolve-failed-checks") {
    throw "Expected stale report to request failed-check resolution, got $($stale.nextAction)."
  }
  Write-Json $supervisedPath ([ordered]@{
      schema = "stackchan.full-online-supervised-flash.v1"
      status = "full-online-supervised-flash-complete"
      dryRun = $false
      failed = 0
      pending = 0
    })
  $pendingValidationOutput = & "tools\check_stackchan_full_online_status.ps1" `
    -FlashReadinessPath $flashPath `
    -ValidationPath $validationPath `
    -SupervisedFlashPath $supervisedPath `
    -PhysicalValidationResumePath $resumePath `
    -NextActionsPath $nextActionsPath `
    -BodyClearAttestationPath $bodyClearPath `
    -DebugJsonPath $debugPath `
    -ReportDir $reportRoot `
    -Json
  if (-not $?) {
    throw "Expected pending-validation status check to exit 0: $pendingValidationOutput"
  }
  $pendingValidation = $pendingValidationOutput | ConvertFrom-Json
  if ($pendingValidation.status -ne "stackchan-full-online-pending-validation" -or $pendingValidation.nextAction -ne "continue-full-online-validation") {
    throw "Expected pending-validation continuation, got status=$($pendingValidation.status) action=$($pendingValidation.nextAction)."
  }
  $postFlashFreshness = @($pendingValidation.checks | Where-Object { $_.id -eq "flash-readiness-fresh" })[0]
  if ($null -eq $postFlashFreshness -or $postFlashFreshness.status -ne "pass" -or $postFlashFreshness.detail -notmatch "not required after supervised flash complete") {
    throw "Expected stale pre-flash readiness to be ignored after supervised flash completion."
  }
  if ($pendingValidation.nextCommand -notmatch "resume_full_online_physical_validation_when_ready.cmd") {
    throw "Expected pending-validation next command to use guarded resume, got $($pendingValidation.nextCommand)."
  }
  if ($pendingValidation.guidedPhysicalSessionCommand -notmatch "LoggerDebugOnly") {
    throw "Expected guided physical session command with LoggerDebugOnly."
  }
  foreach ($snippet in @("-SuggestedVoicePrompt", "hello stackchan")) {
    if ($pendingValidation.guidedPhysicalSessionCommand -notmatch [regex]::Escape($snippet)) {
      throw "Expected guided physical session command to include $snippet."
    }
  }
  if ($pendingValidation.emergencyMotionStopCommand -notmatch "send_stackchan_serial_command.cmd") {
    throw "Expected emergency motion stop command."
  }
  if ($pendingValidation.physicalSessionReadinessCommand -notmatch "check_full_online_physical_session_readiness.cmd") {
    throw "Expected physical-session readiness command."
  }
  if ($pendingValidation.physicalValidationResumeCommand -notmatch "resume_full_online_physical_validation_when_ready.cmd") {
    throw "Expected physical-validation resume command."
  }
  if ($pendingValidation.physicalValidationResumeStatus -ne "full-online-physical-validation-resume-dry-run-ready" -or $pendingValidation.physicalValidationResumeDryRun -ne $true) {
    throw "Expected physical-validation resume dry-run status in aggregate status."
  }
  if ($pendingValidation.readyForSupervisedFlash -ne $false -or $pendingValidation.supervisedFlashComplete -ne $true) {
    throw "Expected readyForSupervisedFlash=false and supervisedFlashComplete=true after completed flash."
  }
  $pendingValidationBrief = Get-Content -LiteralPath (Join-Path $reportRoot "STACKCHAN_FULL_ONLINE_OPERATOR_BRIEF.md") -Raw
  foreach ($snippet in @("Guarded resume dry-run status", "Preferred guarded resume command", "resume_full_online_physical_validation_when_ready.cmd", "physical-session readiness check", "check_full_online_physical_session_readiness.cmd", "guided physical validation session", "start_full_online_physical_validation_session.cmd", "hello stackchan", "send_stackchan_serial_command.cmd", "DTR/RTS disabled")) {
    if ($pendingValidationBrief -notmatch [regex]::Escape($snippet)) {
      throw "Expected pending-validation operator brief to mention $snippet."
    }
  }

  Write-Json $validationPath ([ordered]@{
      schema = "stackchan.full-online-validation-check.v1"
      status = "full-online-validation-ready"
      machineReady = $true
      failed = 0
      pending = 0
    })
  Write-Json $supervisedPath ([ordered]@{
      schema = "stackchan.full-online-supervised-flash.v1"
      status = "full-online-supervised-flash-complete"
      dryRun = $false
      failed = 0
      pending = 0
    })
  $readyOutput = & "tools\check_stackchan_full_online_status.ps1" `
    -FlashReadinessPath $flashPath `
    -ValidationPath $validationPath `
    -SupervisedFlashPath $supervisedPath `
    -PhysicalValidationResumePath $resumePath `
    -NextActionsPath $nextActionsPath `
    -BodyClearAttestationPath $bodyClearPath `
    -DebugJsonPath $debugPath `
    -ReportDir $reportRoot `
    -Json
  if (-not $?) {
    throw "Expected validated status check to exit 0: $readyOutput"
  }
  $ready = $readyOutput | ConvertFrom-Json
  if ($ready.status -ne "stackchan-full-online-validated" -or $ready.physicalValidated -ne $true) {
    throw "Expected validated status, got status=$($ready.status) physicalValidated=$($ready.physicalValidated)."
  }
  if ($ready.nextAction -ne "preserve-full-online-validation-evidence" -or $null -ne $ready.nextCommand) {
    throw "Expected validated next action to preserve evidence with no command, got action=$($ready.nextAction) command=$($ready.nextCommand)."
  }
  foreach ($file in @("STACKCHAN_FULL_ONLINE_STATUS.json", "STACKCHAN_FULL_ONLINE_STATUS.md", "STACKCHAN_FULL_ONLINE_OPERATOR_BRIEF.md")) {
    if (-not (Test-Path -LiteralPath (Join-Path $reportRoot $file) -PathType Leaf)) {
      throw "Expected status report $file."
    }
  }
  $readyBrief = Get-Content -LiteralPath (Join-Path $reportRoot "STACKCHAN_FULL_ONLINE_OPERATOR_BRIEF.md") -Raw
  if ($readyBrief -notmatch "Full-online validation is complete") {
    throw "Expected ready operator brief to mention completion."
  }
} finally {
  Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Host "Stackchan full-online status contract tests passed."
