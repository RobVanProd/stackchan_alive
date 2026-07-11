param(
  [int]$Port = 8765,
  [string]$ExpectedHostName = "0.0.0.0",
  [string]$ExpectedRunnerCommand = "bridge\ollama_stackchan_runner.py",
  [string]$ExpectedSttCommand = "bridge\whisper_cpp_stt.py",
  [string]$ExpectedTtsCommand = "bridge\selected_voice_tts.py",
  [string]$ExpectedTtsVoice = "stackchan-rvc-bright-robot",
  [bool]$ExpectedStreamTtsPhrases = $false,
  [int]$ExpectedDownlinkAudioChunkBytes = 4096,
  [int]$ExpectedDownlinkBinaryFrameDelayMs = 20,
  [int]$ExpectedDownlinkTextFrameDelayMs = 40,
  [int]$ExpectedClientIdleTimeoutSeconds = 120,
  [string]$ExpectedTurnLogFile = "output\pc-brain\latest\turns.jsonl",
  [bool]$ExpectedRequireAudioWakePhrase = $false,
  [bool]$ExpectedDisableAudioDownlink = $true,
  [bool]$ExpectedAudioPlaybackEnabled = $false,
  [string]$VoiceWorkerUrl = "",
  [string]$ExpectedVoiceWorkerSchema = "",
  [string]$LogDir = "output\pc-brain\latest",
  [string]$ReportDir = "",
  [string]$DeviceHost = "",
  [string]$DebugUrl = "",
  [string]$ProcessCommandLine = "",
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

function Normalize-Text {
  param([string]$Text)
  return ($Text -replace "\\", "/" -replace "\s+", " ").Trim().ToLowerInvariant()
}

function Test-CommandLineContains {
  param(
    [string]$Id,
    [string]$NormalizedCommandLine,
    [string]$Needle,
    [string]$Description
  )
  $normalizedNeedle = Normalize-Text $Needle
  Add-Check $Id ($(if ($NormalizedCommandLine.Contains($normalizedNeedle)) { "pass" } else { "fail" })) $Description
}

function Test-CommandLineExcludes {
  param(
    [string]$Id,
    [string]$NormalizedCommandLine,
    [string]$Needle,
    [string]$Description
  )
  $normalizedNeedle = Normalize-Text $Needle
  Add-Check $Id ($(if (-not $NormalizedCommandLine.Contains($normalizedNeedle)) { "pass" } else { "fail" })) $Description
}

function Test-CommandLineFlagAndScript {
  param(
    [string]$Id,
    [string]$NormalizedCommandLine,
    [string]$Flag,
    [string]$ExpectedScript,
    [string]$Description
  )
  $normalizedFlag = Normalize-Text $Flag
  $normalizedScript = Normalize-Text $ExpectedScript
  Add-Check $Id ($(if ($NormalizedCommandLine.Contains($normalizedFlag) -and $NormalizedCommandLine.Contains($normalizedScript)) { "pass" } else { "fail" })) $Description
}

function Write-RuntimeMarkdown {
  param(
    [string]$Path,
    $Result
  )
  $lines = @(
    "# Stackchan PC Brain Runtime Check",
    "",
    "- Schema: ``$($Result.schema)``",
    "- Status: ``$($Result.status)``",
    "- Machine ready: ``$($Result.machineReady)``",
    "- Process id: ``$($Result.processId)``",
    "- Port: ``$($Result.port)``",
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

$processId = 0
$commandLine = $ProcessCommandLine
$processes = @()

if ([string]::IsNullOrWhiteSpace($commandLine)) {
  $processes = @(Get-CimInstance Win32_Process | Where-Object {
      ($_.Name -like "python*" -or $_.ExecutablePath -match "python") -and
      ($_.CommandLine -like "*bridge\lan_service.py*" -or $_.CommandLine -like "*bridge/lan_service.py*")
    })
  if ($processes.Count -gt 0) {
    $selected = $processes | Sort-Object ProcessId | Select-Object -First 1
    $processId = [int]$selected.ProcessId
    $commandLine = [string]$selected.CommandLine
  }
}

if ([string]::IsNullOrWhiteSpace($commandLine)) {
  Add-Check "process-found" "fail" "No bridge\lan_service.py process is running."
} else {
  Add-Check "process-found" "pass" "PC brain process found."
}

if ($processes.Count -gt 1) {
  Add-Check "single-process" "fail" "Multiple PC brain processes found: $($processes.ProcessId -join ', ')"
} elseif ($processes.Count -eq 1 -or -not [string]::IsNullOrWhiteSpace($ProcessCommandLine)) {
  Add-Check "single-process" "pass" "One PC brain command line selected."
}

$normalizedCommandLine = Normalize-Text $commandLine

if (-not [string]::IsNullOrWhiteSpace($commandLine)) {
  Test-CommandLineContains "script" $normalizedCommandLine "bridge/lan_service.py" "Uses bridge/lan_service.py."
  Test-CommandLineContains "host" $normalizedCommandLine "--host $ExpectedHostName" "Host is $ExpectedHostName."
  Test-CommandLineContains "port" $normalizedCommandLine "--port $Port" "Port is $Port."
  Test-CommandLineContains "runner-profile" $normalizedCommandLine "--runner-profile gemma4-e2b-gguf" "Runner profile is gemma4-e2b-gguf."
  Test-CommandLineFlagAndScript "runner-command" $normalizedCommandLine "--runner-command" $ExpectedRunnerCommand "Runner command is $ExpectedRunnerCommand."
  Test-CommandLineContains "require-runner" $normalizedCommandLine "--require-runner" "Real runner is required."
  Test-CommandLineFlagAndScript "stt-command" $normalizedCommandLine "--stt-command" $ExpectedSttCommand "STT command is $ExpectedSttCommand."
  Test-CommandLineFlagAndScript "tts-command" $normalizedCommandLine "--tts-command" $ExpectedTtsCommand "TTS command is $ExpectedTtsCommand."
  Test-CommandLineContains "tts-voice" $normalizedCommandLine "--tts-voice $ExpectedTtsVoice" "TTS voice is $ExpectedTtsVoice."
  Test-CommandLineContains "chunk-bytes" $normalizedCommandLine "--downlink-audio-chunk-bytes $ExpectedDownlinkAudioChunkBytes" "Downlink chunk bytes are $ExpectedDownlinkAudioChunkBytes."
  Test-CommandLineContains "binary-delay" $normalizedCommandLine "--downlink-binary-frame-delay-ms $ExpectedDownlinkBinaryFrameDelayMs" "Binary frame delay is $ExpectedDownlinkBinaryFrameDelayMs ms."
  Test-CommandLineContains "text-delay" $normalizedCommandLine "--downlink-text-frame-delay-ms $ExpectedDownlinkTextFrameDelayMs" "Text frame delay is $ExpectedDownlinkTextFrameDelayMs ms."
  Test-CommandLineContains "client-idle-timeout" $normalizedCommandLine "--client-idle-timeout-s $ExpectedClientIdleTimeoutSeconds" "Client idle timeout is $ExpectedClientIdleTimeoutSeconds seconds."
  Test-CommandLineContains "turn-log-file" $normalizedCommandLine "--turn-log-file $ExpectedTurnLogFile" "Turn summaries will be written to $ExpectedTurnLogFile."
  if ($ExpectedRequireAudioWakePhrase) {
    Test-CommandLineContains "audio-wake-phrase" $normalizedCommandLine "--require-audio-wake-phrase" "Audio turns require Stackchan in the transcript before the brain responds."
  } else {
    Test-CommandLineExcludes "audio-wake-phrase" $normalizedCommandLine "--require-audio-wake-phrase" "Bot-local wake authorizes audio turns; PC transcript wake gate is disabled."
  }
  if ($ExpectedDisableAudioDownlink) {
    Test-CommandLineContains "audio-downlink-disabled" $normalizedCommandLine "--disable-audio-downlink" "Bridge audio downlink is disabled until the speaker path is revalidated."
  } else {
    Test-CommandLineExcludes "audio-downlink-disabled" $normalizedCommandLine "--disable-audio-downlink" "Bridge audio downlink is explicitly enabled for supervised speaker validation."
  }
  if ($ExpectedStreamTtsPhrases) {
    Test-CommandLineContains "stream-tts-phrases" $normalizedCommandLine "--stream-tts-phrases" "Phrase streaming is enabled."
  } else {
    Test-CommandLineExcludes "stream-tts-phrases" $normalizedCommandLine "--stream-tts-phrases" "Phrase streaming is disabled for this profile."
  }
}

$voiceWorkerHealth = $null
if (-not [string]::IsNullOrWhiteSpace($VoiceWorkerUrl)) {
  try {
    $voiceWorkerHealth = Invoke-RestMethod -Uri ($VoiceWorkerUrl.TrimEnd("/") + "/health") -TimeoutSec 8
    Add-Check "voice-worker-health" ($(if ([bool]$voiceWorkerHealth.ready) { "pass" } else { "fail" })) "url=$VoiceWorkerUrl ready=$($voiceWorkerHealth.ready)"
    if (-not [string]::IsNullOrWhiteSpace($ExpectedVoiceWorkerSchema)) {
      Add-Check "voice-worker-schema" ($(if ([string]$voiceWorkerHealth.schema -eq $ExpectedVoiceWorkerSchema) { "pass" } else { "fail" })) "schema=$($voiceWorkerHealth.schema) expected=$ExpectedVoiceWorkerSchema"
    }
  } catch {
    Add-Check "voice-worker-health" "fail" "$VoiceWorkerUrl :: $($_.Exception.Message)"
  }
}

if ([string]::IsNullOrWhiteSpace($ProcessCommandLine)) {
  $listener = @(Get-NetTCPConnection -LocalPort $Port -State Listen -ErrorAction SilentlyContinue)
  if ($listener.Count -eq 0) {
    Add-Check "port-listener" "fail" "No listener on local port $Port."
  } else {
    $owners = @($listener | Select-Object -ExpandProperty OwningProcess -Unique)
    if ($processId -gt 0 -and ($owners -contains $processId)) {
      Add-Check "port-listener" "pass" "Port $Port is owned by PC brain process $processId."
    } else {
      Add-Check "port-listener" "fail" "Port $Port owned by process(es): $($owners -join ', '); selected process=$processId."
    }
  }

  $outLog = Join-Path $LogDir "lan_service.out.log"
  $errLog = Join-Path $LogDir "lan_service.err.log"
  $pidFile = Join-Path $LogDir "lan_service.pid"
  Add-Check "pid-file" ($(if (Test-Path -LiteralPath $pidFile -PathType Leaf) { "pass" } else { "pending" })) $pidFile
  Add-Check "out-log" ($(if (Test-Path -LiteralPath $outLog -PathType Leaf) { "pass" } else { "pending" })) $outLog
  if (Test-Path -LiteralPath $errLog -PathType Leaf) {
    $errText = Get-Content -LiteralPath $errLog -Raw
    Add-Check "err-log-clean" ($(if ([string]::IsNullOrWhiteSpace($errText)) { "pass" } else { "fail" })) $errLog
  } else {
    Add-Check "err-log-clean" "pending" $errLog
  }
} else {
  Add-Check "port-listener" "pending" "Skipped because -ProcessCommandLine was supplied."
}

if ([string]::IsNullOrWhiteSpace($DebugUrl) -and -not [string]::IsNullOrWhiteSpace($DeviceHost)) {
  $DebugUrl = "http://$DeviceHost`:8789/debug"
}

$liveDebug = $null
if (-not [string]::IsNullOrWhiteSpace($DebugUrl)) {
  try {
    $liveDebug = Invoke-RestMethod -Uri $DebugUrl -TimeoutSec 5
    Add-Check "live-debug" "pass" $DebugUrl
    Add-Check "live-debug-ready" ($(if ($liveDebug.network_state -eq "connected" -and $liveDebug.bridge_state -eq "ready") { "pass" } else { "fail" })) "network=$($liveDebug.network_state) bridge=$($liveDebug.bridge_state)"
    Add-Check "live-debug-error-clear" ($(if ([string]$liveDebug.network_error -eq "") { "pass" } else { "fail" })) "network_error=$($liveDebug.network_error)"
    $speakerVolume = [int]$liveDebug.speaker_volume
    Add-Check "live-debug-volume-safe" ($(if ($speakerVolume -gt 0 -and $speakerVolume -le 180) { "pass" } else { "fail" })) "speaker_volume=$($liveDebug.speaker_volume)"
    Add-Check "live-debug-audio-idle" ($(if (-not [bool]$liveDebug.audio_stream_active) { "pass" } else { "fail" })) "audio_stream_active=$($liveDebug.audio_stream_active)"
    if ($liveDebug.PSObject.Properties.Name -contains "bridge_downlink_playback_enabled") {
      $playbackMatches = [bool]$liveDebug.bridge_downlink_playback_enabled -eq $ExpectedAudioPlaybackEnabled
      Add-Check "live-debug-audio-playback-policy" ($(if ($playbackMatches) { "pass" } else { "fail" })) "bridge_downlink_playback_enabled=$($liveDebug.bridge_downlink_playback_enabled) expected=$ExpectedAudioPlaybackEnabled"
    }
  } catch {
    Add-Check "live-debug" "fail" "$DebugUrl :: $($_.Exception.Message)"
  }
} else {
  Add-Check "live-debug" "pending" "Pass -DeviceHost or -DebugUrl to include current robot state."
}

$failed = @($checks | Where-Object { $_.status -eq "fail" })
$pending = @($checks | Where-Object { $_.status -eq "pending" })
$status = if ($failed.Count -gt 0) { "pc-brain-runtime-not-ready" } elseif ($pending.Count -gt 0) { "pc-brain-runtime-pending" } else { "pc-brain-runtime-ready" }

$result = [ordered]@{
  schema = "stackchan.pc-brain-runtime-check.v1"
  status = $status
  machineReady = ($failed.Count -eq 0)
  processId = $processId
  port = $Port
  commandLine = $commandLine
  debugUrl = $DebugUrl
  voiceWorkerUrl = $VoiceWorkerUrl
  voiceWorkerHealth = $voiceWorkerHealth
  passed = @($checks | Where-Object { $_.status -eq "pass" }).Count
  failed = $failed.Count
  pending = $pending.Count
  checks = $checks
}

if (-not [string]::IsNullOrWhiteSpace($ReportDir)) {
  New-Item -ItemType Directory -Force -Path $ReportDir | Out-Null
  $resolvedReportDir = (Resolve-Path $ReportDir).Path
  $jsonPath = Join-Path $resolvedReportDir "PC_BRAIN_RUNTIME_CHECK.json"
  $markdownPath = Join-Path $resolvedReportDir "PC_BRAIN_RUNTIME_CHECK.md"
  $result | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $jsonPath -Encoding UTF8
  Write-RuntimeMarkdown -Path $markdownPath -Result $result
  if ($null -ne $liveDebug) {
    $liveDebug | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath (Join-Path $resolvedReportDir "PC_BRAIN_RUNTIME_LIVE_DEBUG.json") -Encoding UTF8
  }
}

if ($Json) {
  $result | ConvertTo-Json -Depth 8
} else {
  Write-Host "PC brain runtime: $status"
  foreach ($check in $checks) {
    Write-Host "[$($check.status)] $($check.id): $($check.detail)"
  }
}

if ($failed.Count -gt 0) {
  exit 1
}
