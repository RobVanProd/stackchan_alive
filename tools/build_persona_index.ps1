param(
  [switch]$Check,
  [switch]$Json
)

$ErrorActionPreference = "Stop"

. (Join-Path $PSScriptRoot "preview_python_resolver.ps1")

$repoRoot = Resolve-Path (Join-Path $PSScriptRoot "..")
$pythonPath = Get-StackchanPreviewPython
$argsList = @((Join-Path $repoRoot "tools/build_persona_index.py"))
if ($Check) {
  $argsList += "--check"
}
if ($Json) {
  $argsList += "--json"
}

& $pythonPath @argsList
exit $LASTEXITCODE
