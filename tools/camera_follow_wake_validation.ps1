param(
  [string]$DeviceHost = "192.168.1.238",
  [int]$DevicePort = 8789,
  [int]$BridgeLocalPort = 8765,
  [string]$EvidenceRoot = "",
  [int]$DurationSeconds = 75,
  [int]$PollIntervalMs = 500,
  [int]$PreflightTimeoutSeconds = 30,
  [int]$RequiredStableTargetSamples = 3,
  [double]$MinTargetConfidence = 0.45,
  [int]$MinPowerVbusMv = 4400,
  [double]$MaxPreflightChipTempC = 67,
  [double]$MaxChipTempC = 68,
  [int]$MaxDisplayFrameUs = 50000,
  [int]$MinCaptureChunks = 96,
  [switch]$OperatorPresent,
  [switch]$BodyClear,
  [switch]$ConfirmServoRisk,
  [switch]$Json
)

$ErrorActionPreference = "Stop"
$RepoRoot = Resolve-Path (Join-Path $PSScriptRoot "..")
Set-Location $RepoRoot
$SourceCommit = (& git rev-parse HEAD).Trim()
$SourceDirty = -not [string]::IsNullOrWhiteSpace(((& git status --porcelain=v1 --untracked-files=normal) -join "`n"))

if (-not $OperatorPresent -or -not $BodyClear -or -not $ConfirmServoRisk) {
  throw "Refusing camera-follow motor validation without -OperatorPresent -BodyClear -ConfirmServoRisk."
}
if ($DurationSeconds -lt 15 -or $PollIntervalMs -lt 250) {
  throw "DurationSeconds must be at least 15 and PollIntervalMs must be at least 250."
}
if ([string]::IsNullOrWhiteSpace($EvidenceRoot)) {
  $stamp = Get-Date -Format "yyyyMMdd-HHmmss"
  $EvidenceRoot = "output\hardware-evidence\final-integration\camera-follow-wake-supervised-$stamp"
}

function Get-Value {
  param($Object, [string]$Name, $Default = $null)
  if ($null -eq $Object) { return $Default }
  $property = $Object.PSObject.Properties[$Name]
  if ($null -eq $property -or $null -eq $property.Value) { return $Default }
  return $property.Value
}

function Test-True {
  param($Value)
  if ($Value -is [bool]) { return [bool]$Value }
  if ($Value -is [int] -or $Value -is [long]) { return [int64]$Value -ne 0 }
  if ($null -eq $Value) { return $false }
  return ([string]$Value).Trim().ToLowerInvariant() -in @("true", "1", "yes")
}

function Write-JsonAtomic {
  param([string]$Path, $Value)
  $parent = Split-Path -Parent $Path
  if (-not [string]::IsNullOrWhiteSpace($parent)) {
    New-Item -ItemType Directory -Force -Path $parent | Out-Null
  }
  $temp = "$Path.tmp-$([guid]::NewGuid().ToString('N'))"
  try {
    $Value | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $temp -Encoding UTF8
    Move-Item -LiteralPath $temp -Destination $Path -Force
  } finally {
    Remove-Item -LiteralPath $temp -Force -ErrorAction SilentlyContinue
  }
}

function Invoke-RobotEndpoint {
  param([string]$Path, [int]$TimeoutSeconds = 4)
  $url = "http://$DeviceHost`:$DevicePort$Path"
  $body = & curl.exe --max-time $TimeoutSeconds -s $url
  $exitCode = $LASTEXITCODE
  if ($exitCode -ne 0 -or [string]::IsNullOrWhiteSpace($body)) {
    return [pscustomobject]@{ ok = $false; curlExit = $exitCode; body = $body; json = $null }
  }
  try {
    return [pscustomobject]@{ ok = $true; curlExit = $exitCode; body = $body; json = ($body | ConvertFrom-Json) }
  } catch {
    return [pscustomobject]@{ ok = $false; curlExit = $exitCode; body = $body; json = $null; error = $_.Exception.Message }
  }
}

function Get-BridgeSocketRemote {
  try {
    $socket = Get-NetTCPConnection -LocalPort $BridgeLocalPort -State Established -ErrorAction SilentlyContinue |
      Where-Object { $_.RemoteAddress -eq $DeviceHost } |
      Select-Object -First 1
    if ($socket) { return [string]$socket.RemoteAddress }
  } catch {
  }
  return $null
}

function Get-SelectedDebug {
  param($Debug)
  $names = @(
    "uptime_ms", "boot_count", "reset_reason", "debug_response_truncated",
    "ota_expected_sha256", "ota_current_app_confirmed",
    "network_state", "bridge_state", "bridge_uplink_turns", "bridge_uplink_errors",
    "heap_free", "heap_min_free", "chip_temp_c", "power_vbus_mv",
    "power_vbus_hard_floor_entries", "power_pmic_vbus_present", "power_pmic_vbus_loss_entries",
    "display_window_max_frame_us", "motion_enabled", "servo_rail_enabled", "servo_torque_enabled",
    "motion_actuator_ready", "motion_last_reason", "motion_session_timeouts",
    "power_motion_allowed", "motion_power_charge_backed", "motion_thermal_suppressed",
    "motion_power_suppressed", "motion_output_suppressed",
    "camera_ready", "camera_active", "camera_capture_ready", "camera_capture_failures",
    "camera_host_frame_requests", "camera_host_frame_failures", "camera_host_target_updates",
    "camera_host_auth_failures", "camera_target_valid", "camera_target_x", "camera_target_y",
    "camera_target_size", "camera_target_confidence", "camera_gaze_tracking",
    "camera_gaze_motion_output_active", "camera_gaze_yaw_offset_deg", "camera_gaze_pitch_offset_deg",
    "motion_audio_playback_active", "motion_audio_preempt_active", "motion_audio_cooldown_tail_active",
    "motion_audio_microphone_cooldown_clears", "speaker_running", "speaker_power_active",
    "wake_cue_phase", "wake_cue_detections", "wake_cue_captures_started",
    "wake_cue_captures_completed", "wake_cue_captures_failed", "wake_cue_ordering_violations",
    "wake_capture_incremental_active", "wake_capture_chunks_attempted",
    "wake_capture_chunks_submitted", "wake_capture_service_calls", "wake_capture_max_service_us"
  )
  $selected = [ordered]@{}
  foreach ($name in $names) { $selected[$name] = Get-Value $Debug $name $null }
  return [pscustomobject]$selected
}

function Test-RuntimeGate {
  param($Debug, [bool]$RequireTarget, [bool]$RequireOutputsOff)
  $bridge = ([string](Get-Value $Debug "bridge_state" "")).ToLowerInvariant()
  $network = ([string](Get-Value $Debug "network_state" "")).ToLowerInvariant()
  $targetOkay = -not $RequireTarget -or (
    (Test-True (Get-Value $Debug "camera_target_valid" $false)) -and
    [double](Get-Value $Debug "camera_target_confidence" 0) -ge $MinTargetConfidence
  )
  $outputsOkay = -not $RequireOutputsOff -or (
    -not (Test-True (Get-Value $Debug "motion_enabled" $false)) -and
    -not (Test-True (Get-Value $Debug "servo_rail_enabled" $false)) -and
    -not (Test-True (Get-Value $Debug "servo_torque_enabled" $false))
  )
  return -not (Test-True (Get-Value $Debug "debug_response_truncated" $true)) -and
    $network -eq "connected" -and $bridge -in @("ready", "listening", "thinking", "responding") -and
    (Test-True (Get-Value $Debug "camera_ready" $false)) -and
    (Test-True (Get-Value $Debug "camera_active" $false)) -and
    (Test-True (Get-Value $Debug "camera_capture_ready" $false)) -and
    (Test-True (Get-Value $Debug "power_pmic_vbus_present" $false)) -and
    [int64](Get-Value $Debug "power_vbus_mv" 0) -ge $MinPowerVbusMv -and
    [double](Get-Value $Debug "chip_temp_c" 999) -le $MaxChipTempC -and
    [int64](Get-Value $Debug "display_window_max_frame_us" ([int64]::MaxValue)) -le $MaxDisplayFrameUs -and
    $targetOkay -and $outputsOkay
}

function Stop-MotionVerified {
  $attempts = [System.Collections.Generic.List[object]]::new()
  for ($attempt = 1; $attempt -le 4; ++$attempt) {
    $request = Invoke-RobotEndpoint "/motion-stop" 4
    Start-Sleep -Milliseconds 350
    $verify = Invoke-RobotEndpoint "/debug" 4
    $verified = $verify.ok -and
      -not (Test-True (Get-Value $verify.json "motion_enabled" $true)) -and
      -not (Test-True (Get-Value $verify.json "servo_rail_enabled" $true)) -and
      -not (Test-True (Get-Value $verify.json "servo_torque_enabled" $true))
    $attempts.Add([ordered]@{ attempt = $attempt; requestOk = $request.ok; verified = $verified })
    if ($verified) { return [pscustomobject]@{ verified = $true; attempts = $attempts; debug = $verify.json } }
  }
  return [pscustomobject]@{ verified = $false; attempts = $attempts; debug = $null }
}

New-Item -ItemType Directory -Force -Path $EvidenceRoot | Out-Null
$EvidenceRoot = (Resolve-Path $EvidenceRoot).Path
$samples = [System.Collections.Generic.List[object]]::new()
$preflightSamples = [System.Collections.Generic.List[object]]::new()
$startedAt = [DateTimeOffset]::Now
$baseline = $null
$activation = $null
$abortReason = ""
$fatalError = ""
$stopResult = $null
$motionStarted = $false

try {
  $initialStop = Stop-MotionVerified
  if (-not $initialStop.verified) { throw "Could not verify motion was off before preflight." }

  $stableTargetSamples = 0
  $preflightDeadline = [DateTime]::UtcNow.AddSeconds($PreflightTimeoutSeconds)
  while ([DateTime]::UtcNow -lt $preflightDeadline) {
    $probe = Invoke-RobotEndpoint "/debug" 4
    if ($probe.ok) {
      $selected = Get-SelectedDebug $probe.json
      $socketRemote = Get-BridgeSocketRemote
      $selected | Add-Member -NotePropertyName bridge_socket_remote -NotePropertyValue $socketRemote
      $preflightSamples.Add($selected)
      $preflightOkay = (Test-RuntimeGate $probe.json $true $true) -and $socketRemote -eq $DeviceHost
      $preflightTempOkay = [double](Get-Value $probe.json "chip_temp_c" 999) -le $MaxPreflightChipTempC
      if ($preflightOkay -and $preflightTempOkay) { $stableTargetSamples += 1 } else { $stableTargetSamples = 0 }
      if ($stableTargetSamples -ge $RequiredStableTargetSamples) { $baseline = $probe.json; break }
    } else {
      $stableTargetSamples = 0
      $preflightSamples.Add([pscustomobject]@{ at = [DateTimeOffset]::Now.ToString("o"); error = "debug_failed"; curlExit = $probe.curlExit })
    }
    Start-Sleep -Milliseconds $PollIntervalMs
  }
  if ($null -eq $baseline) { throw "Stable face lock and runtime gates were not acquired before the preflight timeout." }
  Write-JsonAtomic (Join-Path $EvidenceRoot "pre-debug.json") $baseline
  Write-JsonAtomic (Join-Path $EvidenceRoot "preflight-samples.json") $preflightSamples

  $resume = Invoke-RobotEndpoint "/motion-resume" 4
  if (-not $resume.ok) { throw "The motion-resume request failed." }
  $activationDeadline = [DateTime]::UtcNow.AddSeconds(6)
  while ([DateTime]::UtcNow -lt $activationDeadline) {
    Start-Sleep -Milliseconds 350
    $probe = Invoke-RobotEndpoint "/debug" 4
    if ($probe.ok -and
        (Test-True (Get-Value $probe.json "motion_enabled" $false)) -and
        (Test-True (Get-Value $probe.json "servo_rail_enabled" $false)) -and
        (Test-True (Get-Value $probe.json "servo_torque_enabled" $false)) -and
        (Test-True (Get-Value $probe.json "camera_target_valid" $false)) -and
        (Test-True (Get-Value $probe.json "camera_gaze_motion_output_active" $false))) {
      $activation = $probe.json
      $motionStarted = $true
      break
    }
  }
  if (-not $motionStarted) { throw "Camera-follow motion did not become active after motion-resume." }
  Write-JsonAtomic (Join-Path $EvidenceRoot "activation-debug.json") $activation
  Write-Host "CAMERA FOLLOW ACTIVE. Say 'Hey Stackchan', then ask 'What is your name?' once."

  $baselineBoot = [int64](Get-Value $baseline "boot_count" -1)
  $baselineHardFloor = [int64](Get-Value $baseline "power_vbus_hard_floor_entries" -1)
  $baselinePmicLoss = [int64](Get-Value $baseline "power_pmic_vbus_loss_entries" -1)
  $baselineTimeouts = [int64](Get-Value $baseline "motion_session_timeouts" -1)
  $baselineCaptureStarted = [int64](Get-Value $baseline "wake_cue_captures_started" 0)
  $baselineCaptureCompleted = [int64](Get-Value $baseline "wake_cue_captures_completed" 0)
  $baselineCaptureFailed = [int64](Get-Value $baseline "wake_cue_captures_failed" 0)
  $baselineOrdering = [int64](Get-Value $baseline "wake_cue_ordering_violations" 0)
  $baselineChunksAttempted = [int64](Get-Value $baseline "wake_capture_chunks_attempted" 0)
  $baselineChunksSubmitted = [int64](Get-Value $baseline "wake_capture_chunks_submitted" 0)
  $baselineServiceCalls = [int64](Get-Value $baseline "wake_capture_service_calls" 0)
  $baselineCooldownClears = [int64](Get-Value $baseline "motion_audio_microphone_cooldown_clears" 0)
  $baselineTurns = [int64](Get-Value $baseline "bridge_uplink_turns" 0)
  $deadline = [DateTime]::UtcNow.AddSeconds($DurationSeconds)
  $runStarted = [DateTime]::UtcNow
  $captureCompletedAt = $null
  $consecutiveDebugFailures = 0

  while ([DateTime]::UtcNow -lt $deadline) {
    $probe = Invoke-RobotEndpoint "/debug" 4
    $elapsed = [math]::Round(([DateTime]::UtcNow - $runStarted).TotalSeconds, 3)
    if (-not $probe.ok) {
      $consecutiveDebugFailures += 1
      $samples.Add([pscustomobject]@{ t_s = $elapsed; ok = $false; curlExit = $probe.curlExit })
      if ($consecutiveDebugFailures -gt 1) { $abortReason = "repeated_debug_failure"; break }
      Start-Sleep -Milliseconds $PollIntervalMs
      continue
    }
    $consecutiveDebugFailures = 0
    $j = $probe.json
    $selected = Get-SelectedDebug $j
    $socketRemote = Get-BridgeSocketRemote
    $selected | Add-Member -NotePropertyName t_s -NotePropertyValue $elapsed
    $selected | Add-Member -NotePropertyName ok -NotePropertyValue $true
    $selected | Add-Member -NotePropertyName bridge_socket_remote -NotePropertyValue $socketRemote
    $samples.Add($selected)

    $bridge = ([string](Get-Value $j "bridge_state" "")).ToLowerInvariant()
    $captureActive = Test-True (Get-Value $j "wake_capture_incremental_active" $false)
    $targetValid = Test-True (Get-Value $j "camera_target_valid" $false)
    $actualPlayback = (Test-True (Get-Value $j "motion_audio_playback_active" $false)) -or
      (Test-True (Get-Value $j "speaker_running" $false)) -or
      (Test-True (Get-Value $j "speaker_power_active" $false))
    $motionOn = Test-True (Get-Value $j "motion_enabled" $false)
    $railOn = Test-True (Get-Value $j "servo_rail_enabled" $false)
    $torqueOn = Test-True (Get-Value $j "servo_torque_enabled" $false)
    $gazeOutput = Test-True (Get-Value $j "camera_gaze_motion_output_active" $false)
    $audioPreempt = Test-True (Get-Value $j "motion_audio_preempt_active" $false)

    if ([int64](Get-Value $j "boot_count" -2) -ne $baselineBoot) { $abortReason = "robot_rebooted"; break }
    if ($socketRemote -ne $DeviceHost) { $abortReason = "bridge_socket_missing"; break }
    if (([string](Get-Value $j "network_state" "")) -ne "connected" -or $bridge -notin @("ready", "listening", "thinking", "responding")) { $abortReason = "bridge_or_network_unhealthy"; break }
    if ([double](Get-Value $j "chip_temp_c" 999) -gt $MaxChipTempC) { $abortReason = "chip_temp_limit_exceeded"; break }
    if ([int64](Get-Value $j "power_vbus_mv" 0) -lt $MinPowerVbusMv) { $abortReason = "vbus_floor_exceeded"; break }
    if ([int64](Get-Value $j "display_window_max_frame_us" ([int64]::MaxValue)) -gt $MaxDisplayFrameUs) { $abortReason = "display_frame_limit_exceeded"; break }
    if (-not (Test-True (Get-Value $j "power_pmic_vbus_present" $false)) -or [int64](Get-Value $j "power_pmic_vbus_loss_entries" -1) -gt $baselinePmicLoss) { $abortReason = "pmic_vbus_loss_observed"; break }
    if ([int64](Get-Value $j "power_vbus_hard_floor_entries" -1) -gt $baselineHardFloor) { $abortReason = "hard_floor_event_observed"; break }
    if ([int64](Get-Value $j "motion_session_timeouts" -1) -gt $baselineTimeouts) { $abortReason = "motion_session_timeout_observed"; break }
    if ([int64](Get-Value $j "wake_cue_captures_failed" 0) -gt $baselineCaptureFailed) { $abortReason = "wake_capture_failed"; break }
    if ([int64](Get-Value $j "wake_cue_ordering_violations" 0) -gt $baselineOrdering) { $abortReason = "wake_ordering_violation"; break }
    if ($railOn -and -not (Test-True (Get-Value $j "power_motion_allowed" $false))) { $abortReason = "rail_without_power_grant"; break }
    if ($torqueOn -and -not $railOn) { $abortReason = "torque_without_rail"; break }

    if ($captureActive -and $targetValid) {
      if ($actualPlayback) { $abortReason = "speaker_playback_overlapped_microphone_capture"; break }
      if ($audioPreempt) { $abortReason = "audio_preempt_active_during_microphone_capture"; break }
      if (-not $motionOn -or -not $railOn -or -not $torqueOn -or -not $gazeOutput) { $abortReason = "camera_follow_lost_during_microphone_capture"; break }
    }

    $captureCompletedDelta = [int64](Get-Value $j "wake_cue_captures_completed" 0) - $baselineCaptureCompleted
    if ($captureCompletedDelta -gt 0 -and $null -eq $captureCompletedAt) { $captureCompletedAt = [DateTime]::UtcNow }
    $turnDelta = [int64](Get-Value $j "bridge_uplink_turns" 0) - $baselineTurns
    if ($null -ne $captureCompletedAt -and $turnDelta -gt 0 -and ([DateTime]::UtcNow - $captureCompletedAt).TotalSeconds -ge 5) { break }
    Start-Sleep -Milliseconds $PollIntervalMs
  }
} catch {
  $fatalError = $_.Exception.Message
  if ([string]::IsNullOrWhiteSpace($abortReason)) { $abortReason = "exception" }
} finally {
  Write-JsonAtomic (Join-Path $EvidenceRoot "samples.json") $samples
  $stopResult = Stop-MotionVerified
  if ($null -ne $stopResult.debug) { Write-JsonAtomic (Join-Path $EvidenceRoot "motion-stop.json") $stopResult.debug }
}

$valid = @($samples | Where-Object { $_.ok })
$captureSamples = @($valid | Where-Object { Test-True $_.wake_capture_incremental_active })
$captureTargetSamples = @($captureSamples | Where-Object { Test-True $_.camera_target_valid })
$captureFollowSamples = @($captureTargetSamples | Where-Object {
    (Test-True $_.motion_enabled) -and (Test-True $_.servo_rail_enabled) -and
    (Test-True $_.servo_torque_enabled) -and (Test-True $_.camera_gaze_motion_output_active) -and
    -not (Test-True $_.motion_audio_preempt_active)
  })
$last = if ($valid.Count -gt 0) { $valid[-1] } else { $null }
$wakeStartedDelta = if ($null -ne $last) { [int64]$last.wake_cue_captures_started - [int64](Get-Value $baseline "wake_cue_captures_started" 0) } else { 0 }
$wakeCompletedDelta = if ($null -ne $last) { [int64]$last.wake_cue_captures_completed - [int64](Get-Value $baseline "wake_cue_captures_completed" 0) } else { 0 }
$chunksAttemptedDelta = if ($null -ne $last) { [int64]$last.wake_capture_chunks_attempted - [int64](Get-Value $baseline "wake_capture_chunks_attempted" 0) } else { 0 }
$chunksSubmittedDelta = if ($null -ne $last) { [int64]$last.wake_capture_chunks_submitted - [int64](Get-Value $baseline "wake_capture_chunks_submitted" 0) } else { 0 }
$serviceCallsDelta = if ($null -ne $last) { [int64]$last.wake_capture_service_calls - [int64](Get-Value $baseline "wake_capture_service_calls" 0) } else { 0 }
$cooldownClearsDelta = if ($null -ne $last) { [int64]$last.motion_audio_microphone_cooldown_clears - [int64](Get-Value $baseline "motion_audio_microphone_cooldown_clears" 0) } else { 0 }
$turnDelta = if ($null -ne $last) { [int64]$last.bridge_uplink_turns - [int64](Get-Value $baseline "bridge_uplink_turns" 0) } else { 0 }

$checks = [System.Collections.Generic.List[object]]::new()
function Add-Check([string]$Id, [bool]$Passed, [string]$Detail) {
  $checks.Add([ordered]@{ id = $Id; status = $(if ($Passed) { "pass" } else { "fail" }); detail = $Detail })
}
Add-Check "preflight" ($null -ne $baseline) "stable_target=$($null -ne $baseline)"
Add-Check "motion-activated" ($motionStarted) "motion_started=$motionStarted"
Add-Check "wake-capture-started" ($wakeStartedDelta -ge 1) "delta=$wakeStartedDelta"
Add-Check "wake-capture-completed" ($wakeCompletedDelta -ge 1) "delta=$wakeCompletedDelta"
Add-Check "incremental-capture-observed" ($captureSamples.Count -ge 2) "samples=$($captureSamples.Count)"
Add-Check "capture-chunks" ($chunksAttemptedDelta -ge $MinCaptureChunks -and $chunksSubmittedDelta -ge $MinCaptureChunks -and $serviceCallsDelta -ge $MinCaptureChunks) "attempted=$chunksAttemptedDelta submitted=$chunksSubmittedDelta service_calls=$serviceCallsDelta minimum=$MinCaptureChunks"
Add-Check "camera-follow-during-capture" ($captureTargetSamples.Count -ge 2 -and $captureFollowSamples.Count -eq $captureTargetSamples.Count) "target_samples=$($captureTargetSamples.Count) follow_samples=$($captureFollowSamples.Count)"
Add-Check "microphone-cooldown-handoff" ($cooldownClearsDelta -ge 1) "delta=$cooldownClearsDelta"
Add-Check "bridge-turn" ($turnDelta -ge 1) "delta=$turnDelta"
Add-Check "strict-runtime" ([string]::IsNullOrWhiteSpace($abortReason) -and [string]::IsNullOrWhiteSpace($fatalError)) "abort_reason=$abortReason fatal_error=$fatalError"
Add-Check "motion-stop-verified" ($null -ne $stopResult -and $stopResult.verified) "verified=$($stopResult.verified)"
$failed = @($checks | Where-Object { $_.status -eq "fail" }).Count
$status = if ($failed -eq 0) { "telemetry_pass_pending_visual" } else { "fail" }
$summary = [ordered]@{
  schema = "stackchan.camera-follow-wake-validation.v1"
  status = $status
  sourceCommit = $SourceCommit
  sourceDirty = $SourceDirty
  installedFirmwareSha256 = Get-Value $baseline "ota_expected_sha256" ""
  generatedAt = [DateTimeOffset]::Now.ToString("o")
  startedAt = $startedAt.ToString("o")
  evidenceRoot = $EvidenceRoot
  durationSeconds = [math]::Round(([DateTimeOffset]::Now - $startedAt).TotalSeconds, 2)
  abortReason = $abortReason
  fatalError = $fatalError
  visualVerdict = "pending_operator"
  sampleCount = $samples.Count
  captureSamples = $captureSamples.Count
  captureTargetSamples = $captureTargetSamples.Count
  captureFollowSamples = $captureFollowSamples.Count
  wakeStartedDelta = $wakeStartedDelta
  wakeCompletedDelta = $wakeCompletedDelta
  chunksAttemptedDelta = $chunksAttemptedDelta
  chunksSubmittedDelta = $chunksSubmittedDelta
  serviceCallsDelta = $serviceCallsDelta
  cooldownClearsDelta = $cooldownClearsDelta
  bridgeTurnDelta = $turnDelta
  maxCaptureServiceUs = if ($valid.Count -gt 0) { ($valid | Measure-Object wake_capture_max_service_us -Maximum).Maximum } else { $null }
  minVbusMv = if ($valid.Count -gt 0) { ($valid | Measure-Object power_vbus_mv -Minimum).Minimum } else { $null }
  maxChipTempC = if ($valid.Count -gt 0) { ($valid | Measure-Object chip_temp_c -Maximum).Maximum } else { $null }
  maxDisplayFrameUs = if ($valid.Count -gt 0) { ($valid | Measure-Object display_window_max_frame_us -Maximum).Maximum } else { $null }
  motionStopVerified = $null -ne $stopResult -and $stopResult.verified
  checks = $checks
}
Write-JsonAtomic (Join-Path $EvidenceRoot "summary.json") $summary

if ($Json) { $summary | ConvertTo-Json -Depth 12 } else {
  Write-Output "Camera-follow wake validation: $status"
  Write-Output "Evidence: $EvidenceRoot"
  Write-Output "Capture samples: $($captureSamples.Count), followed: $($captureFollowSamples.Count)/$($captureTargetSamples.Count), chunks: $chunksSubmittedDelta, bridge turns: $turnDelta"
  Write-Output "Motion stop verified: $($summary.motionStopVerified)"
}
if ($status -eq "fail") { exit 1 }
