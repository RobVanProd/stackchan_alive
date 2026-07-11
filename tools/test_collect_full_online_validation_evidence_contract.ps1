$ErrorActionPreference = "Stop"

$RepoRoot = Resolve-Path (Join-Path $PSScriptRoot "..")
Set-Location $RepoRoot

function Write-Json {
  param([string]$Path, $Object)
  $Object | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $Path -Encoding UTF8
}

$tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("stackchan-full-online-collector-" + [guid]::NewGuid().ToString("N"))
$debugPath = Join-Path $tempRoot "debug.json"
$preflightPath = Join-Path $tempRoot "FULL_ONLINE_PREFLIGHT.json"

try {
  New-Item -ItemType Directory -Force -Path $tempRoot | Out-Null
  Write-Json $preflightPath ([ordered]@{
      schema = "stackchan.full-online-preflight.v1"
      readyToFlash = $true
      failed = 0
    })
  Write-Json $debugPath ([ordered]@{
      schema = "stackchan.bridge-debug.v1"
      network_state = "connected"
      bridge_state = "ready"
      network_error = ""
      compiled_enable_servos = 1
      compiled_enable_speaker = 1
      compiled_enable_mic_capture = 1
      compiled_enable_bridge_audio_uplink = 1
      motion_enabled = $true
      audio_capture_enabled = $true
      audio_capture_hw_ready = $true
      bridge_uplink_ready = $true
      bridge_uplink_enabled = $true
      bridge_wake_gate_ready = $true
      bridge_uplink_errors = 0
      bridge_uplink_queue_failures = 0
      bridge_uplink_bytes = 100
      bridge_uplink_chunks = 2
      bridge_uplink_turns = 1
      bridge_uplink_completed = 1
      audio_capture_windows = 4
      audio_capture_events = 2
      bridge_downlink_playback_starts = 3
      audio_streams_started = 2
      audio_streams_ended = 2
      audio_stream_errors = 0
      audio_stream_chunks_expected = 16
      audio_stream_bytes_expected = 65536
      audio_stream_active = $false
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
    })

  $collectorScript = Join-Path $RepoRoot "tools\collect_full_online_validation_evidence.ps1"
  $collectorOutput = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $collectorScript `
    -EvidenceRoot $tempRoot `
    -DebugJsonPath $debugPath `
    -PreflightPath $preflightPath `
    -Prepare `
    -CaptureLiveGate `
    -CaptureVoiceBefore `
    -CaptureVoiceOutBefore `
    -CaptureServoBefore `
    -Check `
    -Json
  if (-not $?) {
    throw "Collector failed: $collectorOutput"
  }
  $collector = $collectorOutput | ConvertFrom-Json
  if ($collector.status -ne "full-online-validation-collect-ok") {
    throw "Expected collector ok, got $($collector.status)."
  }
  foreach ($file in @("FULL_ONLINE_PREFLIGHT.json", "FULL_ONLINE_REVIEW.md", "FULL_ONLINE_LIVE_CHECK.json", "VOICE_IN_BEFORE_DEBUG.json", "VOICE_OUT_BEFORE_DEBUG.json", "SERVO_BEFORE_DEBUG.json", "FULL_ONLINE_VALIDATION_COLLECTOR.json", "FULL_ONLINE_NEXT_ACTIONS.md")) {
    if (-not (Test-Path -LiteralPath (Join-Path $tempRoot $file) -PathType Leaf)) {
      throw "Expected collector file $file."
    }
  }

  $liveGate = Get-Content -LiteralPath (Join-Path $tempRoot "FULL_ONLINE_LIVE_CHECK.json") -Raw | ConvertFrom-Json
  if ($liveGate.schema -ne "stackchan.first-pc-brain-deploy-check.v1") {
    throw "Unexpected live gate schema $($liveGate.schema)."
  }
  foreach ($id in @("full-online-servos-compiled", "full-online-mic-compiled", "full-online-uplink-ready", "full-online-uplink-no-errors")) {
    $check = @($liveGate.checks | Where-Object { $_.id -eq $id })[0]
    if ($null -eq $check -or $check.status -ne "pass") {
      throw "Expected $id to pass."
    }
  }

  $nextActions = Get-Content -LiteralPath (Join-Path $tempRoot "FULL_ONLINE_NEXT_ACTIONS.md") -Raw
  foreach ($snippet in @("Validation status", "resume_full_online_physical_validation_when_ready.cmd", "Suggested robot-mic prompt", "hello stackchan", "start_full_online_physical_validation_session.cmd", "-SuggestedVoicePrompt", "send_stackchan_serial_command.cmd", "start_full_online_validation_logging.cmd", "turns.jsonl", "CaptureVoiceAfter", "CaptureVoiceOutAfter", "CaptureServoAfter", "full_online_serial.log", "RequireReady")) {
    if ($nextActions -notmatch [regex]::Escape($snippet)) {
      throw "Expected FULL_ONLINE_NEXT_ACTIONS.md to mention $snippet."
    }
  }

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
  Write-Json $debugPath ([ordered]@{
      schema = "stackchan.bridge-debug.v1"
      network_state = "connected"
      bridge_state = "ready"
      network_error = ""
      compiled_enable_servos = 1
      compiled_enable_speaker = 1
      compiled_enable_mic_capture = 1
      compiled_enable_bridge_audio_uplink = 1
      motion_enabled = $true
      audio_capture_enabled = $true
      audio_capture_hw_ready = $true
      bridge_uplink_ready = $true
      bridge_uplink_enabled = $true
      bridge_wake_gate_ready = $true
      bridge_uplink_errors = 0
      bridge_uplink_queue_failures = 0
      bridge_uplink_bytes = 9000
      bridge_uplink_chunks = 8
      bridge_uplink_turns = 2
      bridge_uplink_completed = 2
      audio_capture_windows = 9
      audio_capture_events = 4
      bridge_downlink_playback_starts = 4
      audio_streams_started = 3
      audio_streams_ended = 3
      audio_stream_errors = 0
      audio_stream_chunks_expected = 16
      audio_stream_bytes_expected = 65536
      audio_stream_active = $false
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
    })
  $collectorAfterOutput = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $collectorScript `
    -EvidenceRoot $tempRoot `
    -DebugJsonPath $debugPath `
    -PreflightPath $preflightPath `
    -CaptureVoiceAfter `
    -CaptureVoiceOutAfter `
    -CaptureServoAfter `
    -Check `
    -Json
  if (-not $?) {
    throw "Collector after-capture failed: $collectorAfterOutput"
  }

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

  $readyOutput = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $collectorScript `
    -EvidenceRoot $tempRoot `
    -DebugJsonPath $debugPath `
    -PreflightPath $preflightPath `
    -Check `
    -RequireReady `
    -Json
  if (-not $?) {
    throw "Collector ready check failed: $readyOutput"
  }
  $readyCollector = $readyOutput | ConvertFrom-Json
  if ($readyCollector.validationStatus -ne "full-online-validation-ready") {
    throw "Expected collector validation ready, got $($readyCollector.validationStatus)."
  }
  $readyCheck = Get-Content -LiteralPath (Join-Path $tempRoot "FULL_ONLINE_VALIDATION_CHECK.json") -Raw | ConvertFrom-Json
  if ($readyCheck.status -ne "full-online-validation-ready") {
    throw "Expected strict validation ready, got $($readyCheck.status)."
  }
  $readyActions = Get-Content -LiteralPath (Join-Path $tempRoot "FULL_ONLINE_NEXT_ACTIONS.md") -Raw
  if ($readyActions -notmatch "Full-online validation is ready") {
    throw "Expected ready next-actions handoff."
  }
} finally {
  Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Host "Full-online validation collector contract tests passed."
