param(
  [string]$Persona = "spark",
  [switch]$Json
)

$ErrorActionPreference = "Stop"

. (Join-Path $PSScriptRoot "preview_python_resolver.ps1")

$repoRoot = Resolve-Path (Join-Path $PSScriptRoot "..")
$pythonPath = Get-StackchanPreviewPython
$argsList = @((Join-Path $repoRoot "tools/verify_persona_pack.py"), $Persona)
if ($Json) {
  $argsList += "--json"
}

& $pythonPath @argsList
