param(
  [string]$BindHost = "",
  [int]$Port = 8766,
  [double]$Timeout = 10.0,
  [string]$ExpectedEndpointId = "",
  [string]$OutputDir = "output/android-udp-beacon/latest",
  [switch]$Json,
  [switch]$AllowNonAndroid
)

$ErrorActionPreference = "Stop"
. (Join-Path $PSScriptRoot "preview_python_resolver.ps1")

$repoRoot = Resolve-Path (Join-Path $PSScriptRoot "..")
$python = Get-StackchanPreviewPython
$script = Join-Path $repoRoot "bridge/android_udp_beacon_probe.py"

$args = @($script, "--port", "$Port", "--timeout", "$Timeout", "--out-dir", $OutputDir)
if ($BindHost -ne "") {
  $args += @("--bind-host", $BindHost)
}
if ($ExpectedEndpointId -ne "") {
  $args += @("--expected-endpoint-id", $ExpectedEndpointId)
}
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
    throw "Android UDP beacon probe failed with exit code $LASTEXITCODE"
  }
} finally {
  Pop-Location
}
