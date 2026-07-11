param(
  [string]$OutDir = "output\pc-brain\full-online-status-latest",
  [string]$Operator = "Rob",
  [string]$Note = "Body was reported clear before leaving.",
  [switch]$Json
)

$ErrorActionPreference = "Stop"

$RepoRoot = Resolve-Path (Join-Path $PSScriptRoot "..")
Set-Location $RepoRoot

New-Item -ItemType Directory -Force -Path $OutDir | Out-Null
$ResolvedOutDir = (Resolve-Path $OutDir).Path
$generatedAt = (Get-Date).ToString("o")

$result = [ordered]@{
  schema = "stackchan.body-clear-attestation.v1"
  generatedAt = $generatedAt
  operator = $Operator
  note = $Note
  stillRequiresLiveOperatorConfirmation = $true
}

$jsonPath = Join-Path $ResolvedOutDir "BODY_CLEAR_ATTESTATION.json"
$markdownPath = Join-Path $ResolvedOutDir "BODY_CLEAR_ATTESTATION.md"
$result | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $jsonPath -Encoding UTF8

@(
  "# Stackchan Body Clear Attestation",
  "",
  "- Schema: ``$($result.schema)``",
  "- Generated at: ``$generatedAt``",
  "- Operator: ``$Operator``",
  "- Note: $Note",
  "- Still requires live operator confirmation before upload: ``true``",
  "",
  "This records the reported body-clear state. It does not replace ``-OperatorPresent`` or the final body-clear check immediately before flashing motor-enabled firmware."
) | Set-Content -LiteralPath $markdownPath -Encoding UTF8

if ($Json) {
  $result | ConvertTo-Json -Depth 8
} else {
  Write-Host "Body clear attestation written: $markdownPath"
}
