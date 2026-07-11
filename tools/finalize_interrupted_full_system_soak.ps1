param(
  [Parameter(Mandatory = $true)]
  [string]$EvidenceRoot,
  [string]$Reason = "interrupted_without_summary",
  [switch]$Json
)

$ErrorActionPreference = "Stop"

$evidencePath = (Resolve-Path $EvidenceRoot).Path
$progressPath = Join-Path $evidencePath "progress.json"
$preflightPath = Join-Path $evidencePath "preflight.json"
$summaryPath = Join-Path $evidencePath "summary.json"

if (-not (Test-Path -LiteralPath $progressPath -PathType Leaf)) {
  throw "Missing progress file: $progressPath"
}

function Read-JsonFile {
  param([string]$Path)
  return Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json
}

function Get-Value {
  param($Object, [string]$Name, $Default = $null)
  if ($null -eq $Object) { return $Default }
  $property = $Object.PSObject.Properties[$Name]
  if ($null -eq $property -or $null -eq $property.Value) { return $Default }
  return $property.Value
}

$progress = Read-JsonFile $progressPath
$preflight = $null
if (Test-Path -LiteralPath $preflightPath -PathType Leaf) {
  $preflight = Read-JsonFile $preflightPath
}

$issues = New-Object System.Collections.Generic.List[string]
$issues.Add($Reason)

$failedPolls = [int64](Get-Value $progress "failedPolls" 0)
$maxConsecutiveFailedPolls = [int64](Get-Value $progress "maxConsecutiveFailedPolls" 0)
$motionRefreshFailures = [int64](Get-Value $progress "motionRefreshFailures" 0)
$motionRefreshes = [int64](Get-Value $progress "motionRefreshes" 0)
$records = [int64](Get-Value $progress "records" 0)
$motionSamples = [int64](Get-Value $progress "motionSamples" 0)
$rvcWorkerPolls = [int64](Get-Value $progress "rvcWorkerPolls" 0)
$rvcWorkerReadySamples = [int64](Get-Value $progress "rvcWorkerReadySamples" 0)

if ($failedPolls -gt 0) { $issues.Add("failed_polls_observed") }
if ($maxConsecutiveFailedPolls -gt 1) { $issues.Add("consecutive_failed_polls_observed") }
if ($motionRefreshFailures -gt 0) { $issues.Add("motion_refresh_failed") }

$durationSeconds = [int64](Get-Value $progress "durationSeconds" 0)
$elapsedSeconds = [double](Get-Value $progress "elapsedSeconds" 0.0)
$okPolls = [math]::Max(0, $records - $failedPolls)
$latest = Get-Value $progress "latest" $null
$maxFrameUs = Get-Value $latest "max_us" $null
$maxSlowFrames = Get-Value $latest "slow" $null
$maxMotionSessionTimeouts = Get-Value $latest "motion_session_timeouts" $null
$motionSampleRatio = if ($okPolls -gt 0) { [math]::Round($motionSamples / [double]$okPolls, 4) } else { 0.0 }

$summary = [ordered]@{
  schema = "stackchan.full-system-soak-summary.v1"
  startedAt = Get-Value $progress "startedAt" $null
  endedAt = (Get-Date).ToString("o")
  durationSeconds = [int][math]::Floor($elapsedSeconds)
  plannedDurationSeconds = $durationSeconds
  elapsedSeconds = $elapsedSeconds
  evidenceRoot = $evidencePath
  status = "fail"
  issues = @($issues)
  abortReason = $Reason
  strict = [ordered]@{
    requireMotion = $true
    minMotionSampleRatio = 0.95
    requireMotionTelemetry = $true
    requireNoMotionTimeouts = $true
    requireBridgeSocket = $true
    requireWakeReady = $true
    requireMicReady = $true
    requireSpeakerReady = $true
    requireRvcWorker = $true
    maxFailedPolls = Get-Value $preflight "maxFailedPolls" 3
    maxConsecutiveFailedPolls = Get-Value $preflight "maxConsecutiveFailedPolls" 1
    motionRefreshInitialDelaySeconds = Get-Value $preflight "motionRefreshInitialDelaySeconds" $null
    failFastOnStrictBreach = $true
  }
  records = $records
  okPolls = $okPolls
  failedPolls = $failedPolls
  maxConsecutiveFailedPolls = $maxConsecutiveFailedPolls
  motionSamples = $motionSamples
  motionSampleRatio = $motionSampleRatio
  motionTelemetrySamples = $motionSamples
  maxMotionSessionTimeouts = $maxMotionSessionTimeouts
  bridgeReadySamples = Get-Value $progress "bridgeReadySamples" 0
  bridgeHealthySamples = Get-Value $progress "bridgeHealthySamples" 0
  networkConnectedSamples = Get-Value $progress "motionSamples" 0
  socketPresentSamples = Get-Value $progress "socketPresentSamples" 0
  wakeReadySamples = Get-Value $progress "wakeReadySamples" 0
  micReadySamples = Get-Value $progress "micReadySamples" 0
  speakerReadySamples = Get-Value $progress "speakerReadySamples" 0
  maxFrameUs = $maxFrameUs
  maxSlowFrames = $maxSlowFrames
  motionRefreshes = $motionRefreshes
  motionRefreshFailures = $motionRefreshFailures
  rvcWorkerPolls = $rvcWorkerPolls
  rvcWorkerReadySamples = $rvcWorkerReadySamples
  latestRvcWorkerHealth = Get-Value $progress "latestRvcWorkerHealth" $null
  serialMotionLines = 0
  serialResetLines = 0
  fatalError = $null
}

$summary | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $summaryPath -Encoding UTF8

if ($Json) {
  $summary | ConvertTo-Json -Depth 10
} else {
  Write-Host "Wrote interrupted full-system soak failure summary: $summaryPath"
  Write-Host "Reason: $Reason"
}
