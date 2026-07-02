param(
  [string]$VoiceSourceProvenancePath = "",
  [string]$TemplatePath = "",
  [string]$OutputDir = "",
  [switch]$FailOnBlocked
)

$ErrorActionPreference = "Stop"

$repoRoot = Resolve-Path (Join-Path $PSScriptRoot "..")
Set-Location $repoRoot

if ([string]::IsNullOrWhiteSpace($VoiceSourceProvenancePath)) {
  $VoiceSourceProvenancePath = Join-Path $repoRoot "data/voice_source_provenance.yaml"
}
if ([string]::IsNullOrWhiteSpace($TemplatePath)) {
  $TemplatePath = Join-Path $repoRoot "docs/VOICE_SOURCE_PROVENANCE_TEMPLATE.md"
}
if ([string]::IsNullOrWhiteSpace($OutputDir)) {
  $OutputDir = $repoRoot
}

if (-not (Test-Path -LiteralPath $VoiceSourceProvenancePath)) {
  throw "Missing voice source provenance YAML: $VoiceSourceProvenancePath"
}
if (-not (Test-Path -LiteralPath $TemplatePath)) {
  throw "Missing voice source provenance template: $TemplatePath"
}
New-Item -ItemType Directory -Force -Path $OutputDir | Out-Null

$yaml = Get-Content -LiteralPath $VoiceSourceProvenancePath -Raw
$template = Get-Content -LiteralPath $TemplatePath -Raw
$generatedUtc = (Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")

function Get-YamlScalar {
  param(
    [string]$Text,
    [string]$Field
  )

  $escaped = [regex]::Escape($Field)
  $matches = [regex]::Matches($Text, "(?m)^\s*$escaped\s*:\s*(.*?)\s*$")
  if ($matches.Count -lt 1) {
    return ""
  }
  return $matches[$matches.Count - 1].Groups[1].Value.Trim()
}

function Test-ReadyText {
  param([string]$Value)

  if ([string]::IsNullOrWhiteSpace($Value)) {
    return $false
  }
  return ($Value -notmatch "(?i)\b(TBD|pending|required-before|required before|required-before-use|not approved|blocked)\b")
}

function New-Gate {
  param(
    [string]$Gate,
    [string]$Status,
    [string]$Evidence,
    [string]$RequiredBefore = "consumer-rollout"
  )

  return [pscustomobject][ordered]@{
    gate = $Gate
    status = $Status
    evidence = $Evidence
    requiredBefore = $RequiredBefore
  }
}

$gates = New-Object System.Collections.Generic.List[object]
$sourceStatus = if ($yaml -match "(?m)^status\s*:\s*(.*?)\s*$") { $Matches[1].Trim() } else { "" }
$rolloutGate = Get-YamlScalar $yaml "rollout_gate"

if ($sourceStatus -eq "pending-production-source") {
  $gates.Add((New-Gate "production-source-selected" "blocked" "data/voice_source_provenance.yaml status is pending-production-source")) | Out-Null
} else {
  $gates.Add((New-Gate "production-source-selected" "pass" "data/voice_source_provenance.yaml status: $sourceStatus")) | Out-Null
}

foreach ($field in @(
  "provider",
  "owner_or_consent_contact",
  "license_or_consent_evidence",
  "commercial_device_use",
  "generated_prompt_distribution",
  "model_training_or_finetuning"
)) {
  $value = Get-YamlScalar $yaml $field
  if (Test-ReadyText $value) {
    $gates.Add((New-Gate "production-source-$field" "pass" "$field`: $value")) | Out-Null
  } else {
    $gates.Add((New-Gate "production-source-$field" "blocked" "$field is missing or still a placeholder: $value")) | Out-Null
  }
}

if ($yaml -match "rvc_candidate_base:\s*(?:.|\n)*?status:\s*candidate-pending-rights-review") {
  $gates.Add((New-Gate "rvc-candidate-rights-review" "blocked" "RVC candidate remains candidate-pending-rights-review; do not use for bundled consumer release")) | Out-Null
} else {
  $gates.Add((New-Gate "rvc-candidate-rights-review" "pass" "No pending RVC candidate rights-review marker found")) | Out-Null
}

if ($rolloutGate -match "(?i)^blocked") {
  $gates.Add((New-Gate "rollout-gate-open" "blocked" "rollout_gate: $rolloutGate")) | Out-Null
} else {
  $gates.Add((New-Gate "rollout-gate-open" "pass" "rollout_gate: $rolloutGate")) | Out-Null
}

$blankTemplateFields = @(
  [regex]::Matches($template, "(?m)^-\s+([^:\r\n]+):\s*$") |
    ForEach-Object { $_.Groups[1].Value.Trim() }
)
$uncheckedTemplateBoxes = @([regex]::Matches($template, "(?m)^-\s+\[ \]\s+(.+)$"))

if ($blankTemplateFields.Count -gt 0) {
  $gates.Add((New-Gate "provenance-template-fields-complete" "blocked" "Blank template fields: $($blankTemplateFields.Count)")) | Out-Null
} else {
  $gates.Add((New-Gate "provenance-template-fields-complete" "pass" "No blank template fields detected")) | Out-Null
}

if ($uncheckedTemplateBoxes.Count -gt 0) {
  $gates.Add((New-Gate "provenance-template-attestations-complete" "blocked" "Unchecked attestations: $($uncheckedTemplateBoxes.Count)")) | Out-Null
} else {
  $gates.Add((New-Gate "provenance-template-attestations-complete" "pass" "All attestations checked")) | Out-Null
}

$blockedGates = @($gates | Where-Object { $_.status -eq "blocked" })
$overallStatus = if ($blockedGates.Count -eq 0) {
  "production-source-ready"
} else {
  "blocked-pending-production-voice-source"
}

$gateArray = @($gates | ForEach-Object { $_ })
$statusObject = [ordered]@{
  schema = "stackchan.voice-source-status.v1"
  generatedUtc = $generatedUtc
  status = $overallStatus
  provenancePath = $VoiceSourceProvenancePath
  templatePath = $TemplatePath
  blockedGateCount = $blockedGates.Count
  gates = $gateArray
  nextActions = @(
    "Replace review-only prototype/RVC candidate status with a licensed or owned production source.",
    "Record owner/contact, license or consent evidence, commercial/device-use permission, generated-prompt distribution permission, and model-training/fine-tuning terms.",
    "Complete docs/VOICE_SOURCE_PROVENANCE_TEMPLATE.md with checked source attestations.",
    "Capture target-speaker audio evidence on the physical device before consumer rollout."
  )
}

$jsonPath = Join-Path $OutputDir "voice_source_status.json"
$mdPath = Join-Path $OutputDir "VOICE_SOURCE_STATUS.md"
$statusObject | ConvertTo-Json -Depth 8 | Set-Content -Path $jsonPath -Encoding UTF8

$gateLines = @($gates | ForEach-Object {
  $mark = if ($_.status -eq "pass") { "[x]" } else { "[ ]" }
  "- $mark ``$($_.gate)`` - $($_.status): $($_.evidence)"
})

@"
# Voice Source Status

Generated UTC: $generatedUtc
Status: $overallStatus
Blocked gates: $($blockedGates.Count)

This report is generated from ``data/voice_source_provenance.yaml`` and ``docs/VOICE_SOURCE_PROVENANCE_TEMPLATE.md``. Current prototype and RVC audition samples are review-only until every blocked gate below is cleared.

## Gates

$($gateLines -join [Environment]::NewLine)

## Next Actions

- Replace the review-only source with a licensed or owned production voice source.
- Record rights owner/contact, license or consent evidence, commercial/device-use permission, generated-prompt distribution permission, and model-training/fine-tuning terms.
- Complete the voice-source provenance template and source attestations.
- Capture target-speaker audio evidence on the physical device before consumer rollout.

Machine-readable status: ``voice_source_status.json``
"@ | Set-Content -Path $mdPath -Encoding UTF8

Write-Host "Voice source status exported:"
Write-Host $mdPath
Write-Host $jsonPath
Write-Host "Status: $overallStatus"

if ($FailOnBlocked -and $blockedGates.Count -gt 0) {
  exit 2
}
