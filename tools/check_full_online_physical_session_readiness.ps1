param(
  [string]$ValidationPath = "output\pc-brain\full-online-validation-latest\FULL_ONLINE_VALIDATION_CHECK.json",
  [string]$StatusPath = "output\pc-brain\full-online-status-latest\STACKCHAN_FULL_ONLINE_STATUS.json",
  [string]$SupervisedFlashPath = "output\pc-brain\full-online-supervised-flash-latest\FULL_ONLINE_SUPERVISED_FLASH.json",
  [string]$NextActionsPath = "output\pc-brain\full-online-validation-latest\FULL_ONLINE_NEXT_ACTIONS.md",
  [string]$BodyClearAttestationPath = "output\pc-brain\full-online-status-latest\BODY_CLEAR_ATTESTATION.json",
  [string]$DeviceHost = "192.168.1.238",
  [string]$DebugUrl = "",
  [string]$DebugJsonPath = "",
  [string]$Port = "COM4",
  [string[]]$PortNames = @(),
  [string]$ReportDir = "output\pc-brain\full-online-physical-session-readiness-latest",
  [int]$MaxStatusAgeMinutes = 120,
  [int]$SerialReadBackMs = 250,
  [switch]$CheckSerialOpen,
  [switch]$OperatorPresent,
  [switch]$DtrEnable,
  [switch]$RtsEnable,
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

function Get-BoolLike {
  param($Object, [string]$Name, [bool]$DefaultValue = $false)
  if ($null -eq $Object) { return $DefaultValue }
  $property = $Object.PSObject.Properties[$Name]
  if ($null -eq $property -or $null -eq $property.Value) { return $DefaultValue }
  $value = $property.Value
  if ($value -is [bool]) { return $value }
  if ($value -is [int]) { return ($value -ne 0) }
  $text = ([string]$value).Trim().ToLowerInvariant()
  return ($text -eq "true" -or $text -eq "1" -or $text -eq "yes")
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

$validation = Read-JsonIfPresent $ValidationPath
if ($null -ne $validation) {
  Add-Check "validation-json" "pass" $ValidationPath
  Add-Check "validation-schema" ($(if ($validation.schema -eq "stackchan.full-online-validation-check.v1") { "pass" } else { "fail" })) "schema=$($validation.schema)"
  Add-Check "validation-machine-ready" ($(if ($validation.machineReady -eq $true -and (Get-IntValue $validation "failed" 1) -eq 0) { "pass" } else { "fail" })) "status=$($validation.status) machineReady=$($validation.machineReady) failed=$($validation.failed)"
  Add-Check "validation-awaits-physical-session" ($(if ($validation.status -eq "full-online-validation-pending-evidence" -or $validation.status -eq "full-online-validation-ready") { "pass" } else { "fail" })) "status=$($validation.status) pending=$($validation.pending)"
} else {
  Add-Check "validation-json" "fail" "Missing $ValidationPath"
}

$statusReport = Read-JsonIfPresent $StatusPath
if ($null -ne $statusReport) {
  Add-Check "status-json" "pass" $StatusPath
  Add-Check "status-schema" ($(if ($statusReport.schema -eq "stackchan.full-online-status.v1") { "pass" } else { "fail" })) "schema=$($statusReport.schema)"
  Add-Check "status-pending-or-validated" ($(if ($statusReport.status -eq "stackchan-full-online-pending-validation" -or $statusReport.status -eq "stackchan-full-online-validated") { "pass" } else { "fail" })) "status=$($statusReport.status)"
  Add-Check "status-no-failures" ($(if ((Get-IntValue $statusReport "failed" 1) -eq 0) { "pass" } else { "fail" })) "failed=$($statusReport.failed)"
  Add-FreshnessCheck "status-fresh" ([string]$statusReport.generatedAt) $MaxStatusAgeMinutes
} else {
  Add-Check "status-json" "pending" "Run tools\check_stackchan_full_online_status.cmd -Json."
}

$supervisedFlash = Read-JsonIfPresent $SupervisedFlashPath
if ($null -ne $supervisedFlash) {
  Add-Check "supervised-flash-json" "pass" $SupervisedFlashPath
  Add-Check "supervised-flash-complete" ($(if ($supervisedFlash.status -eq "full-online-supervised-flash-complete") { "pass" } else { "fail" })) "status=$($supervisedFlash.status)"
} else {
  Add-Check "supervised-flash-json" "fail" "Missing $SupervisedFlashPath"
}

if (Test-Path -LiteralPath $NextActionsPath -PathType Leaf) {
  $nextActions = Get-Content -LiteralPath $NextActionsPath -Raw
  Add-Check "next-actions-file" "pass" $NextActionsPath
  Add-Check "next-actions-guided-session" ($(if ($nextActions -match "start_full_online_physical_validation_session\.cmd") { "pass" } else { "fail" })) "guided session command present"
  Add-Check "next-actions-emergency-stop" ($(if ($nextActions -match "send_stackchan_serial_command\.cmd" -and $nextActions -match "motion stop") { "pass" } else { "fail" })) "emergency motion stop command present"
} else {
  Add-Check "next-actions-file" "fail" "Missing $NextActionsPath"
}

$bodyClear = Read-JsonIfPresent $BodyClearAttestationPath
if ($null -ne $bodyClear) {
  Add-Check "body-clear-attestation-json" "pass" $BodyClearAttestationPath
  Add-Check "body-clear-attestation-schema" ($(if ($bodyClear.schema -eq "stackchan.body-clear-attestation.v1") { "pass" } else { "fail" })) "schema=$($bodyClear.schema)"
  Add-Check "live-operator-still-required" ($(if ($bodyClear.stillRequiresLiveOperatorConfirmation -eq $true) { "pass" } else { "fail" })) "stillRequiresLiveOperatorConfirmation=$($bodyClear.stillRequiresLiveOperatorConfirmation)"
} else {
  Add-Check "body-clear-attestation-json" "pending" "Optional attestation missing: $BodyClearAttestationPath"
}

$debug = $null
if (-not [string]::IsNullOrWhiteSpace($DebugJsonPath)) {
  $debug = Read-JsonIfPresent $DebugJsonPath
  if ($null -eq $debug) {
    Add-Check "debug-json" "fail" "Missing $DebugJsonPath"
  }
} else {
  try {
    $debug = Invoke-RestMethod -Uri $DebugUrl -TimeoutSec 5
  } catch {
    Add-Check "debug-json" "fail" "$DebugUrl :: $($_.Exception.Message)"
  }
}
if ($null -ne $debug) {
  Add-Check "debug-schema" ($(if ($debug.schema -eq "stackchan.bridge-debug.v1") { "pass" } else { "fail" })) "schema=$($debug.schema)"
  Add-Check "debug-ready" ($(if ($debug.network_state -eq "connected" -and $debug.bridge_state -eq "ready") { "pass" } else { "fail" })) "network=$($debug.network_state) bridge=$($debug.bridge_state)"
  Add-Check "debug-error-clear" ($(if ([string]$debug.network_error -eq "") { "pass" } else { "fail" })) "network_error=$($debug.network_error)"
  Add-Check "debug-volume-150" ($(if ((Get-IntValue $debug "speaker_volume" 0) -eq 150) { "pass" } else { "fail" })) "speaker_volume=$($debug.speaker_volume)"
  Add-Check "debug-audio-idle" ($(if (-not [bool]$debug.audio_stream_active) { "pass" } else { "fail" })) "audio_stream_active=$($debug.audio_stream_active)"
  Add-Check "debug-playback-clean" ($(if ((Get-IntValue $debug "bridge_downlink_playback_errors" 0) -eq 0 -and (Get-IntValue $debug "speaker_stream_play_raw_failed" 0) -eq 0) { "pass" } else { "fail" })) "playback_errors=$($debug.bridge_downlink_playback_errors) speaker_failed=$($debug.speaker_stream_play_raw_failed)"
  Add-Check "debug-mic-uplink-ready" ($(if ((Get-BoolLike $debug "compiled_enable_mic_capture") -and (Get-BoolLike $debug "bridge_uplink_enabled") -and (Get-BoolLike $debug "bridge_wake_gate_ready")) { "pass" } else { "fail" })) "compiled_mic=$($debug.compiled_enable_mic_capture) uplink=$($debug.bridge_uplink_enabled) wake_gate_ready=$($debug.bridge_wake_gate_ready)"
  Add-Check "debug-servo-ready" ($(if ((Get-BoolLike $debug "compiled_enable_servos") -and (Get-BoolLike $debug "motion_enabled")) { "pass" } else { "fail" })) "compiled_servos=$($debug.compiled_enable_servos) motion_enabled=$($debug.motion_enabled)"
}

if ($PortNames.Count -eq 0) {
  try {
    $PortNames = [System.IO.Ports.SerialPort]::GetPortNames()
  } catch {
    Add-Check "serial-port-list" "fail" $_.Exception.Message
  }
}
if ($PortNames.Count -gt 0) {
  Add-Check "serial-port-listed" ($(if ($PortNames -contains $Port) { "pass" } else { "fail" })) "port=$Port available=$($PortNames -join ',')"
}

$serialOpenChecked = $false
if ($CheckSerialOpen) {
  $serialOpenChecked = $true
  if (-not $OperatorPresent) {
    Add-Check "serial-open-operator-present" "fail" "Checking serial open requires -OperatorPresent."
  } elseif ($PortNames.Count -gt 0 -and $PortNames -notcontains $Port) {
    Add-Check "serial-open" "fail" "$Port is not listed."
  } else {
    $serial = [System.IO.Ports.SerialPort]::new($Port, 115200, [System.IO.Ports.Parity]::None, 8, [System.IO.Ports.StopBits]::One)
    $serial.ReadTimeout = 100
    $serial.WriteTimeout = 100
    $serial.DtrEnable = [bool]$DtrEnable
    $serial.RtsEnable = [bool]$RtsEnable
    try {
      $serial.Open()
      Start-Sleep -Milliseconds $SerialReadBackMs
      try { [void]$serial.ReadExisting() } catch {}
      Add-Check "serial-open" "pass" "$Port@115200 dtr=$([bool]$DtrEnable) rts=$([bool]$RtsEnable)"
    } catch {
      Add-Check "serial-open" "fail" $_.Exception.Message
    } finally {
      if ($serial.IsOpen) { $serial.Close() }
      $serial.Dispose()
    }
  }
} else {
  Add-Check "serial-open-skipped" "pass" "Skipped by default; run with -CheckSerialOpen -OperatorPresent if the port must be opened before the session."
}

$failed = @($checks | Where-Object { $_.status -eq "fail" })
$pending = @($checks | Where-Object { $_.status -eq "pending" })
$physicalValidated = ($null -ne $validation -and $validation.status -eq "full-online-validation-ready")
$readyForPhysicalSession = ($failed.Count -eq 0 -and -not $physicalValidated)
$status = if ($failed.Count -gt 0) {
  "full-online-physical-session-not-ready"
} elseif ($physicalValidated) {
  "full-online-physical-validation-already-ready"
} elseif ($pending.Count -gt 0) {
  "full-online-physical-session-ready-with-pending-notes"
} else {
  "full-online-physical-session-ready"
}

$readinessCommand = ".\tools\check_full_online_physical_session_readiness.cmd -DeviceHost $DeviceHost -Port $Port -Json"
$guidedSessionCommand = ".\tools\start_full_online_physical_validation_session.cmd -EvidenceRoot output\pc-brain\full-online-validation-latest -DeviceHost $DeviceHost -Port $Port -OperatorPresent -BodyClear -ConfirmServoRisk -LoggerDebugOnly -SuggestedVoicePrompt `"hello stackchan`""
$emergencyMotionStopCommand = ".\tools\send_stackchan_serial_command.cmd -EvidenceRoot output\pc-brain\full-online-validation-latest -Port $Port -Command `"motion stop`" -OperatorPresent -Json"

$result = [ordered]@{
  schema = "stackchan.full-online-physical-session-readiness.v1"
  status = $status
  readyForPhysicalSession = $readyForPhysicalSession
  physicalValidated = $physicalValidated
  generatedAt = (Get-Date).ToString("o")
  debugUrl = $DebugUrl
  port = $Port
  portNames = $PortNames
  serialOpenChecked = $serialOpenChecked
  serialDtrEnable = $(if ($serialOpenChecked) { [bool]$DtrEnable } else { $null })
  serialRtsEnable = $(if ($serialOpenChecked) { [bool]$RtsEnable } else { $null })
  nextCommand = $(if ($readyForPhysicalSession) { $guidedSessionCommand } else { $readinessCommand })
  emergencyMotionStopCommand = $emergencyMotionStopCommand
  passed = @($checks | Where-Object { $_.status -eq "pass" }).Count
  failed = $failed.Count
  pending = $pending.Count
  checks = $checks
}

New-Item -ItemType Directory -Force -Path $ReportDir | Out-Null
$resolvedReportDir = (Resolve-Path $ReportDir).Path
$jsonPath = Join-Path $resolvedReportDir "FULL_ONLINE_PHYSICAL_SESSION_READINESS.json"
$markdownPath = Join-Path $resolvedReportDir "FULL_ONLINE_PHYSICAL_SESSION_READINESS.md"
$result | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $jsonPath -Encoding UTF8

$lines = @(
  "# Stackchan Full-Online Physical Session Readiness",
  "",
  "- Schema: ``$($result.schema)``",
  "- Status: ``$($result.status)``",
  "- Ready for physical session: ``$($result.readyForPhysicalSession)``",
  "- Physical validation complete: ``$($result.physicalValidated)``",
  "- Port: ``$($result.port)``",
  "- Serial open checked: ``$($result.serialOpenChecked)``",
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
if ($result.readyForPhysicalSession) {
  $lines += "- Start the guided physical session only when Rob is present and ready to observe voice, mic, and servo behavior:"
  $lines += ""
  $lines += '```powershell'
  $lines += $result.nextCommand
  $lines += '```'
  $lines += ""
  $lines += "- Keep this emergency stop command ready before controlled motion:"
  $lines += ""
  $lines += '```powershell'
  $lines += $result.emergencyMotionStopCommand
  $lines += '```'
} elseif ($result.physicalValidated) {
  $lines += "- Physical validation is already ready. Preserve the evidence folder."
} else {
  $lines += "- Resolve failed checks, then rerun:"
  $lines += ""
  $lines += '```powershell'
  $lines += $readinessCommand
  $lines += '```'
}
$lines | Set-Content -LiteralPath $markdownPath -Encoding UTF8

if ($Json) {
  $result | ConvertTo-Json -Depth 8
} else {
  Write-Host "Full-online physical session readiness: $status"
  Write-Host "Report: $markdownPath"
}

if ($failed.Count -gt 0) {
  exit 1
}
