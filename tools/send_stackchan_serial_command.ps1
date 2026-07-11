param(
  [string]$Command = "motion stop",
  [string]$Port = "COM4",
  [int]$BaudRate = 115200,
  [string]$EvidenceRoot = "output\pc-brain\full-online-validation-latest",
  [int]$ReadBackMs = 1500,
  [switch]$OperatorPresent,
  [switch]$BodyClear,
  [switch]$ConfirmServoRisk,
  [switch]$DtrEnable,
  [switch]$RtsEnable,
  [switch]$DryRun,
  [switch]$Json
)

$ErrorActionPreference = "Stop"

$RepoRoot = Resolve-Path (Join-Path $PSScriptRoot "..")
Set-Location $RepoRoot

$normalizedCommand = ($Command.Trim() -replace "\s+", " ").ToLowerInvariant()
$stopCommands = @("motion stop", "halt", "safe stop", "panic", "servos off", "demo off", "status", "telemetry", "health")
$resumeCommands = @("motion resume", "servos on", "safe resume", "restore", "demo on")
$audioCommands = @("mic cue", "speaker cue")
$wakeCommands = @("wake", "listen")
$allowedCommands = @($stopCommands + $resumeCommands + $audioCommands + $wakeCommands)

if ($allowedCommands -notcontains $normalizedCommand) {
  throw "Unsupported command '$Command'. Allowed commands: $($allowedCommands -join ', ')"
}
if (-not $OperatorPresent) {
  throw "Serial command send requires -OperatorPresent."
}
if ($resumeCommands -contains $normalizedCommand) {
  if (-not $BodyClear) {
    throw "Motion/resume command '$normalizedCommand' requires -BodyClear."
  }
  if (-not $ConfirmServoRisk) {
    throw "Motion/resume command '$normalizedCommand' requires -ConfirmServoRisk."
  }
}
if ($ReadBackMs -lt 0 -or $ReadBackMs -gt 10000) {
  throw "ReadBackMs must be between 0 and 10000."
}

New-Item -ItemType Directory -Force -Path $EvidenceRoot | Out-Null
$EvidencePath = (Resolve-Path $EvidenceRoot).Path
$safeName = ($normalizedCommand -replace '[^a-z0-9]+', '_').Trim("_")
if ([string]::IsNullOrWhiteSpace($safeName)) {
  $safeName = "command"
}
$logPath = Join-Path $EvidencePath "serial_command_$safeName.log"
$jsonPath = Join-Path $EvidencePath "SERIAL_COMMAND_$($safeName.ToUpperInvariant()).json"

$startedAt = Get-Date
$lines = @()
$serialBytes = 0
$sawMotionStop = $false
$sawControl = $false
$sawRuntime = $false

function Add-LogLine {
  param([string]$Line)
  $script:lines += $Line
}

function Read-SerialAvailable {
  param([System.IO.Ports.SerialPort]$Serial, [int]$DrainMs)
  if ($DrainMs -le 0 -or -not $Serial.IsOpen) {
    return
  }
  $deadline = [DateTime]::UtcNow.AddMilliseconds($DrainMs)
  do {
    Start-Sleep -Milliseconds 25
    try {
      $text = $Serial.ReadExisting()
    } catch {
      return
    }
    if ([string]::IsNullOrEmpty($text)) {
      continue
    }
    $script:serialBytes += [System.Text.Encoding]::UTF8.GetByteCount($text)
    foreach ($raw in ($text -split "\r?\n")) {
      $line = $raw.Trim()
      if ([string]::IsNullOrWhiteSpace($line)) {
        continue
      }
      Add-LogLine "[$((Get-Date).ToString("o"))] < $line"
      if ($line -match "\[motion\]\s+enabled=0" -or $line -match "command=motion_stop" -or $line -match "safe_stop") {
        $script:sawMotionStop = $true
      }
      if ($line -match "^\[control\]") {
        $script:sawControl = $true
      }
      if ($line -match "^\[(runtime|heartbeat|system)\]") {
        $script:sawRuntime = $true
      }
    }
  } while ([DateTime]::UtcNow -lt $deadline)
}

Add-LogLine "# Stackchan serial command started $($startedAt.ToString("o")) port=$Port baud=$BaudRate dtr=$([bool]$DtrEnable) rts=$([bool]$RtsEnable) dryRun=$([bool]$DryRun)"
Add-LogLine "[$($startedAt.ToString("o"))] > $normalizedCommand"

$status = "serial-command-dry-run"
if (-not $DryRun) {
  $serial = [System.IO.Ports.SerialPort]::new($Port, $BaudRate, [System.IO.Ports.Parity]::None, 8, [System.IO.Ports.StopBits]::One)
  $serial.NewLine = "`n"
  $serial.ReadTimeout = 250
  $serial.WriteTimeout = 1000
  $serial.DtrEnable = [bool]$DtrEnable
  $serial.RtsEnable = [bool]$RtsEnable
  try {
    $serial.Open()
    Start-Sleep -Milliseconds 150
    try { [void]$serial.ReadExisting() } catch {}
    $serial.WriteLine($normalizedCommand)
    Read-SerialAvailable -Serial $serial -DrainMs $ReadBackMs
    $status = "serial-command-sent"
  } finally {
    if ($serial.IsOpen) {
      $serial.Close()
    }
    $serial.Dispose()
  }
}

$endedAt = Get-Date
$lines | Set-Content -LiteralPath $logPath -Encoding UTF8
$result = [ordered]@{
  schema = "stackchan.serial-command.v1"
  status = $status
  evidenceRoot = $EvidencePath
  command = $normalizedCommand
  port = $Port
  baudRate = $BaudRate
  dtrEnable = [bool]$DtrEnable
  rtsEnable = [bool]$RtsEnable
  dryRun = [bool]$DryRun
  operatorPresent = [bool]$OperatorPresent
  bodyClear = [bool]$BodyClear
  confirmServoRisk = [bool]$ConfirmServoRisk
  startedAt = $startedAt.ToString("o")
  endedAt = $endedAt.ToString("o")
  logPath = $logPath
  serialBytes = $serialBytes
  sawMotionStop = $sawMotionStop
  sawControl = $sawControl
  sawRuntime = $sawRuntime
}
$result | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $jsonPath -Encoding UTF8

if ($Json) {
  $result | ConvertTo-Json -Depth 8
} else {
  Write-Host "Stackchan serial command: $status"
  Write-Host "Command: $normalizedCommand"
  Write-Host "Log: $logPath"
}
