param(
  [string]$Root = "",
  [string]$VoiceSourceProvenancePath = "",
  [string]$TemplatePath = "",
  [string]$SourceCommit = "",
  [switch]$RequireProductionReady,
  [switch]$Json
)

$ErrorActionPreference = "Stop"

if ([string]::IsNullOrWhiteSpace($Root)) {
  $Root = Resolve-Path (Join-Path $PSScriptRoot "..")
} else {
  $Root = Resolve-Path $Root
}

function Join-RootPath {
  param([string]$RelativePath)
  return Join-Path $Root $RelativePath
}

if ([string]::IsNullOrWhiteSpace($VoiceSourceProvenancePath)) {
  $VoiceSourceProvenancePath = Join-RootPath "data/voice_source_provenance.yaml"
}
if ([string]::IsNullOrWhiteSpace($TemplatePath)) {
  $TemplatePath = Join-RootPath "docs/VOICE_SOURCE_PROVENANCE_TEMPLATE.md"
}

$checks = @()

function Add-Check {
  param(
    [string]$Id,
    [ValidateSet("pass", "fail", "pending")]
    [string]$Status,
    [string]$Detail,
    [string]$Evidence = ""
  )

  $script:checks += [ordered]@{
    id = $Id
    status = $Status
    detail = $Detail
    evidence = $Evidence
  }
}

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

function Get-YamlTopLevelScalar {
  param(
    [string]$Text,
    [string]$Field
  )

  $escaped = [regex]::Escape($Field)
  $match = [regex]::Match($Text, "(?m)^$escaped\s*:\s*(.*?)\s*$")
  if (-not $match.Success) {
    return ""
  }
  return $match.Groups[1].Value.Trim()
}

function Test-ReadyText {
  param([string]$Value)

  if ([string]::IsNullOrWhiteSpace($Value)) {
    return $false
  }
  return ($Value -notmatch "(?i)\b(TBD|pending|required-before|required before|required-before-use|not approved|blocked)\b")
}

function Test-Commit {
  param([string]$Value)
  return $Value -match "^[a-fA-F0-9]{40}$"
}

function Get-CurrentSourceCommit {
  try {
    $commit = (& git -C $Root rev-parse HEAD 2>$null | Select-Object -First 1)
    if (Test-Commit $commit) {
      return $commit
    }
  } catch {
  }
  return ""
}

if ([string]::IsNullOrWhiteSpace($SourceCommit)) {
  $SourceCommit = Get-CurrentSourceCommit
}

if (Test-Commit $SourceCommit) {
  Add-Check "voice-source-source-commit" "pass" "Full source commit recorded for the voice-source readiness report." ""
} else {
  Add-Check "voice-source-source-commit" "pending" "Run from a git checkout or pass -SourceCommit <40-character SHA> before using this report as final v1 evidence." ""
}

if (-not (Test-Path -LiteralPath $VoiceSourceProvenancePath -PathType Leaf)) {
  Add-Check "voice-source-provenance-file" "fail" "Missing voice source provenance YAML." $VoiceSourceProvenancePath
} else {
  Add-Check "voice-source-provenance-file" "pass" "Voice source provenance YAML exists." $VoiceSourceProvenancePath
}

if (-not (Test-Path -LiteralPath $TemplatePath -PathType Leaf)) {
  Add-Check "voice-source-template-file" "fail" "Missing voice source provenance template." $TemplatePath
} else {
  Add-Check "voice-source-template-file" "pass" "Voice source provenance template exists." $TemplatePath
}

$yaml = if (Test-Path -LiteralPath $VoiceSourceProvenancePath -PathType Leaf) {
  Get-Content -LiteralPath $VoiceSourceProvenancePath -Raw
} else {
  ""
}
$template = if (Test-Path -LiteralPath $TemplatePath -PathType Leaf) {
  Get-Content -LiteralPath $TemplatePath -Raw
} else {
  ""
}

$provenanceSourceCommit = ""
$productionSourceReady = $false

if (-not [string]::IsNullOrWhiteSpace($yaml)) {
  $schema = Get-YamlTopLevelScalar $yaml "schema"
  if ($schema -eq "stackchan.voice-source-provenance.v1") {
    Add-Check "voice-source-schema" "pass" "Schema is stackchan.voice-source-provenance.v1." $VoiceSourceProvenancePath
  } else {
    Add-Check "voice-source-schema" "fail" "Unexpected voice-source schema: $schema" $VoiceSourceProvenancePath
  }

  $status = Get-YamlTopLevelScalar $yaml "status"
  if ($status -eq "pending-production-source") {
    Add-Check "production-source-selected" "pending" "Production voice source is still pending." $VoiceSourceProvenancePath
  } elseif (Test-ReadyText $status) {
    $productionSourceReady = $true
    Add-Check "production-source-selected" "pass" "Production voice source status: $status" $VoiceSourceProvenancePath
  } else {
    Add-Check "production-source-selected" "fail" "Production voice source status is blank or invalid: $status" $VoiceSourceProvenancePath
  }

  $provenanceSourceCommit = Get-YamlTopLevelScalar $yaml "source_commit"
  if ($productionSourceReady) {
    if (Test-Commit $provenanceSourceCommit) {
      Add-Check "voice-source-provenance-commit-match" "pass" "Voice-source provenance records the fixed commit that introduced the released voice assets; the report sourceCommit independently identifies the current package/source revision." $VoiceSourceProvenancePath
    } else {
      Add-Check "voice-source-provenance-commit-match" "fail" "Released voice provenance must record its own 40-character source_commit." $VoiceSourceProvenancePath
    }
  } else {
    Add-Check "voice-source-provenance-commit-match" "pending" "Record source_commit in the completed production voice provenance YAML before consumer promotion." $VoiceSourceProvenancePath
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
      Add-Check "production-source-$field" "pass" "$field is filled." $VoiceSourceProvenancePath
    } else {
      Add-Check "production-source-$field" "pending" "$field is missing or still a placeholder: $value" $VoiceSourceProvenancePath
    }
  }

  if ($productionSourceReady) {
    foreach ($asset in @(
      @{ id = "model"; pathField = "model_path"; hashField = "model_sha256" },
      @{ id = "index"; pathField = "index_path"; hashField = "index_sha256" }
    )) {
      $relativePath = Get-YamlScalar $yaml $asset.pathField
      $expectedHash = (Get-YamlScalar $yaml $asset.hashField).ToUpperInvariant()
      $rootPath = [System.IO.Path]::GetFullPath([string]$Root)
      $assetPath = ""
      $pathSafe = -not [System.IO.Path]::IsPathRooted($relativePath)
      if ($pathSafe -and -not [string]::IsNullOrWhiteSpace($relativePath)) {
        $assetPath = [System.IO.Path]::GetFullPath((Join-Path $rootPath $relativePath))
        $rootPrefix = $rootPath.TrimEnd('\', '/') + [System.IO.Path]::DirectorySeparatorChar
        $pathSafe = $assetPath.StartsWith($rootPrefix, [System.StringComparison]::OrdinalIgnoreCase)
      }
      if (-not $pathSafe -or [string]::IsNullOrWhiteSpace($assetPath)) {
        Add-Check "production-voice-$($asset.id)-path" "fail" "Released voice asset path is missing, absolute, or escapes the repository: $relativePath" $VoiceSourceProvenancePath
      } elseif (-not (Test-Path -LiteralPath $assetPath -PathType Leaf)) {
        Add-Check "production-voice-$($asset.id)-path" "fail" "Released voice asset is missing: $relativePath" $relativePath
      } elseif ($expectedHash -notmatch "^[A-F0-9]{64}$") {
        Add-Check "production-voice-$($asset.id)-hash" "fail" "Released voice asset has no valid SHA-256 record: $($asset.hashField)" $VoiceSourceProvenancePath
      } else {
        $actualHash = (Get-FileHash -Algorithm SHA256 -LiteralPath $assetPath).Hash.ToUpperInvariant()
        if ($actualHash -eq $expectedHash) {
          Add-Check "production-voice-$($asset.id)-hash" "pass" "Released voice asset hash matches: $relativePath" $relativePath
        } else {
          Add-Check "production-voice-$($asset.id)-hash" "fail" "Released voice asset SHA-256 mismatch: $relativePath" $relativePath
        }
      }
    }
  }

  if ($yaml -match "rvc_candidate_base:\s*(?:.|\n)*?status:\s*candidate-pending-rights-review") {
    Add-Check "rvc-candidate-rights-review" "pending" "RVC candidate remains review-only and pending rights review." $VoiceSourceProvenancePath
  } else {
    Add-Check "rvc-candidate-rights-review" "pass" "No pending RVC candidate rights-review marker found." $VoiceSourceProvenancePath
  }

  $rolloutGate = Get-YamlTopLevelScalar $yaml "rollout_gate"
  if ($rolloutGate -match "(?i)^blocked") {
    Add-Check "voice-rollout-gate" "pending" "Rollout gate is blocked: $rolloutGate" $VoiceSourceProvenancePath
  } elseif (Test-ReadyText $rolloutGate) {
    Add-Check "voice-rollout-gate" "pass" "Rollout gate is open: $rolloutGate" $VoiceSourceProvenancePath
  } else {
    Add-Check "voice-rollout-gate" "fail" "Rollout gate is missing or invalid: $rolloutGate" $VoiceSourceProvenancePath
  }

  foreach ($marker in @(
    "licensed_or_owned_production_voice_source",
    "completed_voice_source_provenance_template",
    "target_speaker_audio_check",
    "real_device_audio_video_evidence",
    "hardware_evidence_verification_pass"
  )) {
    if ($yaml -match [regex]::Escape($marker)) {
      Add-Check "required-rollout-evidence-$marker" "pass" "Required rollout evidence marker is present: $marker" $VoiceSourceProvenancePath
    } else {
      Add-Check "required-rollout-evidence-$marker" "fail" "Missing required rollout evidence marker: $marker" $VoiceSourceProvenancePath
    }
  }
}

if (-not [string]::IsNullOrWhiteSpace($template)) {
  $templatePatterns = if ($productionSourceReady) {
    @(
      "Production Voice Release Record",
      "Stackchan: Alive releases the exact DirectML RVC files",
      "media/voice/rvc/model.pth",
      "media/voice/rvc/model.index",
      "Runtime: DirectML RVC",
      "released for public distribution",
      "verify_tracked_rvc_assets.ps1"
    )
  } else {
    @()
  }
  foreach ($pattern in $templatePatterns) {
    if ($template -match [regex]::Escape($pattern)) {
      Add-Check ("voice-template-pattern-" + ($pattern -replace "[^A-Za-z0-9]+", "-").Trim("-")) "pass" "Template includes: $pattern" $TemplatePath
    } else {
      Add-Check ("voice-template-pattern-" + ($pattern -replace "[^A-Za-z0-9]+", "-").Trim("-")) "fail" "Template is missing: $pattern" $TemplatePath
    }
  }

  $blankTemplateFields = @(
    [regex]::Matches($template, "(?m)^-\s+([^:\r\n]+):\s*$") |
      ForEach-Object { $_.Groups[1].Value.Trim() }
  )
  $uncheckedTemplateBoxes = @([regex]::Matches($template, "(?m)^-\s+\[ \]\s+(.+)$"))

  if ($blankTemplateFields.Count -gt 0) {
    Add-Check "voice-template-fields-complete" "pending" "Template still has blank fields: $($blankTemplateFields.Count)" $TemplatePath
  } else {
    Add-Check "voice-template-fields-complete" "pass" "No blank template fields detected." $TemplatePath
  }

  if ($uncheckedTemplateBoxes.Count -gt 0) {
    Add-Check "voice-template-attestations-complete" "pending" "Template still has unchecked attestations: $($uncheckedTemplateBoxes.Count)" $TemplatePath
  } else {
    Add-Check "voice-template-attestations-complete" "pass" "All template attestations are checked." $TemplatePath
  }
}

$failed = @($checks | Where-Object { $_.status -eq "fail" })
$pending = @($checks | Where-Object { $_.status -eq "pending" })
$status = if ($failed.Count -gt 0) {
  "not-ready"
} elseif ($pending.Count -gt 0) {
  "pending-production-voice-source"
} else {
  "production-voice-source-ready"
}

$report = [ordered]@{
  schema = "stackchan.voice-source-readiness.v1"
  status = $status
  root = [string]$Root
  sourceCommit = $SourceCommit
  voiceSourceCommit = $provenanceSourceCommit
  voiceSourceProvenancePath = $VoiceSourceProvenancePath
  templatePath = $TemplatePath
  passed = @($checks | Where-Object { $_.status -eq "pass" }).Count
  pending = $pending.Count
  failed = $failed.Count
  checks = @($checks)
}

if ($Json) {
  $report | ConvertTo-Json -Depth 8
} else {
  Write-Host "Voice source readiness: $status"
  Write-Host "Passed: $($report.passed)  Pending: $($report.pending)  Failed: $($report.failed)"
  foreach ($check in $checks) {
    Write-Host "[$($check.status)] $($check.id): $($check.detail)"
  }
}

if ($failed.Count -gt 0 -or ($RequireProductionReady -and $pending.Count -gt 0)) {
  exit 1
}
