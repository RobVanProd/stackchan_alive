$ErrorActionPreference = "Stop"
$RepoRoot = Resolve-Path (Join-Path $PSScriptRoot "..")
$Path = Join-Path $RepoRoot "tools\start_warm_rocm_full_system_soak.ps1"
$source = Get-Content -LiteralPath $Path -Raw
$required = @(
  "OperatorPresent", "BodyClear", "ConfirmServoRisk", "Stop-MotionVerified",
  "initialMotionStop", "source-identity-preflight-failure.json", "clean pinned source commit",
  "sourceCommit", "runnerSourceCommit", "sourceDirty", "runtimePreflightReady", "runtime-preflight-failure.json",
  "chip_temp_c", "power_vbus_mv", "power_vbus_min_mv", "display_window_max_frame_us",
  "preflightSocketRemote", "visionPreflightReady", "visionSocketRemote", "camera_target_valid",
  "unauthenticated local loopback HTTP", "workerHealthRaw", "average_convert_ms",
  "camera_host_frame_requests", "camera_host_target_updates", "camera_host_auth_failures",
  "MaxCameraCaptureUs", '"-MaxCameraCaptureUs"',
  "Final integration vision is not ready and advancing; motion was not enabled",
  "Stop-MotionAndThrow", "preflight-failure-motion-stop.json",
  "Could not launch the soak runner", "RequireFinalIntegration", "AllowExternalImuEvents", "FirmwareSourceCommit",
  "RequireStableCameraTarget", "-not `$RequireStableCameraTarget",
  "ExpectedPmicVindpmMv", "pmic-input-policy-preflight-failure.json",
  "pmic_input_policy_not_applied"
)
foreach ($fragment in $required) {
  if (-not $source.Contains($fragment)) {
    throw "Warm ROCm soak wrapper contract missing fragment: $fragment"
  }
}
Write-Output "Warm ROCm full-system soak wrapper contract verified."
