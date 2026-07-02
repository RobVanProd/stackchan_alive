param(
  [string]$VoiceRoot = "output/voice_auditions/rvc_base/final"
)

$ErrorActionPreference = "Stop"

$repoRoot = Resolve-Path (Join-Path $PSScriptRoot "..")
Set-Location $repoRoot

if (-not (Test-Path -LiteralPath $VoiceRoot)) {
  throw "Missing RVC audition directory: $VoiceRoot"
}

$voiceRootPath = (Resolve-Path $VoiceRoot).Path

function Join-VoicePath {
  param([string]$RelativePath)
  return Join-Path $voiceRootPath $RelativePath
}

function Assert-File {
  param(
    [string]$RelativePath,
    [int64]$MinBytes = 1
  )

  $path = Join-VoicePath $RelativePath
  if (-not (Test-Path -LiteralPath $path)) {
    throw "Missing RVC audition artifact: $RelativePath"
  }

  $item = Get-Item -LiteralPath $path
  if ($item.Length -lt $MinBytes) {
    throw "RVC audition artifact is too small: $RelativePath"
  }
}

function Get-WavInfo {
  param([string]$Path)

  $stream = [System.IO.File]::OpenRead($Path)
  try {
    $reader = New-Object System.IO.BinaryReader($stream)
    $riff = [System.Text.Encoding]::ASCII.GetString($reader.ReadBytes(4))
    if ($riff -ne "RIFF") {
      throw "RVC audition is not RIFF WAV: $Path"
    }
    [void]$reader.ReadUInt32()
    $wave = [System.Text.Encoding]::ASCII.GetString($reader.ReadBytes(4))
    if ($wave -ne "WAVE") {
      throw "RVC audition is not WAVE: $Path"
    }

    $fmtFound = $false
    $dataBytes = 0
    $channels = 0
    $sampleRate = 0
    $bitsPerSample = 0
    while ($stream.Position -lt $stream.Length) {
      $chunkIdBytes = $reader.ReadBytes(4)
      if ($chunkIdBytes.Length -lt 4) { break }
      $chunkId = [System.Text.Encoding]::ASCII.GetString($chunkIdBytes)
      $chunkSize = $reader.ReadUInt32()
      $chunkStart = $stream.Position

      if ($chunkId -eq "fmt ") {
        $audioFormat = $reader.ReadUInt16()
        $channels = $reader.ReadUInt16()
        $sampleRate = [int]$reader.ReadUInt32()
        [void]$reader.ReadUInt32()
        [void]$reader.ReadUInt16()
        $bitsPerSample = $reader.ReadUInt16()
        if ($audioFormat -ne 1) {
          throw "RVC audition must be PCM WAV: $Path"
        }
        $fmtFound = $true
      } elseif ($chunkId -eq "data") {
        $dataBytes = [int64]$chunkSize
      }

      $stream.Position = $chunkStart + $chunkSize
      if (($chunkSize % 2) -eq 1 -and $stream.Position -lt $stream.Length) {
        $stream.Position += 1
      }
    }

    if (-not $fmtFound -or $dataBytes -le 0) {
      throw "RVC audition WAV missing fmt or data chunk: $Path"
    }

    $bytesPerFrame = [Math]::Max(1, $channels * ($bitsPerSample / 8))
    $durationSeconds = [Math]::Round($dataBytes / ($sampleRate * $bytesPerFrame), 3)
    return [pscustomobject]@{
      path = $Path
      sampleRate = $sampleRate
      channels = $channels
      bitsPerSample = $bitsPerSample
      durationSeconds = $durationSeconds
      bytes = (Get-Item -LiteralPath $Path).Length
    }
  } finally {
    $stream.Dispose()
  }
}

$expectedWavs = @(
  [pscustomobject]@{ File = "stackchan_rvc_neutral.wav"; MinDuration = 4.6; MaxDuration = 6.5 },
  [pscustomobject]@{ File = "stackchan_rvc_warm_slow.wav"; MinDuration = 5.0; MaxDuration = 7.0 },
  [pscustomobject]@{ File = "stackchan_rvc_bright_robot.wav"; MinDuration = 4.6; MaxDuration = 6.5 },
  [pscustomobject]@{ File = "stackchan_rvc_spark_boops.wav"; MinDuration = 4.6; MaxDuration = 6.5 },
  [pscustomobject]@{ File = "stackchan_rvc_high_character.wav"; MinDuration = 4.6; MaxDuration = 6.5 },
  [pscustomobject]@{ File = "stackchan_rvc_thinking_neutral.wav"; MinDuration = 6.4; MaxDuration = 8.4 },
  [pscustomobject]@{ File = "stackchan_rvc_safety_neutral.wav"; MinDuration = 6.4; MaxDuration = 8.4 }
)

Assert-File "RVC_AUDITIONS.md" 500
Assert-File "RVC_AUDITIONS.json" 500

$notes = Get-Content -LiteralPath (Join-VoicePath "RVC_AUDITIONS.md") -Raw
$json = Get-Content -LiteralPath (Join-VoicePath "RVC_AUDITIONS.json") -Raw | ConvertFrom-Json

foreach ($pattern in @("Stackchan RVC Base Auditions", "Review-only auditions", "not consumer-approved", "RVC Neutral", "RVC Warm Slow", "RVC Bright Robot", "RVC Spark Boops", "RVC High Character")) {
  if ($notes -notmatch [regex]::Escape($pattern)) {
    throw "RVC_AUDITIONS.md missing expected marker: $pattern"
  }
}

if ($json.schema -ne "stackchan.rvc-audition-manifest.v1") {
  throw "RVC_AUDITIONS.json schema mismatch: $($json.schema)"
}
if ($json.status -ne "review-only-candidate") {
  throw "RVC_AUDITIONS.json status mismatch: $($json.status)"
}

$infos = @()
foreach ($expected in $expectedWavs) {
  Assert-File $expected.File 100000
  if ($notes -notmatch [regex]::Escape($expected.File)) {
    throw "RVC_AUDITIONS.md missing file: $($expected.File)"
  }
  $renderedMatch = @($json.rendered | Where-Object { $_.file -eq $expected.File })
  if ($renderedMatch.Count -ne 1) {
    throw "RVC_AUDITIONS.json missing rendered entry for $($expected.File)"
  }

  $info = Get-WavInfo (Join-VoicePath $expected.File)
  if ($info.sampleRate -ne 48000) {
    throw "RVC audition sample rate mismatch for $($expected.File): $($info.sampleRate)"
  }
  if ($info.channels -ne 1) {
    throw "RVC audition must be mono: $($expected.File)"
  }
  if ($info.bitsPerSample -ne 16) {
    throw "RVC audition must be 16-bit PCM: $($expected.File)"
  }
  if ($info.durationSeconds -lt $expected.MinDuration -or $info.durationSeconds -gt $expected.MaxDuration) {
    throw "RVC audition duration out of range for $($expected.File): $($info.durationSeconds)s"
  }
  $infos += $info
}

$infos | ConvertTo-Json -Depth 4
Write-Host "RVC auditions verified:"
Write-Host $voiceRootPath
