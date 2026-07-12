param(
  [string]$VoiceRoot = "media/voice/rvc"
)

$ErrorActionPreference = "Stop"
$repoRoot = Resolve-Path (Join-Path $PSScriptRoot "..")
Set-Location $repoRoot

$expected = [ordered]@{
  "model.pth" = [ordered]@{
    bytes = 57577722
    sha256 = "1A8ADDFD670CD811D1AD1EEB9E9B4FF72C5D795B1123A23E86A0C41C1DD9BF1A"
  }
  "model.index" = [ordered]@{
    bytes = 99428699
    sha256 = "DA0EDB00FB15E8CEEC135B261F32E5907BA570FF0D213BEF8267EB80AB167DC2"
  }
}

if (-not (Test-Path -LiteralPath $VoiceRoot -PathType Container)) {
  throw "Missing production RVC directory: $VoiceRoot"
}

$readmePath = Join-Path $VoiceRoot "README.md"
if (-not (Test-Path -LiteralPath $readmePath -PathType Leaf)) {
  throw "Missing production RVC README.md"
}

$readme = Get-Content -LiteralPath $readmePath -Raw
foreach ($pattern in @("Included Stackchan RVC Voice", "model.pth", "model.index", "install_bundled_rvc_voice.ps1")) {
  if ($readme -notmatch [regex]::Escape($pattern)) {
    throw "Production RVC README missing expected marker: $pattern"
  }
}

foreach ($entry in $expected.GetEnumerator()) {
  $path = Join-Path $VoiceRoot $entry.Key
  if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
    throw "Missing production RVC file: $path. Run 'git lfs pull' and retry."
  }
  $item = Get-Item -LiteralPath $path
  $hash = (Get-FileHash -Algorithm SHA256 -LiteralPath $path).Hash.ToUpperInvariant()
  if ($item.Length -ne [int64]$entry.Value.bytes) {
    throw "$($entry.Key) byte count mismatch: expected $($entry.Value.bytes), got $($item.Length)"
  }
  if ($hash -ne $entry.Value.sha256) {
    throw "$($entry.Key) SHA256 mismatch: expected $($entry.Value.sha256), got $hash"
  }
}

$allowedNames = @("README.md", "model.pth", "model.index")
$unexpected = @(Get-ChildItem -LiteralPath $VoiceRoot -Recurse -File | Where-Object { $allowedNames -notcontains $_.Name })
if ($unexpected.Count -gt 0) {
  throw "Production RVC directory contains unexpected files: $($unexpected.FullName -join ', ')"
}

Write-Host "Production RVC files verified:"
Write-Host (Resolve-Path $VoiceRoot).Path
