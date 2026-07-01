param(
  [string]$EvidenceRoot,
  [int64]$MinLogBytes = 128,
  [switch]$AllowMissingPackage,
  [switch]$AllowMissingMedia
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

function Test-MediaEvidenceFile {
  param([System.IO.FileInfo]$File)

  $extension = $File.Extension.ToLowerInvariant()
  if (@(".png", ".jpg", ".jpeg", ".gif", ".mp4", ".mov", ".webm") -notcontains $extension) {
    return $false
  }

  $bytesToRead = [Math]::Min([int64]64, $File.Length)
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
      return Test-BytesAtOffset $bytes ([byte[]](0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a))
    }
    ".jpg" {
      return Test-BytesAtOffset $bytes ([byte[]](0xff, 0xd8, 0xff))
    }
    ".jpeg" {
      return Test-BytesAtOffset $bytes ([byte[]](0xff, 0xd8, 0xff))
    }
    ".gif" {
      return Test-BytesAtOffset $bytes ([byte[]](0x47, 0x49, 0x46, 0x38))
    }
    ".mp4" {
      return Test-BytesAtOffset $bytes ([byte[]](0x66, 0x74, 0x79, 0x70)) 4
    }
    ".mov" {
      return Test-BytesAtOffset $bytes ([byte[]](0x66, 0x74, 0x79, 0x70)) 4
    }
    ".webm" {
      return Test-BytesAtOffset $bytes ([byte[]](0x1a, 0x45, 0xdf, 0xa3))
    }
  }

  return $false
}

$requiredFiles = @(
  "README.md",
  "CHECKLIST.md",
  "OBSERVATIONS.md",
  "DEVICE_BRINGUP.md",
  "PRODUCTION_READINESS.md",
  "metadata.json",
  "calibration/calibration.yaml"
)

foreach ($file in $requiredFiles) {
  Assert-File $file
}

$metadata = Get-Content -LiteralPath (Join-EvidencePath "metadata.json") -Raw | ConvertFrom-Json

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

foreach ($logPath in @($metadata.requiredLogs)) {
  if ($logPath -eq "logs/package_verify.log") {
    Assert-File $logPath
  } else {
    Assert-File $logPath $MinLogBytes
  }
}

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
}

Write-Host "Hardware evidence verified:"
Write-Host $evidencePath
