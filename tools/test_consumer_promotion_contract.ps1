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
  "Release commit:", "Firmware source commit:"
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
  '$soakEvidence = Assert-FinalSoakReady $FullSystemSoakSummaryPath $ExpectedFirmwareSourceCommit $MinFinalSoakDurationSeconds'
)
foreach ($binding in $identityBindings) {
  if (-not $source.Contains($binding)) {
    throw "Consumer promotion identity binding missing: $binding"
  }
}
Write-Output "Consumer promotion contract verified."
