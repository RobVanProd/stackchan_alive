$ErrorActionPreference = "Stop"

$RepoRoot = Resolve-Path (Join-Path $PSScriptRoot "..")
Set-Location $RepoRoot

function Write-Json {
  param([string]$Path, $Object)
  $Object | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $Path -Encoding UTF8
}

$tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("stackchan-full-online-review-" + [guid]::NewGuid().ToString("N"))
New-Item -ItemType Directory -Force -Path $tempRoot | Out-Null

try {
  $reviewScript = Join-Path $RepoRoot "tools\complete_full_online_review.ps1"
  $checkScript = Join-Path $RepoRoot "tools\check_full_online_validation.ps1"

  $previousErrorActionPreference = $ErrorActionPreference
  $ErrorActionPreference = "Continue"
  $missingTranscriptOutput = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $reviewScript `
    -EvidenceRoot $tempRoot `
    -ConfirmStt `
    -ExactSpokenPrompt "hello stackchan" `
    -Json 2>&1
  $missingTranscriptExit = $LASTEXITCODE
  $ErrorActionPreference = $previousErrorActionPreference
  if ($missingTranscriptExit -eq 0) {
    throw "Expected missing ObservedTranscript to fail."
  }
  if (($missingTranscriptOutput -join "`n") -notmatch "ObservedTranscript is required") {
    throw "Expected missing transcript error, got $missingTranscriptOutput"
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
  $liveChecks = @(
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
      checks = @($liveChecks)
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

  $null = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $checkScript -EvidenceRoot $tempRoot -WriteTemplate -Json
  $reviewPath = Join-Path $tempRoot "FULL_ONLINE_REVIEW.md"
  $reviewText = Get-Content -LiteralPath $reviewPath -Raw
  $reviewText = $reviewText -replace "(?m)^- Full-online firmware flashed:\s*.*$", "- Full-online firmware flashed: yes"
  $reviewText = $reviewText -replace "(?m)^- PC brain runtime check passed after flash:\s*.*$", "- PC brain runtime check passed after flash: yes"
  $reviewText = $reviewText -replace "(?m)^- Full-online live debug gate passed:\s*.*$", "- Full-online live debug gate passed: yes"
  $reviewText | Set-Content -LiteralPath $reviewPath -Encoding UTF8

  $completeOutput = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $reviewScript `
    -EvidenceRoot $tempRoot `
    -Operator "Contract Test" `
    -ExactSpokenPrompt "hello stackchan" `
    -ObservedTranscript "hello stackchan" `
    -ServoMotionObserved "small controlled yaw and pitch response, then stopped" `
    -SafeStopCommand "motion stop" `
    -ConfirmMicUplink `
    -ConfirmStt `
    -ConfirmSelectedVoice `
    -ConfirmVoiceMatch `
    -ConfirmServoControlled `
    -ConfirmSafeStop `
    -ConfirmNoServoRisk `
    -ConfirmNoAudioRisk `
    -Check `
    -Json
  if (-not $?) {
    throw "Review completion failed: $completeOutput"
  }
  $complete = $completeOutput | ConvertFrom-Json
  if ($complete.validationStatus -ne "full-online-validation-ready") {
    throw "Expected validation ready after review completion, got $($complete.validationStatus)."
  }

  $reviewText = Get-Content -LiteralPath (Join-Path $tempRoot "FULL_ONLINE_REVIEW.md") -Raw
  foreach ($snippet in @(
      "- Robot mic voice-in produced uplink chunks: yes",
      "- STT transcript was produced from robot mic input: yes",
      "- Selected voice response returned through robot speaker: yes",
      '- Voice sounded like selected `stackchan-rvc-bright-robot`: yes',
      "- Servo motion was controlled and expected: yes",
      "- Servo binding, runaway spin, tip, snag, or unsafe heat observed: no",
      "- Audio clipping, choppiness, or dropout observed: no",
      "- Operator: Contract Test",
      "- Exact spoken prompt: hello stackchan",
      "- Observed transcript: hello stackchan"
    )) {
    if ($reviewText -notmatch [regex]::Escape($snippet)) {
      throw "Review missing snippet: $snippet"
    }
  }
} finally {
  Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Host "Full-online review completion contract tests passed."
