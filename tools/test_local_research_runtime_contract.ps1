$ErrorActionPreference = "Stop"

$checker = Join-Path $PSScriptRoot "check_local_research.ps1"
$starter = Join-Path $PSScriptRoot "start_local_research.ps1"
$compose = Join-Path $PSScriptRoot "searxng\compose.yaml"
$settings = Join-Path $PSScriptRoot "searxng\settings.yml"
$packager = Join-Path $PSScriptRoot "package_release.ps1"
$verifier = Join-Path $PSScriptRoot "verify_release_package.ps1"

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

Write-Host "Local research runtime contract tests passed."
