param(
  [string]$EvidenceJsonPath = "",
  [string]$EvidenceMarkdownPath = "",
  [string]$ReviewPath = "",
  [switch]$RequireTests,
  [switch]$RequireReady,
  [switch]$Json
)

$ErrorActionPreference = "Stop"

function Add-Check {
  param(
    [string]$Id,
    [ValidateSet("pass", "fail", "pending")]
    [string]$Status,
    [string]$Detail
  )
  $script:checks += [ordered]@{
    id = $Id
    status = $Status
    detail = $Detail
  }
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

function Test-ZeroCounter {
  param(
    $Object,
    [string]$Name
  )
  $value = Get-IntValue $Object $Name 0
  Add-Check $Name ($(if ($value -eq 0) { "pass" } else { "fail" })) "$Name=$value"
}

function Test-Commit {
  param([string]$Value)
  return $Value -match "^[a-fA-F0-9]{40}$"
}

function Get-ReviewSourceCommit {
  param([string]$Text)

  $match = [regex]::Match($Text, "(?im)^-\s*Source commit:\s*([a-fA-F0-9]{40})\s*$")
  if ($match.Success) {
    return $match.Groups[1].Value
  }
  return ""
}

if ([string]::IsNullOrWhiteSpace($EvidenceJsonPath)) {
  $candidates = Get-ChildItem -Path "output\pc-brain" -Recurse -Filter "PC_BRAIN_DEPLOY_EVIDENCE.json" -File -ErrorAction SilentlyContinue |
    Sort-Object LastWriteTime -Descending
  if ($candidates.Count -gt 0) {
    $EvidenceJsonPath = $candidates[0].FullName
  }
}

$checks = @()
$evidence = $null
$debug = $null
$sourceCommit = ""

if ([string]::IsNullOrWhiteSpace($EvidenceJsonPath)) {
  Add-Check "evidence-json" "pending" "Pass -EvidenceJsonPath or place PC_BRAIN_DEPLOY_EVIDENCE.json under output\pc-brain."
} elseif (-not (Test-Path -LiteralPath $EvidenceJsonPath -PathType Leaf)) {
  Add-Check "evidence-json" "fail" "Missing evidence JSON: $EvidenceJsonPath"
} else {
  Add-Check "evidence-json" "pass" "Found evidence JSON: $EvidenceJsonPath"
  try {
    $evidence = Get-Content -LiteralPath $EvidenceJsonPath -Raw | ConvertFrom-Json
  } catch {
    Add-Check "evidence-json-parse" "fail" "Evidence JSON is invalid: $($_.Exception.Message)"
  }
}

if ($evidence) {
  Add-Check "schema" ($(if ($evidence.schema -eq "stackchan.pc-brain-deploy-evidence.v1") { "pass" } else { "fail" })) "schema=$($evidence.schema)"
  Add-Check "collector-status" ($(if ($evidence.status -eq "pass") { "pass" } else { "fail" })) "status=$($evidence.status)"
  $sourceCommit = [string]$evidence.sourceCommit
  Add-Check "source-commit" ($(if (Test-Commit $sourceCommit) { "pass" } else { "fail" })) "sourceCommit=$sourceCommit"

  $issues = @($evidence.issues)
  Add-Check "collector-issues" ($(if ($issues.Count -eq 0) { "pass" } else { "fail" })) "issues=$($issues -join ', ')"

  if ($null -ne $evidence.pc_brain_process -and -not [string]::IsNullOrWhiteSpace([string]$evidence.pc_brain_process.command_line)) {
    $commandLine = [string]$evidence.pc_brain_process.command_line
    Add-Check "pc-brain-process" "pass" "pid=$($evidence.pc_brain_process.pid)"
    foreach ($pattern in @("lan_service.py", "ollama_stackchan_runner.py", "selected_voice_tts.py", "--require-runner")) {
      Add-Check "pc-brain-command-$pattern" ($(if ($commandLine -match [regex]::Escape($pattern)) { "pass" } else { "fail" })) "command includes $pattern"
    }
  } else {
    Add-Check "pc-brain-process" "fail" "PC brain process details are missing."
  }

  $debug = $evidence.device_debug
  if ($null -eq $debug) {
    Add-Check "device-debug" "fail" "Device debug payload is missing."
  } else {
    Add-Check "device-debug" "pass" "Device debug payload is present."
    Add-Check "debug-schema" ($(if ($debug.schema -eq "stackchan.bridge-debug.v1") { "pass" } else { "fail" })) "schema=$($debug.schema)"
    Add-Check "wifi-connected" ($(if ($debug.wifi_connected -eq $true) { "pass" } else { "fail" })) "wifi_connected=$($debug.wifi_connected)"
    Add-Check "network-connected" ($(if ($debug.network_state -eq "connected") { "pass" } else { "fail" })) "network_state=$($debug.network_state)"
    Add-Check "bridge-ready" ($(if ($debug.bridge_state -eq "ready") { "pass" } else { "fail" })) "bridge_state=$($debug.bridge_state)"
    Add-Check "playback-ready" ($(if ($debug.bridge_downlink_playback_ready -eq $true) { "pass" } else { "fail" })) "bridge_downlink_playback_ready=$($debug.bridge_downlink_playback_ready)"
    Add-Check "speaker-enabled" ($(if ((Get-IntValue $debug "speaker_enabled" 0) -eq 1) { "pass" } else { "fail" })) "speaker_enabled=$($debug.speaker_enabled)"
    Add-Check "speaker-volume-safe" ($(if ((Get-IntValue $debug "speaker_volume" 0) -gt 0 -and (Get-IntValue $debug "speaker_volume" 0) -le 180) { "pass" } else { "fail" })) "speaker_volume=$($debug.speaker_volume)"

    foreach ($counter in @(
      "bridge_outputs_dropped",
      "bridge_parse_errors",
      "bridge_timeouts",
      "audio_stream_errors",
      "bridge_downlink_errors",
      "bridge_downlink_playback_errors",
      "bridge_downlink_playback_unsupported",
      "speaker_stream_play_raw_failed"
    )) {
      Test-ZeroCounter $debug $counter
    }

    $audioStarts = Get-IntValue $debug "audio_streams_started" 0
    $audioEnds = Get-IntValue $debug "audio_streams_ended" 0
    $expectedBytes = Get-IntValue $debug "audio_stream_bytes_expected" 0
    $receivedBytes = Get-IntValue $debug "audio_stream_bytes_received" 0
    $expectedChunks = Get-IntValue $debug "audio_stream_chunks_expected" 0
    $receivedChunks = Get-IntValue $debug "audio_stream_chunks_received" 0
    $downlinkStreams = Get-IntValue $debug "bridge_downlink_streams" 0
    $downlinkCompleted = Get-IntValue $debug "bridge_downlink_completed" 0
    $downlinkBytes = Get-IntValue $debug "bridge_downlink_bytes" 0
    $downlinkChunks = Get-IntValue $debug "bridge_downlink_chunks" 0
    $playbackStarts = Get-IntValue $debug "bridge_downlink_playback_starts" 0
    $playbackBytes = Get-IntValue $debug "bridge_downlink_playback_bytes" 0
    $playbackChunks = Get-IntValue $debug "bridge_downlink_playback_chunks" 0
    $speakerTaskBytes = Get-IntValue $debug "speaker_stream_task_bytes" 0
    $speakerTaskChunks = Get-IntValue $debug "speaker_stream_task_chunks" 0

    Add-Check "audio-stream-started" ($(if ($audioStarts -ge 1) { "pass" } else { "fail" })) "audio_streams_started=$audioStarts"
    Add-Check "audio-stream-ended" ($(if ($audioEnds -ge 1) { "pass" } else { "fail" })) "audio_streams_ended=$audioEnds"
    Add-Check "audio-stream-inactive" ($(if ($debug.audio_stream_active -eq $false) { "pass" } else { "fail" })) "audio_stream_active=$($debug.audio_stream_active)"
    Add-Check "audio-stream-bytes-match" ($(if ($expectedBytes -gt 0 -and $expectedBytes -eq $receivedBytes) { "pass" } else { "fail" })) "bytes=$receivedBytes/$expectedBytes"
    Add-Check "audio-stream-chunks-match" ($(if ($expectedChunks -gt 0 -and $expectedChunks -eq $receivedChunks) { "pass" } else { "fail" })) "chunks=$receivedChunks/$expectedChunks"
    Add-Check "downlink-stream-completed" ($(if ($downlinkStreams -ge 1 -and $downlinkCompleted -ge 1) { "pass" } else { "fail" })) "streams=$downlinkStreams completed=$downlinkCompleted"
    Add-Check "downlink-bytes-match" ($(if ($downlinkBytes -eq $expectedBytes -and $downlinkBytes -gt 0) { "pass" } else { "fail" })) "downlink_bytes=$downlinkBytes expected=$expectedBytes"
    Add-Check "downlink-chunks-match" ($(if ($downlinkChunks -eq $expectedChunks -and $downlinkChunks -gt 0) { "pass" } else { "fail" })) "downlink_chunks=$downlinkChunks expected=$expectedChunks"
    Add-Check "playback-started" ($(if ($playbackStarts -ge 1) { "pass" } else { "fail" })) "bridge_downlink_playback_starts=$playbackStarts"
    Add-Check "playback-bytes-match" ($(if ($playbackBytes -eq $expectedBytes -and $playbackBytes -gt 0) { "pass" } else { "fail" })) "playback_bytes=$playbackBytes expected=$expectedBytes"
    Add-Check "playback-chunks-match" ($(if ($playbackChunks -eq $expectedChunks -and $playbackChunks -gt 0) { "pass" } else { "fail" })) "playback_chunks=$playbackChunks expected=$expectedChunks"
    Add-Check "speaker-task-bytes-match" ($(if ($speakerTaskBytes -eq $expectedBytes -and $speakerTaskBytes -gt 0) { "pass" } else { "fail" })) "speaker_task_bytes=$speakerTaskBytes expected=$expectedBytes"
    Add-Check "speaker-task-chunks-match" ($(if ($speakerTaskChunks -eq $expectedChunks -and $speakerTaskChunks -gt 0) { "pass" } else { "fail" })) "speaker_task_chunks=$speakerTaskChunks expected=$expectedChunks"
  }

  if ($RequireTests) {
    $tests = @($evidence.tests)
    $native = $tests | Where-Object { $_.name -match "pio test -e native_logic" } | Select-Object -First 1
    $bridge = $tests | Where-Object { $_.name -match "bridge deploy suites" } | Select-Object -First 1
    Add-Check "native-tests" ($(if ($null -ne $native -and [int]$native.exit_code -eq 0) { "pass" } else { "fail" })) "native test exit=$($native.exit_code)"
    Add-Check "bridge-tests" ($(if ($null -ne $bridge -and [int]$bridge.exit_code -eq 0) { "pass" } else { "fail" })) "bridge test exit=$($bridge.exit_code)"
  }
}

if (-not [string]::IsNullOrWhiteSpace($EvidenceMarkdownPath)) {
  if (-not (Test-Path -LiteralPath $EvidenceMarkdownPath -PathType Leaf)) {
    Add-Check "evidence-markdown" "fail" "Missing evidence markdown: $EvidenceMarkdownPath"
  } else {
    $markdown = Get-Content -LiteralPath $EvidenceMarkdownPath -Raw
    foreach ($pattern in @("Stackchan PC Brain Deploy Evidence", "Status: ``pass``", "Audio streams:", "Playback:")) {
      Add-Check "evidence-markdown-$pattern" ($(if ($markdown -match [regex]::Escape($pattern)) { "pass" } else { "fail" })) "markdown includes $pattern"
    }
    Add-Check "evidence-markdown-source-commit" ($(if ($markdown -match "Source commit:\s*``[a-fA-F0-9]{40}``") { "pass" } else { "fail" })) "markdown includes source commit"
  }
}

if (-not [string]::IsNullOrWhiteSpace($ReviewPath)) {
  if (-not (Test-Path -LiteralPath $ReviewPath -PathType Leaf)) {
    Add-Check "human-review" "fail" "Missing review file: $ReviewPath"
  } else {
    $review = Get-Content -LiteralPath $ReviewPath -Raw
    foreach ($pattern in @(
      "Source commit:",
      "Support decision: pass",
      "Robot connection decision: pass",
      "Audio downlink decision: pass",
      "Speaker playback decision: pass",
      "Safety volume decision: pass"
    )) {
      Add-Check "human-review-$pattern" ($(if ($review -match [regex]::Escape($pattern)) { "pass" } else { "fail" })) "review includes $pattern"
    }
    $reviewSourceCommit = Get-ReviewSourceCommit $review
    Add-Check "human-review-source-commit-match" ($(if ((Test-Commit $reviewSourceCommit) -and $reviewSourceCommit -eq $sourceCommit) { "pass" } else { "fail" })) "review sourceCommit=$reviewSourceCommit evidence sourceCommit=$sourceCommit"
  }
}

$failed = @($checks | Where-Object { $_.status -eq "fail" })
$pending = @($checks | Where-Object { $_.status -eq "pending" })
$status = if ($failed.Count -gt 0) {
  "pc-brain-deploy-not-ready"
} elseif ($pending.Count -gt 0) {
  "pending-pc-brain-deploy-evidence"
} else {
  "pc-brain-deploy-ready"
}

$result = [ordered]@{
  schema = "stackchan.pc-brain-deploy-evidence-check.v1"
  status = $status
  sourceCommit = $sourceCommit
  evidenceJsonPath = $EvidenceJsonPath
  evidenceMarkdownPath = $EvidenceMarkdownPath
  reviewPath = $ReviewPath
  passed = @($checks | Where-Object { $_.status -eq "pass" }).Count
  failed = $failed.Count
  pending = $pending.Count
  checks = $checks
}

if ($Json) {
  $result | ConvertTo-Json -Depth 8
} else {
  Write-Host "PC Brain deploy evidence: $status"
  foreach ($check in $checks) {
    Write-Host "[$($check.status)] $($check.id): $($check.detail)"
  }
}

if ($failed.Count -gt 0 -or ($RequireReady -and $status -ne "pc-brain-deploy-ready")) {
  exit 1
}
