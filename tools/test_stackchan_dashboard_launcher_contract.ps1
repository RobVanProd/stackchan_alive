$ErrorActionPreference = "Stop"

$launcher = Join-Path $PSScriptRoot "start_stackchan_dashboard.ps1"
$installer = Join-Path $PSScriptRoot "install_stackchan_dashboard_shortcut.ps1"
$baseLauncher = Join-Path $PSScriptRoot "start_pc_brain.ps1"
$directmlLauncher = Join-Path $PSScriptRoot "start_pc_brain_directml.ps1"
$packager = Join-Path $PSScriptRoot "package_release.ps1"
$packageVerifier = Join-Path $PSScriptRoot "verify_release_package.ps1"
$icon = Join-Path $PSScriptRoot "..\docs\store-assets\desktop\stackchan-alive.ico"
$dashboardService = Join-Path $PSScriptRoot "..\bridge\dashboard_service.py"
$dashboardApp = Join-Path $PSScriptRoot "..\bridge\dashboard\app.js"

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
  "`$bridgeListeners",
  "bridge[\\/]lan_service\.py",
  "bridge\dashboard_service.py",
  "-WindowStyle Hidden",
  "start_pc_brain_directml.ps1",
  "start_local_research.ps1",
  "local-research-ready",
  "[switch]`$DisableResearch",
  "[switch]`$DisableFaceVision",
  "EnableConversationV2 = `$true",
  "EnableInitiative = `$true",
  "EnableFaceVision = `$true",
  "camera-pairing-code.txt",
  "--conversation-v2-enabled",
  '--enable-research(\s|$)',
  "Start-Process `$DashboardUrl"
)) {
  if (-not $launcherText.Contains($required)) { throw "Dashboard launcher missing contract token: $required" }
}

$baseText = Get-Content -LiteralPath $baseLauncher -Raw
foreach ($required in @(
  '[string]$HostName = "127.0.0.1"',
  "[switch]`$EnableDashboard",
  "Preserving non-Stackchan listener",
  "DashboardHost must be loopback-only.",
  "RobotHost is required when HostName is not loopback.",
  '"--dashboard"',
  '"--robot-host", $RobotHost'
)) {
  if (-not $baseText.Contains($required)) { throw "Base bridge launcher missing dashboard token: $required" }
}
if ($baseText -notmatch '(?s)if \(\$EnableDashboard\).*?\r?\n\}\r?\n\r?\nif \(-not \[string\]::IsNullOrWhiteSpace\(\$RobotHost\)\)') {
  throw "RobotHost must be forwarded independently of dashboard enablement."
}
$peerGuardIndex = $baseText.IndexOf("RobotHost is required when HostName is not loopback.")
$stopExistingIndex = $baseText.IndexOf('if ($StopExisting)')
if ($peerGuardIndex -lt 0 -or $stopExistingIndex -lt 0 -or $peerGuardIndex -gt $stopExistingIndex) {
  throw "Non-loopback peer configuration must fail before an existing listener can be stopped."
}

$directmlText = Get-Content -LiteralPath $directmlLauncher -Raw
foreach ($required in @("-HostName '0.0.0.0'", "-EnableDashboard", "-DashboardPort `$DashboardPort", "dashboardUrl =")) {
  if (-not $directmlText.Contains($required)) { throw "DirectML launcher missing dashboard token: $required" }
}

if ($launcherText.Contains('"--runner-profile", "gemma4-e2b-gguf",' + "`r`n" + '    "--research-enabled"') -or
    $launcherText.Contains('"--runner-profile", "gemma4-e2b-gguf",' + "`n" + '    "--research-enabled"')) {
  throw "Standalone dashboard attach must not claim research without inspecting the bridge command line."
}
if ($launcherText -match 'EnableRoomObservation\s*=\s*\$true') {
  throw "Reset-safe dashboard startup must leave room observation default-off."
}

$dashboardServiceText = Get-Content -LiteralPath $dashboardService -Raw
foreach ($required in @(
  '"debug_http_control_policy"',
  '"motionResumeAvailable"',
  '"motionResumePolicy"',
  'emergency_stop_only',
  'firmware permits emergency stop only'
)) {
  if (-not $dashboardServiceText.Contains($required)) {
    throw "Dashboard motion policy assertion failed: missing $required"
  }
}
$setMotionStart = $dashboardServiceText.IndexOf('    def set_motion(')
$setMotionEnd = $dashboardServiceText.IndexOf('    def set_initiative(', $setMotionStart)
if ($setMotionStart -lt 0 -or $setMotionEnd -le $setMotionStart) {
  throw "Dashboard motion policy assertion failed: set_motion section is missing."
}
$setMotionText = $dashboardServiceText.Substring($setMotionStart, $setMotionEnd - $setMotionStart)
$resumeRefusalIndex = $setMotionText.IndexOf('firmware permits emergency stop only')
$endpointFetchIndex = $setMotionText.IndexOf('self._fetch_robot(endpoint')
if ($resumeRefusalIndex -lt 0 -or $endpointFetchIndex -lt 0 -or
    $resumeRefusalIndex -gt $endpointFetchIndex) {
  throw "Dashboard motion policy assertion failed: Resume refusal must precede robot fetch."
}

$dashboardAppText = Get-Content -LiteralPath $dashboardApp -Raw
foreach ($required in @('robotClearCheck', 'motionResumePolicy', 'emergency_stop_only')) {
  if (-not $dashboardAppText.Contains($required)) {
    throw "Dashboard motion policy assertion failed: UI missing $required"
  }
}

function Get-BoundedJavascriptSection([string]$Text, [string]$StartMarker, [string]$EndMarker) {
  $start = $Text.IndexOf($StartMarker)
  if ($start -lt 0) { throw "Dashboard motion policy assertion failed: missing section start $StartMarker" }
  $end = $Text.IndexOf($EndMarker, $start + $StartMarker.Length)
  if ($end -le $start) { throw "Dashboard motion policy assertion failed: missing section end $EndMarker" }
  return $Text.Substring($start, $end - $start)
}

$renderMotionSection = Get-BoundedJavascriptSection $dashboardAppText 'function renderMotion(robot)' 'function renderEvents(events)'
$changeMotionSection = Get-BoundedJavascriptSection $dashboardAppText 'async function changeMotion(enabled)' 'async function changeInitiative(enabled)'
$clearCheckboxSection = Get-BoundedJavascriptSection $dashboardAppText '$("robotClearCheck").addEventListener("change"' '$("initiativeToggle").addEventListener("change"'

$finallyStart = $changeMotionSection.IndexOf('finally {')
$finallyMatch = if ($finallyStart -ge 0) {
  [regex]::Match($changeMotionSection.Substring($finallyStart), '(?s)^finally\s*\{(?<body>.*?)\r?\n  \}\r?\n\}')
} else {
  [System.Text.RegularExpressions.Match]::Empty
}
$finallyBody = if ($finallyMatch.Success) { $finallyMatch.Groups['body'].Value } else { '' }
if (-not $finallyMatch.Success -or -not ($finallyBody -match '(?m)^\s*\$\("resumeMotionButton"\)\.disabled\s*=\s*!\(\$\("robotClearCheck"\)\.checked\s*&&\s*state\.status\?\.robot\?\.motionResumeAvailable\s*===\s*true\);\s*$')) {
  throw "Dashboard motion policy assertion failed: changeMotion finally path lacks explicit Resume availability guard."
}
if (-not ($clearCheckboxSection -match '(?s)resumeMotionButton.*?motionResumeAvailable\s*===\s*true')) {
  throw "Dashboard motion policy assertion failed: clear-checkbox path lacks explicit Resume availability guard."
}
if (-not ($renderMotionSection -match '(?s)motionResumeAvailable\s*!==\s*true.*?robotClearCheck.*?checked\s*=\s*false.*?robotClearCheck.*?disabled\s*=\s*true.*?resumeMotionButton.*?disabled\s*=\s*true')) {
  throw "Dashboard motion policy assertion failed: render path must clear confirmation and disable Resume under contained/unknown policy."
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
  "stt_supervisor.py",
  "test_stt_supervisor.py",
  "test_dashboard_service.py",
  "bridge/dashboard",
  "tools/start_stackchan_dashboard.ps1",
  "tools/install_stackchan_dashboard_shortcut.ps1",
  "tools/start_local_research.ps1",
  "tools/check_local_research.ps1",
  "tools/searxng/compose.yaml"
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
