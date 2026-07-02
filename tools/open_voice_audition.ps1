param(
  [switch]$Rvc,
  [switch]$PrintOnly
)

$ErrorActionPreference = "Stop"

$root = Resolve-Path (Join-Path $PSScriptRoot "..")
$pageName = if ($Rvc) { "RVC_AUDITION.html" } else { "VOICE_AUDITION.html" }
$candidates = if ($Rvc) {
  @(
    (Join-Path $root "media/voice/rvc/$pageName"),
    (Join-Path $root "output/voice_auditions/rvc_base/final/$pageName")
  )
} else {
  @(
    (Join-Path $root "docs/media/voice/$pageName"),
    (Join-Path $root "media/voice/$pageName")
  )
}

$auditionPath = ""
foreach ($candidate in $candidates) {
  if (Test-Path -LiteralPath $candidate) {
    $auditionPath = (Resolve-Path $candidate).Path
    break
  }
}

if ([string]::IsNullOrWhiteSpace($auditionPath)) {
  if ($Rvc) {
    throw "Missing Stackchan RVC audition page. Run tools/render_rvc_audition_mp3s.cmd in the repo, or use a verified release package that includes media/voice/rvc/RVC_AUDITION.html."
  }
  throw "Missing Stackchan voice audition page. Run tools/render_voice_samples.cmd in the repo, or use a verified release package that includes media/voice/VOICE_AUDITION.html."
}

if ($Rvc) {
  Write-Host "Stackchan RVC voice audition page:"
} else {
  Write-Host "Stackchan voice audition page:"
}
Write-Host $auditionPath

if (-not $PrintOnly) {
  Start-Process $auditionPath
}
