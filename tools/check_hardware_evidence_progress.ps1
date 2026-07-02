param(
  [string]$EvidenceRoot = "",
  [string]$ReportPath = "",
  [switch]$NoWriteReport
)

$ErrorActionPreference = "Stop"

$repoRoot = Resolve-Path (Join-Path $PSScriptRoot "..")
Set-Location $repoRoot

if ([string]::IsNullOrWhiteSpace($EvidenceRoot)) {
  $latestEvidence = Get-ChildItem -Directory -Path "output/hardware-evidence" -ErrorAction SilentlyContinue |
    Sort-Object Name -Descending |
    Select-Object -First 1

  if ($null -eq $latestEvidence) {
    throw "No evidence packet found under output/hardware-evidence. Pass -EvidenceRoot explicitly."
  }
  $EvidenceRoot = $latestEvidence.FullName
}

if (-not (Test-Path -LiteralPath $EvidenceRoot)) {
  throw "Missing evidence packet: $EvidenceRoot"
}

$evidencePath = (Resolve-Path $EvidenceRoot).Path
$findings = New-Object System.Collections.Generic.List[string]
$passes = New-Object System.Collections.Generic.List[string]

function Join-EvidencePath {
  param([string]$RelativePath)
  return Join-Path $evidencePath ($RelativePath -replace "/", "\")
}

function Add-Pass {
  param([string]$Message)
  $passes.Add($Message) | Out-Null
}

function Add-Finding {
  param([string]$Message)
  $findings.Add($Message) | Out-Null
}

function Test-RequiredFile {
  param(
    [string]$RelativePath,
    [int64]$MinBytes = 1
  )

  $path = Join-EvidencePath $RelativePath
  if (-not (Test-Path -LiteralPath $path)) {
    Add-Finding "Missing file: $RelativePath"
    return $false
  }

  $item = Get-Item -LiteralPath $path
  if ($item.Length -lt $MinBytes) {
    Add-Finding "File is too small: $RelativePath ($($item.Length) bytes)"
    return $false
  }

  Add-Pass "Present: $RelativePath"
  return $true
}

function Test-TextPattern {
  param(
    [string]$RelativePath,
    [string]$Pattern,
    [string]$Description
  )

  $path = Join-EvidencePath $RelativePath
  if (-not (Test-Path -LiteralPath $path)) {
    Add-Finding "Missing file for $Description`: $RelativePath"
    return
  }

  $text = Get-Content -LiteralPath $path -Raw
  if ($text -notmatch $Pattern) {
    Add-Finding "$RelativePath missing $Description"
  } else {
    Add-Pass "$RelativePath has $Description"
  }
}

function Get-FirstFindingLike {
  param([string[]]$Patterns)

  foreach ($pattern in $Patterns) {
    foreach ($finding in $findings) {
      if ($finding -match $pattern) {
        return $finding
      }
    }
  }
  return ""
}

function Get-BenchNextAction {
  $packageFinding = Get-FirstFindingLike @("logs/package_verify\.log", "package verification")
  if (-not [string]::IsNullOrWhiteSpace($packageFinding)) {
    return [ordered]@{
      action = "Verify the release package captured in this evidence packet."
      command = "RUN_PACKAGE_VERIFY.cmd"
      reason = $packageFinding
    }
  }

  $displayFinding = Get-FirstFindingLike @("logs/display_only_serial\.log", "display-only boot marker", "display readiness marker", "display frame-budget telemetry", "display face animator telemetry", "display bench control telemetry", "display runtime health telemetry", "No photo or video evidence")
  if (-not [string]::IsNullOrWhiteSpace($displayFinding)) {
    return [ordered]@{
      action = "Run the display-only flash, then add a clear face photo or short video."
      command = "RUN_DISPLAY_ONLY.cmd; RUN_ADD_MEDIA.cmd -Type Photo C:\path\stackchan-face.jpg"
      reason = $displayFinding
    }
  }

  $servoFinding = Get-FirstFindingLike @("logs/servo_calibration_serial\.log", "servo-calibration boot marker", "servo hardware-enable marker", "Yaw classification", "yaw_mode", "calibration/calibration\.yaml", "Calibration changes", "Pitch behavior")
  if (-not [string]::IsNullOrWhiteSpace($servoFinding)) {
    return [ordered]@{
      action = "Run supervised servo calibration and update calibration/calibration.yaml with measured yaw behavior."
      command = "RUN_SERVO_CALIBRATION.cmd"
      reason = $servoFinding
    }
  }

  $soakFinding = Get-FirstFindingLike @("logs/soak_serial\.log", "runtime heartbeat marker", "soak display frame-budget telemetry", "soak face animator telemetry", "soak runtime health telemetry", "Duration", "USB power-cycle recovery", "Reset, stall, jitter, or heat")
  if (-not [string]::IsNullOrWhiteSpace($soakFinding)) {
    return [ordered]@{
      action = "Run the soak monitor for at least 30 minutes and complete the soak fields in OBSERVATIONS.md."
      command = "RUN_SOAK_MONITOR.cmd"
      reason = $soakFinding
    }
  }

  $audioFinding = Get-FirstFindingLike @("AUDIO_REVIEW\.md", "real-device speaker recording", "audio/", "speaker audio", "RVC voice base remains review-only")
  if (-not [string]::IsNullOrWhiteSpace($audioFinding)) {
    return [ordered]@{
      action = "Play the lead voice reference, record the actual target speaker path, import it, and complete AUDIO_REVIEW.md."
      command = "RUN_PLAY_LEAD_VOICE.cmd; RUN_ADD_MEDIA.cmd -Type Audio C:\path\stackchan-speaker.wav"
      reason = $audioFinding
    }
  }

  $checklistFinding = Get-FirstFindingLike @("CHECKLIST\.md still has unchecked gates", "Production voice-source gate remains blocked", "metadata\.json has no shareVerification", "GitHub Actions")
  if (-not [string]::IsNullOrWhiteSpace($checklistFinding)) {
    return [ordered]@{
      action = "Clear the remaining checklist, voice-source, hosted-media, or CI handoff gates."
      command = "RUN_ROLLOUT_STATUS.cmd"
      reason = $checklistFinding
    }
  }

  if ($findings.Count -gt 0) {
    return [ordered]@{
      action = "Resolve the first remaining progress finding."
      command = "RUN_PROGRESS_CHECK.cmd"
      reason = [string]$findings[0]
    }
  }

  return [ordered]@{
    action = "Run the strict hardware evidence verifier."
    command = "RUN_EVIDENCE_VERIFY.cmd"
    reason = "No obvious progress gaps found."
  }
}

function Write-BenchStatusReport {
  param([string]$JsonPath)

  $markdownPath = ""
  if ([string]::IsNullOrWhiteSpace($JsonPath)) {
    $JsonPath = Join-EvidencePath "BENCH_STATUS.json"
    $markdownPath = Join-EvidencePath "BENCH_STATUS.md"
  }

  $jsonFullPath = $JsonPath
  if (-not [System.IO.Path]::IsPathRooted($jsonFullPath)) {
    $jsonFullPath = Join-EvidencePath $jsonFullPath
  }

  $jsonDir = Split-Path -Parent $jsonFullPath
  if (-not [string]::IsNullOrWhiteSpace($jsonDir)) {
    New-Item -ItemType Directory -Force -Path $jsonDir | Out-Null
  }

  if ([string]::IsNullOrWhiteSpace($markdownPath)) {
    $markdownPath = [System.IO.Path]::ChangeExtension($jsonFullPath, ".md")
  }
  $next = Get-BenchNextAction
  $status = if ($findings.Count -gt 0) { "blocked-or-pending" } else { "ready-for-strict-evidence-verify" }
  $generatedUtc = (Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")

  $report = [ordered]@{
    schema = "stackchan.bench-status.v1"
    evidenceRoot = $evidencePath
    generatedUtc = $generatedUtc
    status = $status
    nextAction = [string]$next.action
    nextCommand = [string]$next.command
    reason = [string]$next.reason
    findingCount = $findings.Count
    passCount = $passes.Count
    findings = @($findings)
    passes = @($passes)
  }
  $report | ConvertTo-Json -Depth 6 | Set-Content -Path $jsonFullPath -Encoding UTF8

  $topFindings = @($findings | Select-Object -First 20)
  $markdown = @(
    "# Stackchan Bench Status",
    "",
    "- Schema: stackchan.bench-status.v1",
    "- Generated UTC: $generatedUtc",
    "- Status: $status",
    "- Next action: $($next.action)",
    "- Next command: ``$($next.command)``",
    "- Reason: $($next.reason)",
    "- Findings: $($findings.Count)",
    "- Passing signals: $($passes.Count)",
    "",
    "Run ``RUN_PROGRESS_CHECK.cmd`` after each bench step to refresh this file.",
    "",
    "## Top Findings"
  )
  if ($topFindings.Count -gt 0) {
    foreach ($finding in $topFindings) {
      $markdown += "- $finding"
    }
  } else {
    $markdown += "- No obvious progress gaps found. Run ``RUN_EVIDENCE_VERIFY.cmd`` for the strict promotion check."
  }
  $markdown | Set-Content -Path $markdownPath -Encoding UTF8

  return [ordered]@{
    json = $jsonFullPath
    markdown = $markdownPath
  }
}

foreach ($file in @(
  "README.md",
  "NEXT_STEPS.md",
  "CHECKLIST.md",
  "OBSERVATIONS.md",
  "AUDIO_REVIEW.md",
  "metadata.json",
  "RELEASE_ACCEPTANCE.md",
  "release_acceptance.json",
  "RUN_PLAY_LEAD_VOICE.cmd",
  "calibration/calibration.yaml"
)) {
  [void](Test-RequiredFile $file)
}

$metadata = $null
if (Test-Path -LiteralPath (Join-EvidencePath "metadata.json")) {
  $metadata = Get-Content -LiteralPath (Join-EvidencePath "metadata.json") -Raw | ConvertFrom-Json
  if ($null -ne $metadata.voiceLeadAudition) {
    [void](Test-RequiredFile "RVC_LEAD_AUDITION.md")
    [void](Test-RequiredFile ([string]$metadata.voiceLeadAudition.referenceFile) 100000)
    [void](Test-RequiredFile "reference_audio/RVC_AUDITIONS.md" 500)
    [void](Test-RequiredFile "reference_audio/RVC_AUDITIONS.json" 500)
    if (Test-Path -LiteralPath (Join-EvidencePath ([string]$metadata.voiceLeadAudition.referenceFile))) {
      $leadHash = (Get-FileHash -Algorithm SHA256 -LiteralPath (Join-EvidencePath ([string]$metadata.voiceLeadAudition.referenceFile))).Hash.ToLowerInvariant()
      if ($leadHash -eq [string]$metadata.voiceLeadAudition.sha256) {
        Add-Pass "RVC lead audition reference hash matches metadata"
      } else {
        Add-Finding "RVC lead audition reference hash does not match metadata"
      }
    }
  } else {
    Add-Finding "metadata.json missing voiceLeadAudition reference"
  }
  if ($null -ne $metadata.shareVerification) {
    [void](Test-RequiredFile ([string]$metadata.shareVerification.hostedMediaReference) 200)
    [void](Test-RequiredFile ([string]$metadata.shareVerification.verificationReport) 500)
    [void](Test-RequiredFile ([string]$metadata.shareVerification.verificationSummary) 100)
    [void](Test-RequiredFile "share/share_status.json" 100)
    if (-not [string]::IsNullOrWhiteSpace([string]$metadata.shareVerification.verifiedUrlFile)) {
      [void](Test-RequiredFile ([string]$metadata.shareVerification.verifiedUrlFile) 10)
    } elseif (Test-Path -LiteralPath (Join-EvidencePath "share/VERIFIED_URL.txt")) {
      [void](Test-RequiredFile "share/VERIFIED_URL.txt" 10)
    } else {
      [void](Test-RequiredFile "share/PUBLIC_URL.txt" 10)
    }
    if (Test-Path -LiteralPath (Join-EvidencePath ([string]$metadata.shareVerification.verificationReport))) {
      $shareReport = Get-Content -LiteralPath (Join-EvidencePath ([string]$metadata.shareVerification.verificationReport)) -Raw | ConvertFrom-Json
      if ($shareReport.schema -eq "stackchan.share-verification.v1" -and
          $shareReport.version -eq $metadata.releaseTag -and
          [bool]$shareReport.allHttp200 -and
          [int]$shareReport.probeCount -eq [int]$metadata.shareVerification.probeCount) {
        Add-Pass "Hosted media share verification report matches metadata"
      } else {
        Add-Finding "Hosted media share verification report is missing a matching schema/version/probe pass"
      }
    }
  } else {
    Add-Finding "metadata.json has no shareVerification reference; hosted media review page is not pinned in this evidence packet"
  }

  if ($null -ne $metadata.voiceGateStatus) {
    [void](Test-RequiredFile "VOICE_SOURCE_STATUS.md" 500)
    [void](Test-RequiredFile "voice_source_status.json" 500)
    [void](Test-RequiredFile "RVC_VOICE_BASE_STATUS.md" 500)
    [void](Test-RequiredFile "rvc_voice_base_status.json" 500)

    if (Test-Path -LiteralPath (Join-EvidencePath "voice_source_status.json")) {
      $voiceSourceStatus = Get-Content -LiteralPath (Join-EvidencePath "voice_source_status.json") -Raw | ConvertFrom-Json
      if ($voiceSourceStatus.schema -eq "stackchan.voice-source-status.v1" -and
          $voiceSourceStatus.status -eq $metadata.voiceGateStatus.voiceSourceStatus -and
          [int]$voiceSourceStatus.blockedGateCount -eq [int]$metadata.voiceGateStatus.voiceSourceBlockedGateCount) {
        Add-Pass "Voice source status report matches metadata"
      } else {
        Add-Finding "voice_source_status.json is missing a matching schema/status/blocked-gate count"
      }
      if ($voiceSourceStatus.status -eq "production-source-ready") {
        Add-Pass "Voice source status reports production-source-ready"
      } else {
        Add-Finding "Production voice-source gate remains blocked: $($voiceSourceStatus.status)"
      }
    }

    if (Test-Path -LiteralPath (Join-EvidencePath "rvc_voice_base_status.json")) {
      $rvcBaseStatus = Get-Content -LiteralPath (Join-EvidencePath "rvc_voice_base_status.json") -Raw | ConvertFrom-Json
      if ($rvcBaseStatus.schema -eq "stackchan.rvc-voice-base-status.v1" -and
          $rvcBaseStatus.status -eq $metadata.voiceGateStatus.rvcVoiceBaseStatus -and
          [bool]$rvcBaseStatus.consumerApproved -eq [bool]$metadata.voiceGateStatus.rvcConsumerApproved -and
          [bool]$rvcBaseStatus.distributionApproved -eq [bool]$metadata.voiceGateStatus.rvcDistributionApproved) {
        Add-Pass "RVC voice base status report matches metadata"
      } else {
        Add-Finding "rvc_voice_base_status.json is missing a matching schema/status/approval state"
      }
      if ([bool]$rvcBaseStatus.consumerApproved -and [bool]$rvcBaseStatus.distributionApproved) {
        Add-Pass "RVC voice base is marked approved for consumer distribution"
      } else {
        Add-Finding "RVC voice base remains review-only, not consumer/distribution approved"
      }
    }
  } else {
    Add-Finding "metadata.json missing voiceGateStatus reference; voice-source and RVC gate reports are not pinned in this evidence packet"
  }
}

if (Test-Path -LiteralPath (Join-EvidencePath "CHECKLIST.md")) {
  $checklist = Get-Content -LiteralPath (Join-EvidencePath "CHECKLIST.md") -Raw
  $unchecked = @([regex]::Matches($checklist, "(?m)^- \[ \] (.+)$") | ForEach-Object { $_.Groups[1].Value.Trim() })
  if ($unchecked.Count -gt 0) {
    Add-Finding "CHECKLIST.md still has unchecked gates: $($unchecked.Count)"
    foreach ($item in ($unchecked | Select-Object -First 8)) {
      Add-Finding "  - $item"
    }
  } else {
    Add-Pass "CHECKLIST.md has no unchecked gates"
  }
}

if (Test-Path -LiteralPath (Join-EvidencePath "OBSERVATIONS.md")) {
  $observations = Get-Content -LiteralPath (Join-EvidencePath "OBSERVATIONS.md") -Raw
  foreach ($field in @(
    "Start UTC",
    "End UTC",
    "Command",
    "Result",
    "Reset loop observed",
    "Procedural face visible",
    "Dry-run servo log observed",
    "Pitch behavior",
    "Yaw classification",
    "Heat or brownout observed",
    "Calibration changes",
    "Duration",
    "Reset, stall, jitter, or heat observed",
    "USB power-cycle recovery"
  )) {
    if ($observations -match "(?m)^-\s+$([regex]::Escape($field))\s*:\s*$") {
      Add-Finding "OBSERVATIONS.md has blank field: $field"
    }
  }

  if ($observations -match "Yaw classification:\s*(angle|velocity|disabled)") {
    Add-Pass "OBSERVATIONS.md includes yaw classification"
  } else {
    Add-Finding "OBSERVATIONS.md needs yaw classification: angle, velocity, or disabled"
  }
}

if (Test-Path -LiteralPath (Join-EvidencePath "AUDIO_REVIEW.md")) {
  $audioReview = Get-Content -LiteralPath (Join-EvidencePath "AUDIO_REVIEW.md") -Raw
  foreach ($field in @(
    "Start UTC",
    "End UTC",
    "Sample played",
    "Voice variant",
    "Speaker recording file",
    "Intelligible through device speaker",
    "Clipping or distortion observed",
    "Volume adequate at normal listening distance",
    "Delay or playback dropout observed",
    "Selected voice direction"
  )) {
    if ($audioReview -match "(?m)^-\s+$([regex]::Escape($field))\s*:\s*$") {
      Add-Finding "AUDIO_REVIEW.md has blank field: $field"
    }
  }

  if ($audioReview -match "(?m)^-\s+Intelligible through device speaker:\s*(?i:yes|true|confirmed)\s*$") {
    Add-Pass "AUDIO_REVIEW.md marks speaker audio intelligible"
  } else {
    Add-Finding "AUDIO_REVIEW.md needs intelligible speaker audio marked yes"
  }

  if ($audioReview -match "(?m)^-\s+Clipping or distortion observed:\s*(?i:no|none|false|not observed)\s*$") {
    Add-Pass "AUDIO_REVIEW.md marks clipping/distortion absent"
  } else {
    Add-Finding "AUDIO_REVIEW.md needs clipping/distortion marked no"
  }
}

Test-RequiredFile "logs/package_verify.log" | Out-Null
Test-RequiredFile "logs/display_only_serial.log" 128 | Out-Null
Test-RequiredFile "logs/servo_calibration_serial.log" 128 | Out-Null
Test-RequiredFile "logs/soak_serial.log" 128 | Out-Null

Test-TextPattern "logs/package_verify.log" "Release package verified:" "successful package verification"
Test-TextPattern "logs/display_only_serial.log" "\[boot\]\s+stackchan_alive\s+mode=display_only\s+serial=v1" "display-only boot marker"
Test-TextPattern "logs/display_only_serial.log" "\[display\]\s+M5 display renderer ready" "display readiness marker"
Test-TextPattern "logs/display_only_serial.log" "\[servo\]\s+dry-run mode" "display-only servo dry-run marker"
Test-TextPattern "logs/display_only_serial.log" "\[display\]\s+frame_ms_avg=.*fps_window=.*frame_budget_us=33333.*slow_frames=\d+" "display frame-budget telemetry"
Test-TextPattern "logs/display_only_serial.log" "\[face\]\s+mode=\d+\s+blink_count=\d+\s+saccade_count=\d+.*gesture_active=\d+\s+speech_active=\d+\s+speech_env=" "display face animator telemetry"
Test-TextPattern "logs/display_only_serial.log" "\[control\]\s+command=(mode_listen|event_touch|touch_click_react|button_a_listen|speech_env).*at_ms=\d+" "display bench control telemetry"
Test-TextPattern "logs/display_only_serial.log" "\[speech\]\s+seq=\d+\s+at_ms=\d+\s+intent=\w+\s+priority=\d+\s+earcon=\w+\s+earcon_delay_ms=\d+\s+text=" "display speech cue telemetry"
Test-TextPattern "logs/display_only_serial.log" "\[system\]\s+heap_free=\d+\s+heap_min=\d+\s+stack_loop_hwm=\d+\s+stack_motion_hwm=\d+\s+stack_face_hwm=\d+\s+stack_intent_hwm=\d+" "display runtime health telemetry"
Test-TextPattern "logs/servo_calibration_serial.log" "\[boot\]\s+stackchan_alive\s+mode=servo_calibration\s+serial=v1" "servo-calibration boot marker"
Test-TextPattern "logs/servo_calibration_serial.log" "\[servo\]\s+enabling StackchanSERVO hardware output" "servo hardware-enable marker"
Test-TextPattern "logs/soak_serial.log" "\[heartbeat\]\s+stackchan_alive\s+mode=(display_only|servo_calibration)\s+uptime_ms=\d+" "runtime heartbeat marker"
Test-TextPattern "logs/soak_serial.log" "\[display\]\s+frame_ms_avg=.*fps_window=.*frame_budget_us=33333.*slow_frames=\d+" "soak display frame-budget telemetry"
Test-TextPattern "logs/soak_serial.log" "\[face\]\s+mode=\d+\s+blink_count=\d+\s+saccade_count=\d+.*gesture_active=\d+\s+speech_active=\d+\s+speech_env=" "soak face animator telemetry"
Test-TextPattern "logs/soak_serial.log" "\[speech\]\s+seq=\d+\s+at_ms=\d+\s+intent=\w+\s+priority=\d+\s+earcon=\w+\s+earcon_delay_ms=\d+\s+text=" "soak speech cue telemetry"
Test-TextPattern "logs/soak_serial.log" "\[system\]\s+heap_free=\d+\s+heap_min=\d+\s+stack_loop_hwm=\d+\s+stack_motion_hwm=\d+\s+stack_face_hwm=\d+\s+stack_intent_hwm=\d+" "soak runtime health telemetry"

Test-TextPattern "NEXT_STEPS.md" "RUN_PACKAGE_VERIFY\.cmd" "package verify run order"
Test-TextPattern "NEXT_STEPS.md" "RUN_PROGRESS_CHECK\.cmd" "progress check run order"
Test-TextPattern "NEXT_STEPS.md" "Generated source WAVs alone do not count" "real-device audio warning"
Test-TextPattern "NEXT_STEPS.md" "RUN_CONSUMER_PROMOTION_CHECK\.cmd" "consumer promotion gate"

if (Test-Path -LiteralPath (Join-EvidencePath "calibration/calibration.yaml")) {
  $calibration = Get-Content -LiteralPath (Join-EvidencePath "calibration/calibration.yaml") -Raw
  if ($calibration -match "Hardware truth test values go here") {
    Add-Finding "calibration/calibration.yaml still contains placeholder text"
  } else {
    Add-Pass "calibration/calibration.yaml placeholder has been removed"
  }
  if ($calibration -notmatch "yaw_mode:\s*(angle|velocity|disabled)") {
    Add-Finding "calibration/calibration.yaml needs yaw_mode: angle, velocity, or disabled"
  }
}

$mediaFiles = @(
  Get-ChildItem -LiteralPath (Join-EvidencePath "photos") -File -ErrorAction SilentlyContinue |
  Where-Object { $_.Name -ne ".gitkeep" -and $_.Length -gt 0 }
)
if ($mediaFiles.Count -lt 1) {
  Add-Finding "No photo or video evidence found under photos/"
} else {
  Add-Pass "Photo/video evidence files present: $($mediaFiles.Count)"
}

$audioFiles = @(
  Get-ChildItem -LiteralPath (Join-EvidencePath "audio") -File -ErrorAction SilentlyContinue |
  Where-Object { $_.Name -ne ".gitkeep" -and $_.Length -gt 0 }
)
if ($audioFiles.Count -lt 1) {
  Add-Finding "No real-device speaker recording found under audio/"
} else {
  Add-Pass "Speaker recording files present: $($audioFiles.Count)"
}

$benchStatusPaths = $null
if (-not $NoWriteReport) {
  $benchStatusPaths = Write-BenchStatusReport -JsonPath $ReportPath
}

Write-Host "Hardware evidence progress:"
Write-Host $evidencePath
Write-Host ""

if ($benchStatusPaths) {
  Write-Host "Bench status written:"
  Write-Host "  $($benchStatusPaths.markdown)"
  Write-Host "  $($benchStatusPaths.json)"
  Write-Host ""
}

if ($passes.Count -gt 0) {
  Write-Host "Passing signals:"
  foreach ($item in $passes) {
    Write-Host "  [ok] $item"
  }
  Write-Host ""
}

if ($findings.Count -gt 0) {
  Write-Host "Still needed:"
  foreach ($item in $findings) {
    Write-Host "  [ ] $item"
  }
  exit 2
}

Write-Host "No obvious progress gaps found. Run RUN_EVIDENCE_VERIFY.cmd for the strict promotion check."
