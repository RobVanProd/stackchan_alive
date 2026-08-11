param(
  [string]$DeviceHost = "192.168.1.238",
  [int]$DevicePort = 8789,
  [int]$BridgeLocalPort = 8765,
  [int]$DashboardPort = 8766,
  [string]$EvidenceRoot = "",
  [int]$DurationSeconds = 600,
  [int]$PollMilliseconds = 2000,
  [int]$PollTimeoutSeconds = 4,
  [string]$ExpectedFirmwareSha256 = "",
  [string]$FirmwareSourceCommit = "",
  [Parameter(Mandatory = $false)]
  [string]$CandidateManifestPath = "",
  [string]$HostRuntimeManifestPath = "output\pc-brain\latest\runtime_manifest.json",
  [int]$MinPowerVbusMv = 4400,
  [double]$MaxChipTempC = 70.0,
  [int]$MaxDisplayFrameUs = 50000,
  [switch]$RequireCameraHostVision,
  [switch]$RequireObservedTurn,
  [switch]$ContractProbe
)

$ErrorActionPreference = "Stop"

function Get-PropertyValue {
  param($Object, [string]$Name, $DefaultValue = $null)
  if ($null -eq $Object) { return $DefaultValue }
  $property = $Object.PSObject.Properties[$Name]
  if ($null -eq $property -or $null -eq $property.Value) { return $DefaultValue }
  return $property.Value
}

function Test-TrueValue {
  param($Value, [bool]$FailClosed = $false)
  if ($Value -is [bool]) { return $Value }
  if ($Value -is [ValueType]) {
    try {
      $numeric = [double]$Value
      if ($numeric -eq 0) { return $false }
      if ($numeric -eq 1) { return $true }
    } catch {}
    return $FailClosed
  }
  $normalized = ([string]$Value).Trim().ToLowerInvariant()
  if ($normalized -in @("true", "1", "yes", "on")) { return $true }
  if ($normalized -in @("false", "0", "no", "off")) { return $false }
  return $FailClosed
}

function Get-IntValue {
  param($Object, [string]$Name, [int64]$DefaultValue = 0)
  $value = Get-PropertyValue $Object $Name $null
  if ($null -eq $value) { return $DefaultValue }
  try { return [int64]$value } catch { return $DefaultValue }
}

function Get-DoubleValue {
  param($Object, [string]$Name, [double]$DefaultValue = 0.0)
  $value = Get-PropertyValue $Object $Name $null
  if ($null -eq $value) { return $DefaultValue }
  try { return [double]$value } catch { return $DefaultValue }
}

function Get-Sha256 {
  param([string]$Path)
  return (Get-FileHash -Algorithm SHA256 -LiteralPath $Path).Hash.ToLowerInvariant()
}

function Get-TextSha256 {
  param([string]$Text)
  $bytes = [System.Text.UTF8Encoding]::new($false).GetBytes($Text)
  $sha = [System.Security.Cryptography.SHA256]::Create()
  try { return ([BitConverter]::ToString($sha.ComputeHash($bytes))).Replace('-', '').ToLowerInvariant() } finally { $sha.Dispose() }
}

function Write-JsonAtomic {
  param([string]$Path, $Value)

  $absolutePath = [System.IO.Path]::GetFullPath($Path)
  $directory = [System.IO.Path]::GetDirectoryName($absolutePath)
  [System.IO.Directory]::CreateDirectory($directory) | Out-Null
  $tempPath = Join-Path $directory (([System.IO.Path]::GetFileName($absolutePath)) + ".tmp." + [guid]::NewGuid().ToString("N"))
  $backupPath = Join-Path $directory (([System.IO.Path]::GetFileName($absolutePath)) + ".bak." + [guid]::NewGuid().ToString("N"))
  $json = $Value | ConvertTo-Json -Depth 10
  $encoding = [System.Text.UTF8Encoding]::new($false)

  try {
    [System.IO.File]::WriteAllText($tempPath, $json, $encoding)
    if ([System.IO.File]::Exists($absolutePath)) {
      [System.IO.File]::Replace($tempPath, $absolutePath, $backupPath, $true)
      if ([System.IO.File]::Exists($backupPath)) {
        [System.IO.File]::Delete($backupPath)
      }
    } else {
      [System.IO.File]::Move($tempPath, $absolutePath)
    }
  } finally {
    foreach ($candidate in @($tempPath, $backupPath)) {
      try {
        if ([System.IO.File]::Exists($candidate)) {
          [System.IO.File]::Delete($candidate)
        }
      } catch {}
    }
  }
}

function Invoke-JsonGet {
  param([string]$Uri, [int]$TimeoutSeconds)
  try {
    return [pscustomobject]@{
      ok = $true
      json = Invoke-RestMethod -Method Get -Uri $Uri -TimeoutSec $TimeoutSeconds
      errorCode = ""
    }
  } catch {
    return [pscustomobject]@{
      ok = $false
      json = $null
      errorCode = $_.Exception.GetType().Name
    }
  }
}

function Get-BridgeSocketEvidence {
  try {
    $matches = @(Get-NetTCPConnection -State Established -LocalPort $BridgeLocalPort -ErrorAction Stop |
        Where-Object { $_.RemoteAddress -eq $DeviceHost })
    if ($matches.Count -ne 1) {
      return [pscustomobject]@{ present = $false; owningPid = 0 }
    }
    return [pscustomobject]@{
      present = $true
      owningPid = [int]$matches[0].OwningProcess
    }
  } catch {
    return [pscustomobject]@{ present = $false; owningPid = 0 }
  }
}

function Get-HostEvidence {
  $status = Invoke-JsonGet -Uri "http://127.0.0.1`:$DashboardPort/api/status" -TimeoutSeconds $PollTimeoutSeconds
  if (-not $status.ok) {
    return [pscustomobject]@{
      ok = $false
      operational = $false
      speechReady = $false
      sttHealthy = $false
      voiceConfigured = $false
      voiceSuccesses = 0
      playbackSuccesses = 0
    }
  }
  $bridge = Get-PropertyValue $status.json "bridge" $null
  $services = Get-PropertyValue $status.json "services" $null
  $stt = Get-PropertyValue $services "speechRecognition" $null
  $voice = Get-PropertyValue $services "voice" $null
  $playback = Get-PropertyValue $services "playback" $null
  return [pscustomobject]@{
    ok = $true
    operational = Test-TrueValue (Get-PropertyValue $bridge "operational" $false)
    speechReady = Test-TrueValue (Get-PropertyValue $bridge "speechReady" $false)
    sttHealthy = Test-TrueValue (Get-PropertyValue $stt "healthy" $false)
    voiceConfigured = Test-TrueValue (Get-PropertyValue $voice "configured" $false)
    voiceSuccesses = Get-IntValue $voice "successes" 0
    playbackSuccesses = Get-IntValue $playback "successes" 0
  }
}

function ConvertTo-BoundedSample {
  param($Debug, $Socket, $HostStatus, [int]$Sequence)
  return [pscustomobject][ordered]@{
    sequence = $Sequence
    generatedAt = [DateTime]::UtcNow.ToString("o")
    elapsedMs = [int64]$RunStopwatch.ElapsedMilliseconds
    ok = $true
    errorCode = ""
    uptimeMs = Get-IntValue $Debug "uptime_ms" -1
    bootCount = Get-IntValue $Debug "boot_count" -1
    resetReason = [string](Get-PropertyValue $Debug "reset_reason" "unknown")
    resetReasonCode = Get-IntValue $Debug "reset_reason_code" -1
    debugResponseTruncated = Test-TrueValue (Get-PropertyValue $Debug "debug_response_truncated" $true) $true
    controlPolicy = [string](Get-PropertyValue $Debug "debug_http_control_policy" "unknown")
    firmwareSha256 = ([string](Get-PropertyValue $Debug "ota_expected_sha256" "")).ToLowerInvariant()
    appConfirmed = Test-TrueValue (Get-PropertyValue $Debug "ota_current_app_confirmed" $false)
    motionRequested = Test-TrueValue (Get-PropertyValue $Debug "motion_requested" $true) $true
    motionAutonomous = Test-TrueValue (Get-PropertyValue $Debug "motion_autonomous" $true) $true
    motionEnabled = Test-TrueValue (Get-PropertyValue $Debug "motion_enabled" $true) $true
    servoPowerAllowed = Test-TrueValue (Get-PropertyValue $Debug "servo_power_allowed" $true) $true
    servoRailEnabled = Test-TrueValue (Get-PropertyValue $Debug "servo_rail_enabled" $true) $true
    servoTorqueEnabled = Test-TrueValue (Get-PropertyValue $Debug "servo_torque_enabled" $true) $true
    powerMotionRequested = Test-TrueValue (Get-PropertyValue $Debug "power_motion_requested" $true) $true
    powerMotionAllowed = Test-TrueValue (Get-PropertyValue $Debug "power_motion_allowed" $true) $true
    powerServoRailAllowed = Test-TrueValue (Get-PropertyValue $Debug "power_servo_rail_allowed" $true) $true
    motionActuatorReady = Test-TrueValue (Get-PropertyValue $Debug "motion_actuator_ready" $true) $true
    motionEnableRequests = Get-IntValue $Debug "motion_enable_requests" -1
    motionSessionRefreshes = Get-IntValue $Debug "motion_session_refreshes" -1
    motionLastWriteMs = Get-IntValue $Debug "motion_last_write_ms" -1
    servoRailEnableEntries = Get-IntValue $Debug "servo_rail_enable_entries" -1
    powerMotionGrants = Get-IntValue $Debug "power_motion_grants" -1
    powerForensicsSchema = [string](Get-PropertyValue $Debug "power_forensics_schema" "unknown")
    powerForensicsEnabled = Test-TrueValue (Get-PropertyValue $Debug "power_forensics_enabled" $false)
    powerForensicsIrqEnabled = Test-TrueValue (Get-PropertyValue $Debug "power_forensics_irq_enable_succeeded" $false)
    powerForensicsBootStatusValid = Test-TrueValue (Get-PropertyValue $Debug "power_forensics_boot_status_valid" $false)
    powerForensicsBootEventMask = Get-IntValue $Debug "power_forensics_boot_event_mask" -1
    powerForensicsBootEvent = [string](Get-PropertyValue $Debug "power_forensics_boot_event" "unknown")
    powerForensicsBootProtective = Test-TrueValue (Get-PropertyValue $Debug "power_forensics_boot_protective" $true)
    powerForensicsRuntimeEvents = Get-IntValue $Debug "power_forensics_runtime_event_polls" -1
    powerForensicsProtectiveEvents = Get-IntValue $Debug "power_forensics_runtime_protective_event_polls" -1
    powerForensicsReadFailures = Get-IntValue $Debug "power_forensics_read_failures" -1
    powerForensicsClearFailures = Get-IntValue $Debug "power_forensics_clear_failures" -1
    pmicVbusLossEntries = Get-IntValue $Debug "power_pmic_vbus_loss_entries" -1
    vbusHardFloorEntries = Get-IntValue $Debug "power_vbus_hard_floor_entries" -1
    powerReadFailures = Get-IntValue $Debug "power_read_failures" -1
    pmicInputReadFailures = Get-IntValue $Debug "power_pmic_input_state_read_failures" -1
    pmicConfigReadFailures = Get-IntValue $Debug "power_pmic_config_read_failures" -1
    powerVsysReadFailures = Get-IntValue $Debug "power_vsys_read_failures" -1
    chipTempReadFailures = Get-IntValue $Debug "chip_temp_read_failures" -1
    networkConnected = ([string](Get-PropertyValue $Debug "network_state" "")) -ceq "connected"
    bridgeReady = ([string](Get-PropertyValue $Debug "bridge_state" "")) -ceq "ready"
    bridgeUplinkReady = Test-TrueValue (Get-PropertyValue $Debug "bridge_uplink_ready" $false)
    socketPresent = [bool]$Socket.present
    bridgePid = [int]$Socket.owningPid
    hostRuntimePidAlive = $HostRuntimePid -gt 0 -and $null -ne (Get-Process -Id $HostRuntimePid -ErrorAction SilentlyContinue)
    wakeReady = (Test-TrueValue (Get-PropertyValue $Debug "sr_wake_task_started" $false)) -and
      (Test-TrueValue (Get-PropertyValue $Debug "sr_wake_sr_ready" $false))
    micReady = Test-TrueValue (Get-PropertyValue $Debug "sr_wake_mic_ready" $false)
    wakeAudioPauseRequested = Test-TrueValue (Get-PropertyValue $Debug "sr_wake_audio_pause_requested" $false)
    wakeAudioPaused = Test-TrueValue (Get-PropertyValue $Debug "sr_wake_audio_paused" $false)
    wakeCuePhase = [string](Get-PropertyValue $Debug "wake_cue_phase" "unknown")
    speakerReady = (Get-IntValue $Debug "compiled_enable_speaker" 0) -eq 1 -and
      (Test-TrueValue (Get-PropertyValue $Debug "speaker_enabled" $false))
    hostOperational = [bool]$HostStatus.operational
    hostSpeechReady = [bool]$HostStatus.speechReady
    hostSttHealthy = [bool]$HostStatus.sttHealthy
    hostVoiceConfigured = [bool]$HostStatus.voiceConfigured
    hostVoiceSuccesses = [int64]$HostStatus.voiceSuccesses
    hostPlaybackSuccesses = [int64]$HostStatus.playbackSuccesses
    powerVbusMv = Get-IntValue $Debug "power_vbus_mv" -1
    powerVbusReportedMinMv = Get-IntValue $Debug "power_vbus_min_mv" -1
    chipTempC = Get-DoubleValue $Debug "chip_temp_c" -1.0
    displayMaxFrameUs = Get-IntValue $Debug "display_window_max_frame_us" -1
    displaySlowFrames = Get-IntValue $Debug "display_window_slow_frames" -1
    heapFree = Get-IntValue $Debug "heap_free" -1
    heapMinFree = Get-IntValue $Debug "heap_min_free" -1
    wakeDetections = Get-IntValue $Debug "wake_cue_detections" -1
    wakeCapturesCompleted = Get-IntValue $Debug "wake_cue_captures_completed" -1
    uplinkTurns = Get-IntValue $Debug "bridge_uplink_turns" -1
    playbackStarts = Get-IntValue $Debug "bridge_downlink_playback_starts" -1
    playbackCompletions = Get-IntValue $Debug "bridge_downlink_playback_completions" -1
    playbackErrors = Get-IntValue $Debug "bridge_downlink_playback_errors" -1
    compiledCamera = Get-IntValue $Debug "compiled_enable_camera" -1
    compiledCameraHostVision = Get-IntValue $Debug "compiled_enable_camera_host_vision" -1
    cameraReady = Test-TrueValue (Get-PropertyValue $Debug "camera_ready" $false)
    cameraActive = Test-TrueValue (Get-PropertyValue $Debug "camera_active" $false)
    cameraFrames = Get-IntValue $Debug "camera_frames_captured" -1
    cameraHostFrameRequests = Get-IntValue $Debug "camera_host_frame_requests" -1
    cameraGazeTracking = Test-TrueValue (Get-PropertyValue $Debug "camera_gaze_tracking" $false)
    cameraGazeMotionOutput = Test-TrueValue (Get-PropertyValue $Debug "camera_gaze_motion_output_active" $true) $true
    audioStreamActive = Test-TrueValue (Get-PropertyValue $Debug "audio_stream_active" $false)
    speakerRunning = Test-TrueValue (Get-PropertyValue $Debug "speaker_running" $false)
  }
}

function Test-MotionBreach {
  param($Sample)
  return [bool]($Sample.motionRequested -or $Sample.motionAutonomous -or $Sample.motionEnabled -or
    $Sample.servoPowerAllowed -or $Sample.servoRailEnabled -or $Sample.servoTorqueEnabled -or
    $Sample.powerMotionRequested -or $Sample.powerMotionAllowed -or $Sample.powerServoRailAllowed -or
    $Sample.motionActuatorReady -or $Sample.cameraGazeMotionOutput)
}

function Invoke-SafetyMotionStop {
  $stop = Invoke-JsonGet -Uri "http://$DeviceHost`:$DevicePort/motion-stop" -TimeoutSeconds $PollTimeoutSeconds
  Start-Sleep -Milliseconds 350
  $verify = Invoke-JsonGet -Uri "http://$DeviceHost`:$DevicePort/debug" -TimeoutSeconds $PollTimeoutSeconds
  $verified = $false
  if ($verify.ok) {
    $verified = -not (Test-TrueValue (Get-PropertyValue $verify.json "motion_requested" $true) $true) -and
      -not (Test-TrueValue (Get-PropertyValue $verify.json "motion_autonomous" $true) $true) -and
      -not (Test-TrueValue (Get-PropertyValue $verify.json "motion_enabled" $true) $true) -and
      -not (Test-TrueValue (Get-PropertyValue $verify.json "servo_power_allowed" $true) $true) -and
      -not (Test-TrueValue (Get-PropertyValue $verify.json "servo_rail_enabled" $true) $true) -and
      -not (Test-TrueValue (Get-PropertyValue $verify.json "servo_torque_enabled" $true) $true) -and
      -not (Test-TrueValue (Get-PropertyValue $verify.json "power_motion_requested" $true) $true) -and
      -not (Test-TrueValue (Get-PropertyValue $verify.json "power_motion_allowed" $true) $true) -and
      -not (Test-TrueValue (Get-PropertyValue $verify.json "power_servo_rail_allowed" $true) $true) -and
      -not (Test-TrueValue (Get-PropertyValue $verify.json "motion_actuator_ready" $true) $true) -and
      -not (Test-TrueValue (Get-PropertyValue $verify.json "camera_gaze_motion_output_active" $true) $true)
  }
  return [ordered]@{
    generatedAt = [DateTime]::UtcNow.ToString("o")
    reason = "observed_motion_breach"
    stopRequestTransportOk = [bool]$stop.ok
    stopRequestAccepted = [bool]($stop.ok -and (Test-TrueValue (Get-PropertyValue $stop.json "accepted" $false)))
    postStopDebugAvailable = [bool]$verify.ok
    verifiedOff = [bool]$verified
    postStopDebug = $(if ($verify.ok) { $verify.json } else { $null })
    postStop = $(if ($verify.ok) {
        [ordered]@{
          motionRequested = Test-TrueValue (Get-PropertyValue $verify.json "motion_requested" $true) $true
          motionAutonomous = Test-TrueValue (Get-PropertyValue $verify.json "motion_autonomous" $true) $true
          motionEnabled = Test-TrueValue (Get-PropertyValue $verify.json "motion_enabled" $true) $true
          servoPowerAllowed = Test-TrueValue (Get-PropertyValue $verify.json "servo_power_allowed" $true) $true
          servoRailEnabled = Test-TrueValue (Get-PropertyValue $verify.json "servo_rail_enabled" $true) $true
          servoTorqueEnabled = Test-TrueValue (Get-PropertyValue $verify.json "servo_torque_enabled" $true) $true
          powerMotionRequested = Test-TrueValue (Get-PropertyValue $verify.json "power_motion_requested" $true) $true
          powerMotionAllowed = Test-TrueValue (Get-PropertyValue $verify.json "power_motion_allowed" $true) $true
          powerServoRailAllowed = Test-TrueValue (Get-PropertyValue $verify.json "power_servo_rail_allowed" $true) $true
          motionActuatorReady = Test-TrueValue (Get-PropertyValue $verify.json "motion_actuator_ready" $true) $true
          cameraGazeMotionOutput = Test-TrueValue (Get-PropertyValue $verify.json "camera_gaze_motion_output_active" $true) $true
        }
      } else { $null })
  }
}

function Test-SampleBinding {
  param($Sample)
  if ($Sample.debugResponseTruncated) { return "debug_response_truncated" }
  if ($Sample.controlPolicy -cne "emergency_stop_only") { return "control_policy_mismatch" }
  if ($Sample.firmwareSha256 -cne $ExpectedFirmwareSha256) { return "firmware_sha_mismatch" }
  if (-not $Sample.appConfirmed) { return "app_not_confirmed" }
  return ""
}

if ($ContractProbe) {
  [ordered]@{
    schema = "stackchan.passive-no-motion-contract-probe.v1"
    ordinaryRobotMethods = @("GET /debug")
    safetyException = "GET /motion-stop only after an observed motion breach"
    motionRefresh = $false
    networkMutation = $false
  } | ConvertTo-Json -Depth 4
  exit 0
}

if ($DurationSeconds -lt 1) { throw "DurationSeconds must be at least 1." }
if ($PollMilliseconds -lt 50 -or $PollMilliseconds -gt 2000) { throw "PollMilliseconds must be 50 through 2000." }
if ($PollTimeoutSeconds -lt 1 -or $PollTimeoutSeconds -gt 4) { throw "PollTimeoutSeconds must be 1 through 4." }
$ExpectedFirmwareSha256 = $ExpectedFirmwareSha256.Trim().ToLowerInvariant()
$FirmwareSourceCommit = $FirmwareSourceCommit.Trim().ToLowerInvariant()
if ($ExpectedFirmwareSha256 -notmatch "^[0-9a-f]{64}$") { throw "ExpectedFirmwareSha256 must be a full SHA-256." }
if ($FirmwareSourceCommit -notmatch "^[0-9a-f]{40}$") { throw "FirmwareSourceCommit must be a full Git commit SHA." }
if ([string]::IsNullOrWhiteSpace($CandidateManifestPath)) { throw "CandidateManifestPath is required." }

$RepoRoot = Resolve-Path (Join-Path $PSScriptRoot "..")
Set-Location $RepoRoot
$RunnerSourceCommit = (& git rev-parse HEAD).Trim().ToLowerInvariant()
$RunnerSourceDirty = -not [string]::IsNullOrWhiteSpace(((& git status --porcelain=v1 --untracked-files=normal) -join "`n"))
$RunnerSourceHash = Get-Sha256 $PSCommandPath
$CheckerSourcePath = Join-Path $PSScriptRoot "check_passive_no_motion_evidence.ps1"
$CheckerSourceHash = Get-Sha256 $CheckerSourcePath
$RunnerSourceBlob = ((& git rev-parse "$RunnerSourceCommit`:tools/run_passive_no_motion_evidence.ps1" 2>$null) -join "").Trim().ToLowerInvariant()
$CheckerSourceBlob = ((& git rev-parse "$RunnerSourceCommit`:tools/check_passive_no_motion_evidence.ps1" 2>$null) -join "").Trim().ToLowerInvariant()
if ($RunnerSourceBlob -notmatch "^[0-9a-f]{40}$" -or $CheckerSourceBlob -notmatch "^[0-9a-f]{40}$") {
  throw "Runner/checker are not tracked at the runner source commit."
}
& git cat-file -e "$FirmwareSourceCommit`^{commit}" 2>$null
if ($LASTEXITCODE -ne 0) { throw "FirmwareSourceCommit is unavailable in this repository." }

$CandidateManifestPath = (Resolve-Path -LiteralPath $CandidateManifestPath).Path
$CandidateManifest = Get-Content -Raw -LiteralPath $CandidateManifestPath | ConvertFrom-Json
$CandidateRoot = Split-Path -Parent $CandidateManifestPath
$CandidateFirmwarePath = Join-Path $CandidateRoot "firmware.bin"
$CandidateSourcePath = Join-Path $CandidateRoot ("source-" + $FirmwareSourceCommit.Substring(0, 8) + ".zip")
if (-not (Test-Path -LiteralPath $CandidateFirmwarePath -PathType Leaf) -or
    -not (Test-Path -LiteralPath $CandidateSourcePath -PathType Leaf)) {
  throw "Candidate packet is missing firmware.bin or its exact source archive."
}
$CandidateManifestHash = Get-Sha256 $CandidateManifestPath
$CandidateFirmwareHash = Get-Sha256 $CandidateFirmwarePath
$CandidateSourceHash = Get-Sha256 $CandidateSourcePath
if ([string](Get-PropertyValue $CandidateManifest "sourceCommit" "") -cne $FirmwareSourceCommit -or
    [string](Get-PropertyValue $CandidateManifest "firmwareSha256" "") -cne $ExpectedFirmwareSha256 -or
    $CandidateFirmwareHash -cne $ExpectedFirmwareSha256 -or
    [string](Get-PropertyValue $CandidateManifest "sourceArchiveSha256" "") -cne $CandidateSourceHash -or
    -not (Test-TrueValue (Get-PropertyValue (Get-PropertyValue $CandidateManifest "installation" $null) "confirmed" $false))) {
  throw "Candidate manifest/artifact/source binding failed."
}

$HostRuntimeManifestPath = if ([System.IO.Path]::IsPathRooted($HostRuntimeManifestPath)) {
  (Resolve-Path -LiteralPath $HostRuntimeManifestPath).Path
} else {
  (Resolve-Path -LiteralPath (Join-Path $RepoRoot $HostRuntimeManifestPath)).Path
}
$HostRuntimeManifest = Get-Content -Raw -LiteralPath $HostRuntimeManifestPath | ConvertFrom-Json
$HostRuntimeManifestHash = Get-Sha256 $HostRuntimeManifestPath
$HostRuntimePid = Get-IntValue $HostRuntimeManifest "bridgePid" 0
$HostSourceRoot = [System.IO.Path]::GetFullPath([string](Get-PropertyValue $HostRuntimeManifest "sourceRoot" ""))
if ([string](Get-PropertyValue $HostRuntimeManifest "schema" "") -cne "stackchan.pc-brain-runtime.v1" -or
    [string](Get-PropertyValue $HostRuntimeManifest "sourceCommit" "") -cne $FirmwareSourceCommit -or
    -not (Test-TrueValue (Get-PropertyValue $HostRuntimeManifest "sourceWorktreeClean" $false)) -or
    $HostRuntimePid -le 0 -or $HostSourceRoot -cne [System.IO.Path]::GetFullPath([string]$RepoRoot)) {
  throw "Host runtime manifest does not bind the exact firmware source and qualification root."
}
if ($null -eq (Get-Process -Id $HostRuntimePid -ErrorAction SilentlyContinue)) {
  throw "Host runtime PID is not alive."
}
$HostProcess = Get-CimInstance Win32_Process -Filter "ProcessId=$HostRuntimePid" -ErrorAction Stop
$HostProcessStartedAt = $HostProcess.CreationDate.ToUniversalTime()
$HostRuntimeGeneratedAt = [DateTime]::Parse([string](Get-PropertyValue $HostRuntimeManifest "generatedAt" "")).ToUniversalTime()
$HostCommandLine = [string]$HostProcess.CommandLine
if ($HostRuntimeGeneratedAt -lt $HostProcessStartedAt -or
    ($HostRuntimeGeneratedAt - $HostProcessStartedAt).TotalSeconds -gt 120 -or
    $HostCommandLine -notmatch '(?i)bridge[\\/]lan_service\.py' -or
    $HostCommandLine -notmatch ('(?i)--robot-host\s+' + [regex]::Escape($DeviceHost) + '(?:\s|$)')) {
  throw "Host runtime process creation/command line does not match its manifest and robot binding."
}
$HostCommandLineSha256 = Get-TextSha256 $HostCommandLine
& git diff --quiet $FirmwareSourceCommit -- bridge
if ($LASTEXITCODE -ne 0) { throw "Tracked bridge source differs from the host runtime commit." }

$EvidenceRoot = if ([System.IO.Path]::IsPathRooted($EvidenceRoot)) {
  [System.IO.Path]::GetFullPath($EvidenceRoot)
} elseif ([string]::IsNullOrWhiteSpace($EvidenceRoot)) {
  $generatedId = [guid]::NewGuid().ToString("N")
  [System.IO.Path]::GetFullPath((Join-Path $RepoRoot ("output\pc-brain\passive-no-motion-" + (Get-Date -Format "yyyyMMdd-HHmmss") + "-" + $generatedId.Substring(0, 8))))
} else {
  [System.IO.Path]::GetFullPath((Join-Path $RepoRoot $EvidenceRoot))
}
[string]$RunId = [guid]::NewGuid().ToString("N")
if (Test-Path -LiteralPath $EvidenceRoot) {
  if (@(Get-ChildItem -LiteralPath $EvidenceRoot -Force).Count -gt 0) { throw "EvidenceRoot must be new or empty." }
} else {
  [System.IO.Directory]::CreateDirectory($EvidenceRoot) | Out-Null
}
[System.IO.Directory]::CreateDirectory($EvidenceRoot) | Out-Null
[System.IO.File]::Copy($PSCommandPath, (Join-Path $EvidenceRoot "runner.ps1"), $false)
[System.IO.File]::Copy($CheckerSourcePath, (Join-Path $EvidenceRoot "checker.ps1"), $false)
[System.IO.File]::Copy($CandidateManifestPath, (Join-Path $EvidenceRoot "candidate-manifest.json"), $false)
[System.IO.File]::Copy($HostRuntimeManifestPath, (Join-Path $EvidenceRoot "host-runtime-manifest.json"), $false)
$startUtc = [DateTime]::UtcNow
$RunStopwatch = [System.Diagnostics.Stopwatch]::StartNew()
$deadline = $startUtc.AddSeconds($DurationSeconds)
$records = New-Object System.Collections.Generic.List[object]
$failedPolls = 0
$consecutiveFailedPolls = 0
$maxConsecutiveObserved = 0
$fatalError = ""
$safetyStop = $null
$preflightSample = $null
$MaxFailedPollRatio = 0.01
$MaxConsecutiveFailedPolls = 1

Write-JsonAtomic (Join-Path $EvidenceRoot "run.json") ([ordered]@{
    schema = "stackchan.passive-no-motion-run.v1"
    runId = $RunId
    startedAt = $startUtc.ToString("o")
    evidenceRoot = $EvidenceRoot
    qualificationRoot = [string]$RepoRoot
    deviceHost = $DeviceHost
    devicePort = $DevicePort
    durationSeconds = $DurationSeconds
    pollMilliseconds = $PollMilliseconds
    pollTimeoutSeconds = $PollTimeoutSeconds
    expectedFirmwareSha256 = $ExpectedFirmwareSha256
    firmwareSourceCommit = $FirmwareSourceCommit
    runnerSourceCommit = $RunnerSourceCommit
    runnerSourceDirty = $RunnerSourceDirty
    runnerSourceSha256 = $RunnerSourceHash
    runnerSourceBlob = $RunnerSourceBlob
    checkerSourceSha256 = $CheckerSourceHash
    checkerSourceBlob = $CheckerSourceBlob
    candidateManifestPath = $CandidateManifestPath
    candidateManifestSha256 = $CandidateManifestHash
    candidateFirmwarePath = $CandidateFirmwarePath
    candidateFirmwareSha256 = $CandidateFirmwareHash
    candidateSourcePath = $CandidateSourcePath
    candidateSourceSha256 = $CandidateSourceHash
    hostRuntimeManifestPath = $HostRuntimeManifestPath
    hostRuntimeManifestSha256 = $HostRuntimeManifestHash
    hostRuntimePid = $HostRuntimePid
    hostProcessStartedAt = $HostProcessStartedAt.ToString("o")
    hostRuntimeGeneratedAt = $HostRuntimeGeneratedAt.ToString("o")
    hostCommandLineSha256 = $HostCommandLineSha256
    controlPolicy = "preflight_pending"
    ordinaryRobotMethods = @("GET /debug")
    safetyException = "GET /motion-stop only after an observed motion breach"
    requireCameraHostVision = [bool]$RequireCameraHostVision
    requireObservedTurn = [bool]$RequireObservedTurn
  })

try {
  $debugUri = "http://$DeviceHost`:$DevicePort/debug"
  $preflight = Invoke-JsonGet -Uri $debugUri -TimeoutSeconds $PollTimeoutSeconds
  if (-not $preflight.ok) {
    $fatalError = "preflight_debug_unavailable"
  } else {
    $preflightSample = ConvertTo-BoundedSample $preflight.json (Get-BridgeSocketEvidence) (Get-HostEvidence) 0
    $records.Add($preflightSample)
    Write-JsonAtomic (Join-Path $EvidenceRoot "preflight.json") ([ordered]@{ runId = $RunId; sample = $preflightSample })
    if (Test-MotionBreach $preflightSample) {
      $safetyStop = Invoke-SafetyMotionStop
      Write-JsonAtomic (Join-Path $EvidenceRoot "safety-stop.json") ([ordered]@{ runId = $RunId; result = $safetyStop })
      $fatalError = "observed_motion_breach"
    } else {
      $preflightBindingIssue = Test-SampleBinding $preflightSample
      if (-not [string]::IsNullOrWhiteSpace($preflightBindingIssue)) { $fatalError = $preflightBindingIssue }
    }
    if ([string]::IsNullOrWhiteSpace($fatalError)) {
      $ownerMatches = @(Get-NetTCPConnection -State Established -LocalPort $BridgeLocalPort -ErrorAction SilentlyContinue |
          Where-Object { $_.RemoteAddress -eq $DeviceHost -and [int]$_.OwningProcess -eq $HostRuntimePid })
      if ($ownerMatches.Count -ne 1) { $fatalError = "host_socket_pid_mismatch" }
    }
  }

  $nextPollDueMs = [int64]$RunStopwatch.ElapsedMilliseconds + $PollMilliseconds
  while ([string]::IsNullOrWhiteSpace($fatalError) -and $RunStopwatch.ElapsedMilliseconds -lt ($DurationSeconds * 1000)) {
    $sleepMilliseconds = [int]($nextPollDueMs - $RunStopwatch.ElapsedMilliseconds)
    if ($sleepMilliseconds -gt 0) { Start-Sleep -Milliseconds $sleepMilliseconds }
    if ($RunStopwatch.ElapsedMilliseconds -ge ($DurationSeconds * 1000)) { break }
    $nextPollDueMs += $PollMilliseconds
    $sequence = $records.Count
    $probe = Invoke-JsonGet -Uri $debugUri -TimeoutSeconds $PollTimeoutSeconds
    if (-not $probe.ok) {
      $failedPolls += 1
      $consecutiveFailedPolls += 1
      $maxConsecutiveObserved = [math]::Max($maxConsecutiveObserved, $consecutiveFailedPolls)
      $failedSocket = Get-BridgeSocketEvidence
      $failedHost = Get-HostEvidence
      $records.Add([pscustomobject][ordered]@{
          sequence = $sequence
          generatedAt = [DateTime]::UtcNow.ToString("o")
          elapsedMs = [int64]$RunStopwatch.ElapsedMilliseconds
          ok = $false
          errorCode = $probe.errorCode
          socketPresent = [bool]$failedSocket.present
          bridgePid = [int]$failedSocket.owningPid
          hostOperational = [bool]$failedHost.operational
          hostRuntimePidAlive = $null -ne (Get-Process -Id $HostRuntimePid -ErrorAction SilentlyContinue)
        })
    } else {
      $consecutiveFailedPolls = 0
      $sample = ConvertTo-BoundedSample $probe.json (Get-BridgeSocketEvidence) (Get-HostEvidence) $sequence
      $records.Add($sample)
      Write-JsonAtomic (Join-Path $EvidenceRoot "polls.json") ([ordered]@{
          schema = "stackchan.passive-no-motion-polls.v1"
          runId = $RunId
          records = @($records | ForEach-Object { $_ })
        })
      if (Test-MotionBreach $sample) {
        $safetyStop = Invoke-SafetyMotionStop
        Write-JsonAtomic (Join-Path $EvidenceRoot "safety-stop.json") ([ordered]@{ runId = $RunId; result = $safetyStop })
        $fatalError = "observed_motion_breach"
        break
      }
      $bindingIssue = Test-SampleBinding $sample
      if (-not [string]::IsNullOrWhiteSpace($bindingIssue)) {
        $fatalError = $bindingIssue
        break
      }
    }

    Write-JsonAtomic (Join-Path $EvidenceRoot "polls.json") ([ordered]@{
        schema = "stackchan.passive-no-motion-polls.v1"
        runId = $RunId
        records = @($records | ForEach-Object { $_ })
      })
    Write-JsonAtomic (Join-Path $EvidenceRoot "progress.json") ([ordered]@{
        schema = "stackchan.passive-no-motion-progress.v1"
        runId = $RunId
        status = "running"
        generatedAt = [DateTime]::UtcNow.ToString("o")
        records = $records.Count
        failedPolls = $failedPolls
        maxConsecutiveFailedPolls = $maxConsecutiveObserved
        fatalError = $fatalError
      })
  }
} catch {
  $fatalError = $_.Exception.Message
} finally {
  $endedUtc = [DateTime]::UtcNow
  $elapsedDurationMs = [int64]$RunStopwatch.ElapsedMilliseconds
  $RunnerSourceCommitEnd = (& git rev-parse HEAD).Trim().ToLowerInvariant()
  $RunnerSourceDirtyEnd = -not [string]::IsNullOrWhiteSpace(((& git status --porcelain=v1 --untracked-files=normal) -join "`n"))
  $RunnerSourceHashEnd = Get-Sha256 $PSCommandPath
  $CheckerSourceHashEnd = Get-Sha256 $CheckerSourcePath
  $CandidateManifestHashEnd = Get-Sha256 $CandidateManifestPath
  $CandidateFirmwareHashEnd = Get-Sha256 $CandidateFirmwarePath
  $CandidateSourceHashEnd = Get-Sha256 $CandidateSourcePath
  $HostRuntimeManifestHashEnd = Get-Sha256 $HostRuntimeManifestPath
  $HostRuntimePidAliveEnd = $null -ne (Get-Process -Id $HostRuntimePid -ErrorAction SilentlyContinue)
  $okRecords = @($records | Where-Object { $_.ok -eq $true })
  $issues = New-Object System.Collections.Generic.List[string]
  if (-not [string]::IsNullOrWhiteSpace($fatalError)) { $issues.Add("fatal_error") }
  if ($RunnerSourceDirty -or $RunnerSourceDirtyEnd) { $issues.Add("runner_source_dirty") }
  if ($RunnerSourceCommitEnd -cne $RunnerSourceCommit -or $RunnerSourceHashEnd -cne $RunnerSourceHash -or
      $CheckerSourceHashEnd -cne $CheckerSourceHash) { $issues.Add("runner_source_changed") }
  if ($CandidateManifestHashEnd -cne $CandidateManifestHash -or
      $CandidateFirmwareHashEnd -cne $CandidateFirmwareHash -or
      $CandidateSourceHashEnd -cne $CandidateSourceHash) { $issues.Add("candidate_binding_changed") }
  if ($HostRuntimeManifestHashEnd -cne $HostRuntimeManifestHash -or -not $HostRuntimePidAliveEnd) { $issues.Add("host_runtime_changed") }
  if ($okRecords.Count -eq 0) { $issues.Add("no_successful_polls") }
  $failedPollRatio = if ($records.Count -gt 0) { $failedPolls / [double]$records.Count } else { 1.0 }
  if (($records.Count -lt 100 -and $failedPolls -gt 0) -or
      ($records.Count -ge 100 -and $failedPollRatio -gt $MaxFailedPollRatio)) { $issues.Add("failed_polls_exceeded") }
  if ($maxConsecutiveObserved -gt $MaxConsecutiveFailedPolls) { $issues.Add("consecutive_failed_polls_exceeded") }

  $first = $okRecords | Select-Object -First 1
  $last = $okRecords | Select-Object -Last 1
  $resetReasons = @($okRecords | ForEach-Object { [string]$_.resetReason } | Sort-Object -Unique)
  $resetCodes = @($okRecords | ForEach-Object { [int64]$_.resetReasonCode } | Sort-Object -Unique)
  $bootCounts = @($okRecords | ForEach-Object { [int64]$_.bootCount } | Sort-Object -Unique)
  $uptimeRegressions = 0
  for ($index = 1; $index -lt $okRecords.Count; $index++) {
    if ([int64]$okRecords[$index].uptimeMs -lt [int64]$okRecords[$index - 1].uptimeMs) { $uptimeRegressions += 1 }
  }
  if ($resetReasons.Count -ne 1 -or $resetReasons[0] -notin @("software", "poweron", "power-on")) { $issues.Add("reset_reason_not_clean") }
  if ($bootCounts.Count -ne 1 -or $uptimeRegressions -gt 0) { $issues.Add("boot_not_stable") }

  $sampleCoverageMs = if ($null -ne $first -and $null -ne $last) {
    [int64]$last.elapsedMs - [int64]$first.elapsedMs
  } else { 0 }
  $maxPollGapMs = 0
  for ($index = 1; $index -lt $records.Count; $index++) {
    $maxPollGapMs = [math]::Max($maxPollGapMs, [int64]$records[$index].elapsedMs - [int64]$records[$index - 1].elapsedMs)
  }
  $MaxAllowedPollGapMs = 8000
  $minimumCoverageMs = [math]::Max(0, ($DurationSeconds * 1000) - [math]::Max(2000, 2 * $PollMilliseconds))
  $minimumOkPolls = [math]::Max(1, [math]::Floor(($DurationSeconds * 1000 / [double]$PollMilliseconds) * 0.8))
  if ($sampleCoverageMs -lt $minimumCoverageMs -or $okRecords.Count -lt $minimumOkPolls) { $issues.Add("poll_coverage_insufficient") }
  if ($maxPollGapMs -gt $MaxAllowedPollGapMs) { $issues.Add("poll_gap_exceeded") }
  if ($DurationSeconds -ge 600 -and ($PollMilliseconds -ne 2000 -or $PollTimeoutSeconds -ne 4)) {
    $issues.Add("qualification_poll_contract_mismatch")
  }

  $motionBreachSamples = @($okRecords | Where-Object { Test-MotionBreach $_ }).Count
  if ($motionBreachSamples -gt 0) { $issues.Add("motion_breach") }
  foreach ($counter in @("motionEnableRequests", "motionSessionRefreshes", "motionLastWriteMs", "servoRailEnableEntries", "powerMotionGrants")) {
    if (@($okRecords | Where-Object { [int64]$_.$counter -ne 0 }).Count -gt 0) { $issues.Add("nonzero_$counter") }
  }

  $allReadyFields = @("networkConnected", "bridgeReady", "bridgeUplinkReady", "socketPresent", "hostRuntimePidAlive", "wakeReady", "speakerReady", "hostOperational", "hostSpeechReady", "hostSttHealthy", "hostVoiceConfigured")
  foreach ($field in $allReadyFields) {
    if ($okRecords.Count -eq 0 -or @($okRecords | Where-Object { -not [bool]$_.$field }).Count -gt 0) { $issues.Add("not_ready_$field") }
  }
  $invalidMicSamples = @($okRecords | Where-Object {
      -not [bool]$_.micReady -and -not ([bool]$_.wakeAudioPauseRequested -or [bool]$_.wakeAudioPaused -or
        [bool]$_.audioStreamActive -or [bool]$_.speakerRunning -or
        ([string]$_.wakeCuePhase -notin @("", "idle", "unknown")))
    }).Count
  if ($invalidMicSamples -gt 0) { $issues.Add("not_ready_micReady") }
  if (@($okRecords | Where-Object { [int]$_.bridgePid -ne $HostRuntimePid }).Count -gt 0) {
    $issues.Add("host_socket_pid_changed")
  }

  $minVbus = if ($okRecords.Count -gt 0) { [int64](($okRecords | Measure-Object -Property powerVbusMv -Minimum).Minimum) } else { -1 }
  $minReportedVbus = if ($okRecords.Count -gt 0) { [int64](($okRecords | Measure-Object -Property powerVbusReportedMinMv -Minimum).Minimum) } else { -1 }
  $maxTemp = if ($okRecords.Count -gt 0) { [double](($okRecords | Measure-Object -Property chipTempC -Maximum).Maximum) } else { -1 }
  $maxFrame = if ($okRecords.Count -gt 0) { [int64](($okRecords | Measure-Object -Property displayMaxFrameUs -Maximum).Maximum) } else { -1 }
  if ($minVbus -lt $MinPowerVbusMv -or $minReportedVbus -lt $MinPowerVbusMv) { $issues.Add("vbus_floor_breached") }
  if ($maxTemp -gt $MaxChipTempC) { $issues.Add("temperature_limit_breached") }
  if ($maxFrame -le 0 -or $maxFrame -gt $MaxDisplayFrameUs) { $issues.Add("display_frame_limit_breached") }

  $powerForensicsReadySamples = @($okRecords | Where-Object {
      $_.powerForensicsSchema -ceq "axp2101-v2" -and $_.powerForensicsEnabled -and
      $_.powerForensicsIrqEnabled -and $_.powerForensicsBootStatusValid -and
      $_.powerForensicsBootEventMask -eq 0 -and $_.powerForensicsBootEvent -ceq "none" -and
      -not $_.powerForensicsBootProtective
    }).Count
  $powerCounterNames = @(
    "powerForensicsRuntimeEvents", "powerForensicsProtectiveEvents", "powerForensicsReadFailures",
    "powerForensicsClearFailures", "pmicVbusLossEntries", "vbusHardFloorEntries", "powerReadFailures",
    "pmicInputReadFailures", "pmicConfigReadFailures", "powerVsysReadFailures", "chipTempReadFailures"
  )
  $powerCounterDeltas = [ordered]@{}
  foreach ($counter in $powerCounterNames) {
    $baseline = if ($null -ne $first) { [int64]$first.$counter } else { -1 }
    $latest = if ($null -ne $last) { [int64]$last.$counter } else { -1 }
    $powerCounterDeltas[$counter] = $latest - $baseline
    if ($baseline -lt 0 -or $latest -lt 0 -or $latest -ne $baseline) { $issues.Add("power_counter_changed_$counter") }
  }
  if ($powerForensicsReadySamples -ne $okRecords.Count) { $issues.Add("power_forensics_not_clean") }

  $captureDelta = if ($null -ne $first -and $null -ne $last) { [int64]$last.wakeCapturesCompleted - [int64]$first.wakeCapturesCompleted } else { 0 }
  $turnDelta = if ($null -ne $first -and $null -ne $last) { [int64]$last.uplinkTurns - [int64]$first.uplinkTurns } else { 0 }
  $playbackDelta = if ($null -ne $first -and $null -ne $last) { [int64]$last.playbackCompletions - [int64]$first.playbackCompletions } else { 0 }
  $playbackErrorDelta = if ($null -ne $first -and $null -ne $last) { [int64]$last.playbackErrors - [int64]$first.playbackErrors } else { 0 }
  if ($RequireObservedTurn -and ($captureDelta -lt 1 -or $turnDelta -lt 1 -or $playbackDelta -lt 1 -or $playbackErrorDelta -ne 0)) { $issues.Add("required_turn_not_observed") }
  $cameraReadySamples = @($okRecords | Where-Object { $_.compiledCamera -eq 1 -and $_.compiledCameraHostVision -eq 1 -and $_.cameraReady -and $_.cameraActive }).Count
  $cameraFrameDelta = if ($null -ne $first -and $null -ne $last) { [int64]$last.cameraFrames - [int64]$first.cameraFrames } else { 0 }
  $cameraHostRequestDelta = if ($null -ne $first -and $null -ne $last) { [int64]$last.cameraHostFrameRequests - [int64]$first.cameraHostFrameRequests } else { 0 }
  if ($RequireCameraHostVision -and ($cameraReadySamples -ne $okRecords.Count -or $cameraFrameDelta -lt 1 -or $cameraHostRequestDelta -lt 1)) { $issues.Add("camera_host_vision_not_observed") }
  if (@($okRecords | Where-Object { $_.cameraGazeMotionOutput }).Count -gt 0) { $issues.Add("camera_motion_policy_active") }

  $uniqueIssues = @($issues | Sort-Object -Unique)
  $summary = [ordered]@{
    schema = "stackchan.passive-no-motion-summary.v1"
    runId = $RunId
    status = $(if ($uniqueIssues.Count -eq 0) { "pass" } else { "fail" })
    issues = $uniqueIssues
    startedAt = $startUtc.ToString("o")
    endedAt = $endedUtc.ToString("o")
    requestedDurationSeconds = $DurationSeconds
    durationSeconds = [math]::Floor($elapsedDurationMs / 1000.0)
    elapsedDurationMs = $elapsedDurationMs
    evidenceRoot = $EvidenceRoot
    firmwareSourceCommit = $FirmwareSourceCommit
    installedFirmwareSha256 = $ExpectedFirmwareSha256
    candidateManifestSha256 = $CandidateManifestHash
    candidateManifestSha256End = $CandidateManifestHashEnd
    candidateFirmwareSha256 = $CandidateFirmwareHash
    candidateFirmwareSha256End = $CandidateFirmwareHashEnd
    candidateSourceSha256 = $CandidateSourceHash
    candidateSourceSha256End = $CandidateSourceHashEnd
    runnerSourceCommit = $RunnerSourceCommit
    runnerSourceCommitEnd = $RunnerSourceCommitEnd
    runnerSourceDirty = $RunnerSourceDirty
    runnerSourceDirtyEnd = $RunnerSourceDirtyEnd
    runnerSourceSha256 = $RunnerSourceHash
    runnerSourceSha256End = $RunnerSourceHashEnd
    checkerSourceSha256 = $CheckerSourceHash
    checkerSourceSha256End = $CheckerSourceHashEnd
    hostRuntimeManifestSha256 = $HostRuntimeManifestHash
    hostRuntimeManifestSha256End = $HostRuntimeManifestHashEnd
    hostRuntimePid = $HostRuntimePid
    hostRuntimePidAliveEnd = $HostRuntimePidAliveEnd
    controlPolicy = $(if ($null -ne $preflightSample) { $preflightSample.controlPolicy } else { "unknown" })
    ordinaryRobotMethods = @("GET /debug")
    safetyStop = $safetyStop
    records = $records.Count
    okPolls = $okRecords.Count
    failedPolls = $failedPolls
    failedPollRatio = $failedPollRatio
    allowedMaxFailedPollRatio = $MaxFailedPollRatio
    maxConsecutiveFailedPolls = $maxConsecutiveObserved
    allowedMaxConsecutiveFailedPolls = $MaxConsecutiveFailedPolls
    sampleCoverageMs = $sampleCoverageMs
    maxPollGapMs = $maxPollGapMs
    maxAllowedPollGapMs = $MaxAllowedPollGapMs
    minimumCoverageMs = $minimumCoverageMs
    minimumOkPolls = $minimumOkPolls
    fatalError = $fatalError
    resetReasons = $resetReasons
    resetReasonCodes = $resetCodes
    bootCounts = $bootCounts
    uptimeRegressions = $uptimeRegressions
    motionBreachSamples = $motionBreachSamples
    motionEnableRequestsBaseline = $(if ($null -ne $first) { $first.motionEnableRequests } else { -1 })
    motionEnableRequestsLatest = $(if ($null -ne $last) { $last.motionEnableRequests } else { -1 })
    motionSessionRefreshesBaseline = $(if ($null -ne $first) { $first.motionSessionRefreshes } else { -1 })
    motionSessionRefreshesLatest = $(if ($null -ne $last) { $last.motionSessionRefreshes } else { -1 })
    motionLastWriteMsLatest = $(if ($null -ne $last) { $last.motionLastWriteMs } else { -1 })
    servoRailEnableEntriesLatest = $(if ($null -ne $last) { $last.servoRailEnableEntries } else { -1 })
    powerMotionGrantsLatest = $(if ($null -ne $last) { $last.powerMotionGrants } else { -1 })
    powerForensicsReadySamples = $powerForensicsReadySamples
    powerCounterDeltas = $powerCounterDeltas
    readySamples = [ordered]@{
      network = @($okRecords | Where-Object { $_.networkConnected }).Count
      bridge = @($okRecords | Where-Object { $_.bridgeReady -and $_.bridgeUplinkReady }).Count
      socket = @($okRecords | Where-Object { $_.socketPresent }).Count
      hostRuntimePid = @($okRecords | Where-Object { $_.hostRuntimePidAlive }).Count
      wake = @($okRecords | Where-Object { $_.wakeReady }).Count
      mic = @($okRecords | Where-Object { $_.micReady }).Count
      speaker = @($okRecords | Where-Object { $_.speakerReady }).Count
      host = @($okRecords | Where-Object { $_.hostOperational -and $_.hostSpeechReady -and $_.hostSttHealthy -and $_.hostVoiceConfigured }).Count
      cameraHostVision = $cameraReadySamples
    }
    minPowerVbusMv = $minVbus
    minPowerVbusReportedMv = $minReportedVbus
    maxChipTempC = $maxTemp
    maxDisplayFrameUs = $maxFrame
    wakeCaptureCompletedDelta = $captureDelta
    uplinkTurnDelta = $turnDelta
    playbackCompletionDelta = $playbackDelta
    playbackErrorDelta = $playbackErrorDelta
    cameraFrameDelta = $cameraFrameDelta
    cameraHostFrameRequestDelta = $cameraHostRequestDelta
    requireObservedTurn = [bool]$RequireObservedTurn
    requireCameraHostVision = [bool]$RequireCameraHostVision
  }
  Write-JsonAtomic (Join-Path $EvidenceRoot "polls.json") ([ordered]@{
      schema = "stackchan.passive-no-motion-polls.v1"
      runId = $RunId
      records = @($records | ForEach-Object { $_ })
    })
  $runRecord = Get-Content -Raw -LiteralPath (Join-Path $EvidenceRoot "run.json") | ConvertFrom-Json
  $runRecord.controlPolicy = $summary.controlPolicy
  $runRecord | Add-Member -NotePropertyName completedAt -NotePropertyValue $endedUtc.ToString("o") -Force
  Write-JsonAtomic (Join-Path $EvidenceRoot "run.json") $runRecord
  Write-JsonAtomic (Join-Path $EvidenceRoot "summary.json") $summary
  $seal = [ordered]@{
    schema = "stackchan.passive-no-motion-seal.v1"
    runId = $RunId
    sealedAt = [DateTime]::UtcNow.ToString("o")
    summaryStatus = $summary.status
    files = [ordered]@{
      "run.json" = Get-Sha256 (Join-Path $EvidenceRoot "run.json")
      "polls.json" = Get-Sha256 (Join-Path $EvidenceRoot "polls.json")
      "summary.json" = Get-Sha256 (Join-Path $EvidenceRoot "summary.json")
      "preflight.json" = $(if (Test-Path (Join-Path $EvidenceRoot "preflight.json")) { Get-Sha256 (Join-Path $EvidenceRoot "preflight.json") } else { "" })
      "runner.ps1" = Get-Sha256 (Join-Path $EvidenceRoot "runner.ps1")
      "checker.ps1" = Get-Sha256 (Join-Path $EvidenceRoot "checker.ps1")
      "candidate-manifest.json" = Get-Sha256 (Join-Path $EvidenceRoot "candidate-manifest.json")
      "host-runtime-manifest.json" = Get-Sha256 (Join-Path $EvidenceRoot "host-runtime-manifest.json")
      "safety-stop.json" = $(if (Test-Path (Join-Path $EvidenceRoot "safety-stop.json")) { Get-Sha256 (Join-Path $EvidenceRoot "safety-stop.json") } else { "" })
    }
    externalBindings = [ordered]@{
      candidateFirmwarePath = $CandidateFirmwarePath
      candidateFirmwareSha256 = $CandidateFirmwareHashEnd
      candidateSourcePath = $CandidateSourcePath
      candidateSourceSha256 = $CandidateSourceHashEnd
    }
  }
  Write-JsonAtomic (Join-Path $EvidenceRoot "seal.json") $seal
  Write-JsonAtomic (Join-Path $EvidenceRoot "progress.json") ([ordered]@{
      schema = "stackchan.passive-no-motion-progress.v1"
      runId = $RunId
      status = "sealed"
      generatedAt = [DateTime]::UtcNow.ToString("o")
      summaryStatus = $summary.status
      issues = $summary.issues
    })
  $summary | ConvertTo-Json -Depth 10
  if ($summary.status -ne "pass") { exit 1 }
}
