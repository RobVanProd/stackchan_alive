$ErrorActionPreference = "Stop"

$RepoRoot = Resolve-Path (Join-Path $PSScriptRoot "..")
Set-Location $RepoRoot
$TempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("stackchan-body-sensor-validation-" + [guid]::NewGuid().ToString("N"))
New-Item -ItemType Directory -Force -Path $TempRoot | Out-Null

function New-Debug {
  param(
    [int]$TouchEvents, [int]$Front, [int]$Middle, [int]$Back,
    [int]$Tap, [int]$Hold, [int]$Forward, [int]$Backward,
    [int]$Zone, [int]$Gesture,
    [int]$ImuEvents, [int]$Pickup, [int]$Tilt, [int]$Putdown, [int]$Shake,
    [bool]$PickedUp, [int]$Samples
  )
  return [ordered]@{
    debug_response_truncated = $false; network_state = "connected"; bridge_state = "ready"
    motion_enabled = $false; servo_rail_enabled = $false; servo_torque_enabled = $false
    power_vbus_valid = $true; power_vbus_mv = 5012; chip_temp_c = 61.5; display_window_max_frame_us = 32000
    compiled_enable_body_touch = 1; body_touch_ready = $true; body_touch_samples = 1000 + $Samples
    body_touch_read_failures = 0; body_touch_events = $TouchEvents; body_touch_last_raw = 0
    body_touch_last_zone = $Zone; body_touch_last_gesture = $Gesture; body_touch_last_event_ms = $TouchEvents * 100
    body_touch_front_events = $Front; body_touch_middle_events = $Middle; body_touch_back_events = $Back
    body_touch_tap_events = $Tap; body_touch_hold_events = $Hold
    body_touch_swipe_forward_events = $Forward; body_touch_swipe_backward_events = $Backward
    compiled_enable_imu = 1; imu_ready = $true; imu_calibrated = $true; imu_picked_up = $PickedUp
    imu_samples = 2000 + $Samples; imu_read_failures = 0; imu_events = $ImuEvents
    imu_pickup_events = $Pickup; imu_tilt_events = $Tilt; imu_putdown_events = $Putdown; imu_shake_events = $Shake
  }
}

$steps = @(
  @{ step = "baseline"; debug = New-Debug 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 $false 0 },
  @{ step = "touch-front-tap"; debug = New-Debug 1 1 0 0 1 0 0 0 1 1 0 0 0 0 0 $false 1 },
  @{ step = "touch-middle-tap"; debug = New-Debug 2 1 1 0 2 0 0 0 2 1 0 0 0 0 0 $false 2 },
  @{ step = "touch-back-tap"; debug = New-Debug 3 1 1 1 3 0 0 0 3 1 0 0 0 0 0 $false 3 },
  @{ step = "touch-front-hold"; debug = New-Debug 4 2 1 1 3 1 0 0 1 2 0 0 0 0 0 $false 4 },
  @{ step = "touch-swipe-forward"; debug = New-Debug 5 2 1 2 3 1 1 0 3 3 0 0 0 0 0 $false 5 },
  @{ step = "touch-swipe-backward"; debug = New-Debug 6 3 1 2 3 1 1 1 1 4 0 0 0 0 0 $false 6 },
  @{ step = "imu-pickup"; debug = New-Debug 6 3 1 2 3 1 1 1 1 4 1 1 0 0 0 $true 7 },
  @{ step = "imu-tilt"; debug = New-Debug 6 3 1 2 3 1 1 1 1 4 2 1 1 0 0 $true 8 },
  @{ step = "imu-putdown"; debug = New-Debug 6 3 1 2 3 1 1 1 1 4 3 1 1 1 0 $false 9 },
  @{ step = "imu-shake"; debug = New-Debug 6 3 1 2 3 1 1 1 1 4 4 1 1 1 1 $false 10 }
)

try {
  $manifest = [ordered]@{
    schema = "stackchan.body-sensor-validation-captures.v1"
    startedAt = (Get-Date).ToUniversalTime().ToString("o")
    device = "fixture"
    sourceCommit = ("a" * 40)
    sourceDirty = $false
    installedFirmwareSha256 = ("b" * 64)
    captures = @()
  }
  $index = 0
  foreach ($item in $steps) {
    ++$index
    $manifest.captures += [ordered]@{
      step = $item.step
      capturedAt = (Get-Date).ToUniversalTime().ToString("o")
      snapshot = ("{0:d2}-{1}-debug.json" -f $index, $item.step)
      debug = $item.debug
    }
  }
  $manifest | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath (Join-Path $TempRoot "captures.json") -Encoding UTF8

  $output = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File tools\body_sensor_validation.ps1 -Mode Check -EvidenceRoot $TempRoot -Json
  if ($LASTEXITCODE -ne 0) { throw "Expected valid body sensor fixture to pass: $output" }
  $report = $output | ConvertFrom-Json
  if ($report.status -ne "pass" -or $report.failed -ne 0) { throw "Expected zero failures in valid body sensor fixture." }

  $manifest.captures[2].debug.body_touch_last_zone = 3
  $manifest | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath (Join-Path $TempRoot "captures.json") -Encoding UTF8
  $badOutput = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File tools\body_sensor_validation.ps1 -Mode Check -EvidenceRoot $TempRoot -Json
  if ($LASTEXITCODE -eq 0) { throw "Expected incorrect middle-zone mapping to fail." }
  $badReport = $badOutput | ConvertFrom-Json
  if (@($badReport.checks | Where-Object { $_.id -eq "capture-03-touch-middle-tap-event" -and $_.status -eq "fail" }).Count -ne 1) { throw "Expected focused touch mapping failure evidence." }

  $manifest.captures[2].debug.body_touch_last_zone = 2
  $manifest.captures[7].debug.motion_enabled = $true
  $manifest | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath (Join-Path $TempRoot "captures.json") -Encoding UTF8
  $unsafeOutput = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File tools\body_sensor_validation.ps1 -Mode Check -EvidenceRoot $TempRoot -Json
  if ($LASTEXITCODE -eq 0) { throw "Expected motion-enabled sensor evidence to fail." }
  $unsafeReport = $unsafeOutput | ConvertFrom-Json
  if (@($unsafeReport.checks | Where-Object { $_.id -eq "capture-08-imu-pickup-motion-off" -and $_.status -eq "fail" }).Count -ne 1) { throw "Expected focused motion-off failure evidence." }

  Write-Output "Body sensor validation contract verified."
} finally {
  Remove-Item -LiteralPath $TempRoot -Recurse -Force -ErrorAction SilentlyContinue
}
