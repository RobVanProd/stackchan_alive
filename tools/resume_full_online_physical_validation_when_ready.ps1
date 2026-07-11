param(
  [string]$EvidenceRoot = "output\pc-brain\full-online-validation-latest",
  [string]$DeviceHost = "192.168.1.238",
  [string]$DebugUrl = "",
  [string]$DebugJsonPath = "",
  [string]$Port = "COM4",
  [string]$ReadinessJsonPath = "",
  [string]$ReadinessReportDir = "output\pc-brain\full-online-physical-session-readiness-latest",
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
  [switch]$FullSerialLogger,
  [switch]$CheckSerialOpen,
  [switch]$CompleteReview,
  [switch]$ConfirmMicUplink,
  [switch]$ConfirmStt,
  [switch]$ConfirmSelectedVoice,
  [switch]$ConfirmVoiceMatch,
  [switch]$ConfirmServoControlled,
  [switch]$ConfirmSafeStop,
  [switch]$ConfirmNoServoRisk,
  [switch]$ConfirmNoAudioRisk,
  [switch]$DryRun,
  [switch]$Json
)

$ErrorActionPreference = "Stop"

$RepoRoot = Resolve-Path (Join-Path $PSScriptRoot "..")
Set-Location $RepoRoot

if ([string]::IsNullOrWhiteSpace($DebugUrl) -and -not [string]::IsNullOrWhiteSpace($DeviceHost)) {
  $DebugUrl = "http://$DeviceHost`:8789/debug"
}

$ReadinessScript = Join-Path $PSScriptRoot "check_full_online_physical_session_readiness.ps1"
$StatusScript = Join-Path $PSScriptRoot "check_stackchan_full_online_status.ps1"
$SessionScript = Join-Path $PSScriptRoot "start_full_online_physical_validation_session.ps1"

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

function Quote-Arg {
  param([string]$Value)
  if ($Value -match '[\s"]') {
    return '"' + ($Value -replace '"', '\"') + '"'
  }
  return $Value
}

function Read-JsonFile {
  param([string]$Path)
  return Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json
}

function Invoke-StatusRefresh {
  if (-not [string]::IsNullOrWhiteSpace($ReadinessJsonPath)) {
    Add-Step "status-refresh" "pending" "Skipped because -ReadinessJsonPath was supplied."
    return $null
  }

  $args = @(
    "-DeviceHost", $DeviceHost,
    "-Json"
  )
  if (-not [string]::IsNullOrWhiteSpace($DebugUrl)) {
    $args += @("-DebugUrl", $DebugUrl)
  }
  if (-not [string]::IsNullOrWhiteSpace($DebugJsonPath)) {
    $args += @("-DebugJsonPath", $DebugJsonPath)
  }

  $output = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $StatusScript @args
  if ($LASTEXITCODE -ne 0) {
    throw "Aggregate status refresh failed: $output"
  }
  $status = $output | ConvertFrom-Json
  Add-Step "status-refresh" "pass" "status=$($status.status) failed=$($status.failed) pending=$($status.pending)"
  return $status
}

function Invoke-Readiness {
  if (-not [string]::IsNullOrWhiteSpace($ReadinessJsonPath)) {
    if (-not (Test-Path -LiteralPath $ReadinessJsonPath -PathType Leaf)) {
      throw "ReadinessJsonPath does not exist: $ReadinessJsonPath"
    }
    return Read-JsonFile $ReadinessJsonPath
  }

  $args = @(
    "-DeviceHost", $DeviceHost,
    "-Port", $Port,
    "-ReportDir", $ReadinessReportDir,
    "-Json"
  )
  if (-not [string]::IsNullOrWhiteSpace($DebugUrl)) {
    $args += @("-DebugUrl", $DebugUrl)
  }
  if (-not [string]::IsNullOrWhiteSpace($DebugJsonPath)) {
    $args += @("-DebugJsonPath", $DebugJsonPath)
  }
  if ($CheckSerialOpen) {
    $args += "-CheckSerialOpen"
    if ($OperatorPresent) {
      $args += "-OperatorPresent"
    }
  }

  $output = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $ReadinessScript @args
  if ($LASTEXITCODE -ne 0) {
    throw "Physical-session readiness check failed: $output"
  }
  return $output | ConvertFrom-Json
}

$startedAt = Get-Date
New-Item -ItemType Directory -Force -Path $EvidenceRoot | Out-Null
$EvidencePath = (Resolve-Path $EvidenceRoot).Path

Add-Step "operator-present" ($(if ($OperatorPresent) { "pass" } else { "fail" })) "Operator must be present for the physical validation session."
Add-Step "body-clear" ($(if ($BodyClear) { "pass" } else { "fail" })) "Body and servo area must be clear before physical validation."
Add-Step "servo-risk-confirmed" ($(if ($ConfirmServoRisk) { "pass" } else { "fail" })) "Servo risk must be explicitly accepted before physical validation."
$reviewRequested = (
  -not [string]::IsNullOrWhiteSpace($ExactSpokenPrompt) -or
  -not [string]::IsNullOrWhiteSpace($ObservedTranscript) -or
  -not [string]::IsNullOrWhiteSpace($ServoMotionObserved) -or
  $ConfirmMicUplink -or
  $ConfirmStt -or
  $ConfirmSelectedVoice -or
  $ConfirmVoiceMatch -or
  $ConfirmServoControlled -or
  $ConfirmSafeStop -or
  $ConfirmNoServoRisk -or
  $ConfirmNoAudioRisk
)
Add-Step "review-mode" ($(if ($CompleteReview -or -not $reviewRequested) { "pass" } else { "fail" })) $(if ($CompleteReview) { "Review completion will be passed to the guided session." } elseif ($reviewRequested) { "Review fields require -CompleteReview." } else { "Review completion not requested." })

$readiness = $null
try {
  $null = Invoke-StatusRefresh
  $readiness = Invoke-Readiness
  Add-Step "readiness-check" "pass" "status=$($readiness.status) readyForPhysicalSession=$($readiness.readyForPhysicalSession) failed=$($readiness.failed)"
  Add-Step "readiness-schema" ($(if ($readiness.schema -eq "stackchan.full-online-physical-session-readiness.v1") { "pass" } else { "fail" })) "schema=$($readiness.schema)"
  Add-Step "readiness-ready" ($(if ($readiness.readyForPhysicalSession -eq $true -and [int]$readiness.failed -eq 0) { "pass" } else { "fail" })) "status=$($readiness.status) failed=$($readiness.failed) pending=$($readiness.pending)"
} catch {
  Add-Step "readiness-check" "fail" $_.Exception.Message
}

$sessionArgs = @(
  "-EvidenceRoot", $EvidencePath,
  "-DeviceHost", $DeviceHost,
  "-Port", $Port,
  "-OperatorPresent",
  "-BodyClear",
  "-ConfirmServoRisk",
  "-SuggestedVoicePrompt", $SuggestedVoicePrompt,
  "-TurnLogFile", $TurnLogFile,
  "-LoggerDurationSeconds", ([string]$LoggerDurationSeconds),
  "-PollIntervalSeconds", ([string]$PollIntervalSeconds)
)
if (-not $FullSerialLogger) {
  $sessionArgs += "-LoggerDebugOnly"
}
if (-not [string]::IsNullOrWhiteSpace($DebugUrl)) {
  $sessionArgs += @("-DebugUrl", $DebugUrl)
}
if (-not [string]::IsNullOrWhiteSpace($DebugJsonPath)) {
  $sessionArgs += @("-DebugJsonPath", $DebugJsonPath)
}
if ($CompleteReview) {
  $sessionArgs += @(
    "-CompleteReview",
    "-Operator", $Operator,
    "-ExactSpokenPrompt", $ExactSpokenPrompt,
    "-ObservedTranscript", $ObservedTranscript,
    "-ServoMotionObserved", $ServoMotionObserved,
    "-SafeStopCommand", $SafeStopCommand
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
      $sessionArgs += $flag.name
    }
  }
}

$sessionCommand = ".\tools\start_full_online_physical_validation_session.cmd " + (($sessionArgs | ForEach-Object { Quote-Arg $_ }) -join " ")
$failedBeforeSession = @($steps | Where-Object { $_.status -eq "fail" })
$sessionResult = $null

if ($DryRun) {
  Add-Step "physical-session" "pending" "Dry run only. Command was rendered but not started."
} elseif ($failedBeforeSession.Count -gt 0) {
  Add-Step "physical-session" "pending" "Not started because guard checks failed."
} else {
  $sessionOutput = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $SessionScript @sessionArgs -Json
  if ($LASTEXITCODE -ne 0) {
    Add-Step "physical-session" "fail" $sessionOutput
  } else {
    $sessionResult = $sessionOutput | ConvertFrom-Json
    Add-Step "physical-session" "pass" "status=$($sessionResult.status) validationStatus=$($sessionResult.validationStatus)"
  }
}

$failed = @($steps | Where-Object { $_.status -eq "fail" })
$pending = @($steps | Where-Object { $_.status -eq "pending" })
$status = if ($failed.Count -gt 0) {
  "full-online-physical-validation-resume-not-ready"
} elseif ($DryRun) {
  "full-online-physical-validation-resume-dry-run-ready"
} elseif ($null -ne $sessionResult -and $sessionResult.status -eq "full-online-physical-session-ready") {
  "full-online-physical-validation-resume-complete"
} else {
  "full-online-physical-validation-resume-started"
}

$result = [ordered]@{
  schema = "stackchan.full-online-physical-validation-resume.v1"
  status = $status
  evidenceRoot = $EvidencePath
  startedAt = $startedAt.ToString("o")
  endedAt = (Get-Date).ToString("o")
  deviceHost = $DeviceHost
  debugUrl = $DebugUrl
  port = $Port
  dryRun = [bool]$DryRun
  fullSerialLogger = [bool]$FullSerialLogger
  completeReview = [bool]$CompleteReview
  readinessStatus = $(if ($null -ne $readiness) { $readiness.status } else { $null })
  readinessFailed = $(if ($null -ne $readiness) { $readiness.failed } else { $null })
  sessionStatus = $(if ($null -ne $sessionResult) { $sessionResult.status } else { $null })
  sessionValidationStatus = $(if ($null -ne $sessionResult) { $sessionResult.validationStatus } else { $null })
  sessionCommand = $sessionCommand
  passed = @($steps | Where-Object { $_.status -eq "pass" }).Count
  failed = $failed.Count
  pending = $pending.Count
  steps = $steps
}

$jsonPath = Join-Path $EvidencePath "FULL_ONLINE_PHYSICAL_VALIDATION_RESUME.json"
$markdownPath = Join-Path $EvidencePath "FULL_ONLINE_PHYSICAL_VALIDATION_RESUME.md"
$result | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $jsonPath -Encoding UTF8

$lines = @(
  "# Stackchan Full-Online Physical Validation Resume",
  "",
  "- Schema: ``$($result.schema)``",
  "- Status: ``$($result.status)``",
  "- Dry run: ``$($result.dryRun)``",
  "- Full serial logger: ``$($result.fullSerialLogger)``",
  "- Complete review: ``$($result.completeReview)``",
  "- Readiness status: ``$($result.readinessStatus)``",
  "- Session status: ``$($result.sessionStatus)``",
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
$lines += "## Session Command"
$lines += ""
$lines += '```powershell'
$lines += $result.sessionCommand
$lines += '```'
$lines | Set-Content -LiteralPath $markdownPath -Encoding UTF8

if ($Json) {
  $result | ConvertTo-Json -Depth 8
} else {
  Write-Host "Full-online physical validation resume: $status"
  Write-Host "Report: $markdownPath"
}

if ($failed.Count -gt 0) {
  exit 1
}
