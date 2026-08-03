$ErrorActionPreference = "Stop"
$repoRoot = Resolve-Path (Join-Path $PSScriptRoot "..")
$platformio = Get-Content -LiteralPath (Join-Path $repoRoot "platformio.ini") -Raw
$main = Get-Content -LiteralPath (Join-Path $repoRoot "src/main.cpp") -Raw
$packageRelease = Get-Content -LiteralPath (Join-Path $repoRoot "tools/package_release.ps1") -Raw

if (Test-Path Env:\PLATFORMIO_BUILD_FLAGS) {
  throw "Release boot-motion verification refuses ambient override: PLATFORMIO_BUILD_FLAGS"
}

function Get-EnvironmentBlock {
  param([string]$Name)
  $escaped = [regex]::Escape($Name)
  $match = [regex]::Match($platformio, "(?ms)^\[env:$escaped\]\s*(.*?)(?=^\[env:|\z)")
  if (-not $match.Success) {
    throw "Missing PlatformIO environment: $Name"
  }
  return $match.Value
}

$cameraProbe = Get-EnvironmentBlock "stackchan_camera_probe"
foreach ($marker in @(
  "-D STACKCHAN_MOTION_ENABLED_AT_BOOT=0",
  "-D STACKCHAN_MOTION_ENABLED_AT_BOOT=1",
  "-D STACKCHAN_AUTONOMOUS_MOTION_AT_BOOT=1"
)) {
  if ($cameraProbe -notmatch [regex]::Escape($marker)) {
    throw "stackchan_camera_probe missing private-lab boot-motion marker: $marker"
  }
}

$base = Get-EnvironmentBlock "stackchan_wake_mww_uplink_servos"
if ($base -notmatch [regex]::Escape("-D STACKCHAN_MOTION_ENABLED_AT_BOOT=0")) {
  throw "The guarded test/rollback servo profile must remain motion-off at boot."
}
foreach ($unsafeMarker in @(
  "-D STACKCHAN_MOTION_ENABLED_AT_BOOT=1",
  "-D STACKCHAN_AUTONOMOUS_MOTION_AT_BOOT=1"
)) {
  if ($base -match [regex]::Escape($unsafeMarker)) {
    throw "The guarded servo inheritance root contains a competing unsafe marker: $unsafeMarker"
  }
}

$publicRelease = Get-EnvironmentBlock "stackchan_release_full"
if ($publicRelease -notmatch [regex]::Escape("extends = env:stackchan_release_forensics")) {
  throw "The public full release must inherit the guarded motion-off release-forensics profile."
}
foreach ($unsafeMarker in @(
  "-D STACKCHAN_MOTION_ENABLED_AT_BOOT=1",
  "-D STACKCHAN_AUTONOMOUS_MOTION_AT_BOOT=1"
)) {
  if ($publicRelease -match [regex]::Escape($unsafeMarker)) {
    throw "The public full release must not request or autonomously refresh motion at boot: $unsafeMarker"
  }
}
if ($publicRelease -notmatch [regex]::Escape("-D STACKCHAN_AUTONOMOUS_MOTION_AT_BOOT=0")) {
  throw "The public full release must explicitly freeze autonomous boot motion off."
}

$packageMotionStatement = "production full firmware starts without requesting motion or autonomous refresh; physical servo rail and torque state require fresh /debug verification"
if (([regex]::Matches($packageRelease, [regex]::Escape($packageMotionStatement))).Count -ne 2) {
  throw "Release manifest and generated README must both state the bounded public full-image boot contract."
}
foreach ($staleClaim in @(
  "production full firmware starts guarded autonomous motion after boot",
  "ships guarded autonomous motion in the production full firmware"
)) {
  if ($packageRelease -match [regex]::Escape($staleClaim)) {
    throw "Release packaging still claims that the public full image starts autonomous motion: $staleClaim"
  }
}

$guardIndex = $packageRelease.IndexOf('"PLATFORMIO_BUILD_FLAGS"')
$presenceGuardIndex = $packageRelease.IndexOf('Test-Path ("Env:\" + $releaseOverrideName)')
$pathWorkIndex = $packageRelease.IndexOf('$physicalRepoRoot =')
if ($guardIndex -lt 0 -or $presenceGuardIndex -lt 0 -or $pathWorkIndex -lt 0 -or
    $guardIndex -gt $pathWorkIndex -or $presenceGuardIndex -gt $pathWorkIndex) {
  throw "Release packaging must reject PLATFORMIO_BUILD_FLAGS before path, cache, build, or package work."
}

$effectiveConfig = (& pio project config --json-output | ConvertFrom-Json)
$effectiveReleaseFlags = ""
foreach ($section in $effectiveConfig) {
  if ([string]$section[0] -ne "env:stackchan_release_full") { continue }
  foreach ($item in $section[1]) {
    if ([string]$item[0] -eq "build_flags") {
      $effectiveReleaseFlags = @($item[1]) -join "`n"
    }
  }
}
if ([string]::IsNullOrWhiteSpace($effectiveReleaseFlags)) {
  throw "The public full release effective build flags are unavailable."
}
$motionDefinitions = @([regex]::Matches(
  $effectiveReleaseFlags,
  '(?<!\S)-D\s+STACKCHAN_MOTION_ENABLED_AT_BOOT=(?<value>[^\s]+)'))
$autonomousDefinitions = @([regex]::Matches(
  $effectiveReleaseFlags,
  '(?<!\S)-D\s+STACKCHAN_AUTONOMOUS_MOTION_AT_BOOT=(?<value>[^\s]+)'))
if ($motionDefinitions.Count -ne 1 -or $motionDefinitions[0].Groups['value'].Value -cne '0') {
  throw "The public full release must have one effective motion-at-boot definition with value 0."
}
if ($autonomousDefinitions.Count -ne 1 -or $autonomousDefinitions[0].Groups['value'].Value -cne '0') {
  throw "The public full release must have one effective autonomous-motion-at-boot definition with value 0."
}

foreach ($pattern in @(
  "volatile bool gAutonomousMotionRequested = STACKCHAN_AUTONOMOUS_MOTION_AT_BOOT != 0",
  "if (!input.motionEnabled || !gMotionRequested)",
  "gAutonomousMotionRequested = false",
  "gAutonomousMotionRequested && !thermalSuppressed && !powerSuppressed && !audioSuppressed",
  "gActuation.refreshSession()",
  "motion_autonomous_at_boot"
)) {
  if ($main -notmatch [regex]::Escape($pattern)) {
    throw "Firmware missing autonomous boot-motion safety contract: $pattern"
  }
}

Write-Host "Release boot-motion contract verified."
