param(
  [string]$EvidenceRoot = "output\pc-brain\full-online-validation-latest",
  [string]$DeviceHost = "192.168.1.238",
  [string]$DebugUrl = "",
  [string]$DebugJsonPath = "",
  [string]$PreflightPath = "output\pc-brain\full-online-preflight-latest\FULL_ONLINE_PREFLIGHT.json",
  [switch]$Prepare,
  [switch]$CaptureRuntime,
  [switch]$CaptureLiveGate,
  [switch]$CaptureVoiceBefore,
  [switch]$CaptureVoiceAfter,
  [switch]$CaptureVoiceOutBefore,
  [switch]$CaptureVoiceOutAfter,
  [switch]$CaptureServoBefore,
  [switch]$CaptureServoAfter,
  [switch]$Check,
  [switch]$RequireReady,
  [switch]$Json
)

$ErrorActionPreference = "Stop"

$RepoRoot = Resolve-Path (Join-Path $PSScriptRoot "..")
Set-Location $RepoRoot
$ValidationCheckScript = Join-Path $PSScriptRoot "check_full_online_validation.ps1"
$RuntimeCheckScript = Join-Path $PSScriptRoot "check_pc_brain_runtime.ps1"

if ([string]::IsNullOrWhiteSpace($DebugUrl) -and -not [string]::IsNullOrWhiteSpace($DeviceHost)) {
  $DebugUrl = "http://$DeviceHost`:8789/debug"
}

$actionsRequested = @(
  $Prepare,
  $CaptureRuntime,
  $CaptureLiveGate,
  $CaptureVoiceBefore,
  $CaptureVoiceAfter,
  $CaptureVoiceOutBefore,
  $CaptureVoiceOutAfter,
  $CaptureServoBefore,
  $CaptureServoAfter,
  $Check
) | Where-Object { $_ }

if ($actionsRequested.Count -eq 0) {
  $Prepare = $true
  $Check = $true
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

function Get-IntValue {
  param($Object, [string]$Name, [int]$DefaultValue = 0)
  if ($null -eq $Object) { return $DefaultValue }
  $property = $Object.PSObject.Properties[$Name]
  if ($null -eq $property -or $null -eq $property.Value) { return $DefaultValue }
  return [int]$property.Value
}

function Get-DebugSnapshot {
  if (-not [string]::IsNullOrWhiteSpace($DebugJsonPath)) {
    if (-not (Test-Path -LiteralPath $DebugJsonPath -PathType Leaf)) {
      throw "Missing debug JSON fixture: $DebugJsonPath"
    }
    return Get-Content -LiteralPath $DebugJsonPath -Raw | ConvertFrom-Json
  }

  if ([string]::IsNullOrWhiteSpace($DebugUrl)) {
    throw "Pass -DeviceHost, -DebugUrl, or -DebugJsonPath to capture debug evidence."
  }
  return Invoke-RestMethod -Uri $DebugUrl -TimeoutSec 5
}

function Write-JsonFile {
  param([string]$Path, $Value)
  $Value | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $Path -Encoding UTF8
}

function Add-LiveGateCheck {
  param(
    [ref]$Checks,
    [string]$Id,
    [bool]$Passed,
    [string]$Detail
  )
  $Checks.Value += [ordered]@{
    id = $Id
    status = $(if ($Passed) { "pass" } else { "fail" })
    detail = $Detail
  }
}

function Write-LiveGate {
  param($Debug, [string]$EvidencePath)

  $checks = @()
  Add-LiveGateCheck ([ref]$checks) "live-debug-network-ready" ($Debug.network_state -eq "connected" -and $Debug.bridge_state -eq "ready") "network=$($Debug.network_state) bridge=$($Debug.bridge_state)"
  Add-LiveGateCheck ([ref]$checks) "live-debug-network-error-clear" ([string]$Debug.network_error -eq "") "network_error=$($Debug.network_error)"
  Add-LiveGateCheck ([ref]$checks) "full-online-servos-compiled" ((Get-IntValue $Debug "compiled_enable_servos" 0) -eq 1) "compiled_enable_servos=$($Debug.compiled_enable_servos)"
  Add-LiveGateCheck ([ref]$checks) "full-online-speaker-compiled" ((Get-IntValue $Debug "compiled_enable_speaker" 0) -eq 1) "compiled_enable_speaker=$($Debug.compiled_enable_speaker)"
  Add-LiveGateCheck ([ref]$checks) "full-online-mic-compiled" ((Get-IntValue $Debug "compiled_enable_mic_capture" 0) -eq 1) "compiled_enable_mic_capture=$($Debug.compiled_enable_mic_capture)"
  Add-LiveGateCheck ([ref]$checks) "full-online-uplink-compiled" ((Get-IntValue $Debug "compiled_enable_bridge_audio_uplink" 0) -eq 1) "compiled_enable_bridge_audio_uplink=$($Debug.compiled_enable_bridge_audio_uplink)"
  Add-LiveGateCheck ([ref]$checks) "full-online-motion-enabled" ([bool]$Debug.motion_enabled) "motion_enabled=$($Debug.motion_enabled)"
  Add-LiveGateCheck ([ref]$checks) "full-online-audio-capture-enabled" ([bool]$Debug.audio_capture_enabled) "audio_capture_enabled=$($Debug.audio_capture_enabled)"
  Add-LiveGateCheck ([ref]$checks) "full-online-audio-capture-hw" ([bool]$Debug.audio_capture_hw_ready) "audio_capture_hw_ready=$($Debug.audio_capture_hw_ready)"
  Add-LiveGateCheck ([ref]$checks) "full-online-uplink-ready" ([bool]$Debug.bridge_uplink_ready -and [bool]$Debug.bridge_uplink_enabled) "bridge_uplink_ready=$($Debug.bridge_uplink_ready) bridge_uplink_enabled=$($Debug.bridge_uplink_enabled)"
  Add-LiveGateCheck ([ref]$checks) "full-online-wake-gate-ready" ([bool]$Debug.bridge_wake_gate_ready) "bridge_wake_gate_ready=$($Debug.bridge_wake_gate_ready)"
  Add-LiveGateCheck ([ref]$checks) "full-online-uplink-no-errors" ((Get-IntValue $Debug "bridge_uplink_errors" 0) -eq 0 -and (Get-IntValue $Debug "bridge_uplink_queue_failures" 0) -eq 0) "bridge_uplink_errors=$($Debug.bridge_uplink_errors) queue_failures=$($Debug.bridge_uplink_queue_failures)"

  $failed = @($checks | Where-Object { $_.status -eq "fail" })
  $pending = @($checks | Where-Object { $_.status -eq "pending" })
  $result = [ordered]@{
    schema = "stackchan.first-pc-brain-deploy-check.v1"
    status = $(if ($failed.Count -gt 0) { "first-pc-brain-deploy-not-ready" } elseif ($pending.Count -gt 0) { "first-pc-brain-deploy-pending-human-evidence" } else { "first-pc-brain-deploy-ready" })
    evidenceRoot = $EvidencePath
    machineReady = ($failed.Count -eq 0)
    passed = @($checks | Where-Object { $_.status -eq "pass" }).Count
    failed = $failed.Count
    pending = $pending.Count
    liveDebugUrl = $DebugUrl
    checks = $checks
  }

  Write-JsonFile (Join-Path $EvidencePath "FULL_ONLINE_LIVE_CHECK.json") $result
  Write-JsonFile (Join-Path $EvidencePath "FULL_ONLINE_LIVE_DEBUG.json") $Debug
  return $result
}

function Write-NextActionsMarkdown {
  param(
    [string]$Path,
    [string]$EvidencePath,
    $Validation,
    $CollectorResult
  )

  $validationStatus = if ($null -ne $Validation) { $Validation.status } else { "not-run" }
  $validationChecks = if ($null -ne $Validation -and $null -ne $Validation.checks) { @($Validation.checks) } else { @() }
  function Test-ValidationPending {
    param([string[]]$Ids)
    foreach ($id in $Ids) {
      $check = @($validationChecks | Where-Object { $_.id -eq $id })[0]
      if ($null -ne $check -and $check.status -eq "pending") {
        return $true
      }
    }
    return $false
  }
  $needsVoicePhysical = Test-ValidationPending @(
    "voice-debug-before-after",
    "review-mic-uplink",
    "review-stt",
    "review-selected-voice",
    "review-voice-match",
    "review-no-audio-risk"
  )
  $needsServoPhysical = Test-ValidationPending @(
    "servo-debug-before-after",
    "review-servo-controlled",
    "review-no-servo-risk"
  )
  $needsPhysicalLogging = $needsVoicePhysical -or $needsServoPhysical
  $lines = @(
    "# Stackchan Full-Online Next Actions",
    "",
    "- Evidence root: ``$EvidencePath``",
    "- Collector status: ``$($CollectorResult.status)``",
    "- Validation status: ``$validationStatus``",
    "",
    "## Next",
    ""
  )
  $runtimeJsonPath = Join-Path $EvidencePath "PC_BRAIN_RUNTIME_CHECK.json"
  $liveCheckPath = Join-Path $EvidencePath "FULL_ONLINE_LIVE_CHECK.json"
  $voiceBeforePath = Join-Path $EvidencePath "VOICE_IN_BEFORE_DEBUG.json"
  $voiceAfterPath = Join-Path $EvidencePath "VOICE_IN_AFTER_DEBUG.json"
  $voiceOutBeforePath = Join-Path $EvidencePath "VOICE_OUT_BEFORE_DEBUG.json"
  $voiceOutAfterPath = Join-Path $EvidencePath "VOICE_OUT_AFTER_DEBUG.json"
  $servoBeforePath = Join-Path $EvidencePath "SERVO_BEFORE_DEBUG.json"
  $servoAfterPath = Join-Path $EvidencePath "SERVO_AFTER_DEBUG.json"
  $serialLogPath = Join-Path $EvidencePath "full_online_serial.log"
  $loggingPath = Join-Path $EvidencePath "FULL_ONLINE_VALIDATION_LOGGING.json"

  if ($validationStatus -eq "full-online-validation-ready") {
    $lines += "- Full-online validation is ready. Archive this folder with the deployment evidence."
  } else {
    if (-not (Test-Path -LiteralPath $runtimeJsonPath -PathType Leaf) -or
      -not (Test-Path -LiteralPath $liveCheckPath -PathType Leaf)) {
      $lines += "- After flashing ``stackchan_full_online`` and confirming the body is clear, run:"
      $lines += ""
      $lines += '```powershell'
      $lines += ".\tools\collect_full_online_validation_evidence.cmd -EvidenceRoot output\pc-brain\full-online-validation-latest -DeviceHost 192.168.1.238 -Prepare -CaptureRuntime -CaptureLiveGate -Check -Json"
      $lines += '```'
      $lines += ""
    }

    if ($needsPhysicalLogging -or -not (Test-Path -LiteralPath $loggingPath -PathType Leaf)) {
      $lines += "- Preferred guarded command when Rob is physically ready. It runs the readiness check first, then starts the guided session only with explicit operator/body/servo confirmations:"
      $lines += "- Suggested robot-mic prompt for the voice-in pass: ``hello stackchan``."
      $lines += ""
      $lines += '```powershell'
      $lines += ".\tools\resume_full_online_physical_validation_when_ready.cmd -DeviceHost 192.168.1.238 -Port COM4 -OperatorPresent -BodyClear -ConfirmServoRisk"
      $lines += '```'
      $lines += ""
      $lines += "- If Rob already has the exact spoken prompt, STT transcript, and servo observation ready, the guarded command can also complete the review in one pass:"
      $lines += ""
      $lines += '```powershell'
      $lines += '.\tools\resume_full_online_physical_validation_when_ready.cmd -DeviceHost 192.168.1.238 -Port COM4 -OperatorPresent -BodyClear -ConfirmServoRisk -CompleteReview -Operator "Rob" -ExactSpokenPrompt "<what you said to the robot>" -ObservedTranscript "<what STT heard>" -ServoMotionObserved "<what moved, and that it stopped>" -SafeStopCommand "motion stop" -ConfirmMicUplink -ConfirmStt -ConfirmSelectedVoice -ConfirmVoiceMatch -ConfirmServoControlled -ConfirmSafeStop -ConfirmNoServoRisk -ConfirmNoAudioRisk'
      $lines += '```'
      $lines += ""
      $lines += "- Before Rob starts the physical observations, run the physical-session readiness check. It does not trigger voice or servo motion:"
      $lines += ""
      $lines += '```powershell'
      $lines += ".\tools\check_full_online_physical_session_readiness.cmd -DeviceHost 192.168.1.238 -Port COM4 -Json"
      $lines += '```'
      $lines += ""
      $lines += "- Guided option for the whole physical capture session. This uses debug-only logging so the USB serial port stays available for a serial monitor or emergency ``motion stop``:"
      $lines += ""
      $lines += '```powershell'
      $lines += ".\tools\start_full_online_physical_validation_session.cmd -EvidenceRoot output\pc-brain\full-online-validation-latest -DeviceHost 192.168.1.238 -Port COM4 -OperatorPresent -BodyClear -ConfirmServoRisk -LoggerDebugOnly -SuggestedVoicePrompt `"hello stackchan`""
      $lines += '```'
      $lines += ""
      $lines += "- If motion needs to be stopped from PowerShell while the guided session keeps serial free, send the stop command with DTR/RTS disabled:"
      $lines += ""
      $lines += '```powershell'
      $lines += '.\tools\send_stackchan_serial_command.cmd -EvidenceRoot output\pc-brain\full-online-validation-latest -Port COM4 -Command "motion stop" -OperatorPresent -Json'
      $lines += '```'
      $lines += ""
      $lines += "- In a second terminal, start fresh validation logging before the supervised robot-mic and servo checks. The logger leaves serial DTR/RTS disabled by default:"
      $lines += ""
      $lines += '```powershell'
      $lines += ".\tools\start_full_online_validation_logging.cmd -EvidenceRoot output\pc-brain\full-online-validation-latest -DeviceHost 192.168.1.238 -Port COM4 -OperatorPresent -BodyClear -DurationSeconds 900 -Json"
      $lines += '```'
      $lines += ""
    }

    if ($needsVoicePhysical -or
      -not (Test-Path -LiteralPath $voiceBeforePath -PathType Leaf) -or
      -not (Test-Path -LiteralPath $voiceAfterPath -PathType Leaf)) {
      $lines += "- Immediately before the supervised robot-mic turn, refresh voice-in before-debug:"
      $lines += ""
      $lines += '```powershell'
      $lines += ".\tools\collect_full_online_validation_evidence.cmd -EvidenceRoot output\pc-brain\full-online-validation-latest -DeviceHost 192.168.1.238 -CaptureVoiceBefore -Check -Json"
      $lines += '```'
      $lines += ""
    }

    if ($needsVoicePhysical -or -not (Test-Path -LiteralPath $voiceAfterPath -PathType Leaf)) {
      $lines += "- After one supervised robot-mic voice turn, capture voice-in after-debug:"
      $lines += "- Preserve ``output\pc-brain\latest\turns.jsonl`` after that turn; the latest line should corroborate the STT transcript, selected voice, and response audio payload."
      $lines += ""
      $lines += '```powershell'
      $lines += ".\tools\collect_full_online_validation_evidence.cmd -EvidenceRoot output\pc-brain\full-online-validation-latest -DeviceHost 192.168.1.238 -CaptureVoiceAfter -Check -Json"
      $lines += '```'
      $lines += ""
    }

    if (-not (Test-Path -LiteralPath $voiceOutBeforePath -PathType Leaf)) {
      $lines += "- Before a robot-routed selected-voice text turn, capture voice-out before-debug:"
      $lines += ""
      $lines += '```powershell'
      $lines += ".\tools\collect_full_online_validation_evidence.cmd -EvidenceRoot output\pc-brain\full-online-validation-latest -DeviceHost 192.168.1.238 -CaptureVoiceOutBefore -Check -Json"
      $lines += '```'
      $lines += ""
    }

    if (-not (Test-Path -LiteralPath $voiceOutAfterPath -PathType Leaf)) {
      $lines += "- After the robot-routed selected-voice text turn, capture voice-out after-debug:"
      $lines += ""
      $lines += '```powershell'
      $lines += ".\tools\collect_full_online_validation_evidence.cmd -EvidenceRoot output\pc-brain\full-online-validation-latest -DeviceHost 192.168.1.238 -CaptureVoiceOutAfter -Check -Json"
      $lines += '```'
      $lines += ""
    }

    if ($needsServoPhysical -or -not (Test-Path -LiteralPath $servoBeforePath -PathType Leaf)) {
      $lines += "- Immediately before controlled servo motion, refresh servo before-debug:"
      $lines += ""
      $lines += '```powershell'
      $lines += ".\tools\collect_full_online_validation_evidence.cmd -EvidenceRoot output\pc-brain\full-online-validation-latest -DeviceHost 192.168.1.238 -CaptureServoBefore -Check -Json"
      $lines += '```'
      $lines += ""
    }

    if ($needsServoPhysical -or -not (Test-Path -LiteralPath $servoAfterPath -PathType Leaf)) {
      $lines += "- After controlled servo motion and ``motion stop`` or safe stop, capture servo after-debug:"
      $lines += ""
      $lines += '```powershell'
      $lines += ".\tools\collect_full_online_validation_evidence.cmd -EvidenceRoot output\pc-brain\full-online-validation-latest -DeviceHost 192.168.1.238 -CaptureServoAfter -Check -Json"
      $lines += '```'
      $lines += ""
    }

    if (-not (Test-Path -LiteralPath $serialLogPath -PathType Leaf)) {
      $lines += "- The validation logger writes ``full_online_serial.log`` in this evidence folder. If you use a separate serial monitor instead, save that monitor output with the same filename."
    }
    $lines += "- Fill ``FULL_ONLINE_REVIEW.md`` with ``yes`` for completed proof fields and ``no`` for observed-risk fields when no issue was observed."
    $lines += "- Or, after the physical checks pass, complete the review fields with explicit confirmation flags:"
    $lines += ""
    $lines += '```powershell'
    $lines += '.\tools\complete_full_online_review.cmd -EvidenceRoot output\pc-brain\full-online-validation-latest -Operator "Rob" -ExactSpokenPrompt "<what you said to the robot>" -ObservedTranscript "<what STT heard>" -ServoMotionObserved "<what moved, and that it stopped>" -SafeStopCommand "motion stop" -ConfirmMicUplink -ConfirmStt -ConfirmSelectedVoice -ConfirmVoiceMatch -ConfirmServoControlled -ConfirmSafeStop -ConfirmNoServoRisk -ConfirmNoAudioRisk -Check -Json'
    $lines += '```'
    $lines += "- Close the gate with:"
    $lines += ""
    $lines += '```powershell'
    $lines += ".\tools\check_full_online_validation.cmd -EvidenceRoot output\pc-brain\full-online-validation-latest -RequireReady -Json"
    $lines += '```'
  }

  $lines | Set-Content -LiteralPath $Path -Encoding UTF8
}

New-Item -ItemType Directory -Force -Path $EvidenceRoot | Out-Null
$EvidencePath = (Resolve-Path $EvidenceRoot).Path
Add-Step "evidence-root" "pass" $EvidencePath

if ($Prepare) {
  if (Test-Path -LiteralPath $PreflightPath -PathType Leaf) {
    $preflightSource = (Resolve-Path $PreflightPath).Path
    $preflightDestination = Join-Path $EvidencePath "FULL_ONLINE_PREFLIGHT.json"
    $resolvedDestination = $null
    if (Test-Path -LiteralPath $preflightDestination -PathType Leaf) {
      $resolvedDestination = (Resolve-Path $preflightDestination).Path
    }
    if ($preflightSource -ne $resolvedDestination) {
      Copy-Item -LiteralPath $preflightSource -Destination $preflightDestination -Force
    }
    Add-Step "preflight-copy" "pass" $PreflightPath
  } else {
    Add-Step "preflight-copy" "pending" "Run tools\run_full_online_preflight.cmd before flashing, then rerun this helper."
  }
  $null = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $ValidationCheckScript -EvidenceRoot $EvidencePath -WriteTemplate -Json
  Add-Step "review-template" "pass" (Join-Path $EvidencePath "FULL_ONLINE_REVIEW.md")
}

if ($CaptureRuntime) {
  $runtimeOutput = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $RuntimeCheckScript -DeviceHost $DeviceHost -ReportDir $EvidencePath -Json
  $runtimeExit = $LASTEXITCODE
  Add-Step "runtime-check" ($(if ($runtimeExit -eq 0) { "pass" } else { "fail" })) "PC_BRAIN_RUNTIME_CHECK.json"
  if ($runtimeOutput) {
    $runtimeOutput | Set-Content -LiteralPath (Join-Path $EvidencePath "PC_BRAIN_RUNTIME_CHECK.stdout.json") -Encoding UTF8
  }
}

if ($CaptureLiveGate) {
  $debug = Get-DebugSnapshot
  $gate = Write-LiveGate -Debug $debug -EvidencePath $EvidencePath
  Add-Step "full-online-live-gate" ($(if ($gate.failed -eq 0) { "pass" } else { "fail" })) "FULL_ONLINE_LIVE_CHECK.json failed=$($gate.failed)"
}

foreach ($capture in @(
    @{ enabled = $CaptureVoiceBefore; file = "VOICE_IN_BEFORE_DEBUG.json"; id = "voice-before-debug" },
    @{ enabled = $CaptureVoiceAfter; file = "VOICE_IN_AFTER_DEBUG.json"; id = "voice-after-debug" },
    @{ enabled = $CaptureVoiceOutBefore; file = "VOICE_OUT_BEFORE_DEBUG.json"; id = "voice-out-before-debug" },
    @{ enabled = $CaptureVoiceOutAfter; file = "VOICE_OUT_AFTER_DEBUG.json"; id = "voice-out-after-debug" },
    @{ enabled = $CaptureServoBefore; file = "SERVO_BEFORE_DEBUG.json"; id = "servo-before-debug" },
    @{ enabled = $CaptureServoAfter; file = "SERVO_AFTER_DEBUG.json"; id = "servo-after-debug" }
  )) {
  if ($capture.enabled) {
    $debug = Get-DebugSnapshot
    Write-JsonFile (Join-Path $EvidencePath $capture.file) $debug
    Add-Step $capture.id "pass" $capture.file
  }
}

$validation = $null
if ($Check) {
  $checkArgs = @("-EvidenceRoot", $EvidencePath, "-Json")
  if ($RequireReady) {
    $checkArgs += "-RequireReady"
  }
  $checkOutput = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $ValidationCheckScript @checkArgs
  $checkExit = $LASTEXITCODE
  if ($checkOutput) {
    $validation = $checkOutput | ConvertFrom-Json
  }
  Add-Step "validation-check" ($(if ($checkExit -eq 0) { "pass" } else { "fail" })) "status=$($validation.status)"
}

$failedSteps = @($steps | Where-Object { $_.status -eq "fail" })
$pendingSteps = @($steps | Where-Object { $_.status -eq "pending" })
$result = [ordered]@{
  schema = "stackchan.full-online-validation-collector.v1"
  status = $(if ($failedSteps.Count -gt 0) { "full-online-validation-collect-failed" } elseif ($pendingSteps.Count -gt 0) { "full-online-validation-collect-pending" } else { "full-online-validation-collect-ok" })
  evidenceRoot = $EvidencePath
  debugUrl = $DebugUrl
  validationStatus = $(if ($null -ne $validation) { $validation.status } else { $null })
  passed = @($steps | Where-Object { $_.status -eq "pass" }).Count
  failed = $failedSteps.Count
  pending = $pendingSteps.Count
  steps = $steps
}

Write-JsonFile (Join-Path $EvidencePath "FULL_ONLINE_VALIDATION_COLLECTOR.json") $result
Write-NextActionsMarkdown -Path (Join-Path $EvidencePath "FULL_ONLINE_NEXT_ACTIONS.md") -EvidencePath $EvidencePath -Validation $validation -CollectorResult $result

if ($Json) {
  $result | ConvertTo-Json -Depth 8
} else {
  Write-Host "Full-online validation collector: $($result.status)"
  foreach ($step in $steps) {
    Write-Host "[$($step.status)] $($step.id): $($step.detail)"
  }
}

if ($failedSteps.Count -gt 0) {
  exit 1
}
