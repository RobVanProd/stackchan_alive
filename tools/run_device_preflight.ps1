param(
  [string]$PackageZip = "",
  [string]$Version = "",
  [string]$ExpectedCommit = "",
  [string]$ReportDir = "",
  [switch]$AllowDirty
)

$ErrorActionPreference = "Stop"

$repoRoot = Resolve-Path (Join-Path $PSScriptRoot "..")
Set-Location $repoRoot
. (Join-Path $PSScriptRoot "platformio_resolver.ps1")

$script:PreflightStepResults = @()
$script:PreflightReportWritten = $false

function Write-PreflightReport {
  param(
    [ValidateSet("pass", "fail")]
    [string]$Status,
    [string]$ErrorMessage = ""
  )

  if ([string]::IsNullOrWhiteSpace($ReportDir)) {
    $reportVersion = if ([string]::IsNullOrWhiteSpace($Version)) { "commit-$($ExpectedCommit.Substring(0, [Math]::Min(12, $ExpectedCommit.Length)))" } else { $Version }
    $ReportDir = Join-Path $repoRoot "output/preflight/$reportVersion"
  }

  New-Item -ItemType Directory -Force -Path $ReportDir | Out-Null
  $generatedUtc = (Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")
  $report = [ordered]@{
    schema = "stackchan.preflight-report.v1"
    version = $Version
    commit = $ExpectedCommit
    status = $Status
    generatedUtc = $generatedUtc
    packageZip = $PackageZip
    allowDirty = [bool]$AllowDirty
    error = $ErrorMessage
    steps = @($script:PreflightStepResults)
  }

  $report | ConvertTo-Json -Depth 6 | Set-Content -Path (Join-Path $ReportDir "preflight_report.json") -Encoding UTF8

  $lines = @(
    "# Stackchan Device Preflight Report",
    "",
    "- Version: $Version",
    "- Commit: $ExpectedCommit",
    "- Status: $Status",
    "- Generated UTC: $generatedUtc",
    "- Package ZIP: $PackageZip",
    "- Allow dirty source: $([bool]$AllowDirty)",
    ""
  )

  if (-not [string]::IsNullOrWhiteSpace($ErrorMessage)) {
    $lines += @(
      "## Failure",
      "",
      $ErrorMessage,
      ""
    )
  }

  $lines += @(
    "## Steps",
    ""
  )

  foreach ($step in @($script:PreflightStepResults)) {
    $duration = if ($null -ne $step.durationSeconds) { "$($step.durationSeconds)s" } else { "" }
    $lines += "- $($step.status): $($step.name) $duration".TrimEnd()
  }

  $lines += @(
    "",
    "## Rollout Note",
    "",
    "This preflight proves the no-hardware gates for the named commit and package. Consumer rollout still requires real-device display, servo, soak, speaker-audio evidence, completed production voice-source provenance, and unblocked GitHub Actions."
  )

  $lines | Set-Content -Path (Join-Path $ReportDir "preflight_report.md") -Encoding UTF8
  $script:PreflightReportWritten = $true
}

function Invoke-Step {
  param(
    [string]$Name,
    [scriptblock]$Command
  )

  Write-Host ""
  Write-Host "==> $Name"
  $startedUtc = (Get-Date).ToUniversalTime()
  try {
    & $Command
    if ($LASTEXITCODE -ne 0) {
      throw "Step failed: $Name"
    }
    $endedUtc = (Get-Date).ToUniversalTime()
    $script:PreflightStepResults += [ordered]@{
      name = $Name
      status = "pass"
      startedUtc = $startedUtc.ToString("yyyy-MM-ddTHH:mm:ssZ")
      endedUtc = $endedUtc.ToString("yyyy-MM-ddTHH:mm:ssZ")
      durationSeconds = [Math]::Round(($endedUtc - $startedUtc).TotalSeconds, 3)
    }
  } catch {
    $endedUtc = (Get-Date).ToUniversalTime()
    $script:PreflightStepResults += [ordered]@{
      name = $Name
      status = "fail"
      startedUtc = $startedUtc.ToString("yyyy-MM-ddTHH:mm:ssZ")
      endedUtc = $endedUtc.ToString("yyyy-MM-ddTHH:mm:ssZ")
      durationSeconds = [Math]::Round(($endedUtc - $startedUtc).TotalSeconds, 3)
      error = $_.Exception.Message
    }
    Write-PreflightReport -Status "fail" -ErrorMessage $_.Exception.Message
    throw
  }
}

function Assert-Command {
  param([string]$Name)

  if (-not (Get-Command $Name -ErrorAction SilentlyContinue)) {
    throw "Required command is not available on PATH: $Name"
  }
}

function Assert-CleanSourceTree {
  $dirtyFiles = @(git status --porcelain)
  $generatedMediaDirtyFiles = @(
    $dirtyFiles | Where-Object { $_ -match "^\s*(M|\?\?) docs/media/stackchan_alive_(preview\.(gif|mp4|png)|expression_sheet\.png)$" }
  )
  $sourceDirtyFiles = @(
    $dirtyFiles | Where-Object { $_ -notmatch "^\s*(M|\?\?) docs/media/stackchan_alive_(preview\.(gif|mp4|png)|expression_sheet\.png)$" }
  )

  if ($sourceDirtyFiles.Count -gt 0 -and -not $AllowDirty) {
    $dirtyList = ($sourceDirtyFiles -join [Environment]::NewLine)
    throw "Source worktree is dirty. Commit or discard changes first, or pass -AllowDirty for a diagnostic preflight. Dirty files:$([Environment]::NewLine)$dirtyList"
  }

  if ($generatedMediaDirtyFiles.Count -gt 0) {
    Write-Host "Generated preview media has local changes; package tooling treats these as generated artifacts."
  }
}

function Assert-DependencyPins {
  $platformioLines = Get-Content -LiteralPath "platformio.ini"
  $libDeps = @()
  $insideLibDeps = $false

  foreach ($line in $platformioLines) {
    if ($line -match "^\s*lib_deps\s*=") {
      $insideLibDeps = $true
      continue
    }

    if ($insideLibDeps) {
      if ($line -match "^\s*\S+\s*=" -or $line -match "^\[.+\]") {
        $insideLibDeps = $false
      } elseif ($line -match "^\s+(.+?)\s*$") {
        $dep = $Matches[1].Trim()
        if (-not [string]::IsNullOrWhiteSpace($dep) -and -not $dep.StartsWith('$')) {
          $libDeps += $dep
        }
      }
    }
  }

  foreach ($dep in $libDeps) {
    if ($dep -notmatch "(@|#)[A-Za-z0-9_.-]+$") {
      throw "PlatformIO dependency is not pinned: $dep"
    }
  }

  foreach ($line in Get-Content -LiteralPath "requirements-preview.txt") {
    $trimmed = $line.Trim()
    if ([string]::IsNullOrWhiteSpace($trimmed) -or $trimmed.StartsWith("#")) {
      continue
    }
    if ($trimmed -notmatch "^[A-Za-z0-9_.-]+==[A-Za-z0-9_.-]+$") {
      throw "Preview dependency is not exactly pinned: $trimmed"
    }
  }
}

function Invoke-ToolText {
  param([string[]]$Arguments)

  $oldErrorActionPreference = $ErrorActionPreference
  $ErrorActionPreference = "Continue"
  try {
    $output = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File @Arguments 2>&1
    $exitCode = $LASTEXITCODE
    return [ordered]@{
      ExitCode = $exitCode
      Text = ($output | Out-String)
    }
  } finally {
    $ErrorActionPreference = $oldErrorActionPreference
  }
}

function Assert-TextContains {
  param(
    [string]$Text,
    [string]$Expected
  )

  if ($Text -notmatch [regex]::Escape($Expected)) {
    throw "Expected command output to contain '$Expected'. Output:$([Environment]::NewLine)$Text"
  }
}

function Write-SyntheticAcceptanceArtifacts {
  param(
    [string]$EvidenceRoot,
    [string]$ReleaseTag,
    [string]$Commit
  )

  @(
    "# Release Acceptance",
    "",
    "Current decision: test-ready for device arrival.",
    "",
    "Consumer rollout decision: blocked pending hardware validation.",
    "",
    "## Still Required Before Consumer Rollout",
    "- Display-only flash",
    "- Servo calibration",
    "- Mixed-mode soak",
    "- Power-cycle recovery",
    "- Hardware evidence verification"
  ) | Set-Content -Path (Join-Path $EvidenceRoot "RELEASE_ACCEPTANCE.md") -Encoding UTF8

  $acceptance = [ordered]@{
    schema = "stackchan.release-acceptance.v1"
    version = $ReleaseTag
    commit = $Commit
    currentDecision = "test-ready-for-device-arrival"
    consumerRolloutDecision = "blocked-pending-hardware-validation"
    noHardwareAcceptance = @(
      [ordered]@{ requirement = "clean-release-package"; status = "pass" },
      [ordered]@{ requirement = "dependency-provenance-present"; status = "pass" },
      [ordered]@{ requirement = "voice-review-samples-present"; status = "pass" },
      [ordered]@{ requirement = "servo-risk-gated"; status = "pass" }
    )
    hardwareAcceptanceRequired = @(
      [ordered]@{ requirement = "display-only-flash"; status = "pending-hardware" },
      [ordered]@{ requirement = "servo-calibration"; status = "pending-hardware" },
      [ordered]@{ requirement = "mixed-mode-soak"; status = "pending-hardware" },
      [ordered]@{ requirement = "power-cycle-recovery"; status = "pending-hardware" },
      [ordered]@{ requirement = "hardware-evidence-verification"; status = "pending-hardware" }
    )
  }
  $acceptance | ConvertTo-Json -Depth 5 | Set-Content -Path (Join-Path $EvidenceRoot "release_acceptance.json") -Encoding UTF8
}

function Write-SyntheticVoiceLeadArtifacts {
  param([string]$EvidenceRoot)

  $referenceDir = Join-Path $EvidenceRoot "reference_audio"
  New-Item -ItemType Directory -Force -Path $referenceDir | Out-Null

  $sourceWav = Join-Path $repoRoot "docs/media/voice/stackchan_spark_greeting.wav"
  if (-not (Test-Path -LiteralPath $sourceWav)) {
    throw "Synthetic voice fixture missing: $sourceWav"
  }

  $referenceFile = "reference_audio/stackchan_rvc_bright_robot.wav"
  $referencePath = Join-Path $EvidenceRoot $referenceFile
  Copy-Item -LiteralPath $sourceWav -Destination $referencePath -Force
  $referenceHash = (Get-FileHash -Algorithm SHA256 -LiteralPath $referencePath).Hash.ToLowerInvariant()

  $lead = [ordered]@{
    title = "RVC Bright Robot"
    file = "stackchan_rvc_bright_robot.wav"
    referenceFile = $referenceFile
    sha256 = $referenceHash
    transcript = "Hello. I am Stackchan, and I am awake."
    pitch = "2"
    index_rate = "0.62"
    rms_mix_rate = "0.72"
    protect = "0.28"
  }

  $manifest = [ordered]@{
    schema = "stackchan.rvc-auditions.selftest.v1"
    generatedBy = "run_device_preflight.ps1"
    note = "Synthetic preflight fixture for hardware-evidence verifier gates."
    leadAudition = $lead
    auditions = @($lead)
  }
  $manifest | ConvertTo-Json -Depth 6 | Set-Content -Path (Join-Path $referenceDir "RVC_AUDITIONS.json") -Encoding UTF8

  @(
    "# RVC Auditions",
    "",
    "Synthetic preflight fixture for verifier coverage. This file is intentionally generated by the no-hardware preflight and is not a production voice-source approval.",
    "",
    "## Lead",
    "",
    "- Title: RVC Bright Robot",
    "- Reference WAV: reference_audio/stackchan_rvc_bright_robot.wav",
    "- SHA256: $referenceHash",
    "- Transcript: Hello. I am Stackchan, and I am awake.",
    "- Tuning: pitch 2, index 0.62, RMS mix 0.72, protect 0.28",
    "",
    "## Notes",
    "",
    "The real arrival-day packet copies the selected RVC lead audition from the release package. This synthetic copy exists so negative preflight fixtures can pass the voice-reference gate before intentionally failing the media or serial-marker gate.",
    "It keeps the verifier strict while allowing targeted self-tests."
  ) | Set-Content -Path (Join-Path $referenceDir "RVC_AUDITIONS.md") -Encoding UTF8

  @(
    "# RVC Lead Audition Reference",
    "",
    "This packet stages the current lead voice for speaker review. This is not production voice-source approval.",
    "",
    "- Lead audition: RVC Bright Robot",
    "- Reference WAV: reference_audio/stackchan_rvc_bright_robot.wav",
    "- SHA256: $referenceHash",
    "- Transcript: Hello. I am Stackchan, and I am awake.",
    "- Tuning: pitch 2, index 0.62, RMS mix 0.72, protect 0.28"
  ) | Set-Content -Path (Join-Path $EvidenceRoot "RVC_LEAD_AUDITION.md") -Encoding UTF8

  return $lead
}

function Write-SyntheticNextSteps {
  param(
    [string]$EvidenceRoot,
    [string]$ReleaseTag,
    [string]$Commit
  )

  @(
    "# Stackchan Evidence Next Steps",
    "",
    "Release: $ReleaseTag",
    "Commit: $Commit",
    "Device: SELFTEST",
    "Port: COM_TEST",
    "Operator: preflight",
    "",
    "Synthetic preflight fixture for verifier coverage.",
    "",
    "## Run Order",
    "",
    "1. Run ``RUN_PACKAGE_VERIFY.cmd`` and confirm ``logs/package_verify.log`` ends with ``Release package verified:``.",
    "2. Run ``RUN_DISPLAY_ONLY.cmd`` and confirm the face is visible, flicker-free, and serial logs show display, face, and system telemetry.",
    "3. Add a display photo or short video with ``RUN_ADD_MEDIA.cmd -Type Photo C:\path\stackchan-face.jpg``.",
    "4. Run ``RUN_SERVO_CALIBRATION.cmd`` only with the body clear; this command includes ``-ConfirmServoRisk`` and may move the hardware.",
    "5. Update ``calibration/calibration.yaml`` with measured limits and classify yaw as ``angle``, ``velocity``, or ``disabled``.",
    "6. Run ``RUN_SOAK_MONITOR.cmd`` for at least 30 minutes and record the result in ``OBSERVATIONS.md``.",
    "7. Run ``RUN_PLAY_LEAD_VOICE.cmd`` as the playback reference, record the target speaker path, then add the recording with ``RUN_ADD_MEDIA.cmd -Type Audio C:\path\stackchan-speaker.wav``.",
    "8. Complete ``AUDIO_REVIEW.md`` with real-device speaker results. Generated source WAVs alone do not count.",
    "9. Run ``RUN_PROGRESS_CHECK.cmd`` and fix every missing field, marker, media file, and unchecked checklist item it reports.",
    "10. Run ``RUN_ROLLOUT_STATUS.cmd`` to write ``ROLLOUT_STATUS.md`` and ``ROLLOUT_STATUS.json`` for handoff review.",
    "11. Run ``RUN_EVIDENCE_VERIFY.cmd`` for the strict hardware evidence gate.",
    "12. Run ``RUN_CONSUMER_PROMOTION_CHECK.cmd`` only after strict evidence verification passes.",
    "",
    "## Gates Still Expected",
    "",
    "- Hardware validation remains pending until this packet has real display, servo, soak, calibration, photo/video, and speaker evidence.",
    "- Production voice-source provenance remains pending until the owned or licensed source record is completed.",
    "- RVC voice-base evidence remains review-only until consumer and distribution approvals are explicitly recorded.",
    "",
    "## Hard Stops",
    "",
    "- Do not run servo calibration unless the body is clear and supervised.",
    "- Do not mark the audio gate complete without a recording captured from the actual target speaker path.",
    "- Do not promote if ``CHECKLIST.md`` still has unchecked gates or ``RUN_PROGRESS_CHECK.cmd`` reports missing evidence."
  ) | Set-Content -Path (Join-Path $EvidenceRoot "NEXT_STEPS.md") -Encoding UTF8
}

function Assert-FlashHelperSafety {
  $flashScript = Join-Path $PSScriptRoot "flash_device.ps1"

  $blockedServo = Invoke-ToolText @(
    $flashScript,
    "-Environment", "stackchan_servo_calibration",
    "-DryRun"
  )
  if ($blockedServo.ExitCode -eq 0) {
    throw "Servo calibration dry-run succeeded without -ConfirmServoRisk"
  }
  Assert-TextContains $blockedServo.Text "without -ConfirmServoRisk"

  $servoDryRun = Invoke-ToolText @(
    $flashScript,
    "-Environment", "stackchan_servo_calibration",
    "-ConfirmServoRisk",
    "-DryRun",
    "-Monitor",
    "-Port", "COM_TEST"
  )
  if ($servoDryRun.ExitCode -ne 0) {
    throw "Servo calibration dry-run failed unexpectedly:$([Environment]::NewLine)$($servoDryRun.Text)"
  }
  Assert-TextContains $servoDryRun.Text "Dry run: platformio run -e stackchan_servo_calibration --target upload --upload-port COM_TEST"
  Assert-TextContains $servoDryRun.Text "Dry run: platformio device monitor -e stackchan_servo_calibration --baud 115200 --port COM_TEST"

  $displayDryRun = Invoke-ToolText @(
    $flashScript,
    "-Environment", "stackchan",
    "-DryRun",
    "-Monitor",
    "-Port", "COM_TEST"
  )
  if ($displayDryRun.ExitCode -ne 0) {
    throw "Display-only dry-run failed unexpectedly:$([Environment]::NewLine)$($displayDryRun.Text)"
  }
  Assert-TextContains $displayDryRun.Text "Dry run: platformio run -e stackchan --target upload --upload-port COM_TEST"
  Assert-TextContains $displayDryRun.Text "Dry run: platformio device monitor -e stackchan --baud 115200 --port COM_TEST"
}

function Assert-ReleaseFlashHelperSafety {
  param(
    [string]$ZipPath,
    [switch]$AllowDirtyPackage
  )

  $flashScript = Join-Path $PSScriptRoot "flash_release_firmware.ps1"
  $dirtyPackageArg = @()
  if ($AllowDirtyPackage) {
    $dirtyPackageArg += "-AllowDirtyPackage"
  }

  $blockedArgs = @(
    $flashScript,
    "-PackageZip", $ZipPath,
    "-Firmware", "servo_calibration",
    "-DryRun"
  )
  $blockedServo = Invoke-ToolText ($blockedArgs + $dirtyPackageArg)
  if ($blockedServo.ExitCode -eq 0) {
    throw "Servo calibration package dry-run succeeded without -ConfirmServoRisk"
  }
  Assert-TextContains $blockedServo.Text "without -ConfirmServoRisk"

  $displayArgs = @(
    $flashScript,
    "-PackageZip", $ZipPath,
    "-Firmware", "display_only",
    "-DryRun",
    "-Monitor",
    "-Port", "COM_TEST"
  )
  $displayDryRun = Invoke-ToolText ($displayArgs + $dirtyPackageArg)
  if ($displayDryRun.ExitCode -ne 0) {
    throw "Display package dry-run failed unexpectedly:$([Environment]::NewLine)$($displayDryRun.Text)"
  }
  Assert-TextContains $displayDryRun.Text "Release package verified:"
  Assert-TextContains $displayDryRun.Text "Dry run:"
  Assert-TextContains $displayDryRun.Text "--chip esp32s3"
  Assert-TextContains $displayDryRun.Text "write_flash -z --flash_mode dio --flash_freq 80m --flash_size 16MB"
  Assert-TextContains $displayDryRun.Text "Dry run: platformio device monitor --baud 115200 --port COM_TEST"

  $servoArgs = @(
    $flashScript,
    "-PackageZip", $ZipPath,
    "-Firmware", "servo_calibration",
    "-ConfirmServoRisk",
    "-DryRun",
    "-Port", "COM_TEST"
  )
  $servoDryRun = Invoke-ToolText ($servoArgs + $dirtyPackageArg)
  if ($servoDryRun.ExitCode -ne 0) {
    throw "Servo package dry-run failed unexpectedly:$([Environment]::NewLine)$($servoDryRun.Text)"
  }
  Assert-TextContains $servoDryRun.Text "Release package verified:"
  Assert-TextContains $servoDryRun.Text "Dry run:"
  Assert-TextContains $servoDryRun.Text "--chip esp32s3"
}

function Assert-HardwareEvidenceMediaGate {
  $evidenceRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("stackchan-evidence-media-gate-" + [System.Guid]::NewGuid().ToString("N"))
  $logsDir = Join-Path $evidenceRoot "logs"
  $photosDir = Join-Path $evidenceRoot "photos"
  $audioDir = Join-Path $evidenceRoot "audio"
  $calibrationDir = Join-Path $evidenceRoot "calibration"
  $referenceDir = Join-Path $evidenceRoot "reference_audio"

  New-Item -ItemType Directory -Force -Path $logsDir, $photosDir, $audioDir, $calibrationDir, $referenceDir | Out-Null

  try {
    "ready" | Set-Content -Path (Join-Path $evidenceRoot "README.md") -Encoding UTF8
    "- [x] synthetic gate" | Set-Content -Path (Join-Path $evidenceRoot "CHECKLIST.md") -Encoding UTF8
    "ready" | Set-Content -Path (Join-Path $evidenceRoot "DEVICE_BRINGUP.md") -Encoding UTF8
    "ready" | Set-Content -Path (Join-Path $evidenceRoot "PRODUCTION_READINESS.md") -Encoding UTF8
    $releaseTag = if ([string]::IsNullOrWhiteSpace($Version)) { "v0.0.0-selftest" } else { $Version }
    Write-SyntheticAcceptanceArtifacts -EvidenceRoot $evidenceRoot -ReleaseTag $releaseTag -Commit $ExpectedCommit
    $voiceLeadAudition = Write-SyntheticVoiceLeadArtifacts -EvidenceRoot $evidenceRoot
    Write-SyntheticNextSteps -EvidenceRoot $evidenceRoot -ReleaseTag $releaseTag -Commit $ExpectedCommit

    $observations = @(
      "# Hardware Test Observations",
      "",
      "## Display-Only Flash",
      "- Start UTC: 2026-07-01T00:00:00Z",
      "- End UTC: 2026-07-01T00:10:00Z",
      "- Command: synthetic",
      "- Result: pass",
      "- Reset loop observed: no",
      "- Procedural face visible: yes",
      "- Dry-run servo log observed: yes",
      "",
      "## Servo Calibration Flash",
      "- Start UTC: 2026-07-01T00:10:00Z",
      "- End UTC: 2026-07-01T00:20:00Z",
      "- Command: synthetic",
      "- Result: pass",
      "- Pitch behavior: inside safe range",
      "- Yaw classification: disabled",
      "- Heat or brownout observed: no",
      "- Calibration changes: recorded",
      "",
      "## Soak Test",
      "- Start UTC: 2026-07-01T00:20:00Z",
      "- End UTC: 2026-07-01T00:50:00Z",
      "- Duration: 30 minutes",
      "- Reset, stall, jitter, or heat observed: no",
      "- USB power-cycle recovery: pass"
    )
    $observations | Set-Content -Path (Join-Path $evidenceRoot "OBSERVATIONS.md") -Encoding UTF8

    @(
      "# Stackchan Audio Review",
      "",
      "## Speaker Playback",
      "- Start UTC: 2026-07-01T00:50:00Z",
      "- End UTC: 2026-07-01T00:51:00Z",
      "- Sample played: reference_audio/stackchan_rvc_bright_robot.wav",
      "- Voice variant: RVC Bright Robot (pitch 2, index 0.62, RMS mix 0.72, protect 0.28)",
      "- Speaker recording file: audio/speaker.wav",
      "- Intelligible through device speaker: yes",
      "- Clipping or distortion observed: no",
      "- Volume adequate at normal listening distance: yes",
      "- Delay or playback dropout observed: no",
      "- Selected voice direction: synthetic preflight fixture for RVC Bright Robot lead audition"
    ) | Set-Content -Path (Join-Path $evidenceRoot "AUDIO_REVIEW.md") -Encoding UTF8
    Copy-Item -LiteralPath "docs/media/voice/stackchan_spark_greeting.wav" -Destination (Join-Path $audioDir "speaker.wav")

    @(
      "pitch_min_deg: -15",
      "pitch_max_deg: 15",
      "yaw_mode: disabled",
      "yaw_min_deg: -30",
      "yaw_max_deg: 30"
    ) | Set-Content -Path (Join-Path $calibrationDir "calibration.yaml") -Encoding UTF8

    @(
      "[boot] stackchan_alive mode=display_only serial=v1",
      "[display] M5 display renderer ready",
      "[display] frame_ms_avg=12.40 frame_ms_max=15.80 fps_avg=80.6 fps_window=30.0 frame_budget_us=33333 slow_frames=0",
      "[face] mode=1 blink_count=3 saccade_count=4 blink_open=1.00 breath_y=0.42 gaze_x=0.08 gaze_y=-0.03 gesture_active=0 speech_active=0 speech_env=0.00",
      "[servo] dry-run mode; set STACKCHAN_ENABLE_SERVOS=1 after calibration",
      "[heartbeat] stackchan_alive mode=display_only uptime_ms=10000",
      "[system] heap_free=243000 heap_min=239000 stack_loop_hwm=7200 stack_motion_hwm=3100 stack_face_hwm=2800 stack_intent_hwm=3300",
      "synthetic display log line for verifier negative-test coverage."
    ) | Set-Content -Path (Join-Path $logsDir "display_only_serial.log") -Encoding UTF8
    @(
      "[boot] stackchan_alive mode=servo_calibration serial=v1",
      "[display] M5 display renderer ready",
      "[servo] enabling StackchanSERVO hardware output",
      "[heartbeat] stackchan_alive mode=servo_calibration uptime_ms=10000",
      "synthetic servo log line for verifier negative-test coverage."
    ) | Set-Content -Path (Join-Path $logsDir "servo_calibration_serial.log") -Encoding UTF8
    @(
      "[heartbeat] stackchan_alive mode=servo_calibration uptime_ms=20000",
      "[display] frame_ms_avg=12.80 frame_ms_max=16.10 fps_avg=78.1 fps_window=30.0 frame_budget_us=33333 slow_frames=0",
      "[face] mode=1 blink_count=12 saccade_count=16 blink_open=1.00 breath_y=-0.18 gaze_x=-0.04 gaze_y=0.02 gesture_active=0 speech_active=0 speech_env=0.00",
      "[system] heap_free=242500 heap_min=238800 stack_loop_hwm=7200 stack_motion_hwm=3090 stack_face_hwm=2760 stack_intent_hwm=3280",
      "[heartbeat] stackchan_alive mode=servo_calibration uptime_ms=30000",
      "synthetic soak log line for verifier negative-test coverage."
    ) | Set-Content -Path (Join-Path $logsDir "soak_serial.log") -Encoding UTF8

    [System.IO.File]::WriteAllBytes(
      (Join-Path $photosDir "header_only.png"),
      [byte[]](0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a)
    )

    $metadata = [ordered]@{
      releaseTag = $releaseTag
      commit = $ExpectedCommit
      createdUtc = "2026-07-01T00:00:00Z"
      deviceId = "SELFTEST"
      port = "COM_TEST"
      operator = "preflight"
      package = $null
      voiceLeadAudition = $voiceLeadAudition
      requiredLogs = @(
        "logs/display_only_serial.log",
        "logs/servo_calibration_serial.log",
        "logs/soak_serial.log"
      )
      requiredRecords = @(
        "NEXT_STEPS.md",
        "CHECKLIST.md",
        "RELEASE_ACCEPTANCE.md",
        "release_acceptance.json",
        "OBSERVATIONS.md",
        "AUDIO_REVIEW.md",
        "RVC_LEAD_AUDITION.md",
        "reference_audio/RVC_AUDITIONS.md",
        "reference_audio/RVC_AUDITIONS.json",
        "reference_audio/stackchan_rvc_bright_robot.wav",
        "calibration/calibration.yaml"
      )
    }
    $metadata | ConvertTo-Json -Depth 5 | Set-Content -Path (Join-Path $evidenceRoot "metadata.json") -Encoding UTF8

    $verifyHardwareEvidence = Invoke-ToolText @(
      (Join-Path $PSScriptRoot "verify_hardware_evidence.ps1"),
      "-EvidenceRoot", $evidenceRoot,
      "-AllowMissingPackage"
    )

    if ($verifyHardwareEvidence.ExitCode -eq 0) {
      throw "Hardware evidence verifier accepted a header-only media file."
    }
    Assert-TextContains $verifyHardwareEvidence.Text "too small to be credible"
    $global:LASTEXITCODE = 0
  } finally {
    if (Test-Path -LiteralPath $evidenceRoot) {
      Remove-Item -LiteralPath $evidenceRoot -Recurse -Force
    }
  }
}

function Assert-HardwareEvidenceSerialMarkerGate {
  $evidenceRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("stackchan-evidence-serial-gate-" + [System.Guid]::NewGuid().ToString("N"))
  $logsDir = Join-Path $evidenceRoot "logs"
  $photosDir = Join-Path $evidenceRoot "photos"
  $audioDir = Join-Path $evidenceRoot "audio"
  $calibrationDir = Join-Path $evidenceRoot "calibration"
  $referenceDir = Join-Path $evidenceRoot "reference_audio"

  New-Item -ItemType Directory -Force -Path $logsDir, $photosDir, $audioDir, $calibrationDir, $referenceDir | Out-Null

  try {
    "ready" | Set-Content -Path (Join-Path $evidenceRoot "README.md") -Encoding UTF8
    "- [x] synthetic gate" | Set-Content -Path (Join-Path $evidenceRoot "CHECKLIST.md") -Encoding UTF8
    "ready" | Set-Content -Path (Join-Path $evidenceRoot "DEVICE_BRINGUP.md") -Encoding UTF8
    "ready" | Set-Content -Path (Join-Path $evidenceRoot "PRODUCTION_READINESS.md") -Encoding UTF8
    $releaseTag = if ([string]::IsNullOrWhiteSpace($Version)) { "v0.0.0-selftest" } else { $Version }
    Write-SyntheticAcceptanceArtifacts -EvidenceRoot $evidenceRoot -ReleaseTag $releaseTag -Commit $ExpectedCommit
    $voiceLeadAudition = Write-SyntheticVoiceLeadArtifacts -EvidenceRoot $evidenceRoot
    Write-SyntheticNextSteps -EvidenceRoot $evidenceRoot -ReleaseTag $releaseTag -Commit $ExpectedCommit

    $observations = @(
      "# Hardware Test Observations",
      "",
      "## Display-Only Flash",
      "- Start UTC: 2026-07-01T00:00:00Z",
      "- End UTC: 2026-07-01T00:10:00Z",
      "- Command: synthetic",
      "- Result: pass",
      "- Reset loop observed: no",
      "- Procedural face visible: yes",
      "- Dry-run servo log observed: yes",
      "",
      "## Servo Calibration Flash",
      "- Start UTC: 2026-07-01T00:10:00Z",
      "- End UTC: 2026-07-01T00:20:00Z",
      "- Command: synthetic",
      "- Result: pass",
      "- Pitch behavior: inside safe range",
      "- Yaw classification: disabled",
      "- Heat or brownout observed: no",
      "- Calibration changes: recorded",
      "",
      "## Soak Test",
      "- Start UTC: 2026-07-01T00:20:00Z",
      "- End UTC: 2026-07-01T00:50:00Z",
      "- Duration: 30 minutes",
      "- Reset, stall, jitter, or heat observed: no",
      "- USB power-cycle recovery: pass"
    )
    $observations | Set-Content -Path (Join-Path $evidenceRoot "OBSERVATIONS.md") -Encoding UTF8

    @(
      "# Stackchan Audio Review",
      "",
      "## Speaker Playback",
      "- Start UTC: 2026-07-01T00:50:00Z",
      "- End UTC: 2026-07-01T00:51:00Z",
      "- Sample played: reference_audio/stackchan_rvc_bright_robot.wav",
      "- Voice variant: RVC Bright Robot (pitch 2, index 0.62, RMS mix 0.72, protect 0.28)",
      "- Speaker recording file: audio/speaker.wav",
      "- Intelligible through device speaker: yes",
      "- Clipping or distortion observed: no",
      "- Volume adequate at normal listening distance: yes",
      "- Delay or playback dropout observed: no",
      "- Selected voice direction: synthetic preflight fixture for RVC Bright Robot lead audition"
    ) | Set-Content -Path (Join-Path $evidenceRoot "AUDIO_REVIEW.md") -Encoding UTF8
    Copy-Item -LiteralPath "docs/media/voice/stackchan_spark_greeting.wav" -Destination (Join-Path $audioDir "speaker.wav")

    @(
      "pitch_min_deg: -15",
      "pitch_max_deg: 15",
      "yaw_mode: disabled",
      "yaw_min_deg: -30",
      "yaw_max_deg: 30"
    ) | Set-Content -Path (Join-Path $calibrationDir "calibration.yaml") -Encoding UTF8

    @(
      "[display] M5 display renderer ready",
      "[display] frame_ms_avg=12.40 frame_ms_max=15.80 fps_avg=80.6 fps_window=30.0 frame_budget_us=33333 slow_frames=0",
      "[face] mode=1 blink_count=3 saccade_count=4 blink_open=1.00 breath_y=0.42 gaze_x=0.08 gaze_y=-0.03 gesture_active=0 speech_active=0 speech_env=0.00",
      "[servo] dry-run mode; set STACKCHAN_ENABLE_SERVOS=1 after calibration",
      "[heartbeat] stackchan_alive mode=display_only uptime_ms=10000",
      "[system] heap_free=243000 heap_min=239000 stack_loop_hwm=7200 stack_motion_hwm=3100 stack_face_hwm=2800 stack_intent_hwm=3300",
      "synthetic display log missing boot marker for verifier negative-test coverage."
    ) | Set-Content -Path (Join-Path $logsDir "display_only_serial.log") -Encoding UTF8
    @(
      "[boot] stackchan_alive mode=servo_calibration serial=v1",
      "[display] M5 display renderer ready",
      "[servo] enabling StackchanSERVO hardware output",
      "[heartbeat] stackchan_alive mode=servo_calibration uptime_ms=10000",
      "synthetic servo log line for verifier negative-test coverage."
    ) | Set-Content -Path (Join-Path $logsDir "servo_calibration_serial.log") -Encoding UTF8
    @(
      "[heartbeat] stackchan_alive mode=servo_calibration uptime_ms=20000",
      "[display] frame_ms_avg=12.80 frame_ms_max=16.10 fps_avg=78.1 fps_window=30.0 frame_budget_us=33333 slow_frames=0",
      "[face] mode=1 blink_count=12 saccade_count=16 blink_open=1.00 breath_y=-0.18 gaze_x=-0.04 gaze_y=0.02 gesture_active=0 speech_active=0 speech_env=0.00",
      "[system] heap_free=242500 heap_min=238800 stack_loop_hwm=7200 stack_motion_hwm=3090 stack_face_hwm=2760 stack_intent_hwm=3280",
      "[heartbeat] stackchan_alive mode=servo_calibration uptime_ms=30000",
      "synthetic soak log line for verifier negative-test coverage."
    ) | Set-Content -Path (Join-Path $logsDir "soak_serial.log") -Encoding UTF8

    Copy-Item -LiteralPath "docs/media/stackchan_alive_preview.png" -Destination (Join-Path $photosDir "evidence.png")

    $metadata = [ordered]@{
      releaseTag = $releaseTag
      commit = $ExpectedCommit
      createdUtc = "2026-07-01T00:00:00Z"
      deviceId = "SELFTEST"
      port = "COM_TEST"
      operator = "preflight"
      package = $null
      voiceLeadAudition = $voiceLeadAudition
      requiredLogs = @(
        "logs/display_only_serial.log",
        "logs/servo_calibration_serial.log",
        "logs/soak_serial.log"
      )
      requiredRecords = @(
        "NEXT_STEPS.md",
        "CHECKLIST.md",
        "RELEASE_ACCEPTANCE.md",
        "release_acceptance.json",
        "OBSERVATIONS.md",
        "AUDIO_REVIEW.md",
        "RVC_LEAD_AUDITION.md",
        "reference_audio/RVC_AUDITIONS.md",
        "reference_audio/RVC_AUDITIONS.json",
        "reference_audio/stackchan_rvc_bright_robot.wav",
        "calibration/calibration.yaml"
      )
    }
    $metadata | ConvertTo-Json -Depth 5 | Set-Content -Path (Join-Path $evidenceRoot "metadata.json") -Encoding UTF8

    $verifyHardwareEvidence = Invoke-ToolText @(
      (Join-Path $PSScriptRoot "verify_hardware_evidence.ps1"),
      "-EvidenceRoot", $evidenceRoot,
      "-AllowMissingPackage"
    )

    if ($verifyHardwareEvidence.ExitCode -eq 0) {
      throw "Hardware evidence verifier accepted logs without the display boot marker."
    }
    Assert-TextContains $verifyHardwareEvidence.Text "display-only boot marker"
    $global:LASTEXITCODE = 0
  } finally {
    if (Test-Path -LiteralPath $evidenceRoot) {
      Remove-Item -LiteralPath $evidenceRoot -Recurse -Force
    }
  }
}

function Assert-ArrivalPacketScaffoldGate {
  param(
    [string]$ZipPath,
    [switch]$AllowDirtyPackage
  )

  $preflightReportDir = Join-Path $repoRoot "output/preflight/$Version"
  $preflightReportPath = Join-Path $preflightReportDir "preflight_report.json"
  $preflightBackupPath = $null
  if (Test-Path -LiteralPath $preflightReportPath) {
    $preflightBackupPath = "$preflightReportPath.preflight-selftest-$([System.Guid]::NewGuid().ToString('N')).bak"
    Move-Item -LiteralPath $preflightReportPath -Destination $preflightBackupPath
  }
  New-Item -ItemType Directory -Force -Path $preflightReportDir | Out-Null
  [ordered]@{
    schema = "stackchan.preflight-report.v1"
    version = $Version
    commit = $ExpectedCommit
    status = "pass"
    generatedUtc = (Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")
    note = "Temporary self-test report used to verify arrival-packet checklist annotation."
    steps = @()
  } | ConvertTo-Json -Depth 5 | Set-Content -Path $preflightReportPath -Encoding UTF8

  function Restore-TemporaryPreflightReport {
    Remove-Item -LiteralPath $preflightReportPath -Force -ErrorAction SilentlyContinue
    if (-not [string]::IsNullOrWhiteSpace($preflightBackupPath) -and (Test-Path -LiteralPath $preflightBackupPath)) {
      Move-Item -LiteralPath $preflightBackupPath -Destination $preflightReportPath
    }
  }

  $startArgs = @(
    (Join-Path $PSScriptRoot "start_hardware_evidence.ps1"),
    "-ReleaseTag", $Version,
    "-PackageZip", $ZipPath,
    "-Port", "COM_TEST",
    "-Operator", "preflight",
    "-DeviceId", "SELFTEST"
  )
  if ($AllowDirtyPackage) {
    $startArgs += "-AllowDirtyPackage"
  }

  $created = Invoke-ToolText $startArgs
  if ($created.ExitCode -ne 0) {
    Restore-TemporaryPreflightReport
    throw "Arrival packet scaffold creation failed:$([Environment]::NewLine)$($created.Text)"
  }

  $evidenceRoot = @(
    ($created.Text -split "\r?\n") |
      ForEach-Object { $_.Trim() } |
      Where-Object { -not [string]::IsNullOrWhiteSpace($_) -and (Test-Path -LiteralPath $_) }
  ) | Select-Object -Last 1

  if ([string]::IsNullOrWhiteSpace($evidenceRoot)) {
    Restore-TemporaryPreflightReport
    throw "Could not locate generated arrival packet in output:$([Environment]::NewLine)$($created.Text)"
  }

  $evidenceRoot = (Resolve-Path $evidenceRoot).Path
  $evidenceBase = (Resolve-Path (Join-Path $repoRoot "output/hardware-evidence")).Path

  try {
    foreach ($relativePath in @(
      "README.md",
      "NEXT_STEPS.md",
      "CHECKLIST.md",
      "OBSERVATIONS.md",
      "AUDIO_REVIEW.md",
      "RVC_LEAD_AUDITION.md",
      "metadata.json",
      "logs/package_verify.log",
      "RUN_PLAY_LEAD_VOICE.cmd",
      "RUN_DISPLAY_ONLY.cmd",
      "RUN_SERVO_CALIBRATION.cmd",
      "RUN_SOAK_MONITOR.cmd",
      "RUN_PACKAGE_VERIFY.cmd",
      "RUN_PROGRESS_CHECK.cmd",
      "RUN_ROLLOUT_STATUS.cmd",
      "RUN_ADD_MEDIA.cmd",
      "RUN_EVIDENCE_VERIFY.cmd",
      "RUN_CONSUMER_PROMOTION_CHECK.cmd",
      "reference_audio/RVC_AUDITIONS.md",
      "reference_audio/RVC_AUDITIONS.json",
      "reference_audio/stackchan_rvc_bright_robot.wav"
    )) {
      $path = Join-Path $evidenceRoot ($relativePath -replace "/", "\")
      if (-not (Test-Path -LiteralPath $path)) {
        throw "Arrival packet missing scaffold file: $relativePath"
      }
      if ((Get-Item -LiteralPath $path).Length -lt 1) {
        throw "Arrival packet scaffold file is empty: $relativePath"
      }
    }

    $metadata = Get-Content -LiteralPath (Join-Path $evidenceRoot "metadata.json") -Raw | ConvertFrom-Json
    if ($null -eq $metadata.voiceLeadAudition) {
      throw "Arrival packet metadata missing voiceLeadAudition"
    }
    if ([string]$metadata.voiceLeadAudition.title -ne "RVC Bright Robot") {
      throw "Arrival packet lead voice mismatch: $($metadata.voiceLeadAudition.title)"
    }
    if ([string]$metadata.voiceLeadAudition.referenceFile -ne "reference_audio/stackchan_rvc_bright_robot.wav") {
      throw "Arrival packet lead reference mismatch: $($metadata.voiceLeadAudition.referenceFile)"
    }
    foreach ($field in @(
      @("pitch", "2"),
      @("index_rate", "0.62"),
      @("rms_mix_rate", "0.72"),
      @("protect", "0.28")
    )) {
      $actual = [string]$metadata.voiceLeadAudition.PSObject.Properties[$field[0]].Value
      if ($actual -ne $field[1]) {
        throw "Arrival packet lead setting mismatch for $($field[0]): $actual"
      }
    }

    $leadPath = Join-Path $evidenceRoot "reference_audio/stackchan_rvc_bright_robot.wav"
    $leadHash = (Get-FileHash -Algorithm SHA256 -LiteralPath $leadPath).Hash.ToLowerInvariant()
    if ($leadHash -ne [string]$metadata.voiceLeadAudition.sha256) {
      throw "Arrival packet lead reference hash mismatch"
    }

    $readme = Get-Content -LiteralPath (Join-Path $evidenceRoot "README.md") -Raw
    Assert-TextContains $readme "RUN_PLAY_LEAD_VOICE.cmd"
    Assert-TextContains $readme "real-device speaker recording"

    $nextSteps = Get-Content -LiteralPath (Join-Path $evidenceRoot "NEXT_STEPS.md") -Raw
    Assert-TextContains $nextSteps "RUN_PACKAGE_VERIFY.cmd"
    Assert-TextContains $nextSteps "RUN_CONSUMER_PROMOTION_CHECK.cmd"
    Assert-TextContains $nextSteps "Generated source WAVs alone do not count"
    Assert-TextContains $nextSteps "Do not run servo calibration unless the body is clear"

    $checklist = Get-Content -LiteralPath (Join-Path $evidenceRoot "CHECKLIST.md") -Raw
    Assert-TextContains $checklist 'Pre-marked no-hardware gates were proven by the matching preflight report'
    Assert-TextContains $checklist '- [x] `pio run -e stackchan` passes.'
    Assert-TextContains $checklist '- [x] `tools/run_device_preflight.ps1` passes.'
    Assert-TextContains $checklist '- [x] `tools/verify_release_package.ps1` passes for the release ZIP.'
    Assert-TextContains $checklist '- [ ] GitHub Actions `Firmware` workflow is green on `main`.'
    Assert-TextContains $checklist '- [ ] Production voice-source provenance is completed and no longer marked pending.'

    $audioReview = Get-Content -LiteralPath (Join-Path $evidenceRoot "AUDIO_REVIEW.md") -Raw
    Assert-TextContains $audioReview "reference_audio/stackchan_rvc_bright_robot.wav"
    Assert-TextContains $audioReview "RVC Bright Robot (pitch 2, index 0.62, RMS mix 0.72, protect 0.28)"

    $oldErrorActionPreference = $ErrorActionPreference
    $ErrorActionPreference = "Continue"
    try {
      $progressOutput = & cmd.exe /c (Join-Path $evidenceRoot "RUN_PROGRESS_CHECK.cmd") 2>&1
      $progressExitCode = $LASTEXITCODE
    } finally {
      $ErrorActionPreference = $oldErrorActionPreference
    }
    $progressText = ($progressOutput | Out-String)
    if ($progressExitCode -ne 2) {
      throw "Expected arrival packet progress wrapper to exit 2 for missing real hardware evidence, got $progressExitCode. Output:$([Environment]::NewLine)$progressText"
    }
    Assert-TextContains $progressText "Hardware evidence progress:"
    Assert-TextContains $progressText "RVC lead audition reference hash matches metadata"
    Assert-TextContains $progressText "No real-device speaker recording found under audio/"

    $oldErrorActionPreference = $ErrorActionPreference
    $ErrorActionPreference = "Continue"
    try {
      $rolloutOutput = & cmd.exe /c (Join-Path $evidenceRoot "RUN_ROLLOUT_STATUS.cmd") 2>&1
      $rolloutExitCode = $LASTEXITCODE
    } finally {
      $ErrorActionPreference = $oldErrorActionPreference
    }
    $rolloutText = ($rolloutOutput | Out-String)
    if ($rolloutExitCode -ne 2) {
      throw "Expected rollout status wrapper to exit 2 for blocked/pending gates, got $rolloutExitCode. Output:$([Environment]::NewLine)$rolloutText"
    }
    Assert-TextContains $rolloutText "Rollout status exported:"
    foreach ($relativePath in @("ROLLOUT_STATUS.md", "ROLLOUT_STATUS.json")) {
      $path = Join-Path $evidenceRoot $relativePath
      if (-not (Test-Path -LiteralPath $path)) {
        throw "Arrival packet rollout status did not write: $relativePath"
      }
    }
    $rolloutStatus = Get-Content -LiteralPath (Join-Path $evidenceRoot "ROLLOUT_STATUS.md") -Raw
    Assert-TextContains $rolloutStatus "blocked-or-pending"
    Assert-TextContains $rolloutStatus "production-voice-source"
    Assert-TextContains $rolloutStatus "strict-hardware-evidence"
    $global:LASTEXITCODE = 0
  } finally {
    $resolvedEvidence = (Resolve-Path $evidenceRoot).Path
    if (-not $resolvedEvidence.StartsWith($evidenceBase, [System.StringComparison]::OrdinalIgnoreCase)) {
      throw "Refusing to clean unexpected arrival packet path: $resolvedEvidence"
    }
    Remove-Item -LiteralPath $resolvedEvidence -Recurse -Force
    Restore-TemporaryPreflightReport
  }
}

if ([string]::IsNullOrWhiteSpace($ExpectedCommit)) {
  $ExpectedCommit = (git rev-parse HEAD).Trim()
}

if (-not [string]::IsNullOrWhiteSpace($PackageZip) -and [string]::IsNullOrWhiteSpace($Version)) {
  $zipName = [System.IO.Path]::GetFileName($PackageZip)
  if ($zipName -match "^stackchan_alive_(.+)\.zip$") {
    $Version = $Matches[1]
  } else {
    throw "Pass -Version when -PackageZip does not match stackchan_alive_<version>.zip"
  }
}

if ([string]::IsNullOrWhiteSpace($ReportDir)) {
  $reportVersion = if ([string]::IsNullOrWhiteSpace($Version)) { "commit-$($ExpectedCommit.Substring(0, [Math]::Min(12, $ExpectedCommit.Length)))" } else { $Version }
  $ReportDir = Join-Path $repoRoot "output/preflight/$reportVersion"
}

Invoke-Step "Check required commands" {
  Assert-Command git
  Get-StackchanPlatformioCommand | Out-Null
  Add-StackchanNativeCompilerToPath | Out-Null
}

Invoke-Step "Check source tree and dependency pins" {
  Assert-CleanSourceTree
  Assert-DependencyPins
}

Invoke-Step "Check flash helper safety gates" {
  Assert-FlashHelperSafety
}

Invoke-Step "Check runtime architecture boundaries" {
  & (Join-Path $PSScriptRoot "verify_architecture.ps1")
}

Invoke-Step "Check preview media quality" {
  & (Join-Path $PSScriptRoot "verify_preview_media.ps1")
}

Invoke-Step "Check hardware evidence media gate" {
  Assert-HardwareEvidenceMediaGate
}

Invoke-Step "Check hardware evidence serial marker gate" {
  Assert-HardwareEvidenceSerialMarkerGate
}

Invoke-Step "Run native logic tests" {
  Invoke-StackchanPlatformio test -e native_logic
}

Invoke-Step "Compile embedded test firmware" {
  Invoke-StackchanPlatformio test -e stackchan --without-uploading --without-testing
}

Invoke-Step "Build display-only and servo-calibration firmware" {
  Invoke-StackchanPlatformio run -e stackchan -e stackchan_servo_calibration
}

if (-not [string]::IsNullOrWhiteSpace($PackageZip)) {
  Invoke-Step "Verify release package" {
    $verifyScript = Join-Path $PSScriptRoot "verify_release_package.ps1"
    if ($AllowDirty) {
      & $verifyScript -Version $Version -ZipPath $PackageZip -ExpectedCommit $ExpectedCommit -AllowDirtyPackage
    } else {
      & $verifyScript -Version $Version -ZipPath $PackageZip -ExpectedCommit $ExpectedCommit
    }
  }

  Invoke-Step "Check arrival packet scaffold" {
    Assert-ArrivalPacketScaffoldGate $PackageZip -AllowDirtyPackage:$AllowDirty
  }

  Invoke-Step "Check release binary flash helper" {
    Assert-ReleaseFlashHelperSafety $PackageZip -AllowDirtyPackage:$AllowDirty
  }
}

Write-Host ""
Write-Host "Device preflight passed for commit $ExpectedCommit"
Write-PreflightReport -Status "pass"
Write-Host "Preflight report:"
Write-Host $ReportDir
