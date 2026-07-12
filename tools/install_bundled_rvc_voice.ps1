[CmdletBinding()]
param(
  [string]$SourceDirectory = "media/voice/rvc",
  [string]$Destination = "output/voice_sources/stackchan_rvc_base/model"
)

$ErrorActionPreference = "Stop"
$repoRoot = Split-Path -Parent $PSScriptRoot
$sourcePath = Join-Path $repoRoot $SourceDirectory
$destinationPath = Join-Path $repoRoot $Destination

$sourceModel = Join-Path $sourcePath "model.pth"
$sourceIndex = Join-Path $sourcePath "model.index"
if (-not (Test-Path -LiteralPath $sourceModel -PathType Leaf) -or
    -not (Test-Path -LiteralPath $sourceIndex -PathType Leaf)) {
  throw "Missing bundled RVC model files under $sourcePath. Run 'git lfs pull' and retry."
}

New-Item -ItemType Directory -Force -Path $destinationPath | Out-Null
Copy-Item -LiteralPath $sourceModel -Destination (Join-Path $destinationPath "model.pth") -Force
Copy-Item -LiteralPath $sourceIndex -Destination (Join-Path $destinationPath "model.index") -Force

$model = Join-Path $destinationPath "model.pth"
$index = Join-Path $destinationPath "model.index"
if (-not (Test-Path -LiteralPath $model -PathType Leaf) -or
    -not (Test-Path -LiteralPath $index -PathType Leaf)) {
  throw "The bundled archive did not produce model.pth and model.index."
}

[pscustomobject]@{
  status = "ready"
  model = $model
  index = $index
} | ConvertTo-Json
