param(
  [ValidateSet("stackchan", "stackchan_wifi", "stackchan_wifi_uplink", "stackchan_servo_calibration", "stackchan_full_online", "stackchan_wake_mww_uplink_servos", "stackchan_wake_mww_uplink_servos_hi", "stackchan_wake_mww_uplink_servos_m5", "stackchan_wake_mww_uplink_servos_m5_voiceout", "stackchan_voice_v2", "stackchan_release_forensics")]
  [string]$Environment = "stackchan",
  [string]$Port = "",
  [switch]$Monitor,
  [switch]$ConfirmServoRisk,
  [switch]$DryRun
)

$ErrorActionPreference = "Stop"

$repoRoot = Resolve-Path (Join-Path $PSScriptRoot "..")
Set-Location $repoRoot
. (Join-Path $PSScriptRoot "platformio_resolver.ps1")

if ($Environment -eq "stackchan_wifi_uplink") {
  Write-Warning "Wi-Fi uplink firmware enables mic capture and bridge audio upload with servos disabled. Use only for supervised bring-up."
}

$motorEnabledFirmware = (
  $Environment -eq "stackchan_servo_calibration" -or
  $Environment -eq "stackchan_full_online" -or
  $Environment -eq "stackchan_voice_v2" -or
  $Environment -eq "stackchan_release_forensics" -or
  $Environment -like "*servos*"
)

if ($motorEnabledFirmware) {
  Write-Warning "$Environment firmware enables motor output. Keep the body clear and powered safely."
  if (-not $ConfirmServoRisk) {
    throw "Refusing to flash $Environment firmware without -ConfirmServoRisk. Run display/bridge-only firmware first, clear the body, and supervise the test."
  }
}

$args = @("run", "-e", $Environment, "--target", "upload")
if (-not [string]::IsNullOrWhiteSpace($Port)) {
  $args += @("--upload-port", $Port)
}

if ($DryRun) {
  Write-Host "Dry run: platformio $($args -join ' ')"
} else {
  Invoke-StackchanPlatformio @args
}

if ($Monitor) {
  $monitorArgs = @("device", "monitor", "-e", $Environment, "--baud", "115200")
  if (-not [string]::IsNullOrWhiteSpace($Port)) {
    $monitorArgs += @("--port", $Port)
  }
  if ($DryRun) {
    Write-Host "Dry run: platformio $($monitorArgs -join ' ')"
  } else {
    Invoke-StackchanPlatformio @monitorArgs
  }
}
