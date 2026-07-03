param(
  [string]$OutputDir = "",
  [string[]]$Profile = @(),
  [switch]$RunModelSmoke,
  [string]$SttCommand = "",
  [string]$TtsCommand = "",
  [string]$TtsVoice = "",
  [switch]$Json
)

$ErrorActionPreference = "Stop"

. (Join-Path $PSScriptRoot "preview_python_resolver.ps1")

$repoRoot = Resolve-Path (Join-Path $PSScriptRoot "..")
$pythonPath = Get-StackchanPreviewPython

if ([string]::IsNullOrWhiteSpace($OutputDir)) {
  $OutputDir = Join-Path $repoRoot "output/prearrival-sim/latest"
}

$args = @(
  (Join-Path $repoRoot "bridge/prearrival_sim_check.py"),
  "--out-dir",
  $OutputDir
)

foreach ($item in $Profile) {
  if (-not [string]::IsNullOrWhiteSpace($item)) {
    $args += @("--profile", $item)
  }
}

if ($RunModelSmoke) {
  $args += "--run-model-smoke"
}

if (-not [string]::IsNullOrWhiteSpace($SttCommand)) {
  $args += @("--stt-command", $SttCommand)
}

if (-not [string]::IsNullOrWhiteSpace($TtsCommand)) {
  $args += @("--tts-command", $TtsCommand)
}

if (-not [string]::IsNullOrWhiteSpace($TtsVoice)) {
  $args += @("--tts-voice", $TtsVoice)
}

if ($Json) {
  $args += "--json"
}

& $pythonPath @args
if ($LASTEXITCODE -ne 0) {
  throw "Pre-arrival simulation check failed."
}
