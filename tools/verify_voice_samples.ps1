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

function Assert-StackchanMp3 {
  param(
    [string]$File,
    [int64]$MinBytes
  )

  $path = Join-VoicePath $File
  if (-not (Test-Path -LiteralPath $path)) {
    throw "Missing MP3 voice sample: $File"
  }

  $bytes = [System.IO.File]::ReadAllBytes($path)
  if ($bytes.Length -lt $MinBytes) {
    throw "MP3 voice sample is too small: $File ($($bytes.Length) bytes)"
  }

  $hasId3 = $bytes.Length -ge 3 -and $bytes[0] -eq 0x49 -and $bytes[1] -eq 0x44 -and $bytes[2] -eq 0x33
  $hasFrameSync = $bytes.Length -ge 2 -and $bytes[0] -eq 0xff -and (($bytes[1] -band 0xe0) -eq 0xe0)
  if (-not ($hasId3 -or $hasFrameSync)) {
    throw "MP3 voice sample has no ID3 tag or MPEG frame sync: $File"
  }
}

$expected = @(
  [pscustomobject]@{ file = "stackchan_spark_greeting.wav"; minDuration = 4.8; maxDuration = 7.1 },
  [pscustomobject]@{ file = "stackchan_spark_thinking.wav"; minDuration = 6.4; maxDuration = 9.2 },
  [pscustomobject]@{ file = "stackchan_spark_safety.wav"; minDuration = 6.4; maxDuration = 9.2 },
  [pscustomobject]@{ file = "stackchan_spark_audition_warm_slow_greeting.wav"; minDuration = 5.4; maxDuration = 8.1 },
  [pscustomobject]@{ file = "stackchan_spark_audition_bright_robot_greeting.wav"; minDuration = 4.8; maxDuration = 7.1 }
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

Assert-StackchanMp3 -File "stackchan_spark_audition_bright_robot_greeting.mp3" -MinBytes 50000
Assert-StackchanMp3 -File "stackchan_spark_thinking.mp3" -MinBytes 50000

$notesPath = Join-VoicePath "VOICE_SAMPLES.md"
if (-not (Test-Path -LiteralPath $notesPath)) {
  throw "Missing voice sample notes: VOICE_SAMPLES.md"
}

$auditionPagePath = Join-VoicePath "VOICE_AUDITION.html"
if (-not (Test-Path -LiteralPath $auditionPagePath)) {
  throw "Missing voice audition page: VOICE_AUDITION.html"
}

$notes = Get-Content -LiteralPath $notesPath -Raw
foreach ($pattern in @(
  "Stackchan Spark Synth v4",
  "eSpeak-NG",
  "formant source",
  "phrase-level micro-prosody",
  "syllable gating",
  "speech-envelope electromechanical mask",
  "formant-like resonators",
  "sample-hold texture",
  "comb-filter resonance",
  "tiny synthetic chirps",
  "light musical vocoder blend",
  "phrase-timed chirp/boop accents",
  "Quick MP3 copies",
  "browser-friendly copy",
  "Audition variants",
  "warmer, slightly slower",
  "brighter synthetic",
  "not a Johnny 5 clone",
  "not trained from soundboard clips"
)) {
  Assert-TextContains -Text $notes -Pattern $pattern -Name "VOICE_SAMPLES.md"
}

$auditionPage = Get-Content -LiteralPath $auditionPagePath -Raw
foreach ($pattern in @(
  "Stackchan Spark Voice Audition",
  "stackchan_spark_audition_bright_robot_greeting.mp3",
  "stackchan_spark_audition_bright_robot_greeting.wav",
  "stackchan_spark_thinking.mp3",
  "stackchan_spark_thinking.wav",
  "Hello. I am Stackchan, and I am awake.",
  "Input received. I am thinking now. Curiosity level rising.",
  "production rollout remains blocked"
)) {
  Assert-TextContains -Text $auditionPage -Pattern $pattern -Name "VOICE_AUDITION.html"
}

$results | ConvertTo-Json -Depth 3
Write-Host "Voice samples verified:"
Write-Host $voiceRootPath
