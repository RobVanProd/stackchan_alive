param(
  [Parameter(Mandatory = $true)]
  [string]$Path,
  [int]$MinFrames = 100,
  [double]$MinMaxEnvelope = 0.5,
  [switch]$AllowFlatVisemes
)

$ErrorActionPreference = "Stop"

if (-not (Test-Path -LiteralPath $Path)) {
  throw "Missing speech envelope sidecar: $Path"
}

function Assert-Range {
  param(
    [string]$Name,
    [double]$Value,
    [double]$Min,
    [double]$Max
  )

  if ($Value -lt $Min -or $Value -gt $Max) {
    throw "$Name must be between $Min and $Max. Received $Value."
  }
}

function Get-JsonProperty {
  param(
    [object]$Object,
    [string]$Name
  )

  $property = $Object.PSObject.Properties[$Name]
  if ($null -eq $property) {
    return $null
  }
  return $property.Value
}

$sidecar = Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json

if ([string]$sidecar.schema -ne "stackchan.speech-envelope-sidecar.v1") {
  throw "Unsupported speech sidecar schema: $($sidecar.schema)"
}

$frameMs = [int]$sidecar.frameMs
Assert-Range -Name "frameMs" -Value $frameMs -Min 10 -Max 100

if ([double]$sidecar.frameRateHz -le 0.0) {
  throw "frameRateHz must be positive."
}

if ([int]$sidecar.sampleRate -le 0) {
  throw "sampleRate must be positive."
}

if ([double]$sidecar.durationSeconds -le 0.0) {
  throw "durationSeconds must be positive."
}

$frames = @($sidecar.frames)
if ($frames.Count -lt $MinFrames) {
  throw "Speech sidecar has too few frames: $($frames.Count), expected at least $MinFrames."
}

$summaryFrames = [int]$sidecar.summary.frames
if ($summaryFrames -ne $frames.Count) {
  throw "summary.frames mismatch: summary=$summaryFrames actual=$($frames.Count)."
}

$validVisemes = @("ah", "oh", "ee", "neutral")
$lastT = -1
$maxEnvelope = 0.0
$voicedFrames = 0
$visemeCounts = @{}
foreach ($name in $validVisemes) {
  $visemeCounts[$name] = 0
}

for ($index = 0; $index -lt $frames.Count; $index++) {
  $frame = $frames[$index]
  $tMs = [int]$frame.tMs
  if ($tMs -le $lastT) {
    throw "Frame timestamps must increase strictly. Frame $index has tMs=$tMs after $lastT."
  }
  if ($index -gt 0 -and ($tMs - $lastT) -ne $frameMs) {
    throw "Frame $index timestamp step is $($tMs - $lastT) ms, expected $frameMs ms."
  }
  $lastT = $tMs

  $envelope = [double]$frame.envelope
  Assert-Range -Name "frames[$index].envelope" -Value $envelope -Min 0.0 -Max 1.0
  if ($envelope -gt $maxEnvelope) {
    $maxEnvelope = $envelope
  }
  if ($envelope -ge 0.04) {
    $voicedFrames++
  }

  $viseme = [string]$frame.viseme
  if ($validVisemes -notcontains $viseme) {
    throw "Frame $index has unsupported viseme: $viseme"
  }
  $visemeCounts[$viseme]++
}

if ($maxEnvelope -lt $MinMaxEnvelope) {
  throw "Speech sidecar max envelope is too low: $maxEnvelope, expected at least $MinMaxEnvelope."
}

$summaryMaxEnvelope = [double]$sidecar.summary.maxEnvelope
if ([Math]::Abs($summaryMaxEnvelope - $maxEnvelope) -gt 0.001) {
  throw "summary.maxEnvelope mismatch: summary=$summaryMaxEnvelope actual=$maxEnvelope."
}

$summaryVoicedFrames = [int]$sidecar.summary.voicedFrames
if ($summaryVoicedFrames -ne $voicedFrames) {
  throw "summary.voicedFrames mismatch: summary=$summaryVoicedFrames actual=$voicedFrames."
}

foreach ($name in $validVisemes) {
  $summaryValue = Get-JsonProperty -Object $sidecar.summary.visemes -Name $name
  $summaryCount = if ($null -eq $summaryValue) { 0 } else { [int]$summaryValue }
  if ($summaryCount -ne [int]$visemeCounts[$name]) {
    throw "summary.visemes.$name mismatch: summary=$summaryCount actual=$($visemeCounts[$name])."
  }
}

if (-not $AllowFlatVisemes) {
  foreach ($name in @("ah", "oh", "ee")) {
    if ([int]$visemeCounts[$name] -le 0) {
      throw "Speech sidecar missing required viseme variation: $name."
    }
  }
}

[ordered]@{
  path = (Resolve-Path -LiteralPath $Path).Path
  frames = $frames.Count
  frameMs = $frameMs
  durationSeconds = [double]$sidecar.durationSeconds
  maxEnvelope = $maxEnvelope
  voicedFrames = $voicedFrames
  visemes = [ordered]@{
    ah = [int]$visemeCounts["ah"]
    oh = [int]$visemeCounts["oh"]
    ee = [int]$visemeCounts["ee"]
    neutral = [int]$visemeCounts["neutral"]
  }
} | ConvertTo-Json -Depth 4

Write-Host "Speech envelope sidecar verified:"
Write-Host (Resolve-Path -LiteralPath $Path).Path
