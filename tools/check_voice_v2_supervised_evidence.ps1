param(
  [Parameter(Mandatory = $true)]
  [string]$EvidenceRoot,
  [double]$MaxFirstAudioMs = 3000,
  [double]$MaxVoiceFirstAudioMs = 3000,
  [int]$MaxFrameUs = 50000,
  [int]$MinVbusMv = 4400,
  [double]$MaxChipTempC = 68,
  [switch]$ConfirmHeardCleanAudio,
  [switch]$ConfirmHeardCompleteReply,
  [switch]$RequireReady,
  [switch]$Json
)

$ErrorActionPreference = "Stop"
$RepoRoot = Resolve-Path (Join-Path $PSScriptRoot "..")
Set-Location $RepoRoot

$Checks = @()
function Add-Check {
  param([string]$Id, [ValidateSet("pass", "fail", "pending")][string]$Status, [string]$Detail)
  $script:Checks += [ordered]@{ id = $Id; status = $Status; detail = $Detail }
}

function Read-Json {
  param([string]$Path)
  if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $null }
  return Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json
}

function Get-Int {
  param($Object, [string]$Name, [int64]$Default = 0)
  if ($null -eq $Object) { return $Default }
  $Property = $Object.PSObject.Properties[$Name]
  if ($null -eq $Property -or $null -eq $Property.Value) { return $Default }
  return [int64]$Property.Value
}

function Get-Double {
  param($Object, [string]$Name, [double]$Default = 0.0)
  if ($null -eq $Object) { return $Default }
  $Property = $Object.PSObject.Properties[$Name]
  if ($null -eq $Property -or $null -eq $Property.Value) { return $Default }
  return [double]$Property.Value
}

$EvidencePath = if (Test-Path -LiteralPath $EvidenceRoot) { (Resolve-Path $EvidenceRoot).Path } else { $EvidenceRoot }
$Before = Read-Json (Join-Path $EvidencePath "before-debug.json")
$After = Read-Json (Join-Path $EvidencePath "after-debug.json")
$Session = Read-Json (Join-Path $EvidencePath "session.json")
$TurnLogPath = Join-Path $EvidencePath "turns.jsonl"
$Turns = @()
if (Test-Path -LiteralPath $TurnLogPath -PathType Leaf) {
  foreach ($Line in Get-Content -LiteralPath $TurnLogPath) {
    if (-not [string]::IsNullOrWhiteSpace($Line)) {
      try { $Turns += ($Line | ConvertFrom-Json) } catch {}
    }
  }
}
$CandidateTurns = @($Turns | Where-Object { $_.tts_streaming -eq $true -and $_.tts_voice -eq "stackchan-rvc-directml-v2" })
$Turn = if ($CandidateTurns.Count -gt 0) { $CandidateTurns[-1] } else { $null }

Add-Check "before-debug" ($(if ($Before) { "pass" } else { "fail" })) "before-debug.json"
Add-Check "after-debug" ($(if ($After) { "pass" } else { "fail" })) "after-debug.json"
Add-Check "session-config" ($(if ($Session -and $Session.mode -eq "voice-v2-directml-supervised") { "pass" } else { "fail" })) "mode=$($Session.mode)"
Add-Check "candidate-turn" ($(if ($Turn) { "pass" } else { "fail" })) "candidate_turns=$($CandidateTurns.Count)"

if ($Before -and $After) {
  Add-Check "robot-voice-v2-firmware" ($(if ((Get-Int $Before "speaker_stream_chunked" 0) -eq 1 -and (Get-Int $After "speaker_stream_chunked" 0) -eq 1) { "pass" } else { "fail" })) "before=$($Before.speaker_stream_chunked) after=$($After.speaker_stream_chunked)"
  Add-Check "robot-network-ready" ($(if ($After.network_state -eq "connected" -and $After.bridge_state -eq "ready") { "pass" } else { "fail" })) "network=$($After.network_state) bridge=$($After.bridge_state)"
  Add-Check "robot-motion-safe" ($(if (-not [bool]$After.motion_enabled -and -not [bool]$After.servo_rail_enabled -and -not [bool]$After.servo_torque_enabled) { "pass" } else { "fail" })) "motion=$($After.motion_enabled) rail=$($After.servo_rail_enabled) torque=$($After.servo_torque_enabled)"
  $FrameUs = Get-Int $After "display_window_max_frame_us" 0
  Add-Check "robot-face-frame" ($(if ($FrameUs -gt 0 -and $FrameUs -le $MaxFrameUs) { "pass" } else { "fail" })) "frame_us=$FrameUs max=$MaxFrameUs fps=$($After.display_window_fps)"
  $Vbus = Get-Int $After "power_vbus_mv" 0
  Add-Check "robot-vbus" ($(if ($Vbus -ge $MinVbusMv) { "pass" } else { "fail" })) "vbus_mv=$Vbus min=$MinVbusMv"
  $Temp = Get-Double $After "chip_temp_c" 0
  Add-Check "robot-temperature" ($(if ($Temp -gt 0 -and $Temp -le $MaxChipTempC) { "pass" } else { "fail" })) "chip_temp_c=$Temp max=$MaxChipTempC"
  $PlaybackDelta = (Get-Int $After "bridge_downlink_playback_starts" 0) - (Get-Int $Before "bridge_downlink_playback_starts" 0)
  $PlaybackChunksDelta = (Get-Int $After "bridge_downlink_playback_chunks" 0) - (Get-Int $Before "bridge_downlink_playback_chunks" 0)
  $PlaybackBytesDelta = (Get-Int $After "bridge_downlink_playback_bytes" 0) - (Get-Int $Before "bridge_downlink_playback_bytes" 0)
  $RawOkDelta = (Get-Int $After "speaker_stream_play_raw_ok" 0) - (Get-Int $Before "speaker_stream_play_raw_ok" 0)
  $PlaybackErrorDelta = (Get-Int $After "bridge_downlink_playback_errors" 0) - (Get-Int $Before "bridge_downlink_playback_errors" 0)
  $RawFailedDelta = (Get-Int $After "speaker_stream_play_raw_failed" 0) - (Get-Int $Before "speaker_stream_play_raw_failed" 0)
  $ForcedStopDelta = (Get-Int $After "speaker_stream_forced_stops" 0) - (Get-Int $Before "speaker_stream_forced_stops" 0)
  Add-Check "robot-playback-started" ($(if ($PlaybackDelta -gt 0 -and $PlaybackChunksDelta -gt 0 -and $PlaybackBytesDelta -gt 0 -and $RawOkDelta -eq $PlaybackChunksDelta) { "pass" } else { "fail" })) "starts_delta=$PlaybackDelta chunks_delta=$PlaybackChunksDelta bytes_delta=$PlaybackBytesDelta raw_ok_delta=$RawOkDelta"
  Add-Check "robot-playback-clean-counters" ($(if ($PlaybackErrorDelta -eq 0 -and $RawFailedDelta -eq 0 -and $ForcedStopDelta -eq 0 -and -not [bool]$After.audio_stream_active -and (Get-Int $After "speaker_channel_state" 1) -eq 0) { "pass" } else { "fail" })) "playback_error_delta=$PlaybackErrorDelta raw_failed_delta=$RawFailedDelta forced_stop_delta=$ForcedStopDelta active=$($After.audio_stream_active) channel=$($After.speaker_channel_state)"
  $FirstChunkDelayMs = Get-Int $After "speaker_stream_first_chunk_delay_ms" 0
  Add-Check "robot-first-chunk-queue" ($(if ($FirstChunkDelayMs -ge 0 -and $FirstChunkDelayMs -le 1000) { "pass" } else { "fail" })) "first_chunk_delay_ms=$FirstChunkDelayMs max=1000"
  $UplinkTurnDelta = (Get-Int $After "bridge_uplink_turns" 0) - (Get-Int $Before "bridge_uplink_turns" 0)
  $UplinkBytesDelta = (Get-Int $After "bridge_uplink_bytes" 0) - (Get-Int $Before "bridge_uplink_bytes" 0)
  Add-Check "robot-mic-turn" ($(if ($UplinkTurnDelta -gt 0 -and $UplinkBytesDelta -gt 0) { "pass" } else { "fail" })) "uplink_turns_delta=$UplinkTurnDelta uplink_bytes_delta=$UplinkBytesDelta"
}

if ($Turn) {
  $FirstAudioValues = @($CandidateTurns | ForEach-Object { Get-Double $_ "tts_first_audio_ms" 0 })
  $VoiceFirstAudioValues = @($CandidateTurns | ForEach-Object {
      $Value = Get-Double $_ "tts_first_audio_after_text_ms" 0
      if ($Value -le 0) {
        $Value = (Get-Double $_ "tts_first_audio_ms" 0) -
          (Get-Double $_ "stt_elapsed_ms" 0) -
          (Get-Double $_ "runner_elapsed_ms" 0)
      }
      $Value
    })
  $FirstAudioMs = ($FirstAudioValues | Measure-Object -Maximum).Maximum
  $VoiceFirstAudioMs = ($VoiceFirstAudioValues | Measure-Object -Maximum).Maximum
  $Phrases = ($CandidateTurns | ForEach-Object { Get-Int $_ "tts_phrases" 0 } | Measure-Object -Sum).Sum
  $Completed = ($CandidateTurns | ForEach-Object { Get-Int $_ "tts_phrases_completed" 0 } | Measure-Object -Sum).Sum
  $PayloadBytes = ($CandidateTurns | ForEach-Object { Get-Int $_ "tts_audio_payload_bytes" 0 } | Measure-Object -Sum).Sum
  $IncompleteTurns = @($CandidateTurns | Where-Object { -not [bool]$_.tts_stream_complete }).Count
  $TruncatedTurns = @($CandidateTurns | Where-Object {
      [bool]$_.tts_audio_truncated -or -not [string]::IsNullOrWhiteSpace([string]$_.tts_error)
    }).Count
  Add-Check "host-first-audio" ($(if ($FirstAudioMs -gt 0 -and $FirstAudioMs -le $MaxFirstAudioMs) { "pass" } else { "fail" })) "conversation_first_audio_ms=$FirstAudioMs max=$MaxFirstAudioMs"
  Add-Check "host-voice-first-audio" ($(if ($VoiceFirstAudioMs -gt 0 -and $VoiceFirstAudioMs -le $MaxVoiceFirstAudioMs) { "pass" } else { "fail" })) "post_text_first_audio_ms=$VoiceFirstAudioMs max=$MaxVoiceFirstAudioMs"
  Add-Check "host-stream-complete" ($(if ($IncompleteTurns -eq 0 -and $Phrases -gt 0 -and $Completed -eq $Phrases) { "pass" } else { "fail" })) "turns=$($CandidateTurns.Count) incomplete=$IncompleteTurns phrases=$Completed/$Phrases"
  Add-Check "host-zero-truncation" ($(if ($TruncatedTurns -eq 0 -and $PayloadBytes -gt 0) { "pass" } else { "fail" })) "turns=$($CandidateTurns.Count) truncated_or_error=$TruncatedTurns payload_bytes=$PayloadBytes"
  if ($Before -and $After) {
    $RobotPlaybackBytes = (Get-Int $After "bridge_downlink_playback_bytes" 0) - (Get-Int $Before "bridge_downlink_playback_bytes" 0)
    Add-Check "host-robot-byte-match" ($(if ($PayloadBytes -gt 0 -and $RobotPlaybackBytes -eq $PayloadBytes) { "pass" } else { "fail" })) "host_payload_bytes=$PayloadBytes robot_playback_bytes=$RobotPlaybackBytes"
  }
  $EmptyTranscripts = @($CandidateTurns | Where-Object { [string]::IsNullOrWhiteSpace([string]$_.transcript) }).Count
  Add-Check "host-stt-transcript" ($(if ($EmptyTranscripts -eq 0) { "pass" } else { "fail" })) "candidate_turns=$($CandidateTurns.Count) empty_transcripts=$EmptyTranscripts"
}

Add-Check "operator-clean-audio" ($(if ($ConfirmHeardCleanAudio) { "pass" } else { "pending" })) "Operator heard clear audio without clipping, static, or choppiness."
Add-Check "operator-complete-reply" ($(if ($ConfirmHeardCompleteReply) { "pass" } else { "pending" })) "Operator heard the complete reply without cutoff."

$Failed = @($Checks | Where-Object { $_.status -eq "fail" })
$Pending = @($Checks | Where-Object { $_.status -eq "pending" })
$Status = if ($Failed.Count -gt 0) { "voice-v2-supervised-not-ready" } elseif ($Pending.Count -gt 0) { "voice-v2-supervised-pending-operator" } else { "voice-v2-supervised-ready" }
$Result = [ordered]@{
  schema = "stackchan.voice-v2-supervised-check.v1"
  status = $Status
  evidence_root = $EvidencePath
  passed = @($Checks | Where-Object { $_.status -eq "pass" }).Count
  failed = $Failed.Count
  pending = $Pending.Count
  checks = $Checks
}
New-Item -ItemType Directory -Force -Path $EvidencePath | Out-Null
$Result | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath (Join-Path $EvidencePath "voice-v2-check.json") -Encoding UTF8
if ($Json) { $Result | ConvertTo-Json -Depth 8 } else { Write-Host "$Status ($($Result.passed) pass, $($Result.failed) fail, $($Result.pending) pending)" }
if ($RequireReady -and $Status -ne "voice-v2-supervised-ready") { exit 1 }
exit 0
