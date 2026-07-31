param(
  [string]$DeviceHost = "192.168.1.238",
  [int]$BridgePort = 8765,
  [int]$WorkerPort = 5059,
  [int]$SttServerPort = 5061,
  [int]$SttThreads = 12,
  [string]$SttExecutablePath = "",
  [string]$SttModelPath = "",
  [string]$SttInitialPrompt = "Stackchan,Gemma,Rhea,SearXNG,servo,telemetry,companion,bridge,camera,persona",
  [ValidateSet("auto", "cpu", "vulkan")]
  [string]$SttBackend = "auto",
  [string]$SttWarmupWavPath = "docs\media\voice\stackchan_spark_greeting.wav",
  [int]$ReconnectTimeoutSeconds = 90,
  [string]$MemoryFile = "output\pc-brain\latest\memory.json",
  [switch]$EnableResearch,
  [string]$SearxngUrl = "http://127.0.0.1:8080",
  [switch]$EnableConversationV2,
  [int]$ConversationMaxContextTurns = 24,
  [int]$ConversationMaxContextChars = 160,
  [switch]$DisableEpisodeDistillation,
  [switch]$EnableInitiative,
  [switch]$EnableRoomObservation,
  [int]$RoomObservationIntervalSeconds = 300,
  [string]$RoomVisionModel = "gemma4:e2b-it-qat",
  [string]$CameraPairingCodeFile = "",
  [switch]$EnableFaceVision,
  [string]$VisionPython = "",
  [double]$FaceVisionIntervalSeconds = 1.0,
  [int]$DashboardPort = 8766,
  [string]$EvidenceRoot = "",
  [switch]$RepairMemory,
  [switch]$StopWarmRocmWorker,
  [switch]$Json
)

$ErrorActionPreference = "Stop"
$RepoRoot = Resolve-Path (Join-Path $PSScriptRoot "..")
Set-Location $RepoRoot

if ([string]::IsNullOrWhiteSpace($EvidenceRoot)) {
  $EvidenceRoot = "output\pc-brain\directml-production-start-" + (Get-Date -Format "yyyyMMdd-HHmmss")
}
New-Item -ItemType Directory -Force -Path $EvidenceRoot | Out-Null
$EvidencePath = (Resolve-Path $EvidenceRoot).Path
$StartFaceVision = [bool]($EnableFaceVision -or $EnableRoomObservation)
$EpisodeDistillationEnabled = [bool](
  $EnableConversationV2 -and -not $DisableEpisodeDistillation
)
if ($StartFaceVision -and [string]::IsNullOrWhiteSpace($CameraPairingCodeFile)) {
  throw "Face or room vision requires CameraPairingCodeFile."
}
if (-not [string]::IsNullOrWhiteSpace($CameraPairingCodeFile) -and
    -not (Test-Path -LiteralPath $CameraPairingCodeFile -PathType Leaf)) {
  throw "CameraPairingCodeFile is missing."
}
if ($SttThreads -lt 1 -or $SttThreads -gt 32) {
  throw "SttThreads must be between 1 and 32."
}

function Stop-ExistingBridge {
  $listeners = @(Get-NetTCPConnection -LocalPort $BridgePort -State Listen -ErrorAction SilentlyContinue)
  foreach ($listener in $listeners) {
    $process = Get-CimInstance Win32_Process -Filter "ProcessId=$($listener.OwningProcess)" -ErrorAction SilentlyContinue
    if ($null -eq $process -or [string]$process.CommandLine -notmatch "bridge[\\/]lan_service\.py") {
      Write-Host "Preserving non-Stackchan listener PID $($listener.OwningProcess) on port $BridgePort."
      continue
    }
    Stop-Process -Id $listener.OwningProcess -Force
  }
  $deadline = (Get-Date).AddSeconds(10)
  while ((Get-Date) -lt $deadline) {
    $stackchanListeners = @(
      Get-NetTCPConnection -LocalPort $BridgePort -State Listen -ErrorAction SilentlyContinue |
        Where-Object {
          $candidate = Get-CimInstance Win32_Process `
            -Filter "ProcessId=$($_.OwningProcess)" -ErrorAction SilentlyContinue
          $null -ne $candidate -and
            [string]$candidate.CommandLine -match "bridge[\\/]lan_service\.py"
        }
    )
    if ($stackchanListeners.Count -eq 0) { break }
    Start-Sleep -Milliseconds 250
  }
  $remainingStackchanListeners = @(
    Get-NetTCPConnection -LocalPort $BridgePort -State Listen -ErrorAction SilentlyContinue |
      Where-Object {
        $candidate = Get-CimInstance Win32_Process `
          -Filter "ProcessId=$($_.OwningProcess)" -ErrorAction SilentlyContinue
        $null -ne $candidate -and
          [string]$candidate.CommandLine -match "bridge[\\/]lan_service\.py"
      }
  )
  if ($remainingStackchanListeners.Count -gt 0) {
    throw "Bridge port $BridgePort did not become free."
  }
}

function Invoke-EncodedChildPowerShell {
  param(
    [string]$ScriptBody,
    [string]$StdoutPath,
    [string]$StderrPath
  )
  $encoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($ScriptBody))
  $process = Start-Process -FilePath "powershell.exe" -ArgumentList @(
    "-NoProfile",
    "-ExecutionPolicy", "Bypass",
    "-EncodedCommand", $encoded
  ) -WorkingDirectory $RepoRoot -RedirectStandardOutput $StdoutPath `
    -RedirectStandardError $StderrPath -WindowStyle Hidden -PassThru
  $process.WaitForExit()
  $process.Refresh()
  $exitCode = if ($process.HasExited) { [int]$process.ExitCode } else { -1 }
  return [pscustomobject]@{
    exitCode = $exitCode
    stdout = if (Test-Path -LiteralPath $StdoutPath) { Get-Content -LiteralPath $StdoutPath } else { @() }
    stderr = if (Test-Path -LiteralPath $StderrPath) { Get-Content -LiteralPath $StderrPath } else { @() }
  }
}

$ResearchGate = $null
if ($EnableResearch) {
  $researchChecker = (Resolve-Path (Join-Path $PSScriptRoot "check_local_research.ps1")).Path
  $researchOutput = & powershell.exe -NoProfile -ExecutionPolicy Bypass `
    -File $researchChecker -SearxngUrl $SearxngUrl -Json 2>&1
  $researchExit = $LASTEXITCODE
  $researchEvidence = Join-Path $EvidencePath "research-preflight.json"
  $researchOutput | Set-Content -LiteralPath $researchEvidence -Encoding UTF8
  try {
    $ResearchGate = ($researchOutput -join "`n") | ConvertFrom-Json
  } catch {
    throw "Local research preflight returned invalid structured evidence."
  }
  if ($researchExit -ne 0 -or -not [bool]$ResearchGate.pass) {
    throw "Local research preflight failed: $([string]$ResearchGate.error). $([string]$ResearchGate.remediation)"
  }
}

$workerStarter = (Resolve-Path (Join-Path $PSScriptRoot "start_voice_v2_directml_worker.ps1")).Path.Replace("'", "''")
$workerScript = "`$ProgressPreference = 'SilentlyContinue'; & '$workerStarter' -StopExisting -Background -Port $WorkerPort -F0Method pm -IndexRate 0.62"
$workerChild = Invoke-EncodedChildPowerShell -ScriptBody $workerScript `
  -StdoutPath (Join-Path $EvidencePath "worker-start.json") `
  -StderrPath (Join-Path $EvidencePath "worker-start.err.log")
if ($workerChild.exitCode -ne 0) {
  throw "DirectML worker start failed with exit $($workerChild.exitCode): $($workerChild.stderr -join ' ')"
}

$WorkerUrl = "http://127.0.0.1`:$WorkerPort"
$workerDeadline = (Get-Date).AddSeconds($ReconnectTimeoutSeconds)
$WorkerHealth = $null
while ((Get-Date) -lt $workerDeadline) {
  try { $WorkerHealth = Invoke-RestMethod -Uri "$WorkerUrl/health" -TimeoutSec 5 } catch { $WorkerHealth = $null }
  if ($WorkerHealth -and [bool]$WorkerHealth.ready -and
      [bool]$WorkerHealth.synthesis_ready -and
      [string]$WorkerHealth.schema -eq "stackchan.rvc-directml-worker.health.v1") {
    break
  }
  Start-Sleep -Seconds 1
}
if ($null -eq $WorkerHealth -or -not [bool]$WorkerHealth.ready -or
    -not [bool]$WorkerHealth.synthesis_ready) {
  throw "DirectML worker did not become ready at $WorkerUrl."
}
$WorkerHealth | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath (Join-Path $EvidencePath "worker-health.json") -Encoding UTF8

if ([string]::IsNullOrWhiteSpace($SttExecutablePath)) {
  $SttExecutablePath = @(
    (Join-Path $RepoRoot "output\local-tools\whisper.cpp-vulkan\Release\whisper-server.exe"),
    (Join-Path $RepoRoot "output\local-tools\whisper.cpp-blas\Release\whisper-server.exe"),
    (Join-Path $RepoRoot "output\local-tools\whisper.cpp\Release\whisper-server.exe")
  ) | Where-Object { Test-Path -LiteralPath $_ -PathType Leaf } | Select-Object -First 1
}
if ([string]::IsNullOrWhiteSpace($SttModelPath)) {
  $SttModelPath = @(
    (Join-Path $RepoRoot "output\local-tools\whisper.cpp-vulkan\models\ggml-small.en.bin"),
    (Join-Path $RepoRoot "output\local-tools\whisper.cpp-blas\models\ggml-small.en.bin"),
    (Join-Path $RepoRoot "output\local-tools\whisper.cpp\models\ggml-small.en.bin")
  ) | Where-Object { Test-Path -LiteralPath $_ -PathType Leaf } | Select-Object -First 1
}
if (-not $SttExecutablePath -or
    -not (Test-Path -LiteralPath $SttExecutablePath -PathType Leaf)) {
  throw "Production STT requires whisper-server.exe. Run tools\setup_whisper_cpp.ps1 -Backend vulkan -Model small.en."
}
if (-not $SttModelPath -or -not (Test-Path -LiteralPath $SttModelPath -PathType Leaf)) {
  throw "Production STT requires ggml-small.en.bin. Run tools\setup_whisper_cpp.ps1 -Backend vulkan -Model small.en."
}
$SttExecutablePath = (Resolve-Path $SttExecutablePath).Path
$SttModelPath = (Resolve-Path $SttModelPath).Path
$SttCliPath = Join-Path (Split-Path -Parent $SttExecutablePath) "whisper-cli.exe"
if (-not (Test-Path -LiteralPath $SttCliPath -PathType Leaf)) {
  throw "Production STT recovery requires whisper-cli.exe beside whisper-server.exe."
}
$SttCliPath = (Resolve-Path $SttCliPath).Path
$ExpectedSmallEnSha256 = "c6138d6d58ecc8322097e0f987c32f1be8bb0a18532a3f88f734d1bbf9c41e5d"
$ActualSttModelSha256 = (Get-FileHash -LiteralPath $SttModelPath -Algorithm SHA256).Hash.ToLowerInvariant()
if ((Split-Path -Leaf $SttModelPath) -ne "ggml-small.en.bin" -or
    $ActualSttModelSha256 -ne $ExpectedSmallEnSha256) {
  throw "Production STT requires the pinned full ggml-small.en.bin model."
}
$ResolvedSttBackend = if ($SttBackend -ne "auto") {
  $SttBackend
} elseif ($SttExecutablePath -match "(?i)whisper\.cpp-vulkan") {
  "vulkan"
} else {
  "cpu"
}
$ResolvedSttWarmupWavPath = if ([IO.Path]::IsPathRooted($SttWarmupWavPath)) {
  $SttWarmupWavPath
} else {
  Join-Path $RepoRoot $SttWarmupWavPath
}
if (-not (Test-Path -LiteralPath $ResolvedSttWarmupWavPath -PathType Leaf)) {
  throw "Production STT warmup WAV is missing: $ResolvedSttWarmupWavPath"
}
$ResolvedSttWarmupWavPath = (Resolve-Path $ResolvedSttWarmupWavPath).Path
$escapedSttExecutable = $SttExecutablePath.Replace("'", "''")
$escapedSttModel = $SttModelPath.Replace("'", "''")
$escapedSttPrompt = $SttInitialPrompt.Replace("'", "''")
$escapedSttWarmupWav = $ResolvedSttWarmupWavPath.Replace("'", "''")
$sttStarter = (Resolve-Path (Join-Path $PSScriptRoot "start_whisper_server.ps1")).Path.Replace("'", "''")
$sttRecoveryOutput = (Join-Path $RepoRoot "output\pc-brain\whisper-server").Replace("'", "''")
$sttRestartScript = "`$ProgressPreference = 'SilentlyContinue'; & '$sttStarter' " +
  "-Port $SttServerPort -Threads $SttThreads -ExecutablePath '$escapedSttExecutable' " +
  "-ModelPath '$escapedSttModel' -InitialPrompt '$escapedSttPrompt' " +
  "-Backend '$ResolvedSttBackend' -WarmupWavPath '$escapedSttWarmupWav' " +
  "-OutputDir '$sttRecoveryOutput' -StopExisting -Json | Out-Null"
$sttRestartEncoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($sttRestartScript))
$SttRestartCommand = "powershell.exe -NoProfile -ExecutionPolicy Bypass -EncodedCommand $sttRestartEncoded"
$sttScript = "`$ProgressPreference = 'SilentlyContinue'; & '$sttStarter' " +
  "-Port $SttServerPort -Threads $SttThreads -ExecutablePath '$escapedSttExecutable' " +
  "-ModelPath '$escapedSttModel' -InitialPrompt '$escapedSttPrompt' " +
  "-Backend '$ResolvedSttBackend' -WarmupWavPath '$escapedSttWarmupWav' -StopExisting -Json"
$sttChild = Invoke-EncodedChildPowerShell -ScriptBody $sttScript `
  -StdoutPath (Join-Path $EvidencePath "stt-server-start.json") `
  -StderrPath (Join-Path $EvidencePath "stt-server-start.err.log")
if ($sttChild.exitCode -ne 0) {
  throw "Whisper server start failed with exit $($sttChild.exitCode): $($sttChild.stderr -join ' ')"
}
$SttStart = try {
  ($sttChild.stdout -join "`n") | ConvertFrom-Json
} catch {
  throw "Whisper server start returned invalid structured evidence."
}
if ([string]$SttStart.status -ne "ready" -or
    -not [bool]$SttStart.configVerified -or
    -not [bool]$SttStart.backendVerified -or
    -not [bool]$SttStart.warmupVerified -or
    [string]$SttStart.backend -ne $ResolvedSttBackend -or
    [int]$SttStart.threads -ne $SttThreads -or
    [string]$SttStart.model -ne (Split-Path -Leaf $SttModelPath) -or
    [string]$SttStart.modelSha256 -ne $ExpectedSmallEnSha256) {
  throw "Whisper server did not prove the requested production STT configuration."
}
$SttServerUrl = "http://127.0.0.1`:$SttServerPort"
$SttHealth = try { Invoke-RestMethod -Uri "$SttServerUrl/health" -TimeoutSec 5 } catch { $null }
if (-not $SttHealth -or [string]$SttHealth.status -ne "ok") {
  throw "Whisper server did not become ready at $SttServerUrl."
}
$SttHealth | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath (Join-Path $EvidencePath "stt-server-health.json") -Encoding UTF8

$escapedDeviceHost = $DeviceHost.Replace("'", "''")
$VisionStart = $null
$VisionPid = 0
if ($StartFaceVision) {
  $visionStarter = (Resolve-Path (Join-Path $PSScriptRoot "start_local_vision.ps1")).Path.Replace("'", "''")
  $escapedPairingCodeFile = $CameraPairingCodeFile.Replace("'", "''")
  $escapedVisionPython = $VisionPython.Replace("'", "''")
  $visionScript = "`$ErrorActionPreference = 'Stop'; `$ProgressPreference = 'SilentlyContinue'; " +
    "& '$visionStarter' -DeviceHost '$escapedDeviceHost' -RobotHttpPort 8789 " +
    "-PairingCodeFile '$escapedPairingCodeFile' -IntervalSeconds $FaceVisionIntervalSeconds " +
    "-StopExisting -Background -Json"
  if (-not [string]::IsNullOrWhiteSpace($VisionPython)) {
    $visionScript += " -PythonExe '$escapedVisionPython'"
  }
  $visionChild = Invoke-EncodedChildPowerShell -ScriptBody $visionScript `
    -StdoutPath (Join-Path $EvidencePath "vision-start.json") `
    -StderrPath (Join-Path $EvidencePath "vision-start.err.log")
  if ($visionChild.exitCode -ne 0) {
    throw "Local vision start failed with exit $($visionChild.exitCode): $($visionChild.stderr -join ' ')"
  }
  $VisionStart = ($visionChild.stdout -join "`n") | ConvertFrom-Json
  if ([string]$VisionStart.status -ne "running" -or [int]$VisionStart.pid -le 0) {
    throw "Local vision launcher did not report a running worker."
  }
  $VisionPid = [int]$VisionStart.pid
}

Stop-ExistingBridge

$MemoryReport = $null
if ($RepairMemory) {
  $memoryOutput = & python bridge\memory_maintenance.py --memory-file $MemoryFile --apply
  if ($LASTEXITCODE -ne 0) { throw "Memory maintenance failed with exit $LASTEXITCODE." }
  $MemoryReport = $memoryOutput | ConvertFrom-Json
  $memoryOutput | Set-Content -LiteralPath (Join-Path $EvidencePath "memory-maintenance.json") -Encoding UTF8
}

$env:STACKCHAN_RVC_DIRECTML_WORKER_URL = $WorkerUrl
$bridgeStarter = (Resolve-Path (Join-Path $PSScriptRoot "start_pc_brain.ps1")).Path.Replace("'", "''")
$escapedMemoryFile = $MemoryFile.Replace("'", "''")
$escapedSearxngUrl = $SearxngUrl.Replace("'", "''")
$escapedSttCli = $SttCliPath.Replace("'", "''")
$escapedSttRestartCommand = $SttRestartCommand.Replace("'", "''")
$bridgeScript = "`$ErrorActionPreference = 'Stop'; `$ProgressPreference = 'SilentlyContinue'; " +
  "`$env:STACKCHAN_RVC_DIRECTML_WORKER_URL = '$WorkerUrl'; " +
  "`$env:STACKCHAN_WHISPER_CPP_EXE = '$escapedSttCli'; " +
  "`$env:STACKCHAN_WHISPER_MODEL = '$escapedSttModel'; " +
  "`$env:STACKCHAN_WHISPER_THREADS = '$SttThreads'; " +
  "& '$bridgeStarter' -Background -EnableAudioDownlink -StreamTtsPhrases " +
  "-InProcessOllamaRunner -InProcessDirectMlTts " +
  "-Port $BridgePort -MemoryFile '$escapedMemoryFile' " +
  "-SttServerUrl '$SttServerUrl' -SttRestartCommand '$escapedSttRestartCommand' " +
  "-SttHealthIntervalSeconds 2 " +
  "-EnableDashboard -DashboardHost '127.0.0.1' -DashboardPort $DashboardPort -RobotHost '$escapedDeviceHost' " +
  "-TtsCommand 'python bridge\rvc_production_tts_client.py' " +
  "-TtsVoice 'stackchan-rvc-directml-v2' " +
  "-TtsPhraseMaxChars 96 -DownlinkAudioChunkBytes 4096 " +
  "-DownlinkBinaryFrameDelayMs 70 -DownlinkTextFrameDelayMs 40"
if ($EnableResearch) {
  $bridgeScript += " -EnableResearch -SearxngUrl '$escapedSearxngUrl'"
}
if ($EnableConversationV2) {
  $bridgeScript += " -EnableConversationV2 -ConversationMaxContextTurns $ConversationMaxContextTurns" +
    " -ConversationMaxContextChars $ConversationMaxContextChars"
}
if ($EpisodeDistillationEnabled) {
  $bridgeScript += " -EnableEpisodeDistillation"
}
if ($EnableInitiative) {
  $bridgeScript += " -EnableInitiative"
}
if ($EnableRoomObservation) {
  $bridgeScript += " -EnableRoomObservation -RoomObservationIntervalSeconds $RoomObservationIntervalSeconds"
}
if (-not [string]::IsNullOrWhiteSpace($RoomVisionModel)) {
  $escapedRoomVisionModel = $RoomVisionModel.Replace("'", "''")
  $bridgeScript += " -RoomVisionModel '$escapedRoomVisionModel'"
}
if (-not [string]::IsNullOrWhiteSpace($CameraPairingCodeFile)) {
  $escapedPairingCodeFile = $CameraPairingCodeFile.Replace("'", "''")
  $bridgeScript += " -CameraPairingCodeFile '$escapedPairingCodeFile'"
}
$BridgeStartupReady = $false
try {
$bridgeChild = Invoke-EncodedChildPowerShell -ScriptBody $bridgeScript `
  -StdoutPath (Join-Path $EvidencePath "bridge-start.txt") `
  -StderrPath (Join-Path $EvidencePath "bridge-start.err.log")
if ($bridgeChild.exitCode -ne 0) {
  throw "DirectML PC brain start failed with exit $($bridgeChild.exitCode): $($bridgeChild.stderr -join ' ')"
}

$BridgePid = [int](Get-Content -LiteralPath "output\pc-brain\latest\lan_service.pid" -Raw)
$DebugUrl = "http://$DeviceHost`:8789/debug"
$readyDeadline = (Get-Date).AddSeconds($ReconnectTimeoutSeconds)
$Debug = $null
$SocketReady = $false
while ((Get-Date) -lt $readyDeadline) {
  $socket = Get-NetTCPConnection -LocalPort $BridgePort -State Established -ErrorAction SilentlyContinue |
    Where-Object { $_.OwningProcess -eq $BridgePid -and $_.RemoteAddress -eq $DeviceHost } |
    Select-Object -First 1
  $SocketReady = [bool]$socket
  try { $Debug = Invoke-RestMethod -Uri $DebugUrl -TimeoutSec 5 } catch { $Debug = $null }
  if ($SocketReady -and $Debug -and $Debug.network_state -eq "connected" -and
      $Debug.bridge_state -eq "ready") {
    break
  }
  Start-Sleep -Seconds 2
}
if (-not $SocketReady -or -not $Debug -or $Debug.bridge_state -ne "ready") {
  throw "DirectML bridge did not reconnect to Stackchan within $ReconnectTimeoutSeconds seconds."
}

$MotionStopUrl = "http://127.0.0.1`:$DashboardPort/api/motion"
$MotionStopResult = $null
$MotionStopError = ""
try {
  $MotionStopResult = Invoke-RestMethod -Method Post -Uri $MotionStopUrl `
    -Headers @{ "X-Stackchan-Dashboard" = "1" } `
    -ContentType "application/json" -Body '{"enabled":false}' -TimeoutSec 10
} catch {
  $MotionStopError = $_.Exception.Message
}
try {
  $Debug = Invoke-RestMethod -Uri $DebugUrl -TimeoutSec 5
} catch {
  $Debug = $null
  if ([string]::IsNullOrWhiteSpace($MotionStopError)) {
    $MotionStopError = $_.Exception.Message
  }
}
$MotionDefaultOffVerified = (
  $null -ne $MotionStopResult -and
  [bool]$MotionStopResult.ok -and
  [bool]$MotionStopResult.accepted -and
  [bool]$MotionStopResult.verified -and
  $null -ne $Debug -and
  $Debug.motion_enabled -eq $false -and
  $Debug.servo_rail_enabled -eq $false -and
  $Debug.servo_torque_enabled -eq $false
)
$MotionDefaultOffEvidence = [ordered]@{
  schema = "stackchan.pc-brain-motion-default-off.v1"
  generatedAt = (Get-Date).ToUniversalTime().ToString("o")
  commandUrl = $MotionStopUrl
  commandSent = if ($MotionStopResult) { [bool]$MotionStopResult.commandSent } else { $false }
  accepted = if ($MotionStopResult) { [bool]$MotionStopResult.accepted } else { $false }
  dashboardVerified = if ($MotionStopResult) { [bool]$MotionStopResult.verified } else { $false }
  firmwareVerified = $MotionDefaultOffVerified
  motionEnabled = if ($Debug) { [bool]$Debug.motion_enabled } else { $null }
  servoRailEnabled = if ($Debug) { [bool]$Debug.servo_rail_enabled } else { $null }
  servoTorqueEnabled = if ($Debug) { [bool]$Debug.servo_torque_enabled } else { $null }
  error = $MotionStopError
}
$MotionDefaultOffEvidence | ConvertTo-Json -Depth 5 | Set-Content `
  -LiteralPath (Join-Path $EvidencePath "motion-default-off.json") -Encoding UTF8
if (-not $MotionDefaultOffVerified) {
  throw "DirectML startup could not verify motion, servo rail, and torque off: $MotionStopError"
}

$VisionReady = -not $StartFaceVision
$VisionBefore = $null
$VisionAfter = $null
if ($StartFaceVision) {
  $VisionBefore = $Debug
  $visionDeadline = (Get-Date).AddSeconds([Math]::Min(30, $ReconnectTimeoutSeconds))
  while ((Get-Date) -lt $visionDeadline) {
    Start-Sleep -Seconds 1
    try { $VisionAfter = Invoke-RestMethod -Uri $DebugUrl -TimeoutSec 5 } catch { $VisionAfter = $null }
    $visionProcess = Get-Process -Id $VisionPid -ErrorAction SilentlyContinue
    if ($visionProcess -and $VisionAfter -and
        [int64]$VisionAfter.camera_host_frame_requests -gt
          [int64]$VisionBefore.camera_host_frame_requests -and
        [int64]$VisionAfter.camera_host_target_updates -gt
          [int64]$VisionBefore.camera_host_target_updates -and
        [int64]$VisionAfter.camera_host_frame_failures -eq
          [int64]$VisionBefore.camera_host_frame_failures -and
        [int64]$VisionAfter.camera_host_auth_failures -eq
          [int64]$VisionBefore.camera_host_auth_failures) {
      $VisionReady = $true
      break
    }
  }
  [ordered]@{
    schema = "stackchan.local-vision-runtime-check.v1"
    ready = $VisionReady
    pid = $VisionPid
    before = $VisionBefore
    after = $VisionAfter
  } | ConvertTo-Json -Depth 12 | Set-Content `
    -LiteralPath (Join-Path $EvidencePath "vision-runtime-check.json") -Encoding UTF8
  if (-not $VisionReady) {
    throw "Local vision did not advance authenticated frame and target counters."
  }
}

$runtimeChecker = (Resolve-Path (Join-Path $PSScriptRoot "check_pc_brain_runtime.ps1")).Path
$escapedRepoRoot = $RepoRoot.Path.Replace("'", "''")
$escapedRuntimeChecker = $runtimeChecker.Replace("'", "''")
$escapedWorkerUrl = $WorkerUrl.Replace("'", "''")
$runtimeScript = "Set-Location '$escapedRepoRoot'; " +
  "& '$escapedRuntimeChecker' -Port $BridgePort -DeviceHost '$escapedDeviceHost' " +
  "-ExpectedTtsCommand 'bridge\rvc_production_tts_client.py' " +
  "-ExpectedTtsVoice 'stackchan-rvc-directml-v2' " +
  "-ExpectedDownlinkBinaryFrameDelayMs 70 " +
  "-ExpectedDisableAudioDownlink `$false " +
  "-ExpectedAudioPlaybackEnabled `$true " +
  "-ExpectedStreamTtsPhrases `$true " +
  "-ExpectedInProcessOllamaRunner `$true " +
  "-ExpectedInProcessDirectMlTts `$true " +
  "-VoiceWorkerUrl '$escapedWorkerUrl' " +
  "-ExpectedVoiceWorkerSchema 'stackchan.rvc-directml-worker.health.v1' " +
  "-RequireVoiceWorkerSynthesis -Json"
$runtimeEncoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($runtimeScript))
$runtimeOutput = & powershell.exe -NoProfile -ExecutionPolicy Bypass -EncodedCommand $runtimeEncoded
$runtimeExit = $LASTEXITCODE
$runtimeOutput | Set-Content -LiteralPath (Join-Path $EvidencePath "runtime-check.json") -Encoding UTF8
if ($runtimeExit -ne 0) { throw "DirectML runtime check failed with exit $runtimeExit." }
$RuntimeCheck = $runtimeOutput | ConvertFrom-Json

if ($StopWarmRocmWorker) {
  $warmListener = Get-NetTCPConnection -LocalPort 5055 -State Listen -ErrorAction SilentlyContinue | Select-Object -First 1
  if ($warmListener) {
    $warmProcess = Get-CimInstance Win32_Process -Filter "ProcessId=$($warmListener.OwningProcess)" -ErrorAction SilentlyContinue
    if ($warmProcess -and [string]$warmProcess.CommandLine -match "rvc_worker_service\.py") {
      Stop-Process -Id $warmListener.OwningProcess -Force
    }
  }
}

$Result = [ordered]@{
  schema = "stackchan.pc-brain-directml-start.v1"
  status = "ready"
  generatedAt = (Get-Date).ToUniversalTime().ToString("o")
  evidenceRoot = $EvidencePath
  bridgePid = $BridgePid
  bridgePort = $BridgePort
  dashboardUrl = "http://127.0.0.1`:$DashboardPort/"
  workerUrl = $WorkerUrl
  workerSchema = $WorkerHealth.schema
  workerDevice = $WorkerHealth.device
  workerMethod = $WorkerHealth.method
  workerSynthesisReady = [bool]$WorkerHealth.synthesis_ready
  workerBaseTtsBackend = [string]$WorkerHealth.base_tts_backend
  sttServerUrl = $SttServerUrl
  sttServerReady = [string]$SttHealth.status -eq "ok"
  sttExecutable = [string]$SttStart.executable
  sttExecutableSha256 = [string]$SttStart.executableSha256
  sttFallbackExecutable = $SttCliPath
  sttFallbackExecutableSha256 = (Get-FileHash -LiteralPath $SttCliPath -Algorithm SHA256).Hash.ToLowerInvariant()
  sttSupervised = $true
  sttModel = [string]$SttStart.model
  sttModelSha256 = [string]$SttStart.modelSha256
  sttThreads = [int]$SttStart.threads
  sttInitialPrompt = [string]$SttStart.initialPrompt
  sttConfigVerified = [bool]$SttStart.configVerified
  sttBackend = [string]$SttStart.backend
  sttBackendDevice = $SttStart.backendDevice
  sttBackendVerified = [bool]$SttStart.backendVerified
  sttWarmupVerified = [bool]$SttStart.warmupVerified
  sttWarmupElapsedMs = $SttStart.warmupElapsedMs
  sttWarmupWavSha256 = [string]$SttStart.warmupWavSha256
  faceVisionEnabled = $StartFaceVision
  faceVisionReady = $VisionReady
  faceVisionPid = if ($StartFaceVision) { $VisionPid } else { $null }
  faceVisionFrameRequests = if ($VisionAfter) {
    [int64]$VisionAfter.camera_host_frame_requests - [int64]$VisionBefore.camera_host_frame_requests
  } else {
    0
  }
  faceVisionTargetUpdates = if ($VisionAfter) {
    [int64]$VisionAfter.camera_host_target_updates - [int64]$VisionBefore.camera_host_target_updates
  } else {
    0
  }
  streamTtsPhrases = $true
  researchEnabled = [bool]$EnableResearch
  researchGateStatus = if ($ResearchGate) { [string]$ResearchGate.status } else { $null }
  conversationV2Enabled = [bool]$EnableConversationV2
  conversationMaxContextTurns = if ($EnableConversationV2) { $ConversationMaxContextTurns } else { 0 }
  episodeDistillationEnabled = $EpisodeDistillationEnabled
  initiativeEnabled = [bool]$EnableInitiative
  roomObservationEnabled = [bool]$EnableRoomObservation
  searxngUrl = if ($EnableResearch) { $SearxngUrl } else { $null }
  ttsCommand = "python bridge\rvc_production_tts_client.py"
  memoryMaintenance = $MemoryReport
  robotNetwork = $Debug.network_state
  robotBridge = $Debug.bridge_state
  robotMotion = [bool]$Debug.motion_enabled
  robotServoRail = [bool]$Debug.servo_rail_enabled
  robotServoTorque = [bool]$Debug.servo_torque_enabled
  motionDefaultOffVerified = $MotionDefaultOffVerified
  motionDefaultOffEvidence = (Join-Path $EvidencePath "motion-default-off.json")
  runtimeCheckStatus = $RuntimeCheck.status
  warmRocmWorkerStopped = [bool]$StopWarmRocmWorker
}
$Result | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath (Join-Path $EvidencePath "result.json") -Encoding UTF8
$BridgeStartupReady = $true
if ($Json) { $Result | ConvertTo-Json -Depth 8 } else { Write-Host "DirectML PC brain ready: PID $BridgePid" }
} finally {
  if (-not $BridgeStartupReady) {
    Stop-ExistingBridge
  }
}
