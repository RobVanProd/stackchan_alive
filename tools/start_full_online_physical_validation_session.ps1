param(
  [string]$EvidenceRoot = "output\pc-brain\full-online-validation-latest",
  [string]$DeviceHost = "192.168.1.238",
  [string]$DebugUrl = "",
  [string]$DebugJsonPath = "",
  [string]$VoiceBeforeDebugJsonPath = "",
  [string]$VoiceAfterDebugJsonPath = "",
  [string]$ServoBeforeDebugJsonPath = "",
  [string]$ServoAfterDebugJsonPath = "",
  [string]$Port = "COM4",
  [int]$LoggerDurationSeconds = 900,
  [int]$PollIntervalSeconds = 2,
  [string]$Operator = "Rob",
  [string]$ExactSpokenPrompt = "",
  [string]$ObservedTranscript = "",
  [string]$ServoMotionObserved = "",
  [string]$SafeStopCommand = "motion stop",
  [string]$SuggestedVoicePrompt = "hello stackchan",
  [string]$TurnLogFile = "output\pc-brain\latest\turns.jsonl",
  [switch]$OperatorPresent,
  [switch]$BodyClear,
  [switch]$ConfirmServoRisk,
  [switch]$NoLogger,
  [switch]$LoggerDebugOnly,
  [switch]$NonInteractive,
  [switch]$SkipVoice,
  [switch]$SkipServo,
  [switch]$CompleteReview,
  [switch]$ConfirmMicUplink,
  [switch]$ConfirmStt,
  [switch]$ConfirmSelectedVoice,
  [switch]$ConfirmVoiceMatch,
  [switch]$ConfirmServoControlled,
  [switch]$ConfirmSafeStop,
  [switch]$ConfirmNoServoRisk,
  [switch]$ConfirmNoAudioRisk,
  [switch]$Json
)

$ErrorActionPreference = "Stop"

$RepoRoot = Resolve-Path (Join-Path $PSScriptRoot "..")
Set-Location $RepoRoot

if ([string]::IsNullOrWhiteSpace($DebugUrl) -and -not [string]::IsNullOrWhiteSpace($DeviceHost)) {
  $DebugUrl = "http://$DeviceHost`:8789/debug"
}

if ($LoggerDurationSeconds -lt 1) {
  throw "LoggerDurationSeconds must be at least 1."
}
if ($PollIntervalSeconds -lt 1) {
  throw "PollIntervalSeconds must be at least 1."
}
if (-not $NoLogger -and -not $LoggerDebugOnly) {
  if (-not $OperatorPresent) {
    throw "Starting serial validation logging requires -OperatorPresent."
  }
  if (-not $BodyClear) {
    throw "Starting serial validation logging requires -BodyClear."
  }
}
if (-not $SkipServo -and -not $ConfirmServoRisk) {
  throw "Supervised servo validation requires -ConfirmServoRisk."
}

New-Item -ItemType Directory -Force -Path $EvidenceRoot | Out-Null
$EvidencePath = (Resolve-Path $EvidenceRoot).Path
$CollectorScript = Join-Path $PSScriptRoot "collect_full_online_validation_evidence.ps1"
$LoggerScript = Join-Path $PSScriptRoot "start_full_online_validation_logging.ps1"
$ReviewScript = Join-Path $PSScriptRoot "complete_full_online_review.ps1"
$CheckScript = Join-Path $PSScriptRoot "check_full_online_validation.ps1"
$SessionJsonPath = Join-Path $EvidencePath "FULL_ONLINE_PHYSICAL_SESSION.json"
$SessionMarkdownPath = Join-Path $EvidencePath "FULL_ONLINE_PHYSICAL_SESSION.md"
$VoiceTurnLogSnapshotPath = Join-Path $EvidencePath "VOICE_IN_TURN_LOG.json"

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

function Invoke-Collector {
  param([string[]]$Arguments)
  $output = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $CollectorScript @Arguments
  if ($LASTEXITCODE -ne 0) {
    throw "Collector failed with args $($Arguments -join ' '): $output"
  }
  if ($output) {
    return $output | ConvertFrom-Json
  }
  return $null
}

function Invoke-Capture {
  param(
    [string]$Id,
    [string]$SwitchName,
    [string]$SnapshotPath
  )
  $args = @("-EvidenceRoot", $EvidencePath, "-DeviceHost", $DeviceHost, "-Check", "-Json", $SwitchName)
  if (-not [string]::IsNullOrWhiteSpace($DebugUrl)) {
    $args += @("-DebugUrl", $DebugUrl)
  }
  if (-not [string]::IsNullOrWhiteSpace($SnapshotPath)) {
    $args += @("-DebugJsonPath", $SnapshotPath)
  } elseif (-not [string]::IsNullOrWhiteSpace($DebugJsonPath)) {
    $args += @("-DebugJsonPath", $DebugJsonPath)
  }
  $collector = Invoke-Collector $args
  Add-Step $Id "pass" "collectorStatus=$($collector.status) validationStatus=$($collector.validationStatus)"
  return $collector
}

function Wait-Operator {
  param([string]$Message)
  if (-not $NonInteractive) {
    Read-Host $Message | Out-Null
  }
}

function Quote-Arg {
  param([string]$Value)
  if ($Value -match '[\s"]') {
    return '"' + ($Value -replace '"', '\"') + '"'
  }
  return $Value
}

function Get-TurnLogLines {
  if ([string]::IsNullOrWhiteSpace($TurnLogFile) -or -not (Test-Path -LiteralPath $TurnLogFile -PathType Leaf)) {
    return @()
  }
  return @(Get-Content -LiteralPath $TurnLogFile | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
}

function Capture-LatestTurnLog {
  param([int]$BeforeLineCount)

  $lines = Get-TurnLogLines
  if ($lines.Count -eq 0) {
    Add-Step "voice-turn-log" "pending" "No turn log lines found at $TurnLogFile."
    return [ordered]@{
      captured = $false
      path = $VoiceTurnLogSnapshotPath
      turnLogFile = $TurnLogFile
      lineCountBefore = $BeforeLineCount
      lineCountAfter = 0
      newLineObserved = $false
    }
  }

  $latest = $lines[-1]
  try {
    $turn = $latest | ConvertFrom-Json
  } catch {
    Add-Step "voice-turn-log" "pending" "Latest turn log line was not JSON: $($_.Exception.Message)"
    return [ordered]@{
      captured = $false
      path = $VoiceTurnLogSnapshotPath
      turnLogFile = $TurnLogFile
      lineCountBefore = $BeforeLineCount
      lineCountAfter = $lines.Count
      newLineObserved = ($lines.Count -gt $BeforeLineCount)
    }
  }

  $newLineObserved = ($lines.Count -gt $BeforeLineCount)
  $snapshot = [ordered]@{
    schema = "stackchan.full-online-voice-turn-log-snapshot.v1"
    capturedAt = (Get-Date).ToString("o")
    turnLogFile = $TurnLogFile
    lineCountBefore = $BeforeLineCount
    lineCountAfter = $lines.Count
    newLineObserved = $newLineObserved
    turn = $turn
  }
  Write-JsonFile $VoiceTurnLogSnapshotPath $snapshot
  Add-Step "voice-turn-log" ($(if ($newLineObserved) { "pass" } else { "pending" })) "snapshot=$VoiceTurnLogSnapshotPath newLineObserved=$newLineObserved transcript=$($turn.transcript) tts_voice=$($turn.tts_voice)"
  return [ordered]@{
    captured = $true
    path = $VoiceTurnLogSnapshotPath
    turnLogFile = $TurnLogFile
    lineCountBefore = $BeforeLineCount
    lineCountAfter = $lines.Count
    newLineObserved = $newLineObserved
  }
}

$startedAt = Get-Date
Add-Step "evidence-root" "pass" $EvidencePath
Add-Step "suggested-voice-prompt" "pass" $SuggestedVoicePrompt

$initialCollector = Invoke-Collector @("-EvidenceRoot", $EvidencePath, "-DeviceHost", $DeviceHost, "-Check", "-Json")
Add-Step "initial-validation-check" "pass" "validationStatus=$($initialCollector.validationStatus)"

$loggerProcess = $null
$voiceTurnLog = [ordered]@{
  captured = $false
  path = $VoiceTurnLogSnapshotPath
  turnLogFile = $TurnLogFile
  lineCountBefore = 0
  lineCountAfter = 0
  newLineObserved = $false
}
if ($NoLogger) {
  Add-Step "validation-logger" "pending" "Skipped by -NoLogger."
} else {
  $loggerStdout = Join-Path $EvidencePath "full_online_validation_logger.stdout.json"
  $loggerStderr = Join-Path $EvidencePath "full_online_validation_logger.stderr.log"
  $loggerArgs = @(
    "-NoProfile",
    "-ExecutionPolicy", "Bypass",
    "-File", (Quote-Arg $LoggerScript),
    "-EvidenceRoot", (Quote-Arg $EvidencePath),
    "-DeviceHost", $DeviceHost,
    "-Port", $Port,
    "-DurationSeconds", ([string]$LoggerDurationSeconds),
    "-PollIntervalSeconds", ([string]$PollIntervalSeconds),
    "-AppendSerial",
    "-Json"
  )
  if ($LoggerDebugOnly) {
    $loggerArgs += "-DebugOnly"
  } else {
    $loggerArgs += @("-OperatorPresent", "-BodyClear")
  }
  if (-not [string]::IsNullOrWhiteSpace($DebugUrl)) {
    $loggerArgs += @("-DebugUrl", $DebugUrl)
  }
  if (-not [string]::IsNullOrWhiteSpace($DebugJsonPath)) {
    $loggerArgs += @("-DebugJsonPath", (Quote-Arg $DebugJsonPath))
  }
  $loggerProcess = Start-Process -FilePath "powershell.exe" -ArgumentList $loggerArgs -WindowStyle Hidden -PassThru -RedirectStandardOutput $loggerStdout -RedirectStandardError $loggerStderr
  Add-Step "validation-logger" "pass" "pid=$($loggerProcess.Id) stdout=$loggerStdout stderr=$loggerStderr"
  Start-Sleep -Seconds 2
}

if (-not $SkipVoice) {
  $null = Invoke-Capture "voice-before-debug" "-CaptureVoiceBefore" $VoiceBeforeDebugJsonPath
  $turnLogBeforeLineCount = (Get-TurnLogLines).Count
  Wait-Operator "Say '$SuggestedVoicePrompt' to the robot, wait for the response, then press Enter"
  $null = Invoke-Capture "voice-after-debug" "-CaptureVoiceAfter" $VoiceAfterDebugJsonPath
  $voiceTurnLog = Capture-LatestTurnLog -BeforeLineCount $turnLogBeforeLineCount
} else {
  Add-Step "voice-capture" "pending" "Skipped by -SkipVoice."
}

if (-not $SkipServo) {
  $null = Invoke-Capture "servo-before-debug" "-CaptureServoBefore" $ServoBeforeDebugJsonPath
  Wait-Operator "Perform controlled servo motion, then motion stop or safe stop, then press Enter"
  $null = Invoke-Capture "servo-after-debug" "-CaptureServoAfter" $ServoAfterDebugJsonPath
} else {
  Add-Step "servo-capture" "pending" "Skipped by -SkipServo."
}

$reviewResult = $null
if ($CompleteReview) {
  $reviewArgs = @(
    "-EvidenceRoot", $EvidencePath,
    "-Operator", $Operator,
    "-ExactSpokenPrompt", $ExactSpokenPrompt,
    "-ObservedTranscript", $ObservedTranscript,
    "-ServoMotionObserved", $ServoMotionObserved,
    "-SafeStopCommand", $SafeStopCommand,
    "-Check",
    "-Json"
  )
  foreach ($flag in @(
      @{ enabled = $ConfirmMicUplink; name = "-ConfirmMicUplink" },
      @{ enabled = $ConfirmStt; name = "-ConfirmStt" },
      @{ enabled = $ConfirmSelectedVoice; name = "-ConfirmSelectedVoice" },
      @{ enabled = $ConfirmVoiceMatch; name = "-ConfirmVoiceMatch" },
      @{ enabled = $ConfirmServoControlled; name = "-ConfirmServoControlled" },
      @{ enabled = $ConfirmSafeStop; name = "-ConfirmSafeStop" },
      @{ enabled = $ConfirmNoServoRisk; name = "-ConfirmNoServoRisk" },
      @{ enabled = $ConfirmNoAudioRisk; name = "-ConfirmNoAudioRisk" }
    )) {
    if ($flag.enabled) {
      $reviewArgs += $flag.name
    }
  }
  $reviewOutput = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $ReviewScript @reviewArgs
  if ($LASTEXITCODE -ne 0) {
    throw "Review completion failed: $reviewOutput"
  }
  $reviewResult = $reviewOutput | ConvertFrom-Json
  Add-Step "review-completion" "pass" "validationStatus=$($reviewResult.validationStatus) pending=$($reviewResult.validationPending)"
} else {
  Add-Step "review-completion" "pending" "Skipped. Run complete_full_online_review.cmd after human confirmations."
}

$checkOutput = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $CheckScript -EvidenceRoot $EvidencePath -Json
if ($LASTEXITCODE -ne 0) {
  throw "Final validation check failed: $checkOutput"
}
$validation = $checkOutput | ConvertFrom-Json
Add-Step "final-validation-check" "pass" "status=$($validation.status) failed=$($validation.failed) pending=$($validation.pending)"

$failed = @($steps | Where-Object { $_.status -eq "fail" })
$pending = @($steps | Where-Object { $_.status -eq "pending" })
$result = [ordered]@{
  schema = "stackchan.full-online-physical-session.v1"
  status = $(if ($failed.Count -gt 0) { "full-online-physical-session-failed" } elseif ($validation.status -eq "full-online-validation-ready") { "full-online-physical-session-ready" } else { "full-online-physical-session-pending-review" })
  evidenceRoot = $EvidencePath
  startedAt = $startedAt.ToString("o")
  endedAt = (Get-Date).ToString("o")
  loggerStarted = ($null -ne $loggerProcess)
  loggerDebugOnly = [bool]$LoggerDebugOnly
  loggerPid = $(if ($null -ne $loggerProcess) { $loggerProcess.Id } else { $null })
  suggestedVoicePrompt = $SuggestedVoicePrompt
  voiceTurnLog = $voiceTurnLog
  validationStatus = $validation.status
  validationFailed = $validation.failed
  validationPending = $validation.pending
  passed = @($steps | Where-Object { $_.status -eq "pass" }).Count
  failed = $failed.Count
  pending = $pending.Count
  steps = $steps
}
Write-JsonFile $SessionJsonPath $result

$lines = @(
  "# Stackchan Full-Online Physical Validation Session",
  "",
  "- Schema: ``$($result.schema)``",
  "- Status: ``$($result.status)``",
  "- Evidence root: ``$EvidencePath``",
  "- Logger started: ``$($result.loggerStarted)``",
  "- Logger debug-only: ``$($result.loggerDebugOnly)``",
  "- Logger PID: ``$($result.loggerPid)``",
  "- Suggested voice prompt: ``$($result.suggestedVoicePrompt)``",
  "- Voice turn log snapshot: ``$($result.voiceTurnLog.path)``",
  "- Voice turn log new line observed: ``$($result.voiceTurnLog.newLineObserved)``",
  "- Validation status: ``$($result.validationStatus)``",
  "- Validation failed: ``$($result.validationFailed)``",
  "- Validation pending: ``$($result.validationPending)``",
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
if ($result.validationStatus -eq "full-online-validation-ready") {
  $lines += "- Full-online validation is ready. Preserve this evidence folder."
} else {
  $lines += "- Finish any pending physical confirmations, then run ``complete_full_online_review.cmd`` and the strict validation check."
}
$lines | Set-Content -LiteralPath $SessionMarkdownPath -Encoding UTF8

if ($Json) {
  $result | ConvertTo-Json -Depth 8
} else {
  Write-Host "Full-online physical session: $($result.status)"
  Write-Host "Report: $SessionMarkdownPath"
}

if ($failed.Count -gt 0) {
  exit 1
}
