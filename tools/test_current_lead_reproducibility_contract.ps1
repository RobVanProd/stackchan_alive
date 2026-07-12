$ErrorActionPreference = "Stop"

$RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
$Checker = Join-Path $RepoRoot "tools\check_current_lead_reproducibility.ps1"
$checkerSource = Get-Content -LiteralPath $Checker -Raw
if (-not $checkerSource.Contains('$leadArchiveLeaf = if ([string]::IsNullOrWhiteSpace($LeadArchivePath))')) {
  throw "Current-lead checker must handle an unavailable auto-discovered archive without calling Split-Path on an empty path."
}
$tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("stackchan-current-lead-repro-" + [guid]::NewGuid().ToString("N"))
$stage = Join-Path $tempRoot "stage"
$sourceCommit = "b" * 40

function Write-Utf8File {
  param([string]$Path, [string]$Text)
  New-Item -ItemType Directory -Force -Path (Split-Path $Path -Parent) | Out-Null
  [System.IO.File]::WriteAllText($Path, $Text, (New-Object System.Text.UTF8Encoding($false)))
}

function New-TestArchive {
  param([string]$Path, [switch]$BadHash, [switch]$MissingSource)
  if (Test-Path -LiteralPath $stage) { Remove-Item -LiteralPath $stage -Recurse -Force }
  New-Item -ItemType Directory -Force -Path $stage | Out-Null
  $firmware = [byte[]](0..255)
  $candidatePath = Join-Path $stage "candidate\firmware.bin"
  New-Item -ItemType Directory -Force -Path (Split-Path $candidatePath -Parent) | Out-Null
  [System.IO.File]::WriteAllBytes($candidatePath, $firmware)
  $actualHash = (Get-FileHash -LiteralPath $candidatePath -Algorithm SHA256).Hash
  if (-not $MissingSource) { Write-Utf8File (Join-Path $stage "source\source.zip") "source" }
  Write-Utf8File (Join-Path $stage "evidence\long-soak\summary.json") "{}"
  Write-Utf8File (Join-Path $stage "evidence\long-soak\formal-check.json") "{}"
  $manifestHash = if ($BadHash) { "0" * 64 } else { $actualHash }
  [ordered]@{
    schema = "stackchan.current-lead-archive.v1"
    firmwareSha256 = $manifestHash
    sourceCommit = $sourceCommit
  } | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $stage "manifest.json") -Encoding UTF8
  @([ordered]@{ path = "candidate/firmware.bin"; bytes = $firmware.Length; sha256 = $actualHash }) |
    ConvertTo-Json | Set-Content -LiteralPath (Join-Path $stage "files.json") -Encoding UTF8
  if (Test-Path -LiteralPath $Path) { Remove-Item -LiteralPath $Path -Force }
  Compress-Archive -Path (Join-Path $stage "*") -DestinationPath $Path
  return $actualHash
}

try {
  New-Item -ItemType Directory -Force -Path $tempRoot | Out-Null
  $archive = Join-Path $tempRoot "stackchan-current-lead-contract.zip"
  $actualHash = New-TestArchive -Path $archive
  $candidate = Join-Path $tempRoot "candidate-manifest.json"
  [ordered]@{
    schema = "stackchan.private-conversation-soak-hardening-candidate.v1"
    firmware_sha256 = $actualHash
    source_commit = $sourceCommit
  } | ConvertTo-Json | Set-Content -LiteralPath $candidate -Encoding UTF8

  $summary = Join-Path $tempRoot "summary.json"
  [ordered]@{
    schema = "stackchan.full-system-soak-summary.v1"
    status = "pass"
    issues = @()
    durationSeconds = 28800
    installedFirmwareSha256 = $actualHash
    sourceCommit = $sourceCommit
  } | ConvertTo-Json | Set-Content -LiteralPath $summary -Encoding UTF8
  $formal = Join-Path $tempRoot "formal-check.json"
  [ordered]@{
    schema = "stackchan.full-system-soak-evidence-check.v1"
    status = "full-system-soak-ready"
    passed = 70
    failed = 0
    pending = 0
  } | ConvertTo-Json | Set-Content -LiteralPath $formal -Encoding UTF8
  $statusDoc = Join-Path $tempRoot "FIRST_DEPLOY_STATUS.md"
  $runbook = Join-Path $tempRoot "ARRIVAL_DAY_RUNBOOK.md"
  $markers = "$actualHash`n$sourceCommit`n$(Split-Path $archive -Leaf)`n"
  Write-Utf8File $statusDoc $markers
  Write-Utf8File $runbook $markers
  $reportDir = Join-Path $tempRoot "report"

  $output = & $Checker `
    -LeadArchivePath $archive `
    -CandidateManifestPath $candidate `
    -SoakSummaryPath $summary `
    -FormalCheckPath $formal `
    -StatusDocPath $statusDoc `
    -RunbookPath $runbook `
    -ReportDir $reportDir `
    -MinSoakDurationSeconds 28800 `
    -SkipLive `
    -Json
  if ($LASTEXITCODE -ne 0) {
    Write-Host ($output | Out-String)
    throw "Expected exact-lead contract fixture to pass without -RequireReady."
  }
  $result = $output | ConvertFrom-Json
  if ($result.schema -ne "stackchan.current-lead-reproducibility.v2") { throw "Unexpected schema: $($result.schema)" }
  if ($result.status -ne "current-lead-reproducible-pending") { throw "SkipLive should leave only live checks pending." }
  if ($result.failed -ne 0) { throw "Expected zero failed checks, got $($result.failed)." }
  foreach ($id in @(
      "lead-archive-entries",
      "lead-archive-firmware-hash",
      "lead-archive-file-index",
      "archive-expected-source-match",
      "strict-soak-summary",
      "strict-soak-firmware-match",
      "strict-soak-source-match",
      "strict-soak-formal-check"
    )) {
    $check = @($result.checks | Where-Object { $_.id -eq $id })[0]
    if ($null -eq $check -or $check.status -ne "pass") { throw "Expected $id to pass." }
  }

  $badHashArchive = Join-Path $tempRoot "bad-hash.zip"
  [void](New-TestArchive -Path $badHashArchive -BadHash)
  & $Checker `
    -LeadArchivePath $badHashArchive `
    -CandidateManifestPath $candidate `
    -SoakSummaryPath $summary `
    -FormalCheckPath $formal `
    -StatusDocPath $statusDoc `
    -RunbookPath $runbook `
    -ReportDir (Join-Path $tempRoot "bad-hash-report") `
    -SkipLive `
    -Json | Out-Null
  if ($LASTEXITCODE -eq 0) { throw "Expected a manifest/firmware archive hash mismatch to fail." }

  $missingSourceArchive = Join-Path $tempRoot "missing-source.zip"
  [void](New-TestArchive -Path $missingSourceArchive -MissingSource)
  & $Checker `
    -LeadArchivePath $missingSourceArchive `
    -CandidateManifestPath $candidate `
    -SoakSummaryPath $summary `
    -FormalCheckPath $formal `
    -StatusDocPath $statusDoc `
    -RunbookPath $runbook `
    -ReportDir (Join-Path $tempRoot "missing-source-report") `
    -SkipLive `
    -Json | Out-Null
  if ($LASTEXITCODE -eq 0) { throw "Expected a missing source snapshot to fail." }

  Write-Host "Current-lead reproducibility v2 contract verified."
} finally {
  if (Test-Path -LiteralPath $tempRoot) { Remove-Item -LiteralPath $tempRoot -Recurse -Force }
}
