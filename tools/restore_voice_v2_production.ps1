param(
  [string]$DeviceHost = "192.168.1.238",
  [string]$EvidenceRoot = "",
  [int]$ReconnectTimeoutSeconds = 60,
  [switch]$Json
)

$ErrorActionPreference = "Stop"
$RepoRoot = Resolve-Path (Join-Path $PSScriptRoot "..")
Set-Location $RepoRoot
$DebugUrl = "http://$DeviceHost`:8789/debug"

$ProductionHealth = Invoke-RestMethod -Uri "http://127.0.0.1:5055/health" -TimeoutSec 5
if (-not $ProductionHealth.ready) { throw "Production RVC worker is not ready on port 5055." }

$env:STACKCHAN_RVC_WORKER_URL = "http://127.0.0.1:5055"
& (Join-Path $PSScriptRoot "start_pc_brain.ps1") `
  -StopExisting -Background -EnableAudioDownlink `
  -TtsCommand "python bridge\rvc_tts_client.py" `
  -TtsVoice "stackchan-rvc-warm-rocm" `
  -DownlinkBinaryFrameDelayMs 80
if ($LASTEXITCODE -ne 0) { throw "Could not restart the production bridge." }

$BridgePid = [int](Get-Content -LiteralPath "output\pc-brain\latest\lan_service.pid" -Raw)
$Deadline = (Get-Date).AddSeconds($ReconnectTimeoutSeconds)
$Debug = $null
$SocketReady = $false
while ((Get-Date) -lt $Deadline) {
  $Socket = Get-NetTCPConnection -LocalPort 8765 -State Established -ErrorAction SilentlyContinue |
    Where-Object { $_.OwningProcess -eq $BridgePid -and $_.RemoteAddress -eq $DeviceHost } |
    Select-Object -First 1
  $SocketReady = [bool]$Socket
  try { $Debug = Invoke-RestMethod -Uri $DebugUrl -TimeoutSec 5 } catch { $Debug = $null }
  if ($SocketReady -and $Debug -and $Debug.network_state -eq "connected" -and $Debug.bridge_state -eq "ready") { break }
  Start-Sleep -Seconds 2
}
if (-not $SocketReady -or -not $Debug -or $Debug.bridge_state -ne "ready") {
  throw "Production bridge did not reconnect to Stackchan within $ReconnectTimeoutSeconds seconds."
}

$LabWorkers = @(Get-CimInstance Win32_Process |
  Where-Object {
    $_.Name -like "python*.exe" -and
    $_.CommandLine -and
    $_.CommandLine.Contains("rvc_directml_worker_service.py")
  })
$LabWorkers | ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
Start-Sleep -Milliseconds 500

$Result = [ordered]@{
  schema = "stackchan.voice-v2-production-restore.v1"
  restored = $true
  production_bridge_pid = $BridgePid
  production_worker_pid = (Get-NetTCPConnection -LocalPort 5055 -State Listen | Select-Object -First 1).OwningProcess
  lab_worker_stopped = -not [bool](Get-NetTCPConnection -LocalPort 5059 -State Listen -ErrorAction SilentlyContinue) -and
    -not [bool](Get-CimInstance Win32_Process | Where-Object {
        $_.Name -like "python*.exe" -and
        $_.CommandLine -and
        $_.CommandLine.Contains("rvc_directml_worker_service.py")
      })
  robot_network = $Debug.network_state
  robot_bridge = $Debug.bridge_state
  robot_motion = [bool]$Debug.motion_enabled
  robot_servo_rail = [bool]$Debug.servo_rail_enabled
}
if (-not [string]::IsNullOrWhiteSpace($EvidenceRoot)) {
  New-Item -ItemType Directory -Force -Path $EvidenceRoot | Out-Null
  $Result | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath (Join-Path $EvidenceRoot "production-restore.json") -Encoding UTF8
}
if ($Json) { $Result | ConvertTo-Json -Depth 5 } else { Write-Host "Production bridge restored: PID $BridgePid" }
