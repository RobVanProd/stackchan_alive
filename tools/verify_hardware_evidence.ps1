param(
  [string]$EvidenceRoot,
  [int64]$MinLogBytes = 128,
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
  Assert-File $logPath $MinLogBytes
}

foreach ($recordPath in @($metadata.requiredRecords)) {
  Assert-File $recordPath
}

if ($null -ne $metadata.package) {
  $copiedPackage = [string]$metadata.package.copiedFile
  Assert-File $copiedPackage 100000

  $copiedPath = Join-EvidencePath $copiedPackage
  $actualPackageHash = (Get-FileHash -Algorithm SHA256 -LiteralPath $copiedPath).Hash.ToLowerInvariant()
  if ($actualPackageHash -ne [string]$metadata.package.sha256) {
    throw "Copied package hash does not match metadata"
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

if (-not $AllowMissingMedia) {
  $mediaFiles = Get-ChildItem -LiteralPath (Join-EvidencePath "photos") -File -ErrorAction SilentlyContinue |
    Where-Object { $_.Name -ne ".gitkeep" -and $_.Length -gt 0 }

  if ($null -eq $mediaFiles -or @($mediaFiles).Count -lt 1) {
    throw "No non-empty photo or video evidence found under photos/"
  }
}

Write-Host "Hardware evidence verified:"
Write-Host $evidencePath
