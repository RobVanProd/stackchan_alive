$ErrorActionPreference = "Stop"
$RepoRoot = Resolve-Path (Join-Path $PSScriptRoot "..")
$Path = Join-Path $RepoRoot "tools\verify_consumer_promotion.ps1"
$source = Get-Content -LiteralPath $Path -Raw
$required = @(
  "ProjectLicensePath", "Assert-ProjectLicenseReady", "CameraFollowSummaryPath",
  "Assert-CameraFollowReady", "BodySensorReportPath", "Assert-BodySensorReady",
  "FullSystemSoakSummaryPath", "Assert-FinalSoakReady", "MinFinalSoakDurationSeconds",
  "RequireFinalIntegration", "RequirePowerForensics", "requireCameraHostVision",
  "requireVerifiedMotionStop", "Assert-EvidenceIdentity", "source commit mismatch",
  "dirty source worktree", "same installed firmware SHA-256", "ExpectedFirmwareSourceCommit",
  "Release commit:", "Firmware source commit:", "ActionsStatusPath",
  "export_github_actions_status.ps1", "successful live GitHub Actions status",
  "stackchan.github-actions-status.v1", "GitHub Actions evidence:",
  "CompanionV1EvidenceRoot", "Assert-CompanionV1PromotionReady",
  "check_companion_v1_evidence_bundle.ps1", "-RequireReady",
  "stackchan.companion-v1-evidence-bundle-check.v1", "companion-v1-evidence-ready",
  "Companion v1 aggregate source commit mismatch", "Companion v1 aggregate release version mismatch",
  "Companion v1 aggregate firmware source commit mismatch",
  "Companion v1 hardware evidence root does not match the packet being promoted",
  "Companion v1 release ZIP SHA-256 does not match the package being promoted",
  "Consumer promotion requires -PackageZip", "Companion v1 evidence:", "Release ZIP SHA256:"
)
foreach ($fragment in $required) {
  if (-not $source.Contains($fragment)) {
    throw "Consumer promotion contract missing fragment: $fragment"
  }
}

$identityBindings = @(
  '-RequireReleaseEligible -ToolchainAllowlistPath $ToolchainAllowlistPath',
  '-GitExecutable $GitExecutable -PythonExecutable $PythonExecutable',
  '-LegacyCoreDir $LegacyCoreDir -ReleaseCoreDir $ReleaseCoreDir',
  '$cameraEvidence = Assert-CameraFollowReady $CameraFollowSummaryPath $ExpectedFirmwareSourceCommit',
  '$bodyEvidence = Assert-BodySensorReady $BodySensorReportPath $ExpectedFirmwareSourceCommit',
  '$soakEvidence = Assert-FinalSoakReady $FullSystemSoakSummaryPath $ExpectedFirmwareSourceCommit $MinFinalSoakDurationSeconds',
  '-ExpectedSourceCommit $ExpectedCommit',
  '-ExpectedFirmwareSourceCommit $ExpectedFirmwareSourceCommit',
  '-ExpectedHardwareEvidenceRoot $EvidenceRoot',
  '-ExpectedPackageZipSha256 $promotionPackageZipSha256'
)
foreach ($binding in $identityBindings) {
  if (-not $source.Contains($binding)) {
    throw "Consumer promotion identity binding missing: $binding"
  }
}

$packageSource = Get-Content -LiteralPath (Join-Path $RepoRoot "tools\package_release.ps1") -Raw
$packageVerifierSource = Get-Content -LiteralPath (Join-Path $RepoRoot "tools\verify_release_package.ps1") -Raw
$actionsExporterSource = Get-Content -LiteralPath (Join-Path $RepoRoot "tools\export_github_actions_status.ps1") -Raw

foreach ($fragment in @(
    'Assert-StackchanReleaseToolchainIdentity',
    'pre-Git byte authority mismatch',
    'release_toolchain_identity_allowlist.json',
    'if ($SkipBuild -and -not $AllowDirty) {',
    'if ($AllowDirty -and -not $SkipBuild) {',
    'if ($SkipBuild -and $ObserveCandidateActions) {',
    '"diagnostic-only; reproducibility not proven; release and hardware validation forbidden"',
    '"test-ready prerelease; hardware validation pending"',
    'diagnosticPackage = [bool]$SkipBuild',
    'releaseEligible = ($releaseToolchainEligible -and (-not $SkipBuild))',
    'hardwareValidationEligible = ($releaseToolchainEligible -and (-not $SkipBuild))',
    'distributionEligible = ($releaseToolchainEligible -and (-not $SkipBuild))',
    'flashEligible = ($releaseToolchainEligible -and (-not $SkipBuild))',
    'status = if ($SkipBuild) { "diagnostic-only-unqualified" } else { "test-ready-prerelease" }',
    'consumerRollout = if ($SkipBuild) { "forbidden-diagnostic-package" } else { "blocked-pending-hardware-validation" }',
    'releaseClass = if ($SkipBuild) { "diagnostic-only-unqualified" } else { "test-ready-prerelease" }',
    'currentDecision = if ($SkipBuild) { "release-and-hardware-use-forbidden" } else { "test-ready-for-device-arrival" }',
    'consumerRolloutDecision = if ($SkipBuild) { "forbidden-diagnostic-package" } else { "blocked-pending-hardware-validation" }',
    "Owner approval has not been recorded for this candidate"
  )) {
  if (-not $packageSource.Contains($fragment)) {
    throw "Release package candidate-state contract missing fragment: $fragment"
  }
}

foreach ($fragment in @(
    '-ExpectedCommit $ExpectedCommit -RequireReleaseEligible',
    'Operational release ZIP verification failed before consumer-promotion extraction.',
    'Expand-StackchanReleaseZipSafely',
    '-PackageRoot $packageRootPath -ExpectedCommit $ExpectedCommit',
    '-RequireReleaseEligible -ToolchainAllowlistPath $ToolchainAllowlistPath'
  )) {
  if (-not $source.Contains($fragment)) {
    throw "Consumer promotion release-eligibility boundary missing fragment: $fragment"
  }
}

$packageFailClosedGuardIndex = $packageSource.IndexOf('if (-not $SkipBuild) {')
$packageFailClosedMessageIndex = $packageSource.IndexOf('Assert-StackchanReleaseToolchainIdentity')
$packageFirstGitResolutionIndex = $packageSource.IndexOf('$releaseBootstrapGitCommand = Get-Command -Name git')
if ($packageFailClosedGuardIndex -lt 0 -or
    $packageFailClosedMessageIndex -lt $packageFailClosedGuardIndex -or
    $packageFirstGitResolutionIndex -lt $packageFailClosedMessageIndex) {
  throw "Release package fail-closed guard must precede Git and build-tool resolution."
}

foreach ($fragment in @(
    '[switch]$RequireReleaseEligible',
    'Assert-StackchanReleaseToolchainIdentity',
    'Release verifier pre-Git byte authority mismatch:',
    'Operational release verification refuses diagnostic packages.',
    '$manifest.releaseEligible -ne $false',
    '$manifest.hardwareValidationEligible -ne $false',
    '$manifest.distributionEligible -ne $false',
    '$manifest.flashEligible -ne $false',
    'if ($RequireReleaseEligible -and',
    '$manifest.releaseEligible -ne $true',
    '$manifest.hardwareValidationEligible -ne $true',
    '$manifest.distributionEligible -ne $true',
    '$manifest.flashEligible -ne $true'
  )) {
  if (-not $packageVerifierSource.Contains($fragment)) {
    throw "Release package verifier fail-closed eligibility contract missing fragment: $fragment"
  }
}

$verifierFailClosedGuardIndex = $packageVerifierSource.IndexOf('if ($RequireReleaseEligible) {')
$verifierFailClosedMessageIndex = $packageVerifierSource.IndexOf('Assert-StackchanReleaseToolchainIdentity')
$verifierAmbientProcessingIndex = $packageVerifierSource.IndexOf('$trustedGitDisabledHooksPath = Join-Path')
if ($verifierFailClosedGuardIndex -lt 0 -or
    $verifierFailClosedMessageIndex -lt $verifierFailClosedGuardIndex -or
    $verifierAmbientProcessingIndex -lt $verifierFailClosedMessageIndex) {
  throw "Release package verifier identity guard must precede trusted Git, tool, and package processing."
}

foreach ($fragment in @(
    "[switch]`$ObserveCandidateActions",
    "-AcceptFirmwareCandidate",
    "firmwareCandidateReady",
    "only the tag-only Release workflow pending"
  )) {
  if (-not $packageSource.Contains($fragment)) {
    throw "Release package observed candidate Actions contract missing fragment: $fragment"
  }
}

$zipEligibilityVerifyIndex = $source.IndexOf('-ExpectedCommit $ExpectedCommit -RequireReleaseEligible')
$zipVerificationFailureIndex = $source.IndexOf('Operational release ZIP verification failed before consumer-promotion extraction.')
$safeExtractionIndex = $source.IndexOf('Expand-StackchanReleaseZipSafely')
$rootEligibilityVerifyIndex = $source.IndexOf('-Version $Version -PackageRoot $packageRootPath -ExpectedCommit $ExpectedCommit')
$firstEvidenceCheckIndex = $source.IndexOf('if ([string]::IsNullOrWhiteSpace($EvidenceRoot))')
if ($zipEligibilityVerifyIndex -lt 0 -or
    $zipVerificationFailureIndex -lt $zipEligibilityVerifyIndex -or
    $safeExtractionIndex -lt $zipVerificationFailureIndex -or
    $rootEligibilityVerifyIndex -lt $safeExtractionIndex -or
    $firstEvidenceCheckIndex -lt $rootEligibilityVerifyIndex) {
  throw "Consumer promotion must verify release eligibility before safe extraction and again before evidence checks."
}

foreach ($fragment in @(
    "[switch]`$AcceptFirmwareCandidate",
    "`$firmwareCandidateReady",
    "supervised prerelease hardware qualification",
    "-not (`$AcceptFirmwareCandidate -and `$firmwareCandidateReady)"
  )) {
  if (-not $actionsExporterSource.Contains($fragment)) {
    throw "Actions exporter Firmware candidate contract missing fragment: $fragment"
  }
}

foreach ($fragment in @(
    "github_actions_status.json missing firmwareCandidateReady",
    "github_actions_status.json has invalid Firmware candidate evidence"
  )) {
  if (-not $packageVerifierSource.Contains($fragment)) {
    throw "Release package verifier Firmware candidate contract missing fragment: $fragment"
  }
}

foreach ($fragment in @(
    '$manifest.status -notmatch "test-ready prerelease"',
    '$manifest.status -notmatch "hardware validation pending"',
    '$acceptance.releaseClass -ne "test-ready-prerelease"',
    '$acceptance.currentDecision -ne "test-ready-for-device-arrival"',
    '$acceptance.consumerRolloutDecision -ne "blocked-pending-hardware-validation"',
    '$readinessJson.status -ne "test-ready-prerelease"',
    '$readinessJson.consumerRollout -ne "blocked-pending-hardware-validation"'
  )) {
  if (-not $packageVerifierSource.Contains($fragment)) {
    throw "Release package verifier candidate-state contract missing fragment: $fragment"
  }
}

foreach ($forbidden in @(
    'status = "public release; reference hardware accepted by owner"',
    'consumerRollout = "owner-approved"',
    'currentDecision = "owner-approved-release"',
    'consumerRolloutDecision = "released"'
  )) {
  if ($packageSource.Contains($forbidden) -or $packageVerifierSource.Contains($forbidden)) {
    throw "Release candidate source still contains an automatic promotion marker: $forbidden"
  }
}

Write-Output "Consumer promotion contract verified."
