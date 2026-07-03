param(
  [string]$OutputDir = "",
  [string[]]$Scenario = @(),
  [switch]$Json
)

$ErrorActionPreference = "Stop"

. (Join-Path $PSScriptRoot "preview_python_resolver.ps1")

$repoRoot = Resolve-Path (Join-Path $PSScriptRoot "..")
$pythonPath = Get-StackchanPreviewPython

if ([string]::IsNullOrWhiteSpace($OutputDir)) {
  $OutputDir = Join-Path $repoRoot "output/hardware-sim/latest"
}

$args = @(
  (Join-Path $repoRoot "bridge/hardware_simulator.py"),
  "--out-dir",
  $OutputDir
)

foreach ($item in $Scenario) {
  if (-not [string]::IsNullOrWhiteSpace($item)) {
    $args += @("--scenario", $item)
  }
}

if ($Json) {
  $args += "--json"
}

& $pythonPath @args
if ($LASTEXITCODE -ne 0) {
  throw "Hardware simulation failed."
}

Write-Host "Hardware simulation report:"
Write-Host $OutputDir
