param(
  [string]$WarmArchivePath = "",
  [string]$CandidateArchivePath = "",
  [string]$ReportDir = "output\current-lead\current-lead-reproducibility-latest",
  [string]$RvcWorkerUrl = "http://127.0.0.1:5059",
  [string]$DeviceHost = "192.168.1.238",
  [int]$DevicePort = 8789,
  [string]$PassiveWatchProgressPath = "",
  [string]$SoakSummaryPath = "",
  [int]$MinSoakDurationSeconds = 28800,
  [switch]$SkipLive,
  [switch]$RequireReady,
  [switch]$Json
)

$ErrorActionPreference = "Stop"

$RepoRoot = Resolve-Path (Join-Path $PSScriptRoot "..")
Set-Location $RepoRoot

$checks = @()

function Add-Check {
  param(
    [string]$Id,
    [ValidateSet("pass", "fail", "pending")]
    [string]$Status,
    [string]$Detail
  )
  $script:checks += [ordered]@{
    id = $Id
    status = $Status
    detail = $Detail
  }
}

function Find-LatestArchive {
  param([string]$Pattern)
  $item = Get-ChildItem -Path "output\current-lead" -Filter $Pattern -File -ErrorAction SilentlyContinue |
    Sort-Object LastWriteTime -Descending |
    Select-Object -First 1
  if ($null -eq $item) { return "" }
  return $item.FullName
}

function Get-ZipEntryNames {
  param([string]$Path)
  Add-Type -AssemblyName System.IO.Compression.FileSystem
  $archive = [System.IO.Compression.ZipFile]::OpenRead((Resolve-Path $Path))
  try {
    return @($archive.Entries | ForEach-Object { $_.FullName.Replace("\", "/") })
  } finally {
    $archive.Dispose()
  }
}

function Test-ZipEntries {
  param(
    [string]$CheckPrefix,
    [string]$Path,
    [string[]]$RequiredEntries
  )
  if ([string]::IsNullOrWhiteSpace($Path) -or -not (Test-Path -LiteralPath $Path -PathType Leaf)) {
    Add-Check "$CheckPrefix-archive" "fail" "Missing archive: $Path"
    return
  }
  $item = Get-Item -LiteralPath $Path
  Add-Check "$CheckPrefix-archive" "pass" "$Path size=$($item.Length)"
  try {
    $entries = Get-ZipEntryNames -Path $Path
    $missing = @($RequiredEntries | Where-Object { $entries -notcontains $_ })
    Add-Check "$CheckPrefix-entries" ($(if ($missing.Count -eq 0) { "pass" } else { "fail" })) "$(if ($missing.Count -eq 0) { 'required entries present' } else { 'missing: ' + ($missing -join ', ') })"
    $restricted = @($entries | Where-Object {
      $_ -match '(?i)(^|/)[^/]+\.(pth|index|onnx)$' -or
      $_ -match '(?i)weightsgg|weights\.gg' -or
      $_ -match '(?i)(^|/)[^/]*rvc[^/]*\.(wav|mp3|html)$'
    })
    Add-Check "$CheckPrefix-voice-payload" ($(if ($restricted.Count -eq 0) { "pass" } else { "fail" })) "$(if ($restricted.Count -eq 0) { 'no restricted model or converted RVC payload' } else { 'restricted: ' + ($restricted -join ', ') })"
  } catch {
    Add-Check "$CheckPrefix-entries" "fail" $_.Exception.Message
  }
}

function Read-JsonFile {
  param([string]$Path)
  return Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json
}

function Get-IntValue {
  param($Object, [string]$Name, [int64]$Default = 0)
  if ($null -eq $Object) { return $Default }
  $property = $Object.PSObject.Properties[$Name]
  if ($null -eq $property -or $null -eq $property.Value) { return $Default }
  return [int64]$property.Value
}

if ([string]::IsNullOrWhiteSpace($WarmArchivePath)) {
  $WarmArchivePath = Find-LatestArchive -Pattern "stackchan-full-online-warm-rocm-lead-*.zip"
}
if ([string]::IsNullOrWhiteSpace($CandidateArchivePath)) {
  $CandidateArchivePath = Find-LatestArchive -Pattern "stackchan-motion-timing-fix-candidate-*.zip"
}

$warmName = if (-not [string]::IsNullOrWhiteSpace($WarmArchivePath)) { Split-Path $WarmArchivePath -Leaf } else { "" }
$candidateName = if (-not [string]::IsNullOrWhiteSpace($CandidateArchivePath)) { Split-Path $CandidateArchivePath -Leaf } else { "" }

$warmRequired = @(
  "bridge/lan_service.py",
  "bridge/lan_smoke.py",
  "bridge/rvc_tts_client.py",
  "bridge/rvc_worker_service.py",
  "bridge/test_lan_service.py",
  "bridge/test_lan_smoke.py",
  "docs/BRIDGE_PROTOCOL.md",
  "docs/FIRST_DEPLOY_STATUS.md",
  "docs/ARRIVAL_DAY_RUNBOOK.md",
  "firmware/firmware.bin",
  "tools/start_rvc_worker.ps1",
  "tools/start_warm_rocm_full_system_soak.ps1",
  "tools/start_motion_timing_candidate_recovery_soak.ps1",
  "tools/finalize_interrupted_full_system_soak.ps1",
  "tools/finalize_interrupted_full_system_soak.cmd",
  "tools/check_full_system_soak_evidence.ps1",
  "tools/test_motion_timing_candidate_recovery_soak_contract.ps1",
  "logs/test-motion-timing-candidate-recovery-soak-contract.log",
  "CURRENT_LEAD.md",
  "CURRENT_LEAD_MANIFEST.json"
)
$candidateRequired = @(
  "docs/FIRST_DEPLOY_STATUS.md",
  "docs/ARRIVAL_DAY_RUNBOOK.md",
  "firmware/firmware.bin",
  "src/motion/ActuationEngine.cpp",
  "src/motion/ActuationEngine.hpp",
  "src/main.cpp",
  "tools/start_warm_rocm_full_system_soak.ps1",
  "tools/start_motion_timing_candidate_recovery_soak.ps1",
  "tools/finalize_interrupted_full_system_soak.ps1",
  "tools/finalize_interrupted_full_system_soak.cmd",
  "tools/test_motion_timing_candidate_recovery_soak_contract.ps1",
  "logs/test-motion-timing-candidate-recovery-soak-contract.log",
  "CANDIDATE_STATUS.md",
  "CANDIDATE_MANIFEST.json"
)

Test-ZipEntries -CheckPrefix "warm" -Path $WarmArchivePath -RequiredEntries $warmRequired
Test-ZipEntries -CheckPrefix "candidate" -Path $CandidateArchivePath -RequiredEntries $candidateRequired

$statusText = ""
if (Test-Path -LiteralPath "docs\FIRST_DEPLOY_STATUS.md" -PathType Leaf) {
  $statusText = Get-Content -LiteralPath "docs\FIRST_DEPLOY_STATUS.md" -Raw
  Add-Check "status-doc" "pass" "docs\FIRST_DEPLOY_STATUS.md"
  foreach ($marker in @($warmName, $candidateName, "start_motion_timing_candidate_recovery_soak.cmd", "start_warm_rocm_full_system_soak.ps1", "-OperatorPresent -BodyClear -ConfirmServoRisk")) {
    if ([string]::IsNullOrWhiteSpace($marker)) { continue }
    Add-Check "status-doc-marker-$($checks.Count)" ($(if ($statusText -match [regex]::Escape($marker)) { "pass" } else { "fail" })) $marker
  }
} else {
  Add-Check "status-doc" "fail" "Missing docs\FIRST_DEPLOY_STATUS.md"
}

if (Test-Path -LiteralPath "docs\ARRIVAL_DAY_RUNBOOK.md" -PathType Leaf) {
  $runbookText = Get-Content -LiteralPath "docs\ARRIVAL_DAY_RUNBOOK.md" -Raw
  Add-Check "runbook-doc" "pass" "docs\ARRIVAL_DAY_RUNBOOK.md"
  foreach ($marker in @($warmName, $candidateName, "start_motion_timing_candidate_recovery_soak.cmd", "-OperatorPresent -BodyClear -ConfirmServoRisk")) {
    if ([string]::IsNullOrWhiteSpace($marker)) { continue }
    Add-Check "runbook-doc-marker-$($checks.Count)" ($(if ($runbookText -match [regex]::Escape($marker)) { "pass" } else { "fail" })) $marker
  }
} else {
  Add-Check "runbook-doc" "fail" "Missing docs\ARRIVAL_DAY_RUNBOOK.md"
}

if ($SkipLive) {
  Add-Check "rvc-worker-live" "pending" "Skipped by -SkipLive."
  Add-Check "bridge-process-live" "pending" "Skipped by -SkipLive."
  Add-Check "robot-debug-live" "pending" "Skipped by -SkipLive."
} else {
  try {
    $health = Invoke-RestMethod -Uri "$RvcWorkerUrl/health" -TimeoutSec 5
    $rvcOk = [bool]$health.ready -and
      -not [string]::IsNullOrWhiteSpace([string]$health.device) -and
      [string]$health.method -eq "pm"
    Add-Check "rvc-worker-live" ($(if ($rvcOk) { "pass" } else { "fail" })) "ready=$($health.ready) device=$($health.device) method=$($health.method)"
  } catch {
    Add-Check "rvc-worker-live" "fail" "$RvcWorkerUrl/health :: $($_.Exception.Message)"
  }

  $bridge = @(Get-CimInstance Win32_Process | Where-Object {
      $_.Name -match '^python(?:w)?\.exe$' -and $_.CommandLine -and
      $_.CommandLine -match "lan_service.py" -and $_.CommandLine -match "8765"
    })
  Add-Check "bridge-process-live" ($(if ($bridge.Count -gt 0) { "pass" } else { "fail" })) "$(if ($bridge.Count -gt 0) { 'bridge process count=' + $bridge.Count } else { 'No Python lan_service.py process on port 8765.' })"

  try {
    $debug = Invoke-RestMethod -Uri "http://$DeviceHost`:$DevicePort/debug" -TimeoutSec 3
    Add-Check "robot-debug-live" "pass" "network=$($debug.network_state) bridge=$($debug.bridge_state)"
  } catch {
    Add-Check "robot-debug-live" "pending" "Robot debug not reachable yet: $($_.Exception.Message)"
  }
}

if ([string]::IsNullOrWhiteSpace($PassiveWatchProgressPath)) {
  foreach ($progressFile in @(Get-ChildItem -Path "output\pc-brain" -Recurse -Filter "progress.json" -File -ErrorAction SilentlyContinue |
      Sort-Object LastWriteTime -Descending)) {
    try {
      $progressCandidate = Read-JsonFile $progressFile.FullName
      $candidateRecords = Get-IntValue $progressCandidate "records" 0
      $candidateFailedPolls = Get-IntValue $progressCandidate "failedPolls" 0
      $candidateFailureRatio = if ($candidateRecords -gt 0) {
        [double]$candidateFailedPolls / [double]$candidateRecords
      } else { 1.0 }
      if ([string]$progressCandidate.schema -eq "stackchan.full-system-soak-progress.v1" -and
          (Get-IntValue $progressCandidate "motionRefreshes" -1) -eq 0 -and
          $candidateRecords -gt 0 -and $candidateFailureRatio -le 0.01) {
        $PassiveWatchProgressPath = $progressFile.FullName
        break
      }
    } catch {
      continue
    }
  }
}

if (-not [string]::IsNullOrWhiteSpace($PassiveWatchProgressPath) -and
    (Test-Path -LiteralPath $PassiveWatchProgressPath -PathType Leaf)) {
  try {
    $watch = Read-JsonFile $PassiveWatchProgressPath
    $motionRefreshes = Get-IntValue $watch "motionRefreshes" -1
    $watchRecords = Get-IntValue $watch "records" 0
    $watchFailedPolls = Get-IntValue $watch "failedPolls" 0
    $watchFailureRatio = if ($watchRecords -gt 0) {
      [double]$watchFailedPolls / [double]$watchRecords
    } else { 1.0 }
    $watchHealthy = $watchRecords -gt 0 -and $watchFailureRatio -le 0.01
    Add-Check "passive-watch-progress" ($(if ($watchHealthy) { "pass" } else { "fail" })) "$PassiveWatchProgressPath records=$watchRecords failedPolls=$watchFailedPolls failedPollRatio=$([Math]::Round($watchFailureRatio, 6))"
    Add-Check "passive-watch-no-motion" ($(if ($motionRefreshes -eq 0) { "pass" } else { "fail" })) "motionRefreshes=$motionRefreshes"
  } catch {
    Add-Check "passive-watch-progress" "fail" $_.Exception.Message
  }
} else {
  Add-Check "passive-watch-progress" "pending" "Passive watch progress not found: $PassiveWatchProgressPath"
}

$activeSoakProgressPath = ""
if ([string]::IsNullOrWhiteSpace($SoakSummaryPath)) {
  $candidateSummary = $null
  $passedSummaryCandidates = @()
  $summaryCandidates = Get-ChildItem -Path "output\pc-brain" -Recurse -Filter "summary.json" -File -ErrorAction SilentlyContinue |
    Sort-Object LastWriteTime -Descending
  foreach ($summaryFile in $summaryCandidates) {
    try {
      $summaryCandidate = Read-JsonFile $summaryFile.FullName
      if ([string]$summaryCandidate.schema -eq "stackchan.full-system-soak-summary.v1" -and
          [string]$summaryCandidate.status -eq "pass" -and @($summaryCandidate.issues).Count -eq 0) {
        $passedSummaryCandidates += [pscustomobject]@{
          item = $summaryFile
          durationSeconds = Get-IntValue $summaryCandidate "durationSeconds" 0
        }
      }
    } catch {
      continue
    }
  }
  $selectedSummaryCandidate = $passedSummaryCandidates |
      Sort-Object @{ Expression = "durationSeconds"; Descending = $true },
                  @{ Expression = { $_.item.LastWriteTime }; Descending = $true } |
      Select-Object -First 1
  if ($selectedSummaryCandidate) {
    $candidateSummary = $selectedSummaryCandidate.item
  }
  $candidateProgress = Get-ChildItem -Path "output\pc-brain" -Recurse -Filter "progress.json" -File -ErrorAction SilentlyContinue |
    Where-Object { $_.FullName -match "full-system-soak|warm-rocm" -and $_.FullName -notmatch "passive" } |
    Sort-Object LastWriteTime -Descending |
    Select-Object -First 1
  $candidateProgressSummaryPath = if ($candidateProgress) {
    Join-Path $candidateProgress.DirectoryName "summary.json"
  } else { "" }
  if ($candidateProgress -and -not (Test-Path -LiteralPath $candidateProgressSummaryPath -PathType Leaf)) {
    $activeSoakProgressPath = $candidateProgress.FullName
    $SoakSummaryPath = $candidateProgressSummaryPath
  } elseif ($candidateSummary) {
    $SoakSummaryPath = $candidateSummary.FullName
  }
}

if (-not [string]::IsNullOrWhiteSpace($activeSoakProgressPath) -and -not (Test-Path -LiteralPath $SoakSummaryPath -PathType Leaf)) {
  try {
    $progress = Read-JsonFile $activeSoakProgressPath
    $soakLeaf = Split-Path (Split-Path $activeSoakProgressPath -Parent) -Leaf
    $activeProcessCount = @(Get-CimInstance Win32_Process | Where-Object {
        $_.CommandLine -and
        $_.CommandLine -match "run_full_system_soak_http_motion.ps1" -and
        $_.CommandLine -match [regex]::Escape($soakLeaf)
      }).Count
    if ($activeProcessCount -gt 0) {
      Add-Check "strict-soak-progress" "pass" "running=$activeSoakProgressPath processCount=$activeProcessCount records=$($progress.records) failedPolls=$($progress.failedPolls) motionRefreshFailures=$($progress.motionRefreshFailures)"
      Add-Check "strict-soak-summary" "pending" "Strict soak is still running; summary pending at $SoakSummaryPath"
    } else {
      Add-Check "strict-soak-progress" "fail" "Progress exists but no active soak process and no summary: $activeSoakProgressPath records=$($progress.records) failedPolls=$($progress.failedPolls) motionRefreshFailures=$($progress.motionRefreshFailures)"
      Add-Check "strict-soak-summary" "fail" "Strict soak process exited or was stopped without summary: $SoakSummaryPath"
    }
  } catch {
    Add-Check "strict-soak-progress" "fail" $_.Exception.Message
  }
} elseif ([string]::IsNullOrWhiteSpace($SoakSummaryPath)) {
  Add-Check "strict-soak-summary" "pending" "No completed strict full-system soak summary found yet."
} elseif (-not (Test-Path -LiteralPath $SoakSummaryPath -PathType Leaf)) {
  Add-Check "strict-soak-summary" "fail" "Missing strict soak summary: $SoakSummaryPath"
} else {
  try {
    $soak = Read-JsonFile $SoakSummaryPath
    $soakReady = [string]$soak.status -eq "pass" -and @($soak.issues).Count -eq 0 -and
      (Get-IntValue $soak "durationSeconds" 0) -ge $MinSoakDurationSeconds
    $soakStatus = if ($soakReady) {
      "pass"
    } elseif ([string]$soak.status -eq "fail" -or @($soak.issues).Count -gt 0) {
      "fail"
    } else {
      "pending"
    }
    Add-Check "strict-soak-summary" $soakStatus "status=$($soak.status) duration=$($soak.durationSeconds) issues=$(@($soak.issues) -join ', ') path=$SoakSummaryPath"
  } catch {
    Add-Check "strict-soak-summary" "fail" $_.Exception.Message
  }
}

$failed = @($checks | Where-Object { $_.status -eq "fail" })
$pending = @($checks | Where-Object { $_.status -eq "pending" })
$status = if ($failed.Count -gt 0) {
  "current-lead-reproducibility-failed"
} elseif ($pending.Count -gt 0) {
  "current-lead-reproducible-pending-soak"
} else {
  "current-lead-reproducible-ready"
}

New-Item -ItemType Directory -Force -Path $ReportDir | Out-Null
$resolvedReportDir = (Resolve-Path $ReportDir).Path
$jsonPath = Join-Path $resolvedReportDir "CURRENT_LEAD_REPRODUCIBILITY.json"
$markdownPath = Join-Path $resolvedReportDir "CURRENT_LEAD_REPRODUCIBILITY.md"

$result = [ordered]@{
  schema = "stackchan.current-lead-reproducibility.v1"
  status = $status
  generatedAt = (Get-Date).ToString("o")
    warmArchivePath = $WarmArchivePath
  candidateArchivePath = $CandidateArchivePath
  rvcWorkerUrl = $RvcWorkerUrl
  deviceHost = $DeviceHost
    soakSummaryPath = $SoakSummaryPath
    minSoakDurationSeconds = $MinSoakDurationSeconds
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
  "- Warm archive: ``$WarmArchivePath``",
  "- Candidate archive: ``$CandidateArchivePath``",
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
  $lines += "- Current lead artifacts, live ROCm bridge path, and strict soak evidence are ready."
} elseif ($failed.Count -gt 0) {
  $lines += "- Fix failed reproducibility checks before treating this as the current lead."
} else {
  $lines += "- Artifacts are reproducible; complete the supervised overnight strict soak when the robot is reachable and the body is clear."
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
