param(
  [string]$DeviceHost = "192.168.1.238",
  [int]$DevicePort = 8789,
  [int]$WaitSeconds = 300,
  [int]$PollSeconds = 2,
  [string]$SerialPort = "COM4",
  [string]$BridgeLocalPort = "8765",
  [string]$EvidenceRoot = "output\pc-brain\power-forensics-post-return-latest"
)

$ErrorActionPreference = "Stop"
$repoRoot = Resolve-Path (Join-Path $PSScriptRoot "..")
$evidencePath = if ([System.IO.Path]::IsPathRooted($EvidenceRoot)) {
  $EvidenceRoot
} else {
  Join-Path $repoRoot $EvidenceRoot
}
New-Item -ItemType Directory -Force -Path $evidencePath | Out-Null

function Get-BridgeSocketRemote {
  try {
    $socket = Get-NetTCPConnection -LocalPort ([int]$BridgeLocalPort) -ErrorAction SilentlyContinue |
      Where-Object { $_.State -eq "Established" } |
      Select-Object -First 1
    if ($socket) { return [string]$socket.RemoteAddress }
  } catch {
  }
  return $null
}

function Test-SerialPresent {
  try {
    return @([System.IO.Ports.SerialPort]::GetPortNames()) -contains $SerialPort
  } catch {
    return $false
  }
}

function Test-PingOnce {
  try {
    return [bool](Test-Connection -ComputerName $DeviceHost -Count 1 -Quiet -ErrorAction SilentlyContinue)
  } catch {
    return $false
  }
}

$debugUrl = "http://$DeviceHost`:$DevicePort/debug"
$deadline = [DateTime]::UtcNow.AddSeconds($WaitSeconds)
$attempts = New-Object System.Collections.Generic.List[object]
$firstDebug = $null

do {
  $attemptAt = Get-Date
  try {
    $firstDebug = Invoke-RestMethod -Uri $debugUrl -TimeoutSec 4
    $attempts.Add([ordered]@{
        at = $attemptAt.ToString("o")
        debugReachable = $true
        ping = $true
        socketRemote = Get-BridgeSocketRemote
        serialPresent = Test-SerialPresent
      })
    break
  } catch {
    $attempts.Add([ordered]@{
        at = $attemptAt.ToString("o")
        debugReachable = $false
        error = $_.Exception.Message
        ping = Test-PingOnce
        socketRemote = Get-BridgeSocketRemote
        serialPresent = Test-SerialPresent
      })
  }
  Start-Sleep -Seconds ([math]::Max(1, $PollSeconds))
} while ([DateTime]::UtcNow -lt $deadline)

$stamp = Get-Date -Format "yyyyMMdd-HHmmss"
$attemptsPath = Join-Path $evidencePath "post-return-attempts-$stamp.json"
$attempts | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $attemptsPath -Encoding UTF8

if ($null -eq $firstDebug) {
  $offline = [ordered]@{
    schema = "stackchan.power-forensics-post-return.v1"
    capturedAt = (Get-Date).ToString("o")
    status = "offline"
    deviceHost = $DeviceHost
    waitSeconds = $WaitSeconds
    attempts = $attempts.Count
    ping = Test-PingOnce
    socketRemote = Get-BridgeSocketRemote
    serialPresent = Test-SerialPresent
    attemptsPath = $attemptsPath
    action = "No reboot or reflash was attempted. Physical side-button or power recovery may be required."
  }
  $offlinePath = Join-Path $evidencePath "post-return-offline-$stamp.json"
  $offline | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $offlinePath -Encoding UTF8
  $offline | ConvertTo-Json -Depth 6
  exit 2
}

$firstPath = Join-Path $evidencePath "first-post-return-debug-$stamp.json"
$firstDebug | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $firstPath -Encoding UTF8

$motionStopAttempted = $false
$motionStopResponse = $null
$postStopDebug = $null
if ([bool]$firstDebug.motion_enabled -or [bool]$firstDebug.servo_rail_enabled -or
    [bool]$firstDebug.servo_torque_enabled) {
  $motionStopAttempted = $true
  try {
    $motionStopResponse = Invoke-RestMethod -Uri "http://$DeviceHost`:$DevicePort/motion-stop" -TimeoutSec 4
    Start-Sleep -Milliseconds 400
    $postStopDebug = Invoke-RestMethod -Uri $debugUrl -TimeoutSec 4
    $postStopPath = Join-Path $evidencePath "post-motion-stop-debug-$stamp.json"
    $postStopDebug | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $postStopPath -Encoding UTF8
  } catch {
    $motionStopResponse = [ordered]@{ error = $_.Exception.Message }
  }
}

$resultPath = Join-Path $evidencePath "post-return-summary-$stamp.json"
$result = [ordered]@{
  schema = "stackchan.power-forensics-post-return.v1"
  capturedAt = (Get-Date).ToString("o")
  status = "captured"
  deviceHost = $DeviceHost
  resultPath = $resultPath
  firstDebugPath = $firstPath
  attemptsPath = $attemptsPath
  resetReason = $firstDebug.reset_reason
  resetReasonCode = $firstDebug.reset_reason_code
  bootCount = $firstDebug.boot_count
  uptimeMs = $firstDebug.uptime_ms
  forensicsEnabled = $firstDebug.power_forensics_enabled
  irqEnableSucceeded = $firstDebug.power_forensics_irq_enable_succeeded
  bootStatusValid = $firstDebug.power_forensics_boot_status_valid
  bootEventMask = $firstDebug.power_forensics_boot_event_mask
  bootEvent = $firstDebug.power_forensics_boot_event
  bootProtective = $firstDebug.power_forensics_boot_protective
  runtimeEventPolls = $firstDebug.power_forensics_runtime_event_polls
  runtimeProtectiveEventPolls = $firstDebug.power_forensics_runtime_protective_event_polls
  readFailures = $firstDebug.power_forensics_read_failures
  clearFailures = $firstDebug.power_forensics_clear_failures
  vbusMv = $firstDebug.power_vbus_mv
  batteryMv = $firstDebug.power_battery_mv
  pmicVbusPresent = $firstDebug.power_pmic_vbus_present
  pmicBatteryPresent = $firstDebug.power_pmic_battery_present
  chipTempC = $firstDebug.chip_temp_c
  pmicTempC = $firstDebug.power_pmic_temp_c
  motionEnabled = $firstDebug.motion_enabled
  servoRailEnabled = $firstDebug.servo_rail_enabled
  servoTorqueEnabled = $firstDebug.servo_torque_enabled
  bridgeState = $firstDebug.bridge_state
  networkState = $firstDebug.network_state
  motionStopAttempted = $motionStopAttempted
  motionStopResponse = $motionStopResponse
  postStopMotionEnabled = if ($postStopDebug) { $postStopDebug.motion_enabled } else { $null }
}

$result | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $resultPath -Encoding UTF8
$result | ConvertTo-Json -Depth 8
