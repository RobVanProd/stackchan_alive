param(
  [string]$HostName = "127.0.0.1",
  [int]$Port = 8765,
  [string]$Model = "gemma4:e2b-it-qat",
  [string]$RunnerCommand = "python bridge\ollama_stackchan_runner.py",
  [switch]$InProcessOllamaRunner,
  [string]$SttCommand = "python bridge\whisper_cpp_stt.py",
  [string]$SttServerUrl = "",
  [string]$SttRestartCommand = "",
  [double]$SttHealthIntervalSeconds = 2.0,
  [string]$TtsCommand = "python bridge\selected_voice_tts.py",
  [switch]$InProcessDirectMlTts,
  [string]$TtsVoice = "stackchan-rvc-bright-robot",
  [switch]$StreamTtsPhrases,
  [int]$TtsPhraseMaxChars = 96,
  [int]$SelectedVoiceMaxAudioBytes = 65536,
  [int]$SelectedVoiceStartBytes = 65536,
  [double]$SelectedVoiceGain = 0.30,
  [int]$DownlinkAudioChunkBytes = 4096,
  [int]$DownlinkBinaryFrameDelayMs = 80,
  [int]$DownlinkTextFrameDelayMs = 40,
  [int]$ClientIdleTimeoutSeconds = 20,
  [string]$LogDir = "output\pc-brain\latest",
  [string]$MemoryFile = "output\pc-brain\latest\memory.json",
  [string]$TurnLogFile = "output\pc-brain\latest\turns.jsonl",
  [string]$AudioEvidenceDir = "",
  [switch]$EnablePrivateTurnEvidence,
  [string]$AutoTurnText = "",
  [switch]$RequireAudioWakePhrase,
  [switch]$AllowAudioWithoutWakePhrase,
  [switch]$DeterministicRunner,
  [switch]$EnableResearch,
  [string]$SearxngUrl = "http://127.0.0.1:8080",
  [switch]$EnableConversationV2,
  [int]$ConversationReplyWindowMs = 10000,
  [int]$ConversationReplyWindowMinMs = 10000,
  [int]$ConversationReplyWindowStepMs = 0,
  [int]$ConversationAcousticTailMs = 250,
  [int]$ConversationMaxTurns = 24,
  [int]$ConversationMaxContextTurns = 24,
  [int]$ConversationMaxContextChars = 160,
  [switch]$EnableEpisodeDistillation,
  [switch]$EnableInitiative,
  [int]$InitiativeMinIntervalSeconds = 600,
  [switch]$EnableRoomObservation,
  [int]$RoomObservationIntervalSeconds = 300,
  [string]$RoomVisionCommand = "python bridge\ollama_room_vision.py",
  [string]$RoomVisionModel = "",
  [string]$CameraPairingCodeFile = "",
  [switch]$EnableDashboard,
  [string]$DashboardHost = "127.0.0.1",
  [int]$DashboardPort = 8766,
  [string]$RobotHost = "",
  [int]$RobotHttpPort = 8789,
  [switch]$EnableAudioDownlink,
  [switch]$Once,
  [switch]$Background,
  [switch]$StopExisting
)

$ErrorActionPreference = "Stop"

$RepoRoot = Resolve-Path (Join-Path $PSScriptRoot "..")
Set-Location $RepoRoot
$SourceCommit = (& git rev-parse HEAD).Trim()
if ($LASTEXITCODE -ne 0 -or $SourceCommit -notmatch "^[0-9a-fA-F]{40}$") {
  throw "Could not resolve the PC brain source commit."
}
$SourceDirty = @(& git status --porcelain).Count -gt 0

$ParsedBindAddress = $null
$BindIsLoopback = $HostName -eq "localhost"
if ([System.Net.IPAddress]::TryParse($HostName, [ref]$ParsedBindAddress)) {
  $BindIsLoopback = [System.Net.IPAddress]::IsLoopback($ParsedBindAddress)
}
if (-not $BindIsLoopback -and [string]::IsNullOrWhiteSpace($RobotHost)) {
  throw "RobotHost is required when HostName is not loopback."
}

$OllamaExe = Join-Path $env:LOCALAPPDATA "Programs\Ollama\ollama.exe"
if (-not (Test-Path -LiteralPath $OllamaExe)) {
  $OllamaExe = "ollama"
}

$FfmpegExe = ""
$WingetPackages = Join-Path $env:LOCALAPPDATA "Microsoft\WinGet\Packages"
if (Test-Path -LiteralPath $WingetPackages) {
  $Candidate = Get-ChildItem -LiteralPath $WingetPackages -Filter "ffmpeg.exe" -Recurse -ErrorAction SilentlyContinue |
    Sort-Object LastWriteTime -Descending |
    Select-Object -First 1
  if ($Candidate) {
    $FfmpegExe = $Candidate.FullName
  }
}
if (-not $FfmpegExe) {
  $FfmpegExe = "ffmpeg"
}

New-Item -ItemType Directory -Force -Path $LogDir | Out-Null
New-Item -ItemType Directory -Force -Path (Split-Path -Parent $MemoryFile) | Out-Null
if (-not $EnablePrivateTurnEvidence -and -not [string]::IsNullOrWhiteSpace($AudioEvidenceDir)) {
  throw "AudioEvidenceDir requires explicit -EnablePrivateTurnEvidence."
}
if ($EnablePrivateTurnEvidence -and [string]::IsNullOrWhiteSpace($AudioEvidenceDir)) {
  $AudioEvidenceDir = "output\pc-brain\latest\audio-evidence"
}
if (-not [string]::IsNullOrWhiteSpace($AudioEvidenceDir)) {
  New-Item -ItemType Directory -Force -Path $AudioEvidenceDir | Out-Null
}

if ($StopExisting) {
  $Connections = Get-NetTCPConnection -LocalPort $Port -State Listen -ErrorAction SilentlyContinue
  foreach ($Connection in $Connections) {
    $ExistingProcess = Get-CimInstance Win32_Process `
      -Filter "ProcessId=$($Connection.OwningProcess)" -ErrorAction SilentlyContinue
    if ($null -ne $ExistingProcess -and
        [string]$ExistingProcess.CommandLine -match "bridge[\\/]lan_service\.py") {
      Stop-Process -Id $Connection.OwningProcess -Force -ErrorAction SilentlyContinue
    } else {
      Write-Host "Preserving non-Stackchan listener PID $($Connection.OwningProcess) on port $Port."
    }
  }
}

$env:PYTHONUTF8 = "1"
$env:STACKCHAN_OLLAMA_EXE = $OllamaExe
$env:STACKCHAN_OLLAMA_MODEL = $Model
$env:STACKCHAN_FFMPEG_EXE = $FfmpegExe
if (-not [string]::IsNullOrWhiteSpace($RoomVisionModel)) {
  $env:STACKCHAN_OLLAMA_VISION_MODEL = $RoomVisionModel
}
if ($SelectedVoiceMaxAudioBytes -gt 0) {
  $env:STACKCHAN_SELECTED_VOICE_MAX_AUDIO_BYTES = [string]$SelectedVoiceMaxAudioBytes
} else {
  Remove-Item Env:\STACKCHAN_SELECTED_VOICE_MAX_AUDIO_BYTES -ErrorAction SilentlyContinue
}
if ($SelectedVoiceStartBytes -gt 0) {
  $env:STACKCHAN_SELECTED_VOICE_START_BYTES = [string]$SelectedVoiceStartBytes
} else {
  Remove-Item Env:\STACKCHAN_SELECTED_VOICE_START_BYTES -ErrorAction SilentlyContinue
}
if ($SelectedVoiceGain -gt 0) {
  $env:STACKCHAN_SELECTED_VOICE_GAIN = [string]$SelectedVoiceGain
} else {
  Remove-Item Env:\STACKCHAN_SELECTED_VOICE_GAIN -ErrorAction SilentlyContinue
}

$ArgsList = @(
  "bridge\lan_service.py",
  "--host", $HostName,
  "--port", "$Port",
  "--runner-profile", "gemma4-e2b-gguf",
  "--runner-timeout-ms", "120000",
  "--stt-command", $SttCommand,
  "--stt-timeout-ms", "15000",
  "--tts-command", $TtsCommand,
  "--tts-voice", $TtsVoice,
  "--tts-timeout-ms", "120000",
  "--tts-phrase-max-chars", "$TtsPhraseMaxChars",
  "--downlink-audio-chunk-bytes", "$DownlinkAudioChunkBytes",
  "--downlink-binary-frame-delay-ms", "$DownlinkBinaryFrameDelayMs",
  "--downlink-text-frame-delay-ms", "$DownlinkTextFrameDelayMs",
  "--client-idle-timeout-s", "$ClientIdleTimeoutSeconds",
  "--memory-file", $MemoryFile,
  "--turn-log-file", $TurnLogFile
)

if ($EnablePrivateTurnEvidence) {
  $ArgsList += @("--audio-evidence-dir", $AudioEvidenceDir)
} else {
  $ArgsList += "--redact-turn-text"
}

if (-not [string]::IsNullOrWhiteSpace($SttServerUrl)) {
  $ArgsList += @("--stt-server-url", $SttServerUrl)
  $ArgsList += @("--stt-health-interval-s", "$SttHealthIntervalSeconds")
  if (-not [string]::IsNullOrWhiteSpace($SttRestartCommand)) {
    $ArgsList += @("--stt-restart-command", $SttRestartCommand)
  }
}

if ($StreamTtsPhrases) {
  $ArgsList += "--stream-tts-phrases"
}

if ($RequireAudioWakePhrase -and -not $AllowAudioWithoutWakePhrase) {
  $ArgsList += @("--require-audio-wake-phrase")
}

if (-not $EnableAudioDownlink) {
  $ArgsList += @("--disable-audio-downlink")
}

if ($Once) {
  $ArgsList += @("--once")
}

if (-not $DeterministicRunner) {
  $ArgsList += @(
    "--runner-command", $RunnerCommand,
    "--require-runner"
  )
}

if ($InProcessOllamaRunner) {
  $ArgsList += "--in-process-ollama-runner"
}

if ($InProcessDirectMlTts) {
  $ArgsList += "--in-process-directml-tts"
}

if ($EnableResearch) {
  $ArgsList += @(
    "--enable-research",
    "--searxng-url", $SearxngUrl
  )
}

if ($EnableConversationV2) {
  $ArgsList += @(
    "--conversation-v2",
    "--conversation-reply-window-ms", "$ConversationReplyWindowMs",
    "--conversation-reply-window-min-ms", "$ConversationReplyWindowMinMs",
    "--conversation-reply-window-step-ms", "$ConversationReplyWindowStepMs",
    "--conversation-acoustic-tail-ms", "$ConversationAcousticTailMs",
    "--conversation-max-turns", "$ConversationMaxTurns",
    "--conversation-max-context-turns", "$ConversationMaxContextTurns",
    "--conversation-max-context-chars", "$ConversationMaxContextChars"
  )
}

if ($EnableEpisodeDistillation) {
  $ArgsList += "--enable-episode-distillation"
}

if ($EnableInitiative) {
  $ArgsList += @(
    "--enable-initiative",
    "--initiative-min-interval-seconds", "$InitiativeMinIntervalSeconds"
  )
}

if ($EnableRoomObservation) {
  $ArgsList += @(
    "--room-observation",
    "--room-observation-interval-seconds", "$RoomObservationIntervalSeconds"
  )
}

if ($EnableRoomObservation -or -not [string]::IsNullOrWhiteSpace($CameraPairingCodeFile)) {
  $ArgsList += @("--room-vision-command", $RoomVisionCommand)
}

if (-not [string]::IsNullOrWhiteSpace($CameraPairingCodeFile)) {
  $ArgsList += @("--camera-pairing-code-file", $CameraPairingCodeFile)
}

if ($EnableDashboard) {
  if ($DashboardHost -notin @("127.0.0.1", "::1", "localhost")) {
    throw "DashboardHost must be loopback-only."
  }
  $ArgsList += @(
    "--dashboard",
    "--dashboard-host", $DashboardHost,
    "--dashboard-port", "$DashboardPort",
    "--robot-http-port", "$RobotHttpPort"
  )
}

if (-not [string]::IsNullOrWhiteSpace($RobotHost)) {
  $ArgsList += @("--robot-host", $RobotHost)
}

if ($AutoTurnText) {
  $ArgsList += @("--auto-turn-text", $AutoTurnText)
}

function ConvertTo-CommandLineArg([string]$Value) {
  if ($Value -notmatch '[\s"]') {
    return $Value
  }
  return '"' + $Value.Replace('"', '\"') + '"'
}

$OutLog = Join-Path $LogDir "lan_service.out.log"
$ErrLog = Join-Path $LogDir "lan_service.err.log"
$PidFile = Join-Path $LogDir "lan_service.pid"
$RuntimeManifestFile = Join-Path $LogDir "runtime_manifest.json"

if ($Background) {
  $ProcessArgs = ($ArgsList | ForEach-Object { ConvertTo-CommandLineArg $_ }) -join " "
  $Process = Start-Process -FilePath "python" -ArgumentList $ProcessArgs -WorkingDirectory $RepoRoot -RedirectStandardOutput $OutLog -RedirectStandardError $ErrLog -WindowStyle Hidden -PassThru
  Set-Content -Path $PidFile -Value $Process.Id -Encoding ASCII
  [ordered]@{
    schema = "stackchan.pc-brain-runtime.v1"
    generatedAt = (Get-Date).ToUniversalTime().ToString("o")
    sourceRoot = $RepoRoot.Path
    sourceCommit = $SourceCommit.ToLowerInvariant()
    sourceWorktreeClean = -not $SourceDirty
    bridgePid = [int]$Process.Id
    conversationV2Enabled = [bool]$EnableConversationV2
    conversationMaxTurns = if ($EnableConversationV2) { $ConversationMaxTurns } else { 0 }
    conversationMaxContextTurns = if ($EnableConversationV2) { $ConversationMaxContextTurns } else { 0 }
    episodeDistillationEnabled = [bool]$EnableEpisodeDistillation
    sttServerUrl = $SttServerUrl
    sttSupervised = -not [string]::IsNullOrWhiteSpace($SttRestartCommand)
  } | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $RuntimeManifestFile -Encoding UTF8
  Write-Host "Stackchan PC brain started."
  Write-Host "PID: $($Process.Id)"
  Write-Host "URL: ws://$HostName`:$Port/bridge"
  Write-Host "Logs: $OutLog ; $ErrLog"
  Write-Host "Memory: $MemoryFile"
  Write-Host "Turn log: $TurnLogFile"
  Write-Host "Turn text: $(if ($EnablePrivateTurnEvidence) { 'private evidence enabled' } else { 'redacted' })"
  Write-Host "Audio evidence: $(if ($EnablePrivateTurnEvidence) { $AudioEvidenceDir } else { 'disabled' })"
  if ($EnableDashboard) { Write-Host "Dashboard: http://$DashboardHost`:$DashboardPort/" }
  exit 0
}

Write-Host "Starting Stackchan PC brain at ws://$HostName`:$Port/bridge"
Write-Host "Logs are printed in this console. Use -Background for log files."
python @ArgsList
