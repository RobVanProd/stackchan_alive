param(
  [Parameter(Mandatory = $true)]
  [string]$EvidenceRoot,
  [Parameter(Mandatory = $true)]
  [ValidateSet("pass", "fail")]
  [string]$VisualVerdict,
  [Parameter(Mandatory = $true)]
  [string]$OperatorNotes,
  [string]$OperatorName = "operator",
  [switch]$Json
)

$ErrorActionPreference = "Stop"
$RepoRoot = Resolve-Path (Join-Path $PSScriptRoot "..")
Set-Location $RepoRoot

function Write-JsonAtomic {
  param([string]$Path, $Value)
  $temp = "$Path.tmp-$([guid]::NewGuid().ToString('N'))"
  try {
    $Value | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $temp -Encoding UTF8
    Move-Item -LiteralPath $temp -Destination $Path -Force
  } finally {
    Remove-Item -LiteralPath $temp -Force -ErrorAction SilentlyContinue
  }
}

if ([string]::IsNullOrWhiteSpace($OperatorNotes) -or $OperatorNotes.Trim().Length -lt 8) {
  throw "OperatorNotes must contain a specific visual observation of at least eight characters."
}
if ([string]::IsNullOrWhiteSpace($OperatorName)) {
  throw "OperatorName cannot be blank."
}

$summaryPath = Join-Path $EvidenceRoot "summary.json"
if (-not (Test-Path -LiteralPath $summaryPath -PathType Leaf)) {
  throw "Missing camera validation summary: $summaryPath"
}
$summary = Get-Content -LiteralPath $summaryPath -Raw | ConvertFrom-Json
if ($summary.schema -ne "stackchan.camera-follow-wake-validation.v1") {
  throw "Unexpected camera validation schema: $($summary.schema)"
}
if ($null -ne $summary.PSObject.Properties["visualReview"]) {
  throw "Camera validation already has a visual review. Start a new evidence run instead of overwriting it."
}

$telemetryStatus = [string]$summary.status
if ($VisualVerdict -eq "pass") {
  if ($telemetryStatus -ne "telemetry_pass_pending_visual") {
    throw "Cannot record a visual pass when telemetry status is '$telemetryStatus'."
  }
  $failedChecks = @($summary.checks | Where-Object { $_.status -ne "pass" })
  if ($failedChecks.Count -gt 0) {
    throw "Cannot record a visual pass while telemetry checks are not all passing."
  }
  if (-not [bool]$summary.motionStopVerified) {
    throw "Cannot record a visual pass without verified motion-stop cleanup."
  }
  if ([int]$summary.captureTargetSamples -lt 2 -or
      [int]$summary.captureFollowSamples -ne [int]$summary.captureTargetSamples) {
    throw "Cannot record a visual pass without complete camera following during microphone capture."
  }
  if ([int]$summary.chunksSubmittedDelta -lt 96 -or [int]$summary.bridgeTurnDelta -lt 1) {
    throw "Cannot record a visual pass without a complete wake capture and bridge turn."
  }
  if ([string]$summary.sourceCommit -notmatch "^[0-9a-fA-F]{40}$" -or
      [string]$summary.installedFirmwareSha256 -notmatch "^[0-9a-fA-F]{64}$") {
    throw "Cannot record a visual pass without source and firmware identity pins."
  }
}

$summary | Add-Member -NotePropertyName telemetryStatus -NotePropertyValue $telemetryStatus
$summary.visualVerdict = $VisualVerdict
$summary.status = if ($VisualVerdict -eq "pass") { "pass" } else { "fail" }
$summary | Add-Member -NotePropertyName visualReview -NotePropertyValue ([pscustomobject]@{
    verdict = $VisualVerdict
    operator = $OperatorName.Trim()
    notes = $OperatorNotes.Trim()
    reviewedAt = [DateTimeOffset]::Now.ToString("o")
  })
Write-JsonAtomic $summaryPath $summary

$result = [ordered]@{
  schema = "stackchan.camera-follow-wake-visual-review.v1"
  status = $summary.status
  evidenceRoot = (Resolve-Path $EvidenceRoot).Path
  summaryPath = (Resolve-Path $summaryPath).Path
  telemetryStatus = $telemetryStatus
  visualVerdict = $VisualVerdict
  motionStopVerified = [bool]$summary.motionStopVerified
}
if ($Json) { $result | ConvertTo-Json -Depth 5 } else {
  Write-Output "Camera follow visual review: $($result.status)"
  Write-Output "Summary: $($result.summaryPath)"
}
if ($result.status -ne "pass") { exit 1 }
