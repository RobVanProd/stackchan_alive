$ErrorActionPreference = "Stop"

$RepoRoot = Resolve-Path (Join-Path $PSScriptRoot "..")
Set-Location $RepoRoot

$runnerSource = Get-Content -LiteralPath "tools\run_full_system_soak_http_motion.ps1" -Raw
foreach ($requiredPattern in @(
    '\[int\]\$PollTimeoutSeconds = 4',
    '\[double\]\$MaxFailedPollRatio = 0\.01',
    'function Write-JsonWithRetry',
    'function Invoke-VerifiedMotionStop',
    'failed_poll_ratio_exceeded',
    'motion_stop_not_verified',
    'RequirePowerForensics',
    'power_forensics_not_armed',
    'RequireFinalIntegration',
    'final_integration_peripheral_not_ready',
    'RequireCameraCapture',
    'camera_capture_probe_not_ready'
  )) {
  if ($runnerSource -notmatch $requiredPattern) {
    throw "Soak runner safety contract missing pattern: $requiredPattern"
  }
}

function Write-Json {
  param([string]$Path, $Object)
  $Object | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $Path -Encoding UTF8
}

function Invoke-Check {
  param(
    [string]$SummaryPath,
    [switch]$RequireReady,
    [switch]$NoMotionProfile,
    [switch]$RequirePowerForensics,
    [switch]$RequireFinalIntegration,
    [switch]$RequireCameraCapture
  )
  if ($RequireFinalIntegration) {
    $output = & "tools\check_full_system_soak_evidence.ps1" -SummaryJsonPath $SummaryPath -MinDurationSeconds 28800 -RequireFinalIntegration -RequireReady:$RequireReady -Json
  } elseif ($RequireCameraCapture) {
    $output = & "tools\check_full_system_soak_evidence.ps1" -SummaryJsonPath $SummaryPath -MinDurationSeconds 60 -NoMotionProfile -RequireCameraCapture -RequireReady:$RequireReady -Json
  } elseif ($RequirePowerForensics) {
    $output = & "tools\check_full_system_soak_evidence.ps1" -SummaryJsonPath $SummaryPath -MinDurationSeconds 28800 -RequirePowerForensics -RequireReady:$RequireReady -Json
  } elseif ($NoMotionProfile) {
    $output = & "tools\check_full_system_soak_evidence.ps1" -SummaryJsonPath $SummaryPath -MinDurationSeconds 600 -NoMotionProfile -RequireReady:$RequireReady -Json
  } elseif ($RequireReady) {
    $output = & "tools\check_full_system_soak_evidence.ps1" -SummaryJsonPath $SummaryPath -MinDurationSeconds 28800 -RequireReady -Json
  } else {
    $output = & "tools\check_full_system_soak_evidence.ps1" -SummaryJsonPath $SummaryPath -MinDurationSeconds 28800 -Json
  }
  return [pscustomobject]@{
    exitCode = $(if ($?) { 0 } else { 1 })
    output = $output
    json = ($output | ConvertFrom-Json)
  }
}

function Invoke-CheckSubprocess {
  param([string]$SummaryPath)
$script = @"
Set-Location '$RepoRoot'
`$ProgressPreference = 'SilentlyContinue'
& 'tools\check_full_system_soak_evidence.ps1' -SummaryJsonPath '$SummaryPath' -MinDurationSeconds 28800 -RequireReady -Json
"@
  $encoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($script))
  $output = & powershell.exe -NoProfile -ExecutionPolicy Bypass -EncodedCommand $encoded
  return [pscustomobject]@{
    exitCode = $LASTEXITCODE
    output = $output
    json = ($output | ConvertFrom-Json)
  }
}

$tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("stackchan-full-system-soak-" + [guid]::NewGuid().ToString("N"))
New-Item -ItemType Directory -Force -Path $tempRoot | Out-Null

try {
  $readyPath = Join-Path $tempRoot "ready-summary.json"
  Write-Json $readyPath ([ordered]@{
      schema = "stackchan.full-system-soak-summary.v1"
      status = "pass"
      issues = @()
      durationSeconds = 28800
      evidenceRoot = $tempRoot
      strict = [ordered]@{
        requireMotion = $true
        minMotionSampleRatio = 0.95
        minMotionUnsuppressedSampleRatio = 0.50
        requireMotionTelemetry = $true
        requireNoMotionTimeouts = $true
        requireBridgeSocket = $true
        requireWakeReady = $true
        requireMicReady = $true
        requireSpeakerReady = $true
        requireRvcWorker = $true
        minPowerVbusMv = 4400
        minPowerVbusReportedMv = 4400
        maxFailedPolls = 0
        maxFailedPollRatio = 0.01
        minPollsForFailedRatio = 100
        maxConsecutiveFailedPolls = 1
        requireVerifiedMotionStop = $true
      }
      records = 960
      okPolls = 959
      failedPolls = 1
      failedPollRatio = 0.001042
      maxConsecutiveFailedPolls = 1
      motionStopVerified = $true
      motionStopAttempts = 1
      motionSamples = 959
      motionSampleRatio = 1.0
      motionUnsuppressedSamples = 929
      motionUnsuppressedSampleRatio = 0.968
      motionTelemetrySamples = 959
      maxMotionSessionTimeouts = 0
      bridgeReadySamples = 900
      bridgeHealthySamples = 959
      networkConnectedSamples = 959
      socketPresentSamples = 960
      wakeReadySamples = 959
      micReadySamples = 959
      speakerReadySamples = 959
      maxFrameUs = 30266
      maxSlowFrames = 23
      motionRefreshes = 1440
      motionRefreshFailures = 0
      rvcWorkerPolls = 480
      rvcWorkerReadySamples = 480
      minPowerVbusMv = 4620
      minPowerVbusReportedMv = 4600
      latestRvcWorkerHealth = [ordered]@{
        ok = $true
        ready = $true
        device = "cuda:0"
        method = "pm"
      }
      serialMotionLines = 12
      serialResetLines = 0
      fatalError = $null
    })

  $ready = Invoke-Check -SummaryPath $readyPath -RequireReady
  if ($ready.exitCode -ne 0) {
    throw "Expected complete full-system soak summary to pass: $($ready.output)"
  }
  if ($ready.json.status -ne "full-system-soak-ready" -or $ready.json.failed -ne 0) {
    throw "Expected ready status with zero failures, got $($ready.json.status)."
  }
  foreach ($id in @("summary-status", "duration", "failed-polls", "failed-poll-ratio", "consecutive-failed-polls", "motion-samples", "motion-unsuppressed-samples", "motion-telemetry", "motion-timeouts", "bridge-healthy", "bridge-socket", "wake-ready", "mic-ready", "speaker-ready", "rvc-worker", "power-vbus-reported-floor", "power-vbus-sample-floor", "display-frame-time", "motion-refreshes", "motion-stop-verified")) {
    $check = @($ready.json.checks | Where-Object { $_.id -eq $id })[0]
    if ($null -eq $check -or $check.status -ne "pass") {
      throw "Expected $id to pass."
    }
  }

  $forensicsPath = Join-Path $tempRoot "forensics-ready-summary.json"
  $forensicsSummary = Get-Content -LiteralPath $readyPath -Raw | ConvertFrom-Json
  $forensicsSummary.strict | Add-Member -NotePropertyName requirePowerForensics -NotePropertyValue $true
  $forensicsSummary | Add-Member -NotePropertyName newPowerForensicsRuntimeEvents -NotePropertyValue 0
  $forensicsSummary | Add-Member -NotePropertyName newPowerForensicsProtectiveEvents -NotePropertyValue 0
  $forensicsSummary | Add-Member -NotePropertyName latestPowerForensics -NotePropertyValue ([pscustomobject]@{
      power_forensics_enabled = $true
      power_forensics_irq_enable_succeeded = $true
      power_forensics_boot_status_valid = $true
    })
  Write-Json $forensicsPath $forensicsSummary

  $forensicsReady = Invoke-Check -SummaryPath $forensicsPath -RequirePowerForensics -RequireReady
  if ($forensicsReady.exitCode -ne 0 -or $forensicsReady.json.failed -ne 0) {
    throw "Expected armed power-forensics summary to pass: $($forensicsReady.output)"
  }
  foreach ($id in @("strict-requirePowerForensics", "power-forensics-armed", "power-forensics-runtime-events", "power-forensics-protective-events")) {
    $check = @($forensicsReady.json.checks | Where-Object { $_.id -eq $id })[0]
    if ($null -eq $check -or $check.status -ne "pass") {
      throw "Expected power-forensics check $id to pass."
    }
  }

  $finalIntegrationPath = Join-Path $tempRoot "final-integration-ready-summary.json"
  $finalIntegrationSummary = Get-Content -LiteralPath $readyPath -Raw | ConvertFrom-Json
  $finalIntegrationSummary.strict | Add-Member -NotePropertyName requireFinalIntegration -NotePropertyValue $true
  $finalIntegrationSummary | Add-Member -NotePropertyName finalIntegrationReadySamples -NotePropertyValue 959
  $finalIntegrationSummary | Add-Member -NotePropertyName bodyRgbFrameDelta -NotePropertyValue 575000
  $finalIntegrationSummary | Add-Member -NotePropertyName bodyTouchSampleDelta -NotePropertyValue 860000
  $finalIntegrationSummary | Add-Member -NotePropertyName imuSampleDelta -NotePropertyValue 720000
  $finalIntegrationSummary | Add-Member -NotePropertyName newBodyRgbWriteFailures -NotePropertyValue 0
  $finalIntegrationSummary | Add-Member -NotePropertyName newBodyTouchReadFailures -NotePropertyValue 0
  $finalIntegrationSummary | Add-Member -NotePropertyName newImuReadFailures -NotePropertyValue 0
  $finalIntegrationSummary | Add-Member -NotePropertyName newImuEvents -NotePropertyValue 0
  $finalIntegrationSummary | Add-Member -NotePropertyName latestFinalIntegration -NotePropertyValue ([pscustomobject]@{
      debug_response_truncated = $false
      power_forensics_schema = "axp2101-v2"
      compiled_enable_body_rgb = 1
      body_rgb_ready = $true
      compiled_enable_body_touch = 1
      body_touch_ready = $true
      compiled_enable_imu = 1
      imu_ready = $true
      imu_calibrated = $true
      compiled_enable_camera = 0
      camera_active = $false
    })
  Write-Json $finalIntegrationPath $finalIntegrationSummary
  $finalIntegrationReady = Invoke-Check -SummaryPath $finalIntegrationPath -RequireFinalIntegration -RequireReady
  if ($finalIntegrationReady.exitCode -ne 0 -or $finalIntegrationReady.json.failed -ne 0) {
    throw "Expected final integration summary to pass: $($finalIntegrationReady.output)"
  }
  foreach ($id in @("strict-requireFinalIntegration", "final-integration-debug-contract", "final-integration-ready", "body-rgb-frames", "body-touch-samples", "imu-samples", "body-rgb-write-failures", "body-touch-read-failures", "imu-read-failures", "unexpected-imu-events", "production-camera-disabled")) {
    if (@($finalIntegrationReady.json.checks | Where-Object { $_.id -eq $id -and $_.status -eq "pass" }).Count -ne 1) {
      throw "Expected final integration check $id to pass."
    }
  }

  $finalIntegrationImuEventPath = Join-Path $tempRoot "final-integration-imu-event-summary.json"
  $finalIntegrationSummary.newImuEvents = 1
  Write-Json $finalIntegrationImuEventPath $finalIntegrationSummary
  $finalIntegrationImuEvent = Invoke-Check -SummaryPath $finalIntegrationImuEventPath -RequireFinalIntegration
  if ($finalIntegrationImuEvent.exitCode -eq 0 -or
      @($finalIntegrationImuEvent.json.checks | Where-Object { $_.id -eq "unexpected-imu-events" -and $_.status -eq "fail" }).Count -ne 1) {
    throw "Expected surprise IMU event to fail final integration checker."
  }

  $cameraPath = Join-Path $tempRoot "camera-ready-summary.json"
  $cameraSummary = Get-Content -LiteralPath $readyPath -Raw | ConvertFrom-Json
  $cameraSummary.durationSeconds = 60
  $cameraSummary.strict.requireMotion = $false
  $cameraSummary.strict.requireNoMotionTimeouts = $false
  $cameraSummary.strict.requireMotionTelemetry = $false
  $cameraSummary.strict.minMotionUnsuppressedSampleRatio = 0
  $cameraSummary.motionSamples = 0
  $cameraSummary.motionSampleRatio = 0
  $cameraSummary.motionUnsuppressedSamples = 0
  $cameraSummary.motionUnsuppressedSampleRatio = 0
  $cameraSummary.strict | Add-Member -NotePropertyName requireCameraCapture -NotePropertyValue $true
  $cameraSummary.strict | Add-Member -NotePropertyName maxCameraCaptureUs -NotePropertyValue 250000
  $cameraSummary | Add-Member -NotePropertyName cameraCaptureReadySamples -NotePropertyValue 959
  $cameraSummary | Add-Member -NotePropertyName cameraFrameDelta -NotePropertyValue 58
  $cameraSummary | Add-Member -NotePropertyName newCameraCaptureFailures -NotePropertyValue 0
  $cameraSummary | Add-Member -NotePropertyName maxCameraCaptureUsObserved -NotePropertyValue 81000
  Write-Json $cameraPath $cameraSummary
  $cameraReady = Invoke-Check -SummaryPath $cameraPath -RequireCameraCapture -RequireReady
  if ($cameraReady.exitCode -ne 0 -or $cameraReady.json.failed -ne 0 -or
      $cameraReady.json.profile -ne "camera-capture") {
    throw "Expected camera capture summary to pass: $($cameraReady.output)"
  }
  foreach ($id in @("strict-requireCameraCapture", "camera-capture-ready", "camera-frames", "camera-capture-failures", "camera-capture-time")) {
    if (@($cameraReady.json.checks | Where-Object { $_.id -eq $id -and $_.status -eq "pass" }).Count -ne 1) {
      throw "Expected camera capture check $id to pass."
    }
  }

  $cameraFailurePath = Join-Path $tempRoot "camera-failure-summary.json"
  $cameraSummary.newCameraCaptureFailures = 1
  Write-Json $cameraFailurePath $cameraSummary
  $cameraFailure = Invoke-Check -SummaryPath $cameraFailurePath -RequireCameraCapture
  if ($cameraFailure.exitCode -eq 0 -or
      @($cameraFailure.json.checks | Where-Object { $_.id -eq "camera-capture-failures" -and $_.status -eq "fail" }).Count -ne 1) {
    throw "Expected camera capture failure to fail formal checker."
  }

  $forensicsEventPath = Join-Path $tempRoot "forensics-event-summary.json"
  $forensicsSummary.newPowerForensicsRuntimeEvents = 1
  Write-Json $forensicsEventPath $forensicsSummary
  $forensicsEvent = Invoke-Check -SummaryPath $forensicsEventPath -RequirePowerForensics
  if ($forensicsEvent.exitCode -eq 0 -or
      -not (@($forensicsEvent.json.checks | Where-Object { $_.id -eq "power-forensics-runtime-events" -and $_.status -eq "fail" }).Count -eq 1)) {
    throw "Expected a new PMIC runtime event to fail the formal checker."
  }

  $noMotionPath = Join-Path $tempRoot "no-motion-summary.json"
  $noMotionSummary = Get-Content -LiteralPath $readyPath -Raw | ConvertFrom-Json
  $noMotionSummary.durationSeconds = 600
  $noMotionSummary.strict.requireMotion = $false
  $noMotionSummary.strict.requireNoMotionTimeouts = $false
  $noMotionSummary.strict.requireMotionTelemetry = $false
  $noMotionSummary.strict.minMotionUnsuppressedSampleRatio = 0
  $noMotionSummary.records = 60
  $noMotionSummary.okPolls = 59
  $noMotionSummary.failedPolls = 1
  $noMotionSummary.motionSamples = 0
  $noMotionSummary.motionSampleRatio = 0
  $noMotionSummary.motionUnsuppressedSamples = 0
  $noMotionSummary.motionUnsuppressedSampleRatio = 0
  $noMotionSummary.motionTelemetrySamples = 59
  $noMotionSummary.bridgeHealthySamples = 59
  $noMotionSummary.networkConnectedSamples = 59
  $noMotionSummary.socketPresentSamples = 60
  $noMotionSummary.wakeReadySamples = 59
  $noMotionSummary.micReadySamples = 59
  $noMotionSummary.speakerReadySamples = 59
  Write-Json $noMotionPath $noMotionSummary

  $noMotion = Invoke-Check -SummaryPath $noMotionPath -NoMotionProfile -RequireReady
  if ($noMotion.exitCode -ne 0 -or $noMotion.json.failed -ne 0 -or $noMotion.json.profile -ne "no-motion") {
    throw "Expected no-motion isolation summary to pass: $($noMotion.output)"
  }
  foreach ($id in @("strict-requireMotion", "strict-requireMotionTelemetry", "motion-samples", "motion-telemetry", "motion-timeouts", "power-vbus-reported-floor", "power-vbus-sample-floor")) {
    $check = @($noMotion.json.checks | Where-Object { $_.id -eq $id })[0]
    if ($null -eq $check -or $check.status -ne "pass") {
      throw "Expected no-motion $id to pass."
    }
  }

  $badPath = Join-Path $tempRoot "bad-summary.json"
  Write-Json $badPath ([ordered]@{
      schema = "stackchan.full-system-soak-summary.v1"
      status = "fail"
      issues = @("motion_samples_below_required_ratio", "rvc_worker_not_ready_for_all_samples")
      durationSeconds = 120
      strict = [ordered]@{
        requireMotion = $true
        minMotionUnsuppressedSampleRatio = 0.50
        requireMotionTelemetry = $true
        requireNoMotionTimeouts = $true
        requireBridgeSocket = $true
        requireWakeReady = $true
        requireMicReady = $true
        requireSpeakerReady = $true
        requireRvcWorker = $true
        minPowerVbusMv = 4400
        minPowerVbusReportedMv = 4400
      }
      records = 4
      okPolls = 3
      failedPolls = 1
      maxConsecutiveFailedPolls = 2
      motionSamples = 1
      motionSampleRatio = 0.3333
      motionUnsuppressedSamples = 0
      motionUnsuppressedSampleRatio = 0.0
      motionTelemetrySamples = 0
      maxMotionSessionTimeouts = 2
      bridgeReadySamples = 2
      bridgeHealthySamples = 2
      networkConnectedSamples = 3
      socketPresentSamples = 1
      wakeReadySamples = 3
      micReadySamples = 2
      speakerReadySamples = 0
      maxFrameUs = 92000
      maxSlowFrames = 240
      motionRefreshes = 1
      motionRefreshFailures = 1
      rvcWorkerPolls = 2
      rvcWorkerReadySamples = 1
      minPowerVbusMv = 4388
      minPowerVbusReportedMv = 4397
      fatalError = "synthetic failure"
    })

  $bad = Invoke-CheckSubprocess -SummaryPath $badPath
  if ($bad.exitCode -eq 0) {
    throw "Expected bad full-system soak summary to fail."
  }
  foreach ($id in @("summary-status", "summary-issues", "duration", "consecutive-failed-polls", "motion-samples", "motion-unsuppressed-samples", "motion-telemetry", "motion-timeouts", "bridge-healthy", "bridge-socket", "speaker-ready", "rvc-worker", "power-vbus-reported-floor", "power-vbus-sample-floor", "display-frame-time", "display-slow-frames", "fatal-error")) {
    $check = @($bad.json.checks | Where-Object { $_.id -eq $id })[0]
    if ($null -eq $check -or $check.status -ne "fail") {
      throw "Expected $id to fail for bad summary."
    }
  }

  $ratioBadPath = Join-Path $tempRoot "ratio-bad-summary.json"
  $ratioBad = Get-Content -LiteralPath $readyPath -Raw | ConvertFrom-Json
  $ratioBad.status = "fail"
  $ratioBad.issues = @("failed_poll_ratio_exceeded")
  $ratioBad.records = 960
  $ratioBad.okPolls = 940
  $ratioBad.failedPolls = 20
  $ratioBad.failedPollRatio = 0.020833
  $ratioBad.motionSamples = 940
  $ratioBad.motionSampleRatio = 1.0
  $ratioBad.motionUnsuppressedSamples = 929
  $ratioBad.motionUnsuppressedSampleRatio = 0.9883
  $ratioBad.motionTelemetrySamples = 940
  $ratioBad.bridgeHealthySamples = 940
  $ratioBad.networkConnectedSamples = 940
  $ratioBad.socketPresentSamples = 960
  $ratioBad.wakeReadySamples = 940
  $ratioBad.micReadySamples = 940
  $ratioBad.speakerReadySamples = 940
  Write-Json $ratioBadPath $ratioBad

  $ratioBadCheck = Invoke-CheckSubprocess -SummaryPath $ratioBadPath
  $ratioCheck = @($ratioBadCheck.json.checks | Where-Object { $_.id -eq "failed-poll-ratio" })[0]
  if ($ratioBadCheck.exitCode -eq 0 -or $null -eq $ratioCheck -or $ratioCheck.status -ne "fail") {
    throw "Expected excessive isolated poll ratio to fail."
  }

  $stopBadPath = Join-Path $tempRoot "motion-stop-bad-summary.json"
  $stopBad = Get-Content -LiteralPath $readyPath -Raw | ConvertFrom-Json
  $stopBad.status = "fail"
  $stopBad.issues = @("motion_stop_not_verified")
  $stopBad.motionStopVerified = $false
  $stopBad.motionStopAttempts = 4
  Write-Json $stopBadPath $stopBad

  $stopBadCheck = Invoke-CheckSubprocess -SummaryPath $stopBadPath
  $stopCheck = @($stopBadCheck.json.checks | Where-Object { $_.id -eq "motion-stop-verified" })[0]
  if ($stopBadCheck.exitCode -eq 0 -or $null -eq $stopCheck -or $stopCheck.status -ne "fail") {
    throw "Expected unverified motion stop to fail."
  }
} finally {
  Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Host "Full-system soak evidence contract tests passed."
