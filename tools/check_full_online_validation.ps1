param(
  [string]$EvidenceRoot = "output\pc-brain\full-online-validation-latest",
  [switch]$WriteTemplate,
  [switch]$RequireReady,
  [switch]$Json
)

$ErrorActionPreference = "Stop"

$RepoRoot = Resolve-Path (Join-Path $PSScriptRoot "..")
Set-Location $RepoRoot

$checks = @()

function Add-Check {
  param(
    [string]$Id,
    [ValidateSet("pass", "fail", "pending")]
    [string]$Status,
    [string]$Detail
  )
  $script:checks += [ordered]@{
    id = $Id
    status = $Status
    detail = $Detail
  }
}

function Read-JsonIfPresent {
  param([string]$Path)
  if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
    return $null
  }
  return Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json
}

function Get-IntValue {
  param($Object, [string]$Name, [int]$DefaultValue = 0)
  if ($null -eq $Object) { return $DefaultValue }
  $property = $Object.PSObject.Properties[$Name]
  if ($null -eq $property -or $null -eq $property.Value) { return $DefaultValue }
  return [int]$property.Value
}

function Test-YesField {
  param([string]$Text, [string]$Label, [string]$Id)
  Add-Check $Id ($(if ($Text -match "(?m)^- $([regex]::Escape($Label)):\s*yes\s*$") { "pass" } else { "pending" })) $Label
}

function Test-NoField {
  param([string]$Text, [string]$Label, [string]$Id)
  Add-Check $Id ($(if ($Text -match "(?m)^- $([regex]::Escape($Label)):\s*no\s*$") { "pass" } else { "pending" })) $Label
}

function Write-ValidationMarkdown {
  param([string]$Path, $Result)
  $lines = @(
    "# Stackchan Full-Online Validation Check",
    "",
    "- Schema: ``$($Result.schema)``",
    "- Status: ``$($Result.status)``",
    "- Machine ready: ``$($Result.machineReady)``",
    "- Passed: ``$($Result.passed)``",
    "- Failed: ``$($Result.failed)``",
    "- Pending: ``$($Result.pending)``",
    "",
    "## Checks",
    ""
  )
  foreach ($check in $Result.checks) {
    $lines += "- ``$($check.status)`` ``$($check.id)``: $($check.detail)"
  }
  $lines | Set-Content -LiteralPath $Path -Encoding UTF8
}

New-Item -ItemType Directory -Force -Path $EvidenceRoot | Out-Null
$EvidencePath = (Resolve-Path $EvidenceRoot).Path

$reviewPath = Join-Path $EvidencePath "FULL_ONLINE_REVIEW.md"
if ($WriteTemplate -or -not (Test-Path -LiteralPath $reviewPath -PathType Leaf)) {
  @(
    "# Stackchan Full-Online Review",
    "",
    "- Full-online firmware flashed: pending",
    "- PC brain runtime check passed after flash: pending",
    "- Full-online live debug gate passed: pending",
    "- Robot mic voice-in produced uplink chunks: pending",
    "- STT transcript was produced from robot mic input: pending",
    "- Selected voice response returned through robot speaker: pending",
    '- Voice sounded like selected `stackchan-rvc-bright-robot`: pending',
    "- Servo motion was controlled and expected: pending",
    "- Motion stop or safe stop was verified: pending",
    "- Servo binding, runaway spin, tip, snag, or unsafe heat observed: pending",
    "- Audio clipping, choppiness, or dropout observed: pending",
    "",
    "## Notes",
    "",
    "- Operator:",
    "- Date/time:",
    "- Exact spoken prompt:",
    "- Observed transcript:",
    "- Servo motion observed:",
    "- Safe-stop command used:",
    ""
  ) | Set-Content -LiteralPath $reviewPath -Encoding UTF8
}

$preflightPath = Join-Path $EvidencePath "FULL_ONLINE_PREFLIGHT.json"
$runtimePath = Join-Path $EvidencePath "PC_BRAIN_RUNTIME_CHECK.json"
$liveCheckPath = Join-Path $EvidencePath "FULL_ONLINE_LIVE_CHECK.json"
$voiceBeforePath = Join-Path $EvidencePath "VOICE_IN_BEFORE_DEBUG.json"
$voiceAfterPath = Join-Path $EvidencePath "VOICE_IN_AFTER_DEBUG.json"
$voiceOutBeforePath = Join-Path $EvidencePath "VOICE_OUT_BEFORE_DEBUG.json"
$voiceOutAfterPath = Join-Path $EvidencePath "VOICE_OUT_AFTER_DEBUG.json"
$servoBeforePath = Join-Path $EvidencePath "SERVO_BEFORE_DEBUG.json"
$servoAfterPath = Join-Path $EvidencePath "SERVO_AFTER_DEBUG.json"
$serialLogPath = Join-Path $EvidencePath "full_online_serial.log"
$loggingPath = Join-Path $EvidencePath "FULL_ONLINE_VALIDATION_LOGGING.json"

$preflight = Read-JsonIfPresent $preflightPath
$runtime = Read-JsonIfPresent $runtimePath
$liveCheck = Read-JsonIfPresent $liveCheckPath
$voiceBefore = Read-JsonIfPresent $voiceBeforePath
$voiceAfter = Read-JsonIfPresent $voiceAfterPath
$voiceOutBefore = Read-JsonIfPresent $voiceOutBeforePath
$voiceOutAfter = Read-JsonIfPresent $voiceOutAfterPath
$servoBefore = Read-JsonIfPresent $servoBeforePath
$servoAfter = Read-JsonIfPresent $servoAfterPath
$logging = Read-JsonIfPresent $loggingPath

Add-Check "evidence-root" "pass" $EvidencePath
Add-Check "review-template" ($(if (Test-Path -LiteralPath $reviewPath -PathType Leaf) { "pass" } else { "fail" })) $reviewPath

if ($preflight) {
  Add-Check "preflight-schema" ($(if ($preflight.schema -eq "stackchan.full-online-preflight.v1") { "pass" } else { "fail" })) "schema=$($preflight.schema)"
  Add-Check "preflight-ready-to-flash" ($(if ($preflight.readyToFlash -eq $true -and [int]$preflight.failed -eq 0) { "pass" } else { "fail" })) "readyToFlash=$($preflight.readyToFlash) failed=$($preflight.failed)"
} else {
  Add-Check "preflight-json" "pending" "Copy FULL_ONLINE_PREFLIGHT.json from tools\run_full_online_preflight.cmd output."
}

if ($runtime) {
  Add-Check "runtime-schema" ($(if ($runtime.schema -eq "stackchan.pc-brain-runtime-check.v1") { "pass" } else { "fail" })) "schema=$($runtime.schema)"
  Add-Check "runtime-ready" ($(if ($runtime.machineReady -eq $true -and [int]$runtime.failed -eq 0) { "pass" } else { "fail" })) "machineReady=$($runtime.machineReady) failed=$($runtime.failed)"
  $runtimeChecks = @($runtime.checks)
  foreach ($id in @("stt-command", "tts-command", "tts-voice", "runner-command", "live-debug-ready")) {
    $check = @($runtimeChecks | Where-Object { $_.id -eq $id })[0]
    Add-Check "runtime-$id" ($(if ($null -ne $check -and $check.status -eq "pass") { "pass" } else { "fail" })) $id
  }
} else {
  Add-Check "runtime-json" "pending" "Run tools\check_pc_brain_runtime.cmd after flashing."
}

if ($liveCheck) {
  Add-Check "live-check-schema" ($(if ($liveCheck.schema -eq "stackchan.first-pc-brain-deploy-check.v1") { "pass" } else { "fail" })) "schema=$($liveCheck.schema)"
  $liveChecks = @($liveCheck.checks)
  foreach ($id in @(
      "full-online-servos-compiled",
      "full-online-speaker-compiled",
      "full-online-mic-compiled",
      "full-online-uplink-compiled",
      "full-online-motion-enabled",
      "full-online-audio-capture-enabled",
      "full-online-audio-capture-hw",
      "full-online-uplink-ready",
      "full-online-wake-gate-ready",
      "full-online-uplink-no-errors"
    )) {
    $check = @($liveChecks | Where-Object { $_.id -eq $id })[0]
    Add-Check "live-$id" ($(if ($null -ne $check -and $check.status -eq "pass") { "pass" } else { "fail" })) $id
  }
} else {
  Add-Check "live-check-json" "pending" "Run collect_full_online_validation_evidence.cmd -CaptureLiveGate after flashing."
}

if ($voiceBefore -and $voiceAfter) {
  $uplinkBytesDelta = (Get-IntValue $voiceAfter "bridge_uplink_bytes" 0) - (Get-IntValue $voiceBefore "bridge_uplink_bytes" 0)
  $uplinkChunksDelta = (Get-IntValue $voiceAfter "bridge_uplink_chunks" 0) - (Get-IntValue $voiceBefore "bridge_uplink_chunks" 0)
  $uplinkTurnsDelta = (Get-IntValue $voiceAfter "bridge_uplink_turns" 0) - (Get-IntValue $voiceBefore "bridge_uplink_turns" 0)
  $uplinkCompletedDelta = (Get-IntValue $voiceAfter "bridge_uplink_completed" 0) - (Get-IntValue $voiceBefore "bridge_uplink_completed" 0)
  $audioWindowsDelta = (Get-IntValue $voiceAfter "audio_capture_windows" 0) - (Get-IntValue $voiceBefore "audio_capture_windows" 0)
  $audioEventsDelta = (Get-IntValue $voiceAfter "audio_capture_events" 0) - (Get-IntValue $voiceBefore "audio_capture_events" 0)
  $downlinkDelta = (Get-IntValue $voiceAfter "bridge_downlink_playback_starts" 0) - (Get-IntValue $voiceBefore "bridge_downlink_playback_starts" 0)
  Add-Check "voice-uplink-turn" ($(if ($uplinkTurnsDelta -gt 0 -and $uplinkCompletedDelta -gt 0) { "pass" } else { "fail" })) "turns_delta=$uplinkTurnsDelta completed_delta=$uplinkCompletedDelta"
  Add-Check "voice-uplink-bytes" ($(if ($uplinkBytesDelta -gt 0 -and $uplinkChunksDelta -gt 0) { "pass" } else { "fail" })) "bytes_delta=$uplinkBytesDelta chunks_delta=$uplinkChunksDelta"
  Add-Check "voice-mic-capture" ($(if ($audioWindowsDelta -gt 0 -or $audioEventsDelta -gt 0) { "pass" } else { "fail" })) "windows_delta=$audioWindowsDelta events_delta=$audioEventsDelta"
  Add-Check "voice-selected-response-downlink" ($(if ($downlinkDelta -gt 0) { "pass" } else { "fail" })) "playback_starts_delta=$downlinkDelta"
  Add-Check "voice-uplink-no-errors" ($(if ((Get-IntValue $voiceAfter "bridge_uplink_errors" 0) -eq 0 -and (Get-IntValue $voiceAfter "bridge_uplink_queue_failures" 0) -eq 0) { "pass" } else { "fail" })) "errors=$($voiceAfter.bridge_uplink_errors) queue_failures=$($voiceAfter.bridge_uplink_queue_failures)"
} else {
  Add-Check "voice-debug-before-after" "pending" "Capture VOICE_IN_BEFORE_DEBUG.json and VOICE_IN_AFTER_DEBUG.json around a real robot mic turn."
}

if ($voiceOutBefore -and $voiceOutAfter) {
  $streamDelta = (Get-IntValue $voiceOutAfter "audio_streams_started" 0) - (Get-IntValue $voiceOutBefore "audio_streams_started" 0)
  $streamEndDelta = (Get-IntValue $voiceOutAfter "audio_streams_ended" 0) - (Get-IntValue $voiceOutBefore "audio_streams_ended" 0)
  $playbackDelta = (Get-IntValue $voiceOutAfter "bridge_downlink_playback_starts" 0) - (Get-IntValue $voiceOutBefore "bridge_downlink_playback_starts" 0)
  $playbackChunksDelta = (Get-IntValue $voiceOutAfter "bridge_downlink_playback_chunks" 0) - (Get-IntValue $voiceOutBefore "bridge_downlink_playback_chunks" 0)
  $playbackBytesDelta = (Get-IntValue $voiceOutAfter "bridge_downlink_playback_bytes" 0) - (Get-IntValue $voiceOutBefore "bridge_downlink_playback_bytes" 0)
  $speakerChunksDelta = (Get-IntValue $voiceOutAfter "speaker_stream_task_chunks" 0) - (Get-IntValue $voiceOutBefore "speaker_stream_task_chunks" 0)
  $speakerBytesDelta = (Get-IntValue $voiceOutAfter "speaker_stream_task_bytes" 0) - (Get-IntValue $voiceOutBefore "speaker_stream_task_bytes" 0)
  $speakerOkDelta = (Get-IntValue $voiceOutAfter "speaker_stream_play_raw_ok" 0) - (Get-IntValue $voiceOutBefore "speaker_stream_play_raw_ok" 0)
  $micSuspendDelta = (Get-IntValue $voiceOutAfter "speaker_mic_suspends" 0) - (Get-IntValue $voiceOutBefore "speaker_mic_suspends" 0)
  $micResumeDelta = (Get-IntValue $voiceOutAfter "speaker_mic_resume_ok" 0) - (Get-IntValue $voiceOutBefore "speaker_mic_resume_ok" 0)
  $expectedChunks = Get-IntValue $voiceOutAfter "audio_stream_chunks_expected" 0
  $expectedBytes = Get-IntValue $voiceOutAfter "audio_stream_bytes_expected" 0
  Add-Check "voice-out-stream-completed" ($(if ($streamDelta -gt 0 -and $streamEndDelta -gt 0 -and (Get-IntValue $voiceOutAfter "audio_stream_errors" 0) -eq 0) { "pass" } else { "fail" })) "streams_delta=$streamDelta ended_delta=$streamEndDelta audio_errors=$($voiceOutAfter.audio_stream_errors)"
  Add-Check "voice-out-playback-bytes-match" ($(if ($playbackDelta -gt 0 -and $playbackChunksDelta -eq $expectedChunks -and $playbackBytesDelta -eq $expectedBytes -and $playbackBytesDelta -gt 0) { "pass" } else { "fail" })) "starts_delta=$playbackDelta chunks_delta=$playbackChunksDelta expected_chunks=$expectedChunks bytes_delta=$playbackBytesDelta expected_bytes=$expectedBytes"
  Add-Check "voice-out-speaker-accepted-pcm" ($(if ($speakerChunksDelta -eq $expectedChunks -and $speakerBytesDelta -eq $expectedBytes -and $speakerOkDelta -eq $expectedChunks -and $speakerBytesDelta -gt 0) { "pass" } else { "fail" })) "speaker_chunks_delta=$speakerChunksDelta speaker_bytes_delta=$speakerBytesDelta play_raw_ok_delta=$speakerOkDelta"
  Add-Check "voice-out-speaker-clean" ($(if ((Get-IntValue $voiceOutAfter "bridge_downlink_playback_errors" 0) -eq 0 -and (Get-IntValue $voiceOutAfter "speaker_stream_play_raw_failed" 0) -eq 0 -and (Get-IntValue $voiceOutAfter "speaker_stream_queue_drops" 0) -eq 0 -and (Get-IntValue $voiceOutAfter "speaker_channel_state" 1) -eq 0 -and -not [bool]$voiceOutAfter.audio_stream_active) { "pass" } else { "fail" })) "playback_errors=$($voiceOutAfter.bridge_downlink_playback_errors) raw_failed=$($voiceOutAfter.speaker_stream_play_raw_failed) queue_drops=$($voiceOutAfter.speaker_stream_queue_drops) channel_state=$($voiceOutAfter.speaker_channel_state) active=$($voiceOutAfter.audio_stream_active)"
  Add-Check "voice-out-mic-resumed" ($(if ($micSuspendDelta -gt 0 -and $micResumeDelta -ge $micSuspendDelta -and [bool]$voiceOutAfter.audio_capture_hw_ready) { "pass" } else { "fail" })) "mic_suspends_delta=$micSuspendDelta mic_resume_ok_delta=$micResumeDelta audio_capture_hw_ready=$($voiceOutAfter.audio_capture_hw_ready)"
} else {
  Add-Check "voice-out-debug-before-after" "pending" "Capture VOICE_OUT_BEFORE_DEBUG.json and VOICE_OUT_AFTER_DEBUG.json around a robot-routed selected-voice text turn."
}

if ($servoBefore -and $servoAfter) {
  Add-Check "servo-debug-full-online" ($(if ((Get-IntValue $servoAfter "compiled_enable_servos" 0) -eq 1 -and [bool]$servoAfter.motion_enabled) { "pass" } else { "fail" })) "compiled_enable_servos=$($servoAfter.compiled_enable_servos) motion_enabled=$($servoAfter.motion_enabled)"
} else {
  Add-Check "servo-debug-before-after" "pending" "Capture SERVO_BEFORE_DEBUG.json and SERVO_AFTER_DEBUG.json around supervised servo/safe-stop validation."
}

if (Test-Path -LiteralPath $serialLogPath -PathType Leaf) {
  $serialLog = Get-Content -LiteralPath $serialLogPath -Raw
  Add-Check "serial-runtime-full-online" ($(if ($serialLog -match "audio_capture_enabled=1" -and $serialLog -match "bridge_uplink_enabled=1") { "pass" } else { "fail" })) "serial includes mic/uplink enabled runtime markers"
  Add-Check "serial-safe-stop" ($(if ($serialLog -match "\[motion\]\s+enabled=0" -or $serialLog -match "command=motion_stop" -or $serialLog -match "safe_stop") { "pass" } else { "pending" })) "serial includes motion stop/safe stop marker"
} else {
  Add-Check "serial-log" "pending" "Capture full_online_serial.log during physical validation."
}

if ($logging) {
  Add-Check "logging-schema" ($(if ($logging.schema -eq "stackchan.full-online-validation-logging.v1") { "pass" } else { "fail" })) "schema=$($logging.schema)"
  Add-Check "logging-debug-polls" ($(if ((Get-IntValue $logging "debugPolls" 0) -gt 0 -and (Get-IntValue $logging "debugFailures" 1) -eq 0) { "pass" } else { "fail" })) "debugPolls=$($logging.debugPolls) debugFailures=$($logging.debugFailures)"
  $serialBytesFromLog = 0
  if (Test-Path -LiteralPath $serialLogPath -PathType Leaf) {
    $serialBytesFromLog = [int](Get-Item -LiteralPath $serialLogPath).Length
  }
  $loggingSerialIncluded = ([bool]$logging.serialIncluded -and (Get-IntValue $logging "serialBytes" 0) -gt 0)
  $preservedSerialIncluded = ($serialBytesFromLog -gt 0)
  Add-Check "logging-serial-included" ($(if ($loggingSerialIncluded -or $preservedSerialIncluded) { "pass" } else { "fail" })) "serialIncluded=$($logging.serialIncluded) serialBytes=$($logging.serialBytes) preservedSerialBytes=$serialBytesFromLog"
} else {
  Add-Check "logging-json" "pending" "Run tools\start_full_online_validation_logging.cmd during physical validation."
}

$review = Get-Content -LiteralPath $reviewPath -Raw
Test-YesField $review "Full-online firmware flashed" "review-flashed"
Test-YesField $review "PC brain runtime check passed after flash" "review-runtime"
Test-YesField $review "Full-online live debug gate passed" "review-live-gate"
Test-YesField $review "Robot mic voice-in produced uplink chunks" "review-mic-uplink"
Test-YesField $review "STT transcript was produced from robot mic input" "review-stt"
Test-YesField $review "Selected voice response returned through robot speaker" "review-selected-voice"
Test-YesField $review 'Voice sounded like selected `stackchan-rvc-bright-robot`' "review-voice-match"
Test-YesField $review "Servo motion was controlled and expected" "review-servo-controlled"
Test-YesField $review "Motion stop or safe stop was verified" "review-safe-stop"
Test-NoField $review "Servo binding, runaway spin, tip, snag, or unsafe heat observed" "review-no-servo-risk"
Test-NoField $review "Audio clipping, choppiness, or dropout observed" "review-no-audio-risk"

$failed = @($checks | Where-Object { $_.status -eq "fail" })
$pending = @($checks | Where-Object { $_.status -eq "pending" })
$machineFailures = @($failed | Where-Object { $_.id -notmatch "^review-|^serial-safe-stop$|^servo-debug-before-after$" })
$status = if ($failed.Count -gt 0) {
  "full-online-validation-not-ready"
} elseif ($pending.Count -gt 0) {
  "full-online-validation-pending-evidence"
} else {
  "full-online-validation-ready"
}

$result = [ordered]@{
  schema = "stackchan.full-online-validation-check.v1"
  status = $status
  evidenceRoot = $EvidencePath
  machineReady = ($machineFailures.Count -eq 0)
  passed = @($checks | Where-Object { $_.status -eq "pass" }).Count
  failed = $failed.Count
  pending = $pending.Count
  checks = $checks
}

$jsonPath = Join-Path $EvidencePath "FULL_ONLINE_VALIDATION_CHECK.json"
$markdownPath = Join-Path $EvidencePath "FULL_ONLINE_VALIDATION_CHECK.md"
$result | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $jsonPath -Encoding UTF8
Write-ValidationMarkdown -Path $markdownPath -Result $result

if ($Json) {
  $result | ConvertTo-Json -Depth 8
} else {
  Write-Host "Full-online validation: $status"
  foreach ($check in $checks) {
    Write-Host "[$($check.status)] $($check.id): $($check.detail)"
  }
}

if ($RequireReady -and $status -ne "full-online-validation-ready") {
  exit 1
}
if ($failed.Count -gt 0) {
  exit 1
}
