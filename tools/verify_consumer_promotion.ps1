param(
  [string]$Version,
  [string]$PackageRoot,
  [string]$PackageZip,
  [string]$EvidenceRoot,
  [string]$VoiceSourceProvenancePath,
  [string]$VoiceSourceTemplatePath,
  [string]$ExpectedCommit,
  [switch]$AllowExternalAccountCiBlock,
  [switch]$AllowMissingMedia
)

$ErrorActionPreference = "Stop"

$repoRoot = Resolve-Path (Join-Path $PSScriptRoot "..")
Set-Location $repoRoot

if ([string]::IsNullOrWhiteSpace($Version)) {
  $Version = (git describe --tags --always --dirty).Trim()
}

if ([string]::IsNullOrWhiteSpace($ExpectedCommit)) {
  $ExpectedCommit = (git rev-parse HEAD).Trim()
}

$cleanupDir = $null

function Join-ResolvedPath {
  param(
    [string]$Root,
    [string]$RelativePath
  )
  return Join-Path $Root ($RelativePath -replace "/", "\")
}

function Assert-FilePath {
  param(
    [string]$Path,
    [int64]$MinBytes = 1
  )

  if ([string]::IsNullOrWhiteSpace($Path) -or -not (Test-Path -LiteralPath $Path)) {
    throw "Missing file: $Path"
  }

  $item = Get-Item -LiteralPath $Path
  if ($item.Length -lt $MinBytes) {
    throw "File is too small: $Path ($($item.Length) bytes)"
  }
}

function Assert-ObjectTextComplete {
  param(
    [object]$Value,
    [string]$Path
  )

  $text = [string]$Value
  if ([string]::IsNullOrWhiteSpace($text)) {
    throw "Voice source provenance field is blank: $Path"
  }
  if ($text -match "(?i)\b(TBD|pending|required-before|required before|not approved)\b") {
    throw "Voice source provenance field is not production-ready: $Path = $text"
  }
}

function Assert-VoiceSourceReady {
  param(
    [string]$YamlPath,
    [string]$TemplatePath
  )

  Assert-FilePath $YamlPath 100
  $yaml = Get-Content -LiteralPath $YamlPath -Raw
  foreach ($pattern in @("schema: stackchan.voice-source-provenance.v1", "production_source:", "rollout_gate:")) {
    if ($yaml -notmatch [regex]::Escape($pattern)) {
      throw "voice_source_provenance.yaml missing expected field: $pattern"
    }
  }
  if ($yaml -match "status:\s*pending-production-source") {
    throw "Voice source provenance is still pending-production-source"
  }
  if ($yaml -match "rollout_gate:\s*blocked") {
    throw "Voice source rollout gate is still blocked"
  }
  if ($yaml -match "(?m)^\s+(provider|owner_or_consent_contact|license_or_consent_evidence|commercial_device_use|generated_prompt_distribution):\s*(TBD|required-before-consumer-rollout|required-before-use)\s*$") {
    throw "Voice source production fields still contain placeholder approval markers"
  }

  foreach ($pattern in @("licensed_or_owned_production_voice_source", "target_speaker_audio_check", "real_device_audio_video_evidence", "hardware_evidence_verification_pass")) {
    if ($yaml -notmatch [regex]::Escape($pattern)) {
      throw "voice_source_provenance.yaml missing required rollout evidence marker: $pattern"
    }
  }

  if (-not [string]::IsNullOrWhiteSpace($TemplatePath)) {
    Assert-FilePath $TemplatePath 100
    $template = Get-Content -LiteralPath $TemplatePath -Raw
    foreach ($field in @("Production voice source name", "Provider or owner", "License, contract, or consent evidence path", "Production voice approved", "Approval date")) {
      if ($template -match "(?m)^-\s+$([regex]::Escape($field)):\s*$") {
        throw "Voice source provenance template has blank field: $field"
      }
    }
    if ($template -match "(?m)^-\s+\[ \]") {
      throw "Voice source provenance template still has unchecked attestations"
    }
  }
}

if (-not [string]::IsNullOrWhiteSpace($PackageZip)) {
  Assert-FilePath $PackageZip 100000
  $tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) "stackchan-consumer-promotion"
  $cleanupDir = Join-Path $tempRoot ([System.Guid]::NewGuid().ToString("N"))
  New-Item -ItemType Directory -Force -Path $cleanupDir | Out-Null
  Expand-Archive -LiteralPath $PackageZip -DestinationPath $cleanupDir
  $PackageRoot = $cleanupDir
}

if ([string]::IsNullOrWhiteSpace($PackageRoot)) {
  $PackageRoot = Join-Path $repoRoot "output/release/$Version"
}

if (-not (Test-Path -LiteralPath $PackageRoot)) {
  throw "Missing package root: $PackageRoot"
}
$packageRootPath = (Resolve-Path $PackageRoot).Path

try {
  $verifyPackage = Join-Path $PSScriptRoot "verify_release_package.ps1"
  & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $verifyPackage -Version $Version -PackageRoot $packageRootPath -ExpectedCommit $ExpectedCommit
  if ($LASTEXITCODE -ne 0) {
    throw "Release package verification failed."
  }

  if ([string]::IsNullOrWhiteSpace($EvidenceRoot)) {
    throw "Consumer promotion requires a completed hardware evidence packet. Pass -EvidenceRoot."
  }

  $verifyEvidence = Join-Path $PSScriptRoot "verify_hardware_evidence.ps1"
  $evidenceArgs = @("-NoProfile", "-ExecutionPolicy", "Bypass", "-File", $verifyEvidence, "-EvidenceRoot", $EvidenceRoot)
  if ($AllowMissingMedia) {
    $evidenceArgs += "-AllowMissingMedia"
  }
  & powershell.exe @evidenceArgs
  if ($LASTEXITCODE -ne 0) {
    throw "Hardware evidence verification failed."
  }

  $manifest = Get-Content -LiteralPath (Join-ResolvedPath $packageRootPath "release_manifest.json") -Raw | ConvertFrom-Json
  if ($manifest.status -notmatch "hardware validation pending") {
    throw "Unexpected manifest status for prerelease promotion review: $($manifest.status)"
  }

  $readiness = Get-Content -LiteralPath (Join-ResolvedPath $packageRootPath "readiness_report.json") -Raw | ConvertFrom-Json
  if ($readiness.consumerRollout -ne "blocked-pending-hardware-validation") {
    throw "Expected prerelease readiness to document blocked consumer rollout before evidence review"
  }

  $actionsStatus = Get-Content -LiteralPath (Join-ResolvedPath $packageRootPath "github_actions_status.json") -Raw | ConvertFrom-Json
  if ($actionsStatus.status -ne "success") {
    $externalAccountStatuses = @("external-account-billing-or-spending-limit", "external-account-ci-pre-runner-allocation")
    if (-not ($AllowExternalAccountCiBlock -and $externalAccountStatuses -contains $actionsStatus.status)) {
      throw "GitHub Actions status is not promotion-ready: $($actionsStatus.status)"
    }
    Write-Warning "Allowing external GitHub Actions account/pre-runner block because -AllowExternalAccountCiBlock was passed."
  }

  if ([string]::IsNullOrWhiteSpace($VoiceSourceProvenancePath)) {
    $VoiceSourceProvenancePath = Join-ResolvedPath $packageRootPath "data/voice_source_provenance.yaml"
  }
  if ([string]::IsNullOrWhiteSpace($VoiceSourceTemplatePath)) {
    $VoiceSourceTemplatePath = Join-ResolvedPath $packageRootPath "docs/VOICE_SOURCE_PROVENANCE_TEMPLATE.md"
  }
  Assert-VoiceSourceReady -YamlPath $VoiceSourceProvenancePath -TemplatePath $VoiceSourceTemplatePath

  Write-Host "Consumer promotion gate verified:"
  Write-Host "Release: $Version"
  Write-Host "Commit: $ExpectedCommit"
  Write-Host "Package: $packageRootPath"
  Write-Host "Evidence: $EvidenceRoot"
} finally {
  if ($null -ne $cleanupDir) {
    Remove-Item -LiteralPath $cleanupDir -Recurse -Force -ErrorAction SilentlyContinue
  }
}
