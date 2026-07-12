param([switch]$Json)

$ErrorActionPreference = "Stop"
$RepoRoot = Resolve-Path (Join-Path $PSScriptRoot "..")
$ScriptPath = Join-Path $RepoRoot "tools\camera_follow_wake_validation.ps1"
$checks = [System.Collections.Generic.List[object]]::new()

function Add-Check([string]$Id, [bool]$Passed, [string]$Detail) {
  $checks.Add([ordered]@{ id = $Id; status = $(if ($Passed) { "pass" } else { "fail" }); detail = $Detail })
}

Add-Check "script-present" (Test-Path -LiteralPath $ScriptPath -PathType Leaf) "path=$ScriptPath"
$source = if (Test-Path -LiteralPath $ScriptPath -PathType Leaf) { Get-Content -LiteralPath $ScriptPath -Raw } else { "" }
$requiredFragments = @(
  "OperatorPresent", "BodyClear", "ConfirmServoRisk",
  'Invoke-RobotEndpoint "/motion-resume"', 'Invoke-RobotEndpoint "/motion-stop"',
  "Get-NetTCPConnection", "bridge_socket_missing",
  "sourceCommit", "installedFirmwareSha256",
  "finally", "motion-stop-verified", "camera_target_valid",
  "wake_capture_incremental_active", "wake_capture_chunks_submitted",
  "motion_audio_playback_active", "motion_audio_preempt_active",
  "camera_gaze_motion_output_active", "power_vbus_hard_floor_entries",
  "power_pmic_vbus_loss_entries", "display_frame_limit_exceeded",
  "chip_temp_limit_exceeded", "telemetry_pass_pending_visual"
)
foreach ($fragment in $requiredFragments) {
  Add-Check "source-$($fragment -replace '[^A-Za-z0-9]+','-')" ($source.Contains($fragment)) "fragment=$fragment"
}

$savedErrorAction = $ErrorActionPreference
$ErrorActionPreference = "Continue"
$refusalOutput = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $ScriptPath 2>&1 | Out-String
$refusalExit = $LASTEXITCODE
$ErrorActionPreference = $savedErrorAction
Add-Check "missing-attestation-refused" ($refusalExit -ne 0 -and $refusalOutput.Contains("Refusing camera-follow motor validation")) "exit=$refusalExit"

$failed = @($checks | Where-Object { $_.status -eq "fail" }).Count
$result = [ordered]@{
  schema = "stackchan.camera-follow-wake-validation-contract.v1"
  status = $(if ($failed -eq 0) { "pass" } else { "fail" })
  passed = @($checks | Where-Object { $_.status -eq "pass" }).Count
  failed = $failed
  checks = $checks
}
if ($Json) { $result | ConvertTo-Json -Depth 8 } else { Write-Output "Camera-follow wake validation contract: $($result.status), passed=$($result.passed), failed=$failed" }
if ($failed -gt 0) { exit 1 }
