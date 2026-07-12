param(
  [string]$DeviceHost = "192.168.1.238",
  [int]$DevicePort = 8789,
  [string]$DirectMlWorkerUrl = "http://127.0.0.1:5059",
  [int]$DurationSeconds = 3600,
  [int]$PollSeconds = 5,
  [int]$PollTimeoutSeconds = 4,
  [int]$MotionRefreshSeconds = 300,
  [int]$MotionRefreshInitialDelaySeconds = 150,
  [string]$EvidenceRoot = "",
  [switch]$NoSerial,
  [switch]$OperatorPresent,
  [switch]$BodyClear,
  [switch]$ConfirmServoRisk
)

$ErrorActionPreference = "Stop"
$RepoRoot = Resolve-Path (Join-Path $PSScriptRoot "..")
Set-Location $RepoRoot

if (-not $OperatorPresent -or -not $BodyClear -or -not $ConfirmServoRisk) {
  throw "Refusing production full-system soak without -OperatorPresent -BodyClear -ConfirmServoRisk."
}
if ([string]::IsNullOrWhiteSpace($EvidenceRoot)) {
  $stamp = Get-Date -Format "yyyyMMdd-HHmmss"
  $EvidenceRoot = "output\pc-brain\production-directml-final-integration-servo-$stamp"
}

$args = @(
  "-NoProfile", "-ExecutionPolicy", "Bypass",
  "-File", (Join-Path $PSScriptRoot "start_warm_rocm_full_system_soak.ps1"),
  "-DeviceHost", $DeviceHost,
  "-DevicePort", [string]$DevicePort,
  "-RvcWorkerUrl", $DirectMlWorkerUrl,
  "-DurationSeconds", [string]$DurationSeconds,
  "-PollSeconds", [string]$PollSeconds,
  "-PollTimeoutSeconds", [string]$PollTimeoutSeconds,
  "-MotionRefreshSeconds", [string]$MotionRefreshSeconds,
  "-MotionRefreshInitialDelaySeconds", [string]$MotionRefreshInitialDelaySeconds,
  "-EvidenceRoot", $EvidenceRoot,
  "-SkipWorkerRestart", "-SkipBridgeRestart",
  "-RequirePowerForensics", "-RequireFinalIntegration",
  "-OperatorPresent", "-BodyClear", "-ConfirmServoRisk"
)
if ($NoSerial) { $args += "-NoSerial" }

& powershell.exe @args
exit $LASTEXITCODE
