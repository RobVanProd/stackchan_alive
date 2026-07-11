$ErrorActionPreference = "Stop"

$RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
Set-Location $RepoRoot

function Write-Json {
  param([string]$Path, $Value)
  $Value | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $Path -Encoding UTF8
}

function Invoke-EvidenceCheck {
  param([string]$EvidenceRoot, [switch]$RequireReady)
  $require = if ($RequireReady) { " -RequireReady" } else { "" }
  $script = @"
Set-Location '$RepoRoot'
& 'tools\check_voice_v2_supervised_evidence.ps1' -EvidenceRoot '$EvidenceRoot' -ConfirmHeardCleanAudio -ConfirmHeardCompleteReply$require -Json
"@
  $encoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($script))
  $output = & powershell.exe -NoProfile -ExecutionPolicy Bypass -EncodedCommand $encoded
  return [pscustomobject]@{
    exitCode = $LASTEXITCODE
    json = ($output | ConvertFrom-Json)
  }
}

$tempRoot = Join-Path ([IO.Path]::GetTempPath()) ("stackchan-voice-v2-" + [guid]::NewGuid().ToString("N"))
New-Item -ItemType Directory -Force -Path $tempRoot | Out-Null

try {
  $before = [ordered]@{
    network_state = "connected"
    bridge_state = "ready"
    motion_enabled = $false
    servo_rail_enabled = $false
    servo_torque_enabled = $false
    display_window_max_frame_us = 31000
    display_window_fps = 20.0
    power_vbus_mv = 5019
    chip_temp_c = 56.5
    speaker_stream_chunked = 1
    speaker_channel_state = 0
    audio_stream_active = $false
    bridge_downlink_playback_starts = 10
    bridge_downlink_playback_chunks = 100
    bridge_downlink_playback_bytes = 400000
    bridge_downlink_playback_errors = 0
    speaker_stream_play_raw_ok = 100
    speaker_stream_play_raw_failed = 0
    speaker_stream_forced_stops = 0
    bridge_uplink_turns = 3
    bridge_uplink_bytes = 460800
  }
  $after = [ordered]@{}
  foreach ($property in $before.GetEnumerator()) { $after[$property.Key] = $property.Value }
  $after.bridge_downlink_playback_starts = 11
  $after.bridge_downlink_playback_chunks = 143
  $after.bridge_downlink_playback_bytes = 572800
  $after.speaker_stream_play_raw_ok = 143
  $after.bridge_uplink_turns = 4
  $after.bridge_uplink_bytes = 614400
  $after.speaker_stream_first_chunk_delay_ms = 18
  $after.speaker_stream_queued_audio_ms = 5400

  Write-Json (Join-Path $tempRoot "before-debug.json") $before
  Write-Json (Join-Path $tempRoot "after-debug.json") $after
  Write-Json (Join-Path $tempRoot "session.json") ([ordered]@{
      mode = "voice-v2-directml-supervised"
    })
  ([ordered]@{
      tts_streaming = $true
      tts_voice = "stackchan-rvc-directml-v2"
      tts_first_audio_ms = 1215.4
      tts_first_audio_after_text_ms = 915.4
      tts_phrases = 3
      tts_phrases_completed = 3
      tts_stream_complete = $true
      tts_audio_truncated = $false
      tts_error = ""
      tts_audio_payload_bytes = 172800
      transcript = "Hey Stackchan, give me a two sentence status update."
    } | ConvertTo-Json -Compress) | Set-Content -LiteralPath (Join-Path $tempRoot "turns.jsonl") -Encoding UTF8

  $ready = Invoke-EvidenceCheck -EvidenceRoot $tempRoot -RequireReady
  if ($ready.exitCode -ne 0 -or $ready.json.status -ne "voice-v2-supervised-ready" -or $ready.json.failed -ne 0) {
    throw "Expected complete Voice V2 evidence to pass."
  }
  foreach ($id in @("robot-voice-v2-firmware", "robot-playback-started", "robot-playback-clean-counters", "robot-first-chunk-queue", "host-first-audio", "host-voice-first-audio", "host-stream-complete", "host-zero-truncation", "host-robot-byte-match")) {
    $check = @($ready.json.checks | Where-Object { $_.id -eq $id })[0]
    if ($null -eq $check -or $check.status -ne "pass") { throw "Expected $id to pass." }
  }

  $after.speaker_stream_forced_stops = 1
  Write-Json (Join-Path $tempRoot "after-debug.json") $after
  $forcedStop = Invoke-EvidenceCheck -EvidenceRoot $tempRoot -RequireReady
  if ($forcedStop.exitCode -eq 0) { throw "Expected a forced speaker stop to fail readiness." }
  $forcedStopCheck = @($forcedStop.json.checks | Where-Object { $_.id -eq "robot-playback-clean-counters" })[0]
  if ($null -eq $forcedStopCheck -or $forcedStopCheck.status -ne "fail") {
    throw "Expected forced speaker stop counter to fail the clean-playback gate."
  }

  $after.speaker_stream_forced_stops = 0
  $after.bridge_downlink_playback_bytes = 572798
  Write-Json (Join-Path $tempRoot "after-debug.json") $after
  $byteMismatch = Invoke-EvidenceCheck -EvidenceRoot $tempRoot -RequireReady
  if ($byteMismatch.exitCode -eq 0) { throw "Expected host/robot byte mismatch to fail readiness." }
  $byteCheck = @($byteMismatch.json.checks | Where-Object { $_.id -eq "host-robot-byte-match" })[0]
  if ($null -eq $byteCheck -or $byteCheck.status -ne "fail") {
    throw "Expected host/robot byte-match gate to fail."
  }
} finally {
  if (Test-Path -LiteralPath $tempRoot) {
    Remove-Item -LiteralPath $tempRoot -Recurse -Force
  }
}

Write-Host "Voice V2 supervised evidence contract tests passed."
