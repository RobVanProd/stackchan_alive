param(
  [ValidateSet("stackchan", "stackchan_servo_calibration")]
  [string]$Environment = "stackchan",
  [string]$Port = "",
  [switch]$Monitor
)

$ErrorActionPreference = "Stop"

$repoRoot = Resolve-Path (Join-Path $PSScriptRoot "..")
Set-Location $repoRoot

if ($Environment -eq "stackchan_servo_calibration") {
  Write-Warning "Servo calibration firmware enables motor output. Keep the body clear and powered safely."
}

$args = @("run", "-e", $Environment, "--target", "upload")
if (-not [string]::IsNullOrWhiteSpace($Port)) {
  $args += @("--upload-port", $Port)
}

platformio @args

if ($Monitor) {
  $monitorArgs = @("device", "monitor", "-e", $Environment, "--baud", "115200")
  if (-not [string]::IsNullOrWhiteSpace($Port)) {
    $monitorArgs += @("--port", $Port)
  }
  platformio @monitorArgs
}
