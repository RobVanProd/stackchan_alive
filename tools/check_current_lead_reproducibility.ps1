param(
  [string]$LeadArchivePath = "",
  [string]$CandidateManifestPath = "",
  [string]$SoakProgressPath = "",
  [string]$SoakSummaryPath = "",
  [string]$FormalCheckPath = "",
  [string]$ExpectedFirmwareSha256 = "",
  [string]$ExpectedFirmwareSourceCommit = "",
  [string]$StatusDocPath = "docs\FIRST_DEPLOY_STATUS.md",
  [string]$RunbookPath = "docs\ARRIVAL_DAY_RUNBOOK.md",
  [string]$ReportDir = "output\current-lead\current-lead-reproducibility-latest",
  [string]$RvcWorkerUrl = "http://127.0.0.1:5059",
  [string]$DeviceHost = "192.168.1.238",
  [int]$DevicePort = 8789,
  [int]$MinSoakDurationSeconds = 28800,
  [switch]$SkipLive,
  [switch]$RequireReady,
  [switch]$Json
)

$ErrorActionPreference = "Stop"

$RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
Set-Location $RepoRoot

$checks = @()

function Add-Check {
  param(
    [string]$Id,
    [ValidateSet("pass", "fail", "pending")]
    [string]$Status,
    [string]$Detail
  )
  $script:checks += [ordered]@{ id = $Id; status = $Status; detail = $Detail }
}

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

function Get-IntValue {
  param($Object, [string]$Name, [int64]$Default = 0)
  return [int64](Get-PropertyValue $Object $Name $Default)
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

function Find-LatestLeadArchive {
  $roots = @("output\private\current-lead", "output\current-lead")
  $candidates = @()
  foreach ($root in $roots) {
    if (Test-Path -LiteralPath $root -PathType Container) {
      $candidates += @(Get-ChildItem -LiteralPath $root -Filter "stackchan-current-lead-*.zip" -File -ErrorAction SilentlyContinue)
    }
  }
  $latest = $candidates | Sort-Object LastWriteTime -Descending | Select-Object -First 1
  if ($null -eq $latest) { return "" }
  return $latest.FullName
}

function Find-LatestSoakEvidence {
  $progress = @(Get-ChildItem -Path "output\pc-brain" -Recurse -Filter "progress.json" -File -ErrorAction SilentlyContinue |
      Sort-Object LastWriteTime -Descending)
  foreach ($item in $progress) {
    try {
      $value = Read-JsonFile $item.FullName
      if ([string]$value.schema -eq "stackchan.full-system-soak-progress.v1") {
        return $item.FullName
      }
    } catch {
      continue
    }
  }
  return ""
}

function Get-ZipEntryNames {
  param([System.IO.Compression.ZipArchive]$Archive)
  return @($Archive.Entries | ForEach-Object { $_.FullName.Replace("\", "/") })
}

function Get-ZipEntry {
  param([System.IO.Compression.ZipArchive]$Archive, [string]$Name)
  $normalized = $Name.Replace("\", "/")
  return @($Archive.Entries | Where-Object { $_.FullName.Replace("\", "/") -eq $normalized })[0]
}

function Read-ZipJson {
  param([System.IO.Compression.ZipArchive]$Archive, [string]$Name)
  $entry = Get-ZipEntry $Archive $Name
  if ($null -eq $entry) { throw "Missing archive JSON entry: $Name" }
  $stream = $entry.Open()
  $reader = New-Object System.IO.StreamReader($stream, [System.Text.Encoding]::UTF8, $true)
  try {
    return $reader.ReadToEnd() | ConvertFrom-Json
  } finally {
    $reader.Dispose()
    $stream.Dispose()
  }
}

function Get-ZipEntrySha256 {
  param([System.IO.Compression.ZipArchive]$Archive, [string]$Name)
  $entry = Get-ZipEntry $Archive $Name
  if ($null -eq $entry) { return "" }
  $stream = $entry.Open()
  $sha = [System.Security.Cryptography.SHA256]::Create()
  try {
    return ([System.BitConverter]::ToString($sha.ComputeHash($stream))).Replace("-", "")
  } finally {
    $sha.Dispose()
    $stream.Dispose()
  }
}

function Get-ArchiveManifestValue {
  param($Manifest, [string]$CamelName, [string]$SnakeName)
  $value = Get-PropertyValue $Manifest $CamelName ""
  if ([string]::IsNullOrWhiteSpace([string]$value)) {
    $value = Get-PropertyValue $Manifest $SnakeName ""
  }
  return [string]$value
}

$candidateManifest = $null
if (-not [string]::IsNullOrWhiteSpace($CandidateManifestPath)) {
  if (Test-Path -LiteralPath $CandidateManifestPath -PathType Leaf) {
    try {
      $candidateManifest = Read-JsonFile $CandidateManifestPath
      Add-Check "candidate-manifest" "pass" $CandidateManifestPath
    } catch {
      Add-Check "candidate-manifest" "fail" $_.Exception.Message
    }
  } else {
    Add-Check "candidate-manifest" "fail" "Missing candidate manifest: $CandidateManifestPath"
  }
}

if ([string]::IsNullOrWhiteSpace($LeadArchivePath)) {
  $LeadArchivePath = Find-LatestLeadArchive
}

$archiveManifest = $null
$archiveFirmwareSha256 = ""
$archiveSourceCommit = ""
if ([string]::IsNullOrWhiteSpace($LeadArchivePath) -or -not (Test-Path -LiteralPath $LeadArchivePath -PathType Leaf)) {
  Add-Check "lead-archive" "fail" "Missing current-lead archive: $LeadArchivePath"
} else {
  Add-Type -AssemblyName System.IO.Compression.FileSystem
  $archiveItem = Get-Item -LiteralPath $LeadArchivePath
  Add-Check "lead-archive" "pass" "$LeadArchivePath size=$($archiveItem.Length)"
  $archive = [System.IO.Compression.ZipFile]::OpenRead((Resolve-Path $LeadArchivePath))
  try {
    $entries = Get-ZipEntryNames $archive
    $requiredEntries = @(
      "manifest.json",
      "files.json",
      "candidate/firmware.bin",
      "source/source.zip",
      "evidence/long-soak/summary.json",
      "evidence/long-soak/formal-check.json"
    )
    $missing = @($requiredEntries | Where-Object { $entries -notcontains $_ })
    Add-Check "lead-archive-entries" ($(if ($missing.Count -eq 0) { "pass" } else { "fail" })) `
      $(if ($missing.Count -eq 0) { "required entries present" } else { "missing: $($missing -join ', ')" })

    $restricted = @($entries | Where-Object {
      $_ -match '(?i)(^|/)[^/]+\.(pth|index|onnx)$' -or
      $_ -match '(?i)(ota[-_ ]?token|pairing[-_ ]?(code|secret)|wifi[-_ ]?(password|credentials)).*\.(txt|json|ya?ml|env)$' -or
      $_ -match '(?i)weightsgg|weights\.gg'
    })
    Add-Check "lead-archive-sensitive-payload" ($(if ($restricted.Count -eq 0) { "pass" } else { "fail" })) `
      $(if ($restricted.Count -eq 0) { "no plaintext secret or private voice-model payload" } else { "restricted: $($restricted -join ', ')" })

    $archiveManifest = Read-ZipJson $archive "manifest.json"
    $archiveSchemaOk = [string]$archiveManifest.schema -eq "stackchan.current-lead-archive.v1"
    Add-Check "lead-archive-schema" ($(if ($archiveSchemaOk) { "pass" } else { "fail" })) "schema=$($archiveManifest.schema)"
    $archiveFirmwareSha256 = Normalize-Sha256 (Get-ArchiveManifestValue $archiveManifest "firmwareSha256" "firmware_sha256")
    $archiveSourceCommit = Normalize-Commit (Get-ArchiveManifestValue $archiveManifest "sourceCommit" "source_commit")
    $firmwareEntrySha256 = Get-ZipEntrySha256 $archive "candidate/firmware.bin"
    $archiveHashOk = $archiveFirmwareSha256 -ne "" -and $archiveFirmwareSha256 -eq $firmwareEntrySha256
    Add-Check "lead-archive-firmware-hash" ($(if ($archiveHashOk) { "pass" } else { "fail" })) `
      "manifest=$archiveFirmwareSha256 entry=$firmwareEntrySha256"

    $fileIndex = Read-ZipJson $archive "files.json"
    $indexedFirmware = @($fileIndex | Where-Object { ([string]$_.path).Replace("\", "/") -eq "candidate/firmware.bin" })[0]
    $indexHash = if ($null -ne $indexedFirmware) { Normalize-Sha256 ([string]$indexedFirmware.sha256) } else { "" }
    $indexOk = $indexHash -ne "" -and $indexHash -eq $firmwareEntrySha256
    Add-Check "lead-archive-file-index" ($(if ($indexOk) { "pass" } else { "fail" })) `
      "candidate/firmware.bin index=$indexHash"
  } catch {
    Add-Check "lead-archive-readable" "fail" $_.Exception.Message
  } finally {
    $archive.Dispose()
  }
}

$candidateFirmwareSha256 = ""
$candidateSourceCommit = ""
if ($null -ne $candidateManifest) {
  $candidateFirmwareSha256 = Normalize-Sha256 (Get-ArchiveManifestValue $candidateManifest "firmwareSha256" "firmware_sha256")
  $candidateSourceCommit = Normalize-Commit (Get-ArchiveManifestValue $candidateManifest "sourceCommit" "source_commit")
}
if ([string]::IsNullOrWhiteSpace($ExpectedFirmwareSha256)) {
  $ExpectedFirmwareSha256 = if ($candidateFirmwareSha256) { $candidateFirmwareSha256 } else { $archiveFirmwareSha256 }
}
if ([string]::IsNullOrWhiteSpace($ExpectedFirmwareSourceCommit)) {
  $ExpectedFirmwareSourceCommit = if ($candidateSourceCommit) { $candidateSourceCommit } else { $archiveSourceCommit }
}
$ExpectedFirmwareSha256 = Normalize-Sha256 $ExpectedFirmwareSha256
$ExpectedFirmwareSourceCommit = Normalize-Commit $ExpectedFirmwareSourceCommit
Add-Check "expected-firmware-sha256" ($(if ($ExpectedFirmwareSha256) { "pass" } else { "fail" })) $ExpectedFirmwareSha256
Add-Check "expected-source-commit" ($(if ($ExpectedFirmwareSourceCommit) { "pass" } else { "fail" })) $ExpectedFirmwareSourceCommit

if ($archiveFirmwareSha256 -and $ExpectedFirmwareSha256) {
  Add-Check "archive-expected-firmware-match" ($(if ($archiveFirmwareSha256 -eq $ExpectedFirmwareSha256) { "pass" } else { "fail" })) `
    "archive=$archiveFirmwareSha256 expected=$ExpectedFirmwareSha256"
}
if ($archiveSourceCommit -and $ExpectedFirmwareSourceCommit) {
  Add-Check "archive-expected-source-match" ($(if ($archiveSourceCommit -eq $ExpectedFirmwareSourceCommit) { "pass" } else { "fail" })) `
    "archive=$archiveSourceCommit expected=$ExpectedFirmwareSourceCommit"
}
if ($candidateFirmwareSha256) {
  Add-Check "candidate-expected-firmware-match" ($(if ($candidateFirmwareSha256 -eq $ExpectedFirmwareSha256) { "pass" } else { "fail" })) `
    "candidate=$candidateFirmwareSha256 expected=$ExpectedFirmwareSha256"
}
if ($candidateSourceCommit) {
  Add-Check "candidate-expected-source-match" ($(if ($candidateSourceCommit -eq $ExpectedFirmwareSourceCommit) { "pass" } else { "fail" })) `
    "candidate=$candidateSourceCommit expected=$ExpectedFirmwareSourceCommit"
}

$leadArchiveLeaf = if ([string]::IsNullOrWhiteSpace($LeadArchivePath)) {
  ""
} else {
  Split-Path $LeadArchivePath -Leaf
}
foreach ($doc in @(
    @{ id = "status-doc"; path = $StatusDocPath },
    @{ id = "runbook-doc"; path = $RunbookPath }
  )) {
  if (-not (Test-Path -LiteralPath $doc.path -PathType Leaf)) {
    Add-Check $doc.id "fail" "Missing documentation: $($doc.path)"
    continue
  }
  $text = Get-Content -LiteralPath $doc.path -Raw
  Add-Check $doc.id "pass" $doc.path
  foreach ($marker in @($ExpectedFirmwareSourceCommit, $ExpectedFirmwareSha256, $leadArchiveLeaf)) {
    if ([string]::IsNullOrWhiteSpace($marker)) { continue }
    $markerId = "$($doc.id)-marker-$($checks.Count)"
    Add-Check $markerId ($(if ($text -match [regex]::Escape($marker)) { "pass" } else { "fail" })) $marker
  }
}

if ([string]::IsNullOrWhiteSpace($SoakProgressPath) -and [string]::IsNullOrWhiteSpace($SoakSummaryPath)) {
  $SoakProgressPath = Find-LatestSoakEvidence
}
if ([string]::IsNullOrWhiteSpace($SoakSummaryPath) -and -not [string]::IsNullOrWhiteSpace($SoakProgressPath)) {
  $SoakSummaryPath = Join-Path (Split-Path $SoakProgressPath -Parent) "summary.json"
}
if ([string]::IsNullOrWhiteSpace($FormalCheckPath) -and -not [string]::IsNullOrWhiteSpace($SoakSummaryPath)) {
  $FormalCheckPath = Join-Path (Split-Path $SoakSummaryPath -Parent) "formal-check.json"
}

if (-not [string]::IsNullOrWhiteSpace($SoakSummaryPath) -and (Test-Path -LiteralPath $SoakSummaryPath -PathType Leaf)) {
  try {
    $soak = Read-JsonFile $SoakSummaryPath
    $soakStatus = [string](Get-PropertyValue $soak "status" "")
    $soakIssues = @((Get-PropertyValue $soak "issues" @()))
    $soakDuration = Get-IntValue $soak "durationSeconds" 0
    $soakFirmware = Normalize-Sha256 ([string](Get-PropertyValue $soak "installedFirmwareSha256" ""))
    $soakSource = Normalize-Commit ([string](Get-PropertyValue $soak "sourceCommit" ""))
    $soakReady = [string]$soak.schema -eq "stackchan.full-system-soak-summary.v1" -and
      $soakStatus -eq "pass" -and $soakIssues.Count -eq 0 -and $soakDuration -ge $MinSoakDurationSeconds
    Add-Check "strict-soak-summary" ($(if ($soakReady) { "pass" } else { "fail" })) `
      "status=$soakStatus duration=$soakDuration issues=$($soakIssues -join ', ') path=$SoakSummaryPath"
    Add-Check "strict-soak-firmware-match" ($(if ($soakFirmware -and $soakFirmware -eq $ExpectedFirmwareSha256) { "pass" } else { "fail" })) `
      "summary=$soakFirmware expected=$ExpectedFirmwareSha256"
    Add-Check "strict-soak-source-match" ($(if ($soakSource -and $soakSource -eq $ExpectedFirmwareSourceCommit) { "pass" } else { "fail" })) `
      "summary=$soakSource expected=$ExpectedFirmwareSourceCommit"
  } catch {
    Add-Check "strict-soak-summary" "fail" $_.Exception.Message
  }
} elseif (-not [string]::IsNullOrWhiteSpace($SoakProgressPath) -and (Test-Path -LiteralPath $SoakProgressPath -PathType Leaf)) {
  try {
    $progress = Read-JsonFile $SoakProgressPath
    $soakLeaf = Split-Path (Split-Path $SoakProgressPath -Parent) -Leaf
    $activeProcessCount = @(Get-CimInstance Win32_Process | Where-Object {
        $_.CommandLine -and $_.CommandLine -match "run_full_system_soak_http_motion.ps1" -and
        $_.CommandLine -match [regex]::Escape($soakLeaf)
      }).Count
    if ($activeProcessCount -gt 0) {
      Add-Check "strict-soak-progress" "pass" `
        "running=$SoakProgressPath records=$($progress.records) failedPolls=$($progress.failedPolls) processCount=$activeProcessCount"
      Add-Check "strict-soak-summary" "pending" "Summary pending: $SoakSummaryPath"
    } else {
      Add-Check "strict-soak-progress" "fail" "Runner exited without summary: $SoakProgressPath"
    }
  } catch {
    Add-Check "strict-soak-progress" "fail" $_.Exception.Message
  }
} else {
  Add-Check "strict-soak-summary" "pending" "No soak progress or summary was provided."
}

if (-not [string]::IsNullOrWhiteSpace($FormalCheckPath) -and (Test-Path -LiteralPath $FormalCheckPath -PathType Leaf)) {
  try {
    $formal = Read-JsonFile $FormalCheckPath
    $formalReady = [string]$formal.schema -eq "stackchan.full-system-soak-evidence-check.v1" -and
      [string]$formal.status -eq "full-system-soak-ready" -and
      (Get-IntValue $formal "failed" -1) -eq 0 -and (Get-IntValue $formal "pending" -1) -eq 0
    Add-Check "strict-soak-formal-check" ($(if ($formalReady) { "pass" } else { "fail" })) `
      "status=$($formal.status) passed=$($formal.passed) failed=$($formal.failed) pending=$($formal.pending) path=$FormalCheckPath"
  } catch {
    Add-Check "strict-soak-formal-check" "fail" $_.Exception.Message
  }
} elseif (Test-Path -LiteralPath $SoakSummaryPath -PathType Leaf) {
  Add-Check "strict-soak-formal-check" "fail" "Missing formal checker result: $FormalCheckPath"
} else {
  Add-Check "strict-soak-formal-check" "pending" "Formal checker waits for the terminal summary."
}

if ($SkipLive) {
  Add-Check "rvc-worker-live" "pending" "Skipped by -SkipLive."
  Add-Check "bridge-socket-live" "pending" "Skipped by -SkipLive."
  Add-Check "robot-debug-live" "pending" "Skipped by -SkipLive."
} else {
  try {
    $health = Invoke-RestMethod -Uri "$($RvcWorkerUrl.TrimEnd('/'))/health" -TimeoutSec 5
    $rvcOk = [bool]$health.ready -and -not [string]::IsNullOrWhiteSpace([string]$health.device) -and [string]$health.method -eq "pm"
    Add-Check "rvc-worker-live" ($(if ($rvcOk) { "pass" } else { "fail" })) `
      "ready=$($health.ready) device=$($health.device) method=$($health.method)"
  } catch {
    Add-Check "rvc-worker-live" "fail" "$RvcWorkerUrl/health :: $($_.Exception.Message)"
  }

  $socket = @(Get-NetTCPConnection -LocalPort 8765 -State Established -ErrorAction SilentlyContinue |
      Where-Object { $_.RemoteAddress -eq $DeviceHost })
  Add-Check "bridge-socket-live" ($(if ($socket.Count -gt 0) { "pass" } else { "fail" })) `
    "established=$($socket.Count) remote=$DeviceHost localPort=8765"

  try {
    $debug = Invoke-RestMethod -Uri "http://$DeviceHost`:$DevicePort/debug" -TimeoutSec 5
    $liveFirmware = Normalize-Sha256 ([string]$debug.ota_expected_sha256)
    $liveReady = [string]$debug.network_state -eq "connected" -and [string]$debug.bridge_state -eq "ready" -and
      [bool]$debug.ota_current_app_confirmed -and $liveFirmware -eq $ExpectedFirmwareSha256
    Add-Check "robot-debug-live" ($(if ($liveReady) { "pass" } else { "fail" })) `
      "network=$($debug.network_state) bridge=$($debug.bridge_state) confirmed=$($debug.ota_current_app_confirmed) firmware=$liveFirmware"
  } catch {
    Add-Check "robot-debug-live" "fail" $_.Exception.Message
  }
}

$failed = @($checks | Where-Object { $_.status -eq "fail" })
$pending = @($checks | Where-Object { $_.status -eq "pending" })
$status = if ($failed.Count -gt 0) {
  "current-lead-reproducibility-failed"
} elseif ($pending.Count -gt 0) {
  "current-lead-reproducible-pending"
} else {
  "current-lead-reproducible-ready"
}

New-Item -ItemType Directory -Force -Path $ReportDir | Out-Null
$resolvedReportDir = (Resolve-Path $ReportDir).Path
$jsonPath = Join-Path $resolvedReportDir "CURRENT_LEAD_REPRODUCIBILITY.json"
$markdownPath = Join-Path $resolvedReportDir "CURRENT_LEAD_REPRODUCIBILITY.md"
$result = [ordered]@{
  schema = "stackchan.current-lead-reproducibility.v2"
  status = $status
  generatedAt = (Get-Date).ToString("o")
  leadArchivePath = $LeadArchivePath
  candidateManifestPath = $CandidateManifestPath
  expectedFirmwareSha256 = $ExpectedFirmwareSha256
  expectedFirmwareSourceCommit = $ExpectedFirmwareSourceCommit
  soakProgressPath = $SoakProgressPath
  soakSummaryPath = $SoakSummaryPath
  formalCheckPath = $FormalCheckPath
  minSoakDurationSeconds = $MinSoakDurationSeconds
  rvcWorkerUrl = $RvcWorkerUrl
  deviceHost = $DeviceHost
  passed = @($checks | Where-Object { $_.status -eq "pass" }).Count
  failed = $failed.Count
  pending = $pending.Count
  checks = $checks
}
$result | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $jsonPath -Encoding UTF8

$lines = @(
  "# Stackchan Current Lead Reproducibility",
  "",
  "- Schema: ``$($result.schema)``",
  "- Status: ``$($result.status)``",
  "- Lead archive: ``$LeadArchivePath``",
  "- Firmware SHA256: ``$ExpectedFirmwareSha256``",
  "- Firmware source commit: ``$ExpectedFirmwareSourceCommit``",
  "- Soak summary: ``$SoakSummaryPath``",
  "- Passed: ``$($result.passed)``",
  "- Failed: ``$($result.failed)``",
  "- Pending: ``$($result.pending)``",
  "",
  "## Checks",
  ""
)
foreach ($check in $checks) {
  $lines += "- ``$($check.status)`` ``$($check.id)``: $($check.detail)"
}
$lines += ""
$lines += "## Next"
$lines += ""
if ($status -eq "current-lead-reproducible-ready") {
  $lines += "- Exact archive, source, firmware, formal soak evidence, docs, and live runtime agree."
} elseif ($failed.Count -gt 0) {
  $lines += "- Fix failed exact-lead checks before promotion."
} else {
  $lines += "- Finish the pending terminal soak or intentionally rerun live checks."
}
$lines | Set-Content -LiteralPath $markdownPath -Encoding UTF8

if ($Json) {
  $result | ConvertTo-Json -Depth 8
} else {
  Write-Host "Current lead reproducibility: $status"
  Write-Host "Report: $markdownPath"
}

if ($failed.Count -gt 0 -or ($RequireReady -and $status -ne "current-lead-reproducible-ready")) {
  exit 1
}
exit 0
