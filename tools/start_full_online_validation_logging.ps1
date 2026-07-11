param(
  [string]$EvidenceRoot = "output\pc-brain\full-online-validation-latest",
  [string]$Port = "COM4",
  [int]$BaudRate = 115200,
  [string]$DeviceHost = "192.168.1.238",
  [string]$DebugUrl = "",
  [string]$DebugJsonPath = "",
  [int]$DurationSeconds = 900,
  [int]$PollIntervalSeconds = 2,
  [switch]$OperatorPresent,
  [switch]$BodyClear,
  [switch]$DtrEnable,
  [switch]$RtsEnable,
  [switch]$AppendSerial,
  [switch]$DebugOnly,
  [switch]$Json
)

$ErrorActionPreference = "Stop"

$RepoRoot = Resolve-Path (Join-Path $PSScriptRoot "..")
Set-Location $RepoRoot

if ([string]::IsNullOrWhiteSpace($DebugUrl) -and -not [string]::IsNullOrWhiteSpace($DeviceHost)) {
  $DebugUrl = "http://$DeviceHost`:8789/debug"
}

if ($DurationSeconds -lt 1) {
  throw "DurationSeconds must be at least 1."
}
if ($PollIntervalSeconds -lt 1) {
  throw "PollIntervalSeconds must be at least 1."
}

New-Item -ItemType Directory -Force -Path $EvidenceRoot | Out-Null
$EvidencePath = (Resolve-Path $EvidenceRoot).Path

$debugLogPath = Join-Path $EvidencePath "FULL_ONLINE_DEBUG_POLL.jsonl"
$serialLogPath = Join-Path $EvidencePath "full_online_serial.log"

$includeSerial = -not [bool]$DebugOnly
$summaryJsonPath = Join-Path $EvidencePath $(if ($includeSerial) { "FULL_ONLINE_VALIDATION_LOGGING.json" } else { "FULL_ONLINE_DEBUG_ONLY_LOGGING.json" })
$summaryMarkdownPath = Join-Path $EvidencePath $(if ($includeSerial) { "FULL_ONLINE_VALIDATION_LOGGING.md" } else { "FULL_ONLINE_DEBUG_ONLY_LOGGING.md" })
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
  $Value | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $Path -Encoding UTF8
}

function Get-DebugSnapshot {
  if (-not [string]::IsNullOrWhiteSpace($DebugJsonPath)) {
    if (-not (Test-Path -LiteralPath $DebugJsonPath -PathType Leaf)) {
      throw "Missing debug fixture: $DebugJsonPath"
    }
    return Get-Content -LiteralPath $DebugJsonPath -Raw | ConvertFrom-Json
  }
  return Invoke-RestMethod -Uri $DebugUrl -TimeoutSec 5
}

Add-Step "evidence-root" "pass" $EvidencePath
Add-Step "debug-output" "pass" $debugLogPath

if ($includeSerial) {
  Add-Step "operator-present" ($(if ($OperatorPresent) { "pass" } else { "fail" })) "Serial capture requires -OperatorPresent."
  Add-Step "body-clear" ($(if ($BodyClear) { "pass" } else { "fail" })) "Serial capture requires -BodyClear."
  Add-Step "serial-output" "pending" $serialLogPath
} else {
  Add-Step "serial-output" "pending" "Skipped by -DebugOnly."
}

$failedBeforeCapture = @($steps | Where-Object { $_.status -eq "fail" })
$startedAt = (Get-Date)
$endedAt = $null
$debugPolls = 0
$debugFailures = 0
$serialLines = 0
$serialBytes = 0
$serial = $null
$serialBuffer = ""

try {
  if ($failedBeforeCapture.Count -eq 0) {
    if ($includeSerial) {
      $serial = [System.IO.Ports.SerialPort]::new($Port, $BaudRate)
      $serial.ReadTimeout = 100
      $serial.DtrEnable = [bool]$DtrEnable
      $serial.RtsEnable = [bool]$RtsEnable
      $serial.Open()
      Add-Step "serial-open" "pass" "$Port@$BaudRate dtr=$([bool]$DtrEnable) rts=$([bool]$RtsEnable)"
      $serialHeader = "# Stackchan full-online serial log started $($startedAt.ToString("o")) port=$Port baud=$BaudRate append=$([bool]$AppendSerial)"
      if ($AppendSerial -and (Test-Path -LiteralPath $serialLogPath -PathType Leaf)) {
        $serialHeader | Add-Content -LiteralPath $serialLogPath -Encoding UTF8
      } else {
        $serialHeader | Set-Content -LiteralPath $serialLogPath -Encoding UTF8
      }
    }

    $deadline = $startedAt.AddSeconds($DurationSeconds)
    $nextPoll = $startedAt
    while ((Get-Date) -lt $deadline) {
      $now = Get-Date
      if ($now -ge $nextPoll) {
        try {
          $debug = Get-DebugSnapshot
          $entry = [ordered]@{
            capturedAt = $now.ToString("o")
            debug = $debug
          }
          ($entry | ConvertTo-Json -Depth 8 -Compress) | Add-Content -LiteralPath $debugLogPath -Encoding UTF8
          $debugPolls += 1
        } catch {
          $debugFailures += 1
          $entry = [ordered]@{
            capturedAt = $now.ToString("o")
            error = $_.Exception.Message
          }
          ($entry | ConvertTo-Json -Depth 8 -Compress) | Add-Content -LiteralPath $debugLogPath -Encoding UTF8
        }
        $nextPoll = $now.AddSeconds($PollIntervalSeconds)
      }

      if ($includeSerial -and $null -ne $serial -and $serial.IsOpen) {
        try {
          $chunk = $serial.ReadExisting()
          if (-not [string]::IsNullOrEmpty($chunk)) {
            $serialBytes += [System.Text.Encoding]::UTF8.GetByteCount($chunk)
            $serialBuffer += $chunk
            while ($serialBuffer -match "^(.*?)(\r?\n)(.*)$") {
              $line = $Matches[1]
              $serialBuffer = $Matches[3]
              $serialLines += 1
              "[$((Get-Date).ToString("o"))] $line" | Add-Content -LiteralPath $serialLogPath -Encoding UTF8
            }
          }
        } catch [System.TimeoutException] {
        }
      }

      Start-Sleep -Milliseconds 100
    }

    if ($includeSerial -and -not [string]::IsNullOrEmpty($serialBuffer)) {
      $serialLines += 1
      "[$((Get-Date).ToString("o"))] $serialBuffer" | Add-Content -LiteralPath $serialLogPath -Encoding UTF8
    }
  }
} finally {
  if ($null -ne $serial) {
    if ($serial.IsOpen) {
      $serial.Close()
    }
    $serial.Dispose()
  }
  $endedAt = Get-Date
}

if ($failedBeforeCapture.Count -eq 0) {
  Add-Step "debug-polls" ($(if ($debugPolls -gt 0 -and $debugFailures -eq 0) { "pass" } elseif ($debugPolls -gt 0) { "pending" } else { "fail" })) "polls=$debugPolls failures=$debugFailures"
  if ($includeSerial) {
    for ($i = 0; $i -lt $steps.Count; $i++) {
      if ($steps[$i]["id"] -eq "serial-output") {
        $steps[$i]["status"] = "pass"
        $steps[$i]["detail"] = "$serialLogPath lines=$serialLines bytes=$serialBytes"
      }
    }
  }
}

$failed = @($steps | Where-Object { $_.status -eq "fail" })
$pending = @($steps | Where-Object { $_.status -eq "pending" })
$status = if ($failed.Count -gt 0) {
  "full-online-validation-logging-not-started"
} elseif ($pending.Count -gt 0) {
  "full-online-validation-logging-partial"
} else {
  "full-online-validation-logging-complete"
}

$result = [ordered]@{
  schema = "stackchan.full-online-validation-logging.v1"
  status = $status
  evidenceRoot = $EvidencePath
  startedAt = $startedAt.ToString("o")
  endedAt = $endedAt.ToString("o")
  durationSeconds = $DurationSeconds
  pollIntervalSeconds = $PollIntervalSeconds
  debugUrl = $DebugUrl
  debugLogPath = $debugLogPath
  debugPolls = $debugPolls
  debugFailures = $debugFailures
  serialIncluded = $includeSerial
  serialLogPath = $(if ($includeSerial) { $serialLogPath } else { $null })
  serialPort = $(if ($includeSerial) { $Port } else { $null })
  serialBaudRate = $(if ($includeSerial) { $BaudRate } else { $null })
  serialDtrEnable = $(if ($includeSerial) { [bool]$DtrEnable } else { $null })
  serialRtsEnable = $(if ($includeSerial) { [bool]$RtsEnable } else { $null })
  serialAppend = $(if ($includeSerial) { [bool]$AppendSerial } else { $null })
  serialLines = $serialLines
  serialBytes = $serialBytes
  operatorPresent = [bool]$OperatorPresent
  bodyClear = [bool]$BodyClear
  passed = @($steps | Where-Object { $_.status -eq "pass" }).Count
  failed = $failed.Count
  pending = $pending.Count
  steps = $steps
}

Write-JsonFile $summaryJsonPath $result

$lines = @(
  "# Stackchan Full-Online Validation Logging",
  "",
  "- Schema: ``$($result.schema)``",
  "- Status: ``$($result.status)``",
  "- Evidence root: ``$EvidencePath``",
  "- Debug poll log: ``$debugLogPath``",
  "- Serial log: ``$($result.serialLogPath)``",
  "- Serial DTR enabled: ``$($result.serialDtrEnable)``",
  "- Serial RTS enabled: ``$($result.serialRtsEnable)``",
  "- Serial append: ``$($result.serialAppend)``",
  "- Debug polls: ``$debugPolls``",
  "- Debug failures: ``$debugFailures``",
  "- Serial lines: ``$serialLines``",
  "- Serial bytes: ``$serialBytes``",
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
if ($result.status -eq "full-online-validation-logging-complete") {
  $lines += "- Keep this capture running through the robot-mic turn, servo motion, and safe stop."
} elseif ($result.status -eq "full-online-validation-logging-partial") {
  $lines += "- Debug logging completed. Start full serial logging at the bench with ``-OperatorPresent -BodyClear``."
} else {
  $lines += "- Resolve failed safety checks before opening serial."
}
$lines | Set-Content -LiteralPath $summaryMarkdownPath -Encoding UTF8

if ($Json) {
  $result | ConvertTo-Json -Depth 8
} else {
  Write-Host "Full-online validation logging: $status"
  Write-Host "Report: $summaryMarkdownPath"
}

if ($failed.Count -gt 0) {
  exit 1
}
