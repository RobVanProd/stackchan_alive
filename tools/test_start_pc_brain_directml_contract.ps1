$ErrorActionPreference = "Stop"

$RepoRoot = Resolve-Path (Join-Path $PSScriptRoot "..")
$launcherPath = Join-Path $PSScriptRoot "start_pc_brain_directml.ps1"
$text = Get-Content -LiteralPath $launcherPath -Raw
$baseLauncherPath = Join-Path $PSScriptRoot "start_pc_brain.ps1"
$baseText = Get-Content -LiteralPath $baseLauncherPath -Raw

$tokens = $null
$parseErrors = $null
[System.Management.Automation.Language.Parser]::ParseFile(
  $launcherPath,
  [ref]$tokens,
  [ref]$parseErrors
) | Out-Null
if ($parseErrors.Count -ne 0) {
  throw "DirectML launcher has PowerShell parse errors: $($parseErrors -join '; ')"
}

foreach ($required in @(
  "Stop-ExistingBridge",
  "Preserving non-Stackchan listener",
  "BridgeStartupReady",
  "Invoke-EncodedChildPowerShell",
  "RedirectStandardOutput",
  "RedirectStandardError",
  "WaitForExit()",
  "Refresh()",
  "[int]`$process.ExitCode",
  "memory_maintenance.py --memory-file `$MemoryFile --apply",
  "start_voice_v2_directml_worker.ps1",
  "start_whisper_server.ps1",
  "check_local_research.ps1",
  "research-preflight.json",
  "Local research preflight failed:",
  "researchGateStatus =",
  "SttServerPort",
  "[int]`$SttThreads = 12",
  "[string]`$SttInitialPrompt",
  '[ValidateSet("auto", "cpu", "vulkan")]',
  "ggml-small.en.bin",
  "whisper.cpp-vulkan",
  "whisper.cpp-blas",
  "-Backend vulkan -Model small.en",
  "c6138d6d58ecc8322097e0f987c32f1be8bb0a18532a3f88f734d1bbf9c41e5d",
  "Production STT requires the pinned full ggml-small.en.bin model.",
  "-Backend '`$ResolvedSttBackend'",
  "-WarmupWavPath '`$escapedSttWarmupWav'",
  "-StopExisting -Json",
  "did not prove the requested production STT configuration",
  "-SttServerUrl '`$SttServerUrl'",
  "-SttRestartCommand '`$escapedSttRestartCommand'",
  "-SttHealthIntervalSeconds 2",
  "STACKCHAN_WHISPER_CPP_EXE",
  "STACKCHAN_WHISPER_MODEL",
  "STACKCHAN_WHISPER_THREADS",
  "whisper-cli.exe",
  "Production STT recovery requires whisper-cli.exe beside whisper-server.exe.",
  "sttFallbackExecutableSha256 =",
  "sttSupervised = `$true",
  "sttServerReady =",
  "sttExecutableSha256 =",
  "sttModelSha256 =",
  "sttConfigVerified =",
  "sttBackendVerified =",
  "sttWarmupVerified =",
  "sttWarmupElapsedMs =",
  "sttWarmupWavSha256 =",
  "stackchan.rvc-directml-worker.health.v1",
  "synthesis_ready",
  "-RequireVoiceWorkerSynthesis",
  "workerSynthesisReady =",
  "rvc_production_tts_client.py",
  "[switch]`$EnableResearch",
  "[int]`$ConversationMaxContextTurns = 24",
  "[int]`$ConversationMaxContextChars = 160",
  "[switch]`$DisableEpisodeDistillation",
  "[switch]`$EnableFaceVision",
  '[string]$RoomVisionModel = "gemma4:e2b-it-qat"',
  "[string]`$SearxngUrl",
  "-EnableResearch -SearxngUrl",
  "-EnableDashboard",
  "-DashboardPort `$DashboardPort",
  "dashboardUrl =",
  "stackchan.pc-brain-motion-default-off.v1",
  "api/motion",
  '"X-Stackchan-Dashboard" = "1"',
  '''{"enabled":false}''',
  "motion-default-off.json",
  "MotionDefaultOffVerified",
  "servo_torque_enabled -eq `$false",
  "DirectML startup could not verify motion, servo rail, and torque off:",
  "motionDefaultOffVerified =",
  "start_local_vision.ps1",
  "faceVisionReady =",
  "camera_host_frame_requests",
  "camera_host_target_updates",
  "Local vision did not advance authenticated frame and target counters.",
  "researchEnabled = [bool]`$EnableResearch",
  "-ConversationMaxContextTurns `$ConversationMaxContextTurns",
  "-ConversationMaxContextChars `$ConversationMaxContextChars",
  "-EnableEpisodeDistillation",
  "episodeDistillationEnabled =",
  "-StreamTtsPhrases",
  "-EnableAudioDownlink",
  "-InProcessOllamaRunner",
  "-InProcessDirectMlTts",
  "-DownlinkAudioChunkBytes 4096",
  "-DownlinkBinaryFrameDelayMs 70",
  "`$ErrorActionPreference = 'Stop'",
  '-ExpectedDisableAudioDownlink `$false',
  '-ExpectedAudioPlaybackEnabled `$true',
  '-ExpectedStreamTtsPhrases `$true',
  '-ExpectedInProcessOllamaRunner `$true',
  '-ExpectedInProcessDirectMlTts `$true',
  '-EncodedCommand $runtimeEncoded',
  "bridge_state -eq `"ready`""
)) {
  if (-not $text.Contains($required)) {
    throw "DirectML launcher missing contract token: $required"
  }
}

$stopIndex = $text.IndexOf("`nStop-ExistingBridge")
$repairIndex = $text.IndexOf("memory_maintenance.py --memory-file `$MemoryFile --apply")
if ($stopIndex -lt 0 -or $repairIndex -lt 0 -or $stopIndex -gt $repairIndex) {
  throw "Memory repair must happen only after the old bridge is stopped."
}

$workerReadyIndex = $text.IndexOf('worker-health.json')
if ($workerReadyIndex -lt 0 -or $stopIndex -lt $workerReadyIndex) {
  throw "DirectML must pass health before the existing bridge is stopped."
}

$bridgeReadyIndex = $text.IndexOf('DirectML bridge did not reconnect to Stackchan')
$motionStopIndex = $text.IndexOf('$MotionStopUrl =')
$visionReadyIndex = $text.IndexOf('$VisionReady =')
if ($bridgeReadyIndex -lt 0 -or $motionStopIndex -lt $bridgeReadyIndex -or
    $visionReadyIndex -lt $motionStopIndex) {
  throw "Motion default-off verification must run after bridge reconnect and before vision readiness."
}

$researchPreflightIndex = $text.IndexOf('research-preflight.json')
$workerStartIndex = $text.IndexOf('start_voice_v2_directml_worker.ps1')
if ($researchPreflightIndex -lt 0 -or $workerStartIndex -lt 0 -or
    $researchPreflightIndex -gt $workerStartIndex -or $researchPreflightIndex -gt $stopIndex) {
  throw "Research must pass before workers start or the existing bridge is stopped."
}

if ($text -match "Get-CimInstance Win32_Process\s*\|\s*Stop-Process") {
  throw "Launcher must not broadly stop every discovered process."
}

$startupGuardIndex = $text.IndexOf('$BridgeStartupReady = $false')
$bridgeStartIndex = $text.IndexOf('$bridgeChild = Invoke-EncodedChildPowerShell')
$startupSuccessIndex = $text.IndexOf('$BridgeStartupReady = $true')
$startupFinallyIndex = $text.IndexOf('} finally {', $startupSuccessIndex)
$failureCleanupIndex = $text.IndexOf('Stop-ExistingBridge', $startupFinallyIndex)
if ($startupGuardIndex -lt 0 -or $bridgeStartIndex -lt $startupGuardIndex -or
    $startupSuccessIndex -lt $bridgeStartIndex -or $startupFinallyIndex -lt $startupSuccessIndex -or
    $failureCleanupIndex -lt $startupFinallyIndex) {
  throw "A failed production launch must stop the Stackchan bridge listener."
}

foreach ($required in @(
  "[switch]`$EnableResearch",
  "[switch]`$EnableEpisodeDistillation",
  "[string]`$SearxngUrl",
  '"--enable-research"',
  '"--conversation-max-context-turns", "$ConversationMaxContextTurns"',
  '"--conversation-max-context-chars", "$ConversationMaxContextChars"',
  '"--enable-episode-distillation"',
  '"--searxng-url", $SearxngUrl',
  "[string]`$SttServerUrl",
  '"--stt-server-url", $SttServerUrl'
  "[string]`$SttRestartCommand",
  '"--stt-restart-command", $SttRestartCommand',
  '"--stt-health-interval-s", "$SttHealthIntervalSeconds"',
  "[switch]`$InProcessOllamaRunner",
  "[switch]`$InProcessDirectMlTts",
  '"--in-process-ollama-runner"',
  '"--in-process-directml-tts"',
  '"--room-vision-command", $RoomVisionCommand'
  '"--camera-pairing-code-file", $CameraPairingCodeFile'
  "stackchan.pc-brain-runtime.v1",
  "runtime_manifest.json",
  "sourceWorktreeClean",
  "bridgePid"
)) {
  if (-not $baseText.Contains($required)) {
    throw "Base PC brain launcher missing research contract token: $required"
  }
}

$roomEnabledIndex = $baseText.IndexOf('if ($EnableRoomObservation)')
$pairingArgIndex = $baseText.IndexOf('"--camera-pairing-code-file", $CameraPairingCodeFile')
if ($roomEnabledIndex -lt 0 -or $pairingArgIndex -lt 0 -or
    $baseText.Substring($roomEnabledIndex, $pairingArgIndex - $roomEnabledIndex) -match
      'camera-pairing-code-file') {
  throw "Camera pairing must configure the disabled room runtime independently of its initial on/off state."
}

Write-Host "DirectML PC brain launcher contract tests passed."
