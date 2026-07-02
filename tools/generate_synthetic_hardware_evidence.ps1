param(
  [string]$Version = "",
  [string]$PackageZip = "",
  [string]$PackageRoot = "",
  [string]$ExpectedCommit = "",
  [string]$OutputRoot = "output/hardware-evidence-diagnostic",
  [switch]$AllowDirtyPackage,
  [switch]$Verify
)

$ErrorActionPreference = "Stop"

$repoRoot = Resolve-Path (Join-Path $PSScriptRoot "..")
Set-Location $repoRoot

function Quote-PowerShellArgument {
  param([string]$Value)
  return "'" + ($Value -replace "'", "''") + "'"
}

function Copy-AcceptanceArtifactsFromRoot {
  param(
    [string]$SourceRoot,
    [string]$DestinationRoot
  )

  foreach ($relativePath in @("RELEASE_ACCEPTANCE.md", "release_acceptance.json")) {
    $sourcePath = Join-Path $SourceRoot $relativePath
    if (-not (Test-Path -LiteralPath $sourcePath)) {
      throw "Release package missing acceptance artifact: $relativePath"
    }
    Copy-Item -LiteralPath $sourcePath -Destination (Join-Path $DestinationRoot $relativePath)
  }
}

function Copy-AcceptanceArtifactsFromZip {
  param(
    [string]$ZipPath,
    [string]$DestinationRoot
  )

  $tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) "stackchan-synthetic-acceptance"
  $extractDir = Join-Path $tempRoot ([System.Guid]::NewGuid().ToString("N"))
  New-Item -ItemType Directory -Force -Path $extractDir | Out-Null
  try {
    Expand-Archive -LiteralPath $ZipPath -DestinationPath $extractDir
    Copy-AcceptanceArtifactsFromRoot -SourceRoot $extractDir -DestinationRoot $DestinationRoot
  } finally {
    Remove-Item -LiteralPath $extractDir -Recurse -Force -ErrorAction SilentlyContinue
  }
}

function Copy-VoiceLeadArtifactsFromRoot {
  param(
    [string]$SourceRoot,
    [string]$DestinationRoot
  )

  $auditionJsonPath = Join-Path $SourceRoot "media/voice/rvc/RVC_AUDITIONS.json"
  $auditionMarkdownPath = Join-Path $SourceRoot "media/voice/rvc/RVC_AUDITIONS.md"
  if (-not (Test-Path -LiteralPath $auditionJsonPath)) {
    throw "Release package missing RVC audition manifest: media/voice/rvc/RVC_AUDITIONS.json"
  }
  if (-not (Test-Path -LiteralPath $auditionMarkdownPath)) {
    throw "Release package missing RVC audition notes: media/voice/rvc/RVC_AUDITIONS.md"
  }

  $auditions = Get-Content -LiteralPath $auditionJsonPath -Raw | ConvertFrom-Json
  if ($null -eq $auditions.leadAudition) {
    throw "RVC_AUDITIONS.json missing leadAudition metadata."
  }

  $lead = $auditions.leadAudition
  $leadFile = [string]$lead.file
  if ([string]::IsNullOrWhiteSpace($leadFile)) {
    throw "RVC lead audition file is blank."
  }

  $leadSourcePath = Join-Path $SourceRoot "media/voice/rvc/$leadFile"
  if (-not (Test-Path -LiteralPath $leadSourcePath)) {
    throw "Release package missing RVC lead audition WAV: media/voice/rvc/$leadFile"
  }

  $referenceDir = Join-Path $DestinationRoot "reference_audio"
  New-Item -ItemType Directory -Force -Path $referenceDir | Out-Null

  $leadDestinationPath = Join-Path $referenceDir $leadFile
  Copy-Item -LiteralPath $leadSourcePath -Destination $leadDestinationPath
  Copy-Item -LiteralPath $auditionJsonPath -Destination (Join-Path $referenceDir "RVC_AUDITIONS.json")
  Copy-Item -LiteralPath $auditionMarkdownPath -Destination (Join-Path $referenceDir "RVC_AUDITIONS.md")

  $leadHash = (Get-FileHash -Algorithm SHA256 -LiteralPath $leadDestinationPath).Hash.ToLowerInvariant()
  $leadTitle = [string]$lead.title
  $leadTranscript = [string]$lead.transcript
  $leadRating = [string]$lead.userRating
  $leadPurpose = [string]$lead.perceptualPurpose
  $leadPitch = [string]$lead.pitch
  $leadIndex = [string]$lead.index_rate
  $leadRms = [string]$lead.rms_mix_rate
  $leadProtect = [string]$lead.protect
  $leadRelativePath = "reference_audio/$leadFile"

  @(
    "# RVC Lead Audition Reference",
    "",
    "This file pins the exact review-only RVC voice sample to play during the target speaker check. It is not production voice-source approval.",
    "",
    "- Lead audition: $leadTitle",
    "- Reference WAV: $leadRelativePath",
    "- SHA256: $leadHash",
    "- Transcript: $leadTranscript",
    "- Tuning: pitch $leadPitch, index $leadIndex, RMS mix $leadRms, protect $leadProtect",
    "- Listening note: $leadRating",
    "- Perceptual purpose: $leadPurpose",
    "",
    "Use ``RUN_PLAY_LEAD_VOICE.cmd`` only as a playback aid. Consumer promotion still requires a real-device speaker recording imported under ``audio/``, completed ``AUDIO_REVIEW.md``, and completed production voice-source provenance."
  ) | Set-Content -Path (Join-Path $DestinationRoot "RVC_LEAD_AUDITION.md") -Encoding UTF8

  return [ordered]@{
    title = $leadTitle
    file = $leadFile
    referenceFile = $leadRelativePath
    sha256 = $leadHash
    transcript = $leadTranscript
    pitch = $leadPitch
    index_rate = $leadIndex
    rms_mix_rate = $leadRms
    protect = $leadProtect
    userRating = $leadRating
    perceptualPurpose = $leadPurpose
  }
}

function Copy-VoiceLeadArtifactsFromZip {
  param(
    [string]$ZipPath,
    [string]$DestinationRoot
  )

  $tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) "stackchan-synthetic-voice-lead"
  $extractDir = Join-Path $tempRoot ([System.Guid]::NewGuid().ToString("N"))
  New-Item -ItemType Directory -Force -Path $extractDir | Out-Null
  try {
    Expand-Archive -LiteralPath $ZipPath -DestinationPath $extractDir
    return Copy-VoiceLeadArtifactsFromRoot -SourceRoot $extractDir -DestinationRoot $DestinationRoot
  } finally {
    Remove-Item -LiteralPath $extractDir -Recurse -Force -ErrorAction SilentlyContinue
  }
}

function Copy-VoiceGateStatusFromRoot {
  param(
    [string]$SourceRoot,
    [string]$DestinationRoot
  )

  $statusFiles = @(
    "VOICE_SOURCE_STATUS.md",
    "voice_source_status.json",
    "RVC_VOICE_BASE_STATUS.md",
    "rvc_voice_base_status.json"
  )

  foreach ($relativePath in $statusFiles) {
    $sourcePath = Join-Path $SourceRoot $relativePath
    if (-not (Test-Path -LiteralPath $sourcePath)) {
      throw "Release package missing voice gate status artifact: $relativePath"
    }
    Copy-Item -LiteralPath $sourcePath -Destination (Join-Path $DestinationRoot $relativePath)
  }

  $voiceSourceStatus = Get-Content -LiteralPath (Join-Path $DestinationRoot "voice_source_status.json") -Raw | ConvertFrom-Json
  $rvcBaseStatus = Get-Content -LiteralPath (Join-Path $DestinationRoot "rvc_voice_base_status.json") -Raw | ConvertFrom-Json

  return [ordered]@{
    voiceSourceStatus = [string]$voiceSourceStatus.status
    voiceSourceBlockedGateCount = [int]$voiceSourceStatus.blockedGateCount
    rvcVoiceBaseStatus = [string]$rvcBaseStatus.status
    rvcConsumerApproved = [bool]$rvcBaseStatus.consumerApproved
    rvcDistributionApproved = [bool]$rvcBaseStatus.distributionApproved
    reports = @(
      "VOICE_SOURCE_STATUS.md",
      "voice_source_status.json",
      "RVC_VOICE_BASE_STATUS.md",
      "rvc_voice_base_status.json"
    )
  }
}

function Copy-VoiceGateStatusFromZip {
  param(
    [string]$ZipPath,
    [string]$DestinationRoot
  )

  $tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) "stackchan-synthetic-voice-gates"
  $extractDir = Join-Path $tempRoot ([System.Guid]::NewGuid().ToString("N"))
  New-Item -ItemType Directory -Force -Path $extractDir | Out-Null
  try {
    Expand-Archive -LiteralPath $ZipPath -DestinationPath $extractDir
    return Copy-VoiceGateStatusFromRoot -SourceRoot $extractDir -DestinationRoot $DestinationRoot
  } finally {
    Remove-Item -LiteralPath $extractDir -Recurse -Force -ErrorAction SilentlyContinue
  }
}

function Get-ReleaseManifest {
  param([string]$RootPath)

  $manifestPath = Join-Path $RootPath "release_manifest.json"
  if (-not (Test-Path -LiteralPath $manifestPath)) {
    return $null
  }

  return Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json
}

if ([string]::IsNullOrWhiteSpace($ExpectedCommit)) {
  $ExpectedCommit = (git rev-parse HEAD).Trim()
}

if ([string]::IsNullOrWhiteSpace($Version)) {
  if (-not [string]::IsNullOrWhiteSpace($PackageRoot)) {
    $manifest = Get-ReleaseManifest $PackageRoot
    if ($null -ne $manifest) {
      $Version = [string]$manifest.version
    }
  }
  if ([string]::IsNullOrWhiteSpace($Version) -and -not [string]::IsNullOrWhiteSpace($PackageZip)) {
    $zipName = [System.IO.Path]::GetFileName($PackageZip)
    if ($zipName -match "^stackchan_alive_(.+)\.zip$") {
      $Version = $Matches[1]
    }
  }
  if ([string]::IsNullOrWhiteSpace($Version)) {
    $Version = (git describe --tags --always).Trim()
  }
}

if ([string]::IsNullOrWhiteSpace($PackageZip) -and [string]::IsNullOrWhiteSpace($PackageRoot)) {
  $candidateZip = Join-Path $repoRoot "output/release/stackchan_alive_$Version.zip"
  if (Test-Path -LiteralPath $candidateZip) {
    $PackageZip = $candidateZip
  } else {
    $candidateRoot = Join-Path $repoRoot "output/release/$Version"
    if (Test-Path -LiteralPath $candidateRoot) {
      $PackageRoot = $candidateRoot
    }
  }
}

$safeTag = $Version -replace '[^A-Za-z0-9_.-]', '_'
$stamp = (Get-Date).ToUniversalTime().ToString("yyyyMMddTHHmmssZ")
$outDir = Join-Path $repoRoot "$OutputRoot/$safeTag-synthetic-$stamp"
$logsDir = Join-Path $outDir "logs"
$photosDir = Join-Path $outDir "photos"
$audioDir = Join-Path $outDir "audio"
$calibrationDir = Join-Path $outDir "calibration"
$packageDir = Join-Path $outDir "package"
New-Item -ItemType Directory -Force -Path $logsDir, $photosDir, $audioDir, $calibrationDir, $packageDir | Out-Null

$packageInfo = $null
$voiceLeadInfo = $null
$voiceGateInfo = $null
$requiredLogs = @(
  "logs/display_only_serial.log",
  "logs/servo_calibration_serial.log",
  "logs/soak_serial.log"
)

if (-not [string]::IsNullOrWhiteSpace($PackageZip)) {
  if (-not (Test-Path -LiteralPath $PackageZip)) {
    throw "Missing package ZIP: $PackageZip"
  }
  $packageItem = Get-Item -LiteralPath $PackageZip
  $packageHash = Get-FileHash -Algorithm SHA256 -LiteralPath $packageItem.FullName
  Copy-Item -LiteralPath $packageItem.FullName -Destination $packageDir
  $packageInfo = [ordered]@{
    sourcePath = $packageItem.FullName
    copiedFile = "package/$($packageItem.Name)"
    sha256 = $packageHash.Hash.ToLowerInvariant()
    sizeBytes = $packageItem.Length
  }

  $packageVerifyLog = Join-Path $logsDir "package_verify.log"
  $verifyArgs = @(
    "-NoProfile",
    "-ExecutionPolicy",
    "Bypass",
    "-File",
    (Join-Path $PSScriptRoot "verify_release_package.ps1"),
    "-Version",
    $Version,
    "-ZipPath",
    $packageItem.FullName,
    "-ExpectedCommit",
    $ExpectedCommit
  )
  if ($AllowDirtyPackage) {
    $verifyArgs += "-AllowDirtyPackage"
  }
  $verifyOutput = & powershell.exe @verifyArgs 2>&1
  $verifyExitCode = $LASTEXITCODE
  $verifyOutput | Set-Content -Path $packageVerifyLog -Encoding UTF8
  if ($verifyExitCode -ne 0) {
    throw "Release package verification failed while generating synthetic evidence. See $packageVerifyLog"
  }
  Copy-AcceptanceArtifactsFromZip -ZipPath $packageItem.FullName -DestinationRoot $outDir
  $voiceLeadInfo = Copy-VoiceLeadArtifactsFromZip -ZipPath $packageItem.FullName -DestinationRoot $outDir
  $voiceGateInfo = Copy-VoiceGateStatusFromZip -ZipPath $packageItem.FullName -DestinationRoot $outDir
  $requiredLogs = @("logs/package_verify.log") + $requiredLogs
} elseif (-not [string]::IsNullOrWhiteSpace($PackageRoot)) {
  if (-not (Test-Path -LiteralPath $PackageRoot)) {
    throw "Missing package root: $PackageRoot"
  }
  $packageRootItem = Get-Item -LiteralPath $PackageRoot
  $packageInfo = [ordered]@{
    sourcePath = $packageRootItem.FullName
    packageRoot = $true
  }

  $packageVerifyLog = Join-Path $logsDir "package_verify.log"
  $verifyArgs = @(
    "-NoProfile",
    "-ExecutionPolicy",
    "Bypass",
    "-File",
    (Join-Path $PSScriptRoot "verify_release_package.ps1"),
    "-Version",
    $Version,
    "-PackageRoot",
    $packageRootItem.FullName,
    "-ExpectedCommit",
    $ExpectedCommit
  )
  if ($AllowDirtyPackage) {
    $verifyArgs += "-AllowDirtyPackage"
  }
  $verifyOutput = & powershell.exe @verifyArgs 2>&1
  $verifyExitCode = $LASTEXITCODE
  $verifyOutput | Set-Content -Path $packageVerifyLog -Encoding UTF8
  if ($verifyExitCode -ne 0) {
    throw "Release package verification failed while generating synthetic evidence. See $packageVerifyLog"
  }
  Copy-AcceptanceArtifactsFromRoot -SourceRoot $packageRootItem.FullName -DestinationRoot $outDir
  $voiceLeadInfo = Copy-VoiceLeadArtifactsFromRoot -SourceRoot $packageRootItem.FullName -DestinationRoot $outDir
  $voiceGateInfo = Copy-VoiceGateStatusFromRoot -SourceRoot $packageRootItem.FullName -DestinationRoot $outDir
  $requiredLogs = @("logs/package_verify.log") + $requiredLogs
} else {
  throw "Pass -PackageZip or -PackageRoot, or build a release package for $Version first."
}

$checklist = Get-Content -LiteralPath "docs/ROLLOUT_CHECKLIST.md" -Raw
$checklist = $checklist -replace "(?m)^- \[ \]", "- [x]"
@(
  "<!-- SYNTHETIC DIAGNOSTIC PACKET: not real hardware evidence. -->",
  $checklist
) | Set-Content -Path (Join-Path $outDir "CHECKLIST.md") -Encoding UTF8

Copy-Item -LiteralPath "docs/DEVICE_BRINGUP.md" -Destination (Join-Path $outDir "DEVICE_BRINGUP.md")
Copy-Item -LiteralPath "docs/PRODUCTION_READINESS.md" -Destination (Join-Path $outDir "PRODUCTION_READINESS.md")

@(
  "# Stackchan Synthetic Hardware Evidence Packet",
  "",
  "This packet is diagnostic-only synthetic evidence generated by `tools/generate_synthetic_hardware_evidence.ps1`.",
  "It exists to test verifier coverage without hardware. It must not be used as rollout evidence.",
  "",
  "The normal hardware evidence verifier rejects this packet unless `-AllowSyntheticEvidence` is passed.",
  "",
  "BENCH_STATUS.md is generated for workflow-shape testing only. It does not make this packet real hardware evidence.",
  "",
  "Release: $Version",
  "Commit: $ExpectedCommit"
) | Set-Content -Path (Join-Path $outDir "README.md") -Encoding UTF8

@(
  "# Stackchan Evidence Next Steps",
  "",
  "Release: $Version",
  "Commit: $ExpectedCommit",
  "Device: SYNTHETIC-NOT-HARDWARE",
  "Port: COM_SYNTHETIC",
  "Operator: synthetic-verifier",
  "",
  "This is a synthetic diagnostic packet. It tests verifier coverage only and must not be used as rollout evidence.",
  "",
  "Open ``BENCH_STATUS.md`` for the latest synthetic next-action summary. ``RUN_PROGRESS_CHECK.cmd`` refreshes ``BENCH_STATUS.md`` and ``BENCH_STATUS.json``.",
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
  "9. Run ``RUN_PROGRESS_CHECK.cmd`` to refresh ``BENCH_STATUS.md/json`` and fix every missing field, marker, media file, and unchecked checklist item it reports.",
  "10. Run ``RUN_ROLLOUT_STATUS.cmd`` to write ``ROLLOUT_STATUS.md`` and ``ROLLOUT_STATUS.json`` for handoff review.",
  "11. Run ``RUN_EVIDENCE_VERIFY.cmd`` for the strict hardware evidence gate.",
  "12. Run ``RUN_CONSUMER_PROMOTION_CHECK.cmd`` only after strict evidence verification passes.",
  "",
  "## Gates Still Expected",
  "",
  "- Hardware validation remains pending until this packet has real display, servo, soak, calibration, photo/video, and speaker evidence.",
  "- Production voice-source provenance remains pending until the owned or licensed source record is completed.",
  "- RVC voice-base evidence remains review-only until consumer and distribution approvals are explicitly recorded.",
  "- GitHub Actions may still be externally blocked; use ``RUN_ROLLOUT_STATUS.cmd`` for the current CI/account state.",
  "- Hosted media or synthetic diagnostic packets are review aids only. They do not replace real-device evidence.",
  "",
  "## Hard Stops",
  "",
  "- Do not run servo calibration unless the body is clear and supervised.",
  "- Do not mark the audio gate complete without a recording captured from the actual target speaker path.",
  "- Do not use ``-AllowExternalAccountCiBlock`` from this synthetic packet. ``CI_ACCOUNT_BLOCK_EXCEPTION_TEMPLATE.json`` must be completed only in a real evidence packet after each proof gate passes.",
  "- Do not promote if ``CHECKLIST.md`` still has unchecked gates or ``RUN_PROGRESS_CHECK.cmd`` reports missing evidence.",
  "- Do not treat generated samples, local previews, or hosted review pages as consumer rollout evidence."
) | Set-Content -Path (Join-Path $outDir "NEXT_STEPS.md") -Encoding UTF8

$initialBenchStatus = [ordered]@{
  schema = "stackchan.bench-status.v1"
  evidenceRoot = $outDir
  generatedUtc = (Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")
  status = "synthetic-diagnostic-not-for-rollout"
  nextAction = "Run the progress check to exercise the same bench-status refresh path used by real packets."
  nextCommand = "RUN_PROGRESS_CHECK.cmd"
  reason = "Synthetic diagnostic scaffold; not real hardware evidence."
  findingCount = $null
  passCount = $null
  findings = @("Synthetic diagnostic packet cannot be used as rollout evidence.")
  passes = @()
}
$initialBenchStatus | ConvertTo-Json -Depth 5 | Set-Content -Path (Join-Path $outDir "BENCH_STATUS.json") -Encoding UTF8
@(
  "# Stackchan Bench Status",
  "",
  "- Schema: stackchan.bench-status.v1",
  "- Generated UTC: $($initialBenchStatus.generatedUtc)",
  "- Status: synthetic-diagnostic-not-for-rollout",
  "- Next action: Run the progress check to exercise the same bench-status refresh path used by real packets.",
  "- Next command: ``RUN_PROGRESS_CHECK.cmd``",
  "- Reason: Synthetic diagnostic scaffold; not real hardware evidence.",
  "",
  "Run ``RUN_PROGRESS_CHECK.cmd`` to refresh this file. Do not use this packet as rollout evidence."
) | Set-Content -Path (Join-Path $outDir "BENCH_STATUS.md") -Encoding UTF8

@(
  "# Hardware Test Observations",
  "",
  "Synthetic diagnostic packet: yes",
  "",
  "## Display-Only Flash",
  "- Start UTC: 2026-07-01T00:00:00Z",
  "- End UTC: 2026-07-01T00:10:00Z",
  "- Command: synthetic display-only verifier fixture",
  "- Result: pass",
  "- Reset loop observed: no",
  "- Procedural face visible: yes",
  "- Dry-run servo log observed: yes",
  "- Notes: synthetic diagnostic data only; not hardware evidence",
  "",
  "## Servo Calibration Flash",
  "- Start UTC: 2026-07-01T00:10:00Z",
  "- End UTC: 2026-07-01T00:20:00Z",
  "- Command: synthetic servo verifier fixture",
  "- Result: pass",
  "- Pitch behavior: inside safe range",
  "- Yaw classification: disabled",
  "- Heat or brownout observed: no",
  "- Calibration changes: synthetic safe calibration values recorded",
  "- Notes: synthetic diagnostic data only; not hardware evidence",
  "",
  "## Soak Test",
  "- Start UTC: 2026-07-01T00:20:00Z",
  "- End UTC: 2026-07-01T00:55:00Z",
  "- Duration: 35 minutes",
  "- Reset, stall, jitter, or heat observed: no",
  "- USB power-cycle recovery: pass",
  "- Notes: synthetic diagnostic data only; not hardware evidence",
  "",
  "## Attachments",
  "",
  "- Display serial log: logs/display_only_serial.log",
  "- Servo serial log: logs/servo_calibration_serial.log",
  "- Soak serial log: logs/soak_serial.log",
  "- Package verification log: logs/package_verify.log",
  "- Photos/videos: photos/",
  "- Calibration record: calibration/calibration.yaml"
) | Set-Content -Path (Join-Path $outDir "OBSERVATIONS.md") -Encoding UTF8

@(
  "# Stackchan Audio Review",
  "",
  "Synthetic diagnostic packet: yes",
  "",
  "## Speaker Playback",
  "- Start UTC: 2026-07-01T00:55:00Z",
  "- End UTC: 2026-07-01T00:56:00Z",
  "- Sample played: synthetic fixture greeting",
  "- Voice variant: stackchan_spark_greeting",
  "- Speaker recording file: audio/synthetic_speaker_fixture.wav",
  "- Intelligible through device speaker: yes",
  "- Clipping or distortion observed: no",
  "- Volume adequate at normal listening distance: yes",
  "- Delay or playback dropout observed: no",
  "- Selected voice direction: synthetic verifier fixture only",
  "- Notes: synthetic diagnostic data only; not real speaker evidence"
) | Set-Content -Path (Join-Path $outDir "AUDIO_REVIEW.md") -Encoding UTF8

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
  "[control] command=button_a_listen mode=listen event=wake_word strength=1.00 at_ms=2980",
  "[control] command=reduced_motion_on reduced_motion=1 at_ms=3060",
  "[face] reduced_motion=1",
  "[speech] seq=1 at_ms=3020 intent=listen priority=160 earcon=confirm earcon_delay_ms=0 text=`"I am listening with maximum attention.`"",
  "[servo] dry-run mode; set STACKCHAN_ENABLE_SERVOS=1 after calibration",
  "[heartbeat] stackchan_alive mode=display_only uptime_ms=10000",
  "[system] heap_free=243000 heap_min=239000 stack_loop_hwm=7200 stack_motion_hwm=3100 stack_face_hwm=2800 stack_intent_hwm=3300",
  "[heartbeat] stackchan_alive mode=display_only uptime_ms=600000",
  "synthetic diagnostic log: not real hardware evidence"
) | Set-Content -Path (Join-Path $logsDir "display_only_serial.log") -Encoding UTF8

@(
  "[boot] stackchan_alive mode=servo_calibration serial=v1",
  "[display] M5 display renderer ready",
  "[servo] enabling StackchanSERVO hardware output",
  "[heartbeat] stackchan_alive mode=servo_calibration uptime_ms=10000",
  "[heartbeat] stackchan_alive mode=servo_calibration uptime_ms=600000",
  "synthetic diagnostic log: not real hardware evidence"
) | Set-Content -Path (Join-Path $logsDir "servo_calibration_serial.log") -Encoding UTF8

@(
  "[heartbeat] stackchan_alive mode=servo_calibration uptime_ms=1200000",
  "[display] frame_ms_avg=12.80 frame_ms_max=16.10 fps_avg=78.1 fps_window=30.0 frame_budget_us=33333 slow_frames=0",
  "[face] mode=1 blink_count=12 saccade_count=16 blink_open=1.00 breath_y=-0.18 gaze_x=-0.04 gaze_y=0.02 gesture_active=0 speech_active=0 speech_env=0.00",
  "[speech] seq=4 at_ms=1200200 intent=think priority=150 earcon=think earcon_delay_ms=80 text=`"Input received. I am thinking now.`"",
  "[system] heap_free=242500 heap_min=238800 stack_loop_hwm=7200 stack_motion_hwm=3090 stack_face_hwm=2760 stack_intent_hwm=3280",
  "[heartbeat] stackchan_alive mode=servo_calibration uptime_ms=1800000",
  "[heartbeat] stackchan_alive mode=servo_calibration uptime_ms=2100000",
  "synthetic diagnostic soak log: not real hardware evidence"
) | Set-Content -Path (Join-Path $logsDir "soak_serial.log") -Encoding UTF8

$mediaSource = "docs/media/stackchan_alive_preview.png"
if (-not (Test-Path -LiteralPath $mediaSource)) {
  throw "Missing preview image for synthetic media evidence: $mediaSource"
}
Copy-Item -LiteralPath $mediaSource -Destination (Join-Path $photosDir "synthetic_display_evidence.png")

$audioSource = "docs/media/voice/stackchan_spark_greeting.wav"
if (-not (Test-Path -LiteralPath $audioSource)) {
  throw "Missing voice sample for synthetic audio evidence: $audioSource"
}
Copy-Item -LiteralPath $audioSource -Destination (Join-Path $audioDir "synthetic_speaker_fixture.wav")

$verifyPackageCommand = "powershell.exe -NoProfile -ExecutionPolicy Bypass -File `"%~dp0..\..\..\tools\verify_release_package.ps1`" -Version $Version -ExpectedCommit $ExpectedCommit"
$rolloutPackageArg = ""
if ($packageInfo -and $packageInfo.Contains("copiedFile")) {
  $packageFileName = [System.IO.Path]::GetFileName([string]$packageInfo["sourcePath"])
  $packetZip = "%~dp0package\$packageFileName"
  $verifyPackageCommand += " -ZipPath `"$packetZip`""
  $rolloutPackageArg = "-PackageZip `"$packetZip`""
} elseif ($packageInfo -and $packageInfo.Contains("packageRoot")) {
  $sourceRoot = [string]$packageInfo["sourcePath"]
  $verifyPackageCommand += " -PackageRoot `"$sourceRoot`""
  $rolloutPackageArg = "-PackageRoot `"$sourceRoot`""
}
if ($AllowDirtyPackage) {
  $verifyPackageCommand += " -AllowDirtyPackage"
}
$rolloutStatusCommand = "powershell.exe -NoProfile -ExecutionPolicy Bypass -File `"%~dp0..\..\..\tools\export_rollout_status.ps1`" -Version $Version $rolloutPackageArg -EvidenceRoot `"%~dp0.`" -ExpectedCommit $ExpectedCommit -OutDir `"%~dp0.`""

$commandFiles = @{
  "RUN_PLAY_LEAD_VOICE.cmd" = "echo Synthetic diagnostic packet. Use a real hardware packet for target speaker playback."
  "RUN_DISPLAY_ONLY.cmd" = "echo Synthetic diagnostic packet. Do not flash hardware from this fixture."
  "RUN_SERVO_CALIBRATION.cmd" = "echo Synthetic diagnostic packet. Do not move servos from this fixture."
  "RUN_SOAK_MONITOR.cmd" = "echo Synthetic diagnostic packet. Do not use as a real soak log."
  "RUN_PACKAGE_VERIFY.cmd" = $verifyPackageCommand
  "RUN_PROGRESS_CHECK.cmd" = "powershell.exe -NoProfile -ExecutionPolicy Bypass -File `"%~dp0..\..\..\tools\check_hardware_evidence_progress.ps1`" -EvidenceRoot `"%~dp0.`""
  "RUN_ROLLOUT_STATUS.cmd" = $rolloutStatusCommand
  "RUN_ADD_MEDIA.cmd" = "echo Synthetic diagnostic packet already includes fixture media. Add real media only to a real hardware packet."
  "RUN_EVIDENCE_VERIFY.cmd" = "powershell.exe -NoProfile -ExecutionPolicy Bypass -File `"%~dp0..\..\..\tools\verify_hardware_evidence.ps1`" -EvidenceRoot `"%~dp0.`" -AllowSyntheticEvidence"
  "RUN_CONSUMER_PROMOTION_CHECK.cmd" = "echo Synthetic diagnostic packet. Consumer promotion must use real hardware evidence."
}
foreach ($entry in $commandFiles.GetEnumerator()) {
  @(
    "@echo off",
    $entry.Value
  ) | Set-Content -Path (Join-Path $outDir $entry.Key) -Encoding ASCII
}

$metadata = [ordered]@{
  releaseTag = $Version
  commit = $ExpectedCommit
  branch = "synthetic-diagnostic"
  createdUtc = (Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")
  operator = "synthetic-verifier"
  deviceId = "SYNTHETIC-NOT-HARDWARE"
  port = "COM_SYNTHETIC"
  diagnosticOnly = $true
  syntheticEvidence = $true
  package = $packageInfo
  voiceLeadAudition = $voiceLeadInfo
  voiceGateStatus = $voiceGateInfo
  requiredLogs = $requiredLogs
  requiredRecords = @(
    "BENCH_STATUS.md",
    "BENCH_STATUS.json",
    "NEXT_STEPS.md",
    "CHECKLIST.md",
    "RELEASE_ACCEPTANCE.md",
    "release_acceptance.json",
    "OBSERVATIONS.md",
    "AUDIO_REVIEW.md",
    "VOICE_SOURCE_STATUS.md",
    "voice_source_status.json",
    "RVC_VOICE_BASE_STATUS.md",
    "rvc_voice_base_status.json",
    "RVC_LEAD_AUDITION.md",
    "reference_audio/RVC_AUDITIONS.md",
    "reference_audio/RVC_AUDITIONS.json",
    [string]$voiceLeadInfo.referenceFile,
    "calibration/calibration.yaml",
    "RUN_PLAY_LEAD_VOICE.cmd",
    "RUN_DISPLAY_ONLY.cmd",
    "RUN_SERVO_CALIBRATION.cmd",
    "RUN_SOAK_MONITOR.cmd",
    "RUN_PACKAGE_VERIFY.cmd",
    "RUN_PROGRESS_CHECK.cmd",
    "RUN_ROLLOUT_STATUS.cmd",
    "RUN_ADD_MEDIA.cmd",
    "RUN_EVIDENCE_VERIFY.cmd",
    "RUN_CONSUMER_PROMOTION_CHECK.cmd"
  )
  benchStatus = [ordered]@{
    summary = "BENCH_STATUS.md"
    report = "BENCH_STATUS.json"
    refreshCommand = "RUN_PROGRESS_CHECK.cmd"
  }
  promotionVerifier = "tools/verify_consumer_promotion.ps1"
  hardwareEvidenceVerifier = "tools/verify_hardware_evidence.ps1"
}
$metadata | ConvertTo-Json -Depth 6 | Set-Content -Path (Join-Path $outDir "metadata.json") -Encoding UTF8

$progressLog = Join-Path $logsDir "progress_check.log"
$progressOutput = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $PSScriptRoot "check_hardware_evidence_progress.ps1") -EvidenceRoot $outDir 2>&1
$progressExitCode = $LASTEXITCODE
$progressOutput | Set-Content -Path $progressLog -Encoding UTF8
if ($progressExitCode -notin @(0, 2)) {
  throw "Synthetic hardware evidence progress check failed unexpectedly with exit code $progressExitCode. See $progressLog"
}

Write-Host "Synthetic hardware evidence packet:"
Write-Host $outDir

if ($Verify) {
  & powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $PSScriptRoot "verify_hardware_evidence.ps1") -EvidenceRoot $outDir -AllowSyntheticEvidence
  if ($LASTEXITCODE -ne 0) {
    throw "Synthetic hardware evidence packet failed verifier."
  }
}
