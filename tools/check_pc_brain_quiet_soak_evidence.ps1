param(
  [string]$SoakJsonPath = "",
  [string]$SoakMarkdownPath = "",
  [string]$ReviewPath = "",
  [int]$MinDurationSeconds = 600,
  [switch]$RequireReady,
  [switch]$Json
)

$ErrorActionPreference = "Stop"

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

function Get-IntValue {
  param($Object, [string]$Name, [int]$DefaultValue = 0)
  if ($null -eq $Object) { return $DefaultValue }
  $property = $Object.PSObject.Properties[$Name]
  if ($null -eq $property -or $null -eq $property.Value) { return $DefaultValue }
  return [int]$property.Value
}

function Test-Commit {
  param([string]$Value)
  return $Value -match "^[a-fA-F0-9]{40}$"
}

function Get-ReviewSourceCommit {
  param([string]$Text)

  $match = [regex]::Match($Text, "(?im)^-\s*Source commit:\s*([a-fA-F0-9]{40})\s*$")
  if ($match.Success) {
    return $match.Groups[1].Value
  }
  return ""
}

if ([string]::IsNullOrWhiteSpace($SoakJsonPath)) {
  $candidates = Get-ChildItem -Path "output\pc-brain" -Recurse -Filter "PC_BRAIN_QUIET_SOAK.json" -File -ErrorAction SilentlyContinue |
    Sort-Object LastWriteTime -Descending
  if ($candidates.Count -gt 0) {
    $SoakJsonPath = $candidates[0].FullName
  }
}

$checks = @()
$soak = $null
$sourceCommit = ""

if ([string]::IsNullOrWhiteSpace($SoakJsonPath)) {
  Add-Check "soak-json" "pending" "Pass -SoakJsonPath or place PC_BRAIN_QUIET_SOAK.json under output\pc-brain."
} elseif (-not (Test-Path -LiteralPath $SoakJsonPath -PathType Leaf)) {
  Add-Check "soak-json" "fail" "Missing soak JSON: $SoakJsonPath"
} else {
  Add-Check "soak-json" "pass" "Found soak JSON: $SoakJsonPath"
  try {
    $soak = Get-Content -LiteralPath $SoakJsonPath -Raw | ConvertFrom-Json
  } catch {
    Add-Check "soak-json-parse" "fail" "Soak JSON is invalid: $($_.Exception.Message)"
  }
}

if ($soak) {
  Add-Check "schema" ($(if ($soak.schema -eq "stackchan.pc-brain-quiet-soak.v1") { "pass" } else { "fail" })) "schema=$($soak.schema)"
  Add-Check "soak-status" ($(if ($soak.status -eq "pass") { "pass" } else { "fail" })) "status=$($soak.status)"
  $sourceCommit = [string]$soak.sourceCommit
  Add-Check "source-commit" ($(if (Test-Commit $sourceCommit) { "pass" } else { "fail" })) "sourceCommit=$sourceCommit"
  $issues = @($soak.issues)
  Add-Check "soak-issues" ($(if ($issues.Count -eq 0) { "pass" } else { "fail" })) "issues=$($issues -join ', ')"

  $duration = Get-IntValue $soak "duration_seconds" 0
  Add-Check "duration" ($(if ($duration -ge $MinDurationSeconds) { "pass" } else { "fail" })) "duration_seconds=$duration min=$MinDurationSeconds"
  $requested = Get-IntValue $soak "requested_duration_seconds" $duration
  Add-Check "requested-duration" ($(if ($requested -ge $MinDurationSeconds) { "pass" } else { "fail" })) "requested_duration_seconds=$requested min=$MinDurationSeconds"
  $interval = Get-IntValue $soak "interval_seconds" 30
  Add-Check "interval" ($(if ($interval -gt 0 -and $interval -le 60) { "pass" } else { "fail" })) "interval_seconds=$interval"

  $records = @($soak.records)
  $pollCount = Get-IntValue $soak "poll_count" 0
  Add-Check "poll-count" ($(if ($pollCount -eq $records.Count -and $pollCount -ge 2) { "pass" } else { "fail" })) "poll_count=$pollCount records=$($records.Count)"

  $audioStartFirst = $null
  $audioStartLast = $null
  $lastMessages = $null
  $monotonicMessages = $true
  $localIps = @{}
  for ($i = 0; $i -lt $records.Count; $i++) {
    $record = $records[$i]
    $prefix = "record-$i"
    Add-Check "$prefix-debug-ok" ($(if ($record.heap_note -eq "debug-endpoint-ok") { "pass" } else { "fail" })) "heap_note=$($record.heap_note)"
    Add-Check "$prefix-network" ($(if ($record.network_state -eq "connected") { "pass" } else { "fail" })) "network_state=$($record.network_state)"
    Add-Check "$prefix-bridge" ($(if ($record.bridge_state -eq "ready") { "pass" } else { "fail" })) "bridge_state=$($record.bridge_state)"
    foreach ($counter in @("bridge_outputs_dropped", "bridge_parse_errors", "bridge_timeouts", "bridge_downlink_errors", "bridge_downlink_playback_errors")) {
      $value = Get-IntValue $record $counter 0
      Add-Check "$prefix-$counter" ($(if ($value -eq 0) { "pass" } else { "fail" })) "$counter=$value"
    }
    $messages = Get-IntValue $record "bridge_messages" 0
    if ($null -ne $lastMessages -and $messages -lt $lastMessages) {
      $monotonicMessages = $false
    }
    $lastMessages = $messages
    $audioStarts = Get-IntValue $record "audio_streams_started" 0
    if ($null -eq $audioStartFirst) { $audioStartFirst = $audioStarts }
    $audioStartLast = $audioStarts
    if (-not [string]::IsNullOrWhiteSpace([string]$record.local_ip)) {
      $localIps[[string]$record.local_ip] = $true
    }
  }
  Add-Check "bridge-message-monotonic" ($(if ($monotonicMessages) { "pass" } else { "fail" })) "bridge_messages did not decrease across records."
  Add-Check "no-unexpected-audio-streams" ($(if (($audioStartLast - $audioStartFirst) -eq 0) { "pass" } else { "fail" })) "audio_streams_started first=$audioStartFirst last=$audioStartLast"
  Add-Check "stable-local-ip" ($(if ($localIps.Keys.Count -le 1) { "pass" } else { "fail" })) "local_ips=$($localIps.Keys -join ', ')"
}

if (-not [string]::IsNullOrWhiteSpace($SoakMarkdownPath)) {
  if (-not (Test-Path -LiteralPath $SoakMarkdownPath -PathType Leaf)) {
    Add-Check "soak-markdown" "fail" "Missing soak markdown: $SoakMarkdownPath"
  } else {
    $markdown = Get-Content -LiteralPath $SoakMarkdownPath -Raw
    foreach ($pattern in @("Stackchan PC Brain Quiet Soak", "Status: ``pass``", "Polls")) {
      Add-Check "soak-markdown-$pattern" ($(if ($markdown -match [regex]::Escape($pattern)) { "pass" } else { "fail" })) "markdown includes $pattern"
    }
    Add-Check "soak-markdown-source-commit" ($(if ($markdown -match "Source commit:\s*``[a-fA-F0-9]{40}``") { "pass" } else { "fail" })) "markdown includes source commit"
  }
}

if (-not [string]::IsNullOrWhiteSpace($ReviewPath)) {
  if (-not (Test-Path -LiteralPath $ReviewPath -PathType Leaf)) {
    Add-Check "human-review" "fail" "Missing review file: $ReviewPath"
  } else {
    $review = Get-Content -LiteralPath $ReviewPath -Raw
    foreach ($pattern in @(
      "Source commit:",
      "Support decision: pass",
      "Quiet soak decision: pass",
      "Robot connection decision: pass",
      "No unexpected audio decision: pass"
    )) {
      Add-Check "human-review-$pattern" ($(if ($review -match [regex]::Escape($pattern)) { "pass" } else { "fail" })) "review includes $pattern"
    }
    $reviewSourceCommit = Get-ReviewSourceCommit $review
    Add-Check "human-review-source-commit-match" ($(if ((Test-Commit $reviewSourceCommit) -and $reviewSourceCommit -eq $sourceCommit) { "pass" } else { "fail" })) "review sourceCommit=$reviewSourceCommit evidence sourceCommit=$sourceCommit"
  }
}

$failed = @($checks | Where-Object { $_.status -eq "fail" })
$pending = @($checks | Where-Object { $_.status -eq "pending" })
$status = if ($failed.Count -gt 0) {
  "pc-brain-quiet-soak-not-ready"
} elseif ($pending.Count -gt 0) {
  "pending-pc-brain-quiet-soak-evidence"
} else {
  "pc-brain-quiet-soak-ready"
}

$result = [ordered]@{
  schema = "stackchan.pc-brain-quiet-soak-evidence-check.v1"
  status = $status
  sourceCommit = $sourceCommit
  soakJsonPath = $SoakJsonPath
  soakMarkdownPath = $SoakMarkdownPath
  reviewPath = $ReviewPath
  passed = @($checks | Where-Object { $_.status -eq "pass" }).Count
  failed = $failed.Count
  pending = $pending.Count
  checks = $checks
}

if ($Json) {
  $result | ConvertTo-Json -Depth 8
} else {
  Write-Host "PC Brain quiet soak evidence: $status"
  foreach ($check in $checks) {
    Write-Host "[$($check.status)] $($check.id): $($check.detail)"
  }
}

if ($failed.Count -gt 0 -or ($RequireReady -and $status -ne "pc-brain-quiet-soak-ready")) {
  exit 1
}
