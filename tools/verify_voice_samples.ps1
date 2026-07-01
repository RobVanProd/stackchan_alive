param(
  [string]$VoiceRoot = "docs/media/voice"
)

$ErrorActionPreference = "Stop"

if (-not (Test-Path -LiteralPath $VoiceRoot)) {
  throw "Missing voice sample directory: $VoiceRoot"
}

$voiceRootPath = (Resolve-Path $VoiceRoot).Path

function Join-VoicePath {
  param([string]$Name)
  return Join-Path $voiceRootPath $Name
}

function Assert-TextContains {
  param(
    [string]$Text,
    [string]$Pattern,
    [string]$Name
  )

  if ($Text -notmatch [regex]::Escape($Pattern)) {
    throw "$Name missing expected voice note: $Pattern"
  }
}

function Read-StackchanWavInfo {
  param([string]$Path)

  $bytes = [System.IO.File]::ReadAllBytes($Path)
  if ($bytes.Length -lt 44) {
    throw "WAV is too small: $Path"
  }

  $riff = [System.Text.Encoding]::ASCII.GetString($bytes, 0, 4)
  $wave = [System.Text.Encoding]::ASCII.GetString($bytes, 8, 4)
  if ($riff -ne "RIFF" -or $wave -ne "WAVE") {
    throw "Invalid WAV header: $Path"
  }

  $channels = [BitConverter]::ToInt16($bytes, 22)
  $sampleRate = [BitConverter]::ToInt32($bytes, 24)
  $bitsPerSample = [BitConverter]::ToInt16($bytes, 34)

  $dataOffset = -1
  $dataSize = 0
  for ($i = 12; $i -lt ($bytes.Length - 8); $i++) {
    if ($bytes[$i] -eq 0x64 -and $bytes[$i + 1] -eq 0x61 -and $bytes[$i + 2] -eq 0x74 -and $bytes[$i + 3] -eq 0x61) {
      $dataOffset = $i + 8
      $dataSize = [BitConverter]::ToInt32($bytes, $i + 4)
      break
    }
  }

  if ($dataOffset -lt 0 -or $dataSize -le 0) {
    throw "WAV has no data chunk: $Path"
  }

  if (($dataOffset + $dataSize) -gt $bytes.Length) {
    throw "WAV data chunk exceeds file length: $Path"
  }

  if ($channels -ne 1) {
    throw "Voice sample must be mono: $Path has $channels channels"
  }

  if ($bitsPerSample -ne 16) {
    throw "Voice sample must be 16-bit PCM: $Path has $bitsPerSample bits"
  }

  if ($sampleRate -lt 16000 -or $sampleRate -gt 48000) {
    throw "Unexpected voice sample rate in $Path`: $sampleRate"
  }

  $sampleCount = [Math]::Floor($dataSize / 2)
  $sumSquares = 0.0
  $peak = 0.0
  for ($i = 0; $i -lt $sampleCount; $i++) {
    $sample = [BitConverter]::ToInt16($bytes, $dataOffset + ($i * 2)) / 32768.0
    $abs = [Math]::Abs($sample)
    if ($abs -gt $peak) {
      $peak = $abs
    }
    $sumSquares += $sample * $sample
  }

  $duration = $sampleCount / [double]$sampleRate
  $rms = [Math]::Sqrt($sumSquares / [Math]::Max(1, $sampleCount))

  return [pscustomobject]@{
    path = $Path
    sampleRate = $sampleRate
    channels = $channels
    bitsPerSample = $bitsPerSample
    durationSeconds = [Math]::Round($duration, 3)
    peak = [Math]::Round($peak, 4)
    rms = [Math]::Round($rms, 4)
    bytes = $bytes.Length
  }
}

$expected = @(
  [pscustomobject]@{ file = "stackchan_spark_greeting.wav"; minDuration = 4.8; maxDuration = 7.1 },
  [pscustomobject]@{ file = "stackchan_spark_thinking.wav"; minDuration = 6.4; maxDuration = 9.2 },
  [pscustomobject]@{ file = "stackchan_spark_safety.wav"; minDuration = 6.4; maxDuration = 9.2 }
)

$results = @()
foreach ($sample in $expected) {
  $path = Join-VoicePath $sample.file
  if (-not (Test-Path -LiteralPath $path)) {
    throw "Missing voice sample: $($sample.file)"
  }

  $info = Read-StackchanWavInfo -Path $path
  if ($info.durationSeconds -lt $sample.minDuration -or $info.durationSeconds -gt $sample.maxDuration) {
    throw "Voice sample duration out of expected Stackchan Spark range for $($sample.file): $($info.durationSeconds)s"
  }

  if ($info.peak -lt 0.10) {
    throw "Voice sample peak is too low for $($sample.file): $($info.peak)"
  }

  if ($info.rms -lt 0.010) {
    throw "Voice sample RMS is too low for $($sample.file): $($info.rms)"
  }

  $results += $info
}

$notesPath = Join-VoicePath "VOICE_SAMPLES.md"
if (-not (Test-Path -LiteralPath $notesPath)) {
  throw "Missing voice sample notes: VOICE_SAMPLES.md"
}

$notes = Get-Content -LiteralPath $notesPath -Raw
foreach ($pattern in @(
  "Stackchan Spark Synth v2",
  "eSpeak-NG",
  "formant source",
  "phrase-level micro-prosody",
  "staccato amplitude shaping",
  "sample-hold texture",
  "comb-filter resonance",
  "tiny synthetic chirps",
  "not a Johnny 5 clone",
  "not trained from soundboard clips"
)) {
  Assert-TextContains -Text $notes -Pattern $pattern -Name "VOICE_SAMPLES.md"
}

$results | ConvertTo-Json -Depth 3
Write-Host "Voice samples verified:"
Write-Host $voiceRootPath
