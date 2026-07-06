param(
  [string]$DeviceHost = "192.168.1.238",
  [int]$DebugPort = 8789,
  [int]$DurationSeconds = 600,
  [int]$IntervalSeconds = 30,
  [string]$OutDir = ""
)

$ErrorActionPreference = "Stop"

$RepoRoot = Resolve-Path (Join-Path $PSScriptRoot "..")
Set-Location $RepoRoot

function New-UtcTimestamp {
  return (Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH-mm-ssZ")
}

function Write-JsonFile {
  param(
    [string]$Path,
    $Value
  )
  $Value | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $Path -Encoding UTF8
}

function Get-IntValue {
  param(
    $Object,
    [string]$Name,
    [int]$DefaultValue = 0
  )
  if ($null -eq $Object) { return $DefaultValue }
  $property = $Object.PSObject.Properties[$Name]
  if ($null -eq $property -or $null -eq $property.Value) { return $DefaultValue }
  return [int]$property.Value
}

if ($DurationSeconds -lt 1) { throw "DurationSeconds must be positive." }
if ($IntervalSeconds -lt 1) { throw "IntervalSeconds must be positive." }

if ([string]::IsNullOrWhiteSpace($OutDir)) {
  $OutDir = Join-Path "output\pc-brain" ("quiet-soak-" + (New-UtcTimestamp))
}
New-Item -ItemType Directory -Force -Path $OutDir | Out-Null
$ResolvedOutDir = (Resolve-Path $OutDir).Path

$summary = [ordered]@{
  schema = "stackchan.pc-brain-quiet-soak.v1"
  generated_at = (Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")
  device_host = $DeviceHost
  debug_port = $DebugPort
  requested_duration_seconds = $DurationSeconds
  interval_seconds = $IntervalSeconds
  duration_seconds = 0
  poll_count = 0
  status = "fail"
  issues = @()
  records = @()
}

$deadline = (Get-Date).AddSeconds($DurationSeconds)
$lastPoll = $null
$started = Get-Date
do {
  if ($lastPoll) {
    $sleepSeconds = [Math]::Max(0, [Math]::Min($IntervalSeconds, [int]([Math]::Ceiling(($deadline - (Get-Date)).TotalSeconds))))
    if ($sleepSeconds -gt 0) {
      Start-Sleep -Seconds $sleepSeconds
    }
  }
  $lastPoll = Get-Date

  $record = [ordered]@{
    timestamp = (Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")
    network_state = ""
    bridge_state = ""
    handshakes = 0
    bridge_messages = 0
    bridge_parse_errors = 0
    bridge_timeouts = 0
    bridge_outputs_dropped = 0
    audio_streams_started = 0
    bridge_downlink_errors = 0
    bridge_downlink_playback_errors = 0
    speaker_volume = 0
    speaker_channel_state = 0
    local_ip = ""
    heap_note = "debug-endpoint-unset"
  }

  try {
    $debugUri = "http://$DeviceHost`:$DebugPort/"
    $response = Invoke-WebRequest -Uri $debugUri -UseBasicParsing -TimeoutSec 8
    $debug = [string]$response.Content | ConvertFrom-Json
    $record.network_state = [string]$debug.network_state
    $record.bridge_state = [string]$debug.bridge_state
    $record.handshakes = Get-IntValue $debug "handshakes" 0
    $record.bridge_messages = Get-IntValue $debug "bridge_messages" 0
    $record.bridge_parse_errors = Get-IntValue $debug "bridge_parse_errors" 0
    $record.bridge_timeouts = Get-IntValue $debug "bridge_timeouts" 0
    $record.bridge_outputs_dropped = Get-IntValue $debug "bridge_outputs_dropped" 0
    $record.audio_streams_started = Get-IntValue $debug "audio_streams_started" 0
    $record.bridge_downlink_errors = Get-IntValue $debug "bridge_downlink_errors" 0
    $record.bridge_downlink_playback_errors = Get-IntValue $debug "bridge_downlink_playback_errors" 0
    $record.speaker_volume = Get-IntValue $debug "speaker_volume" 0
    $record.speaker_channel_state = Get-IntValue $debug "speaker_channel_state" 0
    $record.local_ip = [string]$debug.local_ip
    $record.heap_note = "debug-endpoint-ok"
  } catch {
    $record.heap_note = "debug-endpoint-error: $($_.Exception.Message)"
    $summary.issues += "debug_poll_failed"
  }

  $summary.records += $record
} while ((Get-Date) -lt $deadline)

$summary.duration_seconds = [int][Math]::Round(((Get-Date) - $started).TotalSeconds)
$summary.poll_count = @($summary.records).Count

if ($summary.poll_count -lt 2) { $summary.issues += "too_few_polls" }
foreach ($record in @($summary.records)) {
  if ($record.heap_note -ne "debug-endpoint-ok") { $summary.issues += "debug_endpoint_error" }
  if ($record.network_state -ne "connected") { $summary.issues += "network_not_connected" }
  if ($record.bridge_state -ne "ready") { $summary.issues += "bridge_not_ready" }
  if ([int]$record.bridge_outputs_dropped -ne 0) { $summary.issues += "bridge_outputs_dropped" }
  if ([int]$record.bridge_parse_errors -ne 0) { $summary.issues += "bridge_parse_errors" }
  if ([int]$record.bridge_timeouts -ne 0) { $summary.issues += "bridge_timeouts" }
  if ([int]$record.bridge_downlink_errors -ne 0) { $summary.issues += "bridge_downlink_errors" }
  if ([int]$record.bridge_downlink_playback_errors -ne 0) { $summary.issues += "bridge_downlink_playback_errors" }
}

$audioStarts = @($summary.records | ForEach-Object { [int]$_.audio_streams_started })
if ($audioStarts.Count -gt 1 -and (($audioStarts[-1] - $audioStarts[0]) -ne 0)) {
  $summary.issues += "unexpected_audio_stream_during_quiet_soak"
}

$summary.issues = @($summary.issues | Select-Object -Unique)
if ($summary.issues.Count -eq 0) {
  $summary.status = "pass"
}

$jsonPath = Join-Path $ResolvedOutDir "PC_BRAIN_QUIET_SOAK.json"
Write-JsonFile $jsonPath $summary

$markdownPath = Join-Path $ResolvedOutDir "PC_BRAIN_QUIET_SOAK.md"
$lines = @(
  "# Stackchan PC Brain Quiet Soak",
  "",
  "- Status: ``$($summary.status)``",
  "- Requested duration seconds: ``$($summary.requested_duration_seconds)``",
  "- Duration seconds: ``$($summary.duration_seconds)``",
  "- Interval seconds: ``$($summary.interval_seconds)``",
  "- Poll count: ``$($summary.poll_count)``",
  "",
  "## Polls"
)
foreach ($record in @($summary.records)) {
  $lines += "- ``$($record.timestamp)`` network=``$($record.network_state)`` bridge=``$($record.bridge_state)`` messages=``$($record.bridge_messages)`` audio_streams=``$($record.audio_streams_started)`` speaker_volume=``$($record.speaker_volume)``"
}
if ($summary.issues.Count -gt 0) {
  $lines += ""
  $lines += "## Issues"
  foreach ($issue in $summary.issues) {
    $lines += "- ``$issue``"
  }
}
$lines | Set-Content -LiteralPath $markdownPath -Encoding UTF8

Write-Host "[pc-brain-quiet-soak] status=$($summary.status) out_dir=$ResolvedOutDir"
exit $(if ($summary.status -eq "pass") { 0 } else { 1 })
