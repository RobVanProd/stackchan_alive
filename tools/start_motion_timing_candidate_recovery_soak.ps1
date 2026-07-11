param(
  [string]$Port = "COM4",
  [string]$DeviceHost = "192.168.1.238",
  [int]$DevicePort = 8789,
  [string]$FirmwareEnvironment = "stackchan_wake_mww_uplink_servos_m5_voiceout",
  [string]$CandidateFirmwarePath = "",
  [string]$EvidenceRoot = "",
  [int]$DurationSeconds = 28800,
  [int]$PollSeconds = 30,
  [int]$MotionRefreshSeconds = 300,
  [int]$WaitForRobotSeconds = 120,
  [switch]$OperatorPresent,
  [switch]$BodyClear,
  [switch]$ConfirmServoRisk,
  [switch]$FlashCandidate,
  [switch]$SkipWorkerRestart,
  [switch]$SkipBridgeRestart,
  [switch]$NoSerial,
  [switch]$DryRun,
  [switch]$Json
)

$ErrorActionPreference = "Stop"

$RepoRoot = Resolve-Path (Join-Path $PSScriptRoot "..")
Set-Location $RepoRoot

if ([string]::IsNullOrWhiteSpace($EvidenceRoot)) {
  $stamp = Get-Date -Format "yyyyMMdd-HHmmss"
  $EvidenceRoot = "output\pc-brain\motion-timing-candidate-recovery-soak-$stamp"
}
New-Item -ItemType Directory -Force -Path $EvidenceRoot | Out-Null
$resolvedEvidenceRoot = (Resolve-Path $EvidenceRoot).Path

if ([string]::IsNullOrWhiteSpace($CandidateFirmwarePath)) {
  $CandidateFirmwarePath = Join-Path $RepoRoot ".pio\build\$FirmwareEnvironment\firmware.bin"
}

$steps = @()

function Add-Step {
  param(
    [string]$Id,
    [ValidateSet("pass", "fail", "pending")]
    [string]$Status,
    [string]$Detail
  )
  $script:steps += [ordered]@{
    id = $Id
    status = $Status
    detail = $Detail
  }
}

function Write-JsonFile {
  param([string]$Path, $Value)
  $Value | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $Path -Encoding UTF8
}

function Has-JsonProperty {
  param($Object, [string]$Name)
  if ($null -eq $Object) { return $false }
  return $null -ne $Object.PSObject.Properties[$Name]
}

function Invoke-JsonEndpoint {
  param([string]$Path, [int]$TimeoutSeconds = 5)
  $url = "http://$DeviceHost`:$DevicePort$Path"
  return Invoke-RestMethod -Uri $url -TimeoutSec $TimeoutSeconds
}

function Wait-ForDebug {
  param([int]$TimeoutSeconds)
  $deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
  $lastError = ""
  do {
    try {
      return [pscustomobject]@{
        ok = $true
        debug = (Invoke-JsonEndpoint -Path "/debug" -TimeoutSeconds 5)
        error = ""
      }
    } catch {
      $lastError = $_.Exception.Message
      Start-Sleep -Seconds 2
    }
  } while ([DateTime]::UtcNow -lt $deadline)

  return [pscustomobject]@{
    ok = $false
    debug = $null
    error = $lastError
  }
}

function Get-BridgeSocketRemote {
  try {
    $socket = Get-NetTCPConnection -LocalPort 8765 -ErrorAction SilentlyContinue |
      Where-Object { $_.State -eq "Established" } |
      Select-Object -First 1
    if ($socket) {
      return [string]$socket.RemoteAddress
    }
  } catch {
  }
  return $null
}

Add-Step "operator-present" ($(if ($OperatorPresent) { "pass" } else { "fail" })) "Requires -OperatorPresent immediately before a servo-enabled recovery soak."
Add-Step "body-clear" ($(if ($BodyClear) { "pass" } else { "fail" })) "Requires -BodyClear immediately before a servo-enabled recovery soak."
Add-Step "servo-risk-confirmed" ($(if ($ConfirmServoRisk) { "pass" } else { "fail" })) "Requires -ConfirmServoRisk for motor-enabled firmware or motion refresh."

$candidateExists = Test-Path -LiteralPath $CandidateFirmwarePath -PathType Leaf
if ($candidateExists) {
  $candidateInfo = Get-Item -LiteralPath $CandidateFirmwarePath
  Add-Step "candidate-firmware" "pass" "$CandidateFirmwarePath size=$($candidateInfo.Length) modified=$($candidateInfo.LastWriteTime.ToString("o"))"
} else {
  Add-Step "candidate-firmware" "fail" "Missing candidate firmware: $CandidateFirmwarePath. Build with: pio run -e $FirmwareEnvironment"
}

$flashLogPath = Join-Path $resolvedEvidenceRoot "flash_candidate.log"
$launchLogPath = Join-Path $resolvedEvidenceRoot "launch_soak.log"
$preflightPath = Join-Path $resolvedEvidenceRoot "RECOVERY_SOAK_PREFLIGHT.json"
$resultPath = Join-Path $resolvedEvidenceRoot "RECOVERY_SOAK_RESULT.json"
$markdownPath = Join-Path $resolvedEvidenceRoot "RECOVERY_SOAK_RESULT.md"
$debug = $null
$launch = $null

$failedBeforeFlash = @($steps | Where-Object { $_.status -eq "fail" })
if ($FlashCandidate -and $failedBeforeFlash.Count -eq 0) {
  $flashArgs = @("-Environment", $FirmwareEnvironment, "-Port", $Port, "-ConfirmServoRisk")
  if ($DryRun) {
    $flashArgs += "-DryRun"
  }
  $flashOutput = & "tools\flash_device.cmd" @flashArgs 2>&1
  $flashExitCode = if ($null -ne $LASTEXITCODE) { [int]$LASTEXITCODE } else { 0 }
  $flashOutput | Out-String | Set-Content -LiteralPath $flashLogPath -Encoding UTF8
  Add-Step "flash-candidate" ($(if ($flashExitCode -eq 0) { "pass" } else { "fail" })) "$(if ($DryRun) { 'Dry run: ' } else { '' })tools\flash_device.cmd -Environment $FirmwareEnvironment -Port $Port -ConfirmServoRisk"
} elseif ($FlashCandidate) {
  Add-Step "flash-candidate" "pending" "Skipped because safety or candidate-firmware checks failed."
} else {
  Add-Step "flash-candidate" "pending" "Not requested. Pass -FlashCandidate when Rob is present and the body is clear."
}

if ($DryRun) {
  Add-Step "robot-debug" "pending" "Skipped by -DryRun."
  Add-Step "motion-telemetry" "pending" "Skipped by -DryRun. After flashing, /debug must expose motion_actuator_ready, motion_last_reason, and motion_session_timeouts."
  Add-Step "bridge-socket" "pending" "Skipped by -DryRun."
  Add-Step "strict-soak-launch" "pending" "Skipped by -DryRun."
} else {
  $failedBeforeRobot = @($steps | Where-Object { $_.status -eq "fail" })
  if ($failedBeforeRobot.Count -eq 0) {
    $debugResult = Wait-ForDebug -TimeoutSeconds $WaitForRobotSeconds
    if ([bool]$debugResult.ok) {
      $debug = $debugResult.debug
      Add-Step "robot-debug" "pass" "Robot /debug reachable at http://$DeviceHost`:$DevicePort/debug"
      $motionTelemetryPresent =
        (Has-JsonProperty $debug "motion_actuator_ready") -and
        (Has-JsonProperty $debug "motion_last_reason") -and
        (Has-JsonProperty $debug "motion_session_timeouts")
      Add-Step "motion-telemetry" ($(if ($motionTelemetryPresent) { "pass" } else { "fail" })) "motion_actuator_ready=$($debug.motion_actuator_ready) motion_last_reason=$($debug.motion_last_reason) motion_session_timeouts=$($debug.motion_session_timeouts)"
      $socketRemote = Get-BridgeSocketRemote
      Add-Step "bridge-socket" ($(if (-not [string]::IsNullOrWhiteSpace($socketRemote)) { "pass" } else { "fail" })) "$(if ($socketRemote) { $socketRemote } else { 'No established local port 8765 bridge socket.' })"
    } else {
      Add-Step "robot-debug" "fail" "Robot /debug did not respond within $WaitForRobotSeconds seconds: $($debugResult.error)"
      Add-Step "motion-telemetry" "pending" "Skipped because robot /debug is unreachable."
      Add-Step "bridge-socket" "pending" "Skipped because robot /debug is unreachable."
    }
  } else {
    Add-Step "robot-debug" "pending" "Skipped because earlier checks failed."
    Add-Step "motion-telemetry" "pending" "Skipped because earlier checks failed."
    Add-Step "bridge-socket" "pending" "Skipped because earlier checks failed."
  }

  $failedBeforeSoak = @($steps | Where-Object { $_.status -eq "fail" })
  if ($failedBeforeSoak.Count -eq 0) {
    $soakArgs = @(
      "-DeviceHost", $DeviceHost,
      "-DevicePort", [string]$DevicePort,
      "-DurationSeconds", [string]$DurationSeconds,
      "-PollSeconds", [string]$PollSeconds,
      "-MotionRefreshSeconds", [string]$MotionRefreshSeconds,
      "-EvidenceRoot", $resolvedEvidenceRoot,
      "-OperatorPresent",
      "-BodyClear",
      "-ConfirmServoRisk"
    )
    if ($NoSerial) { $soakArgs += "-NoSerial" }
    if ($SkipWorkerRestart) { $soakArgs += "-SkipWorkerRestart" }
    if ($SkipBridgeRestart) { $soakArgs += "-SkipBridgeRestart" }

    $launchOutput = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $PSScriptRoot "start_warm_rocm_full_system_soak.ps1") @soakArgs 2>&1
    $launchExitCode = if ($null -ne $LASTEXITCODE) { [int]$LASTEXITCODE } else { 0 }
    $launchOutput | Out-String | Set-Content -LiteralPath $launchLogPath -Encoding UTF8
    if ($launchExitCode -eq 0 -and $launchOutput) {
      try {
        $launch = $launchOutput | ConvertFrom-Json
        Add-Step "strict-soak-launch" "pass" "Started strict soak pid=$($launch.pid) evidenceRoot=$($launch.evidenceRoot)"
      } catch {
        Add-Step "strict-soak-launch" "fail" "Soak launcher output was not JSON: $($_.Exception.Message)"
      }
    } else {
      Add-Step "strict-soak-launch" "fail" "Soak launcher failed. See $launchLogPath"
    }
  } else {
    Add-Step "strict-soak-launch" "pending" "Skipped because recovery preflight failed."
  }
}

$preflight = [ordered]@{
  schema = "stackchan.motion-timing-candidate-recovery-soak-preflight.v1"
  generatedAt = (Get-Date).ToString("o")
  deviceHost = $DeviceHost
  devicePort = $DevicePort
  firmwareEnvironment = $FirmwareEnvironment
  candidateFirmwarePath = $CandidateFirmwarePath
  flashCandidate = [bool]$FlashCandidate
  dryRun = [bool]$DryRun
  durationSeconds = $DurationSeconds
  pollSeconds = $PollSeconds
  motionRefreshSeconds = $MotionRefreshSeconds
  debug = $debug
  launch = $launch
  steps = $steps
}
Write-JsonFile $preflightPath $preflight

$failed = @($steps | Where-Object { $_.status -eq "fail" })
$pending = @($steps | Where-Object { $_.status -eq "pending" })
$status = if ($failed.Count -gt 0) {
  "motion-timing-candidate-recovery-not-run"
} elseif ($DryRun) {
  "motion-timing-candidate-recovery-dry-run-ready"
} else {
  "motion-timing-candidate-recovery-soak-started"
}

$result = [ordered]@{
  schema = "stackchan.motion-timing-candidate-recovery-soak.v1"
  status = $status
  generatedAt = (Get-Date).ToString("o")
  evidenceRoot = $resolvedEvidenceRoot
  preflightPath = $preflightPath
  flashLogPath = $flashLogPath
  launchLogPath = $launchLogPath
  candidateFirmwarePath = $CandidateFirmwarePath
  firmwareEnvironment = $FirmwareEnvironment
  passed = @($steps | Where-Object { $_.status -eq "pass" }).Count
  failed = $failed.Count
  pending = $pending.Count
  launch = $launch
  nextCheckCommand = "powershell -NoProfile -ExecutionPolicy Bypass -File .\tools\check_full_system_soak_evidence.ps1 -SummaryJsonPath `"$resolvedEvidenceRoot\summary.json`" -RequireReady -Json"
  steps = $steps
}
Write-JsonFile $resultPath $result

$lines = @(
  "# Stackchan Motion Timing Candidate Recovery Soak",
  "",
  "- Schema: ``$($result.schema)``",
  "- Status: ``$($result.status)``",
  "- Evidence root: ``$resolvedEvidenceRoot``",
  "- Firmware environment: ``$FirmwareEnvironment``",
  "- Flash candidate requested: ``$([bool]$FlashCandidate)``",
  "- Dry run: ``$([bool]$DryRun)``",
  "- Passed: ``$($result.passed)``",
  "- Failed: ``$($result.failed)``",
  "- Pending: ``$($result.pending)``",
  "",
  "## Steps",
  ""
)
foreach ($step in $steps) {
  $lines += "- ``$($step.status)`` ``$($step.id)``: $($step.detail)"
}
$lines += ""
$lines += "## Next"
$lines += ""
if ($result.status -eq "motion-timing-candidate-recovery-soak-started") {
  $lines += "- Let the soak finish, then run: ``$($result.nextCheckCommand)``"
} elseif ($result.status -eq "motion-timing-candidate-recovery-dry-run-ready") {
  $lines += "- Dry-run passed. With Rob present, body clear, and the robot recovered, rerun without ``-DryRun``."
} else {
  $lines += "- Resolve failed checks before flashing or starting servo motion."
}
$lines | Set-Content -LiteralPath $markdownPath -Encoding UTF8

if ($Json) {
  $result | ConvertTo-Json -Depth 10
} else {
  Write-Host "Motion timing candidate recovery soak: $status"
  Write-Host "Report: $markdownPath"
}

if ($failed.Count -gt 0) {
  exit 1
}
