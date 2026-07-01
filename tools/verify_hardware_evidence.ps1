param(
  [string]$EvidenceRoot,
  [int64]$MinLogBytes = 128,
  [switch]$AllowMissingPackage,
  [switch]$AllowMissingMedia,
  [switch]$AllowSyntheticEvidence
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

function Join-EvidencePath {
  param([string]$RelativePath)
  return Join-Path $evidencePath ($RelativePath -replace "/", "\")
}

function Assert-File {
  param(
    [string]$RelativePath,
    [int64]$MinBytes = 1
  )

  $path = Join-EvidencePath $RelativePath
  if (-not (Test-Path -LiteralPath $path)) {
    throw "Missing evidence file: $RelativePath"
  }

  $item = Get-Item -LiteralPath $path
  if ($item.Length -lt $MinBytes) {
    throw "Evidence file is too small: $RelativePath ($($item.Length) bytes)"
  }
}

function Assert-NoBlankObservation {
  param(
    [string]$Text,
    [string]$Field
  )

  $escaped = [regex]::Escape($Field)
  if ($Text -match "(?m)^- $escaped\s*:\s*$") {
    throw "OBSERVATIONS.md has blank field: $Field"
  }
}

function Get-ObservationValues {
  param(
    [string]$Text,
    [string]$Field
  )

  $escaped = [regex]::Escape($Field)
  $matches = [regex]::Matches($Text, "(?m)^-\s+$escaped\s*:\s*(.*?)\s*$")
  return @($matches | ForEach-Object { $_.Groups[1].Value.Trim() })
}

function Assert-ObservationValue {
  param(
    [string]$Text,
    [string]$Field,
    [string]$RequiredPattern,
    [string]$FailurePattern = ""
  )

  $values = Get-ObservationValues $Text $Field
  if ($values.Count -eq 0) {
    throw "OBSERVATIONS.md missing field: $Field"
  }

  foreach ($value in $values) {
    if (-not [string]::IsNullOrWhiteSpace($FailurePattern) -and $value -match $FailurePattern) {
      throw "OBSERVATIONS.md records failing value for $Field`: $value"
    }
    if ($value -notmatch $RequiredPattern) {
      throw "OBSERVATIONS.md has invalid value for $Field`: $value"
    }
  }
}

function Assert-ObservationDoesNotMatch {
  param(
    [string]$Text,
    [string]$Field,
    [string]$FailurePattern
  )

  foreach ($value in (Get-ObservationValues $Text $Field)) {
    if ($value -match $FailurePattern) {
      throw "OBSERVATIONS.md records failing value for $Field`: $value"
    }
  }
}

function Assert-LogContains {
  param(
    [string]$RelativePath,
    [string]$Pattern,
    [string]$Description
  )

  $path = Join-EvidencePath $RelativePath
  if (-not (Test-Path -LiteralPath $path)) {
    throw "Missing evidence log: $RelativePath"
  }

  $text = Get-Content -LiteralPath $path -Raw
  if ($text -notmatch $Pattern) {
    throw "$RelativePath missing $Description"
  }
}

function Convert-DurationMinutes {
  param([string]$Value)

  $trimmed = $Value.Trim()
  $timeSpan = [TimeSpan]::Zero
  if ([TimeSpan]::TryParse($trimmed, [ref]$timeSpan)) {
    return $timeSpan.TotalMinutes
  }

  if ($trimmed -match "(?i)(\d+(?:\.\d+)?)\s*(hours|hour|hrs|hr|h)\b") {
    return [double]$Matches[1] * 60.0
  }

  if ($trimmed -match "(?i)(\d+(?:\.\d+)?)\s*(minutes|minute|mins|min|m)\b") {
    return [double]$Matches[1]
  }

  if ($trimmed -match "^\d+(?:\.\d+)?$") {
    return [double]$trimmed
  }

  throw "Could not parse duration minutes from OBSERVATIONS.md value: $Value"
}

function Assert-MinimumObservationDuration {
  param(
    [string]$Text,
    [string]$Field,
    [double]$MinimumMinutes
  )

  $values = Get-ObservationValues $Text $Field
  if ($values.Count -eq 0) {
    throw "OBSERVATIONS.md missing field: $Field"
  }

  foreach ($value in $values) {
    $minutes = Convert-DurationMinutes $value
    if ($minutes -lt $MinimumMinutes) {
      throw "OBSERVATIONS.md $Field is below $MinimumMinutes minutes: $value"
    }
  }
}

function Get-YamlNumber {
  param(
    [string]$Text,
    [string]$Field
  )

  $escaped = [regex]::Escape($Field)
  if ($Text -notmatch "(?m)^\s*$escaped\s*:\s*(-?\d+(?:\.\d+)?)\b") {
    throw "calibration/calibration.yaml missing numeric $Field"
  }

  return [double]::Parse($Matches[1], [System.Globalization.CultureInfo]::InvariantCulture)
}

function Test-BytesAtOffset {
  param(
    [byte[]]$Bytes,
    [byte[]]$Expected,
    [int]$Offset = 0
  )

  if ($Bytes.Length -lt ($Offset + $Expected.Length)) {
    return $false
  }

  for ($i = 0; $i -lt $Expected.Length; $i++) {
    if ($Bytes[$Offset + $i] -ne $Expected[$i]) {
      return $false
    }
  }

  return $true
}

function Get-BigEndianUInt16 {
  param(
    [byte[]]$Bytes,
    [int]$Offset
  )

  if ($Bytes.Length -lt ($Offset + 2)) {
    throw "Not enough bytes to read UInt16 at offset $Offset"
  }

  return (($Bytes[$Offset] -shl 8) -bor $Bytes[$Offset + 1])
}

function Get-BigEndianUInt32 {
  param(
    [byte[]]$Bytes,
    [int]$Offset
  )

  if ($Bytes.Length -lt ($Offset + 4)) {
    throw "Not enough bytes to read UInt32 at offset $Offset"
  }

  return (($Bytes[$Offset] -shl 24) -bor ($Bytes[$Offset + 1] -shl 16) -bor ($Bytes[$Offset + 2] -shl 8) -bor $Bytes[$Offset + 3])
}

function Get-LittleEndianUInt16 {
  param(
    [byte[]]$Bytes,
    [int]$Offset
  )

  if ($Bytes.Length -lt ($Offset + 2)) {
    throw "Not enough bytes to read UInt16 at offset $Offset"
  }

  return ($Bytes[$Offset] -bor ($Bytes[$Offset + 1] -shl 8))
}

function Get-JpegDimensions {
  param([byte[]]$Bytes)

  if (-not (Test-BytesAtOffset -Bytes $Bytes -Expected ([byte[]](0xff, 0xd8, 0xff)))) {
    return $null
  }

  $offset = 2
  while ($offset -lt ($Bytes.Length - 9)) {
    while ($offset -lt $Bytes.Length -and $Bytes[$offset] -ne 0xff) {
      $offset++
    }
    while ($offset -lt $Bytes.Length -and $Bytes[$offset] -eq 0xff) {
      $offset++
    }
    if ($offset -ge $Bytes.Length) {
      break
    }

    $marker = $Bytes[$offset]
    $offset++

    if ($marker -eq 0xd9 -or $marker -eq 0xda) {
      break
    }
    if ($offset + 2 -gt $Bytes.Length) {
      break
    }

    $segmentLength = Get-BigEndianUInt16 $Bytes $offset
    if ($segmentLength -lt 2 -or ($offset + $segmentLength) -gt $Bytes.Length) {
      break
    }

    $sofMarkers = @(0xc0, 0xc1, 0xc2, 0xc3, 0xc5, 0xc6, 0xc7, 0xc9, 0xca, 0xcb, 0xcd, 0xce, 0xcf)
    if ($sofMarkers -contains $marker) {
      if ($segmentLength -lt 7) {
        return $null
      }
      return [pscustomobject]@{
        Width = Get-BigEndianUInt16 $Bytes ($offset + 5)
        Height = Get-BigEndianUInt16 $Bytes ($offset + 3)
      }
    }

    $offset += $segmentLength
  }

  return $null
}

function Test-MediaEvidenceFile {
  param([System.IO.FileInfo]$File)

  $extension = $File.Extension.ToLowerInvariant()
  if (@(".png", ".jpg", ".jpeg", ".gif", ".mp4", ".mov", ".webm") -notcontains $extension) {
    return $false
  }

  $minimumBytes = 512
  if (@(".mp4", ".mov", ".webm") -contains $extension) {
    $minimumBytes = 8192
  }

  if ($File.Length -lt $minimumBytes) {
    throw "Media evidence file is too small to be credible: $($File.Name) ($($File.Length) bytes)"
  }

  $bytesToRead = [Math]::Min([int64]$File.Length, [int64]1048576)
  if ($bytesToRead -lt 4) {
    return $false
  }

  $stream = [System.IO.File]::OpenRead($File.FullName)
  try {
    $bytes = New-Object byte[] ([int]$bytesToRead)
    $read = $stream.Read($bytes, 0, $bytes.Length)
    if ($read -lt $bytes.Length) {
      return $false
    }
  } finally {
    $stream.Dispose()
  }

  switch ($extension) {
    ".png" {
      if (-not (Test-BytesAtOffset -Bytes $bytes -Expected ([byte[]](0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a)))) {
        return $false
      }
      if ($bytes.Length -lt 24) {
        return $false
      }
      $width = Get-BigEndianUInt32 $bytes 16
      $height = Get-BigEndianUInt32 $bytes 20
      return ($width -ge 32 -and $height -ge 32)
    }
    ".jpg" {
      $dimensions = Get-JpegDimensions $bytes
      return ($null -ne $dimensions -and $dimensions.Width -ge 32 -and $dimensions.Height -ge 32)
    }
    ".jpeg" {
      $dimensions = Get-JpegDimensions $bytes
      return ($null -ne $dimensions -and $dimensions.Width -ge 32 -and $dimensions.Height -ge 32)
    }
    ".gif" {
      if (-not (Test-BytesAtOffset -Bytes $bytes -Expected ([byte[]](0x47, 0x49, 0x46, 0x38)))) {
        return $false
      }
      if ($bytes.Length -lt 10) {
        return $false
      }
      $width = Get-LittleEndianUInt16 $bytes 6
      $height = Get-LittleEndianUInt16 $bytes 8
      return ($width -ge 32 -and $height -ge 32)
    }
    ".mp4" {
      return Test-BytesAtOffset -Bytes $bytes -Expected ([byte[]](0x66, 0x74, 0x79, 0x70)) -Offset 4
    }
    ".mov" {
      return Test-BytesAtOffset -Bytes $bytes -Expected ([byte[]](0x66, 0x74, 0x79, 0x70)) -Offset 4
    }
    ".webm" {
      return Test-BytesAtOffset -Bytes $bytes -Expected ([byte[]](0x1a, 0x45, 0xdf, 0xa3))
    }
  }

  return $false
}

function Test-AudioEvidenceFile {
  param([System.IO.FileInfo]$File)

  $extension = $File.Extension.ToLowerInvariant()
  if (@(".wav", ".mp3", ".m4a", ".aac", ".mp4", ".mov", ".webm") -notcontains $extension) {
    return $false
  }

  if ($File.Length -lt 4096) {
    throw "Audio evidence file is too small to be credible: $($File.Name) ($($File.Length) bytes)"
  }

  $bytesToRead = [Math]::Min([int64]$File.Length, [int64]1048576)
  if ($bytesToRead -lt 12) {
    return $false
  }

  $stream = [System.IO.File]::OpenRead($File.FullName)
  try {
    $bytes = New-Object byte[] ([int]$bytesToRead)
    $read = $stream.Read($bytes, 0, $bytes.Length)
    if ($read -lt $bytes.Length) {
      return $false
    }
  } finally {
    $stream.Dispose()
  }

  switch ($extension) {
    ".wav" {
      return (
        (Test-BytesAtOffset -Bytes $bytes -Expected ([byte[]](0x52, 0x49, 0x46, 0x46))) -and
        (Test-BytesAtOffset -Bytes $bytes -Expected ([byte[]](0x57, 0x41, 0x56, 0x45)) -Offset 8)
      )
    }
    ".mp3" {
      return (
        (Test-BytesAtOffset -Bytes $bytes -Expected ([byte[]](0x49, 0x44, 0x33))) -or
        ($bytes[0] -eq 0xff -and (($bytes[1] -band 0xe0) -eq 0xe0))
      )
    }
    ".m4a" {
      return Test-BytesAtOffset -Bytes $bytes -Expected ([byte[]](0x66, 0x74, 0x79, 0x70)) -Offset 4
    }
    ".mp4" {
      return Test-BytesAtOffset -Bytes $bytes -Expected ([byte[]](0x66, 0x74, 0x79, 0x70)) -Offset 4
    }
    ".mov" {
      return Test-BytesAtOffset -Bytes $bytes -Expected ([byte[]](0x66, 0x74, 0x79, 0x70)) -Offset 4
    }
    ".webm" {
      return Test-BytesAtOffset -Bytes $bytes -Expected ([byte[]](0x1a, 0x45, 0xdf, 0xa3))
    }
    ".aac" {
      return ($bytes[0] -eq 0xff -and (($bytes[1] -band 0xf0) -eq 0xf0))
    }
  }

  return $false
}

function Resolve-EvidenceRelativeFile {
  param([string]$Value)

  $clean = $Value.Trim().Trim('"').Trim("'")
  if ([string]::IsNullOrWhiteSpace($clean)) {
    throw "Evidence file field is blank"
  }

  $candidate = if ([System.IO.Path]::IsPathRooted($clean)) {
    $clean
  } else {
    Join-EvidencePath $clean
  }

  if (-not (Test-Path -LiteralPath $candidate)) {
    $audioCandidate = Join-EvidencePath (Join-Path "audio" $clean)
    if (Test-Path -LiteralPath $audioCandidate) {
      $candidate = $audioCandidate
    }
  }

  if (-not (Test-Path -LiteralPath $candidate)) {
    throw "Referenced evidence file does not exist: $Value"
  }

  $resolved = (Resolve-Path $candidate).Path
  if (-not $resolved.StartsWith($evidencePath, [System.StringComparison]::OrdinalIgnoreCase)) {
    throw "Referenced evidence file is outside the evidence packet: $resolved"
  }

  return Get-Item -LiteralPath $resolved
}

$requiredFiles = @(
  "README.md",
  "CHECKLIST.md",
  "RELEASE_ACCEPTANCE.md",
  "release_acceptance.json",
  "OBSERVATIONS.md",
  "AUDIO_REVIEW.md",
  "DEVICE_BRINGUP.md",
  "PRODUCTION_READINESS.md",
  "metadata.json",
  "calibration/calibration.yaml"
)

foreach ($file in $requiredFiles) {
  Assert-File $file
}

$metadata = Get-Content -LiteralPath (Join-EvidencePath "metadata.json") -Raw | ConvertFrom-Json

if ($metadata.diagnosticOnly -eq $true -and -not $AllowSyntheticEvidence) {
  throw "Evidence packet is marked diagnosticOnly. Synthetic evidence cannot be used for promotion without -AllowSyntheticEvidence."
}

foreach ($field in @("releaseTag", "commit", "createdUtc", "deviceId", "port", "operator")) {
  if ([string]::IsNullOrWhiteSpace([string]$metadata.$field)) {
    throw "metadata.json missing required field: $field"
  }
}

if ($metadata.releaseTag -notmatch "^v\d+\.\d+\.\d+-.+") {
  throw "metadata releaseTag does not look like a release tag: $($metadata.releaseTag)"
}

if ($metadata.commit -notmatch "^[0-9a-f]{40}$") {
  throw "metadata commit is not a full Git SHA: $($metadata.commit)"
}

$acceptance = Get-Content -LiteralPath (Join-EvidencePath "release_acceptance.json") -Raw | ConvertFrom-Json
if ($acceptance.schema -ne "stackchan.release-acceptance.v1") {
  throw "release_acceptance.json schema mismatch: $($acceptance.schema)"
}
if ($acceptance.version -ne $metadata.releaseTag) {
  throw "release_acceptance.json version mismatch: expected $($metadata.releaseTag), got $($acceptance.version)"
}
if ($acceptance.commit -ne $metadata.commit) {
  throw "release_acceptance.json commit mismatch: expected $($metadata.commit), got $($acceptance.commit)"
}
if ($acceptance.currentDecision -ne "test-ready-for-device-arrival") {
  throw "release_acceptance.json currentDecision mismatch: $($acceptance.currentDecision)"
}
if ($acceptance.consumerRolloutDecision -ne "blocked-pending-hardware-validation") {
  throw "release_acceptance.json consumerRolloutDecision mismatch: $($acceptance.consumerRolloutDecision)"
}
foreach ($requirement in @("clean-release-package", "dependency-provenance-present", "voice-review-samples-present", "servo-risk-gated")) {
  $match = @($acceptance.noHardwareAcceptance | Where-Object { $_.requirement -eq $requirement -and $_.status -eq "pass" })
  if ($match.Count -ne 1) {
    throw "release_acceptance.json missing passed no-hardware requirement: $requirement"
  }
}
foreach ($requirement in @("display-only-flash", "servo-calibration", "mixed-mode-soak", "power-cycle-recovery", "hardware-evidence-verification")) {
  $match = @($acceptance.hardwareAcceptanceRequired | Where-Object { $_.requirement -eq $requirement -and $_.status -match "pending" })
  if ($match.Count -ne 1) {
    throw "release_acceptance.json missing pending hardware requirement: $requirement"
  }
}

$acceptanceText = Get-Content -LiteralPath (Join-EvidencePath "RELEASE_ACCEPTANCE.md") -Raw
foreach ($pattern in @("test-ready for device arrival", "blocked pending hardware validation", "Still Required Before Consumer Rollout")) {
  if ($acceptanceText -notmatch [regex]::Escape($pattern)) {
    throw "RELEASE_ACCEPTANCE.md missing expected acceptance text: $pattern"
  }
}

foreach ($logPath in @($metadata.requiredLogs)) {
  if ($logPath -eq "logs/package_verify.log") {
    Assert-File $logPath
  } else {
    Assert-File $logPath $MinLogBytes
  }
}

Assert-LogContains "logs/display_only_serial.log" "\[boot\]\s+stackchan_alive\s+mode=display_only\s+serial=v1" "display-only boot marker"
Assert-LogContains "logs/display_only_serial.log" "\[display\]\s+M5 display renderer ready" "display renderer readiness marker"
Assert-LogContains "logs/display_only_serial.log" "\[servo\]\s+dry-run mode" "display-only servo dry-run marker"
Assert-LogContains "logs/servo_calibration_serial.log" "\[boot\]\s+stackchan_alive\s+mode=servo_calibration\s+serial=v1" "servo-calibration boot marker"
Assert-LogContains "logs/servo_calibration_serial.log" "\[servo\]\s+enabling StackchanSERVO hardware output" "servo hardware-enable marker"
Assert-LogContains "logs/soak_serial.log" "\[heartbeat\]\s+stackchan_alive\s+mode=(display_only|servo_calibration)\s+uptime_ms=\d+" "runtime heartbeat marker"

foreach ($recordPath in @($metadata.requiredRecords)) {
  Assert-File $recordPath
}

if ($null -eq $metadata.package) {
  if (-not $AllowMissingPackage) {
    throw "metadata.json missing package proof. Recreate the packet with -PackageZip or pass -AllowMissingPackage for diagnostic-only evidence."
  }
} else {
  if ($metadata.package.packageRoot) {
    $sourcePath = [string]$metadata.package.sourcePath
    if ([string]::IsNullOrWhiteSpace($sourcePath) -or -not (Test-Path -LiteralPath $sourcePath)) {
      throw "metadata packageRoot sourcePath is missing or no longer exists"
    }
  } else {
    $copiedPackage = [string]$metadata.package.copiedFile
    Assert-File $copiedPackage 100000

    $copiedPath = Join-EvidencePath $copiedPackage
    $actualPackageHash = (Get-FileHash -Algorithm SHA256 -LiteralPath $copiedPath).Hash.ToLowerInvariant()
    if ($actualPackageHash -ne [string]$metadata.package.sha256) {
      throw "Copied package hash does not match metadata"
    }
  }

  Assert-File "logs/package_verify.log"
  $packageVerifyLog = Get-Content -LiteralPath (Join-EvidencePath "logs/package_verify.log") -Raw
  if ($packageVerifyLog -notmatch "Release package verified:") {
    throw "logs/package_verify.log does not show a successful release package verification"
  }
}

$checklist = Get-Content -LiteralPath (Join-EvidencePath "CHECKLIST.md") -Raw
if ($checklist -match "(?m)^- \[ \]") {
  throw "CHECKLIST.md still contains unchecked gates"
}

$observations = Get-Content -LiteralPath (Join-EvidencePath "OBSERVATIONS.md") -Raw
$requiredObservationFields = @(
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
)

foreach ($field in $requiredObservationFields) {
  Assert-NoBlankObservation $observations $field
}

if ($observations -notmatch "Yaw classification:\s*(angle|velocity|disabled)") {
  throw "OBSERVATIONS.md must classify yaw as angle, velocity, or disabled"
}
if ($observations -match "Yaw classification:\s*angle\s*/\s*velocity\s*/\s*disabled") {
  throw "OBSERVATIONS.md still contains the yaw classification placeholder"
}

$passPattern = "(?i)\b(pass|passed|success|succeeded|ok|clean)\b"
$yesPattern = "(?i)\b(yes|true|visible|observed|confirmed|present)\b"
$noPattern = "(?i)\b(no|none|false|not observed|absent)\b"
$failurePattern = "(?i)\b(fail|failed|failure|reset loop|brownout|overheat|overheated|unsafe|uncontrolled|stall|stalled|jitter|jittered|blocked)\b"
$motionFailurePattern = "(?i)\b(fail|failed|failure|unsafe|out of range|brownout|overheat|overheated)\b"

Assert-ObservationValue $observations "Result" $passPattern $failurePattern
Assert-ObservationValue $observations "Reset loop observed" $noPattern
Assert-ObservationValue $observations "Procedural face visible" $yesPattern "(?i)\b(no|false|not visible|missing|blank)\b"
Assert-ObservationValue $observations "Dry-run servo log observed" $yesPattern "(?i)\b(no|false|missing|absent|not observed)\b"
Assert-ObservationDoesNotMatch $observations "Pitch behavior" $motionFailurePattern
Assert-ObservationValue $observations "Heat or brownout observed" $noPattern
Assert-MinimumObservationDuration $observations "Duration" 30
Assert-ObservationValue $observations "Reset, stall, jitter, or heat observed" $noPattern
Assert-ObservationValue $observations "USB power-cycle recovery" $passPattern "(?i)\b(fail|failed|no|false|did not|not recovered)\b"

$audioReview = Get-Content -LiteralPath (Join-EvidencePath "AUDIO_REVIEW.md") -Raw
$requiredAudioFields = @(
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
)

foreach ($field in $requiredAudioFields) {
  Assert-NoBlankObservation $audioReview $field
}

Assert-ObservationValue $audioReview "Intelligible through device speaker" $yesPattern "(?i)\b(no|false|unintelligible|not intelligible|unclear)\b"
Assert-ObservationValue $audioReview "Clipping or distortion observed" $noPattern "(?i)\b(yes|true|clipping|distortion|observed)\b"
Assert-ObservationValue $audioReview "Volume adequate at normal listening distance" $yesPattern "(?i)\b(no|false|too quiet|inaudible|inadequate)\b"
Assert-ObservationValue $audioReview "Delay or playback dropout observed" $noPattern "(?i)\b(yes|true|delay|dropout|observed)\b"

$speakerRecordingValues = Get-ObservationValues $audioReview "Speaker recording file"
if ($speakerRecordingValues.Count -lt 1) {
  throw "AUDIO_REVIEW.md missing speaker recording file"
}
foreach ($speakerRecording in $speakerRecordingValues) {
  $recordingFile = Resolve-EvidenceRelativeFile $speakerRecording
  if (-not (Test-AudioEvidenceFile $recordingFile)) {
    throw "Speaker recording file is not a supported audio/video evidence file: $speakerRecording"
  }
}

$calibration = Get-Content -LiteralPath (Join-EvidencePath "calibration/calibration.yaml") -Raw
if ($calibration -match "Hardware truth test values go here") {
  throw "calibration/calibration.yaml still contains placeholder text"
}

foreach ($pattern in @("pitch_min_deg:", "pitch_max_deg:", "yaw_mode:", "yaw_min_deg:", "yaw_max_deg:")) {
  if ($calibration -notmatch [regex]::Escape($pattern)) {
    throw "calibration/calibration.yaml missing $pattern"
  }
}

if ($calibration -notmatch "yaw_mode:\s*(angle|velocity|disabled)") {
  throw "calibration/calibration.yaml yaw_mode must be angle, velocity, or disabled"
}

$pitchMin = Get-YamlNumber $calibration "pitch_min_deg"
$pitchMax = Get-YamlNumber $calibration "pitch_max_deg"
$yawMin = Get-YamlNumber $calibration "yaw_min_deg"
$yawMax = Get-YamlNumber $calibration "yaw_max_deg"

if ($pitchMin -ge $pitchMax) {
  throw "calibration/calibration.yaml pitch_min_deg must be less than pitch_max_deg"
}

if ($yawMin -ge $yawMax) {
  throw "calibration/calibration.yaml yaw_min_deg must be less than yaw_max_deg"
}

if (-not $AllowMissingMedia) {
  $mediaFiles = @(
    Get-ChildItem -LiteralPath (Join-EvidencePath "photos") -File -ErrorAction SilentlyContinue |
    Where-Object { $_.Name -ne ".gitkeep" -and $_.Length -gt 0 }
  )

  if ($mediaFiles.Count -lt 1) {
    throw "No non-empty photo or video evidence found under photos/"
  }

  $validMediaFiles = @($mediaFiles | Where-Object { Test-MediaEvidenceFile $_ })
  if ($validMediaFiles.Count -lt 1) {
    throw "No supported photo or video evidence found under photos/. Add a valid .png, .jpg, .jpeg, .gif, .mp4, .mov, or .webm file."
  }

  $audioFiles = @(
    Get-ChildItem -LiteralPath (Join-EvidencePath "audio") -File -ErrorAction SilentlyContinue |
    Where-Object { $_.Name -ne ".gitkeep" -and $_.Length -gt 0 }
  )

  if ($audioFiles.Count -lt 1) {
    throw "No real-device speaker recording found under audio/"
  }

  $validAudioFiles = @($audioFiles | Where-Object { Test-AudioEvidenceFile $_ })
  if ($validAudioFiles.Count -lt 1) {
    throw "No supported real-device speaker recording found under audio/. Add a valid .wav, .mp3, .m4a, .aac, .mp4, .mov, or .webm file."
  }
}

Write-Host "Hardware evidence verified:"
Write-Host $evidencePath
