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

function Test-HasProperty {
  param(
    $Object,
    [string]$Name
  )
  if ($null -eq $Object) { return $false }
  return $null -ne $Object.PSObject.Properties[$Name]
}

function Normalize-CommandLine {
  param([string]$CommandLine)
  return ($CommandLine -replace "\\", "/" -replace "\s+", " ").Trim().ToLowerInvariant()
}

function Test-ExactFlag {
  param(
    [string]$NormalizedCommandLine,
    [string]$Flag
  )
  $pattern = "(?:^|\s)" + [regex]::Escape($Flag.ToLowerInvariant()) + "(?:\s|$)"
  return [regex]::IsMatch($NormalizedCommandLine, $pattern)
}

function Test-ExactTtsCommand {
  param(
    [string]$NormalizedCommandLine,
    [string]$Script
  )
  $expected = '--tts-command\s+"python\s+' +
    [regex]::Escape(($Script -replace "\\", "/").ToLowerInvariant()) + '"'
  return [regex]::IsMatch($NormalizedCommandLine, "(?:^|\s)" + $expected + "(?:\s|$)")
}

function Test-ExactOptionValue {
  param(
    [string]$NormalizedCommandLine,
    [string]$Option,
    [string]$Value
  )
  $pattern = "(?:^|\s)" + [regex]::Escape($Option.ToLowerInvariant()) +
    "\s+" + [regex]::Escape($Value.ToLowerInvariant()) + "(?:\s|$)"
  return [regex]::IsMatch($NormalizedCommandLine, $pattern)
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
    $normalizedCommandLine = Normalize-CommandLine $commandLine
    Add-Check "pc-brain-process" "pass" "pid=$($evidence.pc_brain_process.pid)"
    foreach ($pattern in @("lan_service.py", "ollama_stackchan_runner.py", "--require-runner")) {
      Add-Check "pc-brain-command-$pattern" ($(if ($commandLine -match [regex]::Escape($pattern)) { "pass" } else { "fail" })) "command includes $pattern"
    }
    $selectedVoiceTts = Test-ExactTtsCommand $normalizedCommandLine "bridge/selected_voice_tts.py"
    $productionDirectMlTts =
      (Test-ExactTtsCommand $normalizedCommandLine "bridge/rvc_production_tts_client.py") -and
      (Test-ExactFlag $normalizedCommandLine "--in-process-directml-tts") -and
      (Test-ExactOptionValue $normalizedCommandLine "--tts-voice" "stackchan-rvc-directml-v2")
    Add-Check "pc-brain-command-tts" `
      ($(if ($selectedVoiceTts -or $productionDirectMlTts) { "pass" } else { "fail" })) `
      "TTS is exact selected-voice smoke or production in-process DirectML command."
  } else {
    Add-Check "pc-brain-process" "fail" "PC brain process details are missing."
  }

  $debug = $evidence.device_debug
  if ($null -eq $debug) {
    Add-Check "device-debug" "fail" "Device debug payload is missing."
  } else {
    Add-Check "device-debug" "pass" "Device debug payload is present."
    Add-Check "debug-schema" ($(if ($debug.schema -eq "stackchan.bridge-debug.v1") { "pass" } else { "fail" })) "schema=$($debug.schema)"
    Add-Check "debug-route" ($(if ($debug.debug_request_route -eq "debug") { "pass" } else { "fail" })) "debug_request_route=$($debug.debug_request_route)"
    Add-Check "debug-result" ($(if ($debug.debug_request_result -eq "debug") { "pass" } else { "fail" })) "debug_request_result=$($debug.debug_request_result)"
    Add-Check "wifi-connected" ($(if ($debug.wifi_connected -eq $true) { "pass" } else { "fail" })) "wifi_connected=$($debug.wifi_connected)"
    Add-Check "network-connected" ($(if ($debug.network_state -eq "connected") { "pass" } else { "fail" })) "network_state=$($debug.network_state)"
    Add-Check "bridge-ready" ($(if ($debug.bridge_state -eq "ready") { "pass" } else { "fail" })) "bridge_state=$($debug.bridge_state)"
    Add-Check "speaker-enabled" ($(if ((Get-IntValue $debug "speaker_enabled" 0) -eq 1) { "pass" } else { "fail" })) "speaker_enabled=$($debug.speaker_enabled)"
    Add-Check "speaker-volume-safe" ($(if ((Get-IntValue $debug "speaker_volume" 0) -gt 0 -and (Get-IntValue $debug "speaker_volume" 0) -le 180) { "pass" } else { "fail" })) "speaker_volume=$($debug.speaker_volume)"

    $requiredPlaybackFields = @(
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
    $missingPlaybackFields = @($requiredPlaybackFields | Where-Object { -not (Test-HasProperty $debug $_) })
    foreach ($field in $missingPlaybackFields) {
      Add-Check "device-debug-field-$field" "fail" "Required current /debug field is missing: $field"
    }

    if ($missingPlaybackFields.Count -eq 0) {
      foreach ($counter in @(
        "bridge_downlink_playback_errors",
        "speaker_stream_play_raw_failed",
        "speaker_stream_forced_stops",
        "speaker_stream_orphan_stops"
      )) {
        Test-ZeroCounter $debug $counter
      }

      $playbackStarts = Get-IntValue $debug "bridge_downlink_playback_starts" -1
      $playbackBytes = Get-IntValue $debug "bridge_downlink_playback_bytes" -1
      $playbackChunks = Get-IntValue $debug "bridge_downlink_playback_chunks" -1
      $playbackStops = Get-IntValue $debug "bridge_downlink_playback_stops" -1
      $playbackCompletions = Get-IntValue $debug "bridge_downlink_playback_completions" -1
      $playbackSignals = Get-IntValue $debug "bridge_downlink_playback_completion_signals" -1
      $speakerRawOk = Get-IntValue $debug "speaker_stream_play_raw_ok" -1

      Add-Check "playback-started" ($(if ($playbackStarts -ge 1) { "pass" } else { "fail" })) "starts=$playbackStarts"
      Add-Check "playback-payload-present" ($(if ($playbackBytes -gt 0 -and $playbackChunks -gt 0) { "pass" } else { "fail" })) "chunks=$playbackChunks bytes=$playbackBytes"
      Add-Check "playback-completed" ($(if ($playbackStarts -ge 1 -and $playbackStops -eq $playbackStarts -and $playbackCompletions -eq $playbackStarts) { "pass" } else { "fail" })) "starts=$playbackStarts stops=$playbackStops completions=$playbackCompletions"
      Add-Check "playback-completion-signaled" ($(if ($playbackSignals -eq $playbackCompletions -and $playbackSignals -gt 0) { "pass" } else { "fail" })) "signals=$playbackSignals completions=$playbackCompletions"
      Add-Check "playback-drained" ($(if (-not [bool]$debug.bridge_downlink_playback_awaiting_drain -and -not [bool]$debug.bridge_downlink_playback_completion_pending) { "pass" } else { "fail" })) "awaiting_drain=$($debug.bridge_downlink_playback_awaiting_drain) completion_pending=$($debug.bridge_downlink_playback_completion_pending)"
      Add-Check "audio-stream-inactive" ($(if (-not [bool]$debug.audio_stream_active) { "pass" } else { "fail" })) "audio_stream_active=$($debug.audio_stream_active)"
      Add-Check "speaker-playback-chunks-match" ($(if ($speakerRawOk -eq $playbackChunks -and $speakerRawOk -gt 0) { "pass" } else { "fail" })) "raw_ok=$speakerRawOk playback_chunks=$playbackChunks"
      Add-Check "speaker-playback-idle" ($(if (-not [bool]$debug.speaker_running -and (Get-IntValue $debug "speaker_channel_state" -1) -eq 0) { "pass" } else { "fail" })) "speaker_running=$($debug.speaker_running) channel_state=$($debug.speaker_channel_state)"
    }
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
    foreach ($pattern in @("Stackchan PC Brain Deploy Evidence", "Status: ``pass``", "Playback:", "Playback payload:", "Speaker sink:")) {
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
