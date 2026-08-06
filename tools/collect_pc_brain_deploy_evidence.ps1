param(
  [string]$DeviceHost = "192.168.1.238",
  [int]$DebugPort = 8789,
  [string]$LogDir = "output\pc-brain\latest",
  [string]$OutDir = "",
  [string]$SourceCommit = "",
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

function Test-HasProperty($Object, [string]$Name) {
  if ($null -eq $Object) {
    return $false
  }
  return $null -ne $Object.PSObject.Properties[$Name]
}

function Resolve-SourceCommit {
  param([string]$Value)

  if (-not [string]::IsNullOrWhiteSpace($Value)) {
    return $Value
  }
  try {
    $commit = (& git rev-parse HEAD 2>$null | Select-Object -First 1).Trim()
    if ($commit -match "^[a-fA-F0-9]{40}$") {
      return $commit
    }
  } catch {
  }
  return ""
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
  sourceCommit = Resolve-SourceCommit $SourceCommit
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

$DebugUri = "http://$DeviceHost`:$DebugPort/debug"
try {
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
  if ($Debug.schema -ne "stackchan.bridge-debug.v1") { $summary.issues += "device_debug_schema_invalid" }
  if ($Debug.debug_request_route -ne "debug") { $summary.issues += "device_debug_route_invalid" }
  if ($Debug.debug_request_result -ne "debug") { $summary.issues += "device_debug_result_invalid" }
  if ($Debug.network_state -ne "connected") { $summary.issues += "device_network_not_connected" }
  if ($Debug.bridge_state -ne "ready") { $summary.issues += "bridge_not_ready" }

  $RequiredPlaybackFields = @(
    "audio_stream_active",
    "bridge_downlink_playback_starts",
    "bridge_downlink_playback_chunks",
    "bridge_downlink_playback_bytes",
    "bridge_downlink_playback_stops",
    "bridge_downlink_playback_awaiting_drain",
    "bridge_downlink_playback_completion_pending",
    "bridge_downlink_playback_completions",
    "bridge_downlink_playback_completion_signals",
    "bridge_downlink_playback_errors",
    "speaker_stream_play_raw_ok",
    "speaker_stream_play_raw_failed",
    "speaker_stream_forced_stops",
    "speaker_stream_orphan_stops",
    "speaker_running",
    "speaker_channel_state"
  )
  $MissingPlaybackFields = @($RequiredPlaybackFields | Where-Object { -not (Test-HasProperty $Debug $_) })
  foreach ($Field in $MissingPlaybackFields) {
    $summary.issues += "device_debug_field_missing:$Field"
  }

  if ($MissingPlaybackFields.Count -eq 0) {
    $PlaybackStarts = Get-IntValue $Debug "bridge_downlink_playback_starts" -1
    $PlaybackChunks = Get-IntValue $Debug "bridge_downlink_playback_chunks" -1
    $PlaybackBytes = Get-IntValue $Debug "bridge_downlink_playback_bytes" -1
    $PlaybackStops = Get-IntValue $Debug "bridge_downlink_playback_stops" -1
    $PlaybackCompletions = Get-IntValue $Debug "bridge_downlink_playback_completions" -1
    $PlaybackSignals = Get-IntValue $Debug "bridge_downlink_playback_completion_signals" -1
    $SpeakerRawOk = Get-IntValue $Debug "speaker_stream_play_raw_ok" -1

    if ($PlaybackStarts -lt 1) { $summary.issues += "bridge_downlink_playback_not_started" }
    if ($PlaybackChunks -lt 1) { $summary.issues += "bridge_downlink_playback_chunks_missing" }
    if ($PlaybackBytes -lt 1) { $summary.issues += "bridge_downlink_playback_bytes_missing" }
    if ($PlaybackStops -ne $PlaybackStarts -or $PlaybackCompletions -ne $PlaybackStarts) {
      $summary.issues += "bridge_downlink_playback_not_completed"
    }
    if ($PlaybackSignals -ne $PlaybackCompletions) {
      $summary.issues += "bridge_downlink_playback_completion_not_signaled"
    }
    if ([bool]$Debug.bridge_downlink_playback_awaiting_drain -or
        [bool]$Debug.bridge_downlink_playback_completion_pending) {
      $summary.issues += "bridge_downlink_playback_not_drained"
    }
    if ([bool]$Debug.audio_stream_active) { $summary.issues += "audio_stream_active" }
    if ((Get-IntValue $Debug "bridge_downlink_playback_errors" -1) -ne 0) { $summary.issues += "bridge_downlink_playback_errors" }
    if ((Get-IntValue $Debug "speaker_stream_play_raw_failed" -1) -ne 0) { $summary.issues += "speaker_stream_play_raw_failed" }
    if ((Get-IntValue $Debug "speaker_stream_forced_stops" -1) -ne 0) { $summary.issues += "speaker_stream_forced_stops" }
    if ((Get-IntValue $Debug "speaker_stream_orphan_stops" -1) -ne 0) { $summary.issues += "speaker_stream_orphan_stops" }
    if ($SpeakerRawOk -ne $PlaybackChunks) { $summary.issues += "speaker_playback_chunk_mismatch" }
    if ([bool]$Debug.speaker_running -or (Get-IntValue $Debug "speaker_channel_state" -1) -ne 0) {
      $summary.issues += "speaker_playback_not_idle"
    }
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
  "- Source commit: ``$($summary.sourceCommit)``",
  "- Device debug: ``$DebugUri``",
  "- PC brain PID: ``$(if ($summary.pc_brain_process) { $summary.pc_brain_process.pid } else { 'missing' })``",
  "- Copied logs: ``$($summary.copied_logs -join ', ')``"
)
if ($summary.device_debug) {
  $Debug = $summary.device_debug
  $lines += @(
    "- Network state: ``$($Debug.network_state)``",
    "- Bridge state: ``$($Debug.bridge_state)``",
    "- Debug route: ``$($Debug.debug_request_route)`` result=``$($Debug.debug_request_result)``",
    "- Playback: starts=``$($Debug.bridge_downlink_playback_starts)`` stops=``$($Debug.bridge_downlink_playback_stops)`` completions=``$($Debug.bridge_downlink_playback_completions)`` signals=``$($Debug.bridge_downlink_playback_completion_signals)``",
    "- Playback payload: chunks=``$($Debug.bridge_downlink_playback_chunks)`` bytes=``$($Debug.bridge_downlink_playback_bytes)`` errors=``$($Debug.bridge_downlink_playback_errors)``",
    "- Speaker sink: raw_ok=``$($Debug.speaker_stream_play_raw_ok)`` raw_failed=``$($Debug.speaker_stream_play_raw_failed)`` running=``$($Debug.speaker_running)``"
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
