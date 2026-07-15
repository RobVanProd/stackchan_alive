$ErrorActionPreference = "Stop"

$launcher = Join-Path $PSScriptRoot "start_stackchan_dashboard.ps1"
$installer = Join-Path $PSScriptRoot "install_stackchan_dashboard_shortcut.ps1"
$baseLauncher = Join-Path $PSScriptRoot "start_pc_brain.ps1"
$directmlLauncher = Join-Path $PSScriptRoot "start_pc_brain_directml.ps1"
$packager = Join-Path $PSScriptRoot "package_release.ps1"
$packageVerifier = Join-Path $PSScriptRoot "verify_release_package.ps1"
$icon = Join-Path $PSScriptRoot "..\docs\store-assets\desktop\stackchan-alive.ico"

foreach ($path in @($launcher, $installer, $baseLauncher, $directmlLauncher, $packager, $packageVerifier)) {
  $tokens = $null
  $errors = $null
  [System.Management.Automation.Language.Parser]::ParseFile($path, [ref]$tokens, [ref]$errors) | Out-Null
  if ($errors.Count -ne 0) { throw "$path has PowerShell parse errors: $($errors -join '; ')" }
}

$launcherText = Get-Content -LiteralPath $launcher -Raw
foreach ($required in @(
  "stackchan.bridge-dashboard.v1",
  "Get-NetTCPConnection -LocalPort `$DashboardPort",
  "Get-NetTCPConnection -LocalPort `$BridgePort",
  "bridge[\\/]lan_service\.py",
  "bridge\dashboard_service.py",
  "-WindowStyle Hidden",
  "start_pc_brain_directml.ps1",
  "-EnableResearch",
  "Start-Process `$DashboardUrl"
)) {
  if (-not $launcherText.Contains($required)) { throw "Dashboard launcher missing contract token: $required" }
}

$baseText = Get-Content -LiteralPath $baseLauncher -Raw
foreach ($required in @(
  "[switch]`$EnableDashboard",
  "DashboardHost must be loopback-only.",
  '"--dashboard"',
  '"--robot-host", $RobotHost'
)) {
  if (-not $baseText.Contains($required)) { throw "Base bridge launcher missing dashboard token: $required" }
}

$directmlText = Get-Content -LiteralPath $directmlLauncher -Raw
foreach ($required in @("-EnableDashboard", "-DashboardPort `$DashboardPort", "dashboardUrl =")) {
  if (-not $directmlText.Contains($required)) { throw "DirectML launcher missing dashboard token: $required" }
}

$installerText = Get-Content -LiteralPath $installer -Raw
foreach ($required in @(
  "WScript.Shell",
  "Stackchan Alive.lnk",
  "start_stackchan_dashboard.ps1",
  "stackchan-alive.ico",
  'GetFolderPath("LocalApplicationData")',
  "`$StableLauncher",
  "`$Bootstrap"
)) {
  if (-not $installerText.Contains($required)) { throw "Shortcut installer missing contract token: $required" }
}

$packagerText = Get-Content -LiteralPath $packager -Raw
$verifierText = Get-Content -LiteralPath $packageVerifier -Raw
foreach ($required in @(
  "docs/BRIDGE_DASHBOARD.md",
  "docs/store-assets/desktop/stackchan-alive.ico",
  "dashboard_service.py",
  "test_dashboard_service.py",
  "bridge/dashboard",
  "tools/start_stackchan_dashboard.ps1",
  "tools/install_stackchan_dashboard_shortcut.ps1"
)) {
  if (-not $packagerText.Contains($required)) { throw "Release packager omits dashboard asset: $required" }
  if (-not $verifierText.Contains($required)) { throw "Release verifier omits dashboard asset: $required" }
}

$iconBytes = [IO.File]::ReadAllBytes((Resolve-Path $icon))
if ($iconBytes.Length -lt 1000 -or [BitConverter]::ToUInt16($iconBytes, 0) -ne 0 -or
    [BitConverter]::ToUInt16($iconBytes, 2) -ne 1 -or [BitConverter]::ToUInt16($iconBytes, 4) -lt 6) {
  throw "Desktop shortcut icon is not a valid multi-size ICO."
}

Write-Host "Stackchan dashboard launcher contract tests passed."
