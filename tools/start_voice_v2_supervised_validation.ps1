param(
  [string]$DeviceHost = "192.168.1.238",
  [string]$EvidenceRoot = "",
  [string]$PythonExe = "",
  [int]$ReconnectTimeoutSeconds = 60,
  [switch]$OperatorPresent,
  [switch]$ConfirmSpeakerTest,
  [switch]$DryRun,
  [switch]$Json
)

$ErrorActionPreference = "Stop"
$RepoRoot = Resolve-Path (Join-Path $PSScriptRoot "..")
Set-Location $RepoRoot
if ([string]::IsNullOrWhiteSpace($PythonExe)) {
  $PythonCandidates = @(
    $env:STACKCHAN_BRAIN_PYTHON,
    (Join-Path $env:LOCALAPPDATA "Programs\Python\Python310\python.exe"),
    (Get-Command python.exe -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Source -First 1)
  ) | Where-Object { $_ -and (Test-Path -LiteralPath $_) }
  $PythonExe = $PythonCandidates | Select-Object -First 1
}
if (-not $PythonExe) { throw "Python runtime not found. Set STACKCHAN_BRAIN_PYTHON or pass -PythonExe." }
if ([string]::IsNullOrWhiteSpace($EvidenceRoot)) {
  $EvidenceRoot = "output\pc-brain\voice-v2-supervised-" + (Get-Date -Format "yyyyMMdd-HHmmss")
}
New-Item -ItemType Directory -Force -Path $EvidenceRoot | Out-Null
$EvidencePath = (Resolve-Path $EvidenceRoot).Path
$DebugUrl = "http://$DeviceHost`:8789/debug"

$Before = Invoke-RestMethod -Uri $DebugUrl -TimeoutSec 6
$Before | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath (Join-Path $EvidencePath "before-debug.json") -Encoding UTF8
$BridgeProcess = Get-NetTCPConnection -LocalPort 8765 -State Listen -ErrorAction SilentlyContinue | Select-Object -First 1
$BridgeDetails = if ($BridgeProcess) { Get-CimInstance Win32_Process -Filter "ProcessId = $($BridgeProcess.OwningProcess)" | Select-Object ProcessId,ExecutablePath,CommandLine } else { $null }
$BridgeDetails | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath (Join-Path $EvidencePath "before-bridge-process.json") -Encoding UTF8

$PreflightIssues = @()
if ($Before.network_state -ne "connected" -or $Before.bridge_state -ne "ready") { $PreflightIssues += "robot_bridge_not_ready" }
if ([int]$Before.speaker_stream_chunked -ne 1) { $PreflightIssues += "voice_v2_firmware_not_active" }
if ([bool]$Before.motion_enabled -or [bool]$Before.servo_rail_enabled -or [bool]$Before.servo_torque_enabled) { $PreflightIssues += "actuator_state_not_safe" }
if ([int]$Before.display_window_max_frame_us -gt 50000) { $PreflightIssues += "face_frame_gate_exceeded" }
if ([int]$Before.power_vbus_mv -lt 4400) { $PreflightIssues += "vbus_below_gate" }
if ([double]$Before.chip_temp_c -gt 68) { $PreflightIssues += "temperature_above_gate" }
$ProductionHealth = try { Invoke-RestMethod -Uri "http://127.0.0.1:5055/health" -TimeoutSec 5 } catch { $null }
if (-not $ProductionHealth -or -not $ProductionHealth.ready) { $PreflightIssues += "production_rvc_not_ready" }

$Session = [ordered]@{
  schema = "stackchan.voice-v2-supervised-session.v1"
  mode = "voice-v2-directml-supervised"
  status = $(if ($DryRun) { "dry-run" } else { "preflight" })
  evidence_root = $EvidencePath
  device_host = $DeviceHost
  candidate_worker_url = "http://127.0.0.1:5059"
  candidate_voice = "stackchan-rvc-directml-v2"
  phrase_max_chars = 96
  chunk_bytes = 4096
  binary_delay_ms = 70
  max_first_audio_ms = 5000
  preflight_issues = $PreflightIssues
  production_bridge_before = $BridgeDetails
}
$Session | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath (Join-Path $EvidencePath "session.json") -Encoding UTF8

if ($PreflightIssues.Count -gt 0) { throw "Voice V2 preflight failed: $($PreflightIssues -join ', ')" }
if ($DryRun) {
  if ($Json) { $Session | ConvertTo-Json -Depth 8 } else { Write-Host "Voice V2 dry-run ready: $EvidencePath" }
  exit 0
}
if (-not $OperatorPresent -or -not $ConfirmSpeakerTest) {
  throw "Supervised bridge switching requires -OperatorPresent -ConfirmSpeakerTest."
}

try {
  Invoke-RestMethod -Uri "http://$DeviceHost`:8789/motion-stop" -TimeoutSec 5 | Out-Null
  $SafeDebug = Invoke-RestMethod -Uri $DebugUrl -TimeoutSec 6
  if ([bool]$SafeDebug.motion_enabled -or [bool]$SafeDebug.servo_rail_enabled -or [bool]$SafeDebug.servo_torque_enabled) {
    throw "Motion stop did not leave actuator output safe."
  }

  & (Join-Path $PSScriptRoot "start_voice_v2_directml_worker.ps1") -StopExisting -Background -Port 5059 -F0Method pm -IndexRate 0.62 | Out-Null
  $Deadline = (Get-Date).AddSeconds(60)
  $WorkerHealth = $null
  while ((Get-Date) -lt $Deadline) {
    try { $WorkerHealth = Invoke-RestMethod -Uri "http://127.0.0.1:5059/health" -TimeoutSec 3 } catch { $WorkerHealth = $null }
    if ($WorkerHealth -and $WorkerHealth.ready) { break }
    Start-Sleep -Seconds 1
  }
  if (-not $WorkerHealth -or -not $WorkerHealth.ready) { throw "DirectML candidate worker did not become ready." }
  $WorkerHealth | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath (Join-Path $EvidencePath "worker-health.json") -Encoding UTF8

  $env:STACKCHAN_RVC_DIRECTML_WORKER_URL = "http://127.0.0.1:5059"
  $TtsCommand = "$PythonExe bridge\rvc_directml_tts_client.py"
  & (Join-Path $PSScriptRoot "start_pc_brain.ps1") `
    -StopExisting -Background -EnableAudioDownlink -StreamTtsPhrases `
    -TtsCommand $TtsCommand -TtsVoice "stackchan-rvc-directml-v2" `
    -TtsPhraseMaxChars 96 -DownlinkAudioChunkBytes 4096 `
    -DownlinkBinaryFrameDelayMs 70 -DownlinkTextFrameDelayMs 40 `
    -LogDir $EvidencePath -MemoryFile "output\pc-brain\latest\memory.json" `
    -TurnLogFile (Join-Path $EvidencePath "turns.jsonl") `
    -AudioEvidenceDir (Join-Path $EvidencePath "audio-evidence")
  if ($LASTEXITCODE -ne 0) { throw "Could not start the candidate bridge." }

  $CandidatePid = [int](Get-Content -LiteralPath (Join-Path $EvidencePath "lan_service.pid") -Raw)
  $Deadline = (Get-Date).AddSeconds($ReconnectTimeoutSeconds)
  $CandidateDebug = $null
  $SocketReady = $false
  while ((Get-Date) -lt $Deadline) {
    $Socket = Get-NetTCPConnection -LocalPort 8765 -State Established -ErrorAction SilentlyContinue |
      Where-Object { $_.OwningProcess -eq $CandidatePid -and $_.RemoteAddress -eq $DeviceHost } |
      Select-Object -First 1
    $SocketReady = [bool]$Socket
    try { $CandidateDebug = Invoke-RestMethod -Uri $DebugUrl -TimeoutSec 5 } catch { $CandidateDebug = $null }
    if ($SocketReady -and $CandidateDebug -and $CandidateDebug.bridge_state -eq "ready") { break }
    Start-Sleep -Seconds 2
  }
  if (-not $SocketReady -or -not $CandidateDebug -or $CandidateDebug.bridge_state -ne "ready") {
    throw "Candidate bridge did not reconnect to Stackchan within $ReconnectTimeoutSeconds seconds."
  }
  $Session.status = "active"
  $Session.candidate_bridge_pid = $CandidatePid
  $Session.worker_health = $WorkerHealth
  $Session | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath (Join-Path $EvidencePath "session.json") -Encoding UTF8
  $CandidateDebug | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath (Join-Path $EvidencePath "candidate-ready-debug.json") -Encoding UTF8
} catch {
  try { & (Join-Path $PSScriptRoot "restore_voice_v2_production.ps1") -DeviceHost $DeviceHost -EvidenceRoot $EvidencePath | Out-Null } catch {}
  throw
}

$Result = [ordered]@{
  schema = "stackchan.voice-v2-supervised-start.v1"
  status = "ready-for-one-spoken-turn"
  evidence_root = $EvidencePath
  candidate_bridge_pid = $Session.candidate_bridge_pid
  instruction = "Say Hey Stackchan once, ask for a two-sentence status update, then report whether the complete reply was clear."
}
if ($Json) { $Result | ConvertTo-Json -Depth 5 } else { Write-Host "Voice V2 ready. Evidence: $EvidencePath"; Write-Host $Result.instruction }
