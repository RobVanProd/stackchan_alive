param(
  [string]$Version,
  [string]$PackageRoot,
  [string]$ZipPath,
  [string]$ExpectedCommit,
  [switch]$AllowDirtyPackage
)

$ErrorActionPreference = "Stop"

$repoRoot = Resolve-Path (Join-Path $PSScriptRoot "..")
Set-Location $repoRoot

if ([string]::IsNullOrWhiteSpace($Version)) {
  $Version = (git describe --tags --always --dirty).Trim()
}

if ([string]::IsNullOrWhiteSpace($ExpectedCommit)) {
  $ExpectedCommit = (git rev-parse HEAD).Trim()
}

$cleanupDir = $null

if (-not [string]::IsNullOrWhiteSpace($ZipPath)) {
  if (-not (Test-Path -LiteralPath $ZipPath)) {
    throw "Missing release ZIP: $ZipPath"
  }

  $tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) "stackchan-release-verify"
  $cleanupDir = Join-Path $tempRoot ([System.Guid]::NewGuid().ToString("N"))
  New-Item -ItemType Directory -Force -Path $cleanupDir | Out-Null
  Expand-Archive -LiteralPath $ZipPath -DestinationPath $cleanupDir
  $PackageRoot = $cleanupDir
}

if ([string]::IsNullOrWhiteSpace($PackageRoot)) {
  $PackageRoot = Join-Path $repoRoot "output/release/$Version"
}

if (-not (Test-Path -LiteralPath $PackageRoot)) {
  throw "Missing package directory: $PackageRoot"
}

$packageRootPath = (Resolve-Path $PackageRoot).Path

function Join-PackagePath {
  param([string]$RelativePath)
  return Join-Path $packageRootPath ($RelativePath -replace "/", "\")
}

function Assert-File {
  param(
    [string]$RelativePath,
    [int64]$MinBytes = 1
  )

  $path = Join-PackagePath $RelativePath
  if (-not (Test-Path -LiteralPath $path)) {
    throw "Missing required package file: $RelativePath"
  }

  $item = Get-Item -LiteralPath $path
  if ($item.Length -lt $MinBytes) {
    throw "Package file is too small: $RelativePath ($($item.Length) bytes)"
  }
}

function Assert-Bytes {
  param(
    [string]$RelativePath,
    [byte[]]$Expected,
    [int]$Offset = 0
  )

  $path = Join-PackagePath $RelativePath
  $bytes = [System.IO.File]::ReadAllBytes($path)
  if ($bytes.Length -lt ($Offset + $Expected.Length)) {
    throw "Package file is too small for signature check: $RelativePath"
  }

  for ($i = 0; $i -lt $Expected.Length; $i++) {
    if ($bytes[$Offset + $i] -ne $Expected[$i]) {
      throw "Invalid file signature: $RelativePath"
    }
  }
}

$requiredFiles = @(
  "DEPENDENCIES.md",
  "ARRIVAL_DAY_RUNBOOK.md",
  "GITHUB_ACTIONS_STATUS.md",
  "READINESS_REPORT.md",
  "github_actions_status.json",
  "dependency_lock.json",
  "QUICKSTART.md",
  "RELEASE_ACCEPTANCE.md",
  "RELEASE_NOTES.md",
  "SHA256SUMS.txt",
  "VOICE_SOURCE_STATUS.md",
  "release_acceptance.json",
  "readiness_report.json",
  "release_manifest.json",
  "voice_source_status.json",
  "docs/DEVICE_BRINGUP.md",
  "docs/PRODUCTION_READINESS.md",
  "docs/README.md",
  "docs/RELEASE_PROCESS.md",
  "docs/ROLLOUT_CHECKLIST.md",
  "docs/VOICE_PERSONALITY.md",
  "docs/VOICE_SOURCE_PROVENANCE_TEMPLATE.md",
  "data/calibration.yaml",
  "data/voice_persona.yaml",
  "data/voice_source_provenance.yaml",
  "data/voice_rvc_base.yaml",
  "data/voice_rvc_base_metadata.json",
  "firmware/display_only/bootloader.bin",
  "firmware/display_only/firmware.bin",
  "firmware/display_only/firmware.elf",
  "firmware/display_only/partitions.bin",
  "firmware/servo_calibration/bootloader.bin",
  "firmware/servo_calibration/firmware.bin",
  "firmware/servo_calibration/firmware.elf",
  "firmware/servo_calibration/partitions.bin",
  "media/stackchan_alive_expression_sheet.png",
  "media/stackchan_alive_preview.gif",
  "media/stackchan_alive_preview.mp4",
  "media/stackchan_alive_preview.png",
  "media/stackchan_alive_speech_preview.gif",
  "artifacts/face/phase_a_idle_10s.gif",
  "artifacts/face/phase_a_blink_filmstrip_50ms.png",
  "artifacts/face/phase_a_unlabeled_expression_sheet.png",
  "artifacts/face/phase_b_unlabeled_expression_sheet.png",
  "artifacts/face/phase_c_idle_10s.gif",
  "artifacts/face/phase_d_idle_to_listen_filmstrip_50ms.png",
  "artifacts/face/phase_d_think_to_speak_filmstrip_50ms.png",
  "artifacts/face/phase_d_idle_to_sleep_filmstrip_50ms.png",
  "artifacts/face/phase_e_speech_reactive_6s.gif",
  "media/voice/stackchan_spark_greeting.wav",
  "media/voice/stackchan_spark_thinking.wav",
  "media/voice/stackchan_spark_safety.wav",
  "media/voice/stackchan_spark_audition_warm_slow_greeting.wav",
  "media/voice/stackchan_spark_audition_bright_robot_greeting.wav",
  "media/voice/VOICE_SAMPLES.md",
  "media/voice/rvc/RVC_AUDITIONS.md",
  "media/voice/rvc/RVC_AUDITIONS.json",
  "media/voice/rvc/stackchan_rvc_neutral.wav",
  "media/voice/rvc/stackchan_rvc_warm_slow.wav",
  "media/voice/rvc/stackchan_rvc_bright_robot.wav",
  "media/voice/rvc/stackchan_rvc_bright_robot_less_static.wav",
  "media/voice/rvc/stackchan_rvc_bright_robot_sweet_vocoder.wav",
  "media/voice/rvc/stackchan_rvc_bright_robot_soft_boops.wav",
  "media/voice/rvc/stackchan_rvc_spark_boops.wav",
  "media/voice/rvc/stackchan_rvc_high_character.wav",
  "media/voice/rvc/stackchan_rvc_thinking_neutral.wav",
  "media/voice/rvc/stackchan_rvc_safety_neutral.wav",
  "tools/flash_device.cmd",
  "tools/flash_device.ps1",
  "tools/flash_release_firmware.cmd",
  "tools/flash_release_firmware.ps1",
  "tools/platformio_resolver.ps1",
  "tools/preview_python_resolver.ps1",
  "tools/render_preview.py",
  "tools/publish_release.cmd",
  "tools/publish_release.ps1",
  "tools/export_github_actions_status.cmd",
  "tools/export_github_actions_status.ps1",
  "tools/export_voice_source_status.cmd",
  "tools/export_voice_source_status.ps1",
  "tools/setup_voice_tools.cmd",
  "tools/setup_voice_tools.ps1",
  "tools/render_voice_samples.cmd",
  "tools/render_voice_samples.ps1",
  "tools/render_rvc_auditions.ps1",
  "tools/verify_voice_samples.cmd",
  "tools/verify_voice_samples.ps1",
  "tools/verify_rvc_auditions.cmd",
  "tools/verify_rvc_auditions.ps1",
  "tools/generate_synthetic_hardware_evidence.cmd",
  "tools/generate_synthetic_hardware_evidence.ps1",
  "tools/add_hardware_evidence_media.cmd",
  "tools/add_hardware_evidence_media.ps1",
  "tools/check_hardware_evidence_progress.cmd",
  "tools/check_hardware_evidence_progress.ps1",
  "tools/prepare_device_arrival.cmd",
  "tools/prepare_device_arrival.ps1",
  "tools/run_device_preflight.cmd",
  "tools/run_device_preflight.ps1",
  "tools/share_release.cmd",
  "tools/share_release.ps1",
  "tools/start_hardware_evidence.cmd",
  "tools/start_hardware_evidence.ps1",
  "tools/stop_share.cmd",
  "tools/stop_share.ps1",
  "tools/verify_hardware_evidence.cmd",
  "tools/verify_hardware_evidence.ps1",
  "tools/verify_consumer_promotion.cmd",
  "tools/verify_consumer_promotion.ps1",
  "tools/verify_published_release.cmd",
  "tools/verify_published_release.ps1",
  "tools/verify_architecture.cmd",
  "tools/verify_architecture.ps1",
  "tools/verify_preview_media.cmd",
  "tools/verify_preview_media.ps1",
  "tools/verify_face_phase_a.cmd",
  "tools/verify_face_phase_a.ps1",
  "tools/verify_face_phase_b.cmd",
  "tools/verify_face_phase_b.ps1",
  "tools/verify_face_phase_c.cmd",
  "tools/verify_face_phase_c.ps1",
  "tools/verify_face_phase_d.cmd",
  "tools/verify_face_phase_d.ps1",
  "tools/verify_face_phase_e.cmd",
  "tools/verify_face_phase_e.ps1",
  "tools/verify_rvc_voice_base.cmd",
  "tools/verify_rvc_voice_base.ps1",
  "tools/verify_release_package.cmd",
  "tools/verify_release_package.ps1",
  "tools/verify_share_release.cmd",
  "tools/verify_share_release.ps1",
  "provenance/firmware.yml",
  "provenance/platformio.ini",
  "provenance/src/main.cpp",
  "provenance/src/persona/SpeechPlanner.hpp",
  "provenance/src/persona/SpeechPlanner.cpp",
  "provenance/release.yml",
  "provenance/requirements-preview.txt"
)

foreach ($file in $requiredFiles) {
  Assert-File $file
}

$quickstartText = Get-Content -LiteralPath (Join-PackagePath "QUICKSTART.md") -Raw
foreach ($pattern in @("share_release.cmd", "verify_share_release.cmd", "DownloadCloudflared", "PUBLIC_URL.txt", "STOP_SHARING.cmd", "prepare_device_arrival.cmd", "-Operator", "-DeviceId", "-ShareRoot", "HOSTED_MEDIA_REFERENCE.md", "RUN_DISPLAY_ONLY.cmd", "RUN_SERVO_CALIBRATION.cmd", "RUN_PROGRESS_CHECK.cmd", "RUN_ADD_MEDIA.cmd", "RUN_PLAY_LEAD_VOICE.cmd", "RVC_LEAD_AUDITION.md", "reference_audio\", "RVC Bright Robot", "AUDIO_REVIEW.md", "real-device speaker recording", "audio\", "generated source WAVs alone do not count", "-ConfirmServoRisk", "Hardware validation is still required")) {
  if ($quickstartText -notmatch [regex]::Escape($pattern)) {
    throw "QUICKSTART.md missing required guidance: $pattern"
  }
}

$arrivalRunbookText = Get-Content -LiteralPath (Join-PackagePath "ARRIVAL_DAY_RUNBOOK.md") -Raw
foreach ($pattern in @("Stackchan Arrival-Day Runbook", "RUN_PACKAGE_VERIFY.cmd", "RUN_DISPLAY_ONLY.cmd", "RUN_SERVO_CALIBRATION.cmd", "RUN_SOAK_MONITOR.cmd", "RUN_PLAY_LEAD_VOICE.cmd", "RVC_LEAD_AUDITION.md", "reference_audio/", "HOSTED_MEDIA_REFERENCE.md", "verified Cloudflare/share page", "pitch 2, index 0.62, RMS mix 0.72, and protect 0.28", "RUN_PROGRESS_CHECK.cmd", "RUN_EVIDENCE_VERIFY.cmd", "RUN_CONSUMER_PROMOTION_CHECK.cmd", "Hard stop if", "production voice-source provenance", "GitHub Actions")) {
  if ($arrivalRunbookText -notmatch [regex]::Escape($pattern)) {
    throw "ARRIVAL_DAY_RUNBOOK.md missing required bench guidance: $pattern"
  }
}

$shareGeneratorText = Get-Content -LiteralPath (Join-PackagePath "tools/share_release.ps1") -Raw
foreach ($pattern in @(".zip.sha256", "Get-FileHash", "ZIP SHA256", "Wait-LocalUrlReady", "PublicUrlReadyWaitSeconds", "Wait-PublicUrlReady", "Find-CloudflarePublicUrl", "publicUrlReady", "Stop-ExistingShare", "Remove-ShareRoot", "Test-TcpPortAvailable", "Find-AvailableTcpPort", "Requested share port", "Pending Promotion Gates", "promotionGateItems", "hardwareGates", "requiredEvidence", "Do not mark this release consumer-ready", "Face Phase A", "phase_a_idle_10s.gif", "phase_a_blink_filmstrip_50ms.png", "phase_a_unlabeled_expression_sheet.png", "Face Phase B", "phase_b_unlabeled_expression_sheet.png", "procedural eye-corner cuts", "two-curve open mouth", "authored L0 pose keys", "Face Phase C", "phase_c_idle_10s.gif", "autonomic blink", "saccade jumps", "breathing offset", "Face Phase D", "phase_d_idle_to_listen_filmstrip_50ms.png", "phase_d_think_to_speak_filmstrip_50ms.png", "phase_d_idle_to_sleep_filmstrip_50ms.png", "transition choreography", "anticipation", "channel lag", "Face Phase E", "phase_e_speech_reactive_6s.gif", "speech envelope sidecar", "viseme-lite", "tools/verify_face_phase_e.ps1", "Arrival-Day Evidence Loop", "RUN_PROGRESS_CHECK.cmd", "RUN_EVIDENCE_VERIFY.cmd", "RUN_CONSUMER_PROMOTION_CHECK.cmd", "Hardware Audio Evidence", "AUDIO_REVIEW.md", "real-device speaker sample", "Generated source WAVs alone do not count", "Dependency Provenance", "dependency_lock.json", "Voice Source Gate", "VOICE_SOURCE_PROVENANCE_TEMPLATE.md", "voice_source_provenance.yaml", "RVC Candidate Base", "voice_rvc_base.yaml", "candidate-pending-rights-review", "tools/verify_rvc_voice_base.ps1", "RVC Voice Auditions", "stackchan_rvc_neutral.wav", "stackchan_rvc_bright_robot.wav", "stackchan_rvc_bright_robot_less_static.wav", "RVC_AUDITIONS.md")) {
  if ($shareGeneratorText -notmatch [regex]::Escape($pattern)) {
    throw "tools/share_release.ps1 missing required share generation logic: $pattern"
  }
}

$shareVerifierText = Get-Content -LiteralPath (Join-PackagePath "tools/verify_share_release.ps1") -Raw
foreach ($pattern in @("SHA256SUMS.txt", ".zip.sha256", "ZIP SHA256 sidecar", "Invoke-UrlProbe", "Assert-HttpOk", "ProbeRetries", "ProbeDelaySeconds", "share_verification_report.json", "stackchan.share-verification.v1", "usedCurlResolveFallback", "Pending Promotion Gates", "target-speaker-audio-evidence", "Face Phase A", "phase_a_idle_10s.gif", "Face Phase B", "phase_b_unlabeled_expression_sheet.png", "Face Phase C", "phase_c_idle_10s.gif", "Face Phase D", "phase_d_idle_to_listen_filmstrip_50ms.png", "phase_d_think_to_speak_filmstrip_50ms.png", "phase_d_idle_to_sleep_filmstrip_50ms.png", "Face Phase E", "phase_e_speech_reactive_6s.gif", "Hardware Audio Evidence", "AUDIO_REVIEW.md", "Speaker audio evidence")) {
  if ($shareVerifierText -notmatch [regex]::Escape($pattern)) {
    throw "tools/verify_share_release.ps1 missing required remote verification logic: $pattern"
  }
}

$shareStopText = Get-Content -LiteralPath (Join-PackagePath "tools/stop_share.ps1") -Raw
foreach ($pattern in @("stillRunningProcessIds", "processIds", "Stop-Process", "Unable to stop share processes")) {
  if ($shareStopText -notmatch [regex]::Escape($pattern)) {
    throw "tools/stop_share.ps1 missing robust share cleanup logic: $pattern"
  }
}

$hardwareStarterText = Get-Content -LiteralPath (Join-PackagePath "tools/start_hardware_evidence.ps1") -Raw
foreach ($pattern in @("RELEASE_ACCEPTANCE.md", "release_acceptance.json", "AUDIO_REVIEW.md", "Stackchan Audio Review", "Speaker recording file", "Intelligible through device speaker", "Copy-AcceptanceArtifactsFromZip", "Copy-AcceptanceArtifactsFromRoot", "Copy-VoiceLeadArtifactsFromZip", "Copy-ShareVerificationArtifactsFromRoot", "shareVerification", "HOSTED_MEDIA_REFERENCE.md", "share/share_verification_report.json", "voiceLeadAudition", "RVC_LEAD_AUDITION.md", "reference_audio", "RUN_PLAY_LEAD_VOICE.cmd", "leadAudition", "leadSourcePath", "RUN_ADD_MEDIA.cmd", "add_hardware_evidence_media.ps1", "media_manifest.json", "RUN_PROGRESS_CHECK.cmd", "check_hardware_evidence_progress.ps1", "RUN_CONSUMER_PROMOTION_CHECK.cmd", "verify_consumer_promotion.ps1", "New-PowerShellCommandFile", "`$global:LASTEXITCODE", "exit /b %ERRORLEVEL%")) {
  if ($hardwareStarterText -notmatch [regex]::Escape($pattern)) {
    throw "tools/start_hardware_evidence.ps1 missing acceptance artifact capture logic: $pattern"
  }
}

$hardwareMediaImporterText = Get-Content -LiteralPath (Join-PackagePath "tools/add_hardware_evidence_media.ps1") -Raw
foreach ($pattern in @("stackchan.hardware-media-manifest.v1", "Test-PhotoEvidenceFile", "Test-AudioEvidenceFile", "media_manifest.json", "SHA256", "photos", "audio")) {
  if ($hardwareMediaImporterText -notmatch [regex]::Escape($pattern)) {
    throw "tools/add_hardware_evidence_media.ps1 missing media import or validation logic: $pattern"
  }
}

$syntheticEvidenceGeneratorText = Get-Content -LiteralPath (Join-PackagePath "tools/generate_synthetic_hardware_evidence.ps1") -Raw
foreach ($pattern in @("diagnosticOnly", "syntheticEvidence", "AllowSyntheticEvidence", "Synthetic hardware evidence packet", "AUDIO_REVIEW.md", "synthetic_speaker_fixture.wav", "must not be used as rollout evidence")) {
  if ($syntheticEvidenceGeneratorText -notmatch [regex]::Escape($pattern)) {
    throw "tools/generate_synthetic_hardware_evidence.ps1 missing synthetic evidence safety logic: $pattern"
  }
}

$hardwareProgressText = Get-Content -LiteralPath (Join-PackagePath "tools/check_hardware_evidence_progress.ps1") -Raw
foreach ($pattern in @("OBSERVATIONS.md has blank field", "AUDIO_REVIEW.md has blank field", "No real-device speaker recording found under audio/", "CHECKLIST.md still has unchecked gates", "No photo or video evidence found", "display-only boot marker", "RVC lead audition reference hash matches metadata", "metadata.json has no shareVerification reference", "Hosted media share verification report matches metadata", "RUN_PLAY_LEAD_VOICE.cmd", "RUN_EVIDENCE_VERIFY.cmd")) {
  if ($hardwareProgressText -notmatch [regex]::Escape($pattern)) {
    throw "tools/check_hardware_evidence_progress.ps1 missing evidence progress check: $pattern"
  }
}

$hardwareVerifierText = Get-Content -LiteralPath (Join-PackagePath "tools/verify_hardware_evidence.ps1") -Raw
foreach ($pattern in @("stackchan.release-acceptance.v1", "test-ready-for-device-arrival", "blocked-pending-hardware-validation", "release_acceptance.json", "AUDIO_REVIEW.md", "Test-AudioEvidenceFile", "Speaker recording file", "Intelligible through device speaker", "voiceLeadAudition", "RVC_LEAD_AUDITION.md", "RVC lead audition reference hash does not match metadata", "shareVerification", "stackchan.share-verification.v1", "share verification report does not show all probes HTTP 200", "HOSTED_MEDIA_REFERENCE.md missing expected marker", "AllowSyntheticEvidence", "diagnosticOnly")) {
  if ($hardwareVerifierText -notmatch [regex]::Escape($pattern)) {
    throw "tools/verify_hardware_evidence.ps1 missing acceptance artifact verification logic: $pattern"
  }
}

$consumerPromotionVerifierText = Get-Content -LiteralPath (Join-PackagePath "tools/verify_consumer_promotion.ps1") -Raw
foreach ($pattern in @("verify_release_package.ps1", "verify_hardware_evidence.ps1", "github_actions_status.json", "external-account-billing-or-spending-limit", "voice_source_provenance.yaml", "pending-production-source", "Consumer promotion gate verified", "AllowMissingMedia cannot be used for consumer promotion", "strict media evidence")) {
  if ($consumerPromotionVerifierText -notmatch [regex]::Escape($pattern)) {
    throw "tools/verify_consumer_promotion.ps1 missing promotion gate logic: $pattern"
  }
}
if ($consumerPromotionVerifierText -match "evidenceArgs\s*\+=\s*['`"]-AllowMissingMedia['`"]") {
  throw "tools/verify_consumer_promotion.ps1 must not forward AllowMissingMedia to hardware evidence verification"
}

$publishedVerifierText = Get-Content -LiteralPath (Join-PackagePath "tools/verify_published_release.ps1") -Raw
foreach ($pattern in @("ZipSidecarPath", ".zip.sha256", "Published ZIP SHA256 sidecar", "GITHUB_ACTIONS_STATUS.md", "github_actions_status.json")) {
  if ($publishedVerifierText -notmatch [regex]::Escape($pattern)) {
    throw "tools/verify_published_release.ps1 missing required published ZIP sidecar verification logic: $pattern"
  }
}

$publisherText = Get-Content -LiteralPath (Join-PackagePath "tools/publish_release.ps1") -Raw
foreach ($pattern in @("Export-ActionsStatusWithRetry", "Update-ReleaseArchive", "GITHUB_ACTIONS_STATUS.md", "github_actions_status.json", "--clobber")) {
  if ($publisherText -notmatch [regex]::Escape($pattern)) {
    throw "tools/publish_release.ps1 missing required finalized Actions status publish logic: $pattern"
  }
}

$actionsStatusExporterText = Get-Content -LiteralPath (Join-PackagePath "tools/export_github_actions_status.ps1") -Raw
foreach ($pattern in @("stackchan.github-actions-status.v1", "external-account-billing-or-spending-limit", "external-account-ci-pre-runner-allocation", "payments have failed", "spending limit", "runnerId", "stepCount")) {
  if ($actionsStatusExporterText -notmatch [regex]::Escape($pattern)) {
    throw "tools/export_github_actions_status.ps1 missing required Actions status export logic: $pattern"
  }
}

$voiceSourceStatusExporterText = Get-Content -LiteralPath (Join-PackagePath "tools/export_voice_source_status.ps1") -Raw
foreach ($pattern in @("stackchan.voice-source-status.v1", "blocked-pending-production-voice-source", "production-source-ready", "candidate-pending-rights-review", "VOICE_SOURCE_STATUS.md", "voice_source_status.json", "FailOnBlocked")) {
  if ($voiceSourceStatusExporterText -notmatch [regex]::Escape($pattern)) {
    throw "tools/export_voice_source_status.ps1 missing required voice-source status logic: $pattern"
  }
}

$voiceToolsSetupText = Get-Content -LiteralPath (Join-PackagePath "tools/setup_voice_tools.ps1") -Raw
foreach ($pattern in @("eSpeak-NG.eSpeak-NG", "ChrisBagwell.SoX", "ContinueOnInstallFailure", "RenderEspeakSamples", "render_voice_samples.ps1", "-Engine espeak", "verify_voice_samples.ps1", "stackchan.voice-tools-status.v1", "installFailures")) {
  if ($voiceToolsSetupText -notmatch [regex]::Escape($pattern)) {
    throw "tools/setup_voice_tools.ps1 missing required lightweight voice setup logic: $pattern"
  }
}

Assert-File "firmware/display_only/firmware.bin" 100000
Assert-File "firmware/servo_calibration/firmware.bin" 100000
Assert-File "media/stackchan_alive_preview.png" 1000
Assert-File "media/stackchan_alive_expression_sheet.png" 2000
Assert-File "media/stackchan_alive_preview.gif" 1000
Assert-File "media/stackchan_alive_preview.mp4" 1000
Assert-File "media/stackchan_alive_speech_preview.gif" 1000
Assert-File "artifacts/face/phase_a_idle_10s.gif" 100000
Assert-File "artifacts/face/phase_a_blink_filmstrip_50ms.png" 1000
Assert-File "artifacts/face/phase_a_unlabeled_expression_sheet.png" 1000
Assert-File "artifacts/face/phase_b_unlabeled_expression_sheet.png" 1000
Assert-File "artifacts/face/phase_c_idle_10s.gif" 100000
Assert-File "artifacts/face/phase_d_idle_to_listen_filmstrip_50ms.png" 1000
Assert-File "artifacts/face/phase_d_think_to_speak_filmstrip_50ms.png" 1000
Assert-File "artifacts/face/phase_d_idle_to_sleep_filmstrip_50ms.png" 1000
Assert-File "artifacts/face/phase_e_speech_reactive_6s.gif" 1000
Assert-File "media/voice/stackchan_spark_greeting.wav" 1000
Assert-File "media/voice/stackchan_spark_thinking.wav" 1000
Assert-File "media/voice/stackchan_spark_safety.wav" 1000
Assert-File "media/voice/stackchan_spark_audition_warm_slow_greeting.wav" 1000
Assert-File "media/voice/stackchan_spark_audition_bright_robot_greeting.wav" 1000
Assert-File "media/voice/VOICE_SAMPLES.md" 100
Assert-File "media/voice/rvc/RVC_AUDITIONS.md" 500
Assert-File "media/voice/rvc/RVC_AUDITIONS.json" 500
Assert-File "media/voice/rvc/stackchan_rvc_neutral.wav" 100000
Assert-File "media/voice/rvc/stackchan_rvc_warm_slow.wav" 100000
Assert-File "media/voice/rvc/stackchan_rvc_bright_robot.wav" 100000
Assert-File "media/voice/rvc/stackchan_rvc_bright_robot_less_static.wav" 100000
Assert-File "media/voice/rvc/stackchan_rvc_bright_robot_sweet_vocoder.wav" 100000
Assert-File "media/voice/rvc/stackchan_rvc_bright_robot_soft_boops.wav" 100000
Assert-File "media/voice/rvc/stackchan_rvc_spark_boops.wav" 100000
Assert-File "media/voice/rvc/stackchan_rvc_high_character.wav" 100000
Assert-File "media/voice/rvc/stackchan_rvc_thinking_neutral.wav" 100000
Assert-File "media/voice/rvc/stackchan_rvc_safety_neutral.wav" 100000

Assert-Bytes "media/stackchan_alive_preview.png" ([byte[]](0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a))
Assert-Bytes "media/stackchan_alive_expression_sheet.png" ([byte[]](0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a))
Assert-Bytes "media/stackchan_alive_preview.gif" ([byte[]](0x47, 0x49, 0x46, 0x38))
Assert-Bytes "media/stackchan_alive_preview.mp4" ([byte[]](0x66, 0x74, 0x79, 0x70)) 4
Assert-Bytes "media/stackchan_alive_speech_preview.gif" ([byte[]](0x47, 0x49, 0x46, 0x38))
Assert-Bytes "artifacts/face/phase_a_idle_10s.gif" ([byte[]](0x47, 0x49, 0x46, 0x38))
Assert-Bytes "artifacts/face/phase_a_blink_filmstrip_50ms.png" ([byte[]](0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a))
Assert-Bytes "artifacts/face/phase_a_unlabeled_expression_sheet.png" ([byte[]](0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a))
Assert-Bytes "artifacts/face/phase_b_unlabeled_expression_sheet.png" ([byte[]](0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a))
Assert-Bytes "artifacts/face/phase_c_idle_10s.gif" ([byte[]](0x47, 0x49, 0x46, 0x38))
Assert-Bytes "artifacts/face/phase_d_idle_to_listen_filmstrip_50ms.png" ([byte[]](0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a))
Assert-Bytes "artifacts/face/phase_d_think_to_speak_filmstrip_50ms.png" ([byte[]](0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a))
Assert-Bytes "artifacts/face/phase_d_idle_to_sleep_filmstrip_50ms.png" ([byte[]](0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a))
Assert-Bytes "artifacts/face/phase_e_speech_reactive_6s.gif" ([byte[]](0x47, 0x49, 0x46, 0x38))
Assert-Bytes "media/voice/stackchan_spark_greeting.wav" ([byte[]](0x52, 0x49, 0x46, 0x46))
Assert-Bytes "media/voice/stackchan_spark_thinking.wav" ([byte[]](0x52, 0x49, 0x46, 0x46))
Assert-Bytes "media/voice/stackchan_spark_safety.wav" ([byte[]](0x52, 0x49, 0x46, 0x46))
Assert-Bytes "media/voice/stackchan_spark_audition_warm_slow_greeting.wav" ([byte[]](0x52, 0x49, 0x46, 0x46))
Assert-Bytes "media/voice/stackchan_spark_audition_bright_robot_greeting.wav" ([byte[]](0x52, 0x49, 0x46, 0x46))
Assert-Bytes "media/voice/rvc/stackchan_rvc_neutral.wav" ([byte[]](0x52, 0x49, 0x46, 0x46))
Assert-Bytes "media/voice/rvc/stackchan_rvc_warm_slow.wav" ([byte[]](0x52, 0x49, 0x46, 0x46))
Assert-Bytes "media/voice/rvc/stackchan_rvc_bright_robot.wav" ([byte[]](0x52, 0x49, 0x46, 0x46))
Assert-Bytes "media/voice/rvc/stackchan_rvc_bright_robot_less_static.wav" ([byte[]](0x52, 0x49, 0x46, 0x46))
Assert-Bytes "media/voice/rvc/stackchan_rvc_bright_robot_sweet_vocoder.wav" ([byte[]](0x52, 0x49, 0x46, 0x46))
Assert-Bytes "media/voice/rvc/stackchan_rvc_bright_robot_soft_boops.wav" ([byte[]](0x52, 0x49, 0x46, 0x46))
Assert-Bytes "media/voice/rvc/stackchan_rvc_spark_boops.wav" ([byte[]](0x52, 0x49, 0x46, 0x46))
Assert-Bytes "media/voice/rvc/stackchan_rvc_high_character.wav" ([byte[]](0x52, 0x49, 0x46, 0x46))
Assert-Bytes "media/voice/rvc/stackchan_rvc_thinking_neutral.wav" ([byte[]](0x52, 0x49, 0x46, 0x46))
Assert-Bytes "media/voice/rvc/stackchan_rvc_safety_neutral.wav" ([byte[]](0x52, 0x49, 0x46, 0x46))

& (Join-PackagePath "tools/verify_voice_samples.ps1") -VoiceRoot (Join-PackagePath "media/voice")
& (Join-PackagePath "tools/verify_rvc_auditions.ps1") -VoiceRoot (Join-PackagePath "media/voice/rvc")

& (Join-Path $PSScriptRoot "verify_preview_media.ps1") -MediaRoot (Join-PackagePath "media")
& (Join-PackagePath "tools/verify_face_phase_a.ps1") -ArtifactsRoot (Join-PackagePath "artifacts/face")
& (Join-PackagePath "tools/verify_face_phase_b.ps1") -ArtifactsRoot (Join-PackagePath "artifacts/face")
& (Join-PackagePath "tools/verify_face_phase_c.ps1") -ArtifactsRoot (Join-PackagePath "artifacts/face")
& (Join-PackagePath "tools/verify_face_phase_d.ps1") -ArtifactsRoot (Join-PackagePath "artifacts/face")
& (Join-PackagePath "tools/verify_face_phase_e.ps1") -ArtifactsRoot (Join-PackagePath "artifacts/face")

$manifestPath = Join-PackagePath "release_manifest.json"
$manifest = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json

if ($manifest.version -ne $Version) {
  throw "Manifest version mismatch: expected $Version, got $($manifest.version)"
}

if ($manifest.commit -ne $ExpectedCommit) {
  throw "Manifest commit mismatch: expected $ExpectedCommit, got $($manifest.commit)"
}

if ($manifest.board -ne "m5stack-cores3") {
  throw "Manifest board mismatch: $($manifest.board)"
}

if ($manifest.defaultEnvironment -ne "stackchan") {
  throw "Manifest defaultEnvironment mismatch: $($manifest.defaultEnvironment)"
}

$envs = @($manifest.includedEnvironments)
if (-not ($envs -contains "stackchan") -or -not ($envs -contains "stackchan_servo_calibration")) {
  throw "Manifest missing expected environments"
}

if ($manifest.status -notmatch "hardware validation pending") {
  throw "Manifest status must state that hardware validation is pending"
}

if ($manifest.dirty -and -not $AllowDirtyPackage) {
  throw "Release package manifest reports a dirty source worktree"
}

if ($manifest.dependencyReport -ne "DEPENDENCIES.md") {
  throw "Manifest dependencyReport mismatch: $($manifest.dependencyReport)"
}

if ($manifest.dependencyLock -ne "dependency_lock.json") {
  throw "Manifest dependencyLock mismatch: $($manifest.dependencyLock)"
}

if ($manifest.readinessReport -ne "READINESS_REPORT.md") {
  throw "Manifest readinessReport mismatch: $($manifest.readinessReport)"
}

if ($manifest.readinessReportJson -ne "readiness_report.json") {
  throw "Manifest readinessReportJson mismatch: $($manifest.readinessReportJson)"
}

if ($manifest.ciStatusReport -ne "GITHUB_ACTIONS_STATUS.md") {
  throw "Manifest ciStatusReport mismatch: $($manifest.ciStatusReport)"
}

if ($manifest.ciStatusReportJson -ne "github_actions_status.json") {
  throw "Manifest ciStatusReportJson mismatch: $($manifest.ciStatusReportJson)"
}

if ($manifest.acceptanceChecklist -ne "RELEASE_ACCEPTANCE.md") {
  throw "Manifest acceptanceChecklist mismatch: $($manifest.acceptanceChecklist)"
}

if ($manifest.acceptanceChecklistJson -ne "release_acceptance.json") {
  throw "Manifest acceptanceChecklistJson mismatch: $($manifest.acceptanceChecklistJson)"
}

if ($manifest.voicePersonalityGuide -ne "docs/VOICE_PERSONALITY.md") {
  throw "Manifest voicePersonalityGuide mismatch: $($manifest.voicePersonalityGuide)"
}

if ($manifest.voicePersona -ne "data/voice_persona.yaml") {
  throw "Manifest voicePersona mismatch: $($manifest.voicePersona)"
}

if ($manifest.voiceSourceProvenanceTemplate -ne "docs/VOICE_SOURCE_PROVENANCE_TEMPLATE.md") {
  throw "Manifest voiceSourceProvenanceTemplate mismatch: $($manifest.voiceSourceProvenanceTemplate)"
}

if ($manifest.voiceSourceProvenance -ne "data/voice_source_provenance.yaml") {
  throw "Manifest voiceSourceProvenance mismatch: $($manifest.voiceSourceProvenance)"
}

if ($manifest.voiceSourceStatusReport -ne "VOICE_SOURCE_STATUS.md") {
  throw "Manifest voiceSourceStatusReport mismatch: $($manifest.voiceSourceStatusReport)"
}

if ($manifest.voiceSourceStatusReportJson -ne "voice_source_status.json") {
  throw "Manifest voiceSourceStatusReportJson mismatch: $($manifest.voiceSourceStatusReportJson)"
}

if ($manifest.voiceRvcBase -ne "data/voice_rvc_base.yaml") {
  throw "Manifest voiceRvcBase mismatch: $($manifest.voiceRvcBase)"
}

if ($manifest.voiceRvcBaseMetadata -ne "data/voice_rvc_base_metadata.json") {
  throw "Manifest voiceRvcBaseMetadata mismatch: $($manifest.voiceRvcBaseMetadata)"
}

$expectedMediaArtifacts = @(
  "media/stackchan_alive_preview.png",
  "media/stackchan_alive_expression_sheet.png",
  "media/stackchan_alive_preview.mp4",
  "media/stackchan_alive_preview.gif",
  "media/stackchan_alive_speech_preview.gif",
  "artifacts/face/phase_a_idle_10s.gif",
  "artifacts/face/phase_a_blink_filmstrip_50ms.png",
  "artifacts/face/phase_a_unlabeled_expression_sheet.png",
  "artifacts/face/phase_b_unlabeled_expression_sheet.png",
  "artifacts/face/phase_c_idle_10s.gif",
  "artifacts/face/phase_d_idle_to_listen_filmstrip_50ms.png",
  "artifacts/face/phase_d_think_to_speak_filmstrip_50ms.png",
  "artifacts/face/phase_d_idle_to_sleep_filmstrip_50ms.png",
  "artifacts/face/phase_e_speech_reactive_6s.gif",
  "media/voice/stackchan_spark_greeting.wav",
  "media/voice/stackchan_spark_thinking.wav",
  "media/voice/stackchan_spark_safety.wav",
  "media/voice/stackchan_spark_audition_warm_slow_greeting.wav",
  "media/voice/stackchan_spark_audition_bright_robot_greeting.wav",
  "media/voice/VOICE_SAMPLES.md",
  "media/voice/rvc/RVC_AUDITIONS.md",
  "media/voice/rvc/RVC_AUDITIONS.json",
  "media/voice/rvc/stackchan_rvc_neutral.wav",
  "media/voice/rvc/stackchan_rvc_warm_slow.wav",
  "media/voice/rvc/stackchan_rvc_bright_robot.wav",
  "media/voice/rvc/stackchan_rvc_bright_robot_less_static.wav",
  "media/voice/rvc/stackchan_rvc_bright_robot_sweet_vocoder.wav",
  "media/voice/rvc/stackchan_rvc_bright_robot_soft_boops.wav",
  "media/voice/rvc/stackchan_rvc_spark_boops.wav",
  "media/voice/rvc/stackchan_rvc_high_character.wav",
  "media/voice/rvc/stackchan_rvc_thinking_neutral.wav",
  "media/voice/rvc/stackchan_rvc_safety_neutral.wav"
)
$actualMediaArtifacts = @($manifest.mediaArtifacts)
foreach ($file in $expectedMediaArtifacts) {
  if ($actualMediaArtifacts -notcontains $file) {
    throw "Manifest mediaArtifacts missing expected file: $file"
  }
}
foreach ($file in $actualMediaArtifacts) {
  if ($expectedMediaArtifacts -notcontains $file) {
    throw "Manifest mediaArtifacts contains unexpected file: $file"
  }
  Assert-File $file
}

foreach ($file in @($manifest.includedTools)) {
  Assert-File $file
}

foreach ($file in @($manifest.provenanceFiles)) {
  Assert-File $file
}

$dependenciesText = Get-Content -LiteralPath (Join-PackagePath "DEPENDENCIES.md") -Raw
$dependencyPatterns = @(
  "PlatformIO Core",
  "pillow==12.2.0",
  "imageio==2.37.3",
  "imageio-ffmpeg==0.6.0",
  "stackchan-arduino",
  "b7b98f5",
  "SCServo",
  "ee6ee4a",
  "Dependency Audit",
  "Direct Git dependencies missing refs",
  "Unpinned upstream Git requirements",
  "Resolved Git packages without SHA evidence"
)

foreach ($pattern in $dependencyPatterns) {
  if ($dependenciesText -notmatch [regex]::Escape($pattern)) {
    throw "DEPENDENCIES.md missing expected text: $pattern"
  }
}

$dependencyLockPath = Join-PackagePath "dependency_lock.json"
$dependencyLock = Get-Content -LiteralPath $dependencyLockPath -Raw | ConvertFrom-Json

if ($dependencyLock.schema -ne "stackchan.dependency-lock.v1") {
  throw "dependency_lock.json schema mismatch: $($dependencyLock.schema)"
}

if ($dependencyLock.version -ne $Version) {
  throw "dependency_lock.json version mismatch: expected $Version, got $($dependencyLock.version)"
}

if ($dependencyLock.commit -ne $ExpectedCommit) {
  throw "dependency_lock.json commit mismatch: expected $ExpectedCommit, got $($dependencyLock.commit)"
}

if ($dependencyLock.platformioCore -notmatch "PlatformIO Core, version 6\.1\.19") {
  throw "dependency_lock.json has unexpected PlatformIO version: $($dependencyLock.platformioCore)"
}

$expectedPreviewRequirements = @(
  "pillow==12.2.0",
  "imageio==2.37.3",
  "imageio-ffmpeg==0.6.0"
)
$actualPreviewRequirements = @($dependencyLock.previewRequirements)
foreach ($requirement in $expectedPreviewRequirements) {
  if ($actualPreviewRequirements -notcontains $requirement) {
    throw "dependency_lock.json missing preview requirement: $requirement"
  }
}

foreach ($requirement in $actualPreviewRequirements) {
  if ($requirement -notmatch "^[A-Za-z0-9_.-]+==[A-Za-z0-9_.-]+$") {
    throw "dependency_lock.json has non-exact preview requirement: $requirement"
  }
}

$expectedDeclaredLibDeps = @(
  "https://github.com/stack-chan/stackchan-arduino.git#b7b98f5",
  "bblanchon/ArduinoJson@7.4.3",
  "robotis-git/Dynamixel2Arduino@0.7.0",
  "madhephaestus/ESP32Servo@0.13.0",
  "M5Stack/M5Unified@0.2.17",
  "M5GFX@0.2.24",
  "https://github.com/mongonta0716/SCServo.git#ee6ee4a",
  "arminjo/ServoEasing@3.1.0",
  "tobozo/YAMLDuino@1.5.0"
)
$actualDeclaredLibDeps = @($dependencyLock.declaredLibDeps)
foreach ($dep in $expectedDeclaredLibDeps) {
  if ($actualDeclaredLibDeps -notcontains $dep) {
    throw "dependency_lock.json missing declared lib dependency: $dep"
  }
}

foreach ($dep in $actualDeclaredLibDeps) {
  if ($dep -notmatch "(@|#)[A-Za-z0-9_.-]+$") {
    throw "dependency_lock.json has unpinned declared lib dependency: $dep"
  }
}

function Assert-LockedPackage {
  param(
    [object[]]$Packages,
    [string]$Name,
    [string]$VersionPattern
  )

  $matches = @($Packages | Where-Object { $_.name -eq $Name -and $_.version -match $VersionPattern })
  if ($matches.Count -eq 0) {
    throw "dependency_lock.json missing locked package $Name matching $VersionPattern"
  }
}

function ConvertTo-Array {
  param([object]$Value)
  if ($null -eq $Value) {
    return @()
  }
  return @($Value)
}

foreach ($envName in @("stackchan", "stackchan_servo_calibration")) {
  $envLock = $dependencyLock.environments.$envName
  if ($null -eq $envLock) {
    throw "dependency_lock.json missing environment: $envName"
  }
  if ($envLock.board -ne "m5stack-cores3") {
    throw "dependency_lock.json board mismatch for $envName`: $($envLock.board)"
  }
  if ($envLock.framework -ne "arduino") {
    throw "dependency_lock.json framework mismatch for $envName`: $($envLock.framework)"
  }
  if ($envLock.platform -ne "espressif32@7.0.1") {
    throw "dependency_lock.json platform mismatch for $envName`: $($envLock.platform)"
  }

  $packages = @($envLock.resolvedPackages)
  Assert-LockedPackage $packages "espressif32" "^7\.0\.1$"
  Assert-LockedPackage $packages "framework-arduinoespressif32" "^3\.20017\.241212\+sha\.dcc1105b$"
  Assert-LockedPackage $packages "tool-esptoolpy" "^2\.41100\.0$"
  Assert-LockedPackage $packages "toolchain-xtensa-esp32s3" "^8\.4\.0\+2021r2-patch5$"
  Assert-LockedPackage $packages "stackchan-arduino" "sha\.b7b98f5$"
  Assert-LockedPackage $packages "SCServo" "sha\.ee6ee4a$"
}

$dependencyAudit = $dependencyLock.dependencyAudit
if ($null -eq $dependencyAudit) {
  throw "dependency_lock.json missing dependencyAudit"
}

if ([string]::IsNullOrWhiteSpace([string]$dependencyAudit.policy)) {
  throw "dependency_lock.json dependencyAudit missing policy"
}

$directGitDepsMissingRef = ConvertTo-Array $dependencyAudit.directGitDepsMissingRef
if ($directGitDepsMissingRef.Count -gt 0) {
  throw "dependency_lock.json has direct Git dependencies without refs: $($directGitDepsMissingRef -join ', ')"
}

$gitResolvedWithoutSha = ConvertTo-Array $dependencyAudit.gitResolvedWithoutSha
if ($gitResolvedWithoutSha.Count -gt 0) {
  $badNames = ($gitResolvedWithoutSha | ForEach-Object { "$($_.environment)/$($_.name)" }) -join ", "
  throw "dependency_lock.json has resolved Git dependencies without SHA evidence: $badNames"
}

$duplicateResolvedPackages = ConvertTo-Array $dependencyAudit.duplicateResolvedPackages
foreach ($duplicate in $duplicateResolvedPackages) {
  if ($duplicate.name -ne "SCServo") {
    throw "dependency_lock.json has unexpected duplicate resolved package: $($duplicate.environment)/$($duplicate.name)"
  }
}

$unpinnedGitRequirements = ConvertTo-Array $dependencyAudit.unpinnedGitRequirements
foreach ($requirement in $unpinnedGitRequirements) {
  if ($requirement.name -ne "SCServo") {
    throw "dependency_lock.json has unexpected unpinned upstream Git requirement: $($requirement.environment)/$($requirement.name)"
  }
  if ($requirement.version -notmatch "sha\.ee6ee4a$") {
    throw "dependency_lock.json SCServo upstream Git requirement resolved to unexpected version: $($requirement.version)"
  }
}

$releaseNotes = Get-Content -LiteralPath (Join-PackagePath "RELEASE_NOTES.md") -Raw
if ($releaseNotes -notmatch [regex]::Escape($ExpectedCommit)) {
  throw "RELEASE_NOTES.md missing expected commit"
}
if ($releaseNotes -notmatch "Hardware validation is still required") {
  throw "RELEASE_NOTES.md must state that hardware validation is still required"
}
if ($releaseNotes -notmatch "READINESS_REPORT.md") {
  throw "RELEASE_NOTES.md missing readiness report reference"
}

$voiceGuide = Get-Content -LiteralPath (Join-PackagePath "docs/VOICE_PERSONALITY.md") -Raw
foreach ($pattern in @("Stackchan Spark", "must not clone", "soundboard clips", "RVC character models", "licensed neutral TTS voice", "Acceptance Criteria")) {
  if ($voiceGuide -notmatch [regex]::Escape($pattern)) {
    throw "VOICE_PERSONALITY.md missing expected voice guardrail: $pattern"
  }
}

$voicePersona = Get-Content -LiteralPath (Join-PackagePath "data/voice_persona.yaml") -Raw
foreach ($pattern in @("schema: stackchan.voice-persona.v1", "profile_id: stackchan_spark", "cloning named character or actor voices", "training from soundboard clips", "licensed_or_owned_voice_source")) {
  if ($voicePersona -notmatch [regex]::Escape($pattern)) {
    throw "voice_persona.yaml missing expected voice policy: $pattern"
  }
}

$voiceSourceTemplate = Get-Content -LiteralPath (Join-PackagePath "docs/VOICE_SOURCE_PROVENANCE_TEMPLATE.md") -Raw
foreach ($pattern in @("Voice Source Provenance Template", "pending production voice source", "No soundboard clips", "No named character", "No RVC character model", "Commercial/device use allowed", "real-device audio/video evidence")) {
  if ($voiceSourceTemplate -notmatch [regex]::Escape($pattern)) {
    throw "VOICE_SOURCE_PROVENANCE_TEMPLATE.md missing expected provenance guidance: $pattern"
  }
}

$voiceSourceProvenance = Get-Content -LiteralPath (Join-PackagePath "data/voice_source_provenance.yaml") -Raw
foreach ($pattern in @("schema: stackchan.voice-source-provenance.v1", "status: pending-production-source", "review-only", "required-before-consumer-rollout", "soundboard clips", "RVC character models", "rvc_candidate_base", "candidate-pending-rights-review", "voice_rvc_base.yaml", "hardware_evidence_verification_pass", "blocked-pending-licensed-or-owned-production-voice-source")) {
  if ($voiceSourceProvenance -notmatch [regex]::Escape($pattern)) {
    throw "voice_source_provenance.yaml missing expected policy: $pattern"
  }
}

$voiceSourceStatusMarkdown = Get-Content -LiteralPath (Join-PackagePath "VOICE_SOURCE_STATUS.md") -Raw
foreach ($pattern in @("Voice Source Status", "blocked-pending-production-voice-source", "production-source-selected", "rvc-candidate-rights-review", "voice_source_status.json")) {
  if ($voiceSourceStatusMarkdown -notmatch [regex]::Escape($pattern)) {
    throw "VOICE_SOURCE_STATUS.md missing expected voice-source status text: $pattern"
  }
}

$voiceSourceStatusJson = Get-Content -LiteralPath (Join-PackagePath "voice_source_status.json") -Raw | ConvertFrom-Json
if ($voiceSourceStatusJson.schema -ne "stackchan.voice-source-status.v1") {
  throw "voice_source_status.json schema mismatch: $($voiceSourceStatusJson.schema)"
}
if ($voiceSourceStatusJson.status -ne "blocked-pending-production-voice-source") {
  throw "voice_source_status.json should keep current package blocked pending production voice source: $($voiceSourceStatusJson.status)"
}
if ([int]$voiceSourceStatusJson.blockedGateCount -lt 1) {
  throw "voice_source_status.json should report at least one blocked voice-source gate"
}
foreach ($gate in @("production-source-selected", "rvc-candidate-rights-review", "rollout-gate-open")) {
  $match = @($voiceSourceStatusJson.gates | Where-Object { $_.gate -eq $gate -and $_.status -eq "blocked" })
  if ($match.Count -ne 1) {
    throw "voice_source_status.json missing blocked gate: $gate"
  }
}

& (Join-PackagePath "tools/verify_rvc_voice_base.ps1") -ManifestPath (Join-PackagePath "data/voice_rvc_base.yaml") -MetadataPath (Join-PackagePath "data/voice_rvc_base_metadata.json")

$acceptance = Get-Content -LiteralPath (Join-PackagePath "release_acceptance.json") -Raw | ConvertFrom-Json
if ($acceptance.schema -ne "stackchan.release-acceptance.v1") {
  throw "release_acceptance.json schema mismatch: $($acceptance.schema)"
}
if ($acceptance.currentDecision -ne "test-ready-for-device-arrival") {
  throw "release_acceptance.json currentDecision mismatch: $($acceptance.currentDecision)"
}
if ($acceptance.consumerRolloutDecision -ne "blocked-pending-hardware-validation") {
  throw "release_acceptance.json consumerRolloutDecision mismatch: $($acceptance.consumerRolloutDecision)"
}
foreach ($requirement in @("clean-release-package", "dependency-provenance-present", "voice-review-samples-present", "voice-source-provenance-template-present", "voice-source-status-report-present", "hardware-media-importer-present", "servo-risk-gated", "share-page-verifiable")) {
  $match = @($acceptance.noHardwareAcceptance | Where-Object { $_.requirement -eq $requirement -and $_.status -eq "pass" })
  if ($match.Count -ne 1) {
    throw "release_acceptance.json missing passed no-hardware requirement: $requirement"
  }
}
foreach ($requirement in @("display-only-flash", "servo-calibration", "mixed-mode-soak", "target-speaker-audio-evidence", "hardware-evidence-verification", "production-voice-source")) {
  $match = @($acceptance.hardwareAcceptanceRequired | Where-Object { $_.requirement -eq $requirement -and $_.status -match "pending" })
  if ($match.Count -ne 1) {
    throw "release_acceptance.json missing pending hardware requirement: $requirement"
  }
}

$acceptanceText = Get-Content -LiteralPath (Join-PackagePath "RELEASE_ACCEPTANCE.md") -Raw
foreach ($pattern in @("test-ready for device arrival", "blocked pending hardware validation", "Dependency provenance", "Voice review samples", "Voice source provenance template", "Voice source status report", "VOICE_SOURCE_STATUS.md", "Hardware media importer", "add_hardware_evidence_media.cmd", "Target-speaker audio evidence", "AUDIO_REVIEW.md", "real-device speaker recording", "Completed voice-source provenance", "licensed or owned production voice source")) {
  if ($acceptanceText -notmatch [regex]::Escape($pattern)) {
    throw "RELEASE_ACCEPTANCE.md missing expected acceptance guidance: $pattern"
  }
}

$actionsStatus = Get-Content -LiteralPath (Join-PackagePath "github_actions_status.json") -Raw | ConvertFrom-Json
if ($actionsStatus.schema -ne "stackchan.github-actions-status.v1") {
  throw "github_actions_status.json schema mismatch: $($actionsStatus.schema)"
}
if ($actionsStatus.version -ne $Version) {
  throw "github_actions_status.json version mismatch: expected $Version, got $($actionsStatus.version)"
}
if ($actionsStatus.commit -ne $ExpectedCommit) {
  throw "github_actions_status.json commit mismatch: expected $ExpectedCommit, got $($actionsStatus.commit)"
}
if (@("post-push-check-required", "external-account-billing-or-spending-limit", "external-account-ci-pre-runner-allocation", "success") -notcontains $actionsStatus.status) {
  throw "github_actions_status.json status is not release-acceptable: $($actionsStatus.status)"
}

$actionsStatusText = Get-Content -LiteralPath (Join-PackagePath "GITHUB_ACTIONS_STATUS.md") -Raw
foreach ($pattern in @("GitHub Actions Status", $Version, $ExpectedCommit, "github_actions_status.json")) {
  if ($actionsStatusText -notmatch [regex]::Escape($pattern)) {
    throw "GITHUB_ACTIONS_STATUS.md missing expected status text: $pattern"
  }
}

$readinessMarkdown = Get-Content -LiteralPath (Join-PackagePath "READINESS_REPORT.md") -Raw
foreach ($pattern in @($Version, $ExpectedCommit, "device-ready prerelease", "blocked pending hardware validation", "Proven Without Hardware", "Pending Device Evidence", "GITHUB_ACTIONS_STATUS.md", "VOICE_SOURCE_STATUS.md", "add_hardware_evidence_media.cmd", "verify_hardware_evidence.cmd", "Voice source provenance", "Do not mark this release consumer-ready")) {
  if ($readinessMarkdown -notmatch [regex]::Escape($pattern)) {
    throw "READINESS_REPORT.md missing expected text: $pattern"
  }
}

$readinessJson = Get-Content -LiteralPath (Join-PackagePath "readiness_report.json") -Raw | ConvertFrom-Json
if ($readinessJson.schema -ne "stackchan.readiness-report.v1") {
  throw "readiness_report.json schema mismatch: $($readinessJson.schema)"
}
if ($readinessJson.version -ne $Version) {
  throw "readiness_report.json version mismatch: expected $Version, got $($readinessJson.version)"
}
if ($readinessJson.commit -ne $ExpectedCommit) {
  throw "readiness_report.json commit mismatch: expected $ExpectedCommit, got $($readinessJson.commit)"
}
if ($readinessJson.consumerRollout -ne "blocked-pending-hardware-validation") {
  throw "readiness_report.json must keep consumer rollout blocked until hardware validation"
}
foreach ($gate in @($readinessJson.noHardwareProof)) {
  if ($gate.status -ne "pass") {
    throw "readiness_report.json has non-passing no-hardware gate: $($gate.gate)"
  }
}
$voiceSourceNoHardwareGate = @($readinessJson.noHardwareProof | Where-Object { $_.gate -eq "voice-source-provenance-template-present" -and $_.status -eq "pass" })
if ($voiceSourceNoHardwareGate.Count -ne 1) {
  throw "readiness_report.json missing passed voice-source provenance template gate"
}
$voiceSourceStatusNoHardwareGate = @($readinessJson.noHardwareProof | Where-Object { $_.gate -eq "voice-source-status-report-present" -and $_.status -eq "pass" })
if ($voiceSourceStatusNoHardwareGate.Count -ne 1) {
  throw "readiness_report.json missing passed voice-source status report gate"
}
$mediaImporterNoHardwareGate = @($readinessJson.noHardwareProof | Where-Object { $_.gate -eq "hardware-media-importer-present" -and $_.status -eq "pass" })
if ($mediaImporterNoHardwareGate.Count -ne 1) {
  throw "readiness_report.json missing passed hardware-media-importer-present gate"
}
$speakerAudioGate = @($readinessJson.hardwareGates | Where-Object { $_.gate -eq "target-speaker-audio-evidence" -and $_.status -eq "pending-device" })
if ($speakerAudioGate.Count -ne 1) {
  throw "readiness_report.json missing pending target-speaker-audio-evidence gate"
}
foreach ($gate in @($readinessJson.hardwareGates)) {
  $allowedStatus = if ($gate.gate -eq "production-voice-source") { "pending-before-consumer-rollout" } else { "pending-device" }
  if ($gate.status -ne $allowedStatus) {
    throw "readiness_report.json hardware gate must remain pending-device before promotion: $($gate.gate)"
  }
}
if (@($readinessJson.hardwareGates).Count -lt 7) {
  throw "readiness_report.json is missing required hardware gates"
}

$hashPath = Join-PackagePath "SHA256SUMS.txt"
$hashLines = Get-Content -LiteralPath $hashPath | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
$seen = @{}

foreach ($line in $hashLines) {
  if ($line -notmatch "^([a-f0-9]{64})  (.+)$") {
    throw "Invalid SHA256SUMS line: $line"
  }

  $expectedHash = $Matches[1]
  $relativePath = $Matches[2]
  $filePath = Join-PackagePath $relativePath

  if (-not (Test-Path -LiteralPath $filePath)) {
    throw "SHA256SUMS references missing file: $relativePath"
  }

  if ($seen.ContainsKey($relativePath)) {
    throw "SHA256SUMS contains duplicate entry: $relativePath"
  }

  $seen[$relativePath] = $true
  $actualHash = (Get-FileHash -Algorithm SHA256 -LiteralPath $filePath).Hash.ToLowerInvariant()
  if ($actualHash -ne $expectedHash) {
    throw "SHA256 mismatch for $relativePath"
  }
}

$packagedFiles = Get-ChildItem -LiteralPath $packageRootPath -File -Recurse |
  ForEach-Object { $_.FullName.Substring($packageRootPath.Length + 1).Replace("\", "/") } |
  Where-Object { $_ -ne "SHA256SUMS.txt" -and $_ -notlike "output/*" }

foreach ($file in $packagedFiles) {
  if (-not $seen.ContainsKey($file)) {
    throw "SHA256SUMS missing entry for $file"
  }
}

foreach ($file in $seen.Keys) {
  if ($packagedFiles -notcontains $file) {
    throw "SHA256SUMS has extra entry for $file"
  }
}

Write-Host "Release package verified:"
Write-Host $packageRootPath

if ($cleanupDir) {
  $resolvedCleanup = (Resolve-Path $cleanupDir).Path
  $resolvedTempRoot = (Resolve-Path $tempRoot).Path
  if (-not $resolvedCleanup.StartsWith($resolvedTempRoot, [System.StringComparison]::OrdinalIgnoreCase)) {
    throw "Refusing to clean unexpected verification directory: $resolvedCleanup"
  }
  Remove-Item -LiteralPath $resolvedCleanup -Recurse -Force
}
