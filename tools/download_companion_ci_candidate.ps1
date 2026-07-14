param(
  [Parameter(Mandatory = $true)]
  [long]$RunId,
  [string]$Repo = "RobVanProd/stackchan_alive",
  [string]$Commit = "",
  [string]$OutDir = "",
  [string]$FixtureRoot = "",
  [switch]$Json
)

$ErrorActionPreference = "Stop"

$repoRoot = Resolve-Path (Join-Path $PSScriptRoot "..")
Set-Location $repoRoot

function Normalize-Commit {
  param([string]$Value)

  $normalized = ([string]$Value).Trim().ToLowerInvariant()
  if ($normalized -notmatch '^[0-9a-f]{40}$') {
    throw "Expected a full 40-character source commit; got '$Value'."
  }
  return $normalized
}

function Split-Repo {
  param([string]$Repository)

  $parts = $Repository -split "/", 2
  if ($parts.Count -ne 2 -or
      [string]::IsNullOrWhiteSpace($parts[0]) -or
      [string]::IsNullOrWhiteSpace($parts[1])) {
    throw "Repo must be in owner/name form: $Repository"
  }
  return [ordered]@{ owner = $parts[0]; name = $parts[1] }
}

function Get-FixtureJson {
  param([string]$Name)

  $path = Join-Path $FixtureRoot $Name
  if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
    throw "Missing companion CI candidate fixture: $path"
  }
  return Get-Content -LiteralPath $path -Raw
}

function Invoke-GhJson {
  param([string[]]$Arguments)

  $oldPreference = $ErrorActionPreference
  $ErrorActionPreference = "Continue"
  try {
    $output = @(& gh @Arguments 2>&1)
    $exitCode = $LASTEXITCODE
  } finally {
    $ErrorActionPreference = $oldPreference
  }
  if ($exitCode -ne 0) {
    throw "gh command failed with exit code $exitCode`: gh $($Arguments -join ' ')`n$($output | Out-String)"
  }
  return ($output | Out-String).Trim()
}

function Copy-FixtureArtifact {
  param(
    [string]$Name,
    [string]$Destination
  )

  $source = Join-Path $FixtureRoot "downloads/$Name"
  if (-not (Test-Path -LiteralPath $source -PathType Container)) {
    throw "Missing downloaded-artifact fixture for $Name`: $source"
  }
  foreach ($file in @(Get-ChildItem -LiteralPath $source -Recurse -File -Force)) {
    $relativePath = Get-RelativePathNormalized -BasePath $source -Path $file.FullName
    $target = Join-Path $Destination $relativePath
    [void][IO.Directory]::CreateDirectory((Get-ExtendedIoPath ([IO.Path]::GetDirectoryName($target))))
    [IO.File]::Copy(
      (Get-ExtendedIoPath $file.FullName),
      (Get-ExtendedIoPath $target),
      $true
    )
  }
}

function Download-Artifact {
  param(
    [string]$Name,
    [string]$Destination
  )

  New-Item -ItemType Directory -Force -Path $Destination | Out-Null
  if (-not [string]::IsNullOrWhiteSpace($FixtureRoot)) {
    Copy-FixtureArtifact -Name $Name -Destination $Destination
    return
  }

  $oldPreference = $ErrorActionPreference
  $ErrorActionPreference = "Continue"
  try {
    $output = @(& gh run download $RunId --repo $Repo --name $Name --dir $Destination 2>&1)
    $exitCode = $LASTEXITCODE
  } finally {
    $ErrorActionPreference = $oldPreference
  }
  if ($exitCode -ne 0) {
    throw "Could not download GitHub Actions artifact '$Name' from run $RunId (exit $exitCode).`n$($output | Out-String)"
  }
}

function Get-ExtendedIoPath {
  param([string]$Path)

  $fullPath = [IO.Path]::GetFullPath($Path)
  if ([Environment]::OSVersion.Platform -eq [PlatformID]::Win32NT -and
      -not $fullPath.StartsWith("\\?\", [StringComparison]::Ordinal)) {
    if ($fullPath.StartsWith("\\", [StringComparison]::Ordinal)) {
      return "\\?\UNC\" + $fullPath.Substring(2)
    }
    return "\\?\" + $fullPath
  }
  return $fullPath
}

function Get-RelativePathNormalized {
  param(
    [string]$BasePath,
    [string]$Path
  )

  $baseFull = [IO.Path]::GetFullPath($BasePath).TrimEnd("\", "/")
  $pathFull = [IO.Path]::GetFullPath($Path)
  $prefix = $baseFull + [IO.Path]::DirectorySeparatorChar
  if (-not $pathFull.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase)) {
    throw "Path is outside candidate root: $pathFull"
  }
  return $pathFull.Substring($prefix.Length).Replace("\", "/")
}

function Get-Sha256Hex {
  param([string]$Path)

  $stream = $null
  $sha256 = $null
  try {
    $stream = [IO.File]::Open(
      (Get-ExtendedIoPath $Path),
      [IO.FileMode]::Open,
      [IO.FileAccess]::Read,
      [IO.FileShare]::Read
    )
    $sha256 = [Security.Cryptography.SHA256]::Create()
    return ([BitConverter]::ToString($sha256.ComputeHash($stream)) -replace "-", "").ToLowerInvariant()
  } finally {
    if ($null -ne $sha256) { $sha256.Dispose() }
    if ($null -ne $stream) { $stream.Dispose() }
  }
}

function Get-FileEntry {
  param(
    [string]$CandidateRoot,
    [IO.FileInfo]$File
  )

  return [pscustomobject][ordered]@{
    path = Get-RelativePathNormalized -BasePath $CandidateRoot -Path $File.FullName
    name = $File.Name
    bytes = [int64]$File.Length
    sha256 = Get-Sha256Hex -Path $File.FullName
  }
}

if ($RunId -le 0) {
  throw "RunId must be a positive GitHub Actions run id."
}
if ([string]::IsNullOrWhiteSpace($Commit)) {
  $Commit = (& git rev-parse HEAD).Trim()
  if ($LASTEXITCODE -ne 0) {
    throw "Could not resolve the current source commit."
  }
}
$Commit = Normalize-Commit $Commit
$repoParts = Split-Repo $Repo

$runJson = if (-not [string]::IsNullOrWhiteSpace($FixtureRoot)) {
  Get-FixtureJson "run.json"
} else {
  Invoke-GhJson @(
    "run", "view", [string]$RunId,
    "--repo", $Repo,
    "--json", "databaseId,name,headSha,headBranch,status,conclusion,url,event,createdAt,updatedAt,jobs"
  )
}
$run = $runJson | ConvertFrom-Json
$runCommit = Normalize-Commit ([string]$run.headSha)

if ([long]$run.databaseId -ne $RunId) {
  throw "GitHub Actions run id mismatch: requested $RunId, received $($run.databaseId)."
}
if ([string]$run.name -ne "Firmware") {
  throw "Run $RunId is '$($run.name)', not the Firmware workflow."
}
if ([string]$run.status -ne "completed" -or [string]$run.conclusion -ne "success") {
  throw "Firmware run $RunId is not successful and complete: status=$($run.status) conclusion=$($run.conclusion)."
}
if ($runCommit -ne $Commit) {
  throw "Firmware run $RunId source mismatch: run=$runCommit expected=$Commit."
}

$requiredJobs = @(
  "changes",
  "bridge-tests",
  "native-tests",
  "build",
  "companion-tests",
  "companion-platform-builds (android-apk)",
  "companion-platform-builds (desktop-windows)",
  "companion-platform-builds (desktop-macos)",
  "companion-platform-builds (desktop-linux)",
  "companion-android-emulator-smoke",
  "companion-release-evidence"
)
$jobReports = @()
foreach ($jobName in $requiredJobs) {
  $matches = @($run.jobs | Where-Object { [string]$_.name -eq $jobName })
  if ($matches.Count -ne 1) {
    throw "Firmware run $RunId must contain exactly one '$jobName' job; found $($matches.Count)."
  }
  $job = $matches[0]
  if ([string]$job.status -ne "completed" -or [string]$job.conclusion -ne "success") {
    throw "Firmware run $RunId job '$jobName' is not successful and complete."
  }
  $jobReports += [ordered]@{
    name = $jobName
    status = [string]$job.status
    conclusion = [string]$job.conclusion
  }
}

$artifactsJson = if (-not [string]::IsNullOrWhiteSpace($FixtureRoot)) {
  Get-FixtureJson "artifacts.json"
} else {
  Invoke-GhJson @(
    "api",
    "repos/$($repoParts.owner)/$($repoParts.name)/actions/runs/$RunId/artifacts?per_page=100"
  )
}
$artifactResponse = $artifactsJson | ConvertFrom-Json
$availableArtifacts = @($artifactResponse.artifacts)
$requiredArtifacts = @(
  "companion-release-evidence",
  "companion-android-apks",
  "companion-android-emulator-smoke",
  "companion-desktop-windows",
  "companion-desktop-macos",
  "companion-desktop-linux"
)
$artifactMetadata = @()
foreach ($artifactName in $requiredArtifacts) {
  $matches = @($availableArtifacts | Where-Object { [string]$_.name -eq $artifactName })
  if ($matches.Count -ne 1) {
    throw "Firmware run $RunId must contain exactly one '$artifactName' artifact; found $($matches.Count)."
  }
  $artifact = $matches[0]
  if ([bool]$artifact.expired) {
    throw "Firmware run $RunId artifact '$artifactName' has expired."
  }
  if ([int64]$artifact.size_in_bytes -le 0) {
    throw "Firmware run $RunId artifact '$artifactName' is empty."
  }
  $artifactMetadata += $artifact
}

if ([string]::IsNullOrWhiteSpace($OutDir)) {
  $OutDir = Join-Path $repoRoot "output/companion/ci-candidates/$($Commit.Substring(0, 12))-run-$RunId"
}
$candidateRoot = [IO.Path]::GetFullPath($OutDir)
if (Test-Path -LiteralPath $candidateRoot) {
  $existing = @(Get-ChildItem -LiteralPath $candidateRoot -Force -ErrorAction SilentlyContinue)
  if ($existing.Count -gt 0) {
    throw "Candidate output directory is not empty: $candidateRoot"
  }
}
New-Item -ItemType Directory -Force -Path $candidateRoot | Out-Null
$artifactRoot = Join-Path $candidateRoot "artifacts"
New-Item -ItemType Directory -Force -Path $artifactRoot | Out-Null

$artifactReports = @()
foreach ($artifactName in $requiredArtifacts) {
  $metadata = @($artifactMetadata | Where-Object { [string]$_.name -eq $artifactName })[0]
  $destination = Join-Path $artifactRoot $artifactName
  Download-Artifact -Name $artifactName -Destination $destination
  $files = @(
    Get-ChildItem -LiteralPath $destination -Recurse -File |
      Sort-Object FullName |
      ForEach-Object { Get-FileEntry -CandidateRoot $candidateRoot -File $_ }
  )
  if ($files.Count -lt 1) {
    throw "Downloaded artifact '$artifactName' contains no files."
  }

  if ($artifactName -eq "companion-release-evidence") {
    $probeFiles = @(
      Get-ChildItem -LiteralPath $destination -Recurse -File -Filter "COMPANION_RELEASE_EVIDENCE.json"
    )
    if ($probeFiles.Count -ne 1) {
      throw "Expected exactly one COMPANION_RELEASE_EVIDENCE.json; found $($probeFiles.Count)."
    }
    $probe = Get-Content -LiteralPath $probeFiles[0].FullName -Raw | ConvertFrom-Json
    if ([string]$probe.schema -ne "stackchan.companion-release-evidence.v1") {
      throw "Downloaded companion release evidence has an unexpected schema."
    }
    if ([string]$probe.status -ne "complete" -or @($probe.pending).Count -ne 0) {
      throw "Downloaded companion release evidence is incomplete: status=$($probe.status)."
    }
    $probeCommit = Normalize-Commit ([string]$probe.commit)
    if ($probeCommit -ne $Commit) {
      throw "Downloaded companion release evidence source mismatch: evidence=$probeCommit expected=$Commit."
    }
    if ((Normalize-Commit ([string]$probe.version)) -ne $Commit) {
      throw "Downloaded companion release evidence version is not the exact source commit."
    }
  }

  $artifactReports += [ordered]@{
    name = $artifactName
    id = [long]$metadata.id
    apiSizeBytes = [int64]$metadata.size_in_bytes
    expired = [bool]$metadata.expired
    localPath = Get-RelativePathNormalized -BasePath $candidateRoot -Path $destination
    fileCount = $files.Count
    downloadedBytes = [int64](($files | Measure-Object -Property bytes -Sum).Sum)
    files = @($files)
  }
}

$releaseEvidenceFiles = @(
  Get-ChildItem -LiteralPath (Join-Path $artifactRoot "companion-release-evidence") -Recurse -File -Filter "COMPANION_RELEASE_EVIDENCE.json"
)
if ($releaseEvidenceFiles.Count -ne 1) {
  throw "Expected exactly one COMPANION_RELEASE_EVIDENCE.json; found $($releaseEvidenceFiles.Count)."
}
$releaseEvidenceFile = $releaseEvidenceFiles[0]
$releaseEvidence = Get-Content -LiteralPath $releaseEvidenceFile.FullName -Raw | ConvertFrom-Json
if ([string]$releaseEvidence.schema -ne "stackchan.companion-release-evidence.v1") {
  throw "Downloaded companion release evidence has an unexpected schema."
}
if ([string]$releaseEvidence.status -ne "complete" -or @($releaseEvidence.pending).Count -ne 0) {
  throw "Downloaded companion release evidence is incomplete: status=$($releaseEvidence.status)."
}
$evidenceCommit = Normalize-Commit ([string]$releaseEvidence.commit)
if ($evidenceCommit -ne $Commit) {
  throw "Downloaded companion release evidence source mismatch: evidence=$evidenceCommit expected=$Commit."
}
if ((Normalize-Commit ([string]$releaseEvidence.version)) -ne $Commit) {
  throw "Downloaded companion release evidence version is not the exact source commit."
}

$downloadedFiles = @($artifactReports | ForEach-Object { @($_.files) })
$evidenceArtifactEntries = @($releaseEvidence.artifacts | ForEach-Object { @($_.entries) })
if ($evidenceArtifactEntries.Count -ne 6) {
  throw "Companion release evidence must bind exactly six Android/desktop distribution artifacts; found $($evidenceArtifactEntries.Count)."
}
foreach ($entry in $evidenceArtifactEntries) {
  $matches = @($downloadedFiles | Where-Object { $_.name -eq [string]$entry.name })
  if ($matches.Count -ne 1) {
    throw "Evidence entry '$($entry.name)' must match exactly one downloaded file; found $($matches.Count)."
  }
  $downloaded = $matches[0]
  if ([int64]$downloaded.bytes -ne [int64]$entry.bytes -or
      [string]$downloaded.sha256 -ne ([string]$entry.sha256).ToLowerInvariant()) {
    throw "Downloaded file does not match companion release evidence: $($entry.name)"
  }
}

$report = [ordered]@{
  schema = "stackchan.companion-ci-candidate.v1"
  status = "companion-ci-candidate-ready"
  scope = "exact-source-ci-rehearsal-artifacts"
  substitutesForTaggedRelease = $false
  substitutesForPhysicalEvidence = $false
  publicReleaseReady = $false
  repo = $Repo
  runId = $RunId
  runUrl = [string]$run.url
  workflow = [string]$run.name
  event = [string]$run.event
  branch = [string]$run.headBranch
  sourceCommit = $Commit
  generatedUtc = (Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")
  outputRoot = $candidateRoot
  jobs = @($jobReports)
  artifacts = @($artifactReports)
  releaseEvidence = [ordered]@{
    path = Get-RelativePathNormalized -BasePath $candidateRoot -Path $releaseEvidenceFile.FullName
    sha256 = Get-Sha256Hex -Path $releaseEvidenceFile.FullName
    status = [string]$releaseEvidence.status
    sourceCommit = $evidenceCommit
    androidSigningProfile = [string]$releaseEvidence.androidSigning.signingProfile
    androidBundleSigningProfile = [string]$releaseEvidence.androidBundleSigning.signingProfile
    desktopPackageEvidenceStatus = [string]$releaseEvidence.desktopPackageEvidence.status
  }
  limitations = @(
    "CI rehearsal Android release artifacts may use the explicit lab debug-signing fallback.",
    "CI rehearsal desktop packages are not substitutes for production Authenticode or Developer ID/notarization evidence.",
    "Target-phone, target-workstation, and robot evidence must remain bound to the exact downloaded file hashes."
  )
}

$manifestPath = Join-Path $candidateRoot "COMPANION_CI_CANDIDATE.json"
$report | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $manifestPath -Encoding UTF8

if ($Json) {
  $report | ConvertTo-Json -Depth 12
} else {
  Write-Host "Companion CI candidate: $($report.status)"
  Write-Host "Run: $RunId ($($report.runUrl))"
  Write-Host "Source commit: $Commit"
  Write-Host "Artifacts: $($artifactReports.Count)  Files: $($downloadedFiles.Count)"
  Write-Host "Manifest: $manifestPath"
  Write-Host "Scope: CI rehearsal only; not a tagged or production-signed release."
}
