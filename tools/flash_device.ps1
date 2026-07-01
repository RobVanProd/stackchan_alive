param(
  [ValidateSet("stackchan", "stackchan_servo_calibration")]
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

if ($Environment -eq "stackchan_servo_calibration") {
  Write-Warning "Servo calibration firmware enables motor output. Keep the body clear and powered safely."
  if (-not $ConfirmServoRisk) {
    throw "Refusing to flash servo calibration firmware without -ConfirmServoRisk. Run display-only firmware first, clear the body, and supervise the test."
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
