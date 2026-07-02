param(
  [string]$EvidenceRoot = ""
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

foreach ($file in @(
  "README.md",
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
Test-TextPattern "logs/servo_calibration_serial.log" "\[boot\]\s+stackchan_alive\s+mode=servo_calibration\s+serial=v1" "servo-calibration boot marker"
Test-TextPattern "logs/servo_calibration_serial.log" "\[servo\]\s+enabling StackchanSERVO hardware output" "servo hardware-enable marker"
Test-TextPattern "logs/soak_serial.log" "\[heartbeat\]\s+stackchan_alive\s+mode=(display_only|servo_calibration)\s+uptime_ms=\d+" "runtime heartbeat marker"

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

Write-Host "Hardware evidence progress:"
Write-Host $evidencePath
Write-Host ""

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
