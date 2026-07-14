param(
  [string]$Version,
  [string]$PackageRoot,
  [string]$PackageZip,
  [string]$EvidenceRoot,
  [string]$CompanionV1EvidenceRoot,
  [string]$VoiceSourceProvenancePath,
  [string]$VoiceSourceTemplatePath,
  [string]$ProjectLicensePath,
  [string]$CameraFollowSummaryPath,
  [string]$BodySensorReportPath,
  [string]$FullSystemSoakSummaryPath,
  [int]$MinFinalSoakDurationSeconds = 3600,
  [string]$ExternalAccountCiExceptionPath,
  [string]$ExpectedCommit,
  [string]$ExpectedFirmwareSourceCommit,
  [string]$Repo = "RobVanProd/stackchan_alive",
  [string]$ActionsStatusPath,
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
if ([string]::IsNullOrWhiteSpace($ExpectedFirmwareSourceCommit)) {
  $ExpectedFirmwareSourceCommit = $ExpectedCommit
}

$cleanupDir = $null
$actionsStatusTempDir = $null
$promotionPackageZipPath = ""
$promotionPackageZipSha256 = ""

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

function Resolve-PromotionPath {
  param([string]$Path)

  if ([string]::IsNullOrWhiteSpace($Path)) {
    return ""
  }
  $fullPath = if ([System.IO.Path]::IsPathRooted($Path)) {
    [System.IO.Path]::GetFullPath($Path)
  } else {
    [System.IO.Path]::GetFullPath((Join-Path $repoRoot $Path))
  }
  if (Test-Path -LiteralPath $fullPath) {
    return (Resolve-Path -LiteralPath $fullPath).Path
  }
  return $fullPath
}

function Assert-CompanionV1PromotionReady {
  param(
    [string]$EvidenceRootPath,
    [string]$ExpectedVersion,
    [string]$ExpectedSourceCommit,
    [string]$ExpectedFirmwareSourceCommit,
    [string]$ExpectedHardwareEvidenceRoot,
    [string]$ExpectedPackageZipPath,
    [string]$ExpectedPackageZipSha256
  )

  $resolvedRoot = Resolve-PromotionPath $EvidenceRootPath
  if ([string]::IsNullOrWhiteSpace($resolvedRoot) -or -not (Test-Path -LiteralPath $resolvedRoot -PathType Container)) {
    throw "Consumer promotion requires a completed Companion v1 aggregate evidence directory: $EvidenceRootPath"
  }

  $checker = Join-Path $PSScriptRoot "check_companion_v1_evidence_bundle.ps1"
  $checkerOutput = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $checker `
    -Root $repoRoot `
    -EvidenceRoot $resolvedRoot `
    -RequireReady `
    -Json 2>&1
  $checkerExitCode = $LASTEXITCODE
  $checkerText = ($checkerOutput | Out-String).Trim()
  if ($checkerExitCode -ne 0) {
    throw "Companion v1 aggregate evidence is not promotion-ready: $checkerText"
  }
  try {
    $checkerReport = $checkerText | ConvertFrom-Json
  } catch {
    throw "Companion v1 aggregate checker did not return valid JSON: $($_.Exception.Message)"
  }
  if ($checkerReport.schema -ne "stackchan.companion-v1-evidence-bundle-check.v1" -or
      $checkerReport.status -ne "companion-v1-evidence-ready" -or
      [int]$checkerReport.failed -ne 0 -or [int]$checkerReport.pending -ne 0) {
    throw "Companion v1 aggregate evidence did not return companion-v1-evidence-ready."
  }
  if ([string]$checkerReport.sourceCommit -ne $ExpectedSourceCommit) {
    throw "Companion v1 aggregate source commit mismatch: expected $ExpectedSourceCommit, got $($checkerReport.sourceCommit)"
  }
  if ([string]$checkerReport.firmwareSourceCommit -ne $ExpectedFirmwareSourceCommit) {
    throw "Companion v1 aggregate firmware source commit mismatch: expected $ExpectedFirmwareSourceCommit, got $($checkerReport.firmwareSourceCommit)"
  }
  if ([string]$checkerReport.releaseVersion -ne $ExpectedVersion) {
    throw "Companion v1 aggregate release version mismatch: expected $ExpectedVersion, got $($checkerReport.releaseVersion)"
  }

  $bundlePath = Join-Path $resolvedRoot "COMPANION_V1_EVIDENCE_BUNDLE.json"
  $bundle = Read-JsonFile $bundlePath
  $bundleHardwareRoot = Resolve-PromotionPath ([string]$bundle.hardwareEvidenceRoot)
  $promotionHardwareRoot = Resolve-PromotionPath $ExpectedHardwareEvidenceRoot
  if ([string]::IsNullOrWhiteSpace($bundleHardwareRoot) -or
      -not $bundleHardwareRoot.Equals($promotionHardwareRoot, [System.StringComparison]::OrdinalIgnoreCase)) {
    throw "Companion v1 hardware evidence root does not match the packet being promoted: expected $promotionHardwareRoot, got $bundleHardwareRoot"
  }

  $bundlePackageSha256 = ([string]$bundle.releasePackage.sha256).ToLowerInvariant()
  if ($bundlePackageSha256 -ne $ExpectedPackageZipSha256.ToLowerInvariant()) {
    throw "Companion v1 release ZIP SHA-256 does not match the package being promoted: $ExpectedPackageZipPath"
  }

  return [pscustomobject]@{
    root = $resolvedRoot
    report = $checkerReport
    bundle = $bundle
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

function Assert-ProjectLicenseReady {
  param([string]$Path)
  Assert-FilePath $Path 100
  $text = Get-Content -LiteralPath $Path -Raw
  if ($text -match "(?i)\b(TBD|TODO|choose a license|license pending)\b") {
    throw "Project license still contains a placeholder: $Path"
  }
}

function Assert-EvidenceIdentity {
  param($Record, [string]$Label, [string]$ExpectedFirmwareSourceCommit)
  if ([string]$Record.sourceCommit -ne $ExpectedFirmwareSourceCommit) {
    throw "$Label firmware source commit mismatch: expected $ExpectedFirmwareSourceCommit, got $($Record.sourceCommit)"
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
  param([string]$Path, [string]$ExpectedFirmwareSourceCommit)
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
    firmwareSha256 = Assert-EvidenceIdentity $summary "Camera wake/follow evidence" $ExpectedFirmwareSourceCommit
  }
}

function Assert-BodySensorReady {
  param([string]$Path, [string]$ExpectedFirmwareSourceCommit)
  $report = Read-JsonFile $Path
  if ($report.schema -ne "stackchan.body-sensor-validation-report.v1" -or
      $report.status -ne "pass" -or [int]$report.failed -ne 0) {
    throw "Body touch/IMU evidence is not complete: $Path"
  }
  return [pscustomobject]@{
    record = $report
    firmwareSha256 = Assert-EvidenceIdentity $report "Body touch/IMU evidence" $ExpectedFirmwareSourceCommit
  }
}

function Assert-FinalSoakReady {
  param([string]$Path, [string]$ExpectedFirmwareSourceCommit, [int]$MinDurationSeconds)
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
    firmwareSha256 = Assert-EvidenceIdentity $summary "Final integrated soak evidence" $ExpectedFirmwareSourceCommit
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

if ([string]::IsNullOrWhiteSpace($PackageZip)) {
  throw "Consumer promotion requires -PackageZip so the exact release archive can be bound to Companion v1 evidence."
}

if (-not [string]::IsNullOrWhiteSpace($PackageZip)) {
  Assert-FilePath $PackageZip 100000
  $promotionPackageZipPath = (Resolve-Path -LiteralPath $PackageZip).Path
  $promotionPackageZipSha256 = (Get-FileHash -Algorithm SHA256 -LiteralPath $promotionPackageZipPath).Hash.ToLowerInvariant()
  $tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) "stackchan-consumer-promotion"
  $cleanupDir = Join-Path $tempRoot ([System.Guid]::NewGuid().ToString("N"))
  New-Item -ItemType Directory -Force -Path $cleanupDir | Out-Null
  Expand-Archive -LiteralPath $promotionPackageZipPath -DestinationPath $cleanupDir
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

  if ([string]::IsNullOrWhiteSpace($CompanionV1EvidenceRoot)) {
    throw "Consumer promotion requires -CompanionV1EvidenceRoot with a completed aggregate Companion v1 evidence packet."
  }
  $companionV1Evidence = Assert-CompanionV1PromotionReady `
    -EvidenceRootPath $CompanionV1EvidenceRoot `
    -ExpectedVersion $Version `
    -ExpectedSourceCommit $ExpectedCommit `
    -ExpectedFirmwareSourceCommit $ExpectedFirmwareSourceCommit `
    -ExpectedHardwareEvidenceRoot $EvidenceRoot `
    -ExpectedPackageZipPath $promotionPackageZipPath `
    -ExpectedPackageZipSha256 $promotionPackageZipSha256

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
  $cameraEvidence = Assert-CameraFollowReady $CameraFollowSummaryPath $ExpectedFirmwareSourceCommit
  $bodyEvidence = Assert-BodySensorReady $BodySensorReportPath $ExpectedFirmwareSourceCommit
  $soakEvidence = Assert-FinalSoakReady $FullSystemSoakSummaryPath $ExpectedFirmwareSourceCommit $MinFinalSoakDurationSeconds
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

  if ([string]::IsNullOrWhiteSpace($ActionsStatusPath)) {
    $actionsStatusTempDir = Join-Path ([System.IO.Path]::GetTempPath()) `
      ("stackchan-promotion-actions-" + [System.Guid]::NewGuid().ToString("N"))
    New-Item -ItemType Directory -Force -Path $actionsStatusTempDir | Out-Null
    $actionsExporter = Join-Path $PSScriptRoot "export_github_actions_status.ps1"
    $actionsOutput = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $actionsExporter `
      -Repo $Repo -Version $Version -Commit $ExpectedCommit -OutputDir $actionsStatusTempDir 2>&1
    if ($LASTEXITCODE -ne 0) {
      throw "Unable to capture successful live GitHub Actions status for consumer promotion: $($actionsOutput | Out-String)"
    }
    $ActionsStatusPath = Join-Path $actionsStatusTempDir "github_actions_status.json"
  }
  $actionsStatus = Read-JsonFile $ActionsStatusPath
  if ($actionsStatus.schema -ne "stackchan.github-actions-status.v1" -or
      [string]$actionsStatus.commit -ne $ExpectedCommit) {
    throw "GitHub Actions status does not match release commit $ExpectedCommit`: $ActionsStatusPath"
  }
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
  Write-Host "Release commit: $ExpectedCommit"
  Write-Host "Firmware source commit: $ExpectedFirmwareSourceCommit"
  Write-Host "Package: $packageRootPath"
  Write-Host "Evidence: $EvidenceRoot"
  Write-Host "Companion v1 evidence: $($companionV1Evidence.root)"
  Write-Host "Release ZIP SHA256: $promotionPackageZipSha256"
  Write-Host "Installed firmware SHA256: $($firmwareHashes[0])"
  if ($null -ne $ciException) {
    Write-Host "CI exception: $ExternalAccountCiExceptionPath"
  }
  Write-Host "GitHub Actions evidence: $ActionsStatusPath"
} finally {
  if ($null -ne $actionsStatusTempDir) {
    Remove-Item -LiteralPath $actionsStatusTempDir -Recurse -Force -ErrorAction SilentlyContinue
  }
  if ($null -ne $cleanupDir) {
    Remove-Item -LiteralPath $cleanupDir -Recurse -Force -ErrorAction SilentlyContinue
  }
}
