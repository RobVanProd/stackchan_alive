param(
  [string]$OutputDir = "",
  [switch]$Json
)

$ErrorActionPreference = "Stop"

. (Join-Path $PSScriptRoot "preview_python_resolver.ps1")

$repoRoot = Resolve-Path (Join-Path $PSScriptRoot "..")
$pythonPath = Get-StackchanPreviewPython

if ([string]::IsNullOrWhiteSpace($OutputDir)) {
  $OutputDir = Join-Path $repoRoot "output/litert-lm-smoke/latest"
}

$args = @(
  (Join-Path $repoRoot "bridge/litert_lm_contract_smoke.py"),
  "--out-dir",
  $OutputDir
)

if ($Json) {
  $args += "--json"
}

& $pythonPath @args
if ($LASTEXITCODE -ne 0) {
  throw "LiteRT-LM contract smoke failed."
}

if (-not $Json) {
  Write-Host "LiteRT-LM contract smoke report:"
  Write-Host $OutputDir
}
