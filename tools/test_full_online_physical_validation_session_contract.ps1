$ErrorActionPreference = "Stop"

$RepoRoot = Resolve-Path (Join-Path $PSScriptRoot "..")
Set-Location $RepoRoot

function Write-Json {
  param([string]$Path, $Object)
  $Object | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $Path -Encoding UTF8
}

function New-DebugFixture {
  param(
    [int]$UplinkBytes,
    [int]$UplinkChunks,
    [int]$UplinkTurns,
    [int]$UplinkCompleted,
    [int]$PlaybackStarts
  )
  return [ordered]@{
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
    bridge_uplink_bytes = $UplinkBytes
    bridge_uplink_chunks = $UplinkChunks
    bridge_uplink_turns = $UplinkTurns
    bridge_uplink_completed = $UplinkCompleted
    audio_capture_windows = $UplinkChunks
    audio_capture_events = $UplinkChunks
    bridge_downlink_playback_starts = $PlaybackStarts
  }
}

$tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("stackchan-full-online-session-" + [guid]::NewGuid().ToString("N"))
New-Item -ItemType Directory -Force -Path $tempRoot | Out-Null

try {
  $sessionScript = Join-Path $RepoRoot "tools\start_full_online_physical_validation_session.ps1"

  $previousErrorActionPreference = $ErrorActionPreference
  $ErrorActionPreference = "Continue"
  $missingSafetyOutput = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $sessionScript `
    -EvidenceRoot $tempRoot `
    -ConfirmServoRisk `
    -NonInteractive `
    -Json 2>&1
  $missingSafetyExit = $LASTEXITCODE
  $ErrorActionPreference = $previousErrorActionPreference
  if ($missingSafetyExit -eq 0) {
    throw "Expected session without logger safety flags to fail."
  }
  if (($missingSafetyOutput -join "`n") -notmatch "OperatorPresent") {
    throw "Expected missing OperatorPresent error, got $missingSafetyOutput"
  }

  $voiceBeforePath = Join-Path $tempRoot "voice-before.json"
  $voiceAfterPath = Join-Path $tempRoot "voice-after.json"
  $servoBeforePath = Join-Path $tempRoot "servo-before.json"
  $servoAfterPath = Join-Path $tempRoot "servo-after.json"
  $missingTurnLogPath = Join-Path $tempRoot "missing-turns.jsonl"
  Write-Json $voiceBeforePath (New-DebugFixture 100 2 1 1 3)
  Write-Json $voiceAfterPath (New-DebugFixture 9000 8 2 2 4)
  Write-Json $servoBeforePath (New-DebugFixture 9000 8 2 2 4)
  Write-Json $servoAfterPath (New-DebugFixture 9000 8 2 2 4)

  $sessionOutput = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $sessionScript `
    -EvidenceRoot $tempRoot `
    -NoLogger `
    -NonInteractive `
    -ConfirmServoRisk `
    -VoiceBeforeDebugJsonPath $voiceBeforePath `
    -VoiceAfterDebugJsonPath $voiceAfterPath `
    -ServoBeforeDebugJsonPath $servoBeforePath `
    -ServoAfterDebugJsonPath $servoAfterPath `
    -TurnLogFile $missingTurnLogPath `
    -Json
  if (-not $?) {
    throw "Session failed: $sessionOutput"
  }
  $session = $sessionOutput | ConvertFrom-Json
  if ($session.schema -ne "stackchan.full-online-physical-session.v1") {
    throw "Unexpected session schema $($session.schema)."
  }
  if ($session.status -ne "full-online-physical-session-pending-review") {
    throw "Expected pending-review session, got $($session.status)."
  }
  if ($session.suggestedVoicePrompt -ne "hello stackchan") {
    throw "Expected default suggested voice prompt in session evidence."
  }
  if ($session.voiceTurnLog.path -notmatch "VOICE_IN_TURN_LOG.json") {
    throw "Expected voice turn log snapshot path in session evidence."
  }
  foreach ($file in @(
      "VOICE_IN_BEFORE_DEBUG.json",
      "VOICE_IN_AFTER_DEBUG.json",
      "SERVO_BEFORE_DEBUG.json",
      "SERVO_AFTER_DEBUG.json",
      "FULL_ONLINE_PHYSICAL_SESSION.json",
      "FULL_ONLINE_PHYSICAL_SESSION.md"
    )) {
    if (-not (Test-Path -LiteralPath (Join-Path $tempRoot $file) -PathType Leaf)) {
      throw "Expected session artifact $file."
    }
  }
  $step = @($session.steps | Where-Object { $_.id -eq "validation-logger" })[0]
  if ($null -eq $step -or $step.status -ne "pending") {
    throw "Expected NoLogger session to leave validation-logger pending."
  }
  $turnLogStep = @($session.steps | Where-Object { $_.id -eq "voice-turn-log" })[0]
  if ($null -eq $turnLogStep -or $turnLogStep.status -ne "pending" -or $turnLogStep.detail -notmatch "No turn log lines") {
    throw "Expected missing turn log to be recorded as pending evidence."
  }
  $sessionMd = Get-Content -LiteralPath (Join-Path $tempRoot "FULL_ONLINE_PHYSICAL_SESSION.md") -Raw
  if ($sessionMd -notmatch "Suggested voice prompt: ``hello stackchan``") {
    throw "Expected suggested voice prompt in session markdown."
  }
  if ($sessionMd -notmatch "Voice turn log snapshot") {
    throw "Expected voice turn log snapshot in session markdown."
  }
} finally {
  Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Host "Full-online physical validation session contract tests passed."
