param(
  [string]$DeviceHost = "192.168.1.238",
  [int]$BridgePort = 8765,
  [int]$DashboardPort = 8766,
  [int]$RobotHttpPort = 8789,
  [int]$ReadyTimeoutSeconds = 120,
  [switch]$DisableResearch,
  [switch]$DisableFaceVision,
  [string]$CameraPairingCodeFile = "",
  [string]$RoomVisionModel = "gemma4:e2b-it-qat",
  [switch]$NoBrowser
)

$ErrorActionPreference = "Stop"
$RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
$StableRepoRoot = $RepoRoot
$WorktreeMarker = "$([IO.Path]::DirectorySeparatorChar)output$([IO.Path]::DirectorySeparatorChar)worktrees$([IO.Path]::DirectorySeparatorChar)"
$MarkerIndex = $RepoRoot.IndexOf($WorktreeMarker, [StringComparison]::OrdinalIgnoreCase)
if ($MarkerIndex -ge 0) { $StableRepoRoot = $RepoRoot.Substring(0, $MarkerIndex) }
$DashboardUrl = "http://127.0.0.1`:$DashboardPort/"
$StatusUrl = "${DashboardUrl}api/status"
$LogDir = Join-Path $RepoRoot "output\pc-brain\latest"
New-Item -ItemType Directory -Force -Path $LogDir | Out-Null

function Get-DashboardStatus {
  try {
    $status = Invoke-RestMethod -Uri $StatusUrl -TimeoutSec 3
    if ([string]$status.schema -eq "stackchan.bridge-dashboard.v1") { return $status }
  } catch {}
  return $null
}

function Open-Dashboard {
  if (-not $NoBrowser) { Start-Process $DashboardUrl }
  Write-Host "Stackchan dashboard: $DashboardUrl"
}

$status = Get-DashboardStatus
if ($status) {
  Open-Dashboard
  exit 0
}

$dashboardListener = Get-NetTCPConnection -LocalPort $DashboardPort -State Listen -ErrorAction SilentlyContinue |
  Select-Object -First 1
if ($dashboardListener) {
  throw "Port $DashboardPort is already used by a non-Stackchan dashboard process (PID $($dashboardListener.OwningProcess))."
}

$bridgeListener = Get-NetTCPConnection -LocalPort $BridgePort -State Listen -ErrorAction SilentlyContinue |
  Select-Object -First 1
if ($bridgeListener) {
  $bridgeProcess = Get-CimInstance Win32_Process -Filter "ProcessId=$($bridgeListener.OwningProcess)" -ErrorAction SilentlyContinue
  if ($null -eq $bridgeProcess -or [string]$bridgeProcess.CommandLine -notmatch "bridge[\\/]lan_service\.py") {
    throw "Port $BridgePort is occupied by a non-Stackchan process; refusing to attach the dashboard."
  }
  $bridgeCommandLine = [string]$bridgeProcess.CommandLine
  $arguments = @(
    "bridge\dashboard_service.py",
    "--host", "127.0.0.1",
    "--port", "$DashboardPort",
    "--robot-host", $DeviceHost,
    "--robot-http-port", "$RobotHttpPort",
    "--bridge-port", "$BridgePort",
    "--runner-profile", "gemma4-e2b-gguf"
  )
  if ($bridgeCommandLine -match "(^|\s)--enable-research(\s|$)") {
    $arguments += "--research-enabled"
  }
  if ($bridgeCommandLine -match "(^|\s)--conversation-v2(\s|$)") {
    $arguments += "--conversation-v2-enabled"
  }
  $process = Start-Process -FilePath "python" -ArgumentList $arguments -WorkingDirectory $RepoRoot `
    -RedirectStandardOutput (Join-Path $LogDir "dashboard.out.log") `
    -RedirectStandardError (Join-Path $LogDir "dashboard.err.log") `
    -WindowStyle Hidden -PassThru
  Set-Content -LiteralPath (Join-Path $LogDir "dashboard.pid") -Value $process.Id -Encoding ASCII
} else {
  if (-not $DisableResearch) {
    $researchStarter = Join-Path $PSScriptRoot "start_local_research.ps1"
    $researchOutput = & powershell.exe -NoProfile -ExecutionPolicy Bypass `
      -File $researchStarter -Json 2>&1
    $researchExit = $LASTEXITCODE
    try {
      $research = ($researchOutput -join "`n") | ConvertFrom-Json
    } catch {
      throw "Local research startup returned invalid structured evidence."
    }
    if ($researchExit -ne 0 -or [string]$research.status -ne "local-research-ready") {
      throw "Local research is required for normal startup: $([string]$research.error). $([string]$research.remediation) Use -DisableResearch only for an intentional offline session."
    }
  }

  $effectivePairingCodeFile = $CameraPairingCodeFile
  if ([string]::IsNullOrWhiteSpace($effectivePairingCodeFile)) {
    $effectivePairingCodeFile = @(
      (Join-Path $StableRepoRoot "output\private\camera-pairing-code.txt"),
      (Join-Path $RepoRoot "output\private\camera-pairing-code.txt")
    ) | Where-Object { Test-Path -LiteralPath $_ -PathType Leaf } | Select-Object -First 1
  } elseif (-not (Test-Path -LiteralPath $effectivePairingCodeFile -PathType Leaf)) {
    throw "CameraPairingCodeFile is missing."
  }

  $productionLauncher = Join-Path $PSScriptRoot "start_pc_brain_directml.ps1"
  $productionArgs = @{
    DeviceHost = $DeviceHost
    BridgePort = $BridgePort
    DashboardPort = $DashboardPort
    EnableConversationV2 = $true
    EnableInitiative = $true
  }
  if (-not $DisableResearch) {
    $productionArgs.EnableResearch = $true
  }
  if (-not $DisableFaceVision -and -not [string]::IsNullOrWhiteSpace($effectivePairingCodeFile)) {
    $productionArgs.EnableFaceVision = $true
    $productionArgs.CameraPairingCodeFile = $effectivePairingCodeFile
    $productionArgs.RoomVisionModel = $RoomVisionModel
  }
  & $productionLauncher @productionArgs
  if ($LASTEXITCODE -ne 0) {
    throw "Stackchan production bridge failed to start."
  }
}

$deadline = (Get-Date).AddSeconds($ReadyTimeoutSeconds)
do {
  Start-Sleep -Milliseconds 500
  $status = Get-DashboardStatus
} while (-not $status -and (Get-Date) -lt $deadline)

if (-not $status) {
  throw "Stackchan dashboard did not become ready at $DashboardUrl within $ReadyTimeoutSeconds seconds."
}

Open-Dashboard
