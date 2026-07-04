param(
  [Parameter(Mandatory = $true)]
  [string]$Url,
  [string]$OutputDir = "output/android-companion-probe/latest",
  [switch]$Json,
  [switch]$AllowNonAndroid
)

$ErrorActionPreference = "Stop"
. (Join-Path $PSScriptRoot "preview_python_resolver.ps1")

$repoRoot = Resolve-Path (Join-Path $PSScriptRoot "..")
$python = Get-StackchanPreviewPython
$script = Join-Path $repoRoot "bridge/android_companion_probe.py"

$args = @($script, $Url, "--out-dir", $OutputDir)
if ($Json) {
  $args += "--json"
}
if ($AllowNonAndroid) {
  $args += "--allow-non-android"
}

Push-Location $repoRoot
try {
  & $python @args
  if ($LASTEXITCODE -ne 0) {
    throw "Android companion probe failed with exit code $LASTEXITCODE"
  }
} finally {
  Pop-Location
}
