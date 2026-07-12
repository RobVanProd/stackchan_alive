param(
  [Parameter(Mandatory = $true)]
  [string]$CandidateRoot,
  [Parameter(Mandatory = $true)]
  [string]$NoMotionEvidenceRoot,
  [Parameter(Mandatory = $true)]
  [string]$ShortActuatorEvidenceRoot,
  [Parameter(Mandatory = $true)]
  [string]$HourEvidenceRoot,
  [Parameter(Mandatory = $true)]
  [string]$VoiceProofRoot,
  [Parameter(Mandatory = $true)]
  [string]$LongSoakEvidenceRoot,
  [string]$OutputRoot = "",
  [switch]$Json
)

$ErrorActionPreference = "Stop"

$RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
Set-Location $RepoRoot

function Read-JsonFile {
  param([string]$Path)
  return Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json
}

function Get-PropertyValue {
  param($Object, [string]$Name, $Default = $null)
  if ($null -eq $Object) { return $Default }
  $property = $Object.PSObject.Properties[$Name]
  if ($null -eq $property -or $null -eq $property.Value) { return $Default }
  return $property.Value
}

function Normalize-Sha256 {
  param([string]$Value)
  $clean = $Value.Trim().ToUpperInvariant()
  if ($clean -notmatch '^[0-9A-F]{64}$') { return "" }
  return $clean
}

function Normalize-Commit {
  param([string]$Value)
  $clean = $Value.Trim().ToLowerInvariant()
  if ($clean -notmatch '^[0-9a-f]{40}$') { return "" }
  return $clean
}

function Copy-Tree {
  param([string]$Source, [string]$Destination)
  if (-not (Test-Path -LiteralPath $Source -PathType Container)) {
    throw "Required evidence directory is missing: $Source"
  }
  New-Item -ItemType Directory -Force -Path $Destination | Out-Null
  Get-ChildItem -LiteralPath $Source -Force | Copy-Item -Destination $Destination -Recurse -Force
}

function Test-SoakEvidence {
  param(
    [string]$Root,
    [string]$Label,
    [string]$FirmwareSha256,
    [string]$SourceCommit,
    [int]$MinimumDurationSeconds
  )
  $summaryPath = Join-Path $Root "summary.json"
  $formalPath = Join-Path $Root "formal-check.json"
  if (-not (Test-Path -LiteralPath $summaryPath -PathType Leaf)) {
    throw "$Label summary is missing: $summaryPath"
  }
  if (-not (Test-Path -LiteralPath $formalPath -PathType Leaf)) {
    throw "$Label formal check is missing: $formalPath"
  }
  $summary = Read-JsonFile $summaryPath
  $formal = Read-JsonFile $formalPath
  $summaryHash = Normalize-Sha256 ([string](Get-PropertyValue $summary "installedFirmwareSha256" ""))
  $summaryCommit = Normalize-Commit ([string](Get-PropertyValue $summary "sourceCommit" ""))
  $issues = @((Get-PropertyValue $summary "issues" @()))
  $duration = [int64](Get-PropertyValue $summary "durationSeconds" 0)
  if ([string]$summary.schema -ne "stackchan.full-system-soak-summary.v1" -or
      [string]$summary.status -ne "pass" -or $issues.Count -ne 0 -or
      $duration -lt $MinimumDurationSeconds) {
    throw "$Label summary is not a passing $MinimumDurationSeconds-second soak."
  }
  if ($summaryHash -ne $FirmwareSha256) {
    throw "$Label firmware hash does not match the candidate."
  }
  if ($summaryCommit -ne $SourceCommit) {
    throw "$Label source commit does not match the candidate."
  }
  if ([string]$formal.schema -ne "stackchan.full-system-soak-evidence-check.v1" -or
      [string]$formal.status -ne "full-system-soak-ready" -or
      [int](Get-PropertyValue $formal "failed" -1) -ne 0 -or
      [int](Get-PropertyValue $formal "pending" -1) -ne 0) {
    throw "$Label formal checker result is not ready."
  }
  return [ordered]@{
    durationSeconds = $duration
    summary = "$Label/summary.json"
    formalCheck = "$Label/formal-check.json"
    formalPassed = [int](Get-PropertyValue $formal "passed" 0)
  }
}

$candidateRootPath = (Resolve-Path $CandidateRoot).Path
$candidateManifestPath = Join-Path $candidateRootPath "manifest.json"
if (-not (Test-Path -LiteralPath $candidateManifestPath -PathType Leaf)) {
  throw "Candidate manifest is missing: $candidateManifestPath"
}
$candidateManifest = Read-JsonFile $candidateManifestPath
$firmwareSha256 = Normalize-Sha256 ([string](Get-PropertyValue $candidateManifest "firmware_sha256" ""))
$sourceCommit = Normalize-Commit ([string](Get-PropertyValue $candidateManifest "source_commit" ""))
if (-not $firmwareSha256) { throw "Candidate manifest firmware_sha256 is invalid." }
if (-not $sourceCommit) { throw "Candidate manifest source_commit is invalid." }

$candidateDir = Join-Path $candidateRootPath "candidate"
$requiredCandidateFiles = @("firmware.bin", "firmware.elf", "firmware.map", "bootloader.bin", "partitions.bin")
foreach ($name in $requiredCandidateFiles) {
  $path = Join-Path $candidateDir $name
  if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { throw "Candidate artifact is missing: $path" }
}
$firmwarePath = Join-Path $candidateDir "firmware.bin"
$actualFirmwareSha256 = (Get-FileHash -LiteralPath $firmwarePath -Algorithm SHA256).Hash
if ($actualFirmwareSha256 -ne $firmwareSha256) {
  throw "Candidate firmware does not match its manifest: expected=$firmwareSha256 actual=$actualFirmwareSha256"
}

& git cat-file -e "$sourceCommit`^{commit}"
if ($LASTEXITCODE -ne 0) { throw "Candidate source commit is not available locally: $sourceCommit" }

$noMotion = Test-SoakEvidence $NoMotionEvidenceRoot "no-motion" $firmwareSha256 $sourceCommit 120
$shortActuator = Test-SoakEvidence $ShortActuatorEvidenceRoot "short-actuator" $firmwareSha256 $sourceCommit 300
$hour = Test-SoakEvidence $HourEvidenceRoot "hour" $firmwareSha256 $sourceCommit 3600
$longSoak = Test-SoakEvidence $LongSoakEvidenceRoot "long-soak" $firmwareSha256 $sourceCommit 28800

$voiceProofPath = Join-Path $VoiceProofRoot "voice-proof.json"
if (-not (Test-Path -LiteralPath $voiceProofPath -PathType Leaf)) {
  throw "Voice proof is missing: $voiceProofPath"
}
$voiceProof = Read-JsonFile $voiceProofPath
if ([string]$voiceProof.schema -ne "stackchan.production-voice-proof.v1" -or
    [string]$voiceProof.status -ne "pass" -or
    (Normalize-Sha256 ([string](Get-PropertyValue $voiceProof "firmwareSha256" ""))) -ne $firmwareSha256 -or
    (Normalize-Commit ([string](Get-PropertyValue $voiceProof "sourceCommit" ""))) -ne $sourceCommit) {
  throw "Voice proof does not bind a passing production turn to this candidate."
}

if ([string]::IsNullOrWhiteSpace($OutputRoot)) {
  $OutputRoot = "output\private\current-lead\stackchan-current-lead-$($sourceCommit.Substring(0, 8))-" +
    (Get-Date -Format "yyyyMMdd-HHmmss")
}
$absoluteOutput = [System.IO.Path]::GetFullPath((Join-Path $RepoRoot $OutputRoot))
$allowedRoot = [System.IO.Path]::GetFullPath((Join-Path $RepoRoot "output\private\current-lead"))
if (-not $absoluteOutput.StartsWith($allowedRoot + [System.IO.Path]::DirectorySeparatorChar, [System.StringComparison]::OrdinalIgnoreCase)) {
  throw "OutputRoot must be a new directory under output\private\current-lead."
}
if (Test-Path -LiteralPath $absoluteOutput) { throw "OutputRoot already exists: $absoluteOutput" }
$zipPath = "$absoluteOutput.zip"
if (Test-Path -LiteralPath $zipPath) { throw "Archive already exists: $zipPath" }
$stageRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("stackchan-lead-stage-" + [guid]::NewGuid().ToString("N"))
New-Item -ItemType Directory -Force -Path (Split-Path $zipPath -Parent), $stageRoot | Out-Null
try {
  $candidateOut = Join-Path $stageRoot "candidate"
  $sourceOut = Join-Path $stageRoot "source"
  $evidenceOut = Join-Path $stageRoot "evidence"
  New-Item -ItemType Directory -Force -Path $candidateOut, $sourceOut, $evidenceOut | Out-Null

  foreach ($name in $requiredCandidateFiles) {
    Copy-Item -LiteralPath (Join-Path $candidateDir $name) -Destination (Join-Path $candidateOut $name)
  }
  Copy-Item -LiteralPath $candidateManifestPath -Destination (Join-Path $candidateOut "candidate-manifest.json")
  $otaEvidence = Join-Path $candidateRootPath "ota-evidence"
  if (Test-Path -LiteralPath $otaEvidence -PathType Container) {
    Copy-Tree $otaEvidence (Join-Path $candidateOut "ota-evidence")
  }

  $sourceZip = Join-Path $sourceOut "source.zip"
  & git archive --format=zip --output=$sourceZip $sourceCommit
  if ($LASTEXITCODE -ne 0 -or -not (Test-Path -LiteralPath $sourceZip -PathType Leaf)) {
    throw "Failed to archive exact source commit $sourceCommit."
  }

  Copy-Tree $NoMotionEvidenceRoot (Join-Path $evidenceOut "no-motion")
  Copy-Tree $ShortActuatorEvidenceRoot (Join-Path $evidenceOut "short-actuator")
  Copy-Tree $HourEvidenceRoot (Join-Path $evidenceOut "hour")
  Copy-Tree $VoiceProofRoot (Join-Path $evidenceOut "voice-proof")
  Copy-Tree $LongSoakEvidenceRoot (Join-Path $evidenceOut "long-soak")

  $manifest = [ordered]@{
  schema = "stackchan.current-lead-archive.v1"
  status = "release-acceptance-evidence-complete"
  generatedAt = (Get-Date).ToUniversalTime().ToString("o")
  distribution = "PRIVATE - firmware contains paired deployment configuration; never publish"
  firmwareSha256 = $firmwareSha256
  firmwareBytes = (Get-Item -LiteralPath $firmwarePath).Length
  sourceCommit = $sourceCommit
  candidateManifest = "candidate/candidate-manifest.json"
  sourceSnapshot = "source/source.zip"
  voiceProof = [ordered]@{
    path = "evidence/voice-proof/voice-proof.json"
    route = [string](Get-PropertyValue $voiceProof "route" "")
    firstAudioMs = Get-PropertyValue $voiceProof "firstAudioMs" $null
    complete = [bool](Get-PropertyValue $voiceProof "complete" $false)
    truncated = [bool](Get-PropertyValue $voiceProof "truncated" $true)
  }
  evidence = [ordered]@{
    noMotion = $noMotion
    shortActuator = $shortActuator
    hour = $hour
    longSoak = $longSoak
  }
  }
  $manifestPath = Join-Path $stageRoot "manifest.json"
  $manifest | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $manifestPath -Encoding UTF8

  $files = @(Get-ChildItem -LiteralPath $stageRoot -Recurse -File | Sort-Object FullName | ForEach-Object {
      [ordered]@{
        path = $_.FullName.Substring($stageRoot.Length + 1).Replace("\", "/")
        bytes = $_.Length
        sha256 = (Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash
      }
    })
  $files | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath (Join-Path $stageRoot "files.json") -Encoding UTF8

  Compress-Archive -Path (Join-Path $stageRoot "*") -DestinationPath $zipPath -CompressionLevel Optimal
  Add-Type -AssemblyName System.IO.Compression.FileSystem
  $archive = [System.IO.Compression.ZipFile]::OpenRead($zipPath)
  try {
    $entries = @($archive.Entries | ForEach-Object { $_.FullName.Replace("\", "/") })
  } finally {
    $archive.Dispose()
  }
  $requiredEntries = @(
    "manifest.json",
    "files.json",
    "candidate/firmware.bin",
    "candidate/candidate-manifest.json",
    "source/source.zip",
    "evidence/no-motion/summary.json",
    "evidence/short-actuator/summary.json",
    "evidence/hour/summary.json",
    "evidence/voice-proof/voice-proof.json",
    "evidence/long-soak/summary.json",
    "evidence/long-soak/formal-check.json"
  )
  $missing = @($requiredEntries | Where-Object { $entries -notcontains $_ })
  if ($missing.Count -gt 0) { throw "Archive verification failed; missing: $($missing -join ', ')" }
  $restricted = @($entries | Where-Object {
    $_ -match '(?i)(^|/)[^/]+\.(pth|index|onnx)$' -or
    $_ -match '(?i)(ota[-_ ]?token|pairing[-_ ]?(code|secret)|wifi[-_ ]?(password|credentials)).*\.(txt|json|ya?ml|env)$' -or
    $_ -match '(?i)weightsgg|weights\.gg'
  })
  if ($restricted.Count -gt 0) { throw "Archive contains restricted plaintext/model payload: $($restricted -join ', ')" }

  $result = [ordered]@{
    schema = "stackchan.current-lead-archive-result.v1"
    status = "verified"
    archiveBase = $absoluteOutput
    archive = $zipPath
    archiveSha256 = (Get-FileHash -LiteralPath $zipPath -Algorithm SHA256).Hash
    archiveBytes = (Get-Item -LiteralPath $zipPath).Length
    archiveEntries = $entries.Count
    firmwareSha256 = $firmwareSha256
    sourceCommit = $sourceCommit
  }
  $result | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath "$absoluteOutput-archive-result.json" -Encoding UTF8
  if ($Json) { $result | ConvertTo-Json -Depth 5 } else { Write-Host "Current lead archived: $zipPath" }
} finally {
  if (Test-Path -LiteralPath $stageRoot) {
    Remove-Item -LiteralPath $stageRoot -Recurse -Force
  }
}
