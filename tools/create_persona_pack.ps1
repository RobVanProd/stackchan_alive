param(
  [Parameter(Mandatory = $true, Position = 0)]
  [string]$Id,
  [string]$Name = "",
  [string]$Author = "",
  [string]$FromPersona = "spark",
  [switch]$Json
)

$ErrorActionPreference = "Stop"

. (Join-Path $PSScriptRoot "preview_python_resolver.ps1")

$repoRoot = Resolve-Path (Join-Path $PSScriptRoot "..")
$pythonPath = Get-StackchanPreviewPython
$argsList = @(
  (Join-Path $repoRoot "tools/create_persona_pack.py"),
  $Id,
  "--from-persona",
  $FromPersona
)

if (-not [string]::IsNullOrWhiteSpace($Name)) {
  $argsList += @("--name", $Name)
}

if (-not [string]::IsNullOrWhiteSpace($Author)) {
  $argsList += @("--author", $Author)
}

if ($Json) {
  $argsList += "--json"
}

& $pythonPath @argsList
