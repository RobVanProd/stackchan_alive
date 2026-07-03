param(
  [string]$Profile = "gemma4-e2b-gguf",
  [string]$Persona = "spark",
  [string]$Command = "",
  [switch]$RequireRunner,
  [switch]$Json,
  [string]$OutDir = "output/character-red-team/latest"
)

$ErrorActionPreference = "Stop"

. (Join-Path $PSScriptRoot "preview_python_resolver.ps1")

$repoRoot = Resolve-Path (Join-Path $PSScriptRoot "..")
Set-Location $repoRoot
$pythonPath = Get-StackchanPreviewPython

if (-not [System.IO.Path]::IsPathRooted($OutDir)) {
  $OutDir = Join-Path $repoRoot $OutDir
}

$argsList = @(
  (Join-Path $repoRoot "bridge/character_red_team.py"),
  "--profile",
  $Profile,
  "--persona",
  $Persona,
  "--out-dir",
  $OutDir
)

if (-not [string]::IsNullOrWhiteSpace($Command)) {
  $argsList += @("--command", $Command)
}

if ($RequireRunner) {
  $argsList += "--require-runner"
}

if ($Json) {
  $argsList += "--json"
}

& $pythonPath @argsList
if ($LASTEXITCODE -ne 0) {
  throw "Character red-team gate failed."
}
