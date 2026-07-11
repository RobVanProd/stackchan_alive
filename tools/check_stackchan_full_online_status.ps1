param(
  [string]$FlashReadinessPath = "output\pc-brain\full-online-flash-readiness-latest\FULL_ONLINE_FLASH_READINESS.json",
  [string]$ValidationPath = "output\pc-brain\full-online-validation-latest\FULL_ONLINE_VALIDATION_CHECK.json",
  [string]$SupervisedFlashPath = "output\pc-brain\full-online-supervised-flash-latest\FULL_ONLINE_SUPERVISED_FLASH.json",
  [string]$PhysicalValidationResumePath = "output\pc-brain\full-online-validation-latest\FULL_ONLINE_PHYSICAL_VALIDATION_RESUME.json",
  [string]$NextActionsPath = "output\pc-brain\full-online-validation-latest\FULL_ONLINE_NEXT_ACTIONS.md",
  [string]$BodyClearAttestationPath = "output\pc-brain\full-online-status-latest\BODY_CLEAR_ATTESTATION.json",
  [string]$DeviceHost = "192.168.1.238",
  [string]$DebugUrl = "",
  [string]$DebugJsonPath = "",
  [string]$ReportDir = "output\pc-brain\full-online-status-latest",
  [int]$MaxReportAgeMinutes = 120,
  [switch]$Json
)

$ErrorActionPreference = "Stop"

$RepoRoot = Resolve-Path (Join-Path $PSScriptRoot "..")
Set-Location $RepoRoot

if ([string]::IsNullOrWhiteSpace($DebugUrl) -and -not [string]::IsNullOrWhiteSpace($DeviceHost)) {
  $DebugUrl = "http://$DeviceHost`:8789/debug"
}

$checks = @()

function Add-Check {
  param(
    [string]$Id,
    [ValidateSet("pass", "fail", "pending")]
    [string]$Status,
    [string]$Detail
  )
  $script:checks += [ordered]@{
    id = $Id
    status = $Status
    detail = $Detail
  }
}

function Read-JsonIfPresent {
  param([string]$Path)
  if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $null }
  return Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json
}

function Get-IntValue {
  param($Object, [string]$Name, [int]$DefaultValue = 0)
  if ($null -eq $Object) { return $DefaultValue }
  $property = $Object.PSObject.Properties[$Name]
  if ($null -eq $property -or $null -eq $property.Value) { return $DefaultValue }
  return [int]$property.Value
}

function Add-FreshnessCheck {
  param(
    [string]$Id,
    [string]$GeneratedAt,
    [int]$MaxAgeMinutes
  )
  if ([string]::IsNullOrWhiteSpace($GeneratedAt)) {
    Add-Check $Id "fail" "generatedAt is missing."
    return
  }
  try {
    $generated = [datetimeoffset]::Parse($GeneratedAt)
    $ageMinutes = ([datetimeoffset]::Now - $generated).TotalMinutes
    $roundedAge = [math]::Round($ageMinutes, 1)
    $fresh = ($ageMinutes -ge -5 -and $ageMinutes -le $MaxAgeMinutes)
    Add-Check $Id ($(if ($fresh) { "pass" } else { "fail" })) "generatedAt=$GeneratedAt age_minutes=$roundedAge max_minutes=$MaxAgeMinutes"
  } catch {
    Add-Check $Id "fail" "Could not parse generatedAt=$GeneratedAt :: $($_.Exception.Message)"
  }
}

$supervisedFlash = Read-JsonIfPresent $SupervisedFlashPath
$supervisedFlashCompleteForFreshness = ($null -ne $supervisedFlash -and $supervisedFlash.status -eq "full-online-supervised-flash-complete")

$flashReadiness = Read-JsonIfPresent $FlashReadinessPath
if ($null -ne $flashReadiness) {
  Add-Check "flash-readiness-json" "pass" $FlashReadinessPath
  Add-Check "flash-readiness-schema" ($(if ($flashReadiness.schema -eq "stackchan.full-online-flash-readiness.v1") { "pass" } else { "fail" })) "schema=$($flashReadiness.schema)"
  Add-Check "flash-readiness-ready" ($(if ($flashReadiness.readyToFlash -eq $true -and (Get-IntValue $flashReadiness "failed" 1) -eq 0) { "pass" } else { "fail" })) "status=$($flashReadiness.status) readyToFlash=$($flashReadiness.readyToFlash) failed=$($flashReadiness.failed)"
  if ($supervisedFlashCompleteForFreshness) {
    Add-Check "flash-readiness-fresh" "pass" "not required after supervised flash complete; generatedAt=$($flashReadiness.generatedAt)"
  } else {
    Add-FreshnessCheck "flash-readiness-fresh" ([string]$flashReadiness.generatedAt) $MaxReportAgeMinutes
  }
} else {
  Add-Check "flash-readiness-json" "fail" "Missing $FlashReadinessPath"
}

$validation = Read-JsonIfPresent $ValidationPath
if ($null -ne $validation) {
  Add-Check "validation-json" "pass" $ValidationPath
  Add-Check "validation-schema" ($(if ($validation.schema -eq "stackchan.full-online-validation-check.v1") { "pass" } else { "fail" })) "schema=$($validation.schema)"
  Add-Check "validation-no-failures" ($(if ((Get-IntValue $validation "failed" 1) -eq 0 -and $validation.machineReady -eq $true) { "pass" } else { "fail" })) "status=$($validation.status) machineReady=$($validation.machineReady) failed=$($validation.failed)"
  Add-Check "validation-complete" ($(if ($validation.status -eq "full-online-validation-ready") { "pass" } else { "pending" })) "status=$($validation.status) pending=$($validation.pending)"
} else {
  Add-Check "validation-json" "fail" "Missing $ValidationPath"
}

if ($null -ne $supervisedFlash) {
  Add-Check "supervised-flash-json" "pass" $SupervisedFlashPath
  Add-Check "supervised-flash-schema" ($(if ($supervisedFlash.schema -eq "stackchan.full-online-supervised-flash.v1") { "pass" } else { "fail" })) "schema=$($supervisedFlash.schema)"
  Add-Check "supervised-flash-dry-run" ($(if ($supervisedFlash.status -eq "full-online-supervised-flash-dry-run-ready" -or $supervisedFlash.status -eq "full-online-supervised-flash-complete") { "pass" } else { "fail" })) "status=$($supervisedFlash.status)"
  Add-Check "supervised-flash-complete" ($(if ($supervisedFlash.status -eq "full-online-supervised-flash-complete") { "pass" } else { "pending" })) "status=$($supervisedFlash.status)"
} else {
  Add-Check "supervised-flash-json" "pending" "Run tools\flash_full_online_when_ready.cmd -DryRun or the supervised flash wrapper."
}

$physicalValidationResume = Read-JsonIfPresent $PhysicalValidationResumePath
if ($null -ne $physicalValidationResume) {
  Add-Check "physical-validation-resume-json" "pass" $PhysicalValidationResumePath
  Add-Check "physical-validation-resume-schema" ($(if ($physicalValidationResume.schema -eq "stackchan.full-online-physical-validation-resume.v1") { "pass" } else { "fail" })) "schema=$($physicalValidationResume.schema)"
  Add-Check "physical-validation-resume-clean" ($(if ((Get-IntValue $physicalValidationResume "failed" 1) -eq 0 -and ($physicalValidationResume.status -eq "full-online-physical-validation-resume-dry-run-ready" -or $physicalValidationResume.status -eq "full-online-physical-validation-resume-started" -or $physicalValidationResume.status -eq "full-online-physical-validation-resume-complete")) { "pass" } else { "fail" })) "status=$($physicalValidationResume.status) failed=$($physicalValidationResume.failed)"
} else {
  Add-Check "physical-validation-resume-json" "pending" "Optional guarded resume dry-run missing: $PhysicalValidationResumePath"
}

Add-Check "next-actions" ($(if (Test-Path -LiteralPath $NextActionsPath -PathType Leaf) { "pass" } else { "fail" })) $NextActionsPath

$bodyClearAttestation = Read-JsonIfPresent $BodyClearAttestationPath
if ($null -ne $bodyClearAttestation) {
  Add-Check "body-clear-attestation-json" "pass" $BodyClearAttestationPath
  Add-Check "body-clear-attestation-schema" ($(if ($bodyClearAttestation.schema -eq "stackchan.body-clear-attestation.v1") { "pass" } else { "fail" })) "schema=$($bodyClearAttestation.schema)"
  Add-Check "body-clear-still-requires-live-operator" ($(if ($bodyClearAttestation.stillRequiresLiveOperatorConfirmation -eq $true) { "pass" } else { "fail" })) "stillRequiresLiveOperatorConfirmation=$($bodyClearAttestation.stillRequiresLiveOperatorConfirmation)"
} else {
  Add-Check "body-clear-attestation-json" "pending" "Optional attestation missing: $BodyClearAttestationPath"
}

$debug = $null
if (-not [string]::IsNullOrWhiteSpace($DebugJsonPath)) {
  $debug = Read-JsonIfPresent $DebugJsonPath
  if ($null -eq $debug) {
    Add-Check "live-debug-json" "fail" "Missing $DebugJsonPath"
  }
} else {
  try {
    $debug = Invoke-RestMethod -Uri $DebugUrl -TimeoutSec 5
  } catch {
    Add-Check "live-debug-json" "fail" "$DebugUrl :: $($_.Exception.Message)"
  }
}
if ($null -ne $debug) {
  Add-Check "live-debug-schema" ($(if ($debug.schema -eq "stackchan.bridge-debug.v1") { "pass" } else { "fail" })) "schema=$($debug.schema)"
  Add-Check "live-debug-ready" ($(if ($debug.network_state -eq "connected" -and $debug.bridge_state -eq "ready") { "pass" } else { "fail" })) "network=$($debug.network_state) bridge=$($debug.bridge_state)"
  Add-Check "live-debug-error-clear" ($(if ([string]$debug.network_error -eq "") { "pass" } else { "fail" })) "network_error=$($debug.network_error)"
  Add-Check "live-debug-volume-150" ($(if ((Get-IntValue $debug "speaker_volume" 0) -eq 150) { "pass" } else { "fail" })) "speaker_volume=$($debug.speaker_volume)"
  Add-Check "live-debug-audio-idle" ($(if (-not [bool]$debug.audio_stream_active) { "pass" } else { "fail" })) "audio_stream_active=$($debug.audio_stream_active)"
  Add-Check "live-debug-playback-clean" ($(if ((Get-IntValue $debug "bridge_downlink_playback_errors" 0) -eq 0 -and (Get-IntValue $debug "speaker_stream_play_raw_failed" 0) -eq 0) { "pass" } else { "fail" })) "playback_errors=$($debug.bridge_downlink_playback_errors) speaker_failed=$($debug.speaker_stream_play_raw_failed)"
}

$failed = @($checks | Where-Object { $_.status -eq "fail" })
$pending = @($checks | Where-Object { $_.status -eq "pending" })
$physicalValidated = ($null -ne $validation -and $validation.status -eq "full-online-validation-ready")
$supervisedFlashComplete = ($null -ne $supervisedFlash -and $supervisedFlash.status -eq "full-online-supervised-flash-complete")
$readyForSupervisedFlash = ($null -ne $flashReadiness -and $flashReadiness.readyToFlash -eq $true -and (Get-IntValue $flashReadiness "failed" 1) -eq 0 -and $failed.Count -eq 0 -and -not $supervisedFlashComplete)

$status = if ($failed.Count -gt 0) {
  "stackchan-full-online-not-ready"
} elseif ($physicalValidated) {
  "stackchan-full-online-validated"
} elseif ($supervisedFlashComplete) {
  "stackchan-full-online-pending-validation"
} elseif ($readyForSupervisedFlash) {
  "stackchan-full-online-ready-for-supervised-flash"
} else {
  "stackchan-full-online-pending"
}

$guardedFlashCommand = ".\tools\flash_full_online_when_ready.cmd -ReadinessJsonPath output\pc-brain\full-online-flash-readiness-latest\FULL_ONLINE_FLASH_READINESS.json -OperatorPresent -BodyClear -ConfirmServoRisk"
$physicalSessionReadinessCommand = ".\tools\check_full_online_physical_session_readiness.cmd -DeviceHost $DeviceHost -Port COM4 -Json"
$physicalValidationResumeCommand = ".\tools\resume_full_online_physical_validation_when_ready.cmd -DeviceHost $DeviceHost -Port COM4 -OperatorPresent -BodyClear -ConfirmServoRisk"
$guidedPhysicalSessionCommand = ".\tools\start_full_online_physical_validation_session.cmd -EvidenceRoot output\pc-brain\full-online-validation-latest -DeviceHost $DeviceHost -Port COM4 -OperatorPresent -BodyClear -ConfirmServoRisk -LoggerDebugOnly -SuggestedVoicePrompt `"hello stackchan`""
$emergencyMotionStopCommand = '.\tools\send_stackchan_serial_command.cmd -EvidenceRoot output\pc-brain\full-online-validation-latest -Port COM4 -Command "motion stop" -OperatorPresent -Json'
$nextAction = if ($physicalValidated) {
  "preserve-full-online-validation-evidence"
} elseif ($supervisedFlashComplete) {
  "continue-full-online-validation"
} elseif ($readyForSupervisedFlash) {
  "run-supervised-full-online-flash"
} elseif ($failed.Count -gt 0) {
  "resolve-failed-checks"
} else {
  "continue-full-online-validation"
}
$nextCommand = if ($physicalValidated) {
  $null
} elseif ($supervisedFlashComplete) {
  $physicalValidationResumeCommand
} elseif ($readyForSupervisedFlash) {
  $guardedFlashCommand
} elseif ($failed.Count -gt 0) {
  ".\tools\check_stackchan_full_online_status.cmd -Json"
} else {
  ".\tools\collect_full_online_validation_evidence.cmd -EvidenceRoot output\pc-brain\full-online-validation-latest -DeviceHost $DeviceHost -Check -Json"
}
$nextReason = if ($physicalValidated) {
  "Full-online validation is complete."
} elseif ($supervisedFlashComplete) {
  "Full-online firmware is flashed and machine gates are online; physical voice-in/servo review evidence is still pending."
} elseif ($readyForSupervisedFlash) {
  "Readiness is green; physical upload still requires Rob present, body clear, and servo-risk confirmation."
} elseif ($failed.Count -gt 0) {
  "One or more readiness checks failed."
} else {
  "Validation evidence is still pending."
}

$result = [ordered]@{
  schema = "stackchan.full-online-status.v1"
  status = $status
  readyForSupervisedFlash = $readyForSupervisedFlash
  physicalValidated = $physicalValidated
  supervisedFlashComplete = $supervisedFlashComplete
  nextAction = $nextAction
  nextCommand = $nextCommand
  nextReason = $nextReason
  generatedAt = (Get-Date).ToString("o")
  maxReportAgeMinutes = $MaxReportAgeMinutes
  flashReadinessStatus = $(if ($null -ne $flashReadiness) { $flashReadiness.status } else { $null })
  validationStatus = $(if ($null -ne $validation) { $validation.status } else { $null })
  supervisedFlashStatus = $(if ($null -ne $supervisedFlash) { $supervisedFlash.status } else { $null })
  physicalValidationResumeStatus = $(if ($null -ne $physicalValidationResume) { $physicalValidationResume.status } else { $null })
  physicalValidationResumeDryRun = $(if ($null -ne $physicalValidationResume) { $physicalValidationResume.dryRun } else { $null })
  debugUrl = $DebugUrl
  nextActionsPath = $NextActionsPath
  physicalSessionReadinessCommand = $physicalSessionReadinessCommand
  physicalValidationResumeCommand = $physicalValidationResumeCommand
  guidedPhysicalSessionCommand = $guidedPhysicalSessionCommand
  emergencyMotionStopCommand = $emergencyMotionStopCommand
  bodyClearAttestationPath = $BodyClearAttestationPath
  bodyClearAttested = ($null -ne $bodyClearAttestation)
  passed = @($checks | Where-Object { $_.status -eq "pass" }).Count
  failed = $failed.Count
  pending = $pending.Count
  checks = $checks
}

New-Item -ItemType Directory -Force -Path $ReportDir | Out-Null
$resolvedReportDir = (Resolve-Path $ReportDir).Path
$jsonPath = Join-Path $resolvedReportDir "STACKCHAN_FULL_ONLINE_STATUS.json"
$markdownPath = Join-Path $resolvedReportDir "STACKCHAN_FULL_ONLINE_STATUS.md"
$operatorBriefPath = Join-Path $resolvedReportDir "STACKCHAN_FULL_ONLINE_OPERATOR_BRIEF.md"
$result | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $jsonPath -Encoding UTF8

$lines = @(
  "# Stackchan Full-Online Status",
  "",
  "- Schema: ``$($result.schema)``",
  "- Status: ``$($result.status)``",
  "- Ready for supervised flash: ``$($result.readyForSupervisedFlash)``",
  "- Supervised flash complete: ``$($result.supervisedFlashComplete)``",
  "- Physical validation complete: ``$($result.physicalValidated)``",
  "- Next action: ``$($result.nextAction)``",
  "- Next command: ``$($result.nextCommand)``",
  "- Body clear attested: ``$($result.bodyClearAttested)``",
  "- Max report age minutes: ``$($result.maxReportAgeMinutes)``",
  "- Passed: ``$($result.passed)``",
  "- Failed: ``$($result.failed)``",
  "- Pending: ``$($result.pending)``",
  "",
  "## Checks",
  ""
)
foreach ($check in $checks) {
  $lines += "- ``$($check.status)`` ``$($check.id)``: $($check.detail)"
}
$lines += ""
$lines += "## Next"
$lines += ""
if ($result.physicalValidated) {
  $lines += "- $($result.nextReason)"
} elseif ($result.readyForSupervisedFlash) {
  $lines += "- $($result.nextReason)"
  $lines += ""
  $lines += '```powershell'
  $lines += $result.nextCommand
  $lines += '```'
} elseif ($result.supervisedFlashComplete) {
  $lines += "- $($result.nextReason)"
  $lines += ""
  $lines += '```powershell'
  $lines += $result.nextCommand
  $lines += '```'
  $lines += ""
  $lines += "- Emergency stop from PowerShell with DTR/RTS disabled:"
  $lines += ""
  $lines += '```powershell'
  $lines += $result.emergencyMotionStopCommand
  $lines += '```'
} else {
  $lines += "- $($result.nextReason)"
  if (-not [string]::IsNullOrWhiteSpace($result.nextCommand)) {
    $lines += ""
    $lines += '```powershell'
    $lines += $result.nextCommand
    $lines += '```'
  }
}
$lines | Set-Content -LiteralPath $markdownPath -Encoding UTF8

$brief = @(
  "# Stackchan Full-Online Operator Brief",
  "",
  "- Status: ``$($result.status)``",
  "- Ready for supervised flash: ``$($result.readyForSupervisedFlash)``",
  "- Supervised flash complete: ``$($result.supervisedFlashComplete)``",
  "- Physical validation complete: ``$($result.physicalValidated)``",
  "- Next action: ``$($result.nextAction)``",
  "- Next reason: $($result.nextReason)",
  "- Guarded resume dry-run status: ``$($result.physicalValidationResumeStatus)``",
  "- Body clear attested: ``$($result.bodyClearAttested)``",
  "- Max report age minutes: ``$($result.maxReportAgeMinutes)``",
  "- Live robot: ``$($debug.network_state)`` / ``$($debug.bridge_state)``",
  "- Speaker volume: ``$($debug.speaker_volume)``",
  "",
  "## Do Not",
  "",
  "- Do not call the goal complete until physical validation reports ``full-online-validation-ready``.",
  "- Do not flash unless Rob is present, the body is clear, and servo risk is explicitly accepted.",
  "- Do not trigger voice or servo motion until the physical session is ready.",
  "",
  "## Next Command",
  ""
)
if ($result.physicalValidated) {
  $brief += "- Full-online validation is complete. Preserve the evidence folder."
} elseif ($result.readyForSupervisedFlash) {
  $brief += '```powershell'
  $brief += $result.nextCommand
  $brief += '```'
  $brief += ""
  $brief += "- After flashing, follow ``$NextActionsPath``."
} elseif ($result.supervisedFlashComplete) {
  $brief += "- Preferred guarded resume command. It runs the physical-session readiness check first, then starts the guided session only when Rob is present, the body is clear, and servo risk is explicitly accepted."
  $brief += ""
  $brief += '```powershell'
  $brief += $result.physicalValidationResumeCommand
  $brief += '```'
  $brief += ""
  $brief += "- Component readiness check. It does not trigger voice or servo motion."
  $brief += ""
  $brief += '```powershell'
  $brief += $result.physicalSessionReadinessCommand
  $brief += '```'
  $brief += ""
  $brief += "- Use the guided physical validation session. It uses debug-only logging so USB serial stays available for a serial monitor or emergency stop."
  $brief += ""
  $brief += '```powershell'
  $brief += $result.guidedPhysicalSessionCommand
  $brief += '```'
  $brief += ""
  $brief += "- Emergency stop from PowerShell with DTR/RTS disabled:"
  $brief += ""
  $brief += '```powershell'
  $brief += $result.emergencyMotionStopCommand
  $brief += '```'
  $brief += ""
  $brief += "- Full checklist: ``$NextActionsPath``."
} else {
  $brief += "- Rerun ``.\tools\check_stackchan_full_online_status.cmd -Json`` after fixing failed checks."
}
$brief | Set-Content -LiteralPath $operatorBriefPath -Encoding UTF8

if ($Json) {
  $result | ConvertTo-Json -Depth 8
} else {
  Write-Host "Stackchan full-online status: $status"
  Write-Host "Report: $markdownPath"
}

if ($failed.Count -gt 0) {
  exit 1
}
