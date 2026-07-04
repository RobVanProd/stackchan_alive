param(
  [Parameter(Mandatory = $true)]
  [string]$Url,
  [double]$DurationSeconds = 600.0,
  [double]$IntervalSeconds = 30.0,
  [double]$Timeout = 5.0,
  [string]$OutputDir = "output/android-companion-soak/latest",
  [double]$MinSuccessRate = 1.0,
  [int]$MaxFailures = 0,
  [switch]$Json,
  [switch]$AllowNonAndroid
)

$ErrorActionPreference = "Stop"
. (Join-Path $PSScriptRoot "preview_python_resolver.ps1")

$repoRoot = Resolve-Path (Join-Path $PSScriptRoot "..")
$python = Get-StackchanPreviewPython
$script = Join-Path $repoRoot "bridge/android_companion_soak.py"

$args = @(
  $script,
  $Url,
  "--duration-seconds",
  "$DurationSeconds",
  "--interval-seconds",
  "$IntervalSeconds",
  "--timeout",
  "$Timeout",
  "--out-dir",
  $OutputDir,
  "--min-success-rate",
  "$MinSuccessRate",
  "--max-failures",
  "$MaxFailures"
)
if ($Json) {
  $args += "--json"
}
if ($AllowNonAndroid) {
  $args += "--allow-non-android"
}

Push-Location $repoRoot
try {
  & $python @args
  if ($LASTEXITCODE -ne 0) {
    throw "Android companion screen-off soak failed with exit code $LASTEXITCODE"
  }
} finally {
  Pop-Location
}
