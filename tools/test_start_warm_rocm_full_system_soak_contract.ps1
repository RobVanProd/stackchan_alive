$ErrorActionPreference = "Stop"
$RepoRoot = Resolve-Path (Join-Path $PSScriptRoot "..")
$Path = Join-Path $RepoRoot "tools\start_warm_rocm_full_system_soak.ps1"
$source = Get-Content -LiteralPath $Path -Raw
$required = @(
  "debug_http_control_policy", "emergency_stop_only", "motion_resume_unavailable",
  "ControlPolicyContractProbe", "Get-FirmwareHttpControlPolicy",
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
$policyIndex = $source.IndexOf("debug_http_control_policy")
$guardCallIndex = $source.IndexOf('Assert-EmergencyStopOnlyMotionPolicy -Policy $controlPolicyPreflight')
$enableCallIndex = $source.IndexOf('$motionStart = Enable-MotionWithRetry')
$evidenceIndex = $source.IndexOf('New-Item -ItemType Directory -Force -Path $EvidenceRoot')
$rvcLaunchIndex = $source.IndexOf('.\tools\start_rvc_worker.ps1')
$brainLaunchIndex = $source.IndexOf('.\tools\start_pc_brain.ps1')
$runnerLaunchIndex = $source.IndexOf('$proc = Start-Process')
$guardedSites = @($enableCallIndex, $evidenceIndex, $rvcLaunchIndex, $brainLaunchIndex, $runnerLaunchIndex)
if ($policyIndex -lt 0 -or $guardCallIndex -lt 0 -or
    @($guardedSites | Where-Object { $_ -lt 0 -or $_ -lt $guardCallIndex }).Count -gt 0) {
  throw "Warm-soak policy assertion failed: capability refusal must dominate motion and every worker/runner launch."
}
Write-Output "Warm ROCm full-system soak wrapper contract verified."
