$ErrorActionPreference = "Stop"

. (Join-Path $PSScriptRoot "preview_python_resolver.ps1")

$repoRoot = Resolve-Path (Join-Path $PSScriptRoot "..")
$pythonPath = Get-StackchanPreviewPython
& $pythonPath -m unittest discover -s (Join-Path $repoRoot "bridge") -p "test_*.py"
