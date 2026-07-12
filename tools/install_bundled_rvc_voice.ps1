[CmdletBinding()]
param(
  [string]$ArchivePath = "media/voice/rvc/stackchan_voice_weightsgg_model.zip",
  [string]$Destination = "output/voice_sources/stackchan_rvc_base/model"
)

$ErrorActionPreference = "Stop"
$repoRoot = Split-Path -Parent $PSScriptRoot
$archive = Join-Path $repoRoot $ArchivePath
$destinationPath = Join-Path $repoRoot $Destination

if (-not (Test-Path -LiteralPath $archive -PathType Leaf)) {
  throw "Missing bundled RVC archive: $archive. Run 'git lfs pull' and retry."
}

New-Item -ItemType Directory -Force -Path $destinationPath | Out-Null
Expand-Archive -LiteralPath $archive -DestinationPath $destinationPath -Force

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
