param(
  [string]$EvidenceRoot = "",
  [string]$ReportDir = "",
  [string]$DeviceHost = "",
  [string]$DebugUrl = "",
  [switch]$RequireHumanEvidence,
  [switch]$RequireFullOnline,
  [switch]$Json
)

$ErrorActionPreference = "Stop"

$repoRoot = Resolve-Path (Join-Path $PSScriptRoot "..")
Set-Location $repoRoot

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

function Read-JsonFile {
  param([string]$Path)
  return Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json
}

function Write-DeployCheckMarkdown {
  param(
    [string]$Path,
    $Result
  )

  $lines = @(
    "# Stackchan First PC Brain Deploy Check",
    "",
    "- Schema: ``$($Result.schema)``",
    "- Status: ``$($Result.status)``",
    "- Machine ready: ``$($Result.machineReady)``",
    "- Passed: ``$($Result.passed)``",
    "- Failed: ``$($Result.failed)``",
    "- Pending: ``$($Result.pending)``",
    "- Evidence root: ``$($Result.evidenceRoot)``",
    "",
    "## Pending",
    ""
  )

  $pendingChecks = @($Result.checks | Where-Object { $_.status -eq "pending" })
  if ($pendingChecks.Count -eq 0) {
    $lines += "- none"
  } else {
    foreach ($check in $pendingChecks) {
      $lines += "- ``$($check.id)``: $($check.detail)"
    }
  }

  $failedChecks = @($Result.checks | Where-Object { $_.status -eq "fail" })
  if ($failedChecks.Count -gt 0) {
    $lines += ""
    $lines += "## Failed"
    foreach ($check in $failedChecks) {
      $lines += "- ``$($check.id)``: $($check.detail)"
    }
  }

  $lines += ""
  $lines += "## Passed"
  foreach ($check in @($Result.checks | Where-Object { $_.status -eq "pass" })) {
    $lines += "- ``$($check.id)``: $($check.detail)"
  }

  $lines | Set-Content -LiteralPath $Path -Encoding UTF8
}

if ([string]::IsNullOrWhiteSpace($EvidenceRoot)) {
  $candidate = Get-ChildItem -Directory -Path "output\hardware-evidence" -ErrorAction SilentlyContinue |
    Where-Object { $_.Name -like "pc-brain-first-deploy-*" } |
    Sort-Object LastWriteTime -Descending |
    Select-Object -First 1
  if ($null -ne $candidate) {
    $EvidenceRoot = $candidate.FullName
  }
}

$checks = @()
$evidencePath = ""
$liveDebug = $null
$liveDebugPath = ""

if ([string]::IsNullOrWhiteSpace($EvidenceRoot)) {
  Add-Check "evidence-root" "pending" "Pass -EvidenceRoot or create output\hardware-evidence\pc-brain-first-deploy-*."
} elseif (-not (Test-Path -LiteralPath $EvidenceRoot -PathType Container)) {
  Add-Check "evidence-root" "fail" "Missing evidence root: $EvidenceRoot"
} else {
  $evidencePath = (Resolve-Path $EvidenceRoot).Path
  Add-Check "evidence-root" "pass" $evidencePath
}

if ($evidencePath) {
  $pcBrainDir = Join-Path $evidencePath "pc-brain"
  $deployJsonPath = Join-Path $pcBrainDir "PC_BRAIN_DEPLOY_EVIDENCE.json"
  $soakJsonPath = Join-Path $pcBrainDir "PC_BRAIN_QUIET_SOAK.json"
  $serialLogPath = Join-Path $pcBrainDir "post_flash_voice_turn_serial.log"
  $reviewPath = Join-Path $evidencePath "FIRST_PC_BRAIN_DEPLOY_REVIEW.md"
  $deployModePath = Join-Path $evidencePath "DEPLOY_MODE.md"
  $humanReviewPath = Join-Path $evidencePath "HUMAN_EVIDENCE_REVIEW.md"
  $audioReviewPath = Join-Path $evidencePath "AUDIO_REVIEW.md"
  $mediaManifestPath = Join-Path $evidencePath "media_manifest.json"

  foreach ($file in @(
      @{ id = "deploy-json"; path = $deployJsonPath },
      @{ id = "quiet-soak-json"; path = $soakJsonPath },
      @{ id = "serial-voice-turn-log"; path = $serialLogPath },
      @{ id = "first-deploy-review"; path = $reviewPath },
      @{ id = "deploy-mode"; path = $deployModePath },
      @{ id = "human-review"; path = $humanReviewPath },
      @{ id = "audio-review"; path = $audioReviewPath }
    )) {
    Add-Check $file.id ($(if (Test-Path -LiteralPath $file.path -PathType Leaf) { "pass" } else { "fail" })) $file.path
  }

  if (Test-Path -LiteralPath $deployJsonPath -PathType Leaf) {
    try {
      $deploy = Read-JsonFile $deployJsonPath
      Add-Check "deploy-status" ($(if ($deploy.status -eq "pass") { "pass" } else { "fail" })) "status=$($deploy.status)"
      $issues = @($deploy.issues)
      Add-Check "deploy-issues" ($(if ($issues.Count -eq 0) { "pass" } else { "fail" })) "issues=$($issues -join ', ')"
      $debug = $deploy.device_debug
      Add-Check "deploy-network-ready" ($(if ($debug.network_state -eq "connected" -and $debug.bridge_state -eq "ready") { "pass" } else { "fail" })) "network=$($debug.network_state) bridge=$($debug.bridge_state)"
      Add-Check "deploy-network-error-clear" ($(if ([string]$debug.network_error -eq "") { "pass" } else { "fail" })) "network_error=$($debug.network_error)"
      Add-Check "deploy-volume-150" ($(if ((Get-IntValue $debug "speaker_volume" 0) -eq 150) { "pass" } else { "fail" })) "speaker_volume=$($debug.speaker_volume)"
      Add-Check "deploy-audio-stream" ($(if ((Get-IntValue $debug "audio_streams_started" 0) -ge 1 -and (Get-IntValue $debug "audio_streams_ended" 0) -ge 1) { "pass" } else { "fail" })) "streams=$($debug.audio_streams_started)/$($debug.audio_streams_ended)"
      Add-Check "deploy-audio-chunks" ($(if ((Get-IntValue $debug "audio_stream_chunks_received" 0) -eq 16 -and (Get-IntValue $debug "audio_stream_chunks_expected" 0) -eq 16) { "pass" } else { "fail" })) "chunks=$($debug.audio_stream_chunks_received)/$($debug.audio_stream_chunks_expected)"
      Add-Check "deploy-playback-errors" ($(if ((Get-IntValue $debug "bridge_downlink_playback_errors" 0) -eq 0 -and (Get-IntValue $debug "speaker_stream_play_raw_failed" 0) -eq 0) { "pass" } else { "fail" })) "playback_errors=$($debug.bridge_downlink_playback_errors) speaker_failed=$($debug.speaker_stream_play_raw_failed)"
    } catch {
      Add-Check "deploy-json-parse" "fail" $_.Exception.Message
    }
  }

  if (Test-Path -LiteralPath $soakJsonPath -PathType Leaf) {
    try {
      $soak = Read-JsonFile $soakJsonPath
      Add-Check "soak-status" ($(if ($soak.status -eq "pass") { "pass" } else { "fail" })) "status=$($soak.status)"
      Add-Check "soak-duration" ($(if ((Get-IntValue $soak "duration_seconds" 0) -ge 300) { "pass" } else { "fail" })) "duration_seconds=$($soak.duration_seconds)"
      Add-Check "soak-polls" ($(if ((Get-IntValue $soak "poll_count" 0) -ge 10) { "pass" } else { "fail" })) "poll_count=$($soak.poll_count)"
      $records = @($soak.records)
      $badRecords = @($records | Where-Object { $_.network_state -ne "connected" -or $_.bridge_state -ne "ready" })
      Add-Check "soak-ready-throughout" ($(if ($badRecords.Count -eq 0 -and $records.Count -gt 0) { "pass" } else { "fail" })) "bad_records=$($badRecords.Count)"
      if ($records.Count -gt 1) {
        $firstAudio = Get-IntValue $records[0] "audio_streams_started" 0
        $lastAudio = Get-IntValue $records[-1] "audio_streams_started" 0
        Add-Check "soak-no-extra-audio" ($(if ($firstAudio -eq $lastAudio) { "pass" } else { "fail" })) "audio_streams=$firstAudio->$lastAudio"
      }
    } catch {
      Add-Check "soak-json-parse" "fail" $_.Exception.Message
    }
  }

  if (Test-Path -LiteralPath $serialLogPath -PathType Leaf) {
    $serialLog = Get-Content -LiteralPath $serialLogPath -Raw
    foreach ($pattern in @(
        "network_state=connected",
        "[bridge_text_turn] result=accepted",
        "type=event state=thinking",
        "type=response_start",
        "type=audio_stream_start",
        "chunk_index=16",
        "type=audio_stream_end",
        "type=response_end"
      )) {
      Add-Check "serial-$pattern" ($(if ($serialLog -match [regex]::Escape($pattern)) { "pass" } else { "fail" })) "serial includes $pattern"
    }
  }

  if (Test-Path -LiteralPath $deployModePath -PathType Leaf) {
    $deployMode = Get-Content -LiteralPath $deployModePath -Raw
    Add-Check "deploy-mode-pc-brain" ($(if ($deployMode -match "PC Brain text-turn voice-out bench deploy") { "pass" } else { "fail" })) "DEPLOY_MODE declares PC Brain bench mode"
    Add-Check "deploy-mode-mic-scope" ($(if ($deployMode -match "Physical robot mic capture is not enabled") { "pass" } else { "fail" })) "DEPLOY_MODE documents mic/STT scope"
  }

  if (Test-Path -LiteralPath $humanReviewPath -PathType Leaf) {
    $humanReview = Get-Content -LiteralPath $humanReviewPath -Raw
    Add-Check "human-voice-heard" ($(if ($humanReview -match "(?m)^- Post-flash voice line heard:\s*yes\s*$") { "pass" } else { "pending" })) "Human heard post-flash voice line"
    Add-Check "human-voice-matched" ($(if ($humanReview -match '(?m)^- Voice matched selected `stackchan-rvc-bright-robot` direction:\s*yes\s*$') { "pass" } else { "pending" })) "Human confirms selected voice direction"
    Add-Check "human-volume-ok" ($(if ($humanReview -match '(?m)^- Volume at firmware `150` acceptable:\s*yes\s*$') { "pass" } else { "pending" })) "Human confirms volume 150"
    Add-Check "human-no-bad-audio" ($(if ($humanReview -match "(?m)^- Choppiness, clipping, or dropout heard:\s*no\s*$") { "pass" } else { "pending" })) "Human confirms no choppy/clipped/dropout audio"
  }

  $manifest = $null
  if (Test-Path -LiteralPath $mediaManifestPath -PathType Leaf) {
    try {
      $manifest = Read-JsonFile $mediaManifestPath
      Add-Check "media-manifest" "pass" $mediaManifestPath
    } catch {
      Add-Check "media-manifest" "fail" $_.Exception.Message
    }
  } else {
    Add-Check "media-manifest" "pending" "Import photo/audio with RUN_ADD_MEDIA.cmd."
  }

  if ($manifest) {
    $items = @($manifest.media)
    if ($items.Count -eq 0 -and $null -ne $manifest.items) {
      $items = @($manifest.items)
    }
    $photoItems = @($items | Where-Object { [string]$_.type -match "Photo|Video|photo|video" -or [string]$_.destination -match "photos/" })
    $audioItems = @($items | Where-Object { [string]$_.type -match "Audio|audio" -or [string]$_.destination -match "audio/" })
    Add-Check "photo-media" ($(if ($photoItems.Count -gt 0) { "pass" } else { "pending" })) "photo_or_video_items=$($photoItems.Count)"
    Add-Check "audio-media" ($(if ($audioItems.Count -gt 0) { "pass" } else { "pending" })) "audio_items=$($audioItems.Count)"
  } else {
    Add-Check "photo-media" "pending" "No imported face/display photo or video yet."
    Add-Check "audio-media" "pending" "No imported speaker recording yet."
  }

  if (Test-Path -LiteralPath $audioReviewPath -PathType Leaf) {
    $audioReview = Get-Content -LiteralPath $audioReviewPath -Raw
    Add-Check "audio-review-intelligible" ($(if ($audioReview -match "(?m)^- Intelligible through device speaker:\s*yes\s*$") { "pass" } else { "pending" })) "AUDIO_REVIEW intelligible yes"
    Add-Check "audio-review-no-clipping" ($(if ($audioReview -match "(?m)^- Clipping or distortion observed:\s*no\s*$") { "pass" } else { "pending" })) "AUDIO_REVIEW clipping no"
    Add-Check "audio-review-volume" ($(if ($audioReview -match "(?m)^- Volume adequate at normal listening distance:\s*yes\s*$") { "pass" } else { "pending" })) "AUDIO_REVIEW volume yes"
    Add-Check "audio-review-no-dropout" ($(if ($audioReview -match "(?m)^- Delay or playback dropout observed:\s*no\s*$") { "pass" } else { "pending" })) "AUDIO_REVIEW dropout no"
  }
}

if ([string]::IsNullOrWhiteSpace($DebugUrl) -and -not [string]::IsNullOrWhiteSpace($DeviceHost)) {
  $DebugUrl = "http://$DeviceHost`:8789/debug"
}

if (-not [string]::IsNullOrWhiteSpace($DebugUrl)) {
  try {
    $liveDebug = Invoke-RestMethod -Uri $DebugUrl -TimeoutSec 5
    Add-Check "live-debug-endpoint" "pass" $DebugUrl
    Add-Check "live-debug-schema" ($(if ($liveDebug.schema -eq "stackchan.bridge-debug.v1") { "pass" } else { "fail" })) "schema=$($liveDebug.schema)"
    Add-Check "live-debug-network-ready" ($(if ($liveDebug.network_state -eq "connected" -and $liveDebug.bridge_state -eq "ready") { "pass" } else { "fail" })) "network=$($liveDebug.network_state) bridge=$($liveDebug.bridge_state)"
    Add-Check "live-debug-network-error-clear" ($(if ([string]$liveDebug.network_error -eq "") { "pass" } else { "fail" })) "network_error=$($liveDebug.network_error)"
    Add-Check "live-debug-volume-150" ($(if ((Get-IntValue $liveDebug "speaker_volume" 0) -eq 150) { "pass" } else { "fail" })) "speaker_volume=$($liveDebug.speaker_volume)"
    Add-Check "live-debug-audio-idle" ($(if (-not [bool]$liveDebug.audio_stream_active) { "pass" } else { "fail" })) "audio_stream_active=$($liveDebug.audio_stream_active)"
    Add-Check "live-debug-playback-errors" ($(if ((Get-IntValue $liveDebug "bridge_downlink_playback_errors" 0) -eq 0 -and (Get-IntValue $liveDebug "speaker_stream_play_raw_failed" 0) -eq 0) { "pass" } else { "fail" })) "playback_errors=$($liveDebug.bridge_downlink_playback_errors) speaker_failed=$($liveDebug.speaker_stream_play_raw_failed)"
  } catch {
    Add-Check "live-debug-endpoint" "fail" "$DebugUrl :: $($_.Exception.Message)"
  }
} else {
  Add-Check "live-debug-endpoint" "pending" "Pass -DeviceHost or -DebugUrl to prove the robot is currently online."
}

if ($RequireFullOnline) {
  if ($null -eq $liveDebug) {
    Add-Check "full-online-live-debug" "pending" "Live debug is required to verify full-online mic/servo/uplink state."
  } else {
    Add-Check "full-online-servos-compiled" ($(if ((Get-IntValue $liveDebug "compiled_enable_servos" 0) -eq 1) { "pass" } else { "fail" })) "compiled_enable_servos=$($liveDebug.compiled_enable_servos)"
    Add-Check "full-online-speaker-compiled" ($(if ((Get-IntValue $liveDebug "compiled_enable_speaker" 0) -eq 1) { "pass" } else { "fail" })) "compiled_enable_speaker=$($liveDebug.compiled_enable_speaker)"
    Add-Check "full-online-mic-compiled" ($(if ((Get-IntValue $liveDebug "compiled_enable_mic_capture" 0) -eq 1) { "pass" } else { "fail" })) "compiled_enable_mic_capture=$($liveDebug.compiled_enable_mic_capture)"
    Add-Check "full-online-uplink-compiled" ($(if ((Get-IntValue $liveDebug "compiled_enable_bridge_audio_uplink" 0) -eq 1) { "pass" } else { "fail" })) "compiled_enable_bridge_audio_uplink=$($liveDebug.compiled_enable_bridge_audio_uplink)"
    Add-Check "full-online-motion-enabled" ($(if ([bool]$liveDebug.motion_enabled) { "pass" } else { "fail" })) "motion_enabled=$($liveDebug.motion_enabled)"
    Add-Check "full-online-audio-capture-enabled" ($(if ([bool]$liveDebug.audio_capture_enabled) { "pass" } else { "fail" })) "audio_capture_enabled=$($liveDebug.audio_capture_enabled)"
    Add-Check "full-online-audio-capture-hw" ($(if ([bool]$liveDebug.audio_capture_hw_ready) { "pass" } else { "fail" })) "audio_capture_hw_ready=$($liveDebug.audio_capture_hw_ready)"
    Add-Check "full-online-uplink-ready" ($(if ([bool]$liveDebug.bridge_uplink_ready -and [bool]$liveDebug.bridge_uplink_enabled) { "pass" } else { "fail" })) "bridge_uplink_ready=$($liveDebug.bridge_uplink_ready) bridge_uplink_enabled=$($liveDebug.bridge_uplink_enabled)"
    Add-Check "full-online-wake-gate-ready" ($(if ([bool]$liveDebug.bridge_wake_gate_ready) { "pass" } else { "fail" })) "bridge_wake_gate_ready=$($liveDebug.bridge_wake_gate_ready)"
    Add-Check "full-online-uplink-no-errors" ($(if ((Get-IntValue $liveDebug "bridge_uplink_errors" 0) -eq 0 -and (Get-IntValue $liveDebug "bridge_uplink_queue_failures" 0) -eq 0) { "pass" } else { "fail" })) "bridge_uplink_errors=$($liveDebug.bridge_uplink_errors) queue_failures=$($liveDebug.bridge_uplink_queue_failures)"
  }
}

$failed = @($checks | Where-Object { $_.status -eq "fail" })
$pending = @($checks | Where-Object { $_.status -eq "pending" })
$machineFailures = @($failed | Where-Object { $_.id -notmatch "media|audio-review|photo" })
$status = if ($failed.Count -gt 0) {
  "first-pc-brain-deploy-not-ready"
} elseif ($pending.Count -gt 0) {
  "first-pc-brain-deploy-pending-human-evidence"
} else {
  "first-pc-brain-deploy-ready"
}

$result = [ordered]@{
  schema = "stackchan.first-pc-brain-deploy-check.v1"
  status = $status
  evidenceRoot = $evidencePath
  machineReady = ($machineFailures.Count -eq 0)
  passed = @($checks | Where-Object { $_.status -eq "pass" }).Count
  failed = $failed.Count
  pending = $pending.Count
  liveDebugUrl = $DebugUrl
  liveDebugPath = $liveDebugPath
  checks = $checks
}

if (-not [string]::IsNullOrWhiteSpace($ReportDir)) {
  New-Item -ItemType Directory -Force -Path $ReportDir | Out-Null
  $resolvedReportDir = (Resolve-Path $ReportDir).Path
  $jsonReportPath = Join-Path $resolvedReportDir "FIRST_PC_BRAIN_DEPLOY_CHECK.json"
  $markdownReportPath = Join-Path $resolvedReportDir "FIRST_PC_BRAIN_DEPLOY_CHECK.md"
  if ($null -ne $liveDebug) {
    $liveDebugPath = Join-Path $resolvedReportDir "FIRST_PC_BRAIN_LIVE_DEBUG.json"
    $liveDebug | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $liveDebugPath -Encoding UTF8
    $result.liveDebugPath = $liveDebugPath
  }
  $result | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $jsonReportPath -Encoding UTF8
  Write-DeployCheckMarkdown -Path $markdownReportPath -Result $result
}

if ($Json) {
  $result | ConvertTo-Json -Depth 8
} else {
  Write-Host "First PC Brain deploy: $status"
  foreach ($check in $checks) {
    Write-Host "[$($check.status)] $($check.id): $($check.detail)"
  }
}

if ($failed.Count -gt 0 -or ($RequireHumanEvidence -and $status -ne "first-pc-brain-deploy-ready") -or ($RequireFullOnline -and $status -ne "first-pc-brain-deploy-ready")) {
  exit 1
}
