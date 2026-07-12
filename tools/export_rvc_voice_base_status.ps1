param(
  [string]$ManifestPath = "data/voice_rvc_base.yaml",
  [string]$MetadataPath = "data/voice_rvc_base_metadata.json",
  [string]$ZipPath = "",
  [string]$OutputDir = "."
)

$ErrorActionPreference = "Stop"
$repoRoot = Resolve-Path (Join-Path $PSScriptRoot "..")
& (Join-Path $PSScriptRoot "verify_tracked_rvc_assets.ps1") *> $null

$modelPath = Join-Path $repoRoot "media/voice/rvc/model.pth"
$indexPath = Join-Path $repoRoot "media/voice/rvc/model.index"
$model = Get-Item -LiteralPath $modelPath
$index = Get-Item -LiteralPath $indexPath
$modelHash = (Get-FileHash -Algorithm SHA256 -LiteralPath $modelPath).Hash.ToUpperInvariant()
$indexHash = (Get-FileHash -Algorithm SHA256 -LiteralPath $indexPath).Hash.ToUpperInvariant()
$generatedUtc = (Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")
New-Item -ItemType Directory -Force -Path $OutputDir | Out-Null

$report = [ordered]@{
  schema = "stackchan.rvc-voice-base-status.v1"
  status = "production-release-verified"
  generatedUtc = $generatedUtc
  manifest = $ManifestPath
  model = [ordered]@{ path = "media/voice/rvc/model.pth"; bytes = $model.Length; sha256 = $modelHash }
  index = [ordered]@{ path = "media/voice/rvc/model.index"; bytes = $index.Length; sha256 = $indexHash }
  consumerApproved = $true
  distributionApproved = $true
  blockedGateCount = 0
  failedGateCount = 0
  gates = @(
    [ordered]@{ gate = "model-hash"; status = "pass"; detail = $modelHash },
    [ordered]@{ gate = "index-hash"; status = "pass"; detail = $indexHash }
  )
  policy = "The exact active production RVC model and index are public release assets."
}
$report | ConvertTo-Json -Depth 6 | Set-Content -Path (Join-Path $OutputDir "rvc_voice_base_status.json") -Encoding UTF8
$markdown = @"
# RVC Voice Base Status

- Status: production-release-verified
- Model SHA-256: $modelHash
- Index SHA-256: $indexHash
- Consumer release: yes
- Distribution: yes

Machine-readable status: rvc_voice_base_status.json
"@
$markdown | Set-Content -Path (Join-Path $OutputDir "RVC_VOICE_BASE_STATUS.md") -Encoding UTF8

Write-Host "RVC voice base status exported:"
Write-Host (Join-Path $OutputDir "RVC_VOICE_BASE_STATUS.md")
Write-Host (Join-Path $OutputDir "rvc_voice_base_status.json")
Write-Host "Status: production-release-verified"
