param(
  [string]$DeviceHost = "192.168.1.238",
  [int]$BridgePort = 8765,
  [int]$DashboardPort = 8766,
  [string]$TurnLogFile = "output\pc-brain\latest\turns.jsonl",
  [string]$EvidenceRoot = "",
  [int]$MinReplyWindows = 100,
  [switch]$OperatorPresent,
  [switch]$ConfirmMotionOff,
  [switch]$Json
)

$ErrorActionPreference = "Stop"
$RepoRoot = Resolve-Path (Join-Path $PSScriptRoot "..")
Set-Location $RepoRoot

if (-not $OperatorPresent -or -not $ConfirmMotionOff) {
  throw "Qualification requires -OperatorPresent -ConfirmMotionOff."
}
if ($MinReplyWindows -lt 1) { throw "MinReplyWindows must be positive." }
if ([string]::IsNullOrWhiteSpace($EvidenceRoot)) {
  $EvidenceRoot = "output\pc-brain\bridge-ai-supervised-" + (Get-Date -Format "yyyyMMdd-HHmmss")
}
New-Item -ItemType Directory -Force -Path $EvidenceRoot | Out-Null
$EvidencePath = (Resolve-Path $EvidenceRoot).Path
$DebugUrl = "http://$DeviceHost`:8789/debug"
$DashboardUrl = "http://127.0.0.1`:$DashboardPort/api/status"

$Debug = Invoke-RestMethod -Uri $DebugUrl -TimeoutSec 6
$Dashboard = Invoke-RestMethod -Uri $DashboardUrl -TimeoutSec 6
$Debug | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath (Join-Path $EvidencePath "before-debug.json") -Encoding UTF8
$Dashboard | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath (Join-Path $EvidencePath "before-dashboard.json") -Encoding UTF8

$Listener = Get-NetTCPConnection -LocalPort $BridgePort -State Listen -ErrorAction SilentlyContinue |
  Select-Object -First 1
$BridgeProcess = if ($Listener) {
  Get-CimInstance Win32_Process -Filter "ProcessId=$($Listener.OwningProcess)" -ErrorAction SilentlyContinue
} else {
  $null
}
$CommandLine = if ($BridgeProcess) { [string]$BridgeProcess.CommandLine } else { "" }
$VisionPidFile = "output\pc-brain\latest\vision_service.pid"
$VisionProcess = $null
if (Test-Path -LiteralPath $VisionPidFile -PathType Leaf) {
  $VisionPid = 0
  [void][int]::TryParse((Get-Content -LiteralPath $VisionPidFile -Raw).Trim(), [ref]$VisionPid)
  if ($VisionPid -gt 0) {
    $VisionProcess = Get-CimInstance Win32_Process -Filter "ProcessId=$VisionPid" -ErrorAction SilentlyContinue
  }
}
$Features = [ordered]@{
  conversationV2 = $CommandLine.Contains("--conversation-v2")
  initiative = $CommandLine.Contains("--enable-initiative")
  roomObservation = $CommandLine.Contains("--room-observation")
  persistentStt = $CommandLine.Contains("--stt-server-url")
  privateAudioEvidence = $CommandLine.Contains("--audio-evidence-dir")
  turnTextRedacted = $CommandLine.Contains("--redact-turn-text")
  faceVision = $null -ne $VisionProcess -and
    [string]$VisionProcess.CommandLine -match "bridge[\\/]vision_service\.py"
}

$Issues = @()
if (-not $BridgeProcess -or $CommandLine -notmatch "bridge[\\/]lan_service\.py") { $Issues += "bridge_process_not_found" }
if (-not $Features.conversationV2) { $Issues += "conversation_v2_not_enabled" }
if (-not $Features.initiative) { $Issues += "initiative_not_enabled" }
if (-not $Features.roomObservation) { $Issues += "room_observation_not_enabled" }
if (-not $Features.faceVision) { $Issues += "face_vision_worker_not_running" }
if (-not $Features.persistentStt) { $Issues += "persistent_stt_not_enabled" }
if ($Features.privateAudioEvidence) { $Issues += "private_audio_evidence_enabled" }
if (-not $Features.turnTextRedacted) { $Issues += "turn_text_not_redacted" }
if (-not [bool]$Dashboard.bridge.conversationV2Enabled) { $Issues += "dashboard_conversation_v2_disabled" }
if (-not [bool]$Dashboard.behavior.initiative.enabled) { $Issues += "dashboard_initiative_disabled" }
if (-not [bool]$Dashboard.behavior.roomObservation.enabled) { $Issues += "dashboard_room_observation_disabled" }
if (-not [bool]$Dashboard.behavior.roomObservation.configured) { $Issues += "room_observation_not_configured" }
if ($Debug.network_state -ne "connected" -or $Debug.bridge_state -ne "ready") { $Issues += "robot_bridge_not_ready" }
if ([bool]$Debug.motion_enabled -or [bool]$Debug.servo_rail_enabled -or [bool]$Debug.servo_torque_enabled) {
  $Issues += "robot_motion_not_off"
}
if ([bool]$Debug.audio_stream_active -or [int]$Debug.speaker_channel_state -ne 0) {
  $Issues += "robot_audio_not_drained"
}
if ([int64]$Debug.camera_host_frame_requests -le 0 -or
    [int64]$Debug.camera_host_target_updates -le 0 -or
    [int64]$Debug.camera_face_batches -le 0) {
  $Issues += "robot_host_vision_never_advanced"
}

$SourceCommit = (& git rev-parse HEAD).Trim()
if ($LASTEXITCODE -ne 0) { throw "Could not resolve source commit." }
$SourceDirty = @(& git status --porcelain).Count -gt 0
$TurnLogPath = if ([IO.Path]::IsPathRooted($TurnLogFile)) {
  [IO.Path]::GetFullPath($TurnLogFile)
} else {
  [IO.Path]::GetFullPath((Join-Path $RepoRoot $TurnLogFile))
}
$TurnLogStartLine = if (Test-Path -LiteralPath $TurnLogPath -PathType Leaf) {
  @(Get-Content -LiteralPath $TurnLogPath).Count
} else {
  0
}

$Session = [ordered]@{
  schema = "stackchan.bridge-ai-supervised-session.v1"
  mode = "bridge-ai-supervised"
  status = $(if ($Issues.Count -eq 0) { "active" } else { "preflight-failed" })
  generatedAt = (Get-Date).ToUniversalTime().ToString("o")
  evidenceRoot = $EvidencePath
  deviceHost = $DeviceHost
  bridgePort = $BridgePort
  dashboardPort = $DashboardPort
  sourceCommit = $SourceCommit
  sourceWorktreeClean = -not $SourceDirty
  operatorPresent = [bool]$OperatorPresent
  motionOffConfirmed = [bool]$ConfirmMotionOff
  minReplyWindows = $MinReplyWindows
  bridgePid = if ($BridgeProcess) { [int]$BridgeProcess.ProcessId } else { 0 }
  bridgeFeatures = $Features
  turnLogPath = $TurnLogPath
  turnLogStartLine = $TurnLogStartLine
  preflightIssues = $Issues
}
$Session | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath (Join-Path $EvidencePath "session.json") -Encoding UTF8

$Result = [ordered]@{
  schema = "stackchan.bridge-ai-supervised-start.v1"
  status = $Session.status
  evidenceRoot = $EvidencePath
  issues = $Issues
  instructions = @(
    "Complete a natural multi-turn exchange from one wake.",
    "Exercise explicit exit, silence timeout, and over-speaker barge-in.",
    "Accumulate at least $MinReplyWindows echo-free physical reply windows.",
    "Observe two initiative openers at least ten minutes apart, ignore both, and verify backoff and night suppression.",
    "Collect at least two room observations, verify grounded context, then disable room observation and confirm its summary clears.",
    "Briefly disconnect and restore the bridge, confirming the local face and wake behavior remain available.",
    "Run complete_bridge_ai_supervised_qualification.ps1 only after audio is drained."
  )
}
if ($Json) { $Result | ConvertTo-Json -Depth 8 } else {
  Write-Host "$($Result.status): $EvidencePath"
  foreach ($Instruction in $Result.instructions) { Write-Host "- $Instruction" }
}
if ($Issues.Count -gt 0) { exit 1 }
