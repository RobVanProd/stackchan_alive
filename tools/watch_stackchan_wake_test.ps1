param(
  [string]$DeviceHost = "192.168.1.238",
  [string]$BaseUrl = "",
  [int]$DurationSeconds = 45,
  [int]$PollIntervalMs = 1000,
  [string]$ReportDir = "output\wake-validation-latest",
  [string]$ExpectedPhrase = "Hey StackChan",
  [switch]$SkipReset,
  [switch]$PlayTone,
  [switch]$RequireWake,
  [switch]$Json
)

$ErrorActionPreference = "Stop"

$RepoRoot = Resolve-Path (Join-Path $PSScriptRoot "..")
Set-Location $RepoRoot

if ([string]::IsNullOrWhiteSpace($BaseUrl)) {
  $BaseUrl = "http://$DeviceHost`:8789"
}

function Get-IntValue {
  param($Object, [string]$Name, [int]$DefaultValue = 0)
  if ($null -eq $Object) { return $DefaultValue }
  $property = $Object.PSObject.Properties[$Name]
  if ($null -eq $property -or $null -eq $property.Value) { return $DefaultValue }
  return [int]$property.Value
}

function Get-DoubleValue {
  param($Object, [string]$Name, [double]$DefaultValue = 0)
  if ($null -eq $Object) { return $DefaultValue }
  $property = $Object.PSObject.Properties[$Name]
  if ($null -eq $property -or $null -eq $property.Value) { return $DefaultValue }
  return [double]$property.Value
}

function Read-Status {
  Invoke-RestMethod -Uri "$BaseUrl/status" -TimeoutSec 5
}

New-Item -ItemType Directory -Force -Path $ReportDir | Out-Null

$startedAt = [DateTimeOffset]::Now
$resetResponse = $null
$toneResponse = $null

if (-not $SkipReset) {
  $resetResponse = Invoke-RestMethod -Uri "$BaseUrl/wake-reset" -TimeoutSec 5
  Start-Sleep -Milliseconds 500
}

if ($PlayTone) {
  $toneResponse = Invoke-RestMethod -Uri "$BaseUrl/mic-tone" -TimeoutSec 5
  Start-Sleep -Milliseconds 1500
}

$samples = New-Object System.Collections.Generic.List[object]
$deadline = (Get-Date).AddSeconds($DurationSeconds)
while ((Get-Date) -lt $deadline) {
  try {
    $status = Read-Status
    $samples.Add([ordered]@{
      sampledAt = [DateTimeOffset]::Now.ToString("o")
      bridgeState = [string]$status.bridge_state
      networkState = [string]$status.network_state
      displayFps = Get-DoubleValue $status "display_window_fps"
      displayMaxFrameUs = Get-IntValue $status "display_window_max_frame_us"
      displaySlowFrames = Get-IntValue $status "display_window_slow_frames"
      recordDrops = Get-IntValue $status "sr_wake_record_drops"
      audioPeak = Get-IntValue $status "sr_wake_audio_peak"
      audioMeanAbs = Get-IntValue $status "sr_wake_audio_mean_abs"
      audioClips = Get-IntValue $status "sr_wake_audio_clips"
      lastProbability = Get-IntValue $status "sr_wake_mww_last_probability"
      maxProbability = Get-IntValue $status "sr_wake_mww_max_probability"
      averageProbability = Get-IntValue $status "sr_wake_mww_average_probability"
      maxAverageProbability = Get-IntValue $status "sr_wake_mww_max_average_probability"
      probabilityCutoff = Get-IntValue $status "sr_wake_mww_probability_cutoff"
      slidingWindow = Get-IntValue $status "sr_wake_mww_sliding_window"
      lastDetectionProbability = Get-IntValue $status "sr_wake_mww_last_detection_probability"
      lastDetectionAverageProbability = Get-IntValue $status "sr_wake_mww_last_detection_average_probability"
      maxDetectionAverageProbability = Get-IntValue $status "sr_wake_mww_max_detection_average_probability"
      detections = Get-IntValue $status "sr_wake_mww_detections"
      wakeEventsApplied = Get-IntValue $status "sr_wake_events_applied"
      speakerToneOk = Get-IntValue $status "speaker_tone_ok"
      speakerToneFailed = Get-IntValue $status "speaker_tone_failed"
      wakeError = [string]$status.sr_wake_error
    })
  } catch {
    $samples.Add([ordered]@{
      sampledAt = [DateTimeOffset]::Now.ToString("o")
      error = $_.Exception.Message
    })
  }
  Start-Sleep -Milliseconds $PollIntervalMs
}

$validSamples = @($samples | Where-Object { -not $_.Contains("error") })
$last = if ($validSamples.Count -gt 0) { $validSamples[-1] } else { $null }
$maxProbability = 0
$maxAverageProbability = 0
$maxDetectionAverageProbability = 0
$lastDetectionProbability = 0
$lastDetectionAverageProbability = 0
$probabilityCutoff = 0
$slidingWindow = 0
$maxFps = 0.0
$minFps = 999.0
$maxFrameUs = 0
$maxSlowFrames = 0
$maxDetections = 0
$maxWakeEvents = 0
$lastDrops = 0
$toneOk = 0
$toneFailed = 0
$bridgeReadySamples = 0
$bridgeAcceptableSamples = 0
$connectedSamples = 0
$sampleErrors = @($samples | Where-Object { $_.Contains("error") }).Count
$acceptableBridgeStates = if ($RequireWake) {
  @("ready", "listening", "thinking", "responding")
} else {
  @("ready")
}

foreach ($sample in $validSamples) {
  $maxProbability = [Math]::Max($maxProbability, [int]$sample.maxProbability)
  $maxAverageProbability = [Math]::Max($maxAverageProbability, [int]$sample.maxAverageProbability)
  $maxDetectionAverageProbability = [Math]::Max($maxDetectionAverageProbability, [int]$sample.maxDetectionAverageProbability)
  $lastDetectionProbability = [int]$sample.lastDetectionProbability
  $lastDetectionAverageProbability = [int]$sample.lastDetectionAverageProbability
  if ([int]$sample.probabilityCutoff -gt 0) { $probabilityCutoff = [int]$sample.probabilityCutoff }
  if ([int]$sample.slidingWindow -gt 0) { $slidingWindow = [int]$sample.slidingWindow }
  $maxFps = [Math]::Max($maxFps, [double]$sample.displayFps)
  $minFps = [Math]::Min($minFps, [double]$sample.displayFps)
  $maxFrameUs = [Math]::Max($maxFrameUs, [int]$sample.displayMaxFrameUs)
  $maxSlowFrames = [Math]::Max($maxSlowFrames, [int]$sample.displaySlowFrames)
  $maxDetections = [Math]::Max($maxDetections, [int]$sample.detections)
  $maxWakeEvents = [Math]::Max($maxWakeEvents, [int]$sample.wakeEventsApplied)
  $lastDrops = [int]$sample.recordDrops
  $toneOk = [Math]::Max($toneOk, [int]$sample.speakerToneOk)
  $toneFailed = [Math]::Max($toneFailed, [int]$sample.speakerToneFailed)
  if ($sample.bridgeState -eq "ready") { $bridgeReadySamples++ }
  if ($acceptableBridgeStates -contains $sample.bridgeState) { $bridgeAcceptableSamples++ }
  if ($sample.networkState -eq "connected") { $connectedSamples++ }
}
if ($validSamples.Count -eq 0) { $minFps = 0.0 }

$wakeDetected = $maxDetections -gt 0 -or $maxWakeEvents -gt 0
$runtimeHealthy = $validSamples.Count -gt 0 -and
  $sampleErrors -eq 0 -and
  $bridgeAcceptableSamples -eq $validSamples.Count -and
  $connectedSamples -eq $validSamples.Count -and
  $minFps -ge 18.0 -and
  $maxFrameUs -le 90000 -and
  $lastDrops -eq 0 -and
  ([string]$last.wakeError) -eq ""
$toneHealthy = (-not $PlayTone) -or ($toneResponse.debug_tone_accepted -eq $true -and $toneFailed -eq 0)

$checks = @(
  [ordered]@{
    id = "runtime-healthy"
    status = if ($runtimeHealthy) { "pass" } else { "fail" }
    detail = "samples=$($validSamples.Count) errors=$sampleErrors bridge_ok=$bridgeAcceptableSamples bridge_ready=$bridgeReadySamples connected=$connectedSamples min_fps=$([Math]::Round($minFps, 2)) max_frame_us=$maxFrameUs record_drops=$lastDrops wake_error=$($last.wakeError)"
  },
  [ordered]@{
    id = "wake-detected"
    status = if ($wakeDetected) { "pass" } elseif ($RequireWake) { "fail" } else { "pending" }
    detail = "detections=$maxDetections wake_events=$maxWakeEvents max_probability=$maxProbability max_average_probability=$maxAverageProbability cutoff=$probabilityCutoff window=$slidingWindow detection_avg=$maxDetectionAverageProbability"
  },
  [ordered]@{
    id = "tone-test"
    status = if ($toneHealthy) { "pass" } else { "fail" }
    detail = if ($PlayTone) { "accepted=$($toneResponse.debug_tone_accepted) tone_ok=$toneOk tone_failed=$toneFailed" } else { "not requested" }
  }
)

$failed = @($checks | Where-Object { $_.status -eq "fail" })
$pending = @($checks | Where-Object { $_.status -eq "pending" })
$status = if ($failed.Count -gt 0) {
  "stackchan-wake-validation-failed"
} elseif ($pending.Count -gt 0) {
  "stackchan-wake-validation-pending-phrase"
} else {
  "stackchan-wake-validation-passed"
}

$report = [ordered]@{
  schema = "stackchan.wake-validation.v1"
  generatedAt = [DateTimeOffset]::Now.ToString("o")
  startedAt = $startedAt.ToString("o")
  durationSeconds = $DurationSeconds
  baseUrl = $BaseUrl
  expectedPhrase = $ExpectedPhrase
  status = $status
  failed = $failed.Count
  pending = $pending.Count
  wakeDetected = $wakeDetected
  runtimeHealthy = $runtimeHealthy
  toneHealthy = $toneHealthy
  resetRequested = (-not $SkipReset)
  resetAccepted = if ($null -ne $resetResponse) { [bool]$resetResponse.debug_wake_reset_request } else { $false }
  toneRequested = [bool]$PlayTone
  toneAccepted = if ($null -ne $toneResponse) { [bool]$toneResponse.debug_tone_accepted } else { $false }
  summary = [ordered]@{
    sampleCount = $validSamples.Count
    minDisplayFps = [Math]::Round($minFps, 2)
    maxDisplayFps = [Math]::Round($maxFps, 2)
    maxDisplayFrameUs = $maxFrameUs
    maxDisplaySlowFrames = $maxSlowFrames
    recordDrops = $lastDrops
    maxProbability = $maxProbability
    maxAverageProbability = $maxAverageProbability
    probabilityCutoff = $probabilityCutoff
    slidingWindow = $slidingWindow
    lastDetectionProbability = $lastDetectionProbability
    lastDetectionAverageProbability = $lastDetectionAverageProbability
    maxDetectionAverageProbability = $maxDetectionAverageProbability
    detections = $maxDetections
    wakeEventsApplied = $maxWakeEvents
    speakerToneOk = $toneOk
    speakerToneFailed = $toneFailed
  }
  checks = $checks
  samples = $samples
}

$reportPath = Join-Path $ReportDir "STACKCHAN_WAKE_VALIDATION.json"
$report | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $reportPath -Encoding UTF8

if ($Json) {
  $report | ConvertTo-Json -Depth 8
} else {
  Write-Host "Wake validation: $status"
  Write-Host "Report: $reportPath"
  Write-Host "Phrase: $ExpectedPhrase"
  Write-Host "Runtime healthy: $runtimeHealthy"
  Write-Host "Wake detected: $wakeDetected max_probability=$maxProbability detections=$maxDetections events=$maxWakeEvents"
  if ($PlayTone) {
    Write-Host "Tone accepted: $($report.toneAccepted) tone_failed=$toneFailed"
  }
}

if ($failed.Count -gt 0) {
  exit 1
}
