param(
  [string]$Version,
  [string]$PackageRoot,
  [string]$PackageZip,
  [string]$EvidenceRoot,
  [string]$VoiceSourceProvenancePath,
  [string]$VoiceSourceTemplatePath,
  [string]$ProjectLicensePath,
  [string]$CameraFollowSummaryPath,
  [string]$BodySensorReportPath,
  [string]$FullSystemSoakSummaryPath,
  [int]$MinFinalSoakDurationSeconds = 3600,
  [string]$ExternalAccountCiExceptionPath,
  [string]$ExpectedCommit,
  [switch]$AllowExternalAccountCiBlock
)

$ErrorActionPreference = "Stop"

$repoRoot = Resolve-Path (Join-Path $PSScriptRoot "..")
Set-Location $repoRoot

foreach ($arg in $args) {
  if ([string]$arg -ieq "-AllowMissingMedia") {
    throw "AllowMissingMedia cannot be used for consumer promotion. Consumer promotion requires strict media evidence."
  }
}

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

function Read-JsonFile {
  param([string]$Path)

  Assert-FilePath $Path 10
  return Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json
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

function Assert-ProjectLicenseReady {
  param([string]$Path)
  Assert-FilePath $Path 100
  $text = Get-Content -LiteralPath $Path -Raw
  if ($text -match "(?i)\b(TBD|TODO|choose a license|license pending)\b") {
    throw "Project license still contains a placeholder: $Path"
  }
}

function Assert-EvidenceIdentity {
  param($Record, [string]$Label, [string]$ExpectedCommit)
  if ([string]$Record.sourceCommit -ne $ExpectedCommit) {
    throw "$Label source commit mismatch: expected $ExpectedCommit, got $($Record.sourceCommit)"
  }
  if ([bool]$Record.sourceDirty) {
    throw "$Label was captured from a dirty source worktree"
  }
  $firmwareSha = [string]$Record.installedFirmwareSha256
  if ($firmwareSha -notmatch "^[0-9a-fA-F]{64}$") {
    throw "$Label does not pin a valid installed firmware SHA-256"
  }
  return $firmwareSha.ToUpperInvariant()
}

function Assert-CameraFollowReady {
  param([string]$Path, [string]$ExpectedCommit)
  $summary = Read-JsonFile $Path
  if ($summary.schema -ne "stackchan.camera-follow-wake-validation.v1" -or
      $summary.status -ne "pass" -or $summary.visualVerdict -ne "pass" -or
      -not [bool]$summary.motionStopVerified) {
    throw "Camera wake/follow evidence is not operator-approved and motion-stop verified: $Path"
  }
  if (@($summary.checks | Where-Object { $_.status -ne "pass" }).Count -gt 0 -or
      [int]$summary.captureTargetSamples -lt 2 -or
      [int]$summary.captureFollowSamples -ne [int]$summary.captureTargetSamples -or
      [int]$summary.chunksSubmittedDelta -lt 96 -or [int]$summary.bridgeTurnDelta -lt 1) {
    throw "Camera wake/follow evidence is incomplete: $Path"
  }
  return [pscustomobject]@{
    record = $summary
    firmwareSha256 = Assert-EvidenceIdentity $summary "Camera wake/follow evidence" $ExpectedCommit
  }
}

function Assert-BodySensorReady {
  param([string]$Path, [string]$ExpectedCommit)
  $report = Read-JsonFile $Path
  if ($report.schema -ne "stackchan.body-sensor-validation-report.v1" -or
      $report.status -ne "pass" -or [int]$report.failed -ne 0) {
    throw "Body touch/IMU evidence is not complete: $Path"
  }
  return [pscustomobject]@{
    record = $report
    firmwareSha256 = Assert-EvidenceIdentity $report "Body touch/IMU evidence" $ExpectedCommit
  }
}

function Assert-FinalSoakReady {
  param([string]$Path, [string]$ExpectedCommit, [int]$MinDurationSeconds)
  $summary = Read-JsonFile $Path
  if ($summary.schema -ne "stackchan.full-system-soak-summary.v1" -or
      $summary.status -ne "pass" -or [int]$summary.durationSeconds -lt $MinDurationSeconds) {
    throw "Final integrated soak evidence is not complete or long enough: $Path"
  }
  foreach ($flag in @(
      "requireMotion", "requireMotionTelemetry", "requireNoMotionTimeouts", "requireBridgeSocket",
      "requireWakeReady", "requireMicReady", "requireSpeakerReady", "requireRvcWorker",
      "requirePowerCoordinator", "requirePowerForensics", "requireFinalIntegration",
      "requireCameraCapture", "requireCameraHostVision", "requirePmicVbusStable",
      "requireNoNewHardFloorEvents", "requireManagedChargePolicy", "requireVerifiedMotionStop",
      "failFastOnStrictBreach"
    )) {
    if ($null -eq $summary.strict.PSObject.Properties[$flag] -or -not [bool]$summary.strict.$flag) {
      throw "Final integrated soak is missing strict flag: $flag"
    }
  }
  $checker = Join-Path $PSScriptRoot "check_full_system_soak_evidence.ps1"
  $checkOutput = & $checker -SummaryJsonPath $Path -MinDurationSeconds $MinDurationSeconds -RequirePowerForensics -RequireFinalIntegration -RequireReady -Json
  if ($LASTEXITCODE -ne 0) {
    throw "Final integrated soak formal verification failed: $checkOutput"
  }
  $check = $checkOutput | ConvertFrom-Json
  if ($check.status -ne "full-system-soak-ready" -or [int]$check.failed -ne 0) {
    throw "Final integrated soak formal verification did not return ready: $($check.status)"
  }
  return [pscustomobject]@{
    record = $summary
    check = $check
    firmwareSha256 = Assert-EvidenceIdentity $summary "Final integrated soak evidence" $ExpectedCommit
  }
}

function Assert-VoiceStatusReportsReady {
  param([string]$PackageRootPath)

  $voiceStatusPath = Join-ResolvedPath $PackageRootPath "voice_source_status.json"
  $voiceStatus = Read-JsonFile $voiceStatusPath
  if ($voiceStatus.schema -ne "stackchan.voice-source-status.v1") {
    throw "voice_source_status.json schema mismatch: $($voiceStatus.schema)"
  }
  if ($voiceStatus.status -ne "production-source-ready") {
    throw "voice_source_status.json is not production-source-ready: $($voiceStatus.status)"
  }
  if ([int]$voiceStatus.blockedGateCount -ne 0) {
    throw "voice_source_status.json still reports blocked gates: $($voiceStatus.blockedGateCount)"
  }

  $rvcStatusPath = Join-ResolvedPath $PackageRootPath "rvc_voice_base_status.json"
  $rvcStatus = Read-JsonFile $rvcStatusPath
  if ($rvcStatus.schema -ne "stackchan.rvc-voice-base-status.v1") {
    throw "rvc_voice_base_status.json schema mismatch: $($rvcStatus.schema)"
  }
  if (-not [bool]$rvcStatus.consumerApproved) {
    throw "rvc_voice_base_status.json is not consumer approved"
  }
  if (-not [bool]$rvcStatus.distributionApproved) {
    throw "rvc_voice_base_status.json is not distribution approved"
  }
  if ([int]$rvcStatus.failedGateCount -gt 0) {
    throw "rvc_voice_base_status.json still reports failed gates: $($rvcStatus.failedGateCount)"
  }
  if ([int]$rvcStatus.blockedGateCount -gt 0) {
    throw "rvc_voice_base_status.json still reports blocked gates: $($rvcStatus.blockedGateCount)"
  }
}

function Assert-CiExceptionRecord {
  param(
    [string]$Path,
    [string]$ExpectedVersion,
    [string]$ExpectedCommit,
    [string]$ExpectedActionsStatus
  )

  Assert-FilePath $Path 100
  $record = Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json
  if ($record.schema -ne "stackchan.ci-account-block-exception.v1") {
    throw "CI account-block exception schema mismatch: $($record.schema)"
  }
  if ([string]$record.version -ne $ExpectedVersion) {
    throw "CI account-block exception version mismatch: expected $ExpectedVersion, got $($record.version)"
  }
  if ([string]$record.commit -ne $ExpectedCommit) {
    throw "CI account-block exception commit mismatch: expected $ExpectedCommit, got $($record.commit)"
  }
  if ([string]$record.githubActionsStatus -ne $ExpectedActionsStatus) {
    throw "CI account-block exception status mismatch: expected $ExpectedActionsStatus, got $($record.githubActionsStatus)"
  }
  foreach ($field in @("approvedBy", "approvedUtc", "reason", "followUpOwner", "followUpDueUtc")) {
    $value = [string]$record.$field
    if ([string]::IsNullOrWhiteSpace($value)) {
      throw "CI account-block exception missing required field: $field"
    }
    if ($value -match "(?i)\b(TBD|pending|required-before|required before|not approved)\b") {
      throw "CI account-block exception field is still a placeholder: $field = $value"
    }
  }
  if (-not [bool]$record.riskAccepted) {
    throw "CI account-block exception must set riskAccepted to true"
  }
  if (-not [bool]$record.localReleaseVerificationPassed) {
    throw "CI account-block exception must confirm localReleaseVerificationPassed"
  }
  if (-not [bool]$record.strictHardwareEvidencePassed) {
    throw "CI account-block exception must confirm strictHardwareEvidencePassed"
  }
  if (-not [bool]$record.productionVoiceSourceReady) {
    throw "CI account-block exception must confirm productionVoiceSourceReady"
  }

  return $record
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
  & powershell.exe @evidenceArgs
  if ($LASTEXITCODE -ne 0) {
    throw "Hardware evidence verification failed."
  }

  if ([string]::IsNullOrWhiteSpace($ProjectLicensePath)) {
    $ProjectLicensePath = Join-Path $repoRoot "LICENSE"
  }
  Assert-ProjectLicenseReady $ProjectLicensePath
  foreach ($requiredEvidence in @(
      @{ name = "CameraFollowSummaryPath"; value = $CameraFollowSummaryPath },
      @{ name = "BodySensorReportPath"; value = $BodySensorReportPath },
      @{ name = "FullSystemSoakSummaryPath"; value = $FullSystemSoakSummaryPath }
    )) {
    if ([string]::IsNullOrWhiteSpace([string]$requiredEvidence.value)) {
      throw "Consumer promotion requires -$($requiredEvidence.name)."
    }
  }
  $cameraEvidence = Assert-CameraFollowReady $CameraFollowSummaryPath $ExpectedCommit
  $bodyEvidence = Assert-BodySensorReady $BodySensorReportPath $ExpectedCommit
  $soakEvidence = Assert-FinalSoakReady $FullSystemSoakSummaryPath $ExpectedCommit $MinFinalSoakDurationSeconds
  $firmwareHashes = @(@($cameraEvidence.firmwareSha256, $bodyEvidence.firmwareSha256, $soakEvidence.firmwareSha256) | Select-Object -Unique)
  if ($firmwareHashes.Count -ne 1) {
    throw "Camera, body-sensor, and final-soak evidence do not reference the same installed firmware SHA-256"
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
  $requiredWorkflowNames = @($actionsStatus.requiredWorkflows | ForEach-Object { [string]$_ })
  foreach ($workflowName in @("Firmware", "Release")) {
    if ($requiredWorkflowNames -notcontains $workflowName) {
      throw "GitHub Actions status is missing required workflow contract: $workflowName"
    }
  }
  if (@($actionsStatus.missingRequiredWorkflows).Count -gt 0) {
    throw "GitHub Actions status is missing required workflow evidence: $(@($actionsStatus.missingRequiredWorkflows) -join ', ')"
  }
  if ($actionsStatus.status -ne "success") {
    $externalAccountStatuses = @("external-account-billing-or-spending-limit", "external-account-ci-pre-runner-allocation")
    if (-not ($AllowExternalAccountCiBlock -and $externalAccountStatuses -contains $actionsStatus.status)) {
      throw "GitHub Actions status is not promotion-ready: $($actionsStatus.status)"
    }
    if ([string]::IsNullOrWhiteSpace($ExternalAccountCiExceptionPath)) {
      throw "Pass -ExternalAccountCiExceptionPath with a completed stackchan.ci-account-block-exception.v1 JSON record when using -AllowExternalAccountCiBlock."
    }
    $ciException = Assert-CiExceptionRecord -Path $ExternalAccountCiExceptionPath -ExpectedVersion $Version -ExpectedCommit $ExpectedCommit -ExpectedActionsStatus ([string]$actionsStatus.status)
    Write-Warning "Allowing external GitHub Actions account/pre-runner block because an explicit exception record was provided: $ExternalAccountCiExceptionPath"
  }

  if ([string]::IsNullOrWhiteSpace($VoiceSourceProvenancePath)) {
    $VoiceSourceProvenancePath = Join-ResolvedPath $packageRootPath "data/voice_source_provenance.yaml"
  }
  if ([string]::IsNullOrWhiteSpace($VoiceSourceTemplatePath)) {
    $VoiceSourceTemplatePath = Join-ResolvedPath $packageRootPath "docs/VOICE_SOURCE_PROVENANCE_TEMPLATE.md"
  }
  Assert-VoiceSourceReady -YamlPath $VoiceSourceProvenancePath -TemplatePath $VoiceSourceTemplatePath
  Assert-VoiceStatusReportsReady -PackageRootPath $packageRootPath

  Write-Host "Consumer promotion gate verified:"
  Write-Host "Release: $Version"
  Write-Host "Commit: $ExpectedCommit"
  Write-Host "Package: $packageRootPath"
  Write-Host "Evidence: $EvidenceRoot"
  Write-Host "Installed firmware SHA256: $($firmwareHashes[0])"
  if ($null -ne $ciException) {
    Write-Host "CI exception: $ExternalAccountCiExceptionPath"
  }
} finally {
  if ($null -ne $cleanupDir) {
    Remove-Item -LiteralPath $cleanupDir -Recurse -Force -ErrorAction SilentlyContinue
  }
}
