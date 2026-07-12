param(
  [string]$VoiceRoot = "media/voice/rvc"
)

$ErrorActionPreference = "Stop"

$repoRoot = Resolve-Path (Join-Path $PSScriptRoot "..")
Set-Location $repoRoot

if (-not (Test-Path -LiteralPath $VoiceRoot -PathType Container)) {
  throw "Missing public RVC policy directory: $VoiceRoot"
}

$voiceRootPath = (Resolve-Path $VoiceRoot).Path
$readmePath = Join-Path $voiceRootPath "README.md"
if (-not (Test-Path -LiteralPath $readmePath -PathType Leaf)) {
  throw "Missing public RVC BYOM policy: README.md"
}
if ((Get-Item -LiteralPath $readmePath).Length -lt 400) {
  throw "Public RVC BYOM policy is unexpectedly small."
}

$readme = Get-Content -LiteralPath $readmePath -Raw
foreach ($pattern in @(
  "Optional Local RVC",
  "user-supplied RVC model",
  "No RVC model",
  "output/voice_auditions/",
  "not bundled"
)) {
  if ($readme -notmatch [regex]::Escape($pattern)) {
    throw "RVC BYOM policy missing expected marker: $pattern"
  }
}

$allowedNames = @("README.md")
$unexpected = @(
  Get-ChildItem -LiteralPath $voiceRootPath -Recurse -File |
    Where-Object { $allowedNames -notcontains $_.Name } |
    Select-Object -ExpandProperty FullName
)
if ($unexpected.Count -gt 0) {
  throw "Public RVC directory contains forbidden bundled assets: $($unexpected -join ', ')"
}

$forbiddenExtensions = @(".pth", ".index", ".onnx")
$forbidden = @(
  Get-ChildItem -LiteralPath $voiceRootPath -Recurse -File |
    Where-Object {
      $forbiddenExtensions -contains $_.Extension.ToLowerInvariant() -or
      $_.Name -match '(?i)weightsgg|weights\.gg|rvc.*\.(wav|mp3|html)$'
    }
)
if ($forbidden.Count -gt 0) {
  throw "Public RVC directory contains a model, index, or converted derivative."
}

Write-Host "Public RVC BYOM policy verified; no model or converted assets are bundled:"
Write-Host $voiceRootPath
