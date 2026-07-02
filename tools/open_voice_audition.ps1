param(
  [switch]$PrintOnly
)

$ErrorActionPreference = "Stop"

$root = Resolve-Path (Join-Path $PSScriptRoot "..")
$candidates = @(
  (Join-Path $root "docs/media/voice/VOICE_AUDITION.html"),
  (Join-Path $root "media/voice/VOICE_AUDITION.html")
)

$auditionPath = ""
foreach ($candidate in $candidates) {
  if (Test-Path -LiteralPath $candidate) {
    $auditionPath = (Resolve-Path $candidate).Path
    break
  }
}

if ([string]::IsNullOrWhiteSpace($auditionPath)) {
  throw "Missing Stackchan voice audition page. Run tools/render_voice_samples.cmd in the repo, or use a verified release package that includes media/voice/VOICE_AUDITION.html."
}

Write-Host "Stackchan voice audition page:"
Write-Host $auditionPath

if (-not $PrintOnly) {
  Start-Process $auditionPath
}
