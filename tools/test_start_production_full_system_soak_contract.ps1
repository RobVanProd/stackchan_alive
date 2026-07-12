$ErrorActionPreference = "Stop"
$RepoRoot = Resolve-Path (Join-Path $PSScriptRoot "..")
$Path = Join-Path $RepoRoot "tools\start_production_full_system_soak.ps1"
$source = Get-Content -LiteralPath $Path -Raw
$required = @(
  "http://127.0.0.1:5059", "OperatorPresent", "BodyClear", "ConfirmServoRisk",
  "SkipWorkerRestart", "SkipBridgeRestart", "RequirePowerForensics",
  "RequireFinalIntegration", "start_warm_rocm_full_system_soak.ps1",
  "production-directml-final-integration-servo"
)
foreach ($fragment in $required) {
  if (-not $source.Contains($fragment)) {
    throw "Production full-system soak wrapper contract missing fragment: $fragment"
  }
}
$warmSource = Get-Content -LiteralPath (Join-Path $RepoRoot "tools\start_warm_rocm_full_system_soak.ps1") -Raw
foreach ($fragment in @("RvcWorkerUrl", '"-RvcWorkerUrl"', "unauthenticated local loopback HTTP", "workerHealthRaw", "Use -SkipWorkerRestart for an existing production worker", "Use -SkipBridgeRestart with an existing production DirectML bridge")) {
  if (-not $warmSource.Contains($fragment)) {
    throw "Worker-aware soak wrapper contract missing fragment: $fragment"
  }
}
Write-Output "Production DirectML full-system soak wrapper contract verified."
