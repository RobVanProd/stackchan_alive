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
  '& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $verifyPackage -Version $Version -PackageRoot $packageRootPath -ExpectedCommit $ExpectedCommit',
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

foreach ($fragment in @(
    'status = "test-ready prerelease; hardware validation pending"',
    'status = "test-ready-prerelease"',
    'consumerRollout = "blocked-pending-hardware-validation"',
    'releaseClass = "test-ready-prerelease"',
    'currentDecision = "test-ready-for-device-arrival"',
    'consumerRolloutDecision = "blocked-pending-hardware-validation"',
    "Owner approval has not been recorded for this candidate"
  )) {
  if (-not $packageSource.Contains($fragment)) {
    throw "Release package candidate-state contract missing fragment: $fragment"
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
