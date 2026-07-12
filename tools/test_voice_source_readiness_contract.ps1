param()

$ErrorActionPreference = "Stop"

$repoRoot = Resolve-Path (Join-Path $PSScriptRoot "..")
$checkScript = Join-Path $PSScriptRoot "check_voice_source_readiness.ps1"
$exportScript = Join-Path $PSScriptRoot "export_voice_source_status.ps1"
$createdRoots = New-Object System.Collections.Generic.List[string]

function New-TempEvidenceRoot {
  $root = Join-Path ([System.IO.Path]::GetTempPath()) ("stackchan-voice-source-contract-" + [guid]::NewGuid().ToString("N"))
  $createdRoots.Add($root) | Out-Null
  New-Item -ItemType Directory -Force -Path $root | Out-Null
  return $root
}

function Invoke-VoiceSourceCheck {
  param(
    [string]$Root,
    [string]$VoiceSourceProvenancePath,
    [string]$TemplatePath,
    [string]$SourceCommit,
    [switch]$RequireProductionReady
  )

  $powerShellExe = (Get-Process -Id $PID).Path
  $arguments = @(
    "-NoProfile",
    "-ExecutionPolicy",
    "Bypass",
    "-File",
    $checkScript,
    "-Root",
    $repoRoot,
    "-VoiceSourceProvenancePath",
    $VoiceSourceProvenancePath,
    "-TemplatePath",
    $TemplatePath,
    "-SourceCommit",
    $SourceCommit,
    "-Json"
  )
  if ($RequireProductionReady) {
    $arguments += "-RequireProductionReady"
  }

  $oldErrorActionPreference = $ErrorActionPreference
  $ErrorActionPreference = "Continue"
  try {
    $output = & $powerShellExe @arguments 2>&1
    $exitCode = $LASTEXITCODE
  } finally {
    $ErrorActionPreference = $oldErrorActionPreference
  }

  $text = ($output | Out-String).Trim()
  $report = if ([string]::IsNullOrWhiteSpace($text)) { $null } else { $text | ConvertFrom-Json }
  return [pscustomobject]@{ exitCode = $exitCode; text = $text; report = $report }
}

function Assert-CheckStatus {
  param(
    [object]$Report,
    [string]$Id,
    [string]$Status
  )

  $check = @($Report.checks | Where-Object { $_.id -eq $Id })
  if ($check.Count -ne 1) {
    throw "Expected exactly one check with id '$Id'."
  }
  if ($check[0].status -ne $Status) {
    throw "Expected check '$Id' to be '$Status', got '$($check[0].status)'. Detail: $($check[0].detail)"
  }
}

function Write-PendingVoiceSourceFiles {
  param([string]$Root)

  @"
schema: stackchan.voice-source-provenance.v1
status: pending-production-source
rvc_candidate_base:
  status: candidate-pending-rights-review
production_source:
  provider: TBD
  owner_or_consent_contact: TBD
  license_or_consent_evidence: required-before-consumer-rollout
  commercial_device_use: required-before-consumer-rollout
  generated_prompt_distribution: required-before-consumer-rollout
  model_training_or_finetuning: required-before-use
required_rollout_evidence:
  - licensed_or_owned_production_voice_source
  - completed_voice_source_provenance_template
  - target_speaker_audio_check
  - real_device_audio_video_evidence
  - hardware_evidence_verification_pass
rollout_gate: blocked-pending-licensed-or-owned-production-voice-source
"@ | Set-Content -Path (Join-Path $Root "voice_source.yaml") -Encoding UTF8

  @"
# Voice Source Provenance Template

- Status: pending production voice source
- Candidate model name or title:
- Provider:
- [ ] No soundboard clips were used as training, conversion, or reference audio.
- [ ] No named character, actor, or celebrity voice was cloned.
- [ ] No RVC character model or similar voice-conversion model was used.
- [ ] Commercial/device use allowed
- [ ] real-device audio/video evidence
"@ | Set-Content -Path (Join-Path $Root "VOICE_TEMPLATE.md") -Encoding UTF8
}

function Write-ReadyVoiceSourceFiles {
  param(
    [string]$Root,
    [string]$SourceCommit,
    [string]$RvcStatus = "rights-reviewed-approved",
    [switch]$OmitSourceCommit
  )

  $sourceCommitLine = if ($OmitSourceCommit) { "" } else { "source_commit: $SourceCommit" }
  @"
schema: stackchan.voice-source-provenance.v1
status: production-source-released
$sourceCommitLine
rvc_candidate_base:
  status: $RvcStatus
  provider: Original Stackchan voice session
production_source:
  provider: Owned studio voice session
  owner_or_consent_contact: Rob Van Productions
  license_or_consent_evidence: evidence/voice/production-consent.pdf
  model_path: media/voice/rvc/model.pth
  model_sha256: 1A8ADDFD670CD811D1AD1EEB9E9B4FF72C5D795B1123A23E86A0C41C1DD9BF1A
  index_path: media/voice/rvc/model.index
  index_sha256: DA0EDB00FB15E8CEEC135B261F32E5907BA570FF0D213BEF8267EB80AB167DC2
  commercial_device_use: allowed for Stackchan companion and robot device use
  generated_prompt_distribution: allowed for generated Stackchan prompts
  model_training_or_finetuning: allowed for project-owned model tuning only
required_rollout_evidence:
  - licensed_or_owned_production_voice_source
  - completed_voice_source_provenance_template
  - target_speaker_audio_check
  - real_device_audio_video_evidence
  - hardware_evidence_verification_pass
rollout_gate: production-ready
"@ | Set-Content -Path (Join-Path $Root "voice_source.yaml") -Encoding UTF8

  @"
# Production Voice Release Record

Stackchan: Alive releases the exact DirectML RVC files used on the reference robot.

- Model: ``media/voice/rvc/model.pth``
- Index: ``media/voice/rvc/model.index``
- Runtime: DirectML RVC
- Release record: created and owned by the repository owner, then released for public distribution

Run ``tools/verify_tracked_rvc_assets.ps1`` before packaging.
"@ | Set-Content -Path (Join-Path $Root "VOICE_TEMPLATE.md") -Encoding UTF8
}

try {
  Set-Location $repoRoot
  $sourceCommit = "b" * 40

  $pendingRoot = New-TempEvidenceRoot
  Write-PendingVoiceSourceFiles -Root $pendingRoot
  $pendingResult = Invoke-VoiceSourceCheck -Root $repoRoot -VoiceSourceProvenancePath (Join-Path $pendingRoot "voice_source.yaml") -TemplatePath (Join-Path $pendingRoot "VOICE_TEMPLATE.md") -SourceCommit $sourceCommit
  if ([int]$pendingResult.exitCode -ne 0) {
    throw "Expected pending voice-source packet to exit successfully without RequireProductionReady. Output:`n$($pendingResult.text)"
  }
  if ($pendingResult.report.status -ne "pending-production-voice-source") {
    throw "Expected pending-production-voice-source, got $($pendingResult.report.status)."
  }
  Assert-CheckStatus -Report $pendingResult.report -Id "production-source-selected" -Status "pending"
  Assert-CheckStatus -Report $pendingResult.report -Id "voice-source-provenance-commit-match" -Status "pending"
  Write-Host "[ok] pending production voice source remains pending"

  $portableExportRoot = New-TempEvidenceRoot
  $powerShellExe = (Get-Process -Id $PID).Path
  & $powerShellExe -NoProfile -ExecutionPolicy Bypass -File $exportScript `
    -VoiceSourceProvenancePath (Join-Path $pendingRoot "voice_source.yaml") `
    -VoiceSourceProvenanceDisplayPath "data/voice_source_provenance.yaml" `
    -TemplatePath (Join-Path $pendingRoot "VOICE_TEMPLATE.md") `
    -TemplateDisplayPath "docs/VOICE_SOURCE_PROVENANCE_TEMPLATE.md" `
    -OutputDir $portableExportRoot *> $null
  if ($LASTEXITCODE -ne 0) {
    throw "Expected portable voice-source status export to succeed."
  }
  $portableStatus = Get-Content -LiteralPath (Join-Path $portableExportRoot "voice_source_status.json") -Raw | ConvertFrom-Json
  if ($portableStatus.provenancePath -ne "data/voice_source_provenance.yaml" -or
      $portableStatus.templatePath -ne "docs/VOICE_SOURCE_PROVENANCE_TEMPLATE.md" -or
      [System.IO.Path]::IsPathRooted([string]$portableStatus.provenancePath) -or
      [System.IO.Path]::IsPathRooted([string]$portableStatus.templatePath)) {
    throw "Voice-source status export leaked non-portable package paths."
  }
  Write-Host "[ok] packaged voice-source status paths remain portable"

  $pendingStrictResult = Invoke-VoiceSourceCheck -Root $repoRoot -VoiceSourceProvenancePath (Join-Path $pendingRoot "voice_source.yaml") -TemplatePath (Join-Path $pendingRoot "VOICE_TEMPLATE.md") -SourceCommit $sourceCommit -RequireProductionReady
  if ([int]$pendingStrictResult.exitCode -eq 0) {
    throw "Expected pending voice-source packet to fail with RequireProductionReady."
  }
  Write-Host "[ok] pending production voice source fails strict readiness"

  $readyRoot = New-TempEvidenceRoot
  Write-ReadyVoiceSourceFiles -Root $readyRoot -SourceCommit $sourceCommit
  $readyResult = Invoke-VoiceSourceCheck -Root $repoRoot -VoiceSourceProvenancePath (Join-Path $readyRoot "voice_source.yaml") -TemplatePath (Join-Path $readyRoot "VOICE_TEMPLATE.md") -SourceCommit $sourceCommit -RequireProductionReady
  if ([int]$readyResult.exitCode -ne 0) {
    throw "Expected complete production voice source to pass. Output:`n$($readyResult.text)"
  }
  if ($readyResult.report.status -ne "production-voice-source-ready" -or $readyResult.report.voiceSourceCommit -ne $sourceCommit) {
    throw "Expected production-voice-source-ready and matching voiceSourceCommit."
  }
  foreach ($id in @("production-source-selected", "voice-source-provenance-commit-match", "production-source-provider", "rvc-candidate-rights-review", "voice-rollout-gate", "voice-template-fields-complete", "voice-template-attestations-complete")) {
    Assert-CheckStatus -Report $readyResult.report -Id $id -Status "pass"
  }
  Write-Host "[ok] complete production voice source is accepted"

  $staleRoot = New-TempEvidenceRoot
  Write-ReadyVoiceSourceFiles -Root $staleRoot -SourceCommit ("c" * 40)
  $staleResult = Invoke-VoiceSourceCheck -Root $repoRoot -VoiceSourceProvenancePath (Join-Path $staleRoot "voice_source.yaml") -TemplatePath (Join-Path $staleRoot "VOICE_TEMPLATE.md") -SourceCommit $sourceCommit -RequireProductionReady
  if ([int]$staleResult.exitCode -ne 0) {
    throw "Expected a fixed voice-source commit to remain valid across later package commits. Output:`n$($staleResult.text)"
  }
  Assert-CheckStatus -Report $staleResult.report -Id "voice-source-provenance-commit-match" -Status "pass"
  Write-Host "[ok] fixed voice-source commit remains valid across later package commits"

  $missingCommitRoot = New-TempEvidenceRoot
  Write-ReadyVoiceSourceFiles -Root $missingCommitRoot -SourceCommit $sourceCommit -OmitSourceCommit
  $missingCommitResult = Invoke-VoiceSourceCheck -Root $repoRoot -VoiceSourceProvenancePath (Join-Path $missingCommitRoot "voice_source.yaml") -TemplatePath (Join-Path $missingCommitRoot "VOICE_TEMPLATE.md") -SourceCommit $sourceCommit -RequireProductionReady
  if ([int]$missingCommitResult.exitCode -eq 0) {
    throw "Expected production voice-source provenance without source_commit to fail."
  }
  Assert-CheckStatus -Report $missingCommitResult.report -Id "voice-source-provenance-commit-match" -Status "fail"
  Write-Host "[ok] missing production voice-source provenance commit is rejected"

  $rvcPendingRoot = New-TempEvidenceRoot
  Write-ReadyVoiceSourceFiles -Root $rvcPendingRoot -SourceCommit $sourceCommit -RvcStatus "candidate-pending-rights-review"
  $rvcPendingResult = Invoke-VoiceSourceCheck -Root $repoRoot -VoiceSourceProvenancePath (Join-Path $rvcPendingRoot "voice_source.yaml") -TemplatePath (Join-Path $rvcPendingRoot "VOICE_TEMPLATE.md") -SourceCommit $sourceCommit -RequireProductionReady
  if ([int]$rvcPendingResult.exitCode -eq 0) {
    throw "Expected production voice-source packet with unresolved RVC rights to fail strict readiness."
  }
  Assert-CheckStatus -Report $rvcPendingResult.report -Id "rvc-candidate-rights-review" -Status "pending"
  Write-Host "[ok] unresolved RVC rights review prevents production voice-source readiness"

  Write-Host "Voice source readiness contract tests passed."
} finally {
  foreach ($root in $createdRoots) {
    if (Test-Path -LiteralPath $root) {
      Remove-Item -LiteralPath $root -Recurse -Force
    }
  }
}
