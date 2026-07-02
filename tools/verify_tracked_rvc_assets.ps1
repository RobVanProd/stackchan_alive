param(
  [string]$VoiceRoot = "media/voice/rvc"
)

$ErrorActionPreference = "Stop"

$repoRoot = Resolve-Path (Join-Path $PSScriptRoot "..")
Set-Location $repoRoot

if (-not (Test-Path -LiteralPath $VoiceRoot)) {
  throw "Missing tracked RVC voice asset directory: $VoiceRoot"
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
    throw "Missing tracked RVC asset: $RelativePath"
  }
  $item = Get-Item -LiteralPath $path
  if ($item.Length -lt $MinBytes) {
    throw "Tracked RVC asset is too small: $RelativePath ($($item.Length) bytes)"
  }
}

function Assert-Mp3File {
  param(
    [string]$RelativePath,
    [int64]$MinBytes = 50000
  )

  Assert-File $RelativePath $MinBytes
  $bytes = [System.IO.File]::ReadAllBytes((Join-VoicePath $RelativePath))
  $hasId3 = $bytes.Length -ge 3 -and $bytes[0] -eq 0x49 -and $bytes[1] -eq 0x44 -and $bytes[2] -eq 0x33
  $hasFrameSync = $bytes.Length -ge 2 -and $bytes[0] -eq 0xff -and (($bytes[1] -band 0xe0) -eq 0xe0)
  if (-not ($hasId3 -or $hasFrameSync)) {
    throw "Tracked RVC MP3 has no ID3 tag or MPEG frame sync: $RelativePath"
  }
}

$samples = @(
  [pscustomobject]@{
    File = "stackchan_rvc_bright_robot.mp3"
    Title = "RVC Bright Robot"
    Transcript = "Hello. I am Stackchan, and I am awake."
  },
  [pscustomobject]@{
    File = "stackchan_rvc_thinking_neutral.mp3"
    Title = "RVC Thinking"
    Transcript = "Input received. I am thinking now. Curiosity level rising."
  },
  [pscustomobject]@{
    File = "stackchan_rvc_safety_neutral.mp3"
    Title = "RVC Safety"
    Transcript = "Small problem found. I can help fix it. Safety first."
  }
)

Assert-File "README.md" 400
Assert-File "RVC_AUDITION.html" 1000

$readme = Get-Content -LiteralPath (Join-VoicePath "README.md") -Raw
$page = Get-Content -LiteralPath (Join-VoicePath "RVC_AUDITION.html") -Raw

foreach ($pattern in @(
  "Stackchan RVC MP3 Auditions",
  "RVC_AUDITION.html",
  "review-only candidate samples",
  "source provenance and rights review"
)) {
  if ($readme -notmatch [regex]::Escape($pattern)) {
    throw "RVC README missing expected marker: $pattern"
  }
}

foreach ($pattern in @(
  "Stackchan RVC Voice Audition",
  "Review-only RVC candidate samples",
  "source provenance and rights review"
)) {
  if ($page -notmatch [regex]::Escape($pattern)) {
    throw "RVC audition page missing expected marker: $pattern"
  }
}

foreach ($sample in $samples) {
  Assert-Mp3File $sample.File
  foreach ($pattern in @($sample.File, $sample.Title, $sample.Transcript)) {
    if ($readme -notmatch [regex]::Escape($sample.File) -and $pattern -eq $sample.File) {
      throw "RVC README missing expected MP3 file: $($sample.File)"
    }
    if ($page -notmatch [regex]::Escape($pattern)) {
      throw "RVC audition page missing expected sample marker: $pattern"
    }
  }
}

Write-Host "Tracked RVC MP3 audition assets verified:"
Write-Host $voiceRootPath
