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
  "dirty source worktree", "same installed firmware SHA-256"
)
foreach ($fragment in $required) {
  if (-not $source.Contains($fragment)) {
    throw "Consumer promotion contract missing fragment: $fragment"
  }
}
Write-Output "Consumer promotion contract verified."
