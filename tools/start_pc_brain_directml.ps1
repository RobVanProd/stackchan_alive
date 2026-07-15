param(
  [string]$DeviceHost = "192.168.1.238",
  [int]$BridgePort = 8765,
  [int]$WorkerPort = 5059,
  [int]$ReconnectTimeoutSeconds = 90,
  [string]$MemoryFile = "output\pc-brain\latest\memory.json",
  [switch]$EnableResearch,
  [string]$SearxngUrl = "http://127.0.0.1:8080",
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

function Stop-ExistingBridge {
  $listeners = @(Get-NetTCPConnection -LocalPort $BridgePort -State Listen -ErrorAction SilentlyContinue)
  foreach ($listener in $listeners) {
    $process = Get-CimInstance Win32_Process -Filter "ProcessId=$($listener.OwningProcess)" -ErrorAction SilentlyContinue
    if ($null -eq $process -or [string]$process.CommandLine -notmatch "bridge[\\/]lan_service\.py") {
      throw "Refusing to stop non-Stackchan listener PID $($listener.OwningProcess) on port $BridgePort."
    }
    Stop-Process -Id $listener.OwningProcess -Force
  }
  $deadline = (Get-Date).AddSeconds(10)
  while ((Get-Date) -lt $deadline -and
      (Get-NetTCPConnection -LocalPort $BridgePort -State Listen -ErrorAction SilentlyContinue)) {
    Start-Sleep -Milliseconds 250
  }
  if (Get-NetTCPConnection -LocalPort $BridgePort -State Listen -ErrorAction SilentlyContinue) {
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
      [string]$WorkerHealth.schema -eq "stackchan.rvc-directml-worker.health.v1") {
    break
  }
  Start-Sleep -Seconds 1
}
if ($null -eq $WorkerHealth -or -not [bool]$WorkerHealth.ready) {
  throw "DirectML worker did not become ready at $WorkerUrl."
}
$WorkerHealth | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath (Join-Path $EvidencePath "worker-health.json") -Encoding UTF8

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
$escapedDeviceHost = $DeviceHost.Replace("'", "''")
$bridgeScript = "`$ErrorActionPreference = 'Stop'; `$ProgressPreference = 'SilentlyContinue'; `$env:STACKCHAN_RVC_DIRECTML_WORKER_URL = '$WorkerUrl'; " +
  "& '$bridgeStarter' -Background -EnableAudioDownlink -StreamTtsPhrases " +
  "-Port $BridgePort -MemoryFile '$escapedMemoryFile' " +
  "-EnableDashboard -DashboardHost '127.0.0.1' -DashboardPort $DashboardPort -RobotHost '$escapedDeviceHost' " +
  "-TtsCommand 'python bridge\rvc_production_tts_client.py' " +
  "-TtsVoice 'stackchan-rvc-directml-v2' " +
  "-TtsPhraseMaxChars 96 -DownlinkAudioChunkBytes 4096 " +
  "-DownlinkBinaryFrameDelayMs 70 -DownlinkTextFrameDelayMs 40"
if ($EnableResearch) {
  $bridgeScript += " -EnableResearch -SearxngUrl '$escapedSearxngUrl'"
}
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
  "-VoiceWorkerUrl '$escapedWorkerUrl' " +
  "-ExpectedVoiceWorkerSchema 'stackchan.rvc-directml-worker.health.v1' -Json"
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
  streamTtsPhrases = $true
  researchEnabled = [bool]$EnableResearch
  searxngUrl = if ($EnableResearch) { $SearxngUrl } else { $null }
  ttsCommand = "python bridge\rvc_production_tts_client.py"
  memoryMaintenance = $MemoryReport
  robotNetwork = $Debug.network_state
  robotBridge = $Debug.bridge_state
  robotMotion = [bool]$Debug.motion_enabled
  robotServoRail = [bool]$Debug.servo_rail_enabled
  runtimeCheckStatus = $RuntimeCheck.status
  warmRocmWorkerStopped = [bool]$StopWarmRocmWorker
}
$Result | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath (Join-Path $EvidencePath "result.json") -Encoding UTF8
if ($Json) { $Result | ConvertTo-Json -Depth 8 } else { Write-Host "DirectML PC brain ready: PID $BridgePid" }
