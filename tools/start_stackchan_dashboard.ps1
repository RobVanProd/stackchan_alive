param(
  [string]$DeviceHost = "192.168.1.238",
  [int]$BridgePort = 8765,
  [int]$DashboardPort = 8766,
  [int]$RobotHttpPort = 8789,
  [int]$ReadyTimeoutSeconds = 120,
  [switch]$NoBrowser
)

$ErrorActionPreference = "Stop"
$RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
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
  $arguments = @(
    "bridge\dashboard_service.py",
    "--host", "127.0.0.1",
    "--port", "$DashboardPort",
    "--robot-host", $DeviceHost,
    "--robot-http-port", "$RobotHttpPort",
    "--bridge-port", "$BridgePort",
    "--runner-profile", "gemma4-e2b-gguf",
    "--research-enabled"
  )
  $process = Start-Process -FilePath "python" -ArgumentList $arguments -WorkingDirectory $RepoRoot `
    -RedirectStandardOutput (Join-Path $LogDir "dashboard.out.log") `
    -RedirectStandardError (Join-Path $LogDir "dashboard.err.log") `
    -WindowStyle Hidden -PassThru
  Set-Content -LiteralPath (Join-Path $LogDir "dashboard.pid") -Value $process.Id -Encoding ASCII
} else {
  $productionLauncher = Join-Path $PSScriptRoot "start_pc_brain_directml.ps1"
  & $productionLauncher -DeviceHost $DeviceHost -BridgePort $BridgePort `
    -DashboardPort $DashboardPort -EnableResearch
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
