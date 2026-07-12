$ErrorActionPreference = "Stop"

$RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
$Archiver = Join-Path $RepoRoot "tools\archive_current_lead.ps1"
$Checker = Join-Path $RepoRoot "tools\check_current_lead_reproducibility.ps1"
$id = [guid]::NewGuid().ToString("N")
$fixtureRoot = Join-Path ([System.IO.Path]::GetTempPath()) "stackchan-current-lead-contract-$id"
$outputRelative = "output\private\current-lead\stackchan-current-lead-contract-$id"
$outputAbsolute = Join-Path $RepoRoot $outputRelative
$sourceCommit = (& git -C $RepoRoot rev-parse HEAD).Trim().ToLowerInvariant()

function Write-Json {
  param([string]$Path, $Value)
  New-Item -ItemType Directory -Force -Path (Split-Path $Path -Parent) | Out-Null
  $Value | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $Path -Encoding UTF8
}

function New-SoakEvidence {
  param([string]$Root, [int]$Duration, [string]$FirmwareSha256)
  New-Item -ItemType Directory -Force -Path $Root | Out-Null
  Write-Json (Join-Path $Root "summary.json") ([ordered]@{
      schema = "stackchan.full-system-soak-summary.v1"
      status = "pass"
      issues = @()
      durationSeconds = $Duration
      installedFirmwareSha256 = $FirmwareSha256
      sourceCommit = $sourceCommit
    })
  Write-Json (Join-Path $Root "formal-check.json") ([ordered]@{
      schema = "stackchan.full-system-soak-evidence-check.v1"
      status = "full-system-soak-ready"
      passed = 70
      failed = 0
      pending = 0
    })
}

try {
  New-Item -ItemType Directory -Force -Path $fixtureRoot | Out-Null
  $candidateRoot = Join-Path $fixtureRoot "candidate-root"
  $candidateDir = Join-Path $candidateRoot "candidate"
  New-Item -ItemType Directory -Force -Path $candidateDir | Out-Null
  foreach ($name in @("firmware.elf", "firmware.map", "bootloader.bin", "partitions.bin")) {
    [System.IO.File]::WriteAllBytes((Join-Path $candidateDir $name), [byte[]](1, 2, 3, 4))
  }
  $firmwarePath = Join-Path $candidateDir "firmware.bin"
  [System.IO.File]::WriteAllBytes($firmwarePath, [byte[]](0..255))
  $firmwareSha256 = (Get-FileHash -LiteralPath $firmwarePath -Algorithm SHA256).Hash
  Write-Json (Join-Path $candidateRoot "manifest.json") ([ordered]@{
      schema = "stackchan.private-conversation-soak-hardening-candidate.v1"
      firmware_sha256 = $firmwareSha256
      source_commit = $sourceCommit
    })
  New-Item -ItemType Directory -Force -Path (Join-Path $candidateRoot "ota-evidence") | Out-Null
  Write-Json (Join-Path $candidateRoot "ota-evidence\manifest.json") ([ordered]@{ status = "confirmed" })

  $noMotion = Join-Path $fixtureRoot "no-motion"
  $short = Join-Path $fixtureRoot "short-actuator"
  $hour = Join-Path $fixtureRoot "hour"
  $long = Join-Path $fixtureRoot "long-soak"
  New-SoakEvidence $noMotion 120 $firmwareSha256
  New-SoakEvidence $short 300 $firmwareSha256
  New-SoakEvidence $hour 3600 $firmwareSha256
  New-SoakEvidence $long 28800 $firmwareSha256
  $voice = Join-Path $fixtureRoot "voice-proof"
  Write-Json (Join-Path $voice "voice-proof.json") ([ordered]@{
      schema = "stackchan.production-voice-proof.v1"
      status = "pass"
      firmwareSha256 = $firmwareSha256
      sourceCommit = $sourceCommit
      route = "local_clock"
      firstAudioMs = 1200
      complete = $true
      truncated = $false
    })

  $archiveOutput = & $Archiver `
    -CandidateRoot $candidateRoot `
    -NoMotionEvidenceRoot $noMotion `
    -ShortActuatorEvidenceRoot $short `
    -HourEvidenceRoot $hour `
    -VoiceProofRoot $voice `
    -LongSoakEvidenceRoot $long `
    -OutputRoot $outputRelative `
    -Json
  if ($LASTEXITCODE -ne 0) { throw "Archive helper failed." }
  $archiveResult = $archiveOutput | ConvertFrom-Json
  if ($archiveResult.status -ne "verified") { throw "Archive result was not verified." }
  if ($archiveResult.firmwareSha256 -ne $firmwareSha256) { throw "Archive result firmware hash mismatch." }
  if ($archiveResult.sourceCommit -ne $sourceCommit) { throw "Archive result source commit mismatch." }
  if (-not (Test-Path -LiteralPath $archiveResult.archive -PathType Leaf)) { throw "Archive ZIP was not created." }

  $statusDoc = Join-Path $fixtureRoot "FIRST_DEPLOY_STATUS.md"
  $runbook = Join-Path $fixtureRoot "ARRIVAL_DAY_RUNBOOK.md"
  $markers = "$sourceCommit`n$firmwareSha256`n$(Split-Path $archiveResult.archive -Leaf)`n"
  [System.IO.File]::WriteAllText($statusDoc, $markers)
  [System.IO.File]::WriteAllText($runbook, $markers)
  $checkerOutput = & $Checker `
    -LeadArchivePath $archiveResult.archive `
    -CandidateManifestPath (Join-Path $candidateRoot "manifest.json") `
    -SoakSummaryPath (Join-Path $long "summary.json") `
    -FormalCheckPath (Join-Path $long "formal-check.json") `
    -StatusDocPath $statusDoc `
    -RunbookPath $runbook `
    -ReportDir (Join-Path $fixtureRoot "repro-report") `
    -MinSoakDurationSeconds 28800 `
    -SkipLive `
    -Json
  if ($LASTEXITCODE -ne 0) { throw "Archive did not pass the reproducibility checker." }
  $checkerResult = $checkerOutput | ConvertFrom-Json
  if ($checkerResult.failed -ne 0) { throw "Archive checker reported failed checks." }

  Write-Host "Current-lead archive contract verified."
} finally {
  $allowedFixture = [System.IO.Path]::GetFullPath((Join-Path $RepoRoot "output\private"))
  if (Test-Path -LiteralPath $fixtureRoot) {
    $resolvedFixture = [System.IO.Path]::GetFullPath($fixtureRoot)
    $allowedTemp = [System.IO.Path]::GetFullPath([System.IO.Path]::GetTempPath())
    if (-not $resolvedFixture.StartsWith($allowedTemp, [System.StringComparison]::OrdinalIgnoreCase)) {
      throw "Refusing to clean contract fixture outside the system temp directory: $resolvedFixture"
    }
    Remove-Item -LiteralPath $resolvedFixture -Recurse -Force
  }
  foreach ($path in @($outputAbsolute, "$outputAbsolute.zip", "$outputAbsolute-archive-result.json")) {
    if (Test-Path -LiteralPath $path) {
      $resolved = [System.IO.Path]::GetFullPath($path)
      if (-not $resolved.StartsWith($allowedFixture + [System.IO.Path]::DirectorySeparatorChar, [System.StringComparison]::OrdinalIgnoreCase)) {
        throw "Refusing to clean contract path outside output\private: $resolved"
      }
      Remove-Item -LiteralPath $resolved -Recurse -Force
    }
  }
}
