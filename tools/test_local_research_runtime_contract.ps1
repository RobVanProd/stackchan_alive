$ErrorActionPreference = "Stop"

$checker = Join-Path $PSScriptRoot "check_local_research.ps1"
$starter = Join-Path $PSScriptRoot "start_local_research.ps1"
$compose = Join-Path $PSScriptRoot "searxng\compose.yaml"
$settings = Join-Path $PSScriptRoot "searxng\settings.yml"
$packager = Join-Path $PSScriptRoot "package_release.ps1"
$verifier = Join-Path $PSScriptRoot "verify_release_package.ps1"
$workflow = Join-Path $PSScriptRoot "..\.github\workflows\firmware.yml"

foreach ($path in @($checker, $starter, $packager, $verifier)) {
  $tokens = $null
  $errors = $null
  [void][System.Management.Automation.Language.Parser]::ParseFile(
    $path,
    [ref]$tokens,
    [ref]$errors
  )
  if ($errors.Count -ne 0) {
    throw "$path has PowerShell parse errors: $($errors -join '; ')"
  }
}

$checkerText = Get-Content -LiteralPath $checker -Raw
foreach ($required in @(
  "stackchan.local-research-gate.v1",
  "http://127.0.0.1:8080",
  "Get-NetTCPConnection",
  "searxng_listener_missing",
  "searxng_listener_not_loopback_only",
  "research_acceptance_runtime_missing",
  "`$ResearchAcceptance",
  "research_acceptance.py",
  "broker_search_fetch_acceptance_failed"
)) {
  if (-not $checkerText.Contains($required)) {
    throw "Local research checker missing contract token: $required"
  }
}

$starterText = Get-Content -LiteralPath $starter -Raw
foreach ($required in @(
  "stackchan.local-research-start.v1",
  "docker.io/searxng/searxng:2026.7.24-4f64d9501",
  "container_runtime_missing",
  "container_runtime_not_ready",
  "RandomNumberGenerator",
  "Remove-Item Env:\SEARXNG_SECRET",
  "compose -f `$ComposeFile up -d"
)) {
  if (-not $starterText.Contains($required)) {
    throw "Local research starter missing contract token: $required"
  }
}
foreach ($forbidden in @("winget", "choco", "Install-Package", "Start-BitsTransfer", "msiexec")) {
  if ($starterText -match [regex]::Escape($forbidden)) {
    throw "Local research starter must not install or elevate system software: $forbidden"
  }
}

$nativeStderrRoot = Join-Path ([IO.Path]::GetTempPath()) (
  "stackchan-local-research-native-stderr-" + [guid]::NewGuid().ToString("N")
)
$nativeStderrTools = Join-Path $nativeStderrRoot "tools"
$nativeStderrBin = Join-Path $nativeStderrRoot "bin"
$nativeStderrMarker = Join-Path $nativeStderrRoot "compose-started"
$previousPath = $env:PATH
$previousMarker = $env:STACKCHAN_LOCAL_RESEARCH_NATIVE_STDERR_TEST_MARKER
try {
  New-Item -ItemType Directory -Force -Path $nativeStderrTools, $nativeStderrBin | Out-Null
  Copy-Item -LiteralPath $starter -Destination (Join-Path $nativeStderrTools "start_local_research.ps1")
  New-Item -ItemType Directory -Force -Path (Join-Path $nativeStderrTools "searxng") | Out-Null
  Set-Content -LiteralPath (Join-Path $nativeStderrTools "searxng\compose.yaml") -Value "services: {}"
  Set-Content -LiteralPath (Join-Path $nativeStderrTools "check_local_research.ps1") -Value @'
param(
  [string]$SearxngUrl,
  [switch]$Json
)
$ready = Test-Path -LiteralPath $env:STACKCHAN_LOCAL_RESEARCH_NATIVE_STDERR_TEST_MARKER
[ordered]@{
  schema = "stackchan.local-research-gate.v1"
  pass = $ready
} | ConvertTo-Json
if ($ready) { exit 0 }
exit 1
'@
  Set-Content -LiteralPath (Join-Path $nativeStderrBin "docker.cmd") -Value @'
@echo off
if "%1"=="info" exit /b 0
if "%1"=="compose" (
  if "%2"=="version" exit /b 0
  echo fake compose progress 1>&2
  type nul > "%STACKCHAN_LOCAL_RESEARCH_NATIVE_STDERR_TEST_MARKER%"
  exit /b 0
)
exit /b 1
'@
  $env:STACKCHAN_LOCAL_RESEARCH_NATIVE_STDERR_TEST_MARKER = $nativeStderrMarker
  $env:PATH = "$nativeStderrBin;$previousPath"
  $oldErrorActionPreference = $ErrorActionPreference
  $ErrorActionPreference = "Continue"
  try {
    $nativeStderrOutput = @(
      & powershell.exe -NoProfile -ExecutionPolicy Bypass `
        -File (Join-Path $nativeStderrTools "start_local_research.ps1") `
        -Runtime docker -ReadyTimeoutSeconds 15 -Json 2>&1
    )
    $nativeStderrExit = $LASTEXITCODE
  } finally {
    $ErrorActionPreference = $oldErrorActionPreference
  }
  try {
    $nativeStderrResult = ($nativeStderrOutput -join "`n") | ConvertFrom-Json
  } catch {
    throw "Local research starter did not preserve structured output when compose wrote progress to stderr."
  }
  if ($nativeStderrExit -ne 0 -or
      [string]$nativeStderrResult.status -ne "local-research-ready" -or
      -not [bool]$nativeStderrResult.started) {
    throw "Local research starter treated successful compose stderr progress as a failure."
  }
} finally {
  $env:PATH = $previousPath
  if ($null -eq $previousMarker) {
    Remove-Item Env:\STACKCHAN_LOCAL_RESEARCH_NATIVE_STDERR_TEST_MARKER -ErrorAction SilentlyContinue
  } else {
    $env:STACKCHAN_LOCAL_RESEARCH_NATIVE_STDERR_TEST_MARKER = $previousMarker
  }
  Remove-Item -LiteralPath $nativeStderrRoot -Recurse -Force -ErrorAction SilentlyContinue
}

$composeText = Get-Content -LiteralPath $compose -Raw
$settingsText = Get-Content -LiteralPath $settings -Raw
if ($composeText -notmatch 'image:\s+docker\.io/searxng/searxng:2026\.7\.24-4f64d9501' -or
    $composeText -match 'searxng:latest' -or
    $composeText -notmatch '"127\.0\.0\.1:8080:8080"') {
  throw "SearXNG compose must use the reviewed image tag and publish loopback only."
}
foreach ($engine in @("duckduckgo", "wikipedia", "brave")) {
  if ($settingsText -notmatch "(?m)^\s+-\s+$engine\s*$") {
    throw "SearXNG settings omit allowlisted engine: $engine"
  }
}
if ($settingsText -notmatch '(?m)^\s+formats:\s*$' -or
    $settingsText -notmatch '(?m)^\s+-\s+json\s*$') {
  throw "SearXNG settings must enable JSON output."
}

$invalidOutput = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $starter `
  -SearxngUrl "http://localhost:8080" -Json 2>&1
$invalidExit = $LASTEXITCODE
$invalid = ($invalidOutput -join "`n") | ConvertFrom-Json
if ($invalidExit -eq 0 -or [bool]$invalid.started -or
    [string]$invalid.error -ne "searxng_url_not_loopback_contract") {
  throw "Local research starter did not fail closed on an alternate endpoint."
}

$listeners = @(Get-NetTCPConnection -LocalPort 8080 -State Listen -ErrorAction SilentlyContinue)
if ($listeners.Count -eq 0) {
  $missingOutput = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $checker -Json 2>&1
  $missingExit = $LASTEXITCODE
  $missing = ($missingOutput -join "`n") | ConvertFrom-Json
  if ($missingExit -eq 0 -or [bool]$missing.pass -or
      [string]$missing.error -ne "searxng_listener_missing") {
    throw "Local research checker did not return structured missing-listener evidence."
  }
}

$packagerText = Get-Content -LiteralPath $packager -Raw
$verifierText = Get-Content -LiteralPath $verifier -Raw
foreach ($required in @(
  "tools/check_local_research.ps1",
  "tools/start_local_research.ps1",
  "tools/test_local_research_runtime_contract.ps1",
  "tools/searxng/compose.yaml",
  "tools/searxng/settings.yml"
)) {
  if (-not $packagerText.Contains($required)) {
    throw "Release packager omits local research asset: $required"
  }
  if (-not $verifierText.Contains($required)) {
    throw "Release verifier omits local research asset: $required"
  }
}

$workflowText = Get-Content -LiteralPath $workflow -Raw
$nativeJobIndex = $workflowText.IndexOf("  native-tests:")
$windowsBuildIndex = $workflowText.IndexOf("  build:")
$windowsRunnerIndex = if ($windowsBuildIndex -ge 0) {
  $workflowText.IndexOf("runs-on: windows-latest", $windowsBuildIndex)
} else {
  -1
}
$contractStepIndex = $workflowText.IndexOf("Verify Windows bridge launch contracts")
if ($nativeJobIndex -lt 0 -or $windowsBuildIndex -lt 0 -or
    $windowsRunnerIndex -lt $windowsBuildIndex -or
    $contractStepIndex -lt $windowsRunnerIndex) {
  throw "Windows bridge launch contracts must run in the windows-latest build job."
}

# The negative child probes above are expected to exit nonzero. Do not leak that
# stale native exit code into a successful caller such as the GitHub pwsh step.
$global:LASTEXITCODE = 0
Write-Host "Local research runtime contract tests passed."
