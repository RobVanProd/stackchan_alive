param(
  [ValidateSet("Capture", "Check")]
  [string]$Mode = "Capture",
  [ValidateSet(
    "baseline",
    "touch-front-tap",
    "touch-middle-tap",
    "touch-back-tap",
    "touch-front-hold",
    "touch-swipe-forward",
    "touch-swipe-backward",
    "imu-pickup",
    "imu-tilt",
    "imu-putdown",
    "imu-shake"
  )]
  [string]$Step = "baseline",
  [string]$EvidenceRoot = "output\hardware-evidence\final-integration\body-sensor-validation-latest",
  [string]$DeviceHost = "192.168.1.238",
  [int]$DevicePort = 8789,
  [int]$TimeoutSeconds = 6,
  [int]$MinPowerVbusMv = 4400,
  [double]$MaxChipTempC = 68,
  [int]$MaxDisplayFrameUs = 50000,
  [switch]$Json
)

$ErrorActionPreference = "Stop"
$RepoRoot = Resolve-Path (Join-Path $PSScriptRoot "..")
Set-Location $RepoRoot
$SourceCommit = (& git rev-parse HEAD).Trim()
$SourceDirty = -not [string]::IsNullOrWhiteSpace(((& git status --porcelain=v1 --untracked-files=normal) -join "`n"))

$requiredSteps = @(
  "baseline",
  "touch-front-tap",
  "touch-middle-tap",
  "touch-back-tap",
  "touch-front-hold",
  "touch-swipe-forward",
  "touch-swipe-backward",
  "imu-pickup",
  "imu-tilt",
  "imu-putdown",
  "imu-shake"
)

$touchExpectations = @{
  "touch-front-tap" = @{ zone = 1; gesture = 1; zoneCounter = "body_touch_front_events"; gestureCounter = "body_touch_tap_events" }
  "touch-middle-tap" = @{ zone = 2; gesture = 1; zoneCounter = "body_touch_middle_events"; gestureCounter = "body_touch_tap_events" }
  "touch-back-tap" = @{ zone = 3; gesture = 1; zoneCounter = "body_touch_back_events"; gestureCounter = "body_touch_tap_events" }
  "touch-front-hold" = @{ zone = 1; gesture = 2; zoneCounter = "body_touch_front_events"; gestureCounter = "body_touch_hold_events" }
  "touch-swipe-forward" = @{ zone = 3; gesture = 3; zoneCounter = "body_touch_back_events"; gestureCounter = "body_touch_swipe_forward_events" }
  "touch-swipe-backward" = @{ zone = 1; gesture = 4; zoneCounter = "body_touch_front_events"; gestureCounter = "body_touch_swipe_backward_events" }
}

$imuExpectations = @{
  "imu-pickup" = @{ counter = "imu_pickup_events"; pickedUp = $true }
  "imu-tilt" = @{ counter = "imu_tilt_events"; pickedUp = $null }
  "imu-putdown" = @{ counter = "imu_putdown_events"; pickedUp = $false }
  "imu-shake" = @{ counter = "imu_shake_events"; pickedUp = $null }
}

function Get-PropertyValue {
  param($Object, [string]$Name, $Default = $null)
  if ($null -eq $Object) { return $Default }
  $property = $Object.PSObject.Properties[$Name]
  if ($null -eq $property -or $null -eq $property.Value) { return $Default }
  return $property.Value
}

function Test-TrueValue {
  param($Value)
  if ($Value -is [bool]) { return [bool]$Value }
  if ($Value -is [int] -or $Value -is [long]) { return [int64]$Value -ne 0 }
  if ($null -eq $Value) { return $false }
  return ([string]$Value).Trim().ToLowerInvariant() -in @("true", "1", "yes")
}

function Write-JsonAtomic {
  param([string]$Path, $Object)
  $parent = Split-Path -Parent $Path
  if (-not [string]::IsNullOrWhiteSpace($parent)) {
    New-Item -ItemType Directory -Force -Path $parent | Out-Null
  }
  $temp = "$Path.tmp-$([guid]::NewGuid().ToString('N'))"
  try {
    $Object | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $temp -Encoding UTF8
    Move-Item -LiteralPath $temp -Destination $Path -Force
  } finally {
    Remove-Item -LiteralPath $temp -Force -ErrorAction SilentlyContinue
  }
}

function Add-Check {
  param([System.Collections.Generic.List[object]]$Checks, [string]$Id, [bool]$Passed, [string]$Detail)
  $Checks.Add([ordered]@{
      id = $Id
      status = $(if ($Passed) { "pass" } else { "fail" })
      detail = $Detail
    })
}

function Get-SelectedDebug {
  param($Debug)
  $names = @(
    "debug_response_truncated", "ota_expected_sha256", "ota_current_app_confirmed",
    "network_state", "bridge_state",
    "motion_enabled", "servo_rail_enabled", "servo_torque_enabled",
    "power_vbus_valid", "power_vbus_mv", "chip_temp_c", "display_window_max_frame_us",
    "compiled_enable_body_touch", "body_touch_ready", "body_touch_samples",
    "body_touch_read_failures", "body_touch_events", "body_touch_last_raw",
    "body_touch_last_zone", "body_touch_last_gesture", "body_touch_last_event_ms",
    "body_touch_front_events", "body_touch_middle_events", "body_touch_back_events",
    "body_touch_tap_events", "body_touch_hold_events",
    "body_touch_swipe_forward_events", "body_touch_swipe_backward_events",
    "compiled_enable_imu", "imu_ready", "imu_calibrated", "imu_picked_up",
    "imu_samples", "imu_read_failures", "imu_events", "imu_pickup_events",
    "imu_putdown_events", "imu_shake_events", "imu_tilt_events",
    "imu_accel_norm", "imu_gyro_norm", "imu_gravity_x", "imu_gravity_y", "imu_gravity_z"
  )
  $selected = [ordered]@{}
  foreach ($name in $names) {
    $selected[$name] = Get-PropertyValue $Debug $name $null
  }
  return $selected
}

function Invoke-CheckEvidence {
  param([string]$ManifestPath)

  $checks = [System.Collections.Generic.List[object]]::new()
  if (-not (Test-Path -LiteralPath $ManifestPath -PathType Leaf)) {
    Add-Check $checks "manifest" $false "Missing capture manifest: $ManifestPath"
    return [ordered]@{ schema = "stackchan.body-sensor-validation-report.v1"; status = "fail"; checks = $checks; passed = 0; failed = 1 }
  }

  try {
    $manifest = Get-Content -LiteralPath $ManifestPath -Raw | ConvertFrom-Json
  } catch {
    Add-Check $checks "manifest" $false "Invalid capture manifest: $($_.Exception.Message)"
    return [ordered]@{ schema = "stackchan.body-sensor-validation-report.v1"; status = "fail"; checks = $checks; passed = 0; failed = 1 }
  }

  Add-Check $checks "schema" ($manifest.schema -eq "stackchan.body-sensor-validation-captures.v1") "schema=$($manifest.schema)"
  $captures = @($manifest.captures)
  Add-Check $checks "capture-count" ($captures.Count -eq $requiredSteps.Count) "captures=$($captures.Count) expected=$($requiredSteps.Count)"
  $observedSteps = @($captures | ForEach-Object { [string]$_.step })
  Add-Check $checks "capture-order" (($observedSteps -join "|") -eq ($requiredSteps -join "|")) "observed=$($observedSteps -join ',')"

  if ($captures.Count -gt 0) {
    $baseline = $captures[0].debug
    Add-Check $checks "baseline-touch-idle" ([int64](Get-PropertyValue $baseline "body_touch_last_raw" -1) -eq 0) "raw=$(Get-PropertyValue $baseline 'body_touch_last_raw' -1)"
    Add-Check $checks "baseline-resting" (-not (Test-TrueValue (Get-PropertyValue $baseline "imu_picked_up" $true))) "imu_picked_up=$(Get-PropertyValue $baseline 'imu_picked_up' $null)"

    for ($i = 0; $i -lt $captures.Count; ++$i) {
      $capture = $captures[$i]
      $debug = $capture.debug
      $prefix = "capture-$('{0:d2}' -f ($i + 1))-$($capture.step)"
      $bridgeState = ([string](Get-PropertyValue $debug "bridge_state" "")).ToLowerInvariant()
      $bridgeHealthy = $bridgeState -in @("ready", "listening", "thinking", "responding")
      $networkHealthy = ([string](Get-PropertyValue $debug "network_state" "")).ToLowerInvariant() -eq "connected"
      $peripheralsReady = [int](Get-PropertyValue $debug "compiled_enable_body_touch" 0) -eq 1 -and
        (Test-TrueValue (Get-PropertyValue $debug "body_touch_ready" $false)) -and
        [int](Get-PropertyValue $debug "compiled_enable_imu" 0) -eq 1 -and
        (Test-TrueValue (Get-PropertyValue $debug "imu_ready" $false)) -and
        (Test-TrueValue (Get-PropertyValue $debug "imu_calibrated" $false))
      $safeOutputs = -not (Test-TrueValue (Get-PropertyValue $debug "motion_enabled" $false)) -and
        -not (Test-TrueValue (Get-PropertyValue $debug "servo_rail_enabled" $false)) -and
        -not (Test-TrueValue (Get-PropertyValue $debug "servo_torque_enabled" $false))
      $vbus = [int64](Get-PropertyValue $debug "power_vbus_mv" 0)
      $temp = [double](Get-PropertyValue $debug "chip_temp_c" 999)
      $frameUs = [int64](Get-PropertyValue $debug "display_window_max_frame_us" ([int64]::MaxValue))
      Add-Check $checks "$prefix-ready" ($peripheralsReady -and $networkHealthy -and $bridgeHealthy -and -not (Test-TrueValue (Get-PropertyValue $debug "debug_response_truncated" $true))) "peripherals=$peripheralsReady network=$networkHealthy bridge=$bridgeState"
      Add-Check $checks "$prefix-motion-off" $safeOutputs "motion=$(Get-PropertyValue $debug 'motion_enabled' $null) rail=$(Get-PropertyValue $debug 'servo_rail_enabled' $null) torque=$(Get-PropertyValue $debug 'servo_torque_enabled' $null)"
      Add-Check $checks "$prefix-runtime-gates" ((Test-TrueValue (Get-PropertyValue $debug "power_vbus_valid" $false)) -and $vbus -ge $MinPowerVbusMv -and $temp -le $MaxChipTempC -and $frameUs -le $MaxDisplayFrameUs) "vbus_mv=$vbus temp_c=$temp frame_us=$frameUs"
      Add-Check $checks "$prefix-io-clean" ([int64](Get-PropertyValue $debug "body_touch_read_failures" -1) -eq [int64](Get-PropertyValue $baseline "body_touch_read_failures" -2) -and [int64](Get-PropertyValue $debug "imu_read_failures" -1) -eq [int64](Get-PropertyValue $baseline "imu_read_failures" -2)) "touch_failures=$(Get-PropertyValue $debug 'body_touch_read_failures' $null) imu_failures=$(Get-PropertyValue $debug 'imu_read_failures' $null)"

      if ($i -eq 0) { continue }
      $previous = $captures[$i - 1].debug
      if ($touchExpectations.ContainsKey([string]$capture.step)) {
        $expected = $touchExpectations[[string]$capture.step]
        $touchAdvanced = [int64](Get-PropertyValue $debug "body_touch_events" 0) -gt [int64](Get-PropertyValue $previous "body_touch_events" 0)
        $zoneAdvanced = [int64](Get-PropertyValue $debug $expected.zoneCounter 0) -gt [int64](Get-PropertyValue $previous $expected.zoneCounter 0)
        $gestureAdvanced = [int64](Get-PropertyValue $debug $expected.gestureCounter 0) -gt [int64](Get-PropertyValue $previous $expected.gestureCounter 0)
        $mappingMatches = [int](Get-PropertyValue $debug "body_touch_last_zone" 0) -eq [int]$expected.zone -and [int](Get-PropertyValue $debug "body_touch_last_gesture" 0) -eq [int]$expected.gesture
        Add-Check $checks "$prefix-event" ($touchAdvanced -and $zoneAdvanced -and $gestureAdvanced -and $mappingMatches) "zone=$(Get-PropertyValue $debug 'body_touch_last_zone' $null)/$($expected.zone) gesture=$(Get-PropertyValue $debug 'body_touch_last_gesture' $null)/$($expected.gesture)"
      } elseif ($imuExpectations.ContainsKey([string]$capture.step)) {
        $expected = $imuExpectations[[string]$capture.step]
        $eventsAdvanced = [int64](Get-PropertyValue $debug "imu_events" 0) -gt [int64](Get-PropertyValue $previous "imu_events" 0)
        $counterAdvanced = [int64](Get-PropertyValue $debug $expected.counter 0) -gt [int64](Get-PropertyValue $previous $expected.counter 0)
        $stateMatches = $null -eq $expected.pickedUp -or (Test-TrueValue (Get-PropertyValue $debug "imu_picked_up" $false)) -eq [bool]$expected.pickedUp
        Add-Check $checks "$prefix-event" ($eventsAdvanced -and $counterAdvanced -and $stateMatches) "counter=$($expected.counter) before=$(Get-PropertyValue $previous $expected.counter 0) after=$(Get-PropertyValue $debug $expected.counter 0) picked_up=$(Get-PropertyValue $debug 'imu_picked_up' $null)"
      }
    }

    if ($captures.Count -gt 1) {
      $last = $captures[$captures.Count - 1].debug
      Add-Check $checks "touch-samples-advanced" ([int64](Get-PropertyValue $last "body_touch_samples" 0) -gt [int64](Get-PropertyValue $baseline "body_touch_samples" 0)) "baseline=$(Get-PropertyValue $baseline 'body_touch_samples' 0) final=$(Get-PropertyValue $last 'body_touch_samples' 0)"
      Add-Check $checks "imu-samples-advanced" ([int64](Get-PropertyValue $last "imu_samples" 0) -gt [int64](Get-PropertyValue $baseline "imu_samples" 0)) "baseline=$(Get-PropertyValue $baseline 'imu_samples' 0) final=$(Get-PropertyValue $last 'imu_samples' 0)"
    }
  }

  $failed = @($checks | Where-Object { $_.status -eq "fail" }).Count
  $passed = @($checks | Where-Object { $_.status -eq "pass" }).Count
  return [ordered]@{
    schema = "stackchan.body-sensor-validation-report.v1"
    status = $(if ($failed -eq 0) { "pass" } else { "fail" })
    sourceCommit = [string](Get-PropertyValue $manifest "sourceCommit" "")
    sourceDirty = [bool](Get-PropertyValue $manifest "sourceDirty" $true)
    installedFirmwareSha256 = [string](Get-PropertyValue $manifest "installedFirmwareSha256" "")
    generatedAt = (Get-Date).ToUniversalTime().ToString("o")
    evidenceRoot = (Resolve-Path $EvidenceRoot).Path
    passed = $passed
    failed = $failed
    checks = $checks
  }
}

$manifestPath = Join-Path $EvidenceRoot "captures.json"
$reportPath = Join-Path $EvidenceRoot "BODY_SENSOR_VALIDATION.json"

if ($Mode -eq "Check") {
  $report = Invoke-CheckEvidence $manifestPath
  Write-JsonAtomic $reportPath $report
  $serialized = $report | ConvertTo-Json -Depth 12
  if ($Json) { $serialized } else { Write-Output "Body sensor validation: $($report.status), passed=$($report.passed), failed=$($report.failed)"; Write-Output "Report: $reportPath" }
  if ($report.status -ne "pass") { exit 1 }
  exit 0
}

New-Item -ItemType Directory -Force -Path $EvidenceRoot | Out-Null
$manifest = $null
if (Test-Path -LiteralPath $manifestPath -PathType Leaf) {
  $manifest = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json
  if ($manifest.schema -ne "stackchan.body-sensor-validation-captures.v1") {
    throw "Unexpected capture manifest schema: $($manifest.schema)"
  }
  foreach ($identityField in @("sourceCommit", "sourceDirty", "installedFirmwareSha256")) {
    if ($manifest.PSObject.Properties.Name -notcontains $identityField) {
      throw "Existing capture manifest predates required source/firmware identity field '$identityField'. Use a new EvidenceRoot."
    }
  }
} else {
  $manifest = [pscustomobject]@{
    schema = "stackchan.body-sensor-validation-captures.v1"
    startedAt = (Get-Date).ToUniversalTime().ToString("o")
    device = "http://$DeviceHost`:$DevicePort"
    sourceCommit = $SourceCommit
    sourceDirty = $SourceDirty
    installedFirmwareSha256 = ""
    captures = @()
  }
}

$captures = @($manifest.captures)
$expectedStep = if ($captures.Count -lt $requiredSteps.Count) { $requiredSteps[$captures.Count] } else { "complete" }
if ($Step -ne $expectedStep) {
  throw "Expected next step '$expectedStep', received '$Step'. Use a new EvidenceRoot to restart."
}

try {
  $debug = Invoke-RestMethod -Uri "http://$DeviceHost`:$DevicePort/debug" -TimeoutSec $TimeoutSeconds
} catch {
  throw "Could not capture robot /debug: $($_.Exception.Message)"
}

$selected = Get-SelectedDebug $debug
if (Test-TrueValue $selected.debug_response_truncated) { throw "Robot /debug response is truncated." }
if ([int]$selected.compiled_enable_body_touch -ne 1 -or -not (Test-TrueValue $selected.body_touch_ready)) { throw "Body touch is not compiled and ready." }
if ([int]$selected.compiled_enable_imu -ne 1 -or -not (Test-TrueValue $selected.imu_ready) -or -not (Test-TrueValue $selected.imu_calibrated)) { throw "IMU is not compiled, ready, and calibrated." }
if ((Test-TrueValue $selected.motion_enabled) -or (Test-TrueValue $selected.servo_rail_enabled) -or (Test-TrueValue $selected.servo_torque_enabled)) { throw "Motion, servo rail, and torque must all be off for body sensor validation." }
if ($captures.Count -eq 0) {
  $manifest.installedFirmwareSha256 = [string]$selected.ota_expected_sha256
}

$ordinal = $captures.Count + 1
$safeStep = $Step -replace "[^a-z0-9-]", "-"
$snapshotName = "{0:d2}-{1}-debug.json" -f $ordinal, $safeStep
$snapshotPath = Join-Path $EvidenceRoot $snapshotName
Write-JsonAtomic $snapshotPath $debug
$capture = [ordered]@{
  step = $Step
  capturedAt = (Get-Date).ToUniversalTime().ToString("o")
  snapshot = $snapshotName
  debug = $selected
}
$manifest.captures = @($captures) + @($capture)
Write-JsonAtomic $manifestPath $manifest

$result = [ordered]@{
  schema = "stackchan.body-sensor-validation-capture-result.v1"
  status = "captured"
  step = $Step
  ordinal = $ordinal
  snapshot = $snapshotPath
  nextStep = $(if ($ordinal -lt $requiredSteps.Count) { $requiredSteps[$ordinal] } else { "check" })
}
if ($Json) { $result | ConvertTo-Json -Depth 4 } else { Write-Output "Captured $Step ($ordinal/$($requiredSteps.Count)). Next: $($result.nextStep)" }
