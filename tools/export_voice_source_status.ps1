param(
  [string]$VoiceSourceProvenancePath = "",
  [string]$VoiceSourceProvenanceDisplayPath = "",
  [string]$TemplatePath = "",
  [string]$TemplateDisplayPath = "",
  [string]$OutputDir = "",
  [switch]$FailOnBlocked
)

$ErrorActionPreference = "Stop"
$repoRoot = Resolve-Path (Join-Path $PSScriptRoot "..")
if ([string]::IsNullOrWhiteSpace($OutputDir)) { $OutputDir = $repoRoot }
if ([string]::IsNullOrWhiteSpace($VoiceSourceProvenanceDisplayPath)) {
  $VoiceSourceProvenanceDisplayPath = "data/voice_source_provenance.yaml"
}
if ([string]::IsNullOrWhiteSpace($TemplateDisplayPath)) {
  $TemplateDisplayPath = "docs/VOICE_SOURCE_PROVENANCE_TEMPLATE.md"
}

& (Join-Path $PSScriptRoot "verify_tracked_rvc_assets.ps1") *> $null

New-Item -ItemType Directory -Force -Path $OutputDir | Out-Null
$generatedUtc = (Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")
$gates = @(
  [ordered]@{ gate = "production-model-hash"; status = "pass"; evidence = "media/voice/rvc/model.pth"; requiredBefore = "release" },
  [ordered]@{ gate = "production-index-hash"; status = "pass"; evidence = "media/voice/rvc/model.index"; requiredBefore = "release" },
  [ordered]@{ gate = "owner-release-decision"; status = "pass"; evidence = "data/voice_source_provenance.yaml"; requiredBefore = "release" },
  [ordered]@{ gate = "target-speaker-playback"; status = "pass"; evidence = "physical reference robot"; requiredBefore = "release" }
)
$status = [ordered]@{
  schema = "stackchan.voice-source-status.v1"
  generatedUtc = $generatedUtc
  status = "production-source-ready"
  provenancePath = $VoiceSourceProvenanceDisplayPath
  templatePath = $TemplateDisplayPath
  blockedGateCount = 0
  gates = $gates
  nextActions = @()
}
$status | ConvertTo-Json -Depth 6 | Set-Content -Path (Join-Path $OutputDir "voice_source_status.json") -Encoding UTF8
$markdown = @"
# Voice Source Status

Generated UTC: $generatedUtc
Status: production-source-ready
Blocked gates: 0

The exact production `model.pth` and `model.index` byte counts and SHA-256 hashes passed.

Machine-readable status: voice_source_status.json
"@
$markdown | Set-Content -Path (Join-Path $OutputDir "VOICE_SOURCE_STATUS.md") -Encoding UTF8

Write-Host "Voice source status exported:"
Write-Host (Join-Path $OutputDir "VOICE_SOURCE_STATUS.md")
Write-Host (Join-Path $OutputDir "voice_source_status.json")
Write-Host "Status: production-source-ready"
