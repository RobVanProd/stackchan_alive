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

New-Item -ItemType Directory -Force -Path $EvidenceRoot | Out-Null
$evidencePath = (Resolve-Path $EvidenceRoot).Path
$preflightPath = Join-Path $evidencePath "preflight.json"

if (-not $SkipWorkerRestart) {
  powershell -NoProfile -ExecutionPolicy Bypass -File .\tools\start_rvc_worker.ps1 -StopExisting -Background -Device cuda:0 -Method pm -Port 5055 | Out-Null
  Start-Sleep -Seconds 8
}

$workerHealth = $null
try {
  $workerHealth = Invoke-RestMethod -Uri "http://127.0.0.1:5055/health" -TimeoutSec 5
} catch {
  throw "Warm RVC worker is not healthy on http://127.0.0.1:5055/health :: $($_.Exception.Message)"
}
if (-not [bool]$workerHealth.ready) {
  throw "Warm RVC worker reported not ready."
}

if (-not $SkipBridgeRestart) {
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

$before = Invoke-JsonEndpoint -Path "/debug" -TimeoutSeconds 5
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
  finalIntegrationReady = $after.power_forensics_schema -eq "axp2101-v2" -and
    $null -ne $after.PSObject.Properties["debug_response_truncated"] -and
    -not [bool]$after.debug_response_truncated -and
    [int]$after.compiled_enable_body_rgb -eq 1 -and [bool]$after.body_rgb_ready -and
    [int]$after.compiled_enable_body_touch -eq 1 -and [bool]$after.body_touch_ready -and
    [int]$after.compiled_enable_imu -eq 1 -and [bool]$after.imu_ready -and
    [bool]$after.imu_calibrated -and [int]$after.compiled_enable_camera -eq 0 -and
    -not [bool]$after.camera_active
  bridgeSocketRemote = $socketRemote
}
$preflight | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $preflightPath -Encoding UTF8

if (-not $motionTelemetryPresent -and -not $AllowLegacyMotionTelemetry) {
  throw "Motion debug telemetry is missing. Flash the motion timing candidate before starting the strict servo-enabled soak, or rerun with -AllowLegacyMotionTelemetry. Evidence: $preflightPath."
}

if (-not [bool]$after.motion_enabled) {
  throw "Motion did not become enabled after /motion-resume. Evidence: $preflightPath. Power-cycle or side-button reset the robot before starting the servo-enabled soak."
}

if ($RequirePowerForensics -and
    (-not [bool]$after.power_forensics_enabled -or
     -not [bool]$after.power_forensics_irq_enable_succeeded -or
     -not [bool]$after.power_forensics_boot_status_valid)) {
  throw "PMIC power forensics is not armed. Flash stackchan_release_forensics and verify /debug before starting this run. Evidence: $preflightPath."
}

if ($RequireFinalIntegration -and -not $preflight.finalIntegrationReady) {
  throw "Final integration telemetry is not ready. Require PMIC v2, untruncated debug JSON, RGB/touch/IMU ready and calibrated, and production camera disabled. Evidence: $preflightPath."
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
  "http://127.0.0.1:5055",
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

$proc = Start-Process -FilePath "powershell.exe" -ArgumentList $args -WorkingDirectory $RepoRoot -RedirectStandardOutput $stdout -RedirectStandardError $stderr -WindowStyle Hidden -PassThru

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
