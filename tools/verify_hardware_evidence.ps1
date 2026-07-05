param(
  [string]$EvidenceRoot,
  [int64]$MinLogBytes = 128,
  [switch]$AllowMissingPackage,
  [switch]$AllowMissingMedia,
  [switch]$AllowSyntheticEvidence,
  [switch]$AndroidApkEvidenceContractSelfTest,
  [switch]$AndroidDashboardEvidenceContractSelfTest,
  [switch]$AndroidProbeEvidenceContractSelfTest
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

function Test-AndroidCompanionReportPresent {
  param([object]$Metadata)

  if ($null -eq $Metadata -or $null -eq $Metadata.androidCompanionProbes) {
    return $false
  }

  foreach ($field in @("apkInstallReport", "companionProbeReport", "screenOffSoakReport", "udpBeaconProbeReport", "logcatReport")) {
    $relativePath = [string]$Metadata.androidCompanionProbes.$field
    if (-not [string]::IsNullOrWhiteSpace($relativePath) -and
        (Test-Path -LiteralPath (Join-EvidencePath $relativePath))) {
      return $true
    }
  }

  return $false
}

function Assert-AndroidReportEvidence {
  param(
    [object]$ProbeConfig,
    [string]$Field,
    [string]$Description,
    [string]$ExpectedSchema,
    [string[]]$PassingStatuses = @("pass")
  )

  $relativePath = [string]$ProbeConfig.$Field
  if ([string]::IsNullOrWhiteSpace($relativePath)) {
    return
  }

  $path = Join-EvidencePath $relativePath
  if (-not (Test-Path -LiteralPath $path)) {
    return
  }

  $report = Get-Content -LiteralPath $path -Raw | ConvertFrom-Json
  if ($report.schema -ne $ExpectedSchema) {
    throw "$Description schema mismatch: $($report.schema)"
  }
  if (@($PassingStatuses) -notcontains [string]$report.status) {
    $issues = @($report.issues) -join "; "
    throw "$Description status is not accepted: $($report.status). $issues"
  }
  if ($ExpectedSchema -eq "stackchan.android-apk-install.v1" -and
      [string]$report.apkSha256 -notmatch "^[0-9a-fA-F]{64}$") {
    throw "$Description is missing a valid apkSha256."
  }
  if ($ExpectedSchema -eq "stackchan.android-apk-install.v1") {
    if ([string]$report.sourceCommit -notmatch "^[0-9a-fA-F]{40}$") {
      throw "$Description is missing a full sourceCommit SHA. Re-run RUN_ANDROID_APK_INSTALL.cmd with -SourceCommit <git-commit>."
    }
    if ([string]::IsNullOrWhiteSpace([string]$report.versionName) -or
        [string]::IsNullOrWhiteSpace([string]$report.versionCode)) {
      throw "$Description is missing installed versionName/versionCode."
    }
  }
}

function Assert-AndroidCompanionReportEvidence {
  param([object]$Metadata)

  if ($null -eq $Metadata -or $null -eq $Metadata.androidCompanionProbes) {
    return
  }

  $probeConfig = $Metadata.androidCompanionProbes
  Assert-AndroidReportEvidence `
    -ProbeConfig $probeConfig `
    -Field "apkInstallReport" `
    -Description "Android APK install evidence" `
    -ExpectedSchema "stackchan.android-apk-install.v1" `
    -PassingStatuses @("installed")
  Assert-AndroidReportEvidence `
    -ProbeConfig $probeConfig `
    -Field "companionProbeReport" `
    -Description "Android companion bridge probe" `
    -ExpectedSchema "stackchan.android-companion-probe.v1"
  Assert-AndroidReportEvidence `
    -ProbeConfig $probeConfig `
    -Field "screenOffSoakReport" `
    -Description "Android screen-off soak" `
    -ExpectedSchema "stackchan.android-companion-soak.v1"
  Assert-AndroidReportEvidence `
    -ProbeConfig $probeConfig `
    -Field "udpBeaconProbeReport" `
    -Description "Android UDP beacon probe" `
    -ExpectedSchema "stackchan.android-udp-beacon-probe.v1"
  Assert-AndroidReportEvidence `
    -ProbeConfig $probeConfig `
    -Field "logcatReport" `
    -Description "Android companion logcat capture" `
    -ExpectedSchema "stackchan.android-companion-logcat.v1" `
    -PassingStatuses @("captured")
}

function Test-AndroidDashboardManifestEntry {
  param([object]$Entry)

  $relativePath = [string]$Entry.relativePath
  $notes = [string]$Entry.notes
  if ([string]$Entry.kind -ne "photo" -or
      $relativePath -notmatch "^(?i:photos)/" -or
      [string]::IsNullOrWhiteSpace($notes)) {
    return $false
  }

  foreach ($pattern in @(
    "(?i)android.*dashboard|dashboard.*android",
    "(?i)connected",
    "(?i)robot\s+identity",
    "(?i)firmware/version|firmware.*version|version.*firmware",
    "(?i)last\s+bridge\s+frame",
    "(?i)active\s+brain\s+owner",
    "(?i)foreground\s+service|service\s+state"
  )) {
    if ($notes -notmatch $pattern) {
      return $false
    }
  }

  $file = Resolve-EvidenceRelativeFile $relativePath
  return (Test-MediaEvidenceFile $file)
}

function Assert-AndroidDashboardManifestEvidence {
  param([object]$Metadata)

  if (-not (Test-AndroidCompanionReportPresent $Metadata)) {
    return
  }

  $manifestPath = Join-EvidencePath "media_manifest.json"
  if (-not (Test-Path -LiteralPath $manifestPath)) {
    throw "Android companion reports are present, but media_manifest.json is missing. Import the connected dashboard screenshot with RUN_ADD_MEDIA.cmd -Type Photo -Notes `"Android dashboard connected state; robot identity; firmware/version signal; last bridge frame; active brain owner; foreground service state`" C:\path\android-dashboard.jpg"
  }

  $manifest = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json
  if ($manifest.schema -ne "stackchan.hardware-media-manifest.v1") {
    throw "media_manifest.json schema mismatch: $($manifest.schema)"
  }

  foreach ($entry in @($manifest.entries)) {
    if (Test-AndroidDashboardManifestEntry $entry) {
      return
    }
  }

  throw "media_manifest.json is missing a photo/video entry whose notes identify the Android dashboard connected state with robot identity, firmware/version signal, last bridge frame, active brain owner, and foreground service state."
}

if ($AndroidApkEvidenceContractSelfTest) {
  $metadataPath = Join-EvidencePath "metadata.json"
  if (-not (Test-Path -LiteralPath $metadataPath)) {
    throw "Android APK evidence contract self-test requires metadata.json."
  }

  $metadata = Get-Content -LiteralPath $metadataPath -Raw | ConvertFrom-Json
  Assert-AndroidCompanionReportEvidence $metadata
  Write-Host "Android APK strict evidence contract verified:"
  Write-Host $evidencePath
  return
}

if ($AndroidDashboardEvidenceContractSelfTest) {
  $metadataPath = Join-EvidencePath "metadata.json"
  if (-not (Test-Path -LiteralPath $metadataPath)) {
    throw "Android dashboard evidence contract self-test requires metadata.json."
  }

  $metadata = Get-Content -LiteralPath $metadataPath -Raw | ConvertFrom-Json
  Assert-AndroidDashboardManifestEvidence $metadata
  Write-Host "Android dashboard strict evidence contract verified:"
  Write-Host $evidencePath
  return
}

if ($AndroidProbeEvidenceContractSelfTest) {
  $metadataPath = Join-EvidencePath "metadata.json"
  if (-not (Test-Path -LiteralPath $metadataPath)) {
    throw "Android probe evidence contract self-test requires metadata.json."
  }

  $metadata = Get-Content -LiteralPath $metadataPath -Raw | ConvertFrom-Json
  Assert-AndroidCompanionReportEvidence $metadata
  Write-Host "Android probe strict evidence contract verified:"
  Write-Host $evidencePath
  return
}

$requiredFiles = @(
  "README.md",
  "BENCH_STATUS.md",
  "BENCH_STATUS.json",
  "NEXT_STEPS.md",
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

$nextStepsText = Get-Content -LiteralPath (Join-EvidencePath "NEXT_STEPS.md") -Raw
foreach ($pattern in @("Stackchan Evidence Next Steps", "RUN_PACKAGE_VERIFY.cmd", "RUN_DISPLAY_ONLY.cmd", "RUN_SPEECH_MOUTH_DEMO.cmd", "RUN_SPEAK_ALL_INTENTS.cmd", "RUN_SERVO_CALIBRATION.cmd", "RUN_SOAK_MONITOR.cmd", "RUN_PLAY_LEAD_VOICE.cmd", "RUN_ADD_MEDIA.cmd", "RUN_PROGRESS_CHECK.cmd", "RUN_ROLLOUT_STATUS.cmd", "RUN_EVIDENCE_VERIFY.cmd", "RUN_CONSUMER_PROMOTION_CHECK.cmd", "pair ticket <stackchan://pair?...>", "Generated source WAVs alone do not count", "Do not run servo calibration unless the body is clear", "production voice-source provenance")) {
  if ($nextStepsText -notmatch [regex]::Escape($pattern)) {
    throw "NEXT_STEPS.md missing expected operator guidance: $pattern"
  }
}

$metadata = Get-Content -LiteralPath (Join-EvidencePath "metadata.json") -Raw | ConvertFrom-Json

$benchStatusText = Get-Content -LiteralPath (Join-EvidencePath "BENCH_STATUS.md") -Raw
foreach ($pattern in @("Stackchan Bench Status", "stackchan.bench-status.v1", "Next action:", "Next command:")) {
  if ($benchStatusText -notmatch [regex]::Escape($pattern)) {
    throw "BENCH_STATUS.md missing expected handoff summary: $pattern"
  }
}

$benchStatus = Get-Content -LiteralPath (Join-EvidencePath "BENCH_STATUS.json") -Raw | ConvertFrom-Json
if ($benchStatus.schema -ne "stackchan.bench-status.v1") {
  throw "BENCH_STATUS.json schema mismatch: $($benchStatus.schema)"
}
foreach ($field in @("status", "nextAction", "nextCommand", "generatedUtc")) {
  if ([string]::IsNullOrWhiteSpace([string]$benchStatus.$field)) {
    throw "BENCH_STATUS.json missing required field: $field"
  }
}

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
foreach ($requirement in @("display-only-flash", "speech-mouth-demo-evidence", "servo-calibration", "mixed-mode-soak", "power-cycle-recovery", "target-speaker-audio-evidence", "hardware-evidence-verification")) {
  $match = @($acceptance.hardwareAcceptanceRequired | Where-Object { $_.requirement -eq $requirement -and $_.status -match "pending" })
  if ($match.Count -ne 1) {
    throw "release_acceptance.json missing pending hardware requirement: $requirement"
  }
}

$acceptanceText = Get-Content -LiteralPath (Join-EvidencePath "RELEASE_ACCEPTANCE.md") -Raw
foreach ($pattern in @("test-ready for device arrival", "blocked pending hardware validation", "Still Required Before Consumer Rollout", "Speech-mouth demo evidence", "Target-speaker audio evidence")) {
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
Assert-LogContains "logs/display_only_serial.log" "\[display\]\s+frame_ms_avg=.*fps_window=.*frame_budget_us=33333.*slow_frames=\d+" "display frame-budget telemetry"
Assert-LogContains "logs/display_only_serial.log" "\[face\]\s+mode=\d+\s+blink_count=\d+\s+saccade_count=\d+.*gesture_active=\d+\s+speech_active=\d+\s+speech_env=" "display face animator telemetry"
Assert-LogContains "logs/display_only_serial.log" "\[control\]\s+command=(mode_listen|event_touch|touch_click_react|button_a_listen|speech_env|reduced_motion_on|reduced_motion_off|safe_stop).*at_ms=\d+" "display bench control telemetry"
Assert-LogContains "logs/display_only_serial.log" "\[speech\]\s+seq=\d+\s+at_ms=\d+\s+intent=\w+\s+priority=\d+\s+earcon=\w+\s+earcon_delay_ms=\d+\s+text=" "display speech cue telemetry"
Assert-LogContains "logs/display_only_serial.log" "\[system\]\s+heap_free=\d+\s+heap_min=\d+\s+stack_loop_hwm=\d+\s+stack_motion_hwm=\d+\s+stack_face_hwm=\d+\s+stack_intent_hwm=\d+" "display runtime health telemetry"
Assert-LogContains "logs/speech_mouth_demo_serial.log" "\[demo\]\s+>\s+speech\s+[0-9]" "speech mouth demo envelope commands"
Assert-LogContains "logs/speech_mouth_demo_serial.log" "\[demo\]\s+>\s+speech clear" "speech mouth demo clear command"
Assert-LogContains "logs/speech_mouth_demo_serial.log" "\[demo\]\s+Speech mouth demo complete\." "speech mouth demo completion"
$speechIntentNames = @("boot", "idle", "attend", "listen", "think", "speak", "react", "happy", "concern", "sleep", "error", "safety")
foreach ($intentName in $speechIntentNames) {
  Assert-LogContains "logs/speak_all_intents_serial.log" "\[speak-all\]\s+>\s+speak\s+$intentName\b" "speak-all command for $intentName"
  Assert-LogContains "logs/speak_all_intents_serial.log" "\[control\]\s+command=speak_intent.*cue_intent=$intentName.*cue_earcon=\w+" "speak-all control cue for $intentName"
}
Assert-LogContains "logs/speak_all_intents_serial.log" "\[audio_out\]\s+seq=\d+\s+source=packaged_prompt\s+prompt_id=" "speak-all packaged prompt audio-output handoff"
Assert-LogContains "logs/speak_all_intents_serial.log" "\[speak-all\]\s+Speak-all-intents demo complete\." "speak-all completion"
Assert-LogContains "logs/servo_calibration_serial.log" "\[boot\]\s+stackchan_alive\s+mode=servo_calibration\s+serial=v1" "servo-calibration boot marker"
Assert-LogContains "logs/servo_calibration_serial.log" "\[servo\]\s+enabling StackchanSERVO hardware output" "servo hardware-enable marker"
Assert-LogContains "logs/soak_serial.log" "\[heartbeat\]\s+stackchan_alive\s+mode=(display_only|servo_calibration)\s+uptime_ms=\d+" "runtime heartbeat marker"
Assert-LogContains "logs/soak_serial.log" "\[display\]\s+frame_ms_avg=.*fps_window=.*frame_budget_us=33333.*slow_frames=\d+" "soak display frame-budget telemetry"
Assert-LogContains "logs/soak_serial.log" "\[face\]\s+mode=\d+\s+blink_count=\d+\s+saccade_count=\d+.*gesture_active=\d+\s+speech_active=\d+\s+speech_env=" "soak face animator telemetry"
Assert-LogContains "logs/soak_serial.log" "\[speech\]\s+seq=\d+\s+at_ms=\d+\s+intent=\w+\s+priority=\d+\s+earcon=\w+\s+earcon_delay_ms=\d+\s+text=" "soak speech cue telemetry"
Assert-LogContains "logs/soak_serial.log" "\[system\]\s+heap_free=\d+\s+heap_min=\d+\s+stack_loop_hwm=\d+\s+stack_motion_hwm=\d+\s+stack_face_hwm=\d+\s+stack_intent_hwm=\d+" "soak runtime health telemetry"

foreach ($recordPath in @($metadata.requiredRecords)) {
  Assert-File $recordPath
}

if ($null -ne $metadata.shareVerification) {
  foreach ($field in @("publicUrl", "verificationReport", "verificationSummary", "hostedMediaReference", "probeCount", "allHttp200")) {
    if ([string]::IsNullOrWhiteSpace([string]$metadata.shareVerification.$field)) {
      throw "metadata shareVerification missing required field: $field"
    }
  }
  $verifiedShareUrl = [string]$metadata.shareVerification.verifiedUrl
  if ([string]::IsNullOrWhiteSpace($verifiedShareUrl)) {
    $verifiedShareUrl = [string]$metadata.shareVerification.publicUrl
  }

  Assert-File ([string]$metadata.shareVerification.hostedMediaReference) 200
  Assert-File ([string]$metadata.shareVerification.verificationReport) 500
  Assert-File ([string]$metadata.shareVerification.verificationSummary) 100
  Assert-File "share/share_status.json" 100
  if (-not [string]::IsNullOrWhiteSpace([string]$metadata.shareVerification.verifiedUrlFile)) {
    Assert-File ([string]$metadata.shareVerification.verifiedUrlFile) 10
  } elseif (Test-Path -LiteralPath (Join-EvidencePath "share/VERIFIED_URL.txt")) {
    Assert-File "share/VERIFIED_URL.txt" 10
  } else {
    Assert-File "share/PUBLIC_URL.txt" 10
  }

  $shareReport = Get-Content -LiteralPath (Join-EvidencePath ([string]$metadata.shareVerification.verificationReport)) -Raw | ConvertFrom-Json
  if ($shareReport.schema -ne "stackchan.share-verification.v1") {
    throw "share verification report schema mismatch: $($shareReport.schema)"
  }
  if ($shareReport.version -ne $metadata.releaseTag) {
    throw "share verification report version mismatch: expected $($metadata.releaseTag), got $($shareReport.version)"
  }
  if ($shareReport.url -ne $verifiedShareUrl) {
    throw "share verification report URL does not match metadata shareVerification verified URL"
  }
  if (-not [bool]$shareReport.allHttp200) {
    throw "share verification report does not show all probes HTTP 200"
  }
  if ([int]$shareReport.probeCount -ne [int]$metadata.shareVerification.probeCount) {
    throw "share verification report probeCount does not match metadata"
  }

  $hostedReferenceText = Get-Content -LiteralPath (Join-EvidencePath ([string]$metadata.shareVerification.hostedMediaReference)) -Raw
  foreach ($pattern in @("Hosted Media Reference", $verifiedShareUrl, "All probes HTTP 200", "review evidence only")) {
    if ($hostedReferenceText -notmatch [regex]::Escape($pattern)) {
      throw "HOSTED_MEDIA_REFERENCE.md missing expected marker: $pattern"
    }
  }
}

if ($null -eq $metadata.voiceLeadAudition) {
  throw "metadata.json missing voiceLeadAudition reference"
}

foreach ($field in @("title", "file", "referenceFile", "sha256", "transcript", "pitch", "index_rate", "rms_mix_rate", "protect")) {
  if ([string]::IsNullOrWhiteSpace([string]$metadata.voiceLeadAudition.$field)) {
    throw "metadata voiceLeadAudition missing required field: $field"
  }
}

Assert-File "RVC_LEAD_AUDITION.md" 200
Assert-File ([string]$metadata.voiceLeadAudition.referenceFile) 100000
Assert-File "reference_audio/RVC_AUDITIONS.md" 500
Assert-File "reference_audio/RVC_AUDITIONS.json" 500

$leadReferencePath = Join-EvidencePath ([string]$metadata.voiceLeadAudition.referenceFile)
$leadReferenceHash = (Get-FileHash -Algorithm SHA256 -LiteralPath $leadReferencePath).Hash.ToLowerInvariant()
if ($leadReferenceHash -ne [string]$metadata.voiceLeadAudition.sha256) {
  throw "RVC lead audition reference hash does not match metadata"
}

$leadReferenceText = Get-Content -LiteralPath (Join-EvidencePath "RVC_LEAD_AUDITION.md") -Raw
foreach ($pattern in @("RVC Lead Audition Reference", [string]$metadata.voiceLeadAudition.title, [string]$metadata.voiceLeadAudition.referenceFile, [string]$metadata.voiceLeadAudition.sha256, "not production voice-source approval")) {
  if ($leadReferenceText -notmatch [regex]::Escape($pattern)) {
    throw "RVC_LEAD_AUDITION.md missing expected marker: $pattern"
  }
}

if ($null -eq $metadata.voiceGateStatus) {
  throw "metadata.json missing voiceGateStatus reference"
}

foreach ($field in @("voiceSourceStatus", "voiceSourceBlockedGateCount", "rvcVoiceBaseStatus", "rvcConsumerApproved", "rvcDistributionApproved")) {
  if ($null -eq $metadata.voiceGateStatus.$field -or [string]::IsNullOrWhiteSpace([string]$metadata.voiceGateStatus.$field)) {
    throw "metadata voiceGateStatus missing required field: $field"
  }
}

Assert-File "VOICE_SOURCE_STATUS.md" 500
Assert-File "voice_source_status.json" 500
Assert-File "RVC_VOICE_BASE_STATUS.md" 500
Assert-File "rvc_voice_base_status.json" 500

$voiceSourceStatus = Get-Content -LiteralPath (Join-EvidencePath "voice_source_status.json") -Raw | ConvertFrom-Json
if ($voiceSourceStatus.schema -ne "stackchan.voice-source-status.v1") {
  throw "voice_source_status.json schema mismatch: $($voiceSourceStatus.schema)"
}
if ($voiceSourceStatus.status -ne [string]$metadata.voiceGateStatus.voiceSourceStatus) {
  throw "voice_source_status.json status does not match metadata voiceGateStatus"
}
if ([int]$voiceSourceStatus.blockedGateCount -ne [int]$metadata.voiceGateStatus.voiceSourceBlockedGateCount) {
  throw "voice_source_status.json blockedGateCount does not match metadata voiceGateStatus"
}

$rvcBaseStatus = Get-Content -LiteralPath (Join-EvidencePath "rvc_voice_base_status.json") -Raw | ConvertFrom-Json
if ($rvcBaseStatus.schema -ne "stackchan.rvc-voice-base-status.v1") {
  throw "rvc_voice_base_status.json schema mismatch: $($rvcBaseStatus.schema)"
}
if ($rvcBaseStatus.status -ne [string]$metadata.voiceGateStatus.rvcVoiceBaseStatus) {
  throw "rvc_voice_base_status.json status does not match metadata voiceGateStatus"
}
if ([bool]$rvcBaseStatus.consumerApproved -ne [bool]$metadata.voiceGateStatus.rvcConsumerApproved) {
  throw "rvc_voice_base_status.json consumerApproved does not match metadata voiceGateStatus"
}
if ([bool]$rvcBaseStatus.distributionApproved -ne [bool]$metadata.voiceGateStatus.rvcDistributionApproved) {
  throw "rvc_voice_base_status.json distributionApproved does not match metadata voiceGateStatus"
}

$voiceSourceStatusText = Get-Content -LiteralPath (Join-EvidencePath "VOICE_SOURCE_STATUS.md") -Raw
foreach ($pattern in @("Voice Source", [string]$metadata.voiceGateStatus.voiceSourceStatus, "production voice")) {
  if ($voiceSourceStatusText -notmatch [regex]::Escape($pattern)) {
    throw "VOICE_SOURCE_STATUS.md missing expected marker: $pattern"
  }
}

$rvcBaseStatusText = Get-Content -LiteralPath (Join-EvidencePath "RVC_VOICE_BASE_STATUS.md") -Raw
foreach ($pattern in @("RVC", [string]$metadata.voiceGateStatus.rvcVoiceBaseStatus, "review")) {
  if ($rvcBaseStatusText -notmatch [regex]::Escape($pattern)) {
    throw "RVC_VOICE_BASE_STATUS.md missing expected marker: $pattern"
  }
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

Assert-AndroidDashboardManifestEvidence $metadata
Assert-AndroidCompanionReportEvidence $metadata

Write-Host "Hardware evidence verified:"
Write-Host $evidencePath
