$ErrorActionPreference = "Stop"
$repoRoot = Resolve-Path (Join-Path $PSScriptRoot "..")
$platformio = Get-Content -LiteralPath (Join-Path $repoRoot "platformio.ini") -Raw
$main = Get-Content -LiteralPath (Join-Path $repoRoot "src/main.cpp") -Raw

function Get-EnvironmentBlock {
  param([string]$Name)
  $escaped = [regex]::Escape($Name)
  $match = [regex]::Match($platformio, "(?ms)^\[env:$escaped\]\s*(.*?)(?=^\[env:|\z)")
  if (-not $match.Success) {
    throw "Missing PlatformIO environment: $Name"
  }
  return $match.Value
}

foreach ($name in @("stackchan_camera_probe", "stackchan_release_full")) {
  $block = Get-EnvironmentBlock $name
  foreach ($marker in @(
    "-D STACKCHAN_MOTION_ENABLED_AT_BOOT=0",
    "-D STACKCHAN_MOTION_ENABLED_AT_BOOT=1",
    "-D STACKCHAN_AUTONOMOUS_MOTION_AT_BOOT=1"
  )) {
    if ($block -notmatch [regex]::Escape($marker)) {
      throw "$name missing release boot-motion marker: $marker"
    }
  }
}

$base = Get-EnvironmentBlock "stackchan_wake_mww_uplink_servos"
if ($base -notmatch [regex]::Escape("-D STACKCHAN_MOTION_ENABLED_AT_BOOT=0")) {
  throw "The guarded test/rollback servo profile must remain motion-off at boot."
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
