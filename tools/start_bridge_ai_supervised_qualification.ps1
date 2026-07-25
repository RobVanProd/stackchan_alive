param(
  [Parameter(Mandatory = $true)]
  [string]$PackageZip,
  [Parameter(Mandatory = $true)]
  [ValidatePattern("^[0-9a-fA-F]{64}$")]
  [string]$ExpectedFirmwareSha256,
  [Parameter(Mandatory = $true)]
  [ValidatePattern("^[0-9a-fA-F]{40}$")]
  [string]$ExpectedFirmwareSourceCommit,
  [string]$DeviceHost = "192.168.1.238",
  [int]$BridgePort = 8765,
  [int]$DashboardPort = 8766,
  [string]$TurnLogFile = "output\pc-brain\latest\turns.jsonl",
  [string]$RuntimeManifestFile = "output\pc-brain\latest\runtime_manifest.json",
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

$SourceCommit = (& git rev-parse HEAD).Trim().ToLowerInvariant()
if ($LASTEXITCODE -ne 0 -or $SourceCommit -notmatch "^[0-9a-f]{40}$") {
  throw "Could not resolve source commit."
}
$SourceDirty = @(& git status --porcelain).Count -gt 0
$ExpectedFirmwareSha256 = $ExpectedFirmwareSha256.ToLowerInvariant()
$ExpectedFirmwareSourceCommit = $ExpectedFirmwareSourceCommit.ToLowerInvariant()
$PackageZipPath = (Resolve-Path $PackageZip).Path
$PackageSha256 = (Get-FileHash -LiteralPath $PackageZipPath -Algorithm SHA256).Hash.ToLowerInvariant()

Add-Type -AssemblyName System.IO.Compression.FileSystem
$Archive = [IO.Compression.ZipFile]::OpenRead($PackageZipPath)
try {
  $ManifestEntry = $Archive.Entries | Where-Object { $_.FullName -eq "release_manifest.json" } | Select-Object -First 1
  if (-not $ManifestEntry) { throw "Release ZIP is missing release_manifest.json." }

  $ManifestReader = [IO.StreamReader]::new($ManifestEntry.Open(), [Text.Encoding]::UTF8, $true)
  try {
    $PackageManifest = $ManifestReader.ReadToEnd() | ConvertFrom-Json
  } finally {
    $ManifestReader.Dispose()
  }
} finally {
  $Archive.Dispose()
}

$PackageVersion = [string]$PackageManifest.version
$PackageCommit = ([string]$PackageManifest.commit).ToLowerInvariant()
if ($PackageCommit -notmatch "^[0-9a-f]{40}$") { throw "Release ZIP manifest commit is invalid." }
if ($PackageCommit -ne $SourceCommit) {
  throw "Release ZIP commit $PackageCommit does not match source commit $SourceCommit."
}
$PackageVerifyLog = Join-Path $EvidencePath "package-verify.log"
$PackageVerifyOutput = & powershell.exe -NoProfile -ExecutionPolicy Bypass `
  -File (Join-Path $PSScriptRoot "verify_release_package.ps1") `
  -Version $PackageVersion -ZipPath $PackageZipPath -ExpectedCommit $SourceCommit 2>&1
$PackageVerifyExit = $LASTEXITCODE
$PackageVerifyOutput | Set-Content -LiteralPath $PackageVerifyLog -Encoding UTF8
if ($PackageVerifyExit -ne 0) {
  throw "Release ZIP verification failed. See $PackageVerifyLog"
}

$FirmwareInputPaths = @(
  "platformio.ini",
  "partitions_esp_sr_16.csv",
  "src",
  "test/test_native_logic",
  "personas",
  "media/voice",
  "bridge/persona_pack.py",
  "tools/platformio_*.py",
  "tools/flash_srmodels.py",
  "tools/flash_release_firmware.ps1"
)
$FirmwareInputStatus = @(& git status --porcelain -- $FirmwareInputPaths)
if ($FirmwareInputStatus.Count -ne 0) {
  throw "Firmware build inputs must be clean before bridge-only qualification."
}
$FirmwareInputDiff = @(& git diff --name-only origin/main -- $FirmwareInputPaths)
if ($FirmwareInputDiff.Count -ne 0) {
  throw "Bridge-only qualification requires firmware build inputs identical to origin/main: $($FirmwareInputDiff -join ', ')"
}

$FirmwareAcceptanceRelativePath = "docs/FIRST_DEPLOY_STATUS.md"
$FirmwareAcceptancePath = Join-Path $RepoRoot $FirmwareAcceptanceRelativePath
if (-not (Test-Path -LiteralPath $FirmwareAcceptancePath -PathType Leaf)) {
  throw "Missing authoritative firmware acceptance record: $FirmwareAcceptanceRelativePath"
}
$FirmwareAcceptanceStatus = @(& git status --porcelain -- $FirmwareAcceptanceRelativePath)
if ($FirmwareAcceptanceStatus.Count -ne 0) {
  throw "$FirmwareAcceptanceRelativePath must match the clean source commit."
}
& git diff --quiet origin/main -- $FirmwareAcceptanceRelativePath
if ($LASTEXITCODE -ne 0) {
  throw "$FirmwareAcceptanceRelativePath must be identical to origin/main."
}
& git merge-base --is-ancestor $ExpectedFirmwareSourceCommit origin/main
if ($LASTEXITCODE -ne 0) {
  throw "Accepted firmware source commit $ExpectedFirmwareSourceCommit is not an ancestor of origin/main."
}
$FirmwareAcceptanceText = Get-Content -LiteralPath $FirmwareAcceptancePath -Raw
$FirmwareAcceptanceLower = $FirmwareAcceptanceText.ToLowerInvariant()
$FirmwareCommitPosition = $FirmwareAcceptanceLower.IndexOf($ExpectedFirmwareSourceCommit)
$FirmwareShaPosition = $FirmwareAcceptanceLower.IndexOf($ExpectedFirmwareSha256)
if ($FirmwareCommitPosition -lt 0 -or $FirmwareShaPosition -lt 0 -or
    [Math]::Abs($FirmwareCommitPosition - $FirmwareShaPosition) -gt 512) {
  throw "Accepted firmware identity is not recorded in $FirmwareAcceptanceRelativePath."
}
$FirmwareAcceptanceEvidencePath = Join-Path $EvidencePath "accepted-main-firmware-status.md"
Copy-Item -LiteralPath $FirmwareAcceptancePath -Destination $FirmwareAcceptanceEvidencePath
$FirmwareAcceptanceEvidenceSha256 = (
  Get-FileHash -LiteralPath $FirmwareAcceptanceEvidencePath -Algorithm SHA256
).Hash.ToLowerInvariant()

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
$RuntimeManifestPath = if ([IO.Path]::IsPathRooted($RuntimeManifestFile)) {
  [IO.Path]::GetFullPath($RuntimeManifestFile)
} else {
  [IO.Path]::GetFullPath((Join-Path $RepoRoot $RuntimeManifestFile))
}
$RuntimeManifest = if (Test-Path -LiteralPath $RuntimeManifestPath -PathType Leaf) {
  Get-Content -LiteralPath $RuntimeManifestPath -Raw | ConvertFrom-Json
} else {
  $null
}
if ($RuntimeManifest) {
  $RuntimeManifest | ConvertTo-Json -Depth 8 |
    Set-Content -LiteralPath (Join-Path $EvidencePath "runtime-manifest.json") -Encoding UTF8
}
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
if (-not $RuntimeManifest) {
  $Issues += "runtime_manifest_missing"
} else {
  if ([string]$RuntimeManifest.schema -ne "stackchan.pc-brain-runtime.v1") { $Issues += "runtime_manifest_schema_invalid" }
  if ([int]$RuntimeManifest.bridgePid -ne [int]$BridgeProcess.ProcessId) { $Issues += "runtime_manifest_pid_mismatch" }
  if (([string]$RuntimeManifest.sourceCommit).ToLowerInvariant() -ne $SourceCommit) { $Issues += "runtime_manifest_commit_mismatch" }
  if ([bool]$RuntimeManifest.sourceWorktreeClean -ne $true) { $Issues += "runtime_manifest_source_dirty" }
  if ([IO.Path]::GetFullPath([string]$RuntimeManifest.sourceRoot) -ne [IO.Path]::GetFullPath($RepoRoot.Path)) {
    $Issues += "runtime_manifest_source_root_mismatch"
  }
}
if ($SourceDirty) { $Issues += "source_worktree_dirty" }
if (([string]$Debug.ota_expected_sha256).ToLowerInvariant() -ne $ExpectedFirmwareSha256) {
  $Issues += "robot_firmware_accepted_main_mismatch"
}
if ([bool]$Debug.ota_current_app_confirmed -ne $true) { $Issues += "robot_firmware_not_confirmed" }
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
  schema = "stackchan.bridge-ai-supervised-session.v3"
  mode = "bridge-ai-supervised"
  status = $(if ($Issues.Count -eq 0) { "active" } else { "preflight-failed" })
  generatedAt = (Get-Date).ToUniversalTime().ToString("o")
  evidenceRoot = $EvidencePath
  deviceHost = $DeviceHost
  bridgePort = $BridgePort
  dashboardPort = $DashboardPort
  sourceCommit = $SourceCommit
  sourceWorktreeClean = -not $SourceDirty
  packageVersion = $PackageVersion
  packageCommit = $PackageCommit
  packageZipPath = $PackageZipPath
  packageSha256 = $PackageSha256
  packageVerified = $true
  expectedFirmwareSha256 = $ExpectedFirmwareSha256
  expectedFirmwareSourceCommit = $ExpectedFirmwareSourceCommit
  firmwareAcceptanceEvidence = "accepted-main-firmware-status.md"
  firmwareAcceptanceBase = "origin/main"
  firmwareAcceptanceEvidenceSha256 = $FirmwareAcceptanceEvidenceSha256
  runtimeManifestPath = $RuntimeManifestPath
  runtimeSourceCommit = if ($RuntimeManifest) { ([string]$RuntimeManifest.sourceCommit).ToLowerInvariant() } else { "" }
  runtimeSourceRoot = if ($RuntimeManifest) { [string]$RuntimeManifest.sourceRoot } else { "" }
  runtimeBridgePid = if ($RuntimeManifest) { [int]$RuntimeManifest.bridgePid } else { 0 }
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
