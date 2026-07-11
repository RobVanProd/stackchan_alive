param(
  [string]$HostName = "0.0.0.0",
  [int]$Port = 8765,
  [string]$Model = "gemma4:e2b-it-qat",
  [string]$RunnerCommand = "python bridge\ollama_stackchan_runner.py",
  [string]$SttCommand = "python bridge\whisper_cpp_stt.py",
  [string]$TtsCommand = "python bridge\selected_voice_tts.py",
  [string]$TtsVoice = "stackchan-rvc-bright-robot",
  [switch]$StreamTtsPhrases,
  [int]$TtsPhraseMaxChars = 96,
  [int]$SelectedVoiceMaxAudioBytes = 65536,
  [int]$SelectedVoiceStartBytes = 65536,
  [double]$SelectedVoiceGain = 0.30,
  [int]$DownlinkAudioChunkBytes = 4096,
  [int]$DownlinkBinaryFrameDelayMs = 80,
  [int]$DownlinkTextFrameDelayMs = 40,
  [int]$ClientIdleTimeoutSeconds = 120,
  [string]$LogDir = "output\pc-brain\latest",
  [string]$MemoryFile = "output\pc-brain\latest\memory.json",
  [string]$TurnLogFile = "output\pc-brain\latest\turns.jsonl",
  [string]$AudioEvidenceDir = "output\pc-brain\latest\audio-evidence",
  [string]$AutoTurnText = "",
  [switch]$RequireAudioWakePhrase,
  [switch]$AllowAudioWithoutWakePhrase,
  [switch]$DeterministicRunner,
  [switch]$EnableAudioDownlink,
  [switch]$Once,
  [switch]$Background,
  [switch]$StopExisting
)

$ErrorActionPreference = "Stop"

$RepoRoot = Resolve-Path (Join-Path $PSScriptRoot "..")
Set-Location $RepoRoot

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
New-Item -ItemType Directory -Force -Path $AudioEvidenceDir | Out-Null

if ($StopExisting) {
  $Connections = Get-NetTCPConnection -LocalPort $Port -State Listen -ErrorAction SilentlyContinue
  foreach ($Connection in $Connections) {
    Stop-Process -Id $Connection.OwningProcess -Force -ErrorAction SilentlyContinue
  }
}

$env:PYTHONUTF8 = "1"
$env:STACKCHAN_OLLAMA_EXE = $OllamaExe
$env:STACKCHAN_OLLAMA_MODEL = $Model
$env:STACKCHAN_FFMPEG_EXE = $FfmpegExe
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
  "--turn-log-file", $TurnLogFile,
  "--audio-evidence-dir", $AudioEvidenceDir
)

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

if ($Background) {
  $ProcessArgs = ($ArgsList | ForEach-Object { ConvertTo-CommandLineArg $_ }) -join " "
  $Process = Start-Process -FilePath "python" -ArgumentList $ProcessArgs -WorkingDirectory $RepoRoot -RedirectStandardOutput $OutLog -RedirectStandardError $ErrLog -WindowStyle Hidden -PassThru
  Set-Content -Path $PidFile -Value $Process.Id -Encoding ASCII
  Write-Host "Stackchan PC brain started."
  Write-Host "PID: $($Process.Id)"
  Write-Host "URL: ws://$HostName`:$Port/bridge"
  Write-Host "Logs: $OutLog ; $ErrLog"
  Write-Host "Memory: $MemoryFile"
  Write-Host "Turn log: $TurnLogFile"
  Write-Host "Audio evidence: $AudioEvidenceDir"
  exit 0
}

Write-Host "Starting Stackchan PC brain at ws://$HostName`:$Port/bridge"
Write-Host "Logs are printed in this console. Use -Background for log files."
python @ArgsList
