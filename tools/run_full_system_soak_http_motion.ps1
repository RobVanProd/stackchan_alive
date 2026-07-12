param(
  [string]$DeviceHost = "192.168.1.238",
  [int]$DevicePort = 8789,
  [string]$BridgeLocalPort = "8765",
  [string]$SerialPort = "COM4",
  [int]$BaudRate = 115200,
  [string]$EvidenceRoot = "output\pc-brain\full-system-soak-http-motion-latest",
  [int]$DurationSeconds = 900,
  [int]$PollSeconds = 5,
  [int]$PollTimeoutSeconds = 4,
  [int]$MotionRefreshSeconds = 0,
  [int]$MotionRefreshInitialDelaySeconds = 7,
  [string]$RvcWorkerUrl = "http://127.0.0.1:5055",
  [int]$RvcWorkerPollSeconds = 60,
  [double]$MinMotionSampleRatio = 0.95,
  [double]$MinMotionUnsuppressedSampleRatio = 0,
  [int]$MinMotionSessionRefreshes = 0,
  [Alias("MaxChipTempC")]
  [double]$MaxAllowedChipTempC = 0,
  [int]$MinPowerVbusMv = 0,
  [int]$MinPowerVbusReportedMv = 0,
  [int]$MotionPowerSoftFloorMv = 0,
  [int]$MaxDisplayFrameUs = 0,
  [int]$MaxFailedPolls = 0,
  [double]$MaxFailedPollRatio = 0.01,
  [int]$MinPollsForFailedRatio = 100,
  [int]$MaxConsecutiveFailedPolls = 1,
  [int]$MotionStopAttempts = 4,
  [switch]$RequireMotion,
  [switch]$RequireMotionTelemetry,
  [switch]$RequireNoMotionTimeouts,
  [switch]$RequireBridgeSocket,
  [switch]$RequireWakeReady,
  [switch]$RequireMicReady,
  [switch]$RequireSpeakerReady,
  [switch]$RequireRvcWorker,
  [switch]$RequirePowerCoordinator,
  [switch]$RequirePowerForensics,
  [int]$ExpectedPmicVindpmMv = 0,
  [string]$FirmwareSourceCommit = "",
  [switch]$RequireFinalIntegration,
  [switch]$RequireCameraCapture,
  [switch]$RequireCameraHostVision,
  [int]$MaxCameraCaptureUs = 250000,
  [int]$MaxCameraHostResponseWriteFailures = 20,
  [double]$MaxCameraHostResponseWriteFailureRatio = 0.001,
  [int]$MinCameraHostResponseWriteAttemptsForRatio = 100,
  [int]$MaxCameraHostResponseWriteConsecutiveFailures = 1,
  [switch]$RequirePmicVbusStable,
  [switch]$RequireNoNewHardFloorEvents,
  [switch]$RequireManagedChargePolicy,
  [switch]$FailFastOnStrictBreach,
  [switch]$NoSerial
)

$ErrorActionPreference = "Stop"
$RepoRoot = Resolve-Path (Join-Path $PSScriptRoot "..")
Set-Location $RepoRoot
$RunnerSourceCommit = (& git rev-parse HEAD).Trim().ToLowerInvariant()
$SourceDirty = -not [string]::IsNullOrWhiteSpace(((& git status --porcelain=v1 --untracked-files=normal) -join "`n"))
if ([string]::IsNullOrWhiteSpace($FirmwareSourceCommit)) {
  $FirmwareSourceCommit = $RunnerSourceCommit
}
$SourceCommit = $FirmwareSourceCommit.Trim().ToLowerInvariant()
if ($SourceCommit -notmatch "^[0-9a-f]{40}$") {
  throw "FirmwareSourceCommit must be a full 40-character Git commit SHA."
}
& git cat-file -e "$SourceCommit`^{commit}" 2>$null
if ($LASTEXITCODE -ne 0) {
  throw "FirmwareSourceCommit is not available in this repository: $SourceCommit"
}

$minPowerVbusMvThreshold = $MinPowerVbusMv
$minPowerVbusReportedMvThreshold = $MinPowerVbusReportedMv
if ($ExpectedPmicVindpmMv -ne 0 -and
    ($ExpectedPmicVindpmMv -lt 3880 -or $ExpectedPmicVindpmMv -gt 5080 -or
      (($ExpectedPmicVindpmMv - 3880) % 80) -ne 0)) {
  throw "ExpectedPmicVindpmMv must be 0 or an 80 mV step from 3880 through 5080."
}

function Invoke-RobotEndpoint {
  param([string]$Path, [int]$TimeoutSeconds = 2)
  $url = "http://$DeviceHost`:$DevicePort$Path"
  $output = & curl.exe --max-time $TimeoutSeconds -s $url
  $exitCode = $LASTEXITCODE
  if ($exitCode -ne 0 -or [string]::IsNullOrWhiteSpace($output)) {
    return [pscustomobject]@{
      ok = $false
      curlExit = $exitCode
      body = $output
      json = $null
    }
  }

  try {
    return [pscustomobject]@{
      ok = $true
      curlExit = $exitCode
      body = $output
      json = ($output | ConvertFrom-Json)
    }
  } catch {
    return [pscustomobject]@{
      ok = $false
      curlExit = $exitCode
      body = $output
      json = $null
      error = $_.Exception.Message
    }
  }
}

function Get-BridgeSocketRemote {
  param([string]$LocalPort)
  try {
    $socket = Get-NetTCPConnection -LocalPort ([int]$LocalPort) -ErrorAction SilentlyContinue |
      Where-Object { $_.State -eq "Established" } |
      Select-Object -First 1
    if ($socket) {
      return [string]$socket.RemoteAddress
    }
  } catch {
  }
  return $null
}

function Test-SerialPortPresent {
  param([string]$PortName)
  if ([string]::IsNullOrWhiteSpace($PortName)) {
    return $false
  }
  try {
    $port = Get-CimInstance Win32_SerialPort -ErrorAction SilentlyContinue |
      Where-Object { $_.DeviceID -eq $PortName } |
      Select-Object -First 1
    return $null -ne $port
  } catch {
    return $false
  }
}

function Get-ObjectProperty {
  param($Object, [string]$Name, $Default = $null)
  if ($null -eq $Object) {
    return $Default
  }
  $property = $Object.PSObject.Properties[$Name]
  if ($null -eq $property) {
    return $Default
  }
  return $property.Value
}

function Test-TrueValue {
  param($Value)
  if ($Value -is [bool]) {
    return [bool]$Value
  }
  if ($Value -is [int] -or $Value -is [long]) {
    return [int64]$Value -ne 0
  }
  if ($null -eq $Value) {
    return $false
  }
  $text = ([string]$Value).Trim().ToLowerInvariant()
  return $text -eq "true" -or $text -eq "1" -or $text -eq "yes"
}

function Test-BridgeHealthyState {
  param([string]$State)
  $normalized = ([string]$State).Trim().ToLowerInvariant()
  return $normalized -eq "ready" -or
         $normalized -eq "listening" -or
         $normalized -eq "thinking" -or
         $normalized -eq "responding"
}

function Test-MicReadyRequired {
  param($Record)
  if ($null -eq $Record -or -not $Record.ok) {
    return $false
  }
  $bridge = ([string]$Record.bridge).Trim().ToLowerInvariant()
  return $bridge -ne "listening" -and $bridge -ne "responding"
}

function Get-MaxConsecutiveFailedPolls {
  param($Records)
  $max = 0
  $current = 0
  foreach ($record in $Records) {
    if ($record.ok) {
      $current = 0
      continue
    }
    $current += 1
    if ($current -gt $max) {
      $max = $current
    }
  }
  return $max
}

function Get-FailedPollRatio {
  param($Records)
  if ($null -eq $Records -or $Records.Count -eq 0) {
    return 0.0
  }
  $failed = @($Records | Where-Object { -not $_.ok }).Count
  return [math]::Round($failed / [double]$Records.Count, 6)
}

function Write-JsonWithRetry {
  param(
    [string]$Path,
    $Value,
    [int]$Depth = 8,
    [int]$Attempts = 40,
    [int]$DelayMilliseconds = 50
  )

  $json = $Value | ConvertTo-Json -Depth $Depth
  for ($attempt = 1; $attempt -le [math]::Max(1, $Attempts); $attempt++) {
    try {
      $json | Set-Content -LiteralPath $Path -Encoding UTF8
      return
    } catch {
      if ($attempt -ge $Attempts) {
        throw
      }
      Start-Sleep -Milliseconds $DelayMilliseconds
    }
  }
}

function Invoke-VerifiedMotionStop {
  param([int]$Attempts = 4)

  $attemptRecords = New-Object System.Collections.Generic.List[object]
  for ($attempt = 1; $attempt -le [math]::Max(1, $Attempts); $attempt++) {
    $stop = Invoke-RobotEndpoint -Path "/motion-stop" -TimeoutSeconds 4
    Start-Sleep -Milliseconds 350
    $verify = Invoke-RobotEndpoint -Path "/debug" -TimeoutSeconds 4
    $verified = $false
    if ($verify.ok) {
      $j = $verify.json
      $verified = -not (Test-TrueValue (Get-ObjectProperty $j "motion_requested" $true)) -and
        -not (Test-TrueValue (Get-ObjectProperty $j "motion_enabled" $true)) -and
        -not (Test-TrueValue (Get-ObjectProperty $j "servo_rail_enabled" $true)) -and
        -not (Test-TrueValue (Get-ObjectProperty $j "servo_torque_enabled" $true))
    }

    $attemptRecords.Add([pscustomobject]@{
        attempt = $attempt
        stopOk = [bool]$stop.ok
        stopCurlExit = $stop.curlExit
        verifyOk = [bool]$verify.ok
        verifyCurlExit = $verify.curlExit
        verified = $verified
      })
    if ($verified) {
      return [pscustomobject]@{
        verified = $true
        attempts = $attempt
        records = @($attemptRecords | ForEach-Object { $_ })
      }
    }
    Start-Sleep -Milliseconds 650
  }

  return [pscustomobject]@{
    verified = $false
    attempts = $attemptRecords.Count
    records = @($attemptRecords | ForEach-Object { $_ })
  }
}

function Invoke-RvcWorkerHealth {
  param([string]$Url)
  if ([string]::IsNullOrWhiteSpace($Url)) {
    return [pscustomobject]@{
      ok = $false
      ready = $false
      error = "rvc_worker_url_empty"
    }
  }
  try {
    $health = Invoke-RestMethod -Uri "$Url/health" -TimeoutSec 5
    return [pscustomobject]@{
      ok = $true
      ready = Test-TrueValue (Get-ObjectProperty $health "ready" $false)
      device = [string](Get-ObjectProperty $health "device" "")
      method = [string](Get-ObjectProperty $health "method" "")
      convert_count = Get-ObjectProperty $health "convert_count" $null
      uptime_seconds = Get-ObjectProperty $health "uptime_seconds" $null
      error = $null
    }
  } catch {
    return [pscustomobject]@{
      ok = $false
      ready = $false
      error = $_.Exception.Message
    }
  }
}

if ($RequireFinalIntegration) {
  $RequireCameraCapture = $true
  $RequireCameraHostVision = $true
}
if ($RequireCameraHostVision -and -not $RequireCameraCapture) {
  throw "RequireCameraHostVision requires RequireCameraCapture."
}

New-Item -ItemType Directory -Force -Path $EvidenceRoot | Out-Null
$evidencePath = (Resolve-Path $EvidenceRoot).Path
$pollPath = Join-Path $evidencePath "polls.json"
$serialPath = Join-Path $evidencePath "serial.log"
$progressPath = Join-Path $evidencePath "progress.json"
$summaryPath = Join-Path $evidencePath "summary.json"

$startedAt = Get-Date
$records = New-Object System.Collections.Generic.List[object]
$serialLines = New-Object System.Collections.Generic.List[string]
$serial = $null
$lastMotionRefresh = [DateTime]::MinValue
$lastRvcWorkerPoll = [DateTime]::MinValue
$rvcWorkerPolls = 0
$rvcWorkerReadySamples = 0
$latestRvcWorkerHealth = $null
$nextPoll = [DateTime]::UtcNow
$startUtc = [DateTime]::UtcNow
$deadline = $startUtc.AddSeconds($DurationSeconds)
$motionRefreshes = 0
$motionRefreshFailures = 0
$fatalError = $null
$abortReason = ""
$pmicVbusLossBaseline = $null
$powerVbusHardFloorEntriesBaseline = $null
$powerForensicsRuntimeEventsBaseline = $null
$powerForensicsProtectiveEventsBaseline = $null
$powerForensicsReadFailuresBaseline = $null
$powerForensicsClearFailuresBaseline = $null
$pmicInputStateReadFailuresBaseline = $null
$pmicConfigReadFailuresBaseline = $null
$powerVsysReadFailuresBaseline = $null
$bodyRgbWriteFailuresBaseline = $null
$bodyRgbWriteRetriesBaseline = $null
$bodyRgbWriteRecoveriesBaseline = $null
$bodyTouchReadFailuresBaseline = $null
$imuReadRetriesBaseline = $null
$imuReadRecoveriesBaseline = $null
$imuReadFailuresBaseline = $null
$imuEventsBaseline = $null
$imuSelfMotionEventsBaseline = $null
$imuExternalEventsBaseline = $null
$cameraCaptureFailuresBaseline = $null
$cameraHostFrameFailuresBaseline = $null
$cameraHostCaptureFailuresBaseline = $null
$cameraHostResponseWriteAttemptsBaseline = $null
$cameraHostResponseWriteFailuresBaseline = $null
$cameraHostAuthFailuresBaseline = $null
$motionStopResult = $null

try {
  if ($MotionRefreshSeconds -gt 0 -and $MotionRefreshInitialDelaySeconds -gt 0) {
    $boundedMotionDelay = [math]::Min($MotionRefreshInitialDelaySeconds, [math]::Max(1, $MotionRefreshSeconds - 1))
    $lastMotionRefresh = $startUtc.AddSeconds(-1 * ($MotionRefreshSeconds - $boundedMotionDelay))
  }

  if (-not $NoSerial) {
    $serial = [System.IO.Ports.SerialPort]::new($SerialPort, $BaudRate, [System.IO.Ports.Parity]::None, 8, [System.IO.Ports.StopBits]::One)
    $serial.NewLine = "`n"
    $serial.ReadTimeout = 100
    $serial.WriteTimeout = 1000
    $serial.DtrEnable = $false
    $serial.RtsEnable = $false
    $serial.Open()
    Start-Sleep -Milliseconds 250
    try { [void]$serial.ReadExisting() } catch {}
  }

  while ([DateTime]::UtcNow -lt $deadline) {
    $now = [DateTime]::UtcNow

    if ($serial -ne $null -and $serial.IsOpen) {
      try {
        $text = $serial.ReadExisting()
        if (-not [string]::IsNullOrEmpty($text)) {
          foreach ($raw in ($text -split "\r?\n")) {
            $line = $raw.Trim()
            if (-not [string]::IsNullOrWhiteSpace($line)) {
              $serialLines.Add("[$((Get-Date).ToString("o"))] $line")
            }
          }
        }
      } catch {
      }
    }

    if ($MotionRefreshSeconds -gt 0 -and
        ($lastMotionRefresh -eq [DateTime]::MinValue -or ($now - $lastMotionRefresh).TotalSeconds -ge $MotionRefreshSeconds)) {
      $motion = Invoke-RobotEndpoint -Path "/motion-resume" -TimeoutSeconds 4
      $motionRefreshes += 1
      if (-not $motion.ok) {
        $motionRefreshFailures += 1
      }
      $lastMotionRefresh = $now
    }

    if ($RequireRvcWorker -or $RvcWorkerPollSeconds -gt 0) {
      if ($lastRvcWorkerPoll -eq [DateTime]::MinValue -or
          ($now - $lastRvcWorkerPoll).TotalSeconds -ge $RvcWorkerPollSeconds) {
        $latestRvcWorkerHealth = Invoke-RvcWorkerHealth -Url $RvcWorkerUrl
        $rvcWorkerPolls += 1
        if ([bool]$latestRvcWorkerHealth.ready) {
          $rvcWorkerReadySamples += 1
        }
        $lastRvcWorkerPoll = $now
      }
    }

    if ($now -ge $nextPoll) {
      $poll = Invoke-RobotEndpoint -Path "/" -TimeoutSeconds $PollTimeoutSeconds
      $socketRemote = Get-BridgeSocketRemote -LocalPort $BridgeLocalPort
      $serialPortPresent = Test-SerialPortPresent -PortName $SerialPort
      $elapsed = [math]::Round(($now - $startUtc).TotalSeconds, 1)
      if ($poll.ok) {
        $j = $poll.json
        $speakerEnabled = (Get-ObjectProperty $j "compiled_enable_speaker" 0) -eq 1
        $speakerVolume = Get-ObjectProperty $j "speaker_volume" $null
        $records.Add([pscustomobject]@{
          t_s = $elapsed
          ok = $true
          ota_expected_sha256 = Get-ObjectProperty $j "ota_expected_sha256" $null
          ota_current_app_confirmed = Test-TrueValue (Get-ObjectProperty $j "ota_current_app_confirmed" $false)
          motion = Test-TrueValue (Get-ObjectProperty $j "motion_enabled" $false)
          motion_actuator_ready = Get-ObjectProperty $j "motion_actuator_ready" $null
          motion_last_reason = Get-ObjectProperty $j "motion_last_reason" $null
          motion_enabled_at_ms = Get-ObjectProperty $j "motion_enabled_at_ms" $null
          motion_last_update_ms = Get-ObjectProperty $j "motion_last_update_ms" $null
          motion_last_write_ms = Get-ObjectProperty $j "motion_last_write_ms" $null
          motion_last_pitch_command_deg = Get-ObjectProperty $j "motion_last_pitch_command_deg" $null
          motion_last_yaw_command_deg = Get-ObjectProperty $j "motion_last_yaw_command_deg" $null
          motion_self_motion_active = Test-TrueValue (Get-ObjectProperty $j "motion_self_motion_active" $false)
          motion_self_motion_until_ms = Get-ObjectProperty $j "motion_self_motion_until_ms" $null
          motion_enable_requests = Get-ObjectProperty $j "motion_enable_requests" $null
          motion_disable_requests = Get-ObjectProperty $j "motion_disable_requests" $null
          motion_enable_failures = Get-ObjectProperty $j "motion_enable_failures" $null
          motion_session_refreshes = Get-ObjectProperty $j "motion_session_refreshes" $null
          motion_session_refreshed_at_ms = Get-ObjectProperty $j "motion_session_refreshed_at_ms" $null
          motion_session_timeouts = Get-ObjectProperty $j "motion_session_timeouts" $null
          motion_stop_calls = Get-ObjectProperty $j "motion_stop_calls" $null
          motion_session_timeout_ms = Get-ObjectProperty $j "motion_session_timeout_ms" $null
          motion_duty_active_ms = Get-ObjectProperty $j "motion_duty_active_ms" $null
          motion_duty_rest_ms = Get-ObjectProperty $j "motion_duty_rest_ms" $null
          motion_duty_resting = Test-TrueValue (Get-ObjectProperty $j "motion_duty_resting" $false)
          motion_duty_cycle_start_ms = Get-ObjectProperty $j "motion_duty_cycle_start_ms" $null
          motion_duty_rest_entries = Get-ObjectProperty $j "motion_duty_rest_entries" $null
          motion_duty_rest_total_ms = Get-ObjectProperty $j "motion_duty_rest_total_ms" $null
          motion_output_suppressed = Test-TrueValue (Get-ObjectProperty $j "motion_output_suppressed" $false)
          motion_output_suppress_entries = Get-ObjectProperty $j "motion_output_suppress_entries" $null
          motion_output_suppress_total_ms = Get-ObjectProperty $j "motion_output_suppress_total_ms" $null
          motion_audio_load_shed_cooldown_ms = Get-ObjectProperty $j "motion_audio_load_shed_cooldown_ms" $null
          motion_thermal_suppressed = Test-TrueValue (Get-ObjectProperty $j "motion_thermal_suppressed" $false)
          motion_thermal_suppress_entries = Get-ObjectProperty $j "motion_thermal_suppress_entries" $null
          motion_thermal_load_shed_c = Get-ObjectProperty $j "motion_thermal_load_shed_c" $null
          motion_thermal_resume_c = Get-ObjectProperty $j "motion_thermal_resume_c" $null
          motion_power_suppressed = Test-TrueValue (Get-ObjectProperty $j "motion_power_suppressed" $false)
          motion_power_suppress_entries = Get-ObjectProperty $j "motion_power_suppress_entries" $null
          motion_power_suppressed_at_ms = Get-ObjectProperty $j "motion_power_suppressed_at_ms" $null
          motion_power_load_shed_mv = Get-ObjectProperty $j "motion_power_load_shed_mv" $null
          motion_power_resume_mv = Get-ObjectProperty $j "motion_power_resume_mv" $null
          motion_power_hard_floor_mv = Get-ObjectProperty $j "motion_power_hard_floor_mv" $null
          motion_power_charge_backed_current_ma = Get-ObjectProperty $j "motion_power_charge_backed_current_ma" $null
          motion_power_charge_backed = Test-TrueValue (Get-ObjectProperty $j "motion_power_charge_backed" $false)
          motion_power_min_suppress_ms = Get-ObjectProperty $j "motion_power_min_suppress_ms" $null
          heap_free = Get-ObjectProperty $j "heap_free" $null
          heap_min_free = Get-ObjectProperty $j "heap_min_free" $null
          chip_temp_c = Get-ObjectProperty $j "chip_temp_c" $null
          chip_temp_max_c = Get-ObjectProperty $j "chip_temp_max_c" $null
          chip_temp_samples = Get-ObjectProperty $j "chip_temp_samples" $null
          chip_temp_read_failures = Get-ObjectProperty $j "chip_temp_read_failures" $null
          power_telemetry_valid = Test-TrueValue (Get-ObjectProperty $j "power_telemetry_valid" $false)
          power_vbus_mv = Get-ObjectProperty $j "power_vbus_mv" $null
          power_vbus_min_mv = Get-ObjectProperty $j "power_vbus_min_mv" $null
          power_vbus_max_mv = Get-ObjectProperty $j "power_vbus_max_mv" $null
          power_vbus_valid = Test-TrueValue (Get-ObjectProperty $j "power_vbus_valid" $false)
          power_vbus_rejected_samples = Get-ObjectProperty $j "power_vbus_rejected_samples" $null
          power_vbus_last_rejected_mv = Get-ObjectProperty $j "power_vbus_last_rejected_mv" $null
          power_vbus_hard_floor_mv = Get-ObjectProperty $j "power_vbus_hard_floor_mv" $null
          power_vbus_floor_valid_samples = Get-ObjectProperty $j "power_vbus_floor_valid_samples" $null
          power_vbus_floor_min_mv = Get-ObjectProperty $j "power_vbus_floor_min_mv" $null
          power_vbus_hard_floor_samples = Get-ObjectProperty $j "power_vbus_hard_floor_samples" $null
          power_vbus_hard_floor_confirmed_samples = Get-ObjectProperty $j "power_vbus_hard_floor_confirmed_samples" $null
          power_vbus_hard_floor_unconfirmed_samples = Get-ObjectProperty $j "power_vbus_hard_floor_unconfirmed_samples" $null
          power_vbus_hard_floor_entries = Get-ObjectProperty $j "power_vbus_hard_floor_entries" $null
          power_vbus_hard_floor_consecutive_samples = Get-ObjectProperty $j "power_vbus_hard_floor_consecutive_samples" $null
          power_vbus_hard_floor_max_consecutive_samples = Get-ObjectProperty $j "power_vbus_hard_floor_max_consecutive_samples" $null
          power_vbus_hard_floor_last_at_ms = Get-ObjectProperty $j "power_vbus_hard_floor_last_at_ms" $null
          power_vbus_hard_floor_last_mv = Get-ObjectProperty $j "power_vbus_hard_floor_last_mv" $null
          power_vbus_hard_floor_last_confirm_mv = Get-ObjectProperty $j "power_vbus_hard_floor_last_confirm_mv" $null
          power_vbus_hard_floor_last_battery_mv = Get-ObjectProperty $j "power_vbus_hard_floor_last_battery_mv" $null
          power_vbus_hard_floor_last_confirm_battery_mv = Get-ObjectProperty $j "power_vbus_hard_floor_last_confirm_battery_mv" $null
          power_vbus_hard_floor_last_body_power_valid = Test-TrueValue (Get-ObjectProperty $j "power_vbus_hard_floor_last_body_power_valid" $false)
          power_vbus_hard_floor_last_body_bus_v = Get-ObjectProperty $j "power_vbus_hard_floor_last_body_bus_v" $null
          power_vbus_hard_floor_last_body_current_ma = Get-ObjectProperty $j "power_vbus_hard_floor_last_body_current_ma" $null
          power_vbus_hard_floor_last_motion_requested = Test-TrueValue (Get-ObjectProperty $j "power_vbus_hard_floor_last_motion_requested" $false)
          power_vbus_hard_floor_last_servo_rail_enabled = Test-TrueValue (Get-ObjectProperty $j "power_vbus_hard_floor_last_servo_rail_enabled" $false)
          power_vbus_hard_floor_last_servo_torque_enabled = Test-TrueValue (Get-ObjectProperty $j "power_vbus_hard_floor_last_servo_torque_enabled" $false)
          power_vbus_hard_floor_last_speaker_power_active = Test-TrueValue (Get-ObjectProperty $j "power_vbus_hard_floor_last_speaker_power_active" $false)
          power_vbus_hard_floor_last_pmic_input_current_limited = Test-TrueValue (Get-ObjectProperty $j "power_vbus_hard_floor_last_pmic_input_current_limited" $false)
          power_vbus_hard_floor_last_pmic_vindpm_active = Test-TrueValue (Get-ObjectProperty $j "power_vbus_hard_floor_last_pmic_vindpm_active" $false)
          power_vbus_hard_floor_last_pmic_battery_discharging = Test-TrueValue (Get-ObjectProperty $j "power_vbus_hard_floor_last_pmic_battery_discharging" $false)
          power_vbus_hard_floor_last_pmic_vsys_valid = Test-TrueValue (Get-ObjectProperty $j "power_vbus_hard_floor_last_pmic_vsys_valid" $false)
          power_vbus_hard_floor_last_pmic_vsys_mv = Get-ObjectProperty $j "power_vbus_hard_floor_last_pmic_vsys_mv" $null
          power_pmic_vbus_present = Get-ObjectProperty $j "power_pmic_vbus_present" $null
          power_pmic_vbus_transitions = Get-ObjectProperty $j "power_pmic_vbus_transitions" $null
          power_pmic_vbus_loss_entries = Get-ObjectProperty $j "power_pmic_vbus_loss_entries" $null
          power_pmic_temp_c = Get-ObjectProperty $j "power_pmic_temp_c" $null
          power_pmic_input_state_valid = Test-TrueValue (Get-ObjectProperty $j "power_pmic_input_state_valid" $false)
          compiled_enable_pmic_input_telemetry = Get-ObjectProperty $j "compiled_enable_pmic_input_telemetry" $null
          power_pmic_input_current_limited = Test-TrueValue (Get-ObjectProperty $j "power_pmic_input_current_limited" $false)
          power_pmic_input_current_limit_samples = Get-ObjectProperty $j "power_pmic_input_current_limit_samples" $null
          power_pmic_input_current_limit_entries = Get-ObjectProperty $j "power_pmic_input_current_limit_entries" $null
          power_pmic_vindpm_active = Test-TrueValue (Get-ObjectProperty $j "power_pmic_vindpm_active" $false)
          power_pmic_vindpm_samples = Get-ObjectProperty $j "power_pmic_vindpm_samples" $null
          power_pmic_vindpm_entries = Get-ObjectProperty $j "power_pmic_vindpm_entries" $null
          power_pmic_battery_direction = Get-ObjectProperty $j "power_pmic_battery_direction" $null
          power_pmic_battery_supplement_samples = Get-ObjectProperty $j "power_pmic_battery_supplement_samples" $null
          power_pmic_battery_supplement_entries = Get-ObjectProperty $j "power_pmic_battery_supplement_entries" $null
          power_pmic_input_state_read_failures = Get-ObjectProperty $j "power_pmic_input_state_read_failures" $null
          power_pmic_config_valid = Test-TrueValue (Get-ObjectProperty $j "power_pmic_config_valid" $false)
          power_pmic_vindpm_target_mv = Get-ObjectProperty $j "power_pmic_vindpm_target_mv" $null
          power_pmic_vindpm_configured = Test-TrueValue (Get-ObjectProperty $j "power_pmic_vindpm_configured" $false)
          power_pmic_vindpm_config_mv = Get-ObjectProperty $j "power_pmic_vindpm_config_mv" $null
          power_pmic_input_current_limit_config_ma = Get-ObjectProperty $j "power_pmic_input_current_limit_config_ma" $null
          power_pmic_config_read_failures = Get-ObjectProperty $j "power_pmic_config_read_failures" $null
          power_vsys_valid = Test-TrueValue (Get-ObjectProperty $j "power_vsys_valid" $false)
          power_vsys_mv = Get-ObjectProperty $j "power_vsys_mv" $null
          power_vsys_min_mv = Get-ObjectProperty $j "power_vsys_min_mv" $null
          power_vsys_max_mv = Get-ObjectProperty $j "power_vsys_max_mv" $null
          power_vsys_read_failures = Get-ObjectProperty $j "power_vsys_read_failures" $null
          power_forensics_enabled = Test-TrueValue (Get-ObjectProperty $j "power_forensics_enabled" $false)
          power_forensics_schema = [string](Get-ObjectProperty $j "power_forensics_schema" "")
          power_forensics_irq_enable_succeeded = Test-TrueValue (Get-ObjectProperty $j "power_forensics_irq_enable_succeeded" $false)
          power_forensics_boot_status_valid = Test-TrueValue (Get-ObjectProperty $j "power_forensics_boot_status_valid" $false)
          power_forensics_boot_event_mask = Get-ObjectProperty $j "power_forensics_boot_event_mask" $null
          power_forensics_boot_event = Get-ObjectProperty $j "power_forensics_boot_event" $null
          power_forensics_boot_protective = Test-TrueValue (Get-ObjectProperty $j "power_forensics_boot_protective" $false)
          power_forensics_runtime_event_polls = Get-ObjectProperty $j "power_forensics_runtime_event_polls" $null
          power_forensics_runtime_protective_event_polls = Get-ObjectProperty $j "power_forensics_runtime_protective_event_polls" $null
          power_forensics_read_failures = Get-ObjectProperty $j "power_forensics_read_failures" $null
          power_forensics_clear_failures = Get-ObjectProperty $j "power_forensics_clear_failures" $null
          power_forensics_last_event_mask = Get-ObjectProperty $j "power_forensics_last_event_mask" $null
          power_forensics_last_event = Get-ObjectProperty $j "power_forensics_last_event" $null
          power_forensics_last_event_at_ms = Get-ObjectProperty $j "power_forensics_last_event_at_ms" $null
          power_forensics_last_protective_event_mask = Get-ObjectProperty $j "power_forensics_last_protective_event_mask" $null
          power_forensics_last_protective_event = Get-ObjectProperty $j "power_forensics_last_protective_event" $null
          power_forensics_last_protective_event_at_ms = Get-ObjectProperty $j "power_forensics_last_protective_event_at_ms" $null
          power_forensics_battery_overvoltage_last_at_ms = Get-ObjectProperty $j "power_forensics_battery_overvoltage_last_at_ms" $null
          power_forensics_vbus_remove_events = Get-ObjectProperty $j "power_forensics_vbus_remove_events" $null
          power_forensics_battery_remove_events = Get-ObjectProperty $j "power_forensics_battery_remove_events" $null
          power_forensics_warning_level2_events = Get-ObjectProperty $j "power_forensics_warning_level2_events" $null
          power_forensics_batfet_overcurrent_events = Get-ObjectProperty $j "power_forensics_batfet_overcurrent_events" $null
          power_forensics_ldo_overcurrent_events = Get-ObjectProperty $j "power_forensics_ldo_overcurrent_events" $null
          power_forensics_die_overtemperature_events = Get-ObjectProperty $j "power_forensics_die_overtemperature_events" $null
          power_forensics_watchdog_expire_events = Get-ObjectProperty $j "power_forensics_watchdog_expire_events" $null
          power_forensics_power_key_long_press_events = Get-ObjectProperty $j "power_forensics_power_key_long_press_events" $null
          power_forensics_last_vbus_mv = Get-ObjectProperty $j "power_forensics_last_vbus_mv" $null
          power_forensics_last_battery_mv = Get-ObjectProperty $j "power_forensics_last_battery_mv" $null
          power_forensics_last_motion_requested = Test-TrueValue (Get-ObjectProperty $j "power_forensics_last_motion_requested" $false)
          power_forensics_last_servo_rail_enabled = Test-TrueValue (Get-ObjectProperty $j "power_forensics_last_servo_rail_enabled" $false)
          power_forensics_last_servo_torque_enabled = Test-TrueValue (Get-ObjectProperty $j "power_forensics_last_servo_torque_enabled" $false)
          power_forensics_last_speaker_power_active = Test-TrueValue (Get-ObjectProperty $j "power_forensics_last_speaker_power_active" $false)
          debug_response_truncated = Test-TrueValue (Get-ObjectProperty $j "debug_response_truncated" $true)
          compiled_enable_body_rgb = Get-ObjectProperty $j "compiled_enable_body_rgb" $null
          body_rgb_ready = Test-TrueValue (Get-ObjectProperty $j "body_rgb_ready" $false)
          body_rgb_frames = Get-ObjectProperty $j "body_rgb_frames" $null
          body_rgb_write_retries = Get-ObjectProperty $j "body_rgb_write_retries" $null
          body_rgb_write_recoveries = Get-ObjectProperty $j "body_rgb_write_recoveries" $null
          body_rgb_write_failures = Get-ObjectProperty $j "body_rgb_write_failures" $null
          compiled_enable_body_touch = Get-ObjectProperty $j "compiled_enable_body_touch" $null
          body_touch_ready = Test-TrueValue (Get-ObjectProperty $j "body_touch_ready" $false)
          body_touch_samples = Get-ObjectProperty $j "body_touch_samples" $null
          body_touch_read_failures = Get-ObjectProperty $j "body_touch_read_failures" $null
          body_touch_events = Get-ObjectProperty $j "body_touch_events" $null
          compiled_enable_imu = Get-ObjectProperty $j "compiled_enable_imu" $null
          imu_ready = Test-TrueValue (Get-ObjectProperty $j "imu_ready" $false)
          imu_calibrated = Test-TrueValue (Get-ObjectProperty $j "imu_calibrated" $false)
          imu_samples = Get-ObjectProperty $j "imu_samples" $null
          imu_read_retries = Get-ObjectProperty $j "imu_read_retries" $null
          imu_read_recoveries = Get-ObjectProperty $j "imu_read_recoveries" $null
          imu_read_failures = Get-ObjectProperty $j "imu_read_failures" $null
          imu_events = Get-ObjectProperty $j "imu_events" $null
          imu_self_motion_events = Get-ObjectProperty $j "imu_self_motion_events" $null
          imu_external_events = Get-ObjectProperty $j "imu_external_events" $null
          imu_last_event_ms = Get-ObjectProperty $j "imu_last_event_ms" $null
          imu_last_event_type = Get-ObjectProperty $j "imu_last_event_type" $null
          imu_last_event_self_motion = Test-TrueValue (Get-ObjectProperty $j "imu_last_event_self_motion" $false)
          imu_last_event_strength = Get-ObjectProperty $j "imu_last_event_strength" $null
          imu_last_event_jerk = Get-ObjectProperty $j "imu_last_event_jerk" $null
          imu_last_event_accel_norm = Get-ObjectProperty $j "imu_last_event_accel_norm" $null
          imu_last_event_gyro_norm = Get-ObjectProperty $j "imu_last_event_gyro_norm" $null
          compiled_enable_camera = Get-ObjectProperty $j "compiled_enable_camera" $null
          compiled_enable_camera_host_vision = Get-ObjectProperty $j "compiled_enable_camera_host_vision" $null
          camera_ready = Test-TrueValue (Get-ObjectProperty $j "camera_ready" $false)
          camera_active = Test-TrueValue (Get-ObjectProperty $j "camera_active" $false)
          camera_capture_ready = Test-TrueValue (Get-ObjectProperty $j "camera_capture_ready" $false)
          camera_frames_captured = Get-ObjectProperty $j "camera_frames_captured" $null
          camera_capture_failures = Get-ObjectProperty $j "camera_capture_failures" $null
          camera_last_capture_us = Get-ObjectProperty $j "camera_last_capture_us" $null
          camera_max_capture_us = Get-ObjectProperty $j "camera_max_capture_us" $null
          camera_host_frame_requests = Get-ObjectProperty $j "camera_host_frame_requests" $null
          camera_host_frame_failures = Get-ObjectProperty $j "camera_host_frame_failures" $null
          camera_host_capture_failures = Get-ObjectProperty $j "camera_host_capture_failures" $null
          camera_host_response_write_attempts = Get-ObjectProperty $j "camera_host_response_write_attempts" $null
          camera_host_response_write_successes = Get-ObjectProperty $j "camera_host_response_write_successes" $null
          camera_host_response_write_failures = Get-ObjectProperty $j "camera_host_response_write_failures" $null
          camera_host_response_write_consecutive_failures = Get-ObjectProperty $j "camera_host_response_write_consecutive_failures" $null
          camera_host_response_write_max_consecutive_failures = Get-ObjectProperty $j "camera_host_response_write_max_consecutive_failures" $null
          camera_host_target_updates = Get-ObjectProperty $j "camera_host_target_updates" $null
          camera_host_auth_failures = Get-ObjectProperty $j "camera_host_auth_failures" $null
          power_battery_mv = Get-ObjectProperty $j "power_battery_mv" $null
          power_battery_min_mv = Get-ObjectProperty $j "power_battery_min_mv" $null
          power_battery_max_mv = Get-ObjectProperty $j "power_battery_max_mv" $null
          power_battery_level = Get-ObjectProperty $j "power_battery_level" $null
          power_charging_state = Get-ObjectProperty $j "power_charging_state" $null
          power_samples = Get-ObjectProperty $j "power_samples" $null
          power_read_failures = Get-ObjectProperty $j "power_read_failures" $null
          body_power_telemetry_valid = Test-TrueValue (Get-ObjectProperty $j "body_power_telemetry_valid" $false)
          body_power_bus_v = Get-ObjectProperty $j "body_power_bus_v" $null
          body_power_bus_min_v = Get-ObjectProperty $j "body_power_bus_min_v" $null
          body_power_bus_max_v = Get-ObjectProperty $j "body_power_bus_max_v" $null
          body_power_current_ma = Get-ObjectProperty $j "body_power_current_ma" $null
          body_power_mw = Get-ObjectProperty $j "body_power_mw" $null
          body_battery_power_flow = Get-ObjectProperty $j "body_battery_power_flow" $null
          power_coordinator_present = $null -ne $j.PSObject.Properties["power_mode"]
          power_mode = Get-ObjectProperty $j "power_mode" $null
          power_reason = Get-ObjectProperty $j "power_reason" $null
          power_motion_requested = Test-TrueValue (Get-ObjectProperty $j "power_motion_requested" $false)
          power_motion_allowed = Test-TrueValue (Get-ObjectProperty $j "power_motion_allowed" $false)
          power_servo_rail_allowed = Test-TrueValue (Get-ObjectProperty $j "power_servo_rail_allowed" $false)
          power_charge_current_ma = Get-ObjectProperty $j "power_charge_current_ma" $null
          power_charge_current_low_input_ma = Get-ObjectProperty $j "power_charge_current_low_input_ma" $null
          power_charge_current_desired_ma = Get-ObjectProperty $j "power_charge_current_desired_ma" $null
          power_charge_derated = Test-TrueValue (Get-ObjectProperty $j "power_charge_derated" $false)
          power_charge_derate_reason = Get-ObjectProperty $j "power_charge_derate_reason" $null
          power_charge_derate_hold_active = Test-TrueValue (Get-ObjectProperty $j "power_charge_derate_hold_active" $false)
          power_charge_derate_hold_remaining_ms = Get-ObjectProperty $j "power_charge_derate_hold_remaining_ms" $null
          servo_power_allowed = Test-TrueValue (Get-ObjectProperty $j "servo_power_allowed" $false)
          servo_rail_enabled = Test-TrueValue (Get-ObjectProperty $j "servo_rail_enabled" $false)
          servo_torque_enabled = Test-TrueValue (Get-ObjectProperty $j "servo_torque_enabled" $false)
          speaker_power_active = Test-TrueValue (Get-ObjectProperty $j "speaker_power_active" $false)
          network = [string](Get-ObjectProperty $j "network_state" "")
          network_error = Get-ObjectProperty $j "network_error" $null
          network_config_source = Get-ObjectProperty $j "network_config_source" $null
          network_bridge_port = Get-ObjectProperty $j "network_bridge_port" $null
          network_tcp_connect_attempts = Get-ObjectProperty $j "network_tcp_connect_attempts" $null
          network_tcp_connect_last_result = Get-ObjectProperty $j "network_tcp_connect_last_result" $null
          network_tcp_connect_last_errno = Get-ObjectProperty $j "network_tcp_connect_last_errno" $null
          network_tcp_connect_last_duration_ms = Get-ObjectProperty $j "network_tcp_connect_last_duration_ms" $null
          network_tcp_connect_max_duration_ms = Get-ObjectProperty $j "network_tcp_connect_max_duration_ms" $null
          bridge = [string](Get-ObjectProperty $j "bridge_state" "")
          fps = Get-ObjectProperty $j "display_window_fps" $null
          max_us = Get-ObjectProperty $j "display_window_max_frame_us" $null
          slow = Get-ObjectProperty $j "display_window_slow_frames" $null
          display_last_dirty_pixels = Get-ObjectProperty $j "display_last_dirty_pixels" $null
          display_window_max_dirty_pixels = Get-ObjectProperty $j "display_window_max_dirty_pixels" $null
          display_window_max_frame_dirty_pixels = Get-ObjectProperty $j "display_window_max_frame_dirty_pixels" $null
          display_last_dirty_regions = Get-ObjectProperty $j "display_last_dirty_regions" $null
          wake_ready = Test-TrueValue (Get-ObjectProperty $j "sr_wake_sr_ready" $false)
          mic_ready = Test-TrueValue (Get-ObjectProperty $j "sr_wake_mic_ready" $false)
          speaker_ready = $speakerEnabled -and $null -ne $speakerVolume -and [int]$speakerVolume -gt 0
          speaker_enabled = $speakerEnabled
          speaker_volume = $speakerVolume
          speaker_channel_state = Get-ObjectProperty $j "speaker_channel_state" $null
          speaker_tone_ok = Get-ObjectProperty $j "speaker_tone_ok" $null
          bridge_downlink_playback_errors = Get-ObjectProperty $j "bridge_downlink_playback_errors" $null
          uplink_errors = Get-ObjectProperty $j "bridge_uplink_errors" $null
          rvc_worker_ready = if ($latestRvcWorkerHealth -ne $null) { [bool]$latestRvcWorkerHealth.ready } else { $null }
          socket_remote = $socketRemote
          serial_present = $serialPortPresent
        })
      } else {
        $records.Add([pscustomobject]@{
          t_s = $elapsed
          ok = $false
          curl_exit = $poll.curlExit
          error = $poll.error
          socket_remote = $socketRemote
          serial_present = $serialPortPresent
        })
      }

      if ($records.Count -gt 0 -and $records[$records.Count - 1].ok -and $null -eq $pmicVbusLossBaseline) {
        $pmicVbusLossBaseline = $records[$records.Count - 1].power_pmic_vbus_loss_entries
      }
      if ($records.Count -gt 0 -and $records[$records.Count - 1].ok -and
          $null -eq $powerVbusHardFloorEntriesBaseline) {
        $powerVbusHardFloorEntriesBaseline = $records[$records.Count - 1].power_vbus_hard_floor_entries
      }
      if ($records.Count -gt 0 -and $records[$records.Count - 1].ok -and
          $null -eq $powerForensicsRuntimeEventsBaseline) {
        $powerForensicsRuntimeEventsBaseline = $records[$records.Count - 1].power_forensics_runtime_event_polls
        $powerForensicsProtectiveEventsBaseline = $records[$records.Count - 1].power_forensics_runtime_protective_event_polls
        $powerForensicsReadFailuresBaseline = $records[$records.Count - 1].power_forensics_read_failures
        $powerForensicsClearFailuresBaseline = $records[$records.Count - 1].power_forensics_clear_failures
      }
      if ($records.Count -gt 0 -and $records[$records.Count - 1].ok -and
          $null -eq $pmicInputStateReadFailuresBaseline) {
        $pmicInputStateReadFailuresBaseline = $records[$records.Count - 1].power_pmic_input_state_read_failures
        $pmicConfigReadFailuresBaseline = $records[$records.Count - 1].power_pmic_config_read_failures
        $powerVsysReadFailuresBaseline = $records[$records.Count - 1].power_vsys_read_failures
      }
      if ($records.Count -gt 0 -and $records[$records.Count - 1].ok -and
          $null -eq $bodyRgbWriteFailuresBaseline) {
        $bodyRgbWriteFailuresBaseline = $records[$records.Count - 1].body_rgb_write_failures
        $bodyRgbWriteRetriesBaseline = $records[$records.Count - 1].body_rgb_write_retries
        $bodyRgbWriteRecoveriesBaseline = $records[$records.Count - 1].body_rgb_write_recoveries
        $bodyTouchReadFailuresBaseline = $records[$records.Count - 1].body_touch_read_failures
        $imuReadRetriesBaseline = $records[$records.Count - 1].imu_read_retries
        $imuReadRecoveriesBaseline = $records[$records.Count - 1].imu_read_recoveries
        $imuReadFailuresBaseline = $records[$records.Count - 1].imu_read_failures
        $imuEventsBaseline = $records[$records.Count - 1].imu_events
        $imuSelfMotionEventsBaseline = $records[$records.Count - 1].imu_self_motion_events
        $imuExternalEventsBaseline = $records[$records.Count - 1].imu_external_events
        $cameraCaptureFailuresBaseline = $records[$records.Count - 1].camera_capture_failures
        $cameraHostFrameFailuresBaseline = $records[$records.Count - 1].camera_host_frame_failures
        $cameraHostCaptureFailuresBaseline = $records[$records.Count - 1].camera_host_capture_failures
        $cameraHostResponseWriteAttemptsBaseline = $records[$records.Count - 1].camera_host_response_write_attempts
        $cameraHostResponseWriteFailuresBaseline = $records[$records.Count - 1].camera_host_response_write_failures
        $cameraHostAuthFailuresBaseline = $records[$records.Count - 1].camera_host_auth_failures
      }

      $progress = [ordered]@{
        schema = "stackchan.full-system-soak-progress.v1"
        startedAt = $startedAt.ToString("o")
        updatedAt = (Get-Date).ToString("o")
        durationSeconds = $DurationSeconds
        elapsedSeconds = [math]::Round((([DateTime]::UtcNow - $startUtc).TotalSeconds), 1)
        records = $records.Count
        failedPolls = @($records | Where-Object { -not $_.ok }).Count
        failedPollRatio = Get-FailedPollRatio -Records $records
        motionSamples = @($records | Where-Object { $_.ok -and $_.motion }).Count
        motionUnsuppressedSamples = @($records | Where-Object { $_.ok -and $_.motion -and -not $_.motion_output_suppressed }).Count
        motionDutyRestSamples = @($records | Where-Object { $_.ok -and $_.motion_duty_resting }).Count
        motionOutputSuppressSamples = @($records | Where-Object { $_.ok -and $_.motion_output_suppressed }).Count
        motionPowerSuppressSamples = @($records | Where-Object { $_.ok -and $_.motion_power_suppressed }).Count
        maxMotionDutyRestEntries = if (@($records | Where-Object { $_.ok -and $null -ne $_.motion_duty_rest_entries }).Count -gt 0) {
          (@($records | Where-Object { $_.ok -and $null -ne $_.motion_duty_rest_entries }) |
            Measure-Object -Property motion_duty_rest_entries -Maximum).Maximum
        } else { $null }
        maxMotionOutputSuppressEntries = if (@($records | Where-Object { $_.ok -and $null -ne $_.motion_output_suppress_entries }).Count -gt 0) {
          (@($records | Where-Object { $_.ok -and $null -ne $_.motion_output_suppress_entries }) |
            Measure-Object -Property motion_output_suppress_entries -Maximum).Maximum
        } else { $null }
        maxChipTempC = if (@($records | Where-Object { $_.ok -and $null -ne $_.chip_temp_c }).Count -gt 0) {
          (@($records | Where-Object { $_.ok -and $null -ne $_.chip_temp_c }) |
            Measure-Object -Property chip_temp_c -Maximum).Maximum
        } else { $null }
        maxMotionThermalSuppressEntries = if (@($records | Where-Object { $_.ok -and $null -ne $_.motion_thermal_suppress_entries }).Count -gt 0) {
          (@($records | Where-Object { $_.ok -and $null -ne $_.motion_thermal_suppress_entries }) |
            Measure-Object -Property motion_thermal_suppress_entries -Maximum).Maximum
        } else { $null }
        maxMotionPowerSuppressEntries = if (@($records | Where-Object { $_.ok -and $null -ne $_.motion_power_suppress_entries }).Count -gt 0) {
          (@($records | Where-Object { $_.ok -and $null -ne $_.motion_power_suppress_entries }) |
            Measure-Object -Property motion_power_suppress_entries -Maximum).Maximum
        } else { $null }
        latestChipTempC = if ($records.Count -gt 0 -and $records[$records.Count - 1].ok) {
          $records[$records.Count - 1].chip_temp_c
        } else { $null }
        powerTelemetrySamples = @($records | Where-Object { $_.ok -and $_.power_telemetry_valid }).Count
        minPowerVbusMv = if (@($records | Where-Object { $_.ok -and $null -ne $_.power_vbus_mv -and [int]$_.power_vbus_mv -ge 0 }).Count -gt 0) {
          (@($records | Where-Object { $_.ok -and $null -ne $_.power_vbus_mv -and [int]$_.power_vbus_mv -ge 0 }) |
            Measure-Object -Property power_vbus_mv -Minimum).Minimum
        } else { $null }
        minPowerVbusReportedMv = if (@($records | Where-Object { $_.ok -and $null -ne $_.power_vbus_min_mv -and [int]$_.power_vbus_min_mv -gt 0 }).Count -gt 0) {
          (@($records | Where-Object { $_.ok -and $null -ne $_.power_vbus_min_mv -and [int]$_.power_vbus_min_mv -gt 0 }) |
            Measure-Object -Property power_vbus_min_mv -Minimum).Minimum
        } else { $null }
        powerVbusHardFloorEntriesBaseline = $powerVbusHardFloorEntriesBaseline
        latestPowerVbusHardFloorEntries = if ($records.Count -gt 0 -and $records[$records.Count - 1].ok) {
          $records[$records.Count - 1].power_vbus_hard_floor_entries
        } else { $null }
        newPowerVbusHardFloorEntries = if ($records.Count -gt 0 -and $records[$records.Count - 1].ok -and
            $null -ne $powerVbusHardFloorEntriesBaseline -and
            $null -ne $records[$records.Count - 1].power_vbus_hard_floor_entries) {
          [int64]$records[$records.Count - 1].power_vbus_hard_floor_entries -
            [int64]$powerVbusHardFloorEntriesBaseline
        } else { $null }
        latestPowerVbusMv = if ($records.Count -gt 0 -and $records[$records.Count - 1].ok) {
          $records[$records.Count - 1].power_vbus_mv
        } else { $null }
        latestPowerBatteryMv = if ($records.Count -gt 0 -and $records[$records.Count - 1].ok) {
          $records[$records.Count - 1].power_battery_mv
        } else { $null }
        pmicInputTelemetrySamples = @($records | Where-Object { $_.ok -and $_.power_pmic_input_state_valid }).Count
        pmicInputStateReadFailuresBaseline = $pmicInputStateReadFailuresBaseline
        pmicConfigReadFailuresBaseline = $pmicConfigReadFailuresBaseline
        powerVsysReadFailuresBaseline = $powerVsysReadFailuresBaseline
        maxPmicInputCurrentLimitEntries = if (@($records | Where-Object { $_.ok -and $null -ne $_.power_pmic_input_current_limit_entries }).Count -gt 0) {
          (@($records | Where-Object { $_.ok -and $null -ne $_.power_pmic_input_current_limit_entries }) |
            Measure-Object -Property power_pmic_input_current_limit_entries -Maximum).Maximum
        } else { $null }
        maxPmicVindpmEntries = if (@($records | Where-Object { $_.ok -and $null -ne $_.power_pmic_vindpm_entries }).Count -gt 0) {
          (@($records | Where-Object { $_.ok -and $null -ne $_.power_pmic_vindpm_entries }) |
            Measure-Object -Property power_pmic_vindpm_entries -Maximum).Maximum
        } else { $null }
        maxPmicBatterySupplementEntries = if (@($records | Where-Object { $_.ok -and $null -ne $_.power_pmic_battery_supplement_entries }).Count -gt 0) {
          (@($records | Where-Object { $_.ok -and $null -ne $_.power_pmic_battery_supplement_entries }) |
            Measure-Object -Property power_pmic_battery_supplement_entries -Maximum).Maximum
        } else { $null }
        minPowerVsysMv = if (@($records | Where-Object { $_.ok -and $_.power_vsys_valid -and $null -ne $_.power_vsys_mv }).Count -gt 0) {
          (@($records | Where-Object { $_.ok -and $_.power_vsys_valid -and $null -ne $_.power_vsys_mv }) |
            Measure-Object -Property power_vsys_mv -Minimum).Minimum
        } else { $null }
        bridgeReadySamples = @($records | Where-Object { $_.ok -and $_.bridge -eq "ready" }).Count
        bridgeHealthySamples = @($records | Where-Object { $_.ok -and (Test-BridgeHealthyState $_.bridge) }).Count
        socketPresentSamples = @($records | Where-Object { $_.socket_remote }).Count
        serialPresentSamples = @($records | Where-Object { $_.serial_present }).Count
        wakeReadySamples = @($records | Where-Object { $_.ok -and $_.wake_ready }).Count
        micReadySamples = @($records | Where-Object { $_.ok -and $_.mic_ready }).Count
        micReadyRequiredSamples = @($records | Where-Object { Test-MicReadyRequired $_ }).Count
        micReadyRequiredReadySamples = @($records | Where-Object { (Test-MicReadyRequired $_) -and $_.mic_ready }).Count
        speakerReadySamples = @($records | Where-Object { $_.ok -and $_.speaker_ready }).Count
        bodyRgbReadySamples = @($records | Where-Object { $_.ok -and $_.body_rgb_ready }).Count
        bodyTouchReadySamples = @($records | Where-Object { $_.ok -and $_.body_touch_ready }).Count
        imuReadySamples = @($records | Where-Object { $_.ok -and $_.imu_ready -and $_.imu_calibrated }).Count
        cameraCaptureReadySamples = @($records | Where-Object { $_.ok -and $_.camera_capture_ready }).Count
        motionRefreshes = $motionRefreshes
        motionRefreshFailures = $motionRefreshFailures
        rvcWorkerPolls = $rvcWorkerPolls
        rvcWorkerReadySamples = $rvcWorkerReadySamples
        maxConsecutiveFailedPolls = Get-MaxConsecutiveFailedPolls -Records $records
        latestRvcWorkerHealth = $latestRvcWorkerHealth
        latest = if ($records.Count -gt 0) { $records[$records.Count - 1] } else { $null }
      }
      Write-JsonWithRetry -Path $progressPath -Value $progress
      Write-JsonWithRetry -Path $pollPath -Value $records
      if ($FailFastOnStrictBreach) {
        $currentFailedPolls = @($records | Where-Object { -not $_.ok }).Count
        $currentMaxConsecutiveFailedPolls = Get-MaxConsecutiveFailedPolls -Records $records
        if ($currentMaxConsecutiveFailedPolls -gt $MaxConsecutiveFailedPolls) {
          $abortReason = "consecutive_failed_poll_limit_exceeded"
          break
        }
        if ($MaxFailedPolls -gt 0 -and $currentFailedPolls -gt $MaxFailedPolls) {
          $abortReason = "failed_poll_limit_exceeded"
          break
        }
        $currentFailedPollRatio = Get-FailedPollRatio -Records $records
        if ($MaxFailedPollRatio -gt 0 -and
            $records.Count -ge $MinPollsForFailedRatio -and
            $currentFailedPollRatio -gt $MaxFailedPollRatio) {
          $abortReason = "failed_poll_ratio_exceeded"
          break
        }
        if ($MotionRefreshSeconds -gt 0 -and $motionRefreshFailures -gt 0) {
          $abortReason = "motion_refresh_failed"
          break
        }
        if ($RequireNoMotionTimeouts) {
          $currentTimeoutRecords = @($records | Where-Object { $_.ok -and $null -ne $_.motion_session_timeouts })
          if ($currentTimeoutRecords.Count -gt 0) {
            $currentMaxMotionSessionTimeouts =
                ($currentTimeoutRecords | Measure-Object -Property motion_session_timeouts -Maximum).Maximum
            if ($null -ne $currentMaxMotionSessionTimeouts -and [int64]$currentMaxMotionSessionTimeouts -gt 0) {
              $abortReason = "motion_session_timeout_observed"
              break
            }
          }
        }
        if ($MaxAllowedChipTempC -gt 0) {
          $currentChipTempRecords = @($records | Where-Object { $_.ok -and $null -ne $_.chip_temp_c })
          if ($currentChipTempRecords.Count -gt 0) {
            $currentMaxChipTempC = ($currentChipTempRecords | Measure-Object -Property chip_temp_c -Maximum).Maximum
            if ($null -ne $currentMaxChipTempC -and [double]$currentMaxChipTempC -gt $MaxAllowedChipTempC) {
              $abortReason = "chip_temp_limit_exceeded"
              break
            }
          }
        }
        if ($minPowerVbusReportedMvThreshold -gt 0) {
          $currentPowerRecords = @($records | Where-Object { $_.ok -and $null -ne $_.power_vbus_min_mv -and [int]$_.power_vbus_min_mv -gt 0 })
          if ($currentPowerRecords.Count -gt 0) {
            $currentMinPowerVbusReportedMv = ($currentPowerRecords | Measure-Object -Property power_vbus_min_mv -Minimum).Minimum
            if ($null -ne $currentMinPowerVbusReportedMv -and [int]$currentMinPowerVbusReportedMv -lt $minPowerVbusReportedMvThreshold) {
              $abortReason = "power_vbus_floor_exceeded"
              break
            }
          }
        }
        if ($minPowerVbusMvThreshold -gt 0) {
          $currentPowerRecords = @($records | Where-Object { $_.ok -and $null -ne $_.power_vbus_mv -and [int]$_.power_vbus_mv -ge 0 })
          if ($currentPowerRecords.Count -gt 0) {
            $currentMinPowerVbusMv = ($currentPowerRecords | Measure-Object -Property power_vbus_mv -Minimum).Minimum
            if ($null -ne $currentMinPowerVbusMv -and [int]$currentMinPowerVbusMv -lt $minPowerVbusMvThreshold) {
              $abortReason = "power_vbus_sample_floor_exceeded"
              break
            }
          }
        }
        if ($RequirePowerCoordinator -and $records.Count -gt 0) {
          $latestRecord = $records[$records.Count - 1]
          if ($latestRecord.ok) {
            if (-not $latestRecord.power_coordinator_present) {
              $abortReason = "power_coordinator_telemetry_missing"
              break
            }
            if ($latestRecord.servo_rail_enabled -and -not $latestRecord.power_motion_allowed) {
              $abortReason = "servo_rail_without_motion_grant"
              break
            }
            if ($latestRecord.servo_torque_enabled -and -not $latestRecord.servo_rail_enabled) {
              $abortReason = "servo_torque_without_rail"
              break
            }
            if ($MotionPowerSoftFloorMv -gt 0 -and
                $latestRecord.servo_rail_enabled -and
                $null -ne $latestRecord.power_vbus_mv -and
                [int]$latestRecord.power_vbus_mv -lt $MotionPowerSoftFloorMv -and
                -not $latestRecord.motion_power_charge_backed) {
              $abortReason = "charge_backed_soft_floor_violation"
              break
            }
          }
        }
        if ($RequirePmicVbusStable -and $records.Count -gt 0) {
          $latestRecord = $records[$records.Count - 1]
          if ($latestRecord.ok) {
            if ($null -eq $latestRecord.power_pmic_vbus_present -or
                -not (Test-TrueValue $latestRecord.power_pmic_vbus_present)) {
              $abortReason = "pmic_vbus_not_present"
              break
            }
            if ($null -eq $latestRecord.power_pmic_vbus_loss_entries -or $null -eq $pmicVbusLossBaseline) {
              $abortReason = "pmic_vbus_loss_telemetry_missing"
              break
            }
            if ([int64]$latestRecord.power_pmic_vbus_loss_entries -gt [int64]$pmicVbusLossBaseline) {
              $abortReason = "pmic_vbus_loss_observed"
              break
            }
          }
        }
        if ($RequirePowerForensics -and $records.Count -gt 0) {
          $latestRecord = $records[$records.Count - 1]
          if ($latestRecord.ok) {
            if (-not $latestRecord.power_forensics_enabled -or
                -not $latestRecord.power_forensics_irq_enable_succeeded -or
                -not $latestRecord.power_forensics_boot_status_valid) {
              $abortReason = "power_forensics_not_armed"
              break
            }
            if ($null -eq $latestRecord.power_forensics_runtime_event_polls -or
                $null -eq $powerForensicsRuntimeEventsBaseline -or
                $null -eq $latestRecord.power_forensics_runtime_protective_event_polls -or
                $null -eq $powerForensicsProtectiveEventsBaseline -or
                $null -eq $latestRecord.power_forensics_read_failures -or
                $null -eq $powerForensicsReadFailuresBaseline -or
                $null -eq $latestRecord.power_forensics_clear_failures -or
                $null -eq $powerForensicsClearFailuresBaseline) {
              $abortReason = "power_forensics_telemetry_missing"
              break
            }
            if ([int64]$latestRecord.power_forensics_runtime_event_polls -gt
                [int64]$powerForensicsRuntimeEventsBaseline) {
              $abortReason = "power_forensics_runtime_event_observed"
              break
            }
            if ([int64]$latestRecord.power_forensics_runtime_protective_event_polls -gt
                [int64]$powerForensicsProtectiveEventsBaseline) {
              $abortReason = "power_forensics_protective_event_observed"
              break
            }
            if ([int64]$latestRecord.power_forensics_read_failures -gt
                [int64]$powerForensicsReadFailuresBaseline -or
                [int64]$latestRecord.power_forensics_clear_failures -gt
                [int64]$powerForensicsClearFailuresBaseline) {
              $abortReason = "power_forensics_io_failure_observed"
              break
            }
            if ($ExpectedPmicVindpmMv -gt 0) {
              if (-not $latestRecord.power_pmic_input_state_valid -or
                  -not $latestRecord.power_pmic_config_valid -or
                  -not $latestRecord.power_pmic_vindpm_configured -or
                  [int]$latestRecord.power_pmic_vindpm_target_mv -ne $ExpectedPmicVindpmMv -or
                  [int]$latestRecord.power_pmic_vindpm_config_mv -ne $ExpectedPmicVindpmMv -or
                  -not $latestRecord.power_vsys_valid) {
                $abortReason = "pmic_input_policy_not_applied"
                break
              }
              if ($null -eq $pmicInputStateReadFailuresBaseline -or
                  $null -eq $pmicConfigReadFailuresBaseline -or
                  $null -eq $powerVsysReadFailuresBaseline -or
                  $null -eq $latestRecord.power_pmic_input_state_read_failures -or
                  $null -eq $latestRecord.power_pmic_config_read_failures -or
                  $null -eq $latestRecord.power_vsys_read_failures) {
                $abortReason = "pmic_input_policy_telemetry_missing"
                break
              }
              if ([int64]$latestRecord.power_pmic_input_state_read_failures -gt
                    [int64]$pmicInputStateReadFailuresBaseline -or
                  [int64]$latestRecord.power_pmic_config_read_failures -gt
                    [int64]$pmicConfigReadFailuresBaseline -or
                  [int64]$latestRecord.power_vsys_read_failures -gt
                    [int64]$powerVsysReadFailuresBaseline) {
                $abortReason = "pmic_input_policy_io_failure_observed"
                break
              }
            }
          }
        }
        if ($RequireFinalIntegration -and $records.Count -gt 0) {
          $latestRecord = $records[$records.Count - 1]
          if ($latestRecord.ok) {
            if ($latestRecord.debug_response_truncated -or
                $latestRecord.power_forensics_schema -ne "axp2101-v2") {
              $abortReason = "final_integration_debug_contract_failed"
              break
            }
            if ([int]$latestRecord.compiled_enable_body_rgb -ne 1 -or -not $latestRecord.body_rgb_ready -or
                [int]$latestRecord.compiled_enable_body_touch -ne 1 -or -not $latestRecord.body_touch_ready -or
                [int]$latestRecord.compiled_enable_imu -ne 1 -or -not $latestRecord.imu_ready -or
                -not $latestRecord.imu_calibrated) {
              $abortReason = "final_integration_peripheral_not_ready"
              break
            }
            if ([int]$latestRecord.compiled_enable_camera -ne 1 -or
                [int]$latestRecord.compiled_enable_camera_host_vision -ne 1 -or
                -not $latestRecord.camera_ready -or -not $latestRecord.camera_active -or
                -not $latestRecord.camera_capture_ready) {
              $abortReason = "final_integration_camera_not_ready"
              break
            }
            if ($null -eq $bodyRgbWriteFailuresBaseline -or
                $null -eq $bodyTouchReadFailuresBaseline -or
                $null -eq $imuReadFailuresBaseline -or
                $null -eq $imuEventsBaseline -or
                $null -eq $imuSelfMotionEventsBaseline -or
                $null -eq $imuExternalEventsBaseline) {
              $abortReason = "final_integration_counter_missing"
              break
            }
            if ([int64]$latestRecord.body_rgb_write_failures -gt [int64]$bodyRgbWriteFailuresBaseline -or
                [int64]$latestRecord.body_touch_read_failures -gt [int64]$bodyTouchReadFailuresBaseline -or
                [int64]$latestRecord.imu_read_failures -gt [int64]$imuReadFailuresBaseline) {
              $abortReason = "final_integration_io_failure_observed"
              break
            }
            if ([int64]$latestRecord.imu_external_events -gt [int64]$imuExternalEventsBaseline) {
              $abortReason = "external_imu_event_observed"
              break
            }
          }
        }
        if ($RequireCameraCapture -and $records.Count -gt 0) {
          $latestRecord = $records[$records.Count - 1]
          if ($latestRecord.ok) {
            if ($latestRecord.debug_response_truncated -or
                [int]$latestRecord.compiled_enable_camera -ne 1 -or
                -not $latestRecord.camera_ready -or -not $latestRecord.camera_active -or
                -not $latestRecord.camera_capture_ready) {
              $abortReason = "camera_capture_probe_not_ready"
              break
            }
            if ($null -eq $cameraCaptureFailuresBaseline -or
                [int64]$latestRecord.camera_capture_failures -gt [int64]$cameraCaptureFailuresBaseline) {
              $abortReason = "camera_capture_failure_observed"
              break
            }
            if ($MaxCameraCaptureUs -gt 0 -and $null -ne $latestRecord.camera_max_capture_us -and
                [int64]$latestRecord.camera_max_capture_us -gt $MaxCameraCaptureUs) {
              $abortReason = "camera_capture_time_limit_exceeded"
              break
            }
          }
        }
        if ($RequireCameraHostVision -and $records.Count -gt 0) {
          $latestRecord = $records[$records.Count - 1]
          if ($latestRecord.ok) {
            if ([int]$latestRecord.compiled_enable_camera_host_vision -ne 1) {
              $abortReason = "camera_host_vision_not_compiled"
              break
            }
            if ($null -eq $cameraHostFrameFailuresBaseline -or
                $null -eq $cameraHostCaptureFailuresBaseline -or
                $null -eq $cameraHostResponseWriteAttemptsBaseline -or
                $null -eq $cameraHostResponseWriteFailuresBaseline -or
                $null -eq $cameraHostAuthFailuresBaseline -or
                $null -eq $latestRecord.camera_host_frame_requests -or
                $null -eq $latestRecord.camera_host_target_updates -or
                $null -eq $latestRecord.camera_host_response_write_consecutive_failures -or
                $null -eq $latestRecord.camera_host_response_write_max_consecutive_failures) {
              $abortReason = "camera_host_vision_counter_missing"
              break
            }
            if ([int64]$latestRecord.camera_host_capture_failures -gt [int64]$cameraHostCaptureFailuresBaseline) {
              $abortReason = "camera_host_capture_failure_observed"
              break
            }
            if ([int64]$latestRecord.camera_host_auth_failures -gt [int64]$cameraHostAuthFailuresBaseline) {
              $abortReason = "camera_host_auth_failure_observed"
              break
            }
            $newResponseWriteFailures =
              [int64]$latestRecord.camera_host_response_write_failures -
              [int64]$cameraHostResponseWriteFailuresBaseline
            $newResponseWriteAttempts =
              [int64]$latestRecord.camera_host_response_write_attempts -
              [int64]$cameraHostResponseWriteAttemptsBaseline
            $responseWriteFailureRatio = if ($newResponseWriteAttempts -gt 0) {
              $newResponseWriteFailures / [double]$newResponseWriteAttempts
            } else { 0.0 }
            if ([int64]$latestRecord.camera_host_response_write_consecutive_failures -gt
                $MaxCameraHostResponseWriteConsecutiveFailures -or
                [int64]$latestRecord.camera_host_response_write_max_consecutive_failures -gt
                $MaxCameraHostResponseWriteConsecutiveFailures) {
              $abortReason = "camera_host_response_write_streak_exceeded"
              break
            }
            if ($MaxCameraHostResponseWriteFailures -ge 0 -and
                $newResponseWriteFailures -gt $MaxCameraHostResponseWriteFailures) {
              $abortReason = "camera_host_response_write_failure_limit_exceeded"
              break
            }
            if ($MaxCameraHostResponseWriteFailureRatio -gt 0 -and
                $newResponseWriteAttempts -ge $MinCameraHostResponseWriteAttemptsForRatio -and
                $responseWriteFailureRatio -gt $MaxCameraHostResponseWriteFailureRatio) {
              $abortReason = "camera_host_response_write_failure_ratio_exceeded"
              break
            }
          }
        }
        if ($RequireNoNewHardFloorEvents -and $records.Count -gt 0) {
          $latestRecord = $records[$records.Count - 1]
          if ($latestRecord.ok) {
            if ($null -eq $latestRecord.power_vbus_hard_floor_entries -or
                $null -eq $powerVbusHardFloorEntriesBaseline) {
              $abortReason = "power_vbus_hard_floor_telemetry_missing"
              break
            }
            if ([int64]$latestRecord.power_vbus_hard_floor_entries -gt
                [int64]$powerVbusHardFloorEntriesBaseline) {
              $abortReason = "power_vbus_hard_floor_event_observed"
              break
            }
          }
        }
        if ($RequireManagedChargePolicy -and $records.Count -gt 0) {
          $latestRecord = $records[$records.Count - 1]
          if ($latestRecord.ok -and $latestRecord.power_motion_requested) {
            if ($null -eq $latestRecord.power_charge_current_ma -or
                $null -eq $latestRecord.power_charge_current_low_input_ma -or
                -not $latestRecord.power_charge_derated -or
                [int]$latestRecord.power_charge_current_ma -ne [int]$latestRecord.power_charge_current_low_input_ma) {
              $abortReason = "managed_charge_policy_violation"
              break
            }
          }
        }
        if ($MaxDisplayFrameUs -gt 0) {
          $currentFrameRecords = @($records | Where-Object { $_.ok -and $null -ne $_.max_us })
          if ($currentFrameRecords.Count -gt 0) {
            $currentMaxFrameUs = ($currentFrameRecords | Measure-Object -Property max_us -Maximum).Maximum
            if ($null -ne $currentMaxFrameUs -and [int64]$currentMaxFrameUs -gt $MaxDisplayFrameUs) {
              $abortReason = "display_frame_limit_exceeded"
              break
            }
          }
        }
      }
      $nextPoll = $now.AddSeconds($PollSeconds)
    }

    Start-Sleep -Milliseconds 200
  }
} catch {
  $fatalError = $_
} finally {
  try {
    $motionStopResult = Invoke-VerifiedMotionStop -Attempts $MotionStopAttempts
  } catch {
    $motionStopResult = [pscustomobject]@{
      verified = $false
      attempts = 0
      records = @()
      error = $_.Exception.Message
    }
  }
  if ($serial -ne $null) {
    if ($serial.IsOpen) {
      try {
        $text = $serial.ReadExisting()
        if (-not [string]::IsNullOrEmpty($text)) {
          foreach ($raw in ($text -split "\r?\n")) {
            $line = $raw.Trim()
            if (-not [string]::IsNullOrWhiteSpace($line)) {
              $serialLines.Add("[$((Get-Date).ToString("o"))] $line")
            }
          }
        }
      } catch {
      }
      $serial.Close()
    }
    $serial.Dispose()
  }
}

Write-JsonWithRetry -Path $pollPath -Value $records
$serialLines | Set-Content -LiteralPath $serialPath -Encoding UTF8

$okRecords = @($records | Where-Object { $_.ok })
$firstOkRecord = $okRecords | Select-Object -First 1
$latestOkRecord = $okRecords | Select-Object -Last 1
$finalIntegrationReadySamples = @($okRecords | Where-Object {
    -not $_.debug_response_truncated -and
    $_.power_forensics_schema -eq "axp2101-v2" -and
    [int]$_.compiled_enable_body_rgb -eq 1 -and $_.body_rgb_ready -and
    [int]$_.compiled_enable_body_touch -eq 1 -and $_.body_touch_ready -and
    [int]$_.compiled_enable_imu -eq 1 -and $_.imu_ready -and $_.imu_calibrated -and
    [int]$_.compiled_enable_camera -eq 1 -and $_.camera_ready -and
    $_.camera_active -and $_.camera_capture_ready -and
    [int]$_.compiled_enable_camera_host_vision -eq 1
  }).Count
$cameraCaptureReadySamples = @($okRecords | Where-Object {
    -not $_.debug_response_truncated -and
    [int]$_.compiled_enable_camera -eq 1 -and $_.camera_ready -and
    $_.camera_active -and $_.camera_capture_ready
  }).Count
$cameraHostVisionReadySamples = @($okRecords | Where-Object {
    -not $_.debug_response_truncated -and
    [int]$_.compiled_enable_camera_host_vision -eq 1 -and
    $null -ne $_.camera_host_frame_requests -and
    $null -ne $_.camera_host_target_updates -and
    $null -ne $_.camera_host_capture_failures -and
    $null -ne $_.camera_host_response_write_attempts -and
    $null -ne $_.camera_host_response_write_failures -and
    $null -ne $_.camera_host_response_write_max_consecutive_failures
  }).Count
$bodyRgbFrameDelta = if ($firstOkRecord -and $latestOkRecord -and
    $null -ne $firstOkRecord.body_rgb_frames -and $null -ne $latestOkRecord.body_rgb_frames) {
  [int64]$latestOkRecord.body_rgb_frames - [int64]$firstOkRecord.body_rgb_frames
} else { $null }
$bodyTouchSampleDelta = if ($firstOkRecord -and $latestOkRecord -and
    $null -ne $firstOkRecord.body_touch_samples -and $null -ne $latestOkRecord.body_touch_samples) {
  [int64]$latestOkRecord.body_touch_samples - [int64]$firstOkRecord.body_touch_samples
} else { $null }
$imuSampleDelta = if ($firstOkRecord -and $latestOkRecord -and
    $null -ne $firstOkRecord.imu_samples -and $null -ne $latestOkRecord.imu_samples) {
  [int64]$latestOkRecord.imu_samples - [int64]$firstOkRecord.imu_samples
} else { $null }
$cameraFrameDelta = if ($firstOkRecord -and $latestOkRecord -and
    $null -ne $firstOkRecord.camera_frames_captured -and $null -ne $latestOkRecord.camera_frames_captured) {
  [int64]$latestOkRecord.camera_frames_captured - [int64]$firstOkRecord.camera_frames_captured
} else { $null }
$cameraHostFrameRequestDelta = if ($firstOkRecord -and $latestOkRecord -and
    $null -ne $firstOkRecord.camera_host_frame_requests -and
    $null -ne $latestOkRecord.camera_host_frame_requests) {
  [int64]$latestOkRecord.camera_host_frame_requests - [int64]$firstOkRecord.camera_host_frame_requests
} else { $null }
$cameraHostTargetUpdateDelta = if ($firstOkRecord -and $latestOkRecord -and
    $null -ne $firstOkRecord.camera_host_target_updates -and
    $null -ne $latestOkRecord.camera_host_target_updates) {
  [int64]$latestOkRecord.camera_host_target_updates - [int64]$firstOkRecord.camera_host_target_updates
} else { $null }
$newBodyRgbWriteFailures = if ($null -ne $bodyRgbWriteFailuresBaseline -and $latestOkRecord -and
    $null -ne $latestOkRecord.body_rgb_write_failures) {
  [int64]$latestOkRecord.body_rgb_write_failures - [int64]$bodyRgbWriteFailuresBaseline
} else { $null }
$newBodyRgbWriteRetries = if ($null -ne $bodyRgbWriteRetriesBaseline -and $latestOkRecord -and
    $null -ne $latestOkRecord.body_rgb_write_retries) {
  [int64]$latestOkRecord.body_rgb_write_retries - [int64]$bodyRgbWriteRetriesBaseline
} else { $null }
$newBodyRgbWriteRecoveries = if ($null -ne $bodyRgbWriteRecoveriesBaseline -and $latestOkRecord -and
    $null -ne $latestOkRecord.body_rgb_write_recoveries) {
  [int64]$latestOkRecord.body_rgb_write_recoveries - [int64]$bodyRgbWriteRecoveriesBaseline
} else { $null }
$newBodyTouchReadFailures = if ($null -ne $bodyTouchReadFailuresBaseline -and $latestOkRecord -and
    $null -ne $latestOkRecord.body_touch_read_failures) {
  [int64]$latestOkRecord.body_touch_read_failures - [int64]$bodyTouchReadFailuresBaseline
} else { $null }
$newImuReadFailures = if ($null -ne $imuReadFailuresBaseline -and $latestOkRecord -and
    $null -ne $latestOkRecord.imu_read_failures) {
  [int64]$latestOkRecord.imu_read_failures - [int64]$imuReadFailuresBaseline
} else { $null }
$newImuReadRetries = if ($null -ne $imuReadRetriesBaseline -and $latestOkRecord -and
    $null -ne $latestOkRecord.imu_read_retries) {
  [int64]$latestOkRecord.imu_read_retries - [int64]$imuReadRetriesBaseline
} else { $null }
$newImuReadRecoveries = if ($null -ne $imuReadRecoveriesBaseline -and $latestOkRecord -and
    $null -ne $latestOkRecord.imu_read_recoveries) {
  [int64]$latestOkRecord.imu_read_recoveries - [int64]$imuReadRecoveriesBaseline
} else { $null }
$newImuEvents = if ($null -ne $imuEventsBaseline -and $latestOkRecord -and
    $null -ne $latestOkRecord.imu_events) {
  [int64]$latestOkRecord.imu_events - [int64]$imuEventsBaseline
} else { $null }
$newImuSelfMotionEvents = if ($null -ne $imuSelfMotionEventsBaseline -and $latestOkRecord -and
    $null -ne $latestOkRecord.imu_self_motion_events) {
  [int64]$latestOkRecord.imu_self_motion_events - [int64]$imuSelfMotionEventsBaseline
} else { $null }
$newImuExternalEvents = if ($null -ne $imuExternalEventsBaseline -and $latestOkRecord -and
    $null -ne $latestOkRecord.imu_external_events) {
  [int64]$latestOkRecord.imu_external_events - [int64]$imuExternalEventsBaseline
} else { $null }
$newCameraCaptureFailures = if ($null -ne $cameraCaptureFailuresBaseline -and $latestOkRecord -and
    $null -ne $latestOkRecord.camera_capture_failures) {
  [int64]$latestOkRecord.camera_capture_failures - [int64]$cameraCaptureFailuresBaseline
} else { $null }
$newCameraHostFrameFailures = if ($null -ne $cameraHostFrameFailuresBaseline -and $latestOkRecord -and
    $null -ne $latestOkRecord.camera_host_frame_failures) {
  [int64]$latestOkRecord.camera_host_frame_failures - [int64]$cameraHostFrameFailuresBaseline
} else { $null }
$newCameraHostCaptureFailures = if ($null -ne $cameraHostCaptureFailuresBaseline -and $latestOkRecord -and
    $null -ne $latestOkRecord.camera_host_capture_failures) {
  [int64]$latestOkRecord.camera_host_capture_failures - [int64]$cameraHostCaptureFailuresBaseline
} else { $null }
$cameraHostResponseWriteAttemptDelta = if ($null -ne $cameraHostResponseWriteAttemptsBaseline -and
    $latestOkRecord -and $null -ne $latestOkRecord.camera_host_response_write_attempts) {
  [int64]$latestOkRecord.camera_host_response_write_attempts -
    [int64]$cameraHostResponseWriteAttemptsBaseline
} else { $null }
$newCameraHostResponseWriteFailures = if ($null -ne $cameraHostResponseWriteFailuresBaseline -and
    $latestOkRecord -and $null -ne $latestOkRecord.camera_host_response_write_failures) {
  [int64]$latestOkRecord.camera_host_response_write_failures -
    [int64]$cameraHostResponseWriteFailuresBaseline
} else { $null }
$cameraHostResponseWriteFailureRatio = if ($null -ne $cameraHostResponseWriteAttemptDelta -and
    [int64]$cameraHostResponseWriteAttemptDelta -gt 0 -and
    $null -ne $newCameraHostResponseWriteFailures) {
  [math]::Round(
    [int64]$newCameraHostResponseWriteFailures / [double][int64]$cameraHostResponseWriteAttemptDelta,
    6)
} else { 0.0 }
$maxCameraHostResponseWriteConsecutiveFailuresObserved = if (@($okRecords | Where-Object {
      $null -ne $_.camera_host_response_write_max_consecutive_failures
    }).Count -gt 0) {
  (@($okRecords | Where-Object { $null -ne $_.camera_host_response_write_max_consecutive_failures }) |
    Measure-Object -Property camera_host_response_write_max_consecutive_failures -Maximum).Maximum
} else { $null }
$newCameraHostAuthFailures = if ($null -ne $cameraHostAuthFailuresBaseline -and $latestOkRecord -and
    $null -ne $latestOkRecord.camera_host_auth_failures) {
  [int64]$latestOkRecord.camera_host_auth_failures - [int64]$cameraHostAuthFailuresBaseline
} else { $null }
$maxCameraCaptureUsObserved = if (@($okRecords | Where-Object { $null -ne $_.camera_max_capture_us }).Count -gt 0) {
  (@($okRecords | Where-Object { $null -ne $_.camera_max_capture_us }) |
    Measure-Object -Property camera_max_capture_us -Maximum).Maximum
} else { $null }
$motionSamples = @($okRecords | Where-Object { $_.motion }).Count
$failedPolls = @($records | Where-Object { -not $_.ok }).Count
$failedPollRatio = Get-FailedPollRatio -Records $records
$maxConsecutiveFailedPollsObserved = Get-MaxConsecutiveFailedPolls -Records $records
$motionSampleRatio = if ($okRecords.Count -gt 0) { [math]::Round($motionSamples / [double]$okRecords.Count, 4) } else { 0.0 }
$motionUnsuppressedSamples = @($okRecords | Where-Object { $_.motion -and -not $_.motion_output_suppressed }).Count
$motionUnsuppressedSampleRatio = if ($okRecords.Count -gt 0) { [math]::Round($motionUnsuppressedSamples / [double]$okRecords.Count, 4) } else { 0.0 }
$motionTelemetrySamples = @($okRecords | Where-Object { $null -ne $_.motion_last_reason }).Count
$motionDutyRestSamples = @($okRecords | Where-Object { $_.motion_duty_resting }).Count
$motionOutputSuppressSamples = @($okRecords | Where-Object { $_.motion_output_suppressed }).Count
$maxMotionDutyRestEntries = if ($okRecords.Count -gt 0) {
  $values = @($okRecords | ForEach-Object {
      if ($null -ne $_.motion_duty_rest_entries) { [int64]$_.motion_duty_rest_entries }
    })
  if ($values.Count -gt 0) { ($values | Measure-Object -Maximum).Maximum } else { $null }
} else {
  $null
}
$maxMotionDutyRestTotalMs = if ($okRecords.Count -gt 0) {
  $values = @($okRecords | ForEach-Object {
      if ($null -ne $_.motion_duty_rest_total_ms) { [int64]$_.motion_duty_rest_total_ms }
    })
  if ($values.Count -gt 0) { ($values | Measure-Object -Maximum).Maximum } else { $null }
} else {
  $null
}
$maxMotionOutputSuppressEntries = if ($okRecords.Count -gt 0) {
  $values = @($okRecords | ForEach-Object {
      if ($null -ne $_.motion_output_suppress_entries) { [int64]$_.motion_output_suppress_entries }
    })
  if ($values.Count -gt 0) { ($values | Measure-Object -Maximum).Maximum } else { $null }
} else {
  $null
}
$maxMotionOutputSuppressTotalMs = if ($okRecords.Count -gt 0) {
  $values = @($okRecords | ForEach-Object {
      if ($null -ne $_.motion_output_suppress_total_ms) { [int64]$_.motion_output_suppress_total_ms }
    })
  if ($values.Count -gt 0) { ($values | Measure-Object -Maximum).Maximum } else { $null }
} else {
  $null
}
$motionThermalSuppressSamples = @($okRecords | Where-Object { $_.motion_thermal_suppressed }).Count
$maxMotionThermalSuppressEntries = if ($okRecords.Count -gt 0) {
  $values = @($okRecords | ForEach-Object {
      if ($null -ne $_.motion_thermal_suppress_entries) { [int64]$_.motion_thermal_suppress_entries }
    })
  if ($values.Count -gt 0) { ($values | Measure-Object -Maximum).Maximum } else { $null }
} else {
  $null
}
$motionPowerSuppressSamples = @($okRecords | Where-Object { $_.motion_power_suppressed }).Count
$maxMotionPowerSuppressEntries = if ($okRecords.Count -gt 0) {
  $values = @($okRecords | ForEach-Object {
      if ($null -ne $_.motion_power_suppress_entries) { [int64]$_.motion_power_suppress_entries }
    })
  if ($values.Count -gt 0) { ($values | Measure-Object -Maximum).Maximum } else { $null }
} else {
  $null
}
$maxMotionSessionTimeouts = if ($okRecords.Count -gt 0) {
  $values = @($okRecords | ForEach-Object {
      if ($null -ne $_.motion_session_timeouts) { [int64]$_.motion_session_timeouts }
    })
  if ($values.Count -gt 0) { ($values | Measure-Object -Maximum).Maximum } else { $null }
} else {
  $null
}
$maxMotionSessionRefreshes = if ($okRecords.Count -gt 0) {
  $values = @($okRecords | ForEach-Object {
      if ($null -ne $_.motion_session_refreshes) { [int64]$_.motion_session_refreshes }
    })
  if ($values.Count -gt 0) { ($values | Measure-Object -Maximum).Maximum } else { $null }
} else {
  $null
}
$latestMotionSessionRefreshedAtMs = if ($okRecords.Count -gt 0) {
  $values = @($okRecords | ForEach-Object {
      if ($null -ne $_.motion_session_refreshed_at_ms) { [int64]$_.motion_session_refreshed_at_ms }
    })
  if ($values.Count -gt 0) { $values[-1] } else { $null }
} else {
  $null
}
$chipTempRecords = @($okRecords | Where-Object { $null -ne $_.chip_temp_c })
$maxChipTempC = if ($chipTempRecords.Count -gt 0) {
  ($chipTempRecords | Measure-Object -Property chip_temp_c -Maximum).Maximum
} else {
  $null
}
$latestChipTempC = if ($chipTempRecords.Count -gt 0) {
  ($chipTempRecords | Select-Object -Last 1).chip_temp_c
} else {
  $null
}
$maxChipTempReportedC = if (@($okRecords | Where-Object { $null -ne $_.chip_temp_max_c }).Count -gt 0) {
  (@($okRecords | Where-Object { $null -ne $_.chip_temp_max_c }) |
    Measure-Object -Property chip_temp_max_c -Maximum).Maximum
} else {
  $null
}
$maxChipTempReadFailures = if (@($okRecords | Where-Object { $null -ne $_.chip_temp_read_failures }).Count -gt 0) {
  (@($okRecords | Where-Object { $null -ne $_.chip_temp_read_failures }) |
    Measure-Object -Property chip_temp_read_failures -Maximum).Maximum
} else {
  $null
}
$minHeapFree = if (@($okRecords | Where-Object { $null -ne $_.heap_free }).Count -gt 0) {
  (@($okRecords | Where-Object { $null -ne $_.heap_free }) |
    Measure-Object -Property heap_free -Minimum).Minimum
} else {
  $null
}
$powerTelemetrySamples = @($okRecords | Where-Object { $_.power_telemetry_valid }).Count
$powerVbusRecords = @($okRecords | Where-Object { $null -ne $_.power_vbus_mv -and [int]$_.power_vbus_mv -ge 0 })
$minPowerVbusMv = if ($powerVbusRecords.Count -gt 0) {
  ($powerVbusRecords | Measure-Object -Property power_vbus_mv -Minimum).Minimum
} else {
  $null
}
$maxPowerVbusMv = if ($powerVbusRecords.Count -gt 0) {
  ($powerVbusRecords | Measure-Object -Property power_vbus_mv -Maximum).Maximum
} else {
  $null
}
$minPowerVbusReportedMv = if (@($okRecords | Where-Object { $null -ne $_.power_vbus_min_mv -and [int]$_.power_vbus_min_mv -gt 0 }).Count -gt 0) {
  (@($okRecords | Where-Object { $null -ne $_.power_vbus_min_mv -and [int]$_.power_vbus_min_mv -gt 0 }) |
    Measure-Object -Property power_vbus_min_mv -Minimum).Minimum
} else {
  $null
}
$maxPowerVbusReportedMv = if (@($okRecords | Where-Object { $null -ne $_.power_vbus_max_mv -and [int]$_.power_vbus_max_mv -ge 0 }).Count -gt 0) {
  (@($okRecords | Where-Object { $null -ne $_.power_vbus_max_mv -and [int]$_.power_vbus_max_mv -ge 0 }) |
    Measure-Object -Property power_vbus_max_mv -Maximum).Maximum
} else {
  $null
}
$powerBatteryRecords = @($okRecords | Where-Object { $null -ne $_.power_battery_mv -and [int]$_.power_battery_mv -gt 0 })
$minPowerBatteryMv = if ($powerBatteryRecords.Count -gt 0) {
  ($powerBatteryRecords | Measure-Object -Property power_battery_mv -Minimum).Minimum
} else {
  $null
}
$maxPowerBatteryMv = if ($powerBatteryRecords.Count -gt 0) {
  ($powerBatteryRecords | Measure-Object -Property power_battery_mv -Maximum).Maximum
} else {
  $null
}
$latestPowerRecord = @($okRecords | Where-Object { $_.power_telemetry_valid }) | Select-Object -Last 1
$latestPowerVbusMv = if ($latestPowerRecord) { $latestPowerRecord.power_vbus_mv } else { $null }
$latestPowerBatteryMv = if ($latestPowerRecord) { $latestPowerRecord.power_battery_mv } else { $null }
$latestPowerBatteryLevel = if ($latestPowerRecord) { $latestPowerRecord.power_battery_level } else { $null }
$latestPowerChargingState = if ($latestPowerRecord) { $latestPowerRecord.power_charging_state } else { $null }
$maxPowerReadFailures = if (@($okRecords | Where-Object { $null -ne $_.power_read_failures }).Count -gt 0) {
  (@($okRecords | Where-Object { $null -ne $_.power_read_failures }) |
    Measure-Object -Property power_read_failures -Maximum).Maximum
} else {
  $null
}
$powerVbusHardFloorRecords = @($okRecords | Where-Object {
    $null -ne $_.power_vbus_hard_floor_entries
  })
$latestPowerVbusHardFloorRecord = $powerVbusHardFloorRecords | Select-Object -Last 1
$latestPowerVbusHardFloorEntries = if ($latestPowerVbusHardFloorRecord) {
  $latestPowerVbusHardFloorRecord.power_vbus_hard_floor_entries
} else { $null }
$newPowerVbusHardFloorEntries = if ($null -ne $powerVbusHardFloorEntriesBaseline -and
    $null -ne $latestPowerVbusHardFloorEntries) {
  [int64]$latestPowerVbusHardFloorEntries - [int64]$powerVbusHardFloorEntriesBaseline
} else { $null }
$maxPowerVbusHardFloorSamples = if ($powerVbusHardFloorRecords.Count -gt 0) {
  ($powerVbusHardFloorRecords | Measure-Object -Property power_vbus_hard_floor_samples -Maximum).Maximum
} else { $null }
$maxPowerVbusHardFloorConfirmedSamples = if ($powerVbusHardFloorRecords.Count -gt 0) {
  ($powerVbusHardFloorRecords | Measure-Object -Property power_vbus_hard_floor_confirmed_samples -Maximum).Maximum
} else { $null }
$maxPowerVbusHardFloorMaxConsecutiveSamples = if ($powerVbusHardFloorRecords.Count -gt 0) {
  ($powerVbusHardFloorRecords | Measure-Object -Property power_vbus_hard_floor_max_consecutive_samples -Maximum).Maximum
} else { $null }

$powerCoordinatorTelemetrySamples = @($okRecords | Where-Object { $_.power_coordinator_present }).Count
$servoRailSamples = @($okRecords | Where-Object { $_.servo_rail_enabled }).Count
$servoTorqueSamples = @($okRecords | Where-Object { $_.servo_torque_enabled }).Count
$servoRailWithoutGrantSamples = @($okRecords | Where-Object { $_.servo_rail_enabled -and -not $_.power_motion_allowed }).Count
$servoTorqueWithoutRailSamples = @($okRecords | Where-Object { $_.servo_torque_enabled -and -not $_.servo_rail_enabled }).Count
$chargeBackedServoRailSamples = @($okRecords | Where-Object { $_.servo_rail_enabled -and $_.motion_power_charge_backed }).Count
$softFloorServoRailSamples = @($okRecords | Where-Object {
    $MotionPowerSoftFloorMv -gt 0 -and
    $_.servo_rail_enabled -and
    $null -ne $_.power_vbus_mv -and
    [int]$_.power_vbus_mv -lt $MotionPowerSoftFloorMv
  }).Count
$unbackedSoftFloorServoRailSamples = @($okRecords | Where-Object {
    $MotionPowerSoftFloorMv -gt 0 -and
    $_.servo_rail_enabled -and
    $null -ne $_.power_vbus_mv -and
    [int]$_.power_vbus_mv -lt $MotionPowerSoftFloorMv -and
    -not $_.motion_power_charge_backed
  }).Count
$bodyPowerCurrentRecords = @($okRecords | Where-Object { $_.body_power_telemetry_valid -and $null -ne $_.body_power_current_ma })
$minBodyPowerCurrentMa = if ($bodyPowerCurrentRecords.Count -gt 0) {
  ($bodyPowerCurrentRecords | Measure-Object -Property body_power_current_ma -Minimum).Minimum
} else { $null }
$maxBodyPowerCurrentMa = if ($bodyPowerCurrentRecords.Count -gt 0) {
  ($bodyPowerCurrentRecords | Measure-Object -Property body_power_current_ma -Maximum).Maximum
} else { $null }
$bodyPowerBusRecords = @($okRecords | Where-Object {
    $_.body_power_telemetry_valid -and $null -ne $_.body_power_bus_v
  })
$minBodyPowerBusV = if ($bodyPowerBusRecords.Count -gt 0) {
  ($bodyPowerBusRecords | Measure-Object -Property body_power_bus_v -Minimum).Minimum
} else { $null }
$maxBodyPowerBusV = if ($bodyPowerBusRecords.Count -gt 0) {
  ($bodyPowerBusRecords | Measure-Object -Property body_power_bus_v -Maximum).Maximum
} else { $null }
$maxPowerVbusRejectedSamples = if (@($okRecords | Where-Object { $null -ne $_.power_vbus_rejected_samples }).Count -gt 0) {
  (@($okRecords | Where-Object { $null -ne $_.power_vbus_rejected_samples }) |
    Measure-Object -Property power_vbus_rejected_samples -Maximum).Maximum
} else { $null }
$pmicInputRecords = @($okRecords | Where-Object { $_.power_pmic_input_state_valid })
$latestPmicInputRecord = $pmicInputRecords | Select-Object -Last 1
$maxPmicInputCurrentLimitEntries = if ($pmicInputRecords.Count -gt 0) {
  ($pmicInputRecords | Measure-Object -Property power_pmic_input_current_limit_entries -Maximum).Maximum
} else { $null }
$maxPmicVindpmEntries = if ($pmicInputRecords.Count -gt 0) {
  ($pmicInputRecords | Measure-Object -Property power_pmic_vindpm_entries -Maximum).Maximum
} else { $null }
$maxPmicBatterySupplementEntries = if ($pmicInputRecords.Count -gt 0) {
  ($pmicInputRecords | Measure-Object -Property power_pmic_battery_supplement_entries -Maximum).Maximum
} else { $null }
$vsysRecords = @($okRecords | Where-Object { $_.power_vsys_valid -and $null -ne $_.power_vsys_mv })
$minPowerVsysMv = if ($vsysRecords.Count -gt 0) {
  ($vsysRecords | Measure-Object -Property power_vsys_mv -Minimum).Minimum
} else { $null }
$maxPowerVsysMv = if ($vsysRecords.Count -gt 0) {
  ($vsysRecords | Measure-Object -Property power_vsys_mv -Maximum).Maximum
} else { $null }
$latestPowerForensicsRecord = @($okRecords | Where-Object { $_.power_forensics_enabled }) | Select-Object -Last 1
$latestPowerForensicsRuntimeEvents = if ($latestPowerForensicsRecord) {
  $latestPowerForensicsRecord.power_forensics_runtime_event_polls
} else { $null }
$latestPowerForensicsProtectiveEvents = if ($latestPowerForensicsRecord) {
  $latestPowerForensicsRecord.power_forensics_runtime_protective_event_polls
} else { $null }
$newPowerForensicsRuntimeEvents = if ($null -ne $powerForensicsRuntimeEventsBaseline -and
    $null -ne $latestPowerForensicsRuntimeEvents) {
  [int64]$latestPowerForensicsRuntimeEvents - [int64]$powerForensicsRuntimeEventsBaseline
} else { $null }
$newPowerForensicsProtectiveEvents = if ($null -ne $powerForensicsProtectiveEventsBaseline -and
    $null -ne $latestPowerForensicsProtectiveEvents) {
  [int64]$latestPowerForensicsProtectiveEvents - [int64]$powerForensicsProtectiveEventsBaseline
} else { $null }

$issues = New-Object System.Collections.Generic.List[string]
if ($fatalError -ne $null) { $issues.Add("fatal_error") }
if (-not [string]::IsNullOrWhiteSpace($abortReason)) { $issues.Add("aborted_$abortReason") }
if ($MaxFailedPolls -gt 0 -and $failedPolls -gt $MaxFailedPolls) { $issues.Add("failed_poll_limit_exceeded") }
if ($MaxFailedPollRatio -gt 0 -and
    $records.Count -ge $MinPollsForFailedRatio -and
    $failedPollRatio -gt $MaxFailedPollRatio) {
  $issues.Add("failed_poll_ratio_exceeded")
}
if ($maxConsecutiveFailedPollsObserved -gt $MaxConsecutiveFailedPolls) { $issues.Add("consecutive_failed_poll_limit_exceeded") }
if ($null -eq $motionStopResult -or -not [bool]$motionStopResult.verified) { $issues.Add("motion_stop_not_verified") }
if ($MotionRefreshSeconds -gt 0 -and $motionRefreshFailures -gt 0) { $issues.Add("motion_refresh_failed") }
if ($RequireMotion -and ($okRecords.Count -eq 0 -or $motionSampleRatio -lt $MinMotionSampleRatio)) {
  $issues.Add("motion_samples_below_required_ratio")
}
if ($MinMotionUnsuppressedSampleRatio -gt 0 -and
    ($okRecords.Count -eq 0 -or $motionUnsuppressedSampleRatio -lt $MinMotionUnsuppressedSampleRatio)) {
  $issues.Add("motion_unsuppressed_samples_below_required_ratio")
}
if ($RequireMotionTelemetry -and ($okRecords.Count -eq 0 -or $motionTelemetrySamples -lt $okRecords.Count)) {
  $issues.Add("motion_telemetry_missing")
}
if ($RequireNoMotionTimeouts -and $maxMotionSessionTimeouts -ne $null -and [int64]$maxMotionSessionTimeouts -gt 0) {
  $issues.Add("motion_session_timeout_observed")
}
if ($MinMotionSessionRefreshes -gt 0 -and
    ($null -eq $maxMotionSessionRefreshes -or [int64]$maxMotionSessionRefreshes -lt $MinMotionSessionRefreshes)) {
  $issues.Add("motion_session_refreshes_below_required")
}
if ($RequireBridgeSocket -and @($records | Where-Object { $_.socket_remote }).Count -lt $records.Count) {
  $issues.Add("bridge_socket_not_present_for_all_samples")
}
if ($RequireWakeReady -and ($okRecords.Count -eq 0 -or @($okRecords | Where-Object { $_.wake_ready }).Count -lt $okRecords.Count)) {
  $issues.Add("wake_not_ready_for_all_ok_samples")
}
$micReadyRequiredSamples = @($okRecords | Where-Object { Test-MicReadyRequired $_ }).Count
$micReadyRequiredReadySamples = @($okRecords | Where-Object { (Test-MicReadyRequired $_) -and $_.mic_ready }).Count
if ($RequireMicReady -and ($okRecords.Count -eq 0 -or $micReadyRequiredReadySamples -lt $micReadyRequiredSamples)) {
  $issues.Add("mic_not_ready_for_all_ok_samples")
}
if ($RequireSpeakerReady -and ($okRecords.Count -eq 0 -or @($okRecords | Where-Object { $_.speaker_ready }).Count -lt $okRecords.Count)) {
  $issues.Add("speaker_not_ready_for_all_ok_samples")
}
if ($RequireRvcWorker -and ($rvcWorkerPolls -eq 0 -or $rvcWorkerReadySamples -lt $rvcWorkerPolls)) {
  $issues.Add("rvc_worker_not_ready_for_all_samples")
}
if ($RequirePowerCoordinator -and ($okRecords.Count -eq 0 -or $powerCoordinatorTelemetrySamples -lt $okRecords.Count)) {
  $issues.Add("power_coordinator_telemetry_missing")
}
if ($RequirePowerCoordinator -and $servoRailWithoutGrantSamples -gt 0) {
  $issues.Add("servo_rail_without_motion_grant")
}
if ($RequirePowerCoordinator -and $servoTorqueWithoutRailSamples -gt 0) {
  $issues.Add("servo_torque_without_rail")
}
if ($RequirePowerCoordinator -and $unbackedSoftFloorServoRailSamples -gt 0) {
  $issues.Add("charge_backed_soft_floor_violation")
}
if ($RequirePowerForensics) {
  if ($null -eq $latestPowerForensicsRecord -or
      -not $latestPowerForensicsRecord.power_forensics_irq_enable_succeeded -or
      -not $latestPowerForensicsRecord.power_forensics_boot_status_valid) {
    $issues.Add("power_forensics_not_armed")
  }
  if ($null -ne $newPowerForensicsRuntimeEvents -and $newPowerForensicsRuntimeEvents -gt 0) {
    $issues.Add("power_forensics_runtime_event_observed")
  }
  if ($null -ne $newPowerForensicsProtectiveEvents -and $newPowerForensicsProtectiveEvents -gt 0) {
    $issues.Add("power_forensics_protective_event_observed")
  }
  if ($ExpectedPmicVindpmMv -gt 0) {
    if ($null -eq $latestPmicInputRecord -or
        -not $latestPmicInputRecord.power_pmic_config_valid -or
        -not $latestPmicInputRecord.power_pmic_vindpm_configured -or
        [int]$latestPmicInputRecord.power_pmic_vindpm_target_mv -ne $ExpectedPmicVindpmMv -or
        [int]$latestPmicInputRecord.power_pmic_vindpm_config_mv -ne $ExpectedPmicVindpmMv -or
        -not $latestPmicInputRecord.power_vsys_valid) {
      $issues.Add("pmic_input_policy_not_applied")
    }
    if ($null -eq $pmicInputStateReadFailuresBaseline -or
        $null -eq $pmicConfigReadFailuresBaseline -or
        $null -eq $powerVsysReadFailuresBaseline -or
        $null -eq $latestPmicInputRecord -or
        $null -eq $latestPmicInputRecord.power_pmic_input_state_read_failures -or
        $null -eq $latestPmicInputRecord.power_pmic_config_read_failures -or
        $null -eq $latestPmicInputRecord.power_vsys_read_failures) {
      $issues.Add("pmic_input_policy_telemetry_missing")
    } elseif ([int64]$latestPmicInputRecord.power_pmic_input_state_read_failures -gt
                [int64]$pmicInputStateReadFailuresBaseline -or
              [int64]$latestPmicInputRecord.power_pmic_config_read_failures -gt
                [int64]$pmicConfigReadFailuresBaseline -or
              [int64]$latestPmicInputRecord.power_vsys_read_failures -gt
                [int64]$powerVsysReadFailuresBaseline) {
      $issues.Add("pmic_input_policy_io_failure_observed")
    }
  }
}
if ($RequireFinalIntegration) {
  if ($okRecords.Count -eq 0 -or $finalIntegrationReadySamples -lt $okRecords.Count) {
    $issues.Add("final_integration_not_ready_for_all_ok_samples")
  }
  if ($null -eq $bodyRgbFrameDelta -or $bodyRgbFrameDelta -le 0 -or
      $null -eq $bodyTouchSampleDelta -or $bodyTouchSampleDelta -le 0 -or
      $null -eq $imuSampleDelta -or $imuSampleDelta -le 0) {
    $issues.Add("final_integration_counters_not_advancing")
  }
  if ($newBodyRgbWriteFailures -ne 0 -or $newBodyTouchReadFailures -ne 0 -or
      $newImuReadFailures -ne 0) {
    $issues.Add("final_integration_io_failure_observed")
  }
  if ($newImuExternalEvents -ne 0) {
    $issues.Add("external_imu_event_observed")
  }
}
if ($RequireCameraCapture) {
  if ($okRecords.Count -eq 0 -or $cameraCaptureReadySamples -lt $okRecords.Count) {
    $issues.Add("camera_capture_probe_not_ready_for_all_ok_samples")
  }
  if ($null -eq $cameraFrameDelta -or $cameraFrameDelta -le 0) {
    $issues.Add("camera_capture_frames_not_advancing")
  }
  if ($newCameraCaptureFailures -ne 0) {
    $issues.Add("camera_capture_failure_observed")
  }
  if ($MaxCameraCaptureUs -gt 0 -and $null -ne $maxCameraCaptureUsObserved -and
      [int64]$maxCameraCaptureUsObserved -gt $MaxCameraCaptureUs) {
    $issues.Add("camera_capture_time_limit_exceeded")
  }
}
if ($RequireCameraHostVision) {
  if ($okRecords.Count -eq 0 -or $cameraHostVisionReadySamples -lt $okRecords.Count) {
    $issues.Add("camera_host_vision_not_ready_for_all_ok_samples")
  }
  if ($null -eq $cameraHostFrameRequestDelta -or $cameraHostFrameRequestDelta -le 0) {
    $issues.Add("camera_host_frame_requests_not_advancing")
  }
  if ($null -eq $cameraHostTargetUpdateDelta -or $cameraHostTargetUpdateDelta -le 0) {
    $issues.Add("camera_host_target_updates_not_advancing")
  }
  if ($newCameraHostCaptureFailures -ne 0) {
    $issues.Add("camera_host_capture_failure_observed")
  }
  if ($newCameraHostAuthFailures -ne 0) {
    $issues.Add("camera_host_auth_failure_observed")
  }
  if ($null -eq $cameraHostResponseWriteAttemptDelta -or
      $null -eq $newCameraHostResponseWriteFailures -or
      $null -eq $maxCameraHostResponseWriteConsecutiveFailuresObserved) {
    $issues.Add("camera_host_response_write_telemetry_missing")
  } else {
    if ($MaxCameraHostResponseWriteFailures -ge 0 -and
        [int64]$newCameraHostResponseWriteFailures -gt $MaxCameraHostResponseWriteFailures) {
      $issues.Add("camera_host_response_write_failure_limit_exceeded")
    }
    if ($MaxCameraHostResponseWriteFailureRatio -gt 0 -and
        [int64]$cameraHostResponseWriteAttemptDelta -ge $MinCameraHostResponseWriteAttemptsForRatio -and
        [double]$cameraHostResponseWriteFailureRatio -gt $MaxCameraHostResponseWriteFailureRatio) {
      $issues.Add("camera_host_response_write_failure_ratio_exceeded")
    }
    if ([int64]$maxCameraHostResponseWriteConsecutiveFailuresObserved -gt
        $MaxCameraHostResponseWriteConsecutiveFailures) {
      $issues.Add("camera_host_response_write_streak_exceeded")
    }
  }
}
if ($MaxAllowedChipTempC -gt 0 -and $maxChipTempC -ne $null -and [double]$maxChipTempC -gt $MaxAllowedChipTempC) {
  $issues.Add("chip_temp_limit_exceeded")
}
if ($minPowerVbusMvThreshold -gt 0 -and $minPowerVbusMv -ne $null -and [int]$minPowerVbusMv -lt $minPowerVbusMvThreshold) {
  $issues.Add("power_vbus_sample_floor_exceeded")
}
if ($minPowerVbusReportedMvThreshold -gt 0 -and $minPowerVbusReportedMv -ne $null -and [int]$minPowerVbusReportedMv -lt $minPowerVbusReportedMvThreshold) {
  $issues.Add("power_vbus_floor_exceeded")
}
if ($RequireNoNewHardFloorEvents) {
  if ($null -eq $powerVbusHardFloorEntriesBaseline -or $null -eq $latestPowerVbusHardFloorEntries) {
    $issues.Add("power_vbus_hard_floor_telemetry_missing")
  } elseif ([int64]$latestPowerVbusHardFloorEntries -gt [int64]$powerVbusHardFloorEntriesBaseline) {
    $issues.Add("power_vbus_hard_floor_event_observed")
  }
}
$summaryMaxFrameUs = if ($okRecords.Count -gt 0) { ($okRecords | Measure-Object -Property max_us -Maximum).Maximum } else { $null }
if ($MaxDisplayFrameUs -gt 0 -and $summaryMaxFrameUs -ne $null -and [int64]$summaryMaxFrameUs -gt $MaxDisplayFrameUs) {
  $issues.Add("display_frame_limit_exceeded")
}
$installedFirmwareSha256 = if ($latestOkRecord) { [string]$latestOkRecord.ota_expected_sha256 } else { "" }
if ($RequireFinalIntegration) {
  if ($SourceDirty) { $issues.Add("final_integration_source_worktree_dirty") }
  if ($SourceCommit -notmatch "^[0-9a-fA-F]{40}$") { $issues.Add("final_integration_source_commit_missing") }
  if ($RunnerSourceCommit -notmatch "^[0-9a-fA-F]{40}$") { $issues.Add("final_integration_runner_source_commit_missing") }
  if ($installedFirmwareSha256 -notmatch "^[0-9a-fA-F]{64}$" -or
      -not [bool]$latestOkRecord.ota_current_app_confirmed) {
    $issues.Add("final_integration_firmware_identity_missing")
  }
}

$endedAt = Get-Date
$actualElapsedSeconds = [math]::Round((([DateTime]::UtcNow - $startUtc).TotalSeconds), 1)
$summary = [ordered]@{
  schema = "stackchan.full-system-soak-summary.v1"
  sourceCommit = $SourceCommit
  sourceDirty = $SourceDirty
  runnerSourceCommit = $RunnerSourceCommit
  runnerSourceDirty = $SourceDirty
  installedFirmwareSha256 = $installedFirmwareSha256
  startedAt = $startedAt.ToString("o")
  endedAt = $endedAt.ToString("o")
  durationSeconds = [int][math]::Floor($actualElapsedSeconds)
  plannedDurationSeconds = $DurationSeconds
  elapsedSeconds = $actualElapsedSeconds
  evidenceRoot = $evidencePath
  status = if ($issues.Count -eq 0) { "pass" } else { "fail" }
  issues = @($issues)
  abortReason = $abortReason
  strict = [ordered]@{
    requireMotion = [bool]$RequireMotion
    minMotionSampleRatio = $MinMotionSampleRatio
    minMotionUnsuppressedSampleRatio = $MinMotionUnsuppressedSampleRatio
    minMotionSessionRefreshes = $MinMotionSessionRefreshes
    requireMotionTelemetry = [bool]$RequireMotionTelemetry
    requireNoMotionTimeouts = [bool]$RequireNoMotionTimeouts
    requireBridgeSocket = [bool]$RequireBridgeSocket
    requireWakeReady = [bool]$RequireWakeReady
    requireMicReady = [bool]$RequireMicReady
    requireSpeakerReady = [bool]$RequireSpeakerReady
    requireRvcWorker = [bool]$RequireRvcWorker
    requirePowerCoordinator = [bool]$RequirePowerCoordinator
    requirePowerForensics = [bool]$RequirePowerForensics
    expectedPmicVindpmMv = $ExpectedPmicVindpmMv
    requireFinalIntegration = [bool]$RequireFinalIntegration
    requireCameraCapture = [bool]$RequireCameraCapture
    requireCameraHostVision = [bool]$RequireCameraHostVision
    maxCameraCaptureUs = $MaxCameraCaptureUs
    maxCameraHostResponseWriteFailures = $MaxCameraHostResponseWriteFailures
    maxCameraHostResponseWriteFailureRatio = $MaxCameraHostResponseWriteFailureRatio
    minCameraHostResponseWriteAttemptsForRatio = $MinCameraHostResponseWriteAttemptsForRatio
    maxCameraHostResponseWriteConsecutiveFailures = $MaxCameraHostResponseWriteConsecutiveFailures
    requirePmicVbusStable = [bool]$RequirePmicVbusStable
    requireNoNewHardFloorEvents = [bool]$RequireNoNewHardFloorEvents
    requireManagedChargePolicy = [bool]$RequireManagedChargePolicy
    maxChipTempC = $MaxAllowedChipTempC
    minPowerVbusMv = $minPowerVbusMvThreshold
    minPowerVbusReportedMv = $minPowerVbusReportedMvThreshold
    motionPowerSoftFloorMv = $MotionPowerSoftFloorMv
    maxDisplayFrameUs = $MaxDisplayFrameUs
    pollTimeoutSeconds = $PollTimeoutSeconds
    maxFailedPolls = $MaxFailedPolls
    maxFailedPollRatio = $MaxFailedPollRatio
    minPollsForFailedRatio = $MinPollsForFailedRatio
    maxConsecutiveFailedPolls = $MaxConsecutiveFailedPolls
    requireVerifiedMotionStop = $true
    motionRefreshSeconds = $MotionRefreshSeconds
    motionRefreshInitialDelaySeconds = $MotionRefreshInitialDelaySeconds
    failFastOnStrictBreach = [bool]$FailFastOnStrictBreach
  }
  records = $records.Count
  okPolls = $okRecords.Count
  failedPolls = $failedPolls
  failedPollRatio = $failedPollRatio
  maxConsecutiveFailedPolls = $maxConsecutiveFailedPollsObserved
  motionStopVerified = if ($null -ne $motionStopResult) { [bool]$motionStopResult.verified } else { $false }
  motionStopAttempts = if ($null -ne $motionStopResult) { [int]$motionStopResult.attempts } else { 0 }
  motionStopRecords = if ($null -ne $motionStopResult) { @($motionStopResult.records) } else { @() }
  motionStopError = if ($null -ne $motionStopResult -and
      $null -ne $motionStopResult.PSObject.Properties["error"]) {
    [string]$motionStopResult.error
  } else { $null }
  motionSamples = $motionSamples
  motionSampleRatio = $motionSampleRatio
  motionUnsuppressedSamples = $motionUnsuppressedSamples
  motionUnsuppressedSampleRatio = $motionUnsuppressedSampleRatio
  motionTelemetrySamples = $motionTelemetrySamples
  motionDutyRestSamples = $motionDutyRestSamples
  maxMotionDutyRestEntries = $maxMotionDutyRestEntries
  maxMotionDutyRestTotalMs = $maxMotionDutyRestTotalMs
  motionOutputSuppressSamples = $motionOutputSuppressSamples
  maxMotionOutputSuppressEntries = $maxMotionOutputSuppressEntries
  maxMotionOutputSuppressTotalMs = $maxMotionOutputSuppressTotalMs
  motionThermalSuppressSamples = $motionThermalSuppressSamples
  maxMotionThermalSuppressEntries = $maxMotionThermalSuppressEntries
  motionPowerSuppressSamples = $motionPowerSuppressSamples
  maxMotionPowerSuppressEntries = $maxMotionPowerSuppressEntries
  maxMotionSessionTimeouts = $maxMotionSessionTimeouts
  maxMotionSessionRefreshes = $maxMotionSessionRefreshes
  latestMotionSessionRefreshedAtMs = $latestMotionSessionRefreshedAtMs
  chipTempTelemetrySamples = $chipTempRecords.Count
  maxChipTempC = $maxChipTempC
  latestChipTempC = $latestChipTempC
  maxChipTempReportedC = $maxChipTempReportedC
  maxChipTempReadFailures = $maxChipTempReadFailures
  minHeapFree = $minHeapFree
  powerTelemetrySamples = $powerTelemetrySamples
  minPowerVbusMv = $minPowerVbusMv
  maxPowerVbusMv = $maxPowerVbusMv
  minPowerVbusReportedMv = $minPowerVbusReportedMv
  maxPowerVbusReportedMv = $maxPowerVbusReportedMv
  powerVbusHardFloorEntriesBaseline = $powerVbusHardFloorEntriesBaseline
  latestPowerVbusHardFloorEntries = $latestPowerVbusHardFloorEntries
  newPowerVbusHardFloorEntries = $newPowerVbusHardFloorEntries
  maxPowerVbusHardFloorSamples = $maxPowerVbusHardFloorSamples
  maxPowerVbusHardFloorConfirmedSamples = $maxPowerVbusHardFloorConfirmedSamples
  maxPowerVbusHardFloorMaxConsecutiveSamples = $maxPowerVbusHardFloorMaxConsecutiveSamples
  minPowerBatteryMv = $minPowerBatteryMv
  maxPowerBatteryMv = $maxPowerBatteryMv
  latestPowerVbusMv = $latestPowerVbusMv
  latestPowerBatteryMv = $latestPowerBatteryMv
  latestPowerBatteryLevel = $latestPowerBatteryLevel
  latestPowerChargingState = $latestPowerChargingState
  maxPowerReadFailures = $maxPowerReadFailures
  maxPowerVbusRejectedSamples = $maxPowerVbusRejectedSamples
  pmicInputTelemetrySamples = $pmicInputRecords.Count
  maxPmicInputCurrentLimitEntries = $maxPmicInputCurrentLimitEntries
  maxPmicVindpmEntries = $maxPmicVindpmEntries
  maxPmicBatterySupplementEntries = $maxPmicBatterySupplementEntries
  minPowerVsysMv = $minPowerVsysMv
  maxPowerVsysMv = $maxPowerVsysMv
  latestPmicInput = $latestPmicInputRecord
  pmicInputStateReadFailuresBaseline = $pmicInputStateReadFailuresBaseline
  pmicConfigReadFailuresBaseline = $pmicConfigReadFailuresBaseline
  powerVsysReadFailuresBaseline = $powerVsysReadFailuresBaseline
  powerForensicsRuntimeEventsBaseline = $powerForensicsRuntimeEventsBaseline
  latestPowerForensicsRuntimeEvents = $latestPowerForensicsRuntimeEvents
  newPowerForensicsRuntimeEvents = $newPowerForensicsRuntimeEvents
  powerForensicsProtectiveEventsBaseline = $powerForensicsProtectiveEventsBaseline
  latestPowerForensicsProtectiveEvents = $latestPowerForensicsProtectiveEvents
  newPowerForensicsProtectiveEvents = $newPowerForensicsProtectiveEvents
  latestPowerForensics = $latestPowerForensicsRecord
  finalIntegrationReadySamples = $finalIntegrationReadySamples
  cameraCaptureReadySamples = $cameraCaptureReadySamples
  cameraHostVisionReadySamples = $cameraHostVisionReadySamples
  bodyRgbFrameDelta = $bodyRgbFrameDelta
  bodyTouchSampleDelta = $bodyTouchSampleDelta
  imuSampleDelta = $imuSampleDelta
  cameraFrameDelta = $cameraFrameDelta
  cameraHostFrameRequestDelta = $cameraHostFrameRequestDelta
  cameraHostTargetUpdateDelta = $cameraHostTargetUpdateDelta
  bodyRgbWriteFailuresBaseline = $bodyRgbWriteFailuresBaseline
  bodyRgbWriteRetriesBaseline = $bodyRgbWriteRetriesBaseline
  bodyRgbWriteRecoveriesBaseline = $bodyRgbWriteRecoveriesBaseline
  bodyTouchReadFailuresBaseline = $bodyTouchReadFailuresBaseline
  imuReadRetriesBaseline = $imuReadRetriesBaseline
  imuReadRecoveriesBaseline = $imuReadRecoveriesBaseline
  imuReadFailuresBaseline = $imuReadFailuresBaseline
  imuEventsBaseline = $imuEventsBaseline
  imuSelfMotionEventsBaseline = $imuSelfMotionEventsBaseline
  imuExternalEventsBaseline = $imuExternalEventsBaseline
  cameraCaptureFailuresBaseline = $cameraCaptureFailuresBaseline
  cameraHostFrameFailuresBaseline = $cameraHostFrameFailuresBaseline
  cameraHostCaptureFailuresBaseline = $cameraHostCaptureFailuresBaseline
  cameraHostResponseWriteAttemptsBaseline = $cameraHostResponseWriteAttemptsBaseline
  cameraHostResponseWriteFailuresBaseline = $cameraHostResponseWriteFailuresBaseline
  cameraHostAuthFailuresBaseline = $cameraHostAuthFailuresBaseline
  newBodyRgbWriteFailures = $newBodyRgbWriteFailures
  newBodyRgbWriteRetries = $newBodyRgbWriteRetries
  newBodyRgbWriteRecoveries = $newBodyRgbWriteRecoveries
  newBodyTouchReadFailures = $newBodyTouchReadFailures
  newImuReadRetries = $newImuReadRetries
  newImuReadRecoveries = $newImuReadRecoveries
  newImuReadFailures = $newImuReadFailures
  newImuEvents = $newImuEvents
  newImuSelfMotionEvents = $newImuSelfMotionEvents
  newImuExternalEvents = $newImuExternalEvents
  newCameraCaptureFailures = $newCameraCaptureFailures
  newCameraHostFrameFailures = $newCameraHostFrameFailures
  newCameraHostCaptureFailures = $newCameraHostCaptureFailures
  cameraHostResponseWriteAttemptDelta = $cameraHostResponseWriteAttemptDelta
  newCameraHostResponseWriteFailures = $newCameraHostResponseWriteFailures
  cameraHostResponseWriteFailureRatio = $cameraHostResponseWriteFailureRatio
  maxCameraHostResponseWriteConsecutiveFailures = $maxCameraHostResponseWriteConsecutiveFailuresObserved
  newCameraHostAuthFailures = $newCameraHostAuthFailures
  maxCameraCaptureUsObserved = $maxCameraCaptureUsObserved
  latestFinalIntegration = $latestOkRecord
  powerCoordinatorTelemetrySamples = $powerCoordinatorTelemetrySamples
  servoRailSamples = $servoRailSamples
  servoTorqueSamples = $servoTorqueSamples
  servoRailWithoutGrantSamples = $servoRailWithoutGrantSamples
  servoTorqueWithoutRailSamples = $servoTorqueWithoutRailSamples
  chargeBackedServoRailSamples = $chargeBackedServoRailSamples
  softFloorServoRailSamples = $softFloorServoRailSamples
  unbackedSoftFloorServoRailSamples = $unbackedSoftFloorServoRailSamples
  bodyPowerTelemetrySamples = $bodyPowerCurrentRecords.Count
  minBodyPowerBusV = $minBodyPowerBusV
  maxBodyPowerBusV = $maxBodyPowerBusV
  minBodyPowerCurrentMa = $minBodyPowerCurrentMa
  maxBodyPowerCurrentMa = $maxBodyPowerCurrentMa
  bridgeReadySamples = @($okRecords | Where-Object { $_.bridge -eq "ready" }).Count
  bridgeHealthySamples = @($okRecords | Where-Object { Test-BridgeHealthyState $_.bridge }).Count
  networkConnectedSamples = @($okRecords | Where-Object { $_.network -eq "connected" }).Count
  socketPresentSamples = @($records | Where-Object { $_.socket_remote }).Count
  serialPresentSamples = @($records | Where-Object { $_.serial_present }).Count
  serialMissingSamples = @($records | Where-Object { -not $_.serial_present }).Count
  wakeReadySamples = @($okRecords | Where-Object { $_.wake_ready }).Count
  micReadySamples = @($okRecords | Where-Object { $_.mic_ready }).Count
  micReadyRequiredSamples = $micReadyRequiredSamples
  micReadyRequiredReadySamples = $micReadyRequiredReadySamples
  speakerReadySamples = @($okRecords | Where-Object { $_.speaker_ready }).Count
  maxFrameUs = $summaryMaxFrameUs
  maxSlowFrames = if ($okRecords.Count -gt 0) { ($okRecords | Measure-Object -Property slow -Maximum).Maximum } else { $null }
  motionRefreshes = $motionRefreshes
  motionRefreshFailures = $motionRefreshFailures
  rvcWorkerUrl = $RvcWorkerUrl
  rvcWorkerPolls = $rvcWorkerPolls
  rvcWorkerReadySamples = $rvcWorkerReadySamples
  latestRvcWorkerHealth = $latestRvcWorkerHealth
  serialMotionLines = @($serialLines | Where-Object { $_ -match "\[motion\]|\[servo\]" }).Count
  serialResetLines = @($serialLines | Where-Object { $_ -match "\[boot\]|rst:|Guru Meditation|Brownout|panic" }).Count
  fatalError = if ($fatalError -ne $null) { [string]$fatalError.Exception.Message } else { $null }
}
Write-JsonWithRetry -Path $summaryPath -Value $summary
$summary | ConvertTo-Json -Depth 8
