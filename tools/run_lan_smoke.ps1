param(
  [string]$OutputDir = "output/lan-smoke/latest",
  [switch]$Json
)

$ErrorActionPreference = "Stop"
. (Join-Path $PSScriptRoot "preview_python_resolver.ps1")

$repoRoot = Resolve-Path (Join-Path $PSScriptRoot "..")
$python = Get-StackchanPreviewPython
$script = Join-Path $repoRoot "bridge/lan_smoke.py"

$args = @($script, "--out-dir", $OutputDir)
if ($Json) {
  $args += "--json"
}

Push-Location $repoRoot
try {
  & $python @args
  if ($LASTEXITCODE -ne 0) {
    throw "LAN bridge smoke check failed with exit code $LASTEXITCODE"
  }
} finally {
  Pop-Location
}
