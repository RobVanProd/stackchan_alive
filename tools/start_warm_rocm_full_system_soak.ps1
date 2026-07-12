param(
  [string]$DeviceHost = "192.168.1.238",
  [int]$DevicePort = 8789,
  [int]$DurationSeconds = 28800,
  [int]$PollSeconds = 30,
  [int]$PollTimeoutSeconds = 4,
  [int]$MotionRefreshSeconds = 300,
  [int]$MotionRefreshInitialDelaySeconds = 150,
  [double]$MinMotionUnsuppressedSampleRatio = 0.50,
  [double]$MaxAllowedChipTempC = 68,
  [int]$MinPowerVbusMv = 4400,
  [int]$MinPowerVbusReportedMv = 4400,
  [int]$MotionPowerSoftFloorMv = 4550,
  [int]$MaxDisplayFrameUs = 50000,
  [int]$MaxFailedPolls = 0,
  [double]$MaxFailedPollRatio = 0.01,
  [int]$MinPollsForFailedRatio = 100,
  [int]$MaxConsecutiveFailedPolls = 1,
  [string]$RvcWorkerUrl = "http://127.0.0.1:5055",
  [string]$EvidenceRoot = "",
  [switch]$NoSerial,
  [switch]$SkipBridgeRestart,
  [switch]$SkipWorkerRestart,
  [switch]$OperatorPresent,
  [switch]$BodyClear,
  [switch]$ConfirmServoRisk,
  [switch]$RequirePowerForensics,
  [switch]$RequireFinalIntegration,
  [switch]$AllowLegacyMotionTelemetry
)

$ErrorActionPreference = "Stop"

$RepoRoot = Resolve-Path (Join-Path $PSScriptRoot "..")
Set-Location $RepoRoot

if ([string]::IsNullOrWhiteSpace($EvidenceRoot)) {
  $stamp = Get-Date -Format "yyyyMMdd-HHmmss"
  $EvidenceRoot = "output\pc-brain\full-system-soak-warm-rocm-servo-$stamp"
}

if (-not $OperatorPresent -or -not $BodyClear -or -not $ConfirmServoRisk) {
  throw "Refusing to start servo-enabled warm ROCm soak without -OperatorPresent -BodyClear -ConfirmServoRisk. This wrapper calls /motion-resume and refreshes motion during the soak."
}
try { $workerUri = [uri]$RvcWorkerUrl } catch { throw "RvcWorkerUrl must be a valid local HTTP URL." }
if ($workerUri.Scheme -ne "http" -or $workerUri.Host -notin @("127.0.0.1", "localhost", "::1") -or
    -not [string]::IsNullOrWhiteSpace($workerUri.UserInfo)) {
  throw "RvcWorkerUrl must use unauthenticated local loopback HTTP."
}
$RvcWorkerUrl = $RvcWorkerUrl.TrimEnd("/")

function Invoke-JsonEndpoint {
  param([string]$Path, [int]$TimeoutSeconds = 5)
  $url = "http://$DeviceHost`:$DevicePort$Path"
  try {
    return Invoke-RestMethod -Uri $url -TimeoutSec $TimeoutSeconds
  } catch {
    throw "Robot endpoint failed: $url :: $($_.Exception.Message)"
  }
}

function Wait-ForMotionEnabled {
  param([int]$TimeoutSeconds = 12)
  $deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
  do {
    Start-Sleep -Milliseconds 500
    $debug = Invoke-JsonEndpoint -Path "/debug" -TimeoutSeconds 5
    if ([bool]$debug.motion_enabled) {
      return $debug
    }
  } while ([DateTime]::UtcNow -lt $deadline)
  return $debug
}

function Enable-MotionWithRetry {
  param(
    [int]$TimeoutSeconds = 20,
    [int]$RetrySeconds = 3
  )
  $deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
  $requests = New-Object System.Collections.Generic.List[object]
  $lastRequest = $null
  $after = $null
  do {
    $lastRequest = Invoke-JsonEndpoint -Path "/motion-resume" -TimeoutSeconds 5
    $requests.Add([ordered]@{
        at = (Get-Date).ToString("o")
        response = $lastRequest
      })
    $after = Wait-ForMotionEnabled -TimeoutSeconds $RetrySeconds
    if ([bool]$after.motion_enabled) {
      break
    }
  } while ([DateTime]::UtcNow -lt $deadline)

  return [pscustomobject]@{
    request = $lastRequest
    requests = $requests
    after = $after
  }
}

function Has-JsonProperty {
  param($Object, [string]$Name)
  if ($null -eq $Object) {
    return $false
  }
  return $null -ne $Object.PSObject.Properties[$Name]
}

function Stop-MotionVerified {
  param([int]$Attempts = 4)
  $records = New-Object System.Collections.Generic.List[object]
  for ($attempt = 1; $attempt -le $Attempts; ++$attempt) {
    $request = $null
    $debug = $null
    try { $request = Invoke-JsonEndpoint -Path "/motion-stop" -TimeoutSeconds 5 } catch {}
    Start-Sleep -Milliseconds 350
    try { $debug = Invoke-JsonEndpoint -Path "/debug" -TimeoutSeconds 5 } catch {}
    $verified = $null -ne $debug -and
      -not [bool]$debug.motion_enabled -and
      -not [bool]$debug.servo_rail_enabled -and
      -not [bool]$debug.servo_torque_enabled
    $records.Add([ordered]@{ attempt = $attempt; request = $request; debug = $debug; verified = $verified })
    if ($verified) { return [pscustomobject]@{ verified = $true; attempts = $attempt; records = $records; debug = $debug } }
  }
  return [pscustomobject]@{ verified = $false; attempts = $Attempts; records = $records; debug = $debug }
}

function Stop-MotionAndThrow {
  param([string]$Message, [string]$PrimaryEvidencePath)
  $stop = Stop-MotionVerified
  $cleanupPath = Join-Path $script:evidencePath "preflight-failure-motion-stop.json"
  [ordered]@{
    schema = "stackchan.warm-rocm-preflight-failure-stop.v1"
    capturedAt = (Get-Date).ToString("o")
    reason = $Message
    stop = $stop
  } | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $cleanupPath -Encoding UTF8
  throw "$Message Motion-stop verified=$($stop.verified). Evidence: $PrimaryEvidencePath. Cleanup: $cleanupPath"
}

New-Item -ItemType Directory -Force -Path $EvidenceRoot | Out-Null
$evidencePath = (Resolve-Path $EvidenceRoot).Path
$preflightPath = Join-Path $evidencePath "preflight.json"

if (-not $SkipWorkerRestart) {
  if ($RvcWorkerUrl -ne "http://127.0.0.1:5055") {
    throw "Automatic worker restart supports only the warm ROCm worker on port 5055. Use -SkipWorkerRestart for an existing production worker."
  }
  powershell -NoProfile -ExecutionPolicy Bypass -File .\tools\start_rvc_worker.ps1 -StopExisting -Background -Device cuda:0 -Method pm -Port 5055 | Out-Null
  Start-Sleep -Seconds 8
}

$workerHealthRaw = $null
try {
  $workerHealthRaw = Invoke-RestMethod -Uri "$RvcWorkerUrl/health" -TimeoutSec 5
} catch {
  throw "Voice worker is not healthy on $RvcWorkerUrl/health :: $($_.Exception.Message)"
}
if (-not [bool]$workerHealthRaw.ready) {
  throw "Warm RVC worker reported not ready."
}
$workerHealth = [ordered]@{
  schema = [string]$workerHealthRaw.schema
  ready = [bool]$workerHealthRaw.ready
  backend = [string]$workerHealthRaw.backend
  device = [string]$workerHealthRaw.device
  method = [string]$workerHealthRaw.method
  load_ms = $workerHealthRaw.load_ms
  convert_count = $workerHealthRaw.convert_count
  average_convert_ms = $workerHealthRaw.average_convert_ms
  last = $workerHealthRaw.last
  uptime_seconds = $workerHealthRaw.uptime_seconds
}

if (-not $SkipBridgeRestart) {
  if ($RvcWorkerUrl -ne "http://127.0.0.1:5055") {
    throw "Automatic bridge restart is configured for the warm ROCm adapter. Use -SkipBridgeRestart with an existing production DirectML bridge."
  }
  $env:STACKCHAN_RVC_WORKER_URL = "http://127.0.0.1:5055"
  $env:STACKCHAN_RVC_WORKER_TIMEOUT_SECONDS = "90"
  $env:STACKCHAN_RVC_MAX_AUDIO_BYTES = "2097152"
  powershell -NoProfile -ExecutionPolicy Bypass -File .\tools\start_pc_brain.ps1 `
    -StopExisting `
    -Background `
    -EnableAudioDownlink `
    -TtsCommand "python bridge\rvc_tts_client.py" `
    -TtsVoice "stackchan-rvc-warm-rocm" `
    -DownlinkBinaryFrameDelayMs 80 | Out-Null
  Start-Sleep -Seconds 8
}

$initialStop = Stop-MotionVerified
if (-not $initialStop.verified) {
  throw "Could not verify motion, servo rail, and torque off before soak preflight. Evidence root: $evidencePath"
}
$sourceCommit = (& git rev-parse HEAD).Trim()
$sourceDirty = -not [string]::IsNullOrWhiteSpace(((& git status --porcelain=v1 --untracked-files=normal) -join "`n"))
if ($RequireFinalIntegration -and ($sourceDirty -or $sourceCommit -notmatch "^[0-9a-fA-F]{40}$")) {
  $sourceFailurePath = Join-Path $evidencePath "source-identity-preflight-failure.json"
  [ordered]@{
    schema = "stackchan.final-integration-source-preflight-failure.v1"
    capturedAt = (Get-Date).ToString("o")
    sourceCommit = $sourceCommit
    sourceDirty = $sourceDirty
    initialStop = $initialStop
  } | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $sourceFailurePath -Encoding UTF8
  throw "Final integration requires a clean pinned source commit; motion was not enabled. Evidence: $sourceFailurePath"
}
$before = $initialStop.debug
$preflightSocketRemote = $null
try {
  $preflightSocket = Get-NetTCPConnection -LocalPort 8765 -State Established -ErrorAction SilentlyContinue |
    Where-Object { $_.RemoteAddress -eq $DeviceHost } |
    Select-Object -First 1
  if ($preflightSocket) { $preflightSocketRemote = [string]$preflightSocket.RemoteAddress }
} catch {
}
$runtimePreflightReady =
  [string]$before.network_state -eq "connected" -and
  [string]$before.bridge_state -in @("ready", "listening", "thinking", "responding") -and
  $preflightSocketRemote -eq $DeviceHost -and
  [double]$before.chip_temp_c -le $MaxAllowedChipTempC -and
  [int]$before.power_vbus_mv -ge $MinPowerVbusMv -and
  [int]$before.power_vbus_min_mv -ge $MinPowerVbusReportedMv -and
  [int]$before.display_window_max_frame_us -le $MaxDisplayFrameUs
if (-not $runtimePreflightReady) {
  $runtimeFailurePath = Join-Path $evidencePath "runtime-preflight-failure.json"
  [ordered]@{
    schema = "stackchan.warm-rocm-runtime-preflight-failure.v1"
    capturedAt = (Get-Date).ToString("o")
    reason = "runtime_gate_not_ready"
    thresholds = [ordered]@{ maxChipTempC = $MaxAllowedChipTempC; minVbusMv = $MinPowerVbusMv; minReportedVbusMv = $MinPowerVbusReportedMv; maxDisplayFrameUs = $MaxDisplayFrameUs }
    bridgeSocketRemote = $preflightSocketRemote
    debug = $before
  } | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $runtimeFailurePath -Encoding UTF8
  throw "Runtime preflight is not ready; motion was not enabled. Evidence: $runtimeFailurePath"
}
if ($RequirePowerForensics -and
    (-not [bool]$before.power_forensics_enabled -or
     -not [bool]$before.power_forensics_irq_enable_succeeded -or
     -not [bool]$before.power_forensics_boot_status_valid)) {
  $forensicsFailurePath = Join-Path $evidencePath "power-forensics-preflight-failure.json"
  [ordered]@{
    schema = "stackchan.power-forensics-preflight-failure.v1"
    capturedAt = (Get-Date).ToString("o")
    reason = "power_forensics_not_armed"
    before = $before
  } | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $forensicsFailurePath -Encoding UTF8
  throw "PMIC power forensics is not armed; motion was not enabled. Flash stackchan_release_forensics and verify /debug. Evidence: $forensicsFailurePath."
}
$visionBefore = $null
$visionAfter = $null
$visionSocketRemote = $null
$visionPreflightReady = $false
if ($RequireFinalIntegration) {
  $visionBefore = $before
  Start-Sleep -Milliseconds 1400
  $visionAfter = Invoke-JsonEndpoint -Path "/debug" -TimeoutSeconds 5
  try {
    $visionSocket = Get-NetTCPConnection -LocalPort 8765 -State Established -ErrorAction SilentlyContinue |
      Where-Object { $_.RemoteAddress -eq $DeviceHost } |
      Select-Object -First 1
    if ($visionSocket) { $visionSocketRemote = [string]$visionSocket.RemoteAddress }
  } catch {
  }
  $visionPreflightReady =
    [int]$visionAfter.compiled_enable_camera -eq 1 -and
    [int]$visionAfter.compiled_enable_camera_host_vision -eq 1 -and
    [bool]$visionAfter.camera_ready -and [bool]$visionAfter.camera_active -and
    [bool]$visionAfter.camera_capture_ready -and
    [bool]$visionBefore.camera_target_valid -and [bool]$visionAfter.camera_target_valid -and
    $visionSocketRemote -eq $DeviceHost -and
    [int64]$visionAfter.camera_host_frame_requests -gt [int64]$visionBefore.camera_host_frame_requests -and
    [int64]$visionAfter.camera_host_target_updates -gt [int64]$visionBefore.camera_host_target_updates -and
    [int64]$visionAfter.camera_host_frame_failures -eq [int64]$visionBefore.camera_host_frame_failures -and
    [int64]$visionAfter.camera_host_auth_failures -eq [int64]$visionBefore.camera_host_auth_failures
  if (-not $visionPreflightReady) {
    $visionFailurePath = Join-Path $evidencePath "vision-preflight-failure.json"
    [ordered]@{
      schema = "stackchan.final-integration-vision-preflight-failure.v1"
      capturedAt = (Get-Date).ToString("o")
      reason = "stable_authenticated_vision_not_ready"
      before = $visionBefore
      after = $visionAfter
      initialStop = $initialStop
    } | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $visionFailurePath -Encoding UTF8
    throw "Final integration vision is not ready and advancing; motion was not enabled. Start the paired vision worker and acquire a stable face. Evidence: $visionFailurePath"
  }
}
$motionStart = Enable-MotionWithRetry -TimeoutSeconds 20 -RetrySeconds 3
$motionRequest = $motionStart.request
$motionRequestRecords = @($motionStart.requests | ForEach-Object { $_ })
$motionAttemptCount = $motionRequestRecords.Count
$after = $motionStart.after
$motionTelemetryPresent =
  (Has-JsonProperty $after "motion_last_reason") -and
  (Has-JsonProperty $after "motion_session_timeouts") -and
  (Has-JsonProperty $after "motion_actuator_ready")

$socketRemote = $null
try {
  $socket = Get-NetTCPConnection -LocalPort 8765 -ErrorAction SilentlyContinue |
    Where-Object { $_.State -eq "Established" } |
    Select-Object -First 1
  if ($socket) {
    $socketRemote = [string]$socket.RemoteAddress
  }
} catch {
}

$preflight = [ordered]@{
  schema = "stackchan.warm-rocm-full-system-soak-preflight.v1"
  generatedAt = (Get-Date).ToString("o")
  evidenceRoot = $evidencePath
  deviceHost = $DeviceHost
  durationSeconds = $DurationSeconds
  pollSeconds = $PollSeconds
  pollTimeoutSeconds = $PollTimeoutSeconds
  motionRefreshSeconds = $MotionRefreshSeconds
  motionRefreshInitialDelaySeconds = $MotionRefreshInitialDelaySeconds
  minMotionUnsuppressedSampleRatio = $MinMotionUnsuppressedSampleRatio
  maxAllowedChipTempC = $MaxAllowedChipTempC
  minPowerVbusMv = $MinPowerVbusMv
  minPowerVbusReportedMv = $MinPowerVbusReportedMv
  motionPowerSoftFloorMv = $MotionPowerSoftFloorMv
  maxDisplayFrameUs = $MaxDisplayFrameUs
  maxFailedPolls = $MaxFailedPolls
  maxFailedPollRatio = $MaxFailedPollRatio
  minPollsForFailedRatio = $MinPollsForFailedRatio
  maxConsecutiveFailedPolls = $MaxConsecutiveFailedPolls
  rvcWorkerUrl = $RvcWorkerUrl
  workerHealth = $workerHealth
  before = $before
  motionRequest = $motionRequest
  motionRequests = $motionRequestRecords
  motionAttemptCount = $motionAttemptCount
  after = $after
  motionTelemetryPresent = $motionTelemetryPresent
  powerForensicsRequired = [bool]$RequirePowerForensics
  powerForensicsArmed = [bool]$after.power_forensics_enabled -and
    [bool]$after.power_forensics_irq_enable_succeeded -and
    [bool]$after.power_forensics_boot_status_valid
  finalIntegrationRequired = [bool]$RequireFinalIntegration
  initialMotionStop = $initialStop
  sourceCommit = $sourceCommit
  sourceDirty = $sourceDirty
  runtimePreflightReady = $runtimePreflightReady
  preflightSocketRemote = $preflightSocketRemote
  visionBefore = $visionBefore
  visionAfter = $visionAfter
  visionSocketRemote = $visionSocketRemote
  visionPreflightReady = $visionPreflightReady
  finalIntegrationReady = $after.power_forensics_schema -eq "axp2101-v2" -and
    $null -ne $after.PSObject.Properties["debug_response_truncated"] -and
    -not [bool]$after.debug_response_truncated -and
    [int]$after.compiled_enable_body_rgb -eq 1 -and [bool]$after.body_rgb_ready -and
    [int]$after.compiled_enable_body_touch -eq 1 -and [bool]$after.body_touch_ready -and
    [int]$after.compiled_enable_imu -eq 1 -and [bool]$after.imu_ready -and
    [bool]$after.imu_calibrated -and [int]$after.compiled_enable_camera -eq 1 -and
    [int]$after.compiled_enable_camera_host_vision -eq 1 -and
    [bool]$after.camera_ready -and [bool]$after.camera_active -and
    [bool]$after.camera_capture_ready -and [bool]$after.camera_target_valid
  bridgeSocketRemote = $socketRemote
}
$preflight | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $preflightPath -Encoding UTF8

if (-not $motionTelemetryPresent -and -not $AllowLegacyMotionTelemetry) {
  Stop-MotionAndThrow "Motion debug telemetry is missing. Flash the motion timing candidate before starting the strict servo-enabled soak, or rerun with -AllowLegacyMotionTelemetry." $preflightPath
}

if (-not [bool]$after.motion_enabled) {
  Stop-MotionAndThrow "Motion did not become enabled after /motion-resume. Power-cycle or side-button reset the robot before starting the servo-enabled soak." $preflightPath
}

if ($RequirePowerForensics -and
    (-not [bool]$after.power_forensics_enabled -or
     -not [bool]$after.power_forensics_irq_enable_succeeded -or
     -not [bool]$after.power_forensics_boot_status_valid)) {
  Stop-MotionAndThrow "PMIC power forensics is not armed. Flash stackchan_release_forensics and verify /debug before starting this run." $preflightPath
}

if ($RequireFinalIntegration -and -not $preflight.finalIntegrationReady) {
  Stop-MotionAndThrow "Final integration telemetry is not ready. Require PMIC v2, untruncated debug JSON, RGB/touch/IMU ready, calibrated IMU, active paired vision, and a stable camera target." $preflightPath
}

$stdout = Join-Path $evidencePath "soak_stdout.log"
$stderr = Join-Path $evidencePath "soak_stderr.log"
$args = @(
  "-NoProfile",
  "-ExecutionPolicy",
  "Bypass",
  "-File",
  (Join-Path $RepoRoot "tools\run_full_system_soak_http_motion.ps1"),
  "-DeviceHost",
  $DeviceHost,
  "-DurationSeconds",
  [string]$DurationSeconds,
  "-PollSeconds",
  [string]$PollSeconds,
  "-PollTimeoutSeconds",
  [string]$PollTimeoutSeconds,
  "-MotionRefreshSeconds",
  [string]$MotionRefreshSeconds,
  "-MotionRefreshInitialDelaySeconds",
  [string]$MotionRefreshInitialDelaySeconds,
  "-RvcWorkerUrl",
  $RvcWorkerUrl,
  "-RvcWorkerPollSeconds",
  "60",
  "-MaxAllowedChipTempC",
  [string]$MaxAllowedChipTempC,
  "-MaxDisplayFrameUs",
  [string]$MaxDisplayFrameUs,
  "-RequireMotion",
  "-RequireNoMotionTimeouts",
  "-RequireBridgeSocket",
  "-RequireWakeReady",
  "-RequireMicReady",
  "-RequireSpeakerReady",
  "-RequireRvcWorker",
  "-RequirePowerCoordinator",
  "-RequirePmicVbusStable",
  "-RequireNoNewHardFloorEvents",
  "-RequireManagedChargePolicy",
  "-FailFastOnStrictBreach",
  "-MaxFailedPolls",
  [string]$MaxFailedPolls,
  "-MaxFailedPollRatio",
  [string]$MaxFailedPollRatio,
  "-MinPollsForFailedRatio",
  [string]$MinPollsForFailedRatio,
  "-MaxConsecutiveFailedPolls",
  [string]$MaxConsecutiveFailedPolls,
  "-MinMotionSampleRatio",
  "0.95",
  "-MinMotionUnsuppressedSampleRatio",
  [string]$MinMotionUnsuppressedSampleRatio,
  "-MinPowerVbusReportedMv",
  [string]$MinPowerVbusReportedMv,
  "-MinPowerVbusMv",
  [string]$MinPowerVbusMv,
  "-MotionPowerSoftFloorMv",
  [string]$MotionPowerSoftFloorMv,
  "-EvidenceRoot",
  $EvidenceRoot
)
if (-not $AllowLegacyMotionTelemetry) {
  $args += "-RequireMotionTelemetry"
}
if ($RequirePowerForensics) {
  $args += "-RequirePowerForensics"
}
if ($RequireFinalIntegration) {
  $args += "-RequireFinalIntegration"
}
if ($NoSerial) {
  $args += "-NoSerial"
}

try {
  $proc = Start-Process -FilePath "powershell.exe" -ArgumentList $args -WorkingDirectory $RepoRoot -RedirectStandardOutput $stdout -RedirectStandardError $stderr -WindowStyle Hidden -PassThru
} catch {
  Stop-MotionAndThrow "Could not launch the soak runner: $($_.Exception.Message)" $preflightPath
}

[pscustomobject]@{
  schema = "stackchan.warm-rocm-full-system-soak-started.v1"
  pid = $proc.Id
  evidenceRoot = $evidencePath
  preflight = $preflightPath
  stdout = $stdout
  stderr = $stderr
  durationSeconds = $DurationSeconds
  pollSeconds = $PollSeconds
  motionRefreshSeconds = $MotionRefreshSeconds
} | ConvertTo-Json -Depth 5
