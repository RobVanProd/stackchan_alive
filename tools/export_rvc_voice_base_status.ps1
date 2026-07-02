param(
  [string]$ManifestPath = "data/voice_rvc_base.yaml",
  [string]$MetadataPath = "data/voice_rvc_base_metadata.json",
  [string]$ZipPath = "",
  [string]$OutputDir = "."
)

$ErrorActionPreference = "Stop"

$repoRoot = Resolve-Path (Join-Path $PSScriptRoot "..")
Push-Location $repoRoot
trap {
  $errorRecord = $_
  Pop-Location
  throw $errorRecord
}

function Get-RegexValue {
  param(
    [string]$Text,
    [string]$Pattern,
    [string]$Default = ""
  )

  $match = [regex]::Match($Text, $Pattern, [System.Text.RegularExpressions.RegexOptions]::Multiline)
  if ($match.Success) {
    return $match.Groups[1].Value.Trim()
  }
  return $Default
}

function New-Gate {
  param(
    [string]$Gate,
    [string]$Status,
    [string]$Detail
  )

  [ordered]@{
    gate = $Gate
    status = $Status
    detail = $Detail
  }
}

if (-not (Test-Path -LiteralPath $ManifestPath)) {
  throw "Missing RVC voice base manifest: $ManifestPath"
}
if (-not (Test-Path -LiteralPath $MetadataPath)) {
  throw "Missing RVC voice base metadata: $MetadataPath"
}

if ([string]::IsNullOrWhiteSpace($ZipPath)) {
  $ZipPath = "output/voice_sources/stackchan_rvc_base/stackchan_voice_weightsgg_model.zip"
}

$manifestText = Get-Content -LiteralPath $ManifestPath -Raw
$metadata = Get-Content -LiteralPath $MetadataPath -Raw | ConvertFrom-Json
$expectedBytes = [int64](Get-RegexValue $manifestText "(?m)^\s+bytes:\s+([0-9]+)\s*$" "0")
$expectedSha256 = (Get-RegexValue $manifestText "(?m)^\s+sha256:\s+([A-Fa-f0-9]+)\s*$").ToUpperInvariant()
$driveFileId = Get-RegexValue $manifestText "(?m)^\s+drive_file_id:\s+(.+)\s*$"
$driveFileUrl = Get-RegexValue $manifestText "(?m)^\s+drive_file_url:\s+(.+)\s*$"
$weightsLink = Get-RegexValue $manifestText "(?m)^\s+weights_link:\s+(.+)\s*$"
$localCachePath = Get-RegexValue $manifestText "(?m)^\s+local_cache_path:\s+(.+)\s*$"
$consumerApproved = ($manifestText -match "(?m)^\s+consumer_approved:\s+true\s*$")
$gates = New-Object System.Collections.Generic.List[object]

if ($manifestText -match "schema:\s+stackchan\.rvc-voice-base\.v1") {
  $gates.Add((New-Gate "manifest-schema" "pass" "RVC base manifest schema present.")) | Out-Null
} else {
  $gates.Add((New-Gate "manifest-schema" "fail" "RVC base manifest schema missing.")) | Out-Null
}

if ($manifestText -match "status:\s+candidate-pending-rights-review") {
  $gates.Add((New-Gate "rights-review-status" "blocked" "Candidate remains pending rights review; not approved for consumer rollout.")) | Out-Null
} else {
  $gates.Add((New-Gate "rights-review-status" "pass" "No pending-rights-review status marker found.")) | Out-Null
}

if ($consumerApproved) {
  $gates.Add((New-Gate "consumer-approval" "pass" "Manifest marks candidate consumer approved.")) | Out-Null
} else {
  $gates.Add((New-Gate "consumer-approval" "blocked" "Manifest marks candidate consumer_approved: false.")) | Out-Null
}

$localArchive = [ordered]@{
  path = $ZipPath
  present = $false
  bytes = [int64]0
  sha256 = ""
  entriesVerified = $false
}

if (Test-Path -LiteralPath $ZipPath) {
  $zipItem = Get-Item -LiteralPath $ZipPath
  $actualSha256 = (Get-FileHash -Algorithm SHA256 -LiteralPath $ZipPath).Hash.ToUpperInvariant()
  $localArchive["present"] = $true
  $localArchive["bytes"] = [int64]$zipItem.Length
  $localArchive["sha256"] = $actualSha256

  if ($zipItem.Length -eq $expectedBytes -and $actualSha256 -eq $expectedSha256) {
    $gates.Add((New-Gate "local-archive-hash" "pass" "Local RVC archive matches expected byte count and SHA256.")) | Out-Null
  } else {
    $gates.Add((New-Gate "local-archive-hash" "fail" "Local RVC archive does not match expected byte count or SHA256.")) | Out-Null
  }

  Add-Type -AssemblyName System.IO.Compression.FileSystem
  $zip = [System.IO.Compression.ZipFile]::OpenRead((Resolve-Path $ZipPath).Path)
  try {
    $expectedEntries = @(
      @{ Path = "model.pth"; Bytes = 57577722 },
      @{ Path = "model.index"; Bytes = 99428699 },
      @{ Path = "metadata.json"; Bytes = 2781 }
    )
    $entryErrors = @()
    foreach ($expected in $expectedEntries) {
      $entry = $zip.GetEntry($expected.Path)
      if ($null -eq $entry) {
        $entryErrors += "missing $($expected.Path)"
      } elseif ($entry.Length -ne $expected.Bytes) {
        $entryErrors += "$($expected.Path) expected $($expected.Bytes), got $($entry.Length)"
      }
    }
    if ($entryErrors.Count -eq 0) {
      $localArchive["entriesVerified"] = $true
      $gates.Add((New-Gate "local-archive-entries" "pass" "Local RVC archive contains model.pth, model.index, and metadata.json with expected sizes.")) | Out-Null
    } else {
      $gates.Add((New-Gate "local-archive-entries" "fail" ($entryErrors -join "; "))) | Out-Null
    }
  } finally {
    $zip.Dispose()
  }
} else {
  $gates.Add((New-Gate "local-archive-hash" "pending" "Local RVC archive not present in cache; manifest and metadata are still recorded.")) | Out-Null
}

$failedCount = @($gates | Where-Object { $_.status -eq "fail" }).Count
$blockedCount = @($gates | Where-Object { $_.status -eq "blocked" }).Count
$localVerified = $localArchive["present"] -and $localArchive["entriesVerified"] -and $localArchive["sha256"] -eq $expectedSha256 -and $localArchive["bytes"] -eq $expectedBytes
$gateArray = @($gates.ToArray())
$status = if ($failedCount -gt 0) {
  "invalid"
} elseif ($localVerified) {
  "local-archive-verified-review-only"
} else {
  "manifest-recorded-review-only"
}

New-Item -ItemType Directory -Force -Path $OutputDir | Out-Null
$jsonPath = Join-Path $OutputDir "rvc_voice_base_status.json"
$markdownPath = Join-Path $OutputDir "RVC_VOICE_BASE_STATUS.md"

$report = [ordered]@{
  schema = "stackchan.rvc-voice-base-status.v1"
  status = $status
  generatedUtc = (Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")
  manifest = $ManifestPath
  metadata = $MetadataPath
  driveFileId = $driveFileId
  driveFileUrl = $driveFileUrl
  weightsLink = $weightsLink
  title = [string]$metadata.title
  author = [string]$metadata.author.name
  modelId = [string]$metadata.id
  modelType = [string]$metadata.type
  sampleRate = [int]$metadata.torchMetadata.config.sr
  f0 = [int]$metadata.torchMetadata.f0
  expectedArchive = [ordered]@{
    localCachePath = $localCachePath
    bytes = $expectedBytes
    sha256 = $expectedSha256
  }
  localArchive = $localArchive
  consumerApproved = $consumerApproved
  distributionApproved = $false
  blockedGateCount = $blockedCount
  failedGateCount = $failedCount
  gates = $gateArray
  policy = "This RVC base is available for internal audition and device-speaker character checks only. It is not a licensed or owned production voice source and must not be used for consumer rollout until rights, consent, training-source, and commercial-device-use evidence are completed."
}

$report | ConvertTo-Json -Depth 8 | Set-Content -Path $jsonPath -Encoding UTF8

$localLine = if ($localVerified) {
  "- Local archive: verified ($($localArchive["bytes"]) bytes, SHA256 $($localArchive["sha256"]))"
} elseif ($localArchive["present"]) {
  "- Local archive: present but failed verification"
} else {
  "- Local archive: not present in cache when this report was generated"
}

$markdown = @(
  "# RVC Voice Base Status",
  "",
  "- Status: $status",
  "- Drive file ID: $driveFileId",
  "- Weights.gg model: $weightsLink",
  "- Title: $($metadata.title)",
  "- Author: $($metadata.author.name)",
  "- Model: $($metadata.type), $($metadata.torchMetadata.config.sr) Hz, f0=$($metadata.torchMetadata.f0)",
  $localLine,
  "- Consumer approved: $consumerApproved",
  "- Distribution approved: False",
  "",
  "This verifies the RVC base artifact used for review auditions when the local cache is available. It does **not** clear the production voice-source gate. The candidate remains review-only until rights, consent, training-source, commercial-device-use, generated-prompt distribution, and real-device evidence are complete.",
  "",
  "Machine-readable status: rvc_voice_base_status.json"
) -join [Environment]::NewLine
$markdown | Set-Content -Path $markdownPath -Encoding UTF8

Write-Host "RVC voice base status exported:"
Write-Host $markdownPath
Write-Host $jsonPath
Write-Host "Status: $status"

Pop-Location
