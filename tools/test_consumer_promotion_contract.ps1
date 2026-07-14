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
Write-Output "Consumer promotion contract verified."
