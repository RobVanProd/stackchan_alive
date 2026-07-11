$ErrorActionPreference = "Stop"

$RepoRoot = Resolve-Path (Join-Path $PSScriptRoot "..")
Set-Location $RepoRoot

function Write-Json {
  param([string]$Path, $Object)
  $Object | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $Path -Encoding UTF8
}

function Invoke-Check {
  param([string]$Root)
  $output = & "tools\check_full_online_validation.ps1" -EvidenceRoot $Root -Json
  return [pscustomobject]@{
    exitCode = $(if ($?) { 0 } else { 1 })
    json = ($output | ConvertFrom-Json)
    output = $output
  }
}

$tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("stackchan-full-online-validation-" + [guid]::NewGuid().ToString("N"))
New-Item -ItemType Directory -Force -Path $tempRoot | Out-Null

try {
  $initial = Invoke-Check -Root $tempRoot
  if ($initial.exitCode -ne 0) {
    throw "Template-only validation should not fail hard."
  }
  if (-not (Test-Path -LiteralPath (Join-Path $tempRoot "FULL_ONLINE_REVIEW.md") -PathType Leaf)) {
    throw "Expected FULL_ONLINE_REVIEW.md template."
  }
  if ($initial.json.status -ne "full-online-validation-pending-evidence") {
    throw "Expected template-only status pending, got $($initial.json.status)."
  }

  Write-Json (Join-Path $tempRoot "FULL_ONLINE_PREFLIGHT.json") ([ordered]@{
      schema = "stackchan.full-online-preflight.v1"
      readyToFlash = $true
      failed = 0
    })
  Write-Json (Join-Path $tempRoot "PC_BRAIN_RUNTIME_CHECK.json") ([ordered]@{
      schema = "stackchan.pc-brain-runtime-check.v1"
      machineReady = $true
      failed = 0
      checks = @(
        @{ id = "stt-command"; status = "pass" },
        @{ id = "tts-command"; status = "pass" },
        @{ id = "tts-voice"; status = "pass" },
        @{ id = "runner-command"; status = "pass" },
        @{ id = "live-debug-ready"; status = "pass" }
      )
    })
  $fullOnlineChecks = @(
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
  ) | ForEach-Object { @{ id = $_; status = "pass" } }
  Write-Json (Join-Path $tempRoot "FULL_ONLINE_LIVE_CHECK.json") ([ordered]@{
      schema = "stackchan.first-pc-brain-deploy-check.v1"
      checks = @($fullOnlineChecks)
    })
  Write-Json (Join-Path $tempRoot "VOICE_IN_BEFORE_DEBUG.json") ([ordered]@{
      bridge_uplink_bytes = 100
      bridge_uplink_chunks = 2
      bridge_uplink_turns = 1
      bridge_uplink_completed = 1
      audio_capture_windows = 4
      audio_capture_events = 2
      bridge_downlink_playback_starts = 3
      bridge_uplink_errors = 0
      bridge_uplink_queue_failures = 0
    })
  Write-Json (Join-Path $tempRoot "VOICE_IN_AFTER_DEBUG.json") ([ordered]@{
      bridge_uplink_bytes = 9000
      bridge_uplink_chunks = 8
      bridge_uplink_turns = 2
      bridge_uplink_completed = 2
      audio_capture_windows = 9
      audio_capture_events = 4
      bridge_downlink_playback_starts = 4
      bridge_uplink_errors = 0
      bridge_uplink_queue_failures = 0
    })
  Write-Json (Join-Path $tempRoot "VOICE_OUT_BEFORE_DEBUG.json") ([ordered]@{
      audio_streams_started = 2
      audio_streams_ended = 2
      audio_stream_errors = 0
      audio_stream_chunks_expected = 16
      audio_stream_bytes_expected = 65536
      audio_stream_active = $false
      bridge_downlink_playback_starts = 3
      bridge_downlink_playback_chunks = 48
      bridge_downlink_playback_bytes = 196608
      bridge_downlink_playback_errors = 0
      speaker_stream_task_chunks = 48
      speaker_stream_task_bytes = 196608
      speaker_stream_play_raw_ok = 48
      speaker_stream_play_raw_failed = 0
      speaker_stream_queue_drops = 0
      speaker_channel_state = 0
      speaker_mic_suspends = 3
      speaker_mic_resume_ok = 3
      audio_capture_hw_ready = $true
    })
  Write-Json (Join-Path $tempRoot "VOICE_OUT_AFTER_DEBUG.json") ([ordered]@{
      audio_streams_started = 3
      audio_streams_ended = 3
      audio_stream_errors = 0
      audio_stream_chunks_expected = 16
      audio_stream_bytes_expected = 65536
      audio_stream_active = $false
      bridge_downlink_playback_starts = 4
      bridge_downlink_playback_chunks = 64
      bridge_downlink_playback_bytes = 262144
      bridge_downlink_playback_errors = 0
      speaker_stream_task_chunks = 64
      speaker_stream_task_bytes = 262144
      speaker_stream_play_raw_ok = 64
      speaker_stream_play_raw_failed = 0
      speaker_stream_queue_drops = 0
      speaker_channel_state = 0
      speaker_mic_suspends = 4
      speaker_mic_resume_ok = 4
      audio_capture_hw_ready = $true
    })
  Write-Json (Join-Path $tempRoot "SERVO_BEFORE_DEBUG.json") ([ordered]@{
      compiled_enable_servos = 1
      motion_enabled = $true
    })
  Write-Json (Join-Path $tempRoot "SERVO_AFTER_DEBUG.json") ([ordered]@{
      compiled_enable_servos = 1
      motion_enabled = $true
    })
  "[runtime] audio_capture_enabled=1 bridge_uplink_enabled=1`n[motion] enabled=0 reason=safe_stop" |
    Set-Content -LiteralPath (Join-Path $tempRoot "full_online_serial.log") -Encoding UTF8
  Write-Json (Join-Path $tempRoot "FULL_ONLINE_VALIDATION_LOGGING.json") ([ordered]@{
      schema = "stackchan.full-online-validation-logging.v1"
      status = "full-online-validation-logging-complete"
      debugPolls = 5
      debugFailures = 0
      serialIncluded = $true
      serialBytes = 128
    })
  @(
    "# Stackchan Full-Online Review",
    "",
    "- Full-online firmware flashed: yes",
    "- PC brain runtime check passed after flash: yes",
    "- Full-online live debug gate passed: yes",
    "- Robot mic voice-in produced uplink chunks: yes",
    "- STT transcript was produced from robot mic input: yes",
    "- Selected voice response returned through robot speaker: yes",
    '- Voice sounded like selected `stackchan-rvc-bright-robot`: yes',
    "- Servo motion was controlled and expected: yes",
    "- Motion stop or safe stop was verified: yes",
    "- Servo binding, runaway spin, tip, snag, or unsafe heat observed: no",
    "- Audio clipping, choppiness, or dropout observed: no"
  ) | Set-Content -LiteralPath (Join-Path $tempRoot "FULL_ONLINE_REVIEW.md") -Encoding UTF8

  $ready = Invoke-Check -Root $tempRoot
  if ($ready.exitCode -ne 0) {
    throw "Complete synthetic validation failed: $($ready.output)"
  }
  if ($ready.json.status -ne "full-online-validation-ready") {
    throw "Expected ready status, got $($ready.json.status)."
  }
  foreach ($id in @("voice-uplink-bytes", "voice-selected-response-downlink", "voice-out-stream-completed", "voice-out-playback-bytes-match", "voice-out-speaker-accepted-pcm", "voice-out-speaker-clean", "voice-out-mic-resumed", "review-safe-stop", "serial-safe-stop", "logging-debug-polls", "logging-serial-included")) {
    $check = @($ready.json.checks | Where-Object { $_.id -eq $id })[0]
    if ($null -eq $check -or $check.status -ne "pass") {
      throw "Expected $id to pass."
    }
  }

  Write-Json (Join-Path $tempRoot "FULL_ONLINE_VALIDATION_LOGGING.json") ([ordered]@{
      schema = "stackchan.full-online-validation-logging.v1"
      status = "full-online-validation-logging-partial"
      debugPolls = 7
      debugFailures = 0
      serialIncluded = $false
      serialBytes = 0
    })
  $preservedSerial = Invoke-Check -Root $tempRoot
  if ($preservedSerial.exitCode -ne 0) {
    throw "Expected preserved serial log to satisfy serial evidence when latest logging summary is debug-only: $($preservedSerial.output)"
  }
  $preservedSerialCheck = @($preservedSerial.json.checks | Where-Object { $_.id -eq "logging-serial-included" })[0]
  if ($null -eq $preservedSerialCheck -or $preservedSerialCheck.status -ne "pass" -or $preservedSerialCheck.detail -notmatch "preservedSerialBytes=") {
    throw "Expected preserved serial log fallback to pass logging-serial-included."
  }
} finally {
  Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Host "Full-online validation contract tests passed."
