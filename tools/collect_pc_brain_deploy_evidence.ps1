param(
  [string]$DeviceHost = "192.168.1.238",
  [int]$DebugPort = 8789,
  [string]$LogDir = "output\pc-brain\latest",
  [string]$OutDir = "",
  [switch]$RunTests
)

$ErrorActionPreference = "Stop"

$RepoRoot = Resolve-Path (Join-Path $PSScriptRoot "..")
Set-Location $RepoRoot

function New-UtcTimestamp {
  return (Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH-mm-ssZ")
}

function Write-JsonFile($Path, $Value) {
  $Value | ConvertTo-Json -Depth 16 | Set-Content -Path $Path -Encoding UTF8
}

function Get-IntValue($Object, [string]$Name, [int]$DefaultValue) {
  if ($null -eq $Object) {
    return $DefaultValue
  }
  $Property = $Object.PSObject.Properties[$Name]
  if ($null -eq $Property -or $null -eq $Property.Value) {
    return $DefaultValue
  }
  return [int]$Property.Value
}

function Invoke-CapturedNative([string]$CommandLine, [string]$LogPath) {
  $ResolvedLogPath = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($LogPath)
  & cmd.exe /d /c "$CommandLine > `"$ResolvedLogPath`" 2>&1"
  return $LASTEXITCODE
}

if (-not $OutDir) {
  $OutDir = Join-Path "output\pc-brain" ("deploy-evidence-" + (New-UtcTimestamp))
}

New-Item -ItemType Directory -Force -Path $OutDir | Out-Null
$ResolvedOutDir = Resolve-Path $OutDir

$summary = [ordered]@{
  schema = "stackchan.pc-brain-deploy-evidence.v1"
  generated_at = (Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")
  device_host = $DeviceHost
  debug_port = $DebugPort
  log_dir = $LogDir
  out_dir = [string]$ResolvedOutDir
  pc_brain_process = $null
  device_debug = $null
  copied_logs = @()
  tests = @()
  status = "fail"
  issues = @()
}

$PidFile = Join-Path $LogDir "lan_service.pid"
if (Test-Path -LiteralPath $PidFile) {
  $PidText = (Get-Content -LiteralPath $PidFile -ErrorAction Stop | Select-Object -First 1).Trim()
  if ($PidText) {
    $ProcessInfo = Get-CimInstance Win32_Process -Filter "ProcessId=$PidText" -ErrorAction SilentlyContinue
    if ($ProcessInfo) {
      $summary.pc_brain_process = [ordered]@{
        pid = [int]$ProcessInfo.ProcessId
        command_line = [string]$ProcessInfo.CommandLine
      }
    } else {
      $summary.issues += "pc_brain_process_not_running"
    }
  } else {
    $summary.issues += "pc_brain_pid_empty"
  }
} else {
  $summary.issues += "pc_brain_pid_missing"
}

foreach ($Name in @("lan_service.out.log", "lan_service.err.log", "lan_service.pid", "memory.json")) {
  $Source = Join-Path $LogDir $Name
  if (Test-Path -LiteralPath $Source) {
    $Destination = Join-Path $OutDir $Name
    Copy-Item -LiteralPath $Source -Destination $Destination -Force
    $summary.copied_logs += $Name
  }
}

try {
  $DebugUri = "http://$DeviceHost`:$DebugPort/"
  $DebugResponse = Invoke-WebRequest -Uri $DebugUri -UseBasicParsing -TimeoutSec 8
  $DebugBody = [string]$DebugResponse.Content
  $DebugPath = Join-Path $OutDir "stackchan_debug.json"
  Set-Content -Path $DebugPath -Value $DebugBody -Encoding UTF8
  $summary.device_debug = $DebugBody | ConvertFrom-Json
} catch {
  $summary.issues += "device_debug_unreachable: $($_.Exception.Message)"
}

if ($RunTests) {
  $NativeLog = Join-Path $OutDir "native_logic_test.log"
  $NativeExit = Invoke-CapturedNative "pio test -e native_logic" $NativeLog
  $summary.tests += [ordered]@{
    name = "pio test -e native_logic"
    exit_code = $NativeExit
    log = "native_logic_test.log"
  }
  if ($NativeExit -ne 0) {
    $summary.issues += "native_logic_tests_failed"
  }

  $BridgeLog = Join-Path $OutDir "bridge_unittest.log"
  Push-Location "bridge"
  try {
    $BridgeExit = Invoke-CapturedNative "python -m unittest test_lan_service test_tts_adapter test_local_runner test_protocol_fixtures test_hardware_simulator test_lan_smoke" (Join-Path ".." $BridgeLog)
  } finally {
    Pop-Location
  }
  $summary.tests += [ordered]@{
    name = "python -m unittest bridge deploy suites"
    exit_code = $BridgeExit
    log = "bridge_unittest.log"
  }
  if ($BridgeExit -ne 0) {
    $summary.issues += "bridge_tests_failed"
  }
}

if ($summary.device_debug) {
  $Debug = $summary.device_debug
  if ($Debug.network_state -ne "connected") { $summary.issues += "device_network_not_connected" }
  if ($Debug.bridge_state -ne "ready") { $summary.issues += "bridge_not_ready" }
  if ((Get-IntValue $Debug "bridge_outputs_dropped" 0) -ne 0) { $summary.issues += "bridge_outputs_dropped" }
  if ((Get-IntValue $Debug "bridge_parse_errors" 0) -ne 0) { $summary.issues += "bridge_parse_errors" }
  if ((Get-IntValue $Debug "bridge_timeouts" 0) -ne 0) { $summary.issues += "bridge_timeouts" }
  if ((Get-IntValue $Debug "audio_stream_errors" 0) -ne 0) { $summary.issues += "audio_stream_errors" }
  if ((Get-IntValue $Debug "bridge_downlink_errors" 0) -ne 0) { $summary.issues += "bridge_downlink_errors" }
  if ((Get-IntValue $Debug "bridge_downlink_playback_errors" 0) -ne 0) { $summary.issues += "bridge_downlink_playback_errors" }
  if ((Get-IntValue $Debug "audio_stream_chunks_expected" 0) -ne (Get-IntValue $Debug "audio_stream_chunks_received" -1)) {
    $summary.issues += "audio_stream_chunk_mismatch"
  }
  if ((Get-IntValue $Debug "bridge_downlink_playback_chunks" 0) -ne (Get-IntValue $Debug "audio_stream_chunks_expected" -1)) {
    $summary.issues += "playback_chunk_mismatch"
  }
}

if ($summary.pc_brain_process -and $summary.device_debug -and $summary.issues.Count -eq 0) {
  $summary.status = "pass"
}

$JsonPath = Join-Path $OutDir "PC_BRAIN_DEPLOY_EVIDENCE.json"
Write-JsonFile $JsonPath $summary

$MarkdownPath = Join-Path $OutDir "PC_BRAIN_DEPLOY_EVIDENCE.md"
$lines = @(
  "# Stackchan PC Brain Deploy Evidence",
  "",
  "- Status: ``$($summary.status)``",
  "- Generated: ``$($summary.generated_at)``",
  "- Device debug: ``http://$DeviceHost`:$DebugPort/``",
  "- PC brain PID: ``$(if ($summary.pc_brain_process) { $summary.pc_brain_process.pid } else { 'missing' })``",
  "- Copied logs: ``$($summary.copied_logs -join ', ')``"
)
if ($summary.device_debug) {
  $Debug = $summary.device_debug
  $lines += @(
    "- Network state: ``$($Debug.network_state)``",
    "- Bridge state: ``$($Debug.bridge_state)``",
    "- Bridge errors: dropped=``$($Debug.bridge_outputs_dropped)`` parse=``$($Debug.bridge_parse_errors)`` timeouts=``$($Debug.bridge_timeouts)``",
    "- Audio streams: started=``$($Debug.audio_streams_started)`` ended=``$($Debug.audio_streams_ended)`` chunks=``$($Debug.audio_stream_chunks_received)/$($Debug.audio_stream_chunks_expected)``",
    "- Playback: chunks=``$($Debug.bridge_downlink_playback_chunks)`` bytes=``$($Debug.bridge_downlink_playback_bytes)`` errors=``$($Debug.bridge_downlink_playback_errors)``"
  )
}
if ($summary.tests.Count -gt 0) {
  $lines += ""
  $lines += "## Tests"
  foreach ($Test in $summary.tests) {
    $lines += "- ``$($Test.name)`` exit=``$($Test.exit_code)`` log=``$($Test.log)``"
  }
}
if ($summary.issues.Count -gt 0) {
  $lines += ""
  $lines += "## Issues"
  foreach ($Issue in $summary.issues) {
    $lines += "- ``$Issue``"
  }
}
$lines | Set-Content -Path $MarkdownPath -Encoding UTF8

Write-Host "[pc-brain-deploy-evidence] status=$($summary.status) out_dir=$ResolvedOutDir"
exit $(if ($summary.status -eq "pass") { 0 } else { 1 })
