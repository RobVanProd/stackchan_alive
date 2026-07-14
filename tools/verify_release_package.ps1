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
$packageRootPrefix = $packageRootPath.TrimEnd('\') + '\'
$restrictedVoicePayloads = @(
  Get-ChildItem -LiteralPath $packageRootPath -File -Recurse | Where-Object {
    $relative = $_.FullName.Substring($packageRootPrefix.Length).Replace('\', '/')
    $extension = $_.Extension.ToLowerInvariant()
    $allowedVisionModel = $relative -match '(?i)^(provenance/)?bridge/models/face_detection_yunet_2023mar\.onnx$'
    $allowedProductionVoice = $relative -match '(?i)^media/voice/rvc/(model\.pth|model\.index)$'
    (($extension -in @('.pth', '.index')) -and -not $allowedProductionVoice) -or
    ($extension -eq '.onnx' -and -not $allowedVisionModel) -or
    ($_.Name -match '(?i)weightsgg|weights\.gg') -or
    ($relative -match '(?i)(^|/)media/voice/rvc/(?!README\.md$|model\.pth$|model\.index$).+') -or
    ($_.Name -match '(?i)rvc.*\.(wav|mp3|html)$')
  } | ForEach-Object {
    $_.FullName.Substring($packageRootPrefix.Length).Replace('\', '/')
  }
)
if ($restrictedVoicePayloads.Count -gt 0) {
  throw "Release package contains restricted RVC/model payloads: $($restrictedVoicePayloads -join ', ')"
}

function Join-PackagePath {
  param([string]$RelativePath)
  $path = Join-Path $packageRootPath ($RelativePath -replace "/", "\")
  if ($env:OS -eq "Windows_NT" -and $path.Length -ge 260 -and -not $path.StartsWith("\\?\")) {
    if ($path.StartsWith("\\")) {
      return "\\?\UNC\$($path.TrimStart('\'))"
    }
    return "\\?\$path"
  }
  return $path
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

function Assert-LocalMarkdownLinks {
  param([string]$RelativePath)

  $documentPath = Join-PackagePath $RelativePath
  $documentDir = Split-Path $documentPath -Parent
  $text = Get-Content -LiteralPath $documentPath -Raw
  foreach ($match in [regex]::Matches($text, '\[[^\]]+\]\(([^)]+)\)')) {
    $target = $match.Groups[1].Value.Trim().Trim('<', '>')
    if (-not $target -or $target -match '^(?:https?://|mailto:|#)' -or $target -match '[<>]') {
      continue
    }
    $pathPart = (($target -split '#', 2)[0] -split '\?', 2)[0]
    if (-not $pathPart) { continue }
    $decoded = [System.Uri]::UnescapeDataString($pathPart)
    $candidate = [System.IO.Path]::GetFullPath((Join-Path $documentDir $decoded))
    if (-not $candidate.StartsWith($packageRootPrefix, [System.StringComparison]::OrdinalIgnoreCase)) {
      throw "$RelativePath contains a local link outside the package: $target"
    }
    if (-not (Test-Path -LiteralPath $candidate)) {
      throw "$RelativePath contains a broken local link: $target"
    }
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

function Assert-Mp3File {
  param(
    [string]$RelativePath,
    [int64]$MinBytes = 50000
  )

  Assert-File $RelativePath $MinBytes
  $path = Join-PackagePath $RelativePath
  $bytes = [System.IO.File]::ReadAllBytes($path)
  $hasId3 = $bytes.Length -ge 3 -and $bytes[0] -eq 0x49 -and $bytes[1] -eq 0x44 -and $bytes[2] -eq 0x33
  $hasFrameSync = $bytes.Length -ge 2 -and $bytes[0] -eq 0xff -and (($bytes[1] -band 0xe0) -eq 0xe0)
  if (-not ($hasId3 -or $hasFrameSync)) {
    throw "Package MP3 has no ID3 tag or MPEG frame sync: $RelativePath"
  }
}

$requiredFiles = @(
  "README.md",
  "AGENTS.md",
  "CONTRIBUTING.md",
  "SECURITY.md",
  "CODE_OF_CONDUCT.md",
  "LICENSE",
  "DEPENDENCIES.md",
  "THIRD_PARTY_NOTICES.md",
  "third_party_licenses/files.json",
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
  "release_assets.json",
  "readiness_report.json",
  "release_manifest.json",
  "voice_source_status.json",
  "docs/ANDROID_COMPANION_SPEC.md",
  "docs/ANDROID_COMPANION_TEST_PLAN.md",
  "docs/ANDROID_PLAY_RELEASE.md",
  "docs/ANDROID_PLAY_POLICY_DECLARATIONS.md",
  "docs/ANDROID_PLAY_PRIVACY_POLICY.md",
  "docs/store-assets/play/icon-512.png",
  "docs/store-assets/play/icon-512.svg",
  "docs/store-assets/play/feature-graphic-1024x500.png",
  "docs/store-assets/play/README.md",
  "docs/BRAIN_MODEL.md",
  "docs/COMPANION_CROSS_PLATFORM_PLAN.md",
  "docs/CONVERSATION_V2_ROADMAP.md",
  "docs/CHARACTER_LOCK.md",
  "docs/CREATING_PERSONAS.md",
  "docs/CUSTOMIZING_THE_FACE.md",
  "docs/DESKTOP_PYTHON_RUNTIME.md",
  "docs/GAP_ANALYSIS.md",
  "docs/JOHNNY_ALIVE_PATHWAY.md",
  "docs/PERSONA_PACKS.md",
  "docs/HARDWARE_SIMULATION.md",
  "docs/HARDWARE_FEATURE_ROADMAP.md",
  "docs/LTR553_CALIBRATION.md",
  "docs/LOCAL_RESEARCH_TOOLING.md",
  "docs/LOCAL_VISION.md",
  "docs/LAN_OTA.md",
  "docs/POWER_BLACKOUT_FORENSICS.md",
  "docs/SPEAKER_AUDIO_RESEARCH.md",
  "docs/VOICE_V2_DIRECTML.md",
  "docs/DEVICE_BRINGUP.md",
  "docs/BRIDGE_PROTOCOL.md",
  "docs/FIRST_DEPLOY_STATUS.md",
  "docs/ARRIVAL_DAY_RUNBOOK.md",
  "docs/stackchan_procedural_runtime_design.pdf",
  "docs/PRIVACY.md",
  "docs/PRODUCTION_READINESS.md",
  "docs/README.md",
  "docs/RELEASE_PROCESS.md",
  "docs/ROLLOUT_CHECKLIST.md",
  "docs/VOICE_PERSONALITY.md",
  "docs/VOICE_SOURCE_PROVENANCE_TEMPLATE.md",
  "bridge/models/LICENSE",
  "data/calibration.yaml",
  "data/expressions.yaml",
  "data/voice_persona.yaml",
  "data/voice_source_provenance.yaml",
  "data/voice_rvc_base.yaml",
  "data/voice_rvc_base_metadata.json",
  "data/persona_index.json",
  "bridge/README.md",
  "bridge/bridge_memory.py",
  "bridge/test_bridge_memory.py",
  "bridge/memory_maintenance.py",
  "bridge/test_memory_maintenance.py",
  "bridge/character_harness.py",
  "bridge/test_character_harness.py",
  "bridge/character_red_team.py",
  "bridge/test_character_red_team.py",
  "bridge/persona_pack.py",
  "bridge/test_persona_pack.py",
  "bridge/reference_bridge.py",
  "bridge/test_reference_bridge.py",
  "bridge/research_broker.py",
  "bridge/test_research_broker.py",
  "bridge/robot_embodiment.py",
  "bridge/test_robot_embodiment.py",
  "bridge/local_facts.py",
  "bridge/test_local_facts.py",
  "bridge/trusted_facts_smoke.py",
  "bridge/test_trusted_facts_smoke.py",
  "bridge/local_runner.py",
  "bridge/test_local_runner.py",
  "bridge/cancellation.py",
  "bridge/cancellable_process.py",
  "bridge/test_cancellable_process.py",
  "bridge/ltr553_calibration.py",
  "bridge/test_ltr553_calibration.py",
  "bridge/ota_channels.py",
  "bridge/test_ota_channels.py",
  "bridge/engine_probe.py",
  "bridge/test_engine_probe.py",
  "bridge/litert_lm_contract_smoke.py",
  "bridge/test_litert_lm_contract_smoke.py",
  "bridge/model_benchmark.py",
  "bridge/test_model_benchmark.py",
  "bridge/stt_normalization.py",
  "bridge/stt_adapter.py",
  "bridge/windows_speech_stt.py",
  "bridge/whisper_cpp_stt.py",
  "bridge/test_stt_adapter.py",
  "bridge/tts_adapter.py",
  "bridge/test_tts_adapter.py",
  "bridge/lan_service.py",
  "bridge/test_lan_service.py",
  "bridge/ollama_stackchan_runner.py",
  "bridge/test_ollama_stackchan_runner.py",
  "bridge/pc_brain_probe.py",
  "bridge/selected_voice_tts.py",
  "bridge/windows_speech_tts.py",
  "bridge/rvc_tts.py",
  "bridge/rvc_tts_client.py",
  "bridge/rvc_worker_service.py",
  "bridge/rvc_directml_tts_client.py",
  "bridge/rvc_directml_worker_service.py",
  "bridge/rvc_production_tts_client.py",
  "bridge/test_rvc_production_tts_client.py",
  "bridge/voice_v2_directml_runtime.py",
  "bridge/voice_v2_directml_benchmark.py",
  "bridge/voice_v2_wire_benchmark.py",
  "bridge/vision_service.py",
  "bridge/test_vision_service.py",
  "bridge/requirements-vision.txt",
  "bridge/models/README.md",
  "bridge/models/face_detection_yunet_2023mar.onnx",
  "bridge/lan_smoke.py",
  "bridge/test_lan_smoke.py",
  "bridge/android_companion_probe.py",
  "bridge/test_android_companion_probe.py",
  "bridge/android_companion_soak.py",
  "bridge/test_android_companion_soak.py",
  "bridge/android_udp_beacon_probe.py",
  "bridge/test_android_udp_beacon_probe.py",
  "bridge/test_android_dashboard_media_gate.py",
  "bridge/hardware_simulator.py",
  "bridge/test_hardware_simulator.py",
  "bridge/prearrival_sim_check.py",
  "bridge/test_prearrival_sim_check.py",
  "provenance/companion/settings.gradle.kts",
  "provenance/companion/build.gradle.kts",
  "provenance/companion/gradle.properties",
  "provenance/companion/gradlew",
  "provenance/companion/gradlew.bat",
  "provenance/companion/gradle/libs.versions.toml",
  "provenance/companion/app-android/build.gradle.kts",
  "provenance/companion/app-android/src/main/AndroidManifest.xml",
  "provenance/companion/app-android/src/main/kotlin/dev/stackchan/companion/android/MainActivity.kt",
  "provenance/companion/app-android/src/main/kotlin/dev/stackchan/companion/android/CompanionBridgeService.kt",
  "provenance/companion/app-android/src/main/kotlin/dev/stackchan/companion/android/AndroidDiagnosticsExport.kt",
  "provenance/companion/app-android/src/main/kotlin/dev/stackchan/companion/android/AndroidBridgeRuntimeStatus.kt",
  "provenance/companion/app-android/src/test/kotlin/dev/stackchan/companion/android/AndroidBridgeRuntimeStatusTest.kt",
  "provenance/companion/core/src/commonMain/kotlin/dev/stackchan/companion/core/ProtocolMessage.kt",
  "provenance/companion/core/src/commonMain/kotlin/dev/stackchan/companion/core/EndpointServer.kt",
  "provenance/companion/ui/src/commonMain/kotlin/dev/stackchan/companion/ui/CompanionConsole.kt",
  "personas/spark/pack.yaml",
  "personas/spark/character.yaml",
  "personas/spark/prompt.md",
  "personas/spark/behavior.yaml",
  "personas/spark/expressions.yaml",
  "personas/spark/earcons.yaml",
  "personas/spark/voice.yaml",
  "personas/glow/pack.yaml",
  "personas/glow/character.yaml",
  "personas/glow/prompt.md",
  "personas/glow/behavior.yaml",
  "personas/glow/expressions.yaml",
  "personas/glow/earcons.yaml",
  "personas/glow/voice.yaml",
  "persona_pack_status.json",
  "persona_prompt_assets.json",
  "character-red-team/CHARACTER_RED_TEAM.md",
  "character-red-team/character_red_team.json",
  "companion/evidence/c6-evidence/EVIDENCE.json",
  "companion/evidence/c6-evidence/EVIDENCE.md",
  "companion/evidence/c6-brain-supervisor/BRAIN_SUPERVISOR_SMOKE.json",
  "companion/evidence/c6-brain-supervisor/BRAIN_SUPERVISOR_SMOKE.md",
  "companion/evidence/c6-brain-supervisor/DIAGNOSTICS_EXPORT.json",
  "companion/evidence/c6-gui-rehearsal/GUI_REHEARSAL.json",
  "companion/evidence/c6-gui-rehearsal/GUI_REHEARSAL.md",
  "companion/evidence/c6-gui-rehearsal/DIAGNOSTICS_EXPORT.json",
  "firmware/display_only/bootloader.bin",
  "firmware/display_only/firmware.bin",
  "firmware/display_only/firmware.elf",
  "firmware/display_only/partitions.bin",
  "firmware/servo_calibration/bootloader.bin",
  "firmware/servo_calibration/firmware.bin",
  "firmware/servo_calibration/firmware.elf",
  "firmware/servo_calibration/partitions.bin",
  "firmware/full_online/bootloader.bin",
  "firmware/full_online/firmware.bin",
  "firmware/full_online/firmware.elf",
  "firmware/full_online/partitions.bin",
  "media/stackchan_alive_expression_sheet.png",
  "media/stackchan_alive_preview.gif",
  "media/stackchan_alive_preview.mp4",
  "media/stackchan_alive_preview.png",
  "media/stackchan_alive_speech_preview.gif",
  "media/diagrams/01-system-overview.png",
  "media/diagrams/02-firmware-task-architecture.png",
  "media/diagrams/03-persona-engine.png",
  "media/diagrams/04-face-runtime.png",
  "media/diagrams/05-motion-servo-safety.png",
  "media/diagrams/06-brain-bridge-protocol.png",
  "media/diagrams/08-io-abstraction-builds.png",
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
  "media/voice/stackchan_spark_audition_bright_robot_greeting.mp3",
  "media/voice/stackchan_spark_thinking.mp3",
  "media/voice/sidecars/stackchan_spark_greeting.speech_envelope.json",
  "media/voice/sidecars/stackchan_spark_thinking.speech_envelope.json",
  "media/voice/sidecars/stackchan_spark_safety.speech_envelope.json",
  "media/voice/VOICE_SAMPLES.md",
  "media/voice/VOICE_AUDITION.html",
  "media/voice/rvc/README.md",
  "tools/flash_device.cmd",
  "tools/flash_device.ps1",
  "tools/provision_stackchan_wifi.cmd",
  "tools/provision_stackchan_wifi.ps1",
  "tools/flash_release_firmware.cmd",
  "tools/flash_release_firmware.ps1",
  "tools/flash_wifi_bridge.cmd",
  "tools/flash_wifi_bridge.ps1",
  "tools/platformio_apply_wifi_bridge_env.py",
  "tools/platformio_apply_ota_env.py",
  "tools/test_platformio_ota_env_contract.py",
  "tools/test_platformio_wifi_env_contract.py",
  "tools/upload_lan_ota.cmd",
  "tools/upload_lan_ota.ps1",
  "tools/test_lan_ota_channel_contract.ps1",
  "tools/body_sensor_validation.ps1",
  "tools/test_body_sensor_validation_contract.ps1",
  "tools/run_full_system_soak_http_motion.ps1",
  "tools/start_warm_rocm_full_system_soak.ps1",
  "tools/start_production_full_system_soak.ps1",
  "tools/check_full_system_soak_evidence.ps1",
  "tools/test_full_system_soak_evidence_contract.ps1",
  "tools/check_current_lead_reproducibility.cmd",
  "tools/check_current_lead_reproducibility.ps1",
  "tools/test_current_lead_reproducibility_contract.cmd",
  "tools/test_current_lead_reproducibility_contract.ps1",
  "tools/archive_current_lead.cmd",
  "tools/archive_current_lead.ps1",
  "tools/test_archive_current_lead_contract.cmd",
  "tools/test_archive_current_lead_contract.ps1",
  "tools/test_start_warm_rocm_full_system_soak_contract.ps1",
  "tools/test_start_production_full_system_soak_contract.ps1",
  "tools/camera_follow_wake_validation.ps1",
  "tools/test_camera_follow_wake_validation_contract.ps1",
  "tools/complete_camera_follow_wake_validation.ps1",
  "tools/test_complete_camera_follow_wake_validation_contract.ps1",
  "tools/prepare_desktop_python_runtime.cmd",
  "tools/prepare_desktop_python_runtime.ps1",
  "tools/check_desktop_python_runtime_payload.cmd",
  "tools/check_desktop_python_runtime_payload.ps1",
  "tools/test_desktop_python_runtime_payload_contract.cmd",
  "tools/test_desktop_python_runtime_payload_contract.ps1",
  "tools/export_desktop_package_evidence.cmd",
  "tools/export_desktop_package_evidence.ps1",
  "tools/test_desktop_package_launch.cmd",
  "tools/test_desktop_package_launch.ps1",
  "tools/test_desktop_package_evidence_contract.cmd",
  "tools/test_desktop_package_evidence_contract.ps1",
  "tools/install_desktop_companion_package.cmd",
  "tools/install_desktop_companion_package.ps1",
  "tools/check_desktop_target_install_evidence.cmd",
  "tools/check_desktop_target_install_evidence.ps1",
  "tools/test_desktop_target_install_evidence_contract.cmd",
  "tools/test_desktop_target_install_evidence_contract.ps1",
  "tools/check_desktop_v1_evidence_bundle.cmd",
  "tools/check_desktop_v1_evidence_bundle.ps1",
  "tools/test_desktop_v1_evidence_bundle_contract.cmd",
  "tools/test_desktop_v1_evidence_bundle_contract.ps1",
  "tools/check_companion_v1_evidence_bundle.cmd",
  "tools/check_companion_v1_evidence_bundle.ps1",
  "tools/test_companion_v1_evidence_bundle_contract.cmd",
  "tools/test_companion_v1_evidence_bundle_contract.ps1",
  "tools/platformio_resolver.ps1",
  "tools/check_native_toolchain.cmd",
  "tools/check_native_toolchain.ps1",
  "tools/check_android_toolchain.cmd",
  "tools/check_android_toolchain.ps1",
  "tools/check_android_play_release_readiness.cmd",
  "tools/check_android_play_release_readiness.ps1",
  "tools/test_android_upload_signing_contract.cmd",
  "tools/test_android_upload_signing_contract.ps1",
  "tools/test_android_emulator_launch.cmd",
  "tools/test_android_emulator_launch.ps1",
  "tools/check_android_emulator_release_evidence.cmd",
  "tools/check_android_emulator_release_evidence.ps1",
  "tools/test_android_emulator_release_evidence_contract.cmd",
  "tools/test_android_emulator_release_evidence_contract.ps1",
  "tools/check_android_play_store_evidence.cmd",
  "tools/check_android_play_store_evidence.ps1",
  "tools/check_android_v1_evidence_bundle.cmd",
  "tools/check_android_v1_evidence_bundle.ps1",
  "tools/check_android_diagnostics_export_evidence.cmd",
  "tools/check_android_diagnostics_export_evidence.ps1",
  "tools/test_android_diagnostics_export_evidence_contract.cmd",
  "tools/test_android_diagnostics_export_evidence_contract.ps1",
  "tools/check_android_speech_evidence.cmd",
  "tools/check_android_speech_evidence.ps1",
  "tools/test_android_speech_evidence_contract.cmd",
  "tools/test_android_speech_evidence_contract.ps1",
  "tools/check_android_controls_evidence.cmd",
  "tools/check_android_controls_evidence.ps1",
  "tools/test_android_controls_evidence_contract.cmd",
  "tools/test_android_controls_evidence_contract.ps1",
  "tools/check_android_pairing_evidence.cmd",
  "tools/check_android_pairing_evidence.ps1",
  "tools/test_android_pairing_evidence_contract.cmd",
  "tools/test_android_pairing_evidence_contract.ps1",
  "tools/check_android_wifi_evidence.cmd",
  "tools/check_android_wifi_evidence.ps1",
  "tools/test_android_wifi_evidence_contract.cmd",
  "tools/test_android_wifi_evidence_contract.ps1",
  "tools/check_voice_source_readiness.ps1",
  "tools/test_voice_source_readiness_contract.ps1",
  "tools/check_android_screen_off_soak_evidence.cmd",
  "tools/check_android_screen_off_soak_evidence.ps1",
  "tools/test_android_screen_off_soak_evidence_contract.cmd",
  "tools/test_android_screen_off_soak_evidence_contract.ps1",
  "tools/check_android_gemma_evidence.cmd",
  "tools/check_android_gemma_evidence.ps1",
  "tools/test_android_gemma_evidence_contract.cmd",
  "tools/test_android_gemma_evidence_contract.ps1",
  "tools/check_companion_v1_readiness.cmd",
  "tools/check_companion_v1_readiness.ps1",
  "tools/export_companion_release_evidence.cmd",
  "tools/export_companion_release_evidence.ps1",
  "tools/preview_python_resolver.ps1",
  "tools/render_preview.py",
  "tools/audit_published_release.cmd",
  "tools/audit_published_release.ps1",
  "tools/publish_release.cmd",
  "tools/publish_release.ps1",
  "tools/export_github_actions_status.cmd",
  "tools/export_github_actions_status.ps1",
  "tools/new_ci_account_block_exception.cmd",
  "tools/new_ci_account_block_exception.ps1",
  "tools/export_voice_source_status.cmd",
  "tools/export_voice_source_status.ps1",
  "tools/setup_voice_tools.cmd",
  "tools/setup_voice_tools.ps1",
  "tools/open_voice_audition.cmd",
  "tools/open_voice_audition.ps1",
  "tools/render_rvc_audition_mp3s.cmd",
  "tools/render_rvc_audition_mp3s.ps1",
  "tools/render_voice_samples.cmd",
  "tools/render_voice_samples.ps1",
  "tools/render_rvc_auditions.ps1",
  "tools/verify_voice_samples.cmd",
  "tools/verify_voice_samples.ps1",
  "tools/verify_rvc_auditions.cmd",
  "tools/verify_rvc_auditions.ps1",
  "tools/verify_tracked_rvc_assets.cmd",
  "tools/verify_tracked_rvc_assets.ps1",
  "tools/sanitize_public_archive.cmd",
  "tools/sanitize_public_archive.ps1",
  "tools/generate_speech_envelope_sidecar.cmd",
  "tools/generate_speech_envelope_sidecar.ps1",
  "tools/generate_speech_envelope_sidecar.py",
  "tools/platformio_generate_persona_assets.py",
  "tools/platformio_generate_voice_assets.py",
  "tools/verify_speech_envelope_sidecar.cmd",
  "tools/verify_speech_envelope_sidecar.ps1",
  "tools/generate_synthetic_hardware_evidence.cmd",
  "tools/generate_synthetic_hardware_evidence.ps1",
  "tools/add_hardware_evidence_media.cmd",
  "tools/add_hardware_evidence_media.ps1",
  "tools/check_hardware_evidence_progress.cmd",
  "tools/check_hardware_evidence_progress.ps1",
  "tools/test_android_apk_install_evidence_contract.cmd",
  "tools/test_android_apk_install_evidence_contract.ps1",
  "tools/test_android_probe_evidence_progress_contract.cmd",
  "tools/test_android_probe_evidence_progress_contract.ps1",
  "tools/test_android_rollout_status_contract.cmd",
  "tools/test_android_rollout_status_contract.ps1",
  "tools/test_android_logcat_capture_contract.cmd",
  "tools/test_android_logcat_capture_contract.ps1",
  "tools/test_android_evidence_packet_contract.cmd",
  "tools/test_android_evidence_packet_contract.ps1",
  "tools/test_strict_android_apk_evidence_contract.cmd",
  "tools/test_strict_android_apk_evidence_contract.ps1",
  "tools/test_strict_android_dashboard_evidence_contract.cmd",
  "tools/test_strict_android_dashboard_evidence_contract.ps1",
  "tools/test_strict_android_probe_evidence_contract.cmd",
  "tools/test_strict_android_probe_evidence_contract.ps1",
  "tools/test_android_play_store_evidence_contract.cmd",
  "tools/test_android_play_store_evidence_contract.ps1",
  "tools/test_android_v1_evidence_bundle_contract.cmd",
  "tools/test_android_v1_evidence_bundle_contract.ps1",
  "tools/test_desktop_v1_evidence_bundle_contract.cmd",
  "tools/test_desktop_v1_evidence_bundle_contract.ps1",
  "tools/test_companion_v1_evidence_bundle_contract.cmd",
  "tools/test_companion_v1_evidence_bundle_contract.ps1",
  "tools/prepare_device_arrival.cmd",
  "tools/prepare_device_arrival.ps1",
  "tools/run_device_preflight.cmd",
  "tools/run_device_preflight.ps1",
  "tools/run_character_harness_tests.cmd",
  "tools/run_character_harness_tests.ps1",
  "tools/run_character_red_team.cmd",
  "tools/run_character_red_team.ps1",
  "tools/create_persona_pack.cmd",
  "tools/create_persona_pack.ps1",
  "tools/create_persona_pack.py",
  "tools/build_persona_index.cmd",
  "tools/build_persona_index.ps1",
  "tools/build_persona_index.py",
  "tools/export_persona_prompt_assets.py",
  "tools/verify_persona_pack.cmd",
  "tools/verify_persona_pack.ps1",
  "tools/verify_persona_pack.py",
  "tools/run_bridge_reference_tests.cmd",
  "tools/run_bridge_reference_tests.ps1",
  "tools/run_engine_probe.cmd",
  "tools/run_engine_probe.ps1",
  "tools/run_litert_lm_smoke.cmd",
  "tools/run_litert_lm_smoke.ps1",
  "tools/run_lan_smoke.cmd",
  "tools/run_lan_smoke.ps1",
  "tools/setup_whisper_cpp.cmd",
  "tools/setup_whisper_cpp.ps1",
  "tools/start_pc_brain.cmd",
  "tools/start_pc_brain.ps1",
  "tools/start_rvc_worker.ps1",
  "tools/setup_voice_v2_directml.ps1",
  "tools/voice_v2_directml_constraints.txt",
  "tools/start_voice_v2_directml_worker.ps1",
  "tools/run_voice_v2_directml_benchmark.ps1",
  "tools/run_voice_v2_wire_benchmark.ps1",
  "tools/start_voice_v2_supervised_validation.ps1",
  "tools/check_voice_v2_supervised_evidence.ps1",
  "tools/complete_voice_v2_supervised_validation.ps1",
  "tools/restore_voice_v2_production.ps1",
  "tools/test_voice_v2_supervised_evidence_contract.ps1",
  "tools/run_pc_brain_probe.cmd",
  "tools/collect_pc_brain_deploy_evidence.cmd",
  "tools/collect_pc_brain_deploy_evidence.ps1",
  "tools/check_pc_brain_deploy_evidence.cmd",
  "tools/check_pc_brain_deploy_evidence.ps1",
  "tools/run_pc_brain_quiet_soak.cmd",
  "tools/run_pc_brain_quiet_soak.ps1",
  "tools/check_pc_brain_quiet_soak_evidence.cmd",
  "tools/check_pc_brain_quiet_soak_evidence.ps1",
  "tools/run_selected_voice_once.cmd",
  "tools/run_selected_voice_once.ps1",
  "tools/run_android_companion_probe.cmd",
  "tools/run_android_companion_probe.ps1",
  "tools/run_android_companion_soak.cmd",
  "tools/run_android_companion_soak.ps1",
  "tools/run_android_udp_beacon_probe.cmd",
  "tools/run_android_udp_beacon_probe.ps1",
  "tools/install_android_companion_apk.cmd",
  "tools/install_android_companion_apk.ps1",
  "tools/capture_android_companion_logcat.cmd",
  "tools/capture_android_companion_logcat.ps1",
  "tools/run_prearrival_sim_check.cmd",
  "tools/run_prearrival_sim_check.ps1",
  "tools/run_hardware_simulation.cmd",
  "tools/run_hardware_simulation.ps1",
  "tools/compare_hardware_sim_baseline.cmd",
  "tools/compare_hardware_sim_baseline.ps1",
  "tools/send_speech_mouth_demo.cmd",
  "tools/send_speech_mouth_demo.ps1",
  "tools/send_speak_all_intents_demo.cmd",
  "tools/send_speak_all_intents_demo.ps1",
  "tools/send_bridge_replay_demo.cmd",
  "tools/send_bridge_replay_demo.ps1",
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
  "tools/test_consumer_promotion_contract.ps1",
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
  "provenance/partitions_esp_sr_16.csv",
  "provenance/src/main.cpp",
  "provenance/src/io/CameraAdapter.hpp",
  "provenance/src/io/CameraAdapter.cpp",
  "provenance/src/io/BridgeClient.hpp",
  "provenance/src/io/BridgeClient.cpp",
  "provenance/src/io/BridgeNetworkSession.hpp",
  "provenance/src/io/BridgeNetworkSession.cpp",
  "provenance/src/io/BridgeSocketWriter.hpp",
  "provenance/src/io/BridgeSocketWriter.cpp",
  "provenance/src/io/BridgeWiFiClientSocket.hpp",
  "provenance/src/io/BridgeWiFiClientSocket.cpp",
  "provenance/src/io/BridgeWiFiProvisioner.hpp",
  "provenance/src/io/BridgeWiFiProvisioner.cpp",
  "provenance/src/io/AudioCaptureAdapter.hpp",
  "provenance/src/io/AudioCaptureAdapter.cpp",
  "provenance/src/io/BridgeAudioDownlink.hpp",
  "provenance/src/io/BridgeAudioDownlink.cpp",
  "provenance/src/io/BridgeAudioUplink.hpp",
  "provenance/src/io/BridgeAudioUplink.cpp",
  "provenance/src/io/BridgeWakeGate.hpp",
  "provenance/src/io/BridgeWakeGate.cpp",
  "provenance/src/persona/SpeechPlanner.hpp",
  "provenance/src/persona/SpeechPlanner.cpp",
  "provenance/src/persona/EarconSynth.hpp",
  "provenance/src/persona/EarconSynth.cpp",
  "provenance/src/io/AudioOut.hpp",
  "provenance/src/io/AudioOut.cpp",
  "provenance/src/io/SpeechPromptBank.hpp",
  "provenance/src/io/SpeechPromptBank.cpp",
  "provenance/src/io/SpeechAdapter.hpp",
  "provenance/src/io/SpeechAdapter.cpp",
  "provenance/release.yml",
  "provenance/requirements-preview.txt",
  "provenance/bridge/README.md",
  "provenance/bridge/export_protocol_fixtures.py",
  "provenance/bridge/test_protocol_fixtures.py",
  "provenance/bridge/character_red_team.py",
  "provenance/bridge/test_character_red_team.py",
  "provenance/bridge/persona_pack.py",
  "provenance/bridge/test_persona_pack.py",
  "provenance/bridge/reference_bridge.py",
  "provenance/bridge/test_reference_bridge.py",
  "provenance/bridge/local_facts.py",
  "provenance/bridge/test_local_facts.py",
  "provenance/bridge/trusted_facts_smoke.py",
  "provenance/bridge/test_trusted_facts_smoke.py",
  "provenance/bridge/local_runner.py",
  "provenance/bridge/test_local_runner.py",
  "provenance/bridge/engine_probe.py",
  "provenance/bridge/test_engine_probe.py",
  "provenance/bridge/litert_lm_contract_smoke.py",
  "provenance/bridge/test_litert_lm_contract_smoke.py",
  "provenance/protocol-fixtures/endpoint_hello.json",
  "provenance/protocol-fixtures/owner_status.json",
  "provenance/protocol-fixtures/settings_get.json",
  "provenance/protocol-fixtures/settings_set.json",
  "provenance/protocol-fixtures/invalid/missing_type.json",
  "provenance/protocol-fixtures/invalid/wrong_protocol.json",
  "provenance/bridge/model_benchmark.py",
  "provenance/bridge/test_model_benchmark.py",
  "provenance/bridge/stt_normalization.py",
  "provenance/bridge/stt_adapter.py",
  "provenance/bridge/windows_speech_stt.py",
  "provenance/bridge/whisper_cpp_stt.py",
  "provenance/bridge/test_stt_adapter.py",
  "provenance/bridge/tts_adapter.py",
  "provenance/bridge/test_tts_adapter.py",
  "provenance/bridge/lan_service.py",
  "provenance/bridge/test_lan_service.py",
  "provenance/bridge/ollama_stackchan_runner.py",
  "provenance/bridge/test_ollama_stackchan_runner.py",
  "provenance/bridge/windows_speech_tts.py",
  "provenance/bridge/rvc_tts.py",
  "provenance/bridge/rvc_tts_client.py",
  "provenance/bridge/rvc_worker_service.py",
  "provenance/bridge/rvc_directml_tts_client.py",
  "provenance/bridge/rvc_directml_worker_service.py",
  "provenance/bridge/voice_v2_directml_runtime.py",
  "provenance/bridge/voice_v2_directml_benchmark.py",
  "provenance/bridge/voice_v2_wire_benchmark.py",
  "provenance/bridge/lan_smoke.py",
  "provenance/bridge/test_lan_smoke.py",
  "provenance/bridge/android_companion_probe.py",
  "provenance/bridge/test_android_companion_probe.py",
  "provenance/bridge/android_companion_soak.py",
  "provenance/bridge/test_android_companion_soak.py",
  "provenance/bridge/android_udp_beacon_probe.py",
  "provenance/bridge/test_android_udp_beacon_probe.py",
  "provenance/bridge/test_android_dashboard_media_gate.py",
  "provenance/bridge/hardware_simulator.py",
  "provenance/bridge/test_hardware_simulator.py",
  "provenance/bridge/prearrival_sim_check.py",
  "provenance/bridge/test_prearrival_sim_check.py",
  "provenance/personas/spark/pack.yaml",
  "provenance/personas/spark/character.yaml",
  "provenance/personas/spark/prompt.md",
  "provenance/personas/spark/behavior.yaml",
  "provenance/personas/spark/expressions.yaml",
  "provenance/personas/spark/earcons.yaml",
  "provenance/personas/spark/voice.yaml",
  "provenance/personas/glow/pack.yaml",
  "provenance/personas/glow/character.yaml",
  "provenance/personas/glow/prompt.md",
  "provenance/personas/glow/behavior.yaml",
  "provenance/personas/glow/expressions.yaml",
  "provenance/personas/glow/earcons.yaml",
  "provenance/personas/glow/voice.yaml"
)

foreach ($file in $requiredFiles) {
  Assert-File $file
}

$projectLicenseText = Get-Content -LiteralPath (Join-PackagePath "LICENSE") -Raw
foreach ($pattern in @(
    "Apache License",
    "Version 2.0, January 2004",
    "TERMS AND CONDITIONS FOR USE, REPRODUCTION, AND DISTRIBUTION",
    "Grant of Patent License",
    "END OF TERMS AND CONDITIONS"
  )) {
  if ($projectLicenseText -notmatch [regex]::Escape($pattern)) {
    throw "Project LICENSE is not the expected Apache-2.0 text: missing $pattern"
  }
}

foreach ($document in @("README.md", "AGENTS.md", "CONTRIBUTING.md", "SECURITY.md", "CODE_OF_CONDUCT.md", "docs/README.md", "docs/CONVERSATION_V2_ROADMAP.md")) {
  Assert-LocalMarkdownLinks $document
}

$contributorGuideText = Get-Content -LiteralPath (Join-PackagePath "CONTRIBUTING.md") -Raw
foreach ($pattern in @("physical hardware", "Private Material", "Bring-your-own-model", "Exact firmware SHA-256", "Apache License 2.0")) {
  if ($contributorGuideText -notmatch [regex]::Escape($pattern)) {
    throw "CONTRIBUTING.md missing release-safety guidance: $pattern"
  }
}

$securityPolicyText = Get-Content -LiteralPath (Join-PackagePath "SECURITY.md") -Raw
foreach ($pattern in @("private vulnerability reporting", "latest published prerelease", "unexpected motion", "rotate or revoke", "Git history")) {
  if ($securityPolicyText -notmatch [regex]::Escape($pattern)) {
    throw "SECURITY.md missing vulnerability-response guidance: $pattern"
  }
}

$codeOfConductText = Get-Content -LiteralPath (Join-PackagePath "CODE_OF_CONDUCT.md") -Raw
foreach ($pattern in @("Expected Behavior", "Unacceptable Behavior", "private information", "unsafe actuator", "Reporting And Enforcement")) {
  if ($codeOfConductText -notmatch [regex]::Escape($pattern)) {
    throw "CODE_OF_CONDUCT.md missing community-safety guidance: $pattern"
  }
}

$visionModelRelativePath = "bridge/models/face_detection_yunet_2023mar.onnx"
$visionModelPath = Join-PackagePath $visionModelRelativePath
$visionModel = Get-Item -LiteralPath $visionModelPath
if ($visionModel.Length -ne 232589) {
  throw "Unexpected YuNet model size: $($visionModel.Length) bytes"
}
$visionModelSha256 = (Get-FileHash -Algorithm SHA256 -LiteralPath $visionModelPath).Hash.ToLowerInvariant()
if ($visionModelSha256 -ne "8f2383e4dd3cfbb4553ea8718107fc0423210dc964f9f4280604804ed2552fa4") {
  throw "Unexpected YuNet model SHA-256: $visionModelSha256"
}

$quickstartText = Get-Content -LiteralPath (Join-PackagePath "QUICKSTART.md") -Raw
foreach ($pattern in @("share_release.cmd", "verify_share_release.cmd", "DownloadCloudflared", "-Lan", "same-network URL", "stop_share.cmd -All", "PUBLIC_URL.txt", "VERIFIED_URL.txt", "STOP_SHARING.cmd", "run_engine_probe.cmd", "RunModelSmoke", "RunModelBenchmark", "run_character_red_team.cmd", "-RequireRunner", "run_litert_lm_smoke.cmd", "LITERT_LM_SMOKE.md/json", "run_prearrival_sim_check.cmd", "PREARRIVAL_SIM_CHECK.md/json", "check_companion_v1_readiness.cmd", "source-ready-pending-hardware", "protocol fixture", "export_companion_release_evidence.cmd", "COMPANION_RELEASE_EVIDENCE.json", "-RequireArtifacts", "model-benchmark/MODEL_BENCHMARK.md/json", "prepare_device_arrival.cmd", "-Operator", "-DeviceId", "-ShareRoot", "NEXT_STEPS.md", "HOSTED_MEDIA_REFERENCE.md", "RUN_DISPLAY_ONLY.cmd", "RUN_SPEECH_MOUTH_DEMO.cmd", "RUN_SPEAK_ALL_INTENTS.cmd", "RUN_SERVO_CALIBRATION.cmd", "RUN_ANDROID_APK_INSTALL.cmd", "-SourceCommit <git-commit>", "check_android_toolchain.cmd", "SDK Platform 36", "cd companion", ".\gradlew.bat :app-android:assembleRelease", "companion\app-android\build\outputs\apk\release\app-android-release.apk", "android\apk-install\", "RUN_ANDROID_COMPANION_PROBE.cmd", "RUN_ANDROID_SCREEN_OFF_SOAK.cmd", "android\screen-off-soak\", "RUN_ANDROID_UDP_BEACON_PROBE.cmd", "RUN_ANDROID_LOGCAT_CAPTURE.cmd", "android/logcat/", "Android dashboard connected state", "foreground service state", "RUN_ADD_MEDIA.cmd -Type Photo -Notes", "Android dashboard connected state; robot identity; firmware/version signal; last bridge frame; active brain owner; foreground service state", "RUN_PROGRESS_CHECK.cmd", "RUN_ROLLOUT_STATUS.cmd", "ROLLOUT_STATUS.md", "RUN_ADD_MEDIA.cmd", "RUN_PLAY_LEAD_VOICE.cmd", "RVC_LEAD_AUDITION.md", "reference_audio\", "RVC Bright Robot", "AUDIO_REVIEW.md", "real-device speaker recording", "audio\", "generated source WAVs alone do not count", "-ConfirmServoRisk", "Hardware validation is still required")) {
  if ($quickstartText -notmatch [regex]::Escape($pattern)) {
    throw "QUICKSTART.md missing required guidance: $pattern"
  }
}

$arrivalRunbookText = Get-Content -LiteralPath (Join-PackagePath "ARRIVAL_DAY_RUNBOOK.md") -Raw
foreach ($pattern in @("Stackchan Arrival-Day Runbook", "NEXT_STEPS.md", "RUN_PACKAGE_VERIFY.cmd", "RUN_DISPLAY_ONLY.cmd", "RUN_SPEECH_MOUTH_DEMO.cmd", "RUN_SPEAK_ALL_INTENTS.cmd", "RUN_SERVO_CALIBRATION.cmd", "RUN_SOAK_MONITOR.cmd", "RUN_PLAY_LEAD_VOICE.cmd", "RVC_LEAD_AUDITION.md", "reference_audio/", "HOSTED_MEDIA_REFERENCE.md", "verified local or Cloudflare share page", "share\VERIFIED_URL.txt", "pitch 2, index 0.62, RMS mix 0.72, and protect 0.28", "check_android_toolchain.cmd", "SDK Platform 36", "cd companion; .\gradlew.bat :app-android:assembleRelease", "companion\app-android\build\outputs\apk\release\app-android-release.apk", "RUN_ANDROID_APK_INSTALL.cmd -ApkPath <path-to-apk> -SourceCommit <git-commit>", "source commit", "android/apk-install/", "RUN_ANDROID_COMPANION_PROBE.cmd -Url ws://<phone-lan-ip>:8765/bridge", "android/companion-probe/", "RUN_ANDROID_SCREEN_OFF_SOAK.cmd -Url ws://<phone-lan-ip>:8765/bridge", "android/screen-off-soak/", "RUN_ANDROID_UDP_BEACON_PROBE.cmd", "android/udp-beacon-probe/", "RUN_ANDROID_LOGCAT_CAPTURE.cmd", "android/logcat/", "Android dashboard connected state", "robot identity", "firmware/version signal", "last bridge frame", "active brain owner", "foreground service state", "RUN_PROGRESS_CHECK.cmd", "RUN_ROLLOUT_STATUS.cmd", "ROLLOUT_STATUS.json", "RUN_EVIDENCE_VERIFY.cmd", "RUN_CONSUMER_PROMOTION_CHECK.cmd", "Hard stop if", "send", "status", "[heartbeat]", "[system]", "verified production voice hashes", "GitHub Actions")) {
  if ($arrivalRunbookText -notmatch [regex]::Escape($pattern)) {
    throw "ARRIVAL_DAY_RUNBOOK.md missing required bench guidance: $pattern"
  }
}

$deviceBringupText = Get-Content -LiteralPath (Join-PackagePath "docs/DEVICE_BRINGUP.md") -Raw
foreach ($pattern in @("status", "telemetry", "health", "[heartbeat]", "[system]", "[runtime]", "motion_enabled", "demo_enabled", "speech_active", "camera_ready", "camera_hw", "camera_active", "camera_events", "speech_adapter_ready", "speech_adapter_hw", "speech_cues", "speech_earcons", "audio_out_ready", "audio_out_hw", "audio_out_hw_ready", "audio_out_core0", "audio_out_requests", "audio_out_playing", "audio_out_frames", "audio_out_ducks", "audio_out_hw_frames", "audio_out_hw_drops", "bridge_ready", "bridge_state", "bridge_messages", "bridge_outputs", "bridge_parse_errors", "bridge_uplink_ready", "bridge_uplink_enabled", "bridge_uplink_gate_blocks", "bridge_timeouts", "[bridge]", "[bridge_uplink]", "[speech_audio]", "source=packaged_prompt", "prompt_id", "prompt_wav", "prompt_sidecar", "[audio_out]", "duck_on_barge_in", "sidecar_frames", "sidecar_frame_ms", "playback_ms", "hw_ready", "hw_playing", "hw_starts", "media/voice/sidecars", "earcon_samples", "earcon_peak", "earcon_checksum", "speak <boot|idle|attend", "RUN_SPEAK_ALL_INTENTS.cmd", "speak_all_intents_serial.log", "RUN_ANDROID_APK_INSTALL.cmd", "check_android_toolchain.cmd", "SDK Platform 36", "cd companion", ".\gradlew.bat :app-android:assembleRelease", "companion\app-android\build\outputs\apk\release\app-android-release.apk", "android/apk-install/", "RUN_ANDROID_COMPANION_PROBE.cmd -Url ws://<phone-lan-ip>:8765/bridge", "android/companion-probe/", "RUN_ANDROID_SCREEN_OFF_SOAK.cmd -Url ws://<phone-lan-ip>:8765/bridge", "android/screen-off-soak/", "RUN_ANDROID_UDP_BEACON_PROBE.cmd", "android/udp-beacon-probe/", "RUN_ANDROID_LOGCAT_CAPTURE.cmd", "android/logcat/", "Android dashboard connected state", "robot identity", "firmware/version signal", "last bridge frame", "active brain owner", "foreground service state", "help", "speech clear", "bridge hello", "bridge response", "bridge audio", "bridge end", "uplink start", "uplink chunk", "uplink end", "uplink abort", "touch cheek", "touch forehead", "proximity 0.85", "pickup 0.80", "shake 1.0", "putdown", "tilt x=0.40 y=-0.20 z=0.90", "sound dir=-45 level=0.70", "noise level=0.90", "[audio] event=", "latency_ms", "azimuth_deg", "payload_x", "payload_y", "payload_z", "ambient 12 22", "ambient lux 700 hour 10", "time 22", "circadian hour 7", "ambient_lux", "circadian_hour", "reduced on", "motion stop", "motion resume", "demo off", "demo on", "safe stop", "panic", "safe resume", "restore", "[motion] enabled=0")) {
  if ($deviceBringupText -notmatch [regex]::Escape($pattern)) {
    throw "docs/DEVICE_BRINGUP.md missing required serial bench guidance: $pattern"
  }
}

$shareGeneratorText = Get-Content -LiteralPath (Join-PackagePath "tools/share_release.ps1") -Raw
$retiredRvcSharePatterns = @(
  "stackchan_rvc_neutral.wav", "stackchan_rvc_bright_robot.wav",
  "stackchan_rvc_bright_robot_less_static.wav", "RVC_AUDITIONS.md",
  "RVC Voice Auditions", "RVC MP3 Readme", "RVC_AUDITION.html",
  "stackchan_rvc_bright_robot.mp3", "stackchan_rvc_thinking_neutral.mp3",
  "stackchan_rvc_safety_neutral.mp3", "Voice Source Gate",
  "RVC Candidate Base", "candidate-pending-rights-review"
)
foreach ($pattern in @(".zip.sha256", "Get-FileHash", "ZIP SHA256", "Wait-LocalUrlReady", "PublicUrlReadyWaitSeconds", "Wait-PublicUrlReady", "Find-CloudflarePublicUrl", "publicUrlReady", "Stop-ExistingShare", "Remove-ShareRoot", "Test-TcpPortAvailable", "Test-SharePortAvailable", "Find-AvailableTcpPort", "Requested share port", "Get-LanShareUrls", "Get-ShareLanDiagnosticsForBind", "Test-ShareUrlsFromHost", "OPEN_LOCAL_SHARE.cmd", "Write-OpenLocalShareHelper", "OpenLocal", "Invoke-OpenLocalShare", "openLocalRequested", "LAN_TROUBLESHOOTING.md", "share_probe_report.json", "stackchan.share-probe-report.v1", "hostProbeResults", "Assert-BindAddressAvailable", "Same-network URL candidates", "loopbackUrl", "lanUrls", "ROLLOUT_STATUS.md", "ROLLOUT_STATUS.json", "Next Action", "rolloutNextAction", "rolloutNextCommand", "ActionsStatusPath", "Pending Promotion Gates", "promotionGateItems", "hardwareGates", "requiredEvidence", "Do not mark this release consumer-ready", "Face Phase A", "phase_a_idle_10s.gif", "phase_a_blink_filmstrip_50ms.png", "phase_a_unlabeled_expression_sheet.png", "Face Phase B", "phase_b_unlabeled_expression_sheet.png", "procedural eye-corner cuts", "two-curve open mouth", "authored L0 pose keys", "Face Phase C", "phase_c_idle_10s.gif", "autonomic blink", "saccade jumps", "breathing offset", "Face Phase D", "phase_d_idle_to_listen_filmstrip_50ms.png", "phase_d_think_to_speak_filmstrip_50ms.png", "phase_d_idle_to_sleep_filmstrip_50ms.png", "transition choreography", "anticipation", "channel lag", "Face Phase E", "phase_e_speech_reactive_6s.gif", "speech envelope sidecar", "viseme-lite", "tools/verify_face_phase_e.ps1", "Arrival-Day Evidence Loop", "RUN_SPEECH_MOUTH_DEMO.cmd", "RUN_SPEAK_ALL_INTENTS.cmd", "speak_all_intents_serial.log", "speech envelope mouth demo", "RUN_PROGRESS_CHECK.cmd", "RUN_EVIDENCE_VERIFY.cmd", "RUN_CONSUMER_PROMOTION_CHECK.cmd", "Hardware Audio Evidence", "AUDIO_REVIEW.md", "real-device speaker sample", "Generated source WAVs alone do not count", "Dependency Provenance", "dependency_lock.json", "Voice Source Gate", "VOICE_SOURCE_PROVENANCE_TEMPLATE.md", "voice_source_provenance.yaml", "RVC Candidate Base", "voice_rvc_base.yaml", "candidate-pending-rights-review", "tools/verify_rvc_voice_base.ps1", "RVC Voice Auditions", "stackchan_rvc_neutral.wav", "stackchan_rvc_bright_robot.wav", "stackchan_rvc_bright_robot_less_static.wav", "voice/rvc/README.md", "RVC MP3 Readme", "RVC_AUDITION.html", "RVC_AUDITIONS.md", "stackchan_rvc_bright_robot.mp3", "stackchan_rvc_thinking_neutral.mp3", "stackchan_rvc_safety_neutral.mp3")) {
  if ($retiredRvcSharePatterns -contains $pattern) { continue }
  if ($shareGeneratorText -notmatch [regex]::Escape($pattern)) {
    throw "tools/share_release.ps1 missing required share generation logic: $pattern"
  }
}
foreach ($pattern in @("Production RVC Voice", "model.pth", "model.index", "production-release-verified")) {
  if ($shareGeneratorText -notmatch [regex]::Escape($pattern)) {
    throw "tools/share_release.ps1 missing production RVC marker: $pattern"
  }
}

$shareVerifierText = Get-Content -LiteralPath (Join-PackagePath "tools/verify_share_release.ps1") -Raw
$retiredRvcShareVerifierPatterns = @(
  "voice/rvc/RVC_AUDITION.html", "voice/rvc/stackchan_rvc_bright_robot.mp3",
  "voice/rvc/stackchan_rvc_thinking_neutral.mp3", "voice/rvc/stackchan_rvc_safety_neutral.mp3"
)
foreach ($pattern in @("SHA256SUMS.txt", ".zip.sha256", "ZIP SHA256 sidecar", "Invoke-UrlProbe", "Assert-HttpOk", "ProbeRetries", "ProbeDelaySeconds", "share_verification_report.json", "share_static_verification_report.json", "stackchan.share-verification.v1", "verificationMode", "offline-static", "allStaticFilesPresent", "usedCurlResolveFallback", "bindAddress", "loopbackUrl", "lanUrls", "OPEN_LOCAL_SHARE.cmd", "openLocalShare", "openLocalRequested", "LAN_TROUBLESHOOTING.md", "share_probe_report.json", "stackchan.share-probe-report.v1", "lanDiagnostics", "hostProbeResults", "ROLLOUT_STATUS.md", "ROLLOUT_STATUS.json", "Next Action", "Next owner:", "Pending Promotion Gates", "speech-mouth-demo-evidence", "power-cycle-recovery", "USB power-cycle observation marked pass", "target-speaker-audio-evidence", "RUN_SPEECH_MOUTH_DEMO.cmd", "speech envelope mouth demo", "Face Phase A", "phase_a_idle_10s.gif", "Face Phase B", "phase_b_unlabeled_expression_sheet.png", "Face Phase C", "phase_c_idle_10s.gif", "Face Phase D", "phase_d_idle_to_listen_filmstrip_50ms.png", "phase_d_think_to_speak_filmstrip_50ms.png", "phase_d_idle_to_sleep_filmstrip_50ms.png", "Face Phase E", "phase_e_speech_reactive_6s.gif", "Hardware Audio Evidence", "AUDIO_REVIEW.md", "Speaker audio evidence", "voice/rvc/README.md", "voice/rvc/RVC_AUDITION.html", "voice/rvc/stackchan_rvc_bright_robot.mp3", "voice/rvc/stackchan_rvc_thinking_neutral.mp3", "voice/rvc/stackchan_rvc_safety_neutral.mp3")) {
  if ($retiredRvcShareVerifierPatterns -contains $pattern) { continue }
  if ($shareVerifierText -notmatch [regex]::Escape($pattern)) {
    throw "tools/verify_share_release.ps1 missing required remote verification logic: $pattern"
  }
}

$shareStopText = Get-Content -LiteralPath (Join-PackagePath "tools/stop_share.ps1") -Raw
foreach ($pattern in @("-All", "output/share", "Test-ShareOwnedProcess", "skippedProcessIds", "stillRunningProcessIds", "processIds", "Stop-Process", "Unable to stop share processes")) {
  if ($shareStopText -notmatch [regex]::Escape($pattern)) {
    throw "tools/stop_share.ps1 missing robust share cleanup logic: $pattern"
  }
}

$hardwareStarterText = Get-Content -LiteralPath (Join-PackagePath "tools/start_hardware_evidence.ps1") -Raw
foreach ($pattern in @("NEXT_STEPS.md", "Stackchan Evidence Next Steps", "Run Order", "Gates Still Expected", "Hard Stops", "BENCH_STATUS.md", "BENCH_STATUS.json", "stackchan.bench-status.v1", "benchStatus", "RELEASE_ACCEPTANCE.md", "release_acceptance.json", "AUDIO_REVIEW.md", "Stackchan Audio Review", "Speaker recording file", "Intelligible through device speaker", "CI_ACCOUNT_BLOCK_EXCEPTION_TEMPLATE.json", "stackchan.ci-account-block-exception.v1", "starts unapproved", "false proof booleans", "TBD - accountable approver required", "TBD - CI account owner", "Copy-AcceptanceArtifactsFromZip", "Copy-AcceptanceArtifactsFromRoot", "Copy-VoiceLeadArtifactsFromZip", "Copy-ShareVerificationArtifactsFromRoot", "Write-EvidenceChecklist", "Set-ChecklistItemState", "Pre-marked no-hardware gates were proven", "GitHub Actions, production voice-source, media, audio, and promotion gates still require explicit evidence", "shareVerification", "HOSTED_MEDIA_REFERENCE.md", "share/share_verification_report.json", "share/VERIFIED_URL.txt", "verifiedUrl", "verifiedUrlFile", "urlKind", "voiceLeadAudition", "RVC_LEAD_AUDITION.md", "reference_audio", "RUN_PLAY_LEAD_VOICE.cmd", "RUN_HARDWARE_SIM_BASELINE.cmd", "hardware_simulation_baseline.log", "simulation/hardware-sim/latest", "comparison baseline only", "run_hardware_simulation.ps1", "RUN_SIM_HARDWARE_COMPARE.cmd", "compare_hardware_sim_baseline.ps1", "SIM_HARDWARE_COMPARE.md", "SIM_HARDWARE_COMPARE.json", "advisory sim-vs-real", "compareCommand", "compareReport", "RUN_ANDROID_APK_INSTALL.cmd", "install_android_companion_apk.ps1", "android/apk-install", "apkInstallCommand", "android_apk_install.json", "RUN_ANDROID_COMPANION_PROBE.cmd", "run_android_companion_probe.ps1", "android/companion-probe", "RUN_ANDROID_SCREEN_OFF_SOAK.cmd", "run_android_companion_soak.ps1", "android/screen-off-soak", "screenOffSoakCommand", "android_companion_soak.json", "RUN_ANDROID_UDP_BEACON_PROBE.cmd", "run_android_udp_beacon_probe.ps1", "android/udp-beacon-probe", "RUN_ANDROID_LOGCAT_CAPTURE.cmd", "capture_android_companion_logcat.ps1", "android/logcat", "logcatCommand", "android_companion_logcat.json", "Android dashboard connected state", "robot identity", "firmware/version signal", "last bridge frame", "active brain owner", "foreground service state", "androidCompanionProbes", "RUN_SPEECH_MOUTH_DEMO.cmd", "RUN_SPEAK_ALL_INTENTS.cmd", "speak_all_intents_serial.log", "send_speak_all_intents_demo.ps1", "speech_mouth_demo_serial.log", "speechDir", "lead_voice.speech_envelope.json", "generate_speech_envelope_sidecar.ps1", "verify_speech_envelope_sidecar.ps1", "leadAudition", "leadSourcePath", "RUN_ADD_MEDIA.cmd", "add_hardware_evidence_media.ps1", "media_manifest.json", "RUN_PROGRESS_CHECK.cmd", "check_hardware_evidence_progress.ps1", "RUN_ROLLOUT_STATUS.cmd", "export_rollout_status.ps1", "ROLLOUT_STATUS.md", "RUN_CONSUMER_PROMOTION_CHECK.cmd", "verify_consumer_promotion.ps1", "CompanionV1EvidenceRoot", "companion-v1-evidence-ready", "companionV1EvidenceRoot", "New-PowerShellCommandFile", "`$global:LASTEXITCODE", "exit /b %ERRORLEVEL%")) {
  if ($hardwareStarterText -notmatch [regex]::Escape($pattern)) {
    throw "tools/start_hardware_evidence.ps1 missing acceptance artifact capture logic: $pattern"
  }
}

$androidEvidencePacketContractText = Get-Content -LiteralPath (Join-PackagePath "tools/test_android_evidence_packet_contract.ps1") -Raw
foreach ($pattern in @("CompanionV1EvidenceRoot", "consumerPromotionPackageArg", "companion-v1-evidence-ready", "companionV1EvidenceRoot", "Consumer promotion requires the exact release ZIP", "Android evidence packet contract tests passed")) {
  if ($androidEvidencePacketContractText -notmatch [regex]::Escape($pattern)) {
    throw "tools/test_android_evidence_packet_contract.ps1 missing promotion command generator coverage: $pattern"
  }
}

$hardwareMediaImporterText = Get-Content -LiteralPath (Join-PackagePath "tools/add_hardware_evidence_media.ps1") -Raw
foreach ($pattern in @("stackchan.hardware-media-manifest.v1", "Test-PhotoEvidenceFile", "Test-AudioEvidenceFile", "media_manifest.json", "SHA256", "photos", "audio")) {
  if ($hardwareMediaImporterText -notmatch [regex]::Escape($pattern)) {
    throw "tools/add_hardware_evidence_media.ps1 missing media import or validation logic: $pattern"
  }
}

$syntheticEvidenceGeneratorText = Get-Content -LiteralPath (Join-PackagePath "tools/generate_synthetic_hardware_evidence.ps1") -Raw
foreach ($pattern in @("diagnosticOnly", "syntheticEvidence", "AllowSyntheticEvidence", "Synthetic hardware evidence packet", "BENCH_STATUS.md", "BENCH_STATUS.json", "stackchan.bench-status.v1", "benchStatus", "progress_check.log", "NEXT_STEPS.md", "Stackchan Evidence Next Steps", "Copy-VoiceLeadArtifactsFromZip", "Copy-VoiceGateStatusFromZip", "VOICE_SOURCE_STATUS.md", "voice_source_status.json", "RVC_VOICE_BASE_STATUS.md", "rvc_voice_base_status.json", "voiceGateStatus", "export_rollout_status.ps1", "RUN_ROLLOUT_STATUS.cmd", "ROLLOUT_STATUS.md", "RVC_LEAD_AUDITION.md", "RUN_PLAY_LEAD_VOICE.cmd", "RUN_SPEAK_ALL_INTENTS.cmd", "AUDIO_REVIEW.md", "synthetic_speaker_fixture.wav", "must not be used as rollout evidence", "-AllowExternalAccountCiBlock", "completed only in a real evidence packet", "Get-CompactEvidenceTag", "fps_window=30.0", "frame_budget_us=33333", "slow_frames=0", "blink_count=3", "saccade_count=4", "speech_env=0.00", "speech_mouth_demo_serial.log", "Speech mouth demo complete", "speak_all_intents_serial.log", "Speak-all-intents demo complete", "command=speak_intent", "[audio_out]", "command=speech_env", "[control] command=", "button_a_listen", "reduced_motion_on", "safe_stop", "[face] reduced_motion=1", "[speech] seq=", "earcon_delay_ms", "heap_free=243000", "stack_face_hwm=2800")) {
  if ($syntheticEvidenceGeneratorText -notmatch [regex]::Escape($pattern)) {
    throw "tools/generate_synthetic_hardware_evidence.ps1 missing synthetic evidence safety logic: $pattern"
  }
}

$hardwareProgressText = Get-Content -LiteralPath (Join-PackagePath "tools/check_hardware_evidence_progress.ps1") -Raw
foreach ($pattern in @("NEXT_STEPS.md", "Generated source WAVs alone do not count", "OBSERVATIONS.md has blank field", "AUDIO_REVIEW.md has blank field", "No real-device speaker recording found under audio/", "CHECKLIST.md still has unchecked gates", "No photo or video evidence found", "display-only boot marker", "logs/display_only_serial\.log.*display frame-budget telemetry", "display face animator telemetry", "display bench control telemetry", "display speech cue telemetry", "display runtime health telemetry", "speech mouth demo envelope commands", "speech mouth demo clear command", "speech mouth demo completion", "speechMouthFinding", "speakAllFinding", "RUN_SPEECH_MOUTH_DEMO.cmd", "RUN_SPEAK_ALL_INTENTS.cmd", "speak_all_intents_serial.log", "speak-all packaged prompt audio-output handoff", "soak display frame-budget telemetry", "soak face animator telemetry", "soak runtime health telemetry", "reduced_motion_on|reduced_motion_off|safe_stop", "RVC lead audition reference hash matches metadata", "metadata.json has no shareVerification reference", "Hosted media share verification report matches metadata", "VERIFIED_URL.txt", "metadata.json missing voiceGateStatus reference", "Voice source status report matches metadata", "RVC voice base status report matches metadata", "Test-OptionalAndroidProbeReport", "apkSha256", "valid apkSha256", "sourceCommit", "full sourceCommit SHA", "versionName/versionCode", "-SourceCommit <git-commit>", "Test-AndroidDashboardManifestEvidence", "androidDashboardFinding", "Import the Android connected-dashboard screenshot", "Android APK install evidence", "Android companion bridge probe", "Android screen-off soak", "Android UDP beacon probe", "stackchan.android-apk-install.v1", "stackchan.android-companion-probe.v1", "stackchan.android-companion-soak.v1", "stackchan.android-udp-beacon-probe.v1", "optional unless Android is the companion bridge host", "media_manifest.json needs a photo/video entry", "Android dashboard connected state; robot identity; firmware/version signal; last bridge frame; active brain owner; foreground service state", "BENCH_STATUS.md", "BENCH_STATUS.json", "stackchan.bench-status.v1", "Get-BenchNextAction", "Write-BenchStatusReport", "nextAction", "nextCommand", "ready-for-strict-evidence-verify", "RUN_PLAY_LEAD_VOICE.cmd", "RUN_EVIDENCE_VERIFY.cmd")) {
  if ($hardwareProgressText -notmatch [regex]::Escape($pattern)) {
    throw "tools/check_hardware_evidence_progress.ps1 missing evidence progress check: $pattern"
  }
}

$androidApkInstallEvidenceContractText = Get-Content -LiteralPath (Join-PackagePath "tools/test_android_apk_install_evidence_contract.ps1") -Raw
foreach ($pattern in @("check_hardware_evidence_progress.ps1", "stackchan.android-apk-install.v1", "BENCH_STATUS.json", "missing a valid apkSha256", "missing a full sourceCommit SHA", "missing installed versionName/versionCode", "Android APK install evidence report status: installed", "Assert-ReportLacksFinding", "Android APK install evidence contract tests passed")) {
  if ($androidApkInstallEvidenceContractText -notmatch [regex]::Escape($pattern)) {
    throw "tools/test_android_apk_install_evidence_contract.ps1 missing APK install evidence coverage: $pattern"
  }
}

$androidProbeEvidenceProgressContractText = Get-Content -LiteralPath (Join-PackagePath "tools/test_android_probe_evidence_progress_contract.ps1") -Raw
foreach ($pattern in @("check_hardware_evidence_progress.ps1", "BENCH_STATUS.json", "stackchan.android-companion-probe.v1", "stackchan.android-companion-soak.v1", "stackchan.android-udp-beacon-probe.v1", "stackchan.android-companion-logcat.v1", "report schema mismatch", "report did not pass", "Android screen-off soak report status: pass", "Android companion logcat capture report status: captured", "Android probe evidence progress contract tests passed")) {
  if ($androidProbeEvidenceProgressContractText -notmatch [regex]::Escape($pattern)) {
    throw "tools/test_android_probe_evidence_progress_contract.ps1 missing Android probe progress evidence coverage: $pattern"
  }
}

$androidRolloutStatusContractText = Get-Content -LiteralPath (Join-PackagePath "tools/test_android_rollout_status_contract.ps1") -Raw
foreach ($pattern in @("export_rollout_status.ps1", "stackchan.android-apk-install.v1", "stackchan.android-companion-probe.v1", "stackchan.android-companion-soak.v1", "stackchan.android-udp-beacon-probe.v1", "stackchan.android-companion-logcat.v1", "ROLLOUT_STATUS.json", "android-companion-probes", "missing a valid apkSha256", "missing a full sourceCommit SHA", "missing installed versionName/versionCode", "Android APK install evidence status installed", "Android companion bridge probe schema mismatch", "Android screen-off soak status fail", "Android UDP beacon probe status fail", "Android companion logcat capture status failed", "Android rollout status evidence contract tests passed")) {
  if ($androidRolloutStatusContractText -notmatch [regex]::Escape($pattern)) {
    throw "tools/test_android_rollout_status_contract.ps1 missing Android rollout status coverage: $pattern"
  }
}

$androidLogcatCaptureContractText = Get-Content -LiteralPath (Join-PackagePath "tools/test_android_logcat_capture_contract.ps1") -Raw
foreach ($pattern in @("capture_android_companion_logcat.ps1", "fake-adb.ps1", "stackchan.android-companion-logcat.v1", "android_companion_logcat.json", "ANDROID_COMPANION_LOGCAT.md", "android_companion_logcat.txt", "android_companion_logcat_raw.txt", "CompanionBridgeService started", "ForegroundService", "FATAL EXCEPTION synthetic", "Android logcat capture contract tests passed")) {
  if ($androidLogcatCaptureContractText -notmatch [regex]::Escape($pattern)) {
    throw "tools/test_android_logcat_capture_contract.ps1 missing Android logcat capture coverage: $pattern"
  }
}

$androidEvidencePacketContractText = Get-Content -LiteralPath (Join-PackagePath "tools/test_android_evidence_packet_contract.ps1") -Raw
foreach ($pattern in @("start_hardware_evidence.ps1", "check_hardware_evidence_progress.ps1", "RUN_ANDROID_APK_INSTALL.cmd", "RUN_ANDROID_COMPANION_PROBE.cmd", "RUN_ANDROID_SCREEN_OFF_SOAK.cmd", "RUN_ANDROID_UDP_BEACON_PROBE.cmd", "RUN_ANDROID_LOGCAT_CAPTURE.cmd", "androidCompanionProbes", "android/apk-install/android_apk_install.json", "android/companion-probe/android_companion_probe.json", "android/screen-off-soak/android_companion_soak.json", "android/udp-beacon-probe/android_udp_beacon_probe.json", "android/logcat/android_companion_logcat.json", "Test-AndroidDashboardManifestEvidence", "Android dashboard connected state", "robot identity", "firmware/version signal", "last bridge frame", "active brain owner", "foreground service state", "RUN_ADD_MEDIA.cmd -Type Photo -Notes", "Android evidence packet contract tests passed")) {
  if ($androidEvidencePacketContractText -notmatch [regex]::Escape($pattern)) {
    throw "tools/test_android_evidence_packet_contract.ps1 missing Android evidence packet coverage: $pattern"
  }
}

$strictAndroidApkEvidenceContractText = Get-Content -LiteralPath (Join-PackagePath "tools/test_strict_android_apk_evidence_contract.ps1") -Raw
foreach ($pattern in @("verify_hardware_evidence.ps1", "AndroidApkEvidenceContractSelfTest", "stackchan.android-apk-install.v1", "missing a valid apkSha256", "missing a full sourceCommit SHA", "missing installed versionName/versionCode", "Android APK strict evidence contract verified", "Strict Android APK evidence contract tests passed")) {
  if ($strictAndroidApkEvidenceContractText -notmatch [regex]::Escape($pattern)) {
    throw "tools/test_strict_android_apk_evidence_contract.ps1 missing strict Android APK evidence coverage: $pattern"
  }
}

$strictAndroidDashboardEvidenceContractText = Get-Content -LiteralPath (Join-PackagePath "tools/test_strict_android_dashboard_evidence_contract.ps1") -Raw
foreach ($pattern in @("verify_hardware_evidence.ps1", "AndroidDashboardEvidenceContractSelfTest", "stackchan.hardware-media-manifest.v1", "media_manifest.json is missing", "missing a photo/video entry", "Android dashboard strict evidence contract verified", "Strict Android dashboard evidence contract tests passed", "Android dashboard connected state; robot identity; firmware/version signal; last bridge frame; active brain owner; foreground service state")) {
  if ($strictAndroidDashboardEvidenceContractText -notmatch [regex]::Escape($pattern)) {
    throw "tools/test_strict_android_dashboard_evidence_contract.ps1 missing strict Android dashboard evidence coverage: $pattern"
  }
}

$strictAndroidProbeEvidenceContractText = Get-Content -LiteralPath (Join-PackagePath "tools/test_strict_android_probe_evidence_contract.ps1") -Raw
foreach ($pattern in @("verify_hardware_evidence.ps1", "AndroidProbeEvidenceContractSelfTest", "stackchan.android-companion-probe.v1", "stackchan.android-companion-soak.v1", "stackchan.android-udp-beacon-probe.v1", "stackchan.android-companion-logcat.v1", "schema mismatch", "status is not accepted", "Android screen-off soak status is not accepted", "Android probe strict evidence contract verified", "Strict Android probe evidence contract tests passed")) {
  if ($strictAndroidProbeEvidenceContractText -notmatch [regex]::Escape($pattern)) {
    throw "tools/test_strict_android_probe_evidence_contract.ps1 missing strict Android probe evidence coverage: $pattern"
  }
}

$androidDashboardMediaGateTestText = Get-Content -LiteralPath (Join-PackagePath "bridge/test_android_dashboard_media_gate.py") -Raw
foreach ($pattern in @("AndroidDashboardMediaGateTest", "check_hardware_evidence_progress.ps1", "BENCH_STATUS.json", "test_android_probe_requires_dashboard_media_notes", "test_matching_dashboard_media_notes_clear_android_dashboard_finding", "RUN_ADD_MEDIA.cmd -Type Photo -Notes", "media_manifest.json is missing the connected-dashboard", "Android dashboard connected state; robot identity; firmware/version signal;", "last bridge frame; active brain owner; foreground service state")) {
  if ($androidDashboardMediaGateTestText -notmatch [regex]::Escape($pattern)) {
    throw "bridge/test_android_dashboard_media_gate.py missing dashboard media gate coverage: $pattern"
  }
}

$androidCompanionProbeText = Get-Content -LiteralPath (Join-PackagePath "bridge/android_companion_probe.py") -Raw
foreach ($pattern in @("stackchan.android-companion-probe.v1", "stackchan.bridge.v1", "Android bridge URL must start with ws://", "Android bridge URL path must be /bridge", "101 Switching Protocols", "endpoint_hello", "expected endpoint_kind android", "settings", "diagnostics", "android_companion_probe.json", "ANDROID_COMPANION_PROBE.md", "ws://192.168.1.42:8765/bridge", "--allow-non-android")) {
  if ($androidCompanionProbeText -notmatch [regex]::Escape($pattern)) {
    throw "bridge/android_companion_probe.py missing Android companion probe runtime contract: $pattern"
  }
}

$androidCompanionProbeTestText = Get-Content -LiteralPath (Join-PackagePath "bridge/test_android_companion_probe.py") -Raw
foreach ($pattern in @("AndroidCompanionProbeTest", "test_parse_requires_ws_bridge_url", "test_probe_accepts_android_endpoint_hello", "test_probe_rejects_non_android_endpoint_by_default", "endpoint_kind", "android", "expected endpoint_kind android")) {
  if ($androidCompanionProbeTestText -notmatch [regex]::Escape($pattern)) {
    throw "bridge/test_android_companion_probe.py missing Android companion probe test coverage: $pattern"
  }
}

$androidCompanionSoakText = Get-Content -LiteralPath (Join-PackagePath "bridge/android_companion_soak.py") -Raw
foreach ($pattern in @("stackchan.android-companion-soak.v1", "build_soak_report", "evaluate_samples", "android_companion_soak.json", "ANDROID_COMPANION_SOAK.md", "DEFAULT_DURATION_SECONDS = 600.0", "DEFAULT_INTERVAL_SECONDS = 30.0", "--min-success-rate", "--max-failures", "RUN_ANDROID_LOGCAT_CAPTURE.cmd")) {
  if ($androidCompanionSoakText -notmatch [regex]::Escape($pattern)) {
    throw "bridge/android_companion_soak.py missing Android screen-off soak runtime contract: $pattern"
  }
}

$androidCompanionSoakTestText = Get-Content -LiteralPath (Join-PackagePath "bridge/test_android_companion_soak.py") -Raw
foreach ($pattern in @("AndroidCompanionSoakTest", "test_soak_passes_when_all_samples_pass", "test_soak_fails_when_any_strict_sample_fails", "test_write_outputs_include_logcat_follow_up", "RUN_ANDROID_LOGCAT_CAPTURE.cmd", "android-companion-test")) {
  if ($androidCompanionSoakTestText -notmatch [regex]::Escape($pattern)) {
    throw "bridge/test_android_companion_soak.py missing Android screen-off soak test coverage: $pattern"
  }
}

$androidUdpBeaconProbeText = Get-Content -LiteralPath (Join-PackagePath "bridge/android_udp_beacon_probe.py") -Raw
foreach ($pattern in @("stackchan.android-udp-beacon-probe.v1", "stackchan.bridge.v1", "stackchan_bridge_beacon", "DEFAULT_BEACON_PORT = 8766", "DEFAULT_BRIDGE_PORT = 8765", "expected endpoint_kind android", "expected bridge port", "expected endpoint_id", "settings", "diagnostics", "timed out waiting for UDP beacon", "android_udp_beacon_probe.json", "ANDROID_UDP_BEACON_PROBE.md", "--expected-bridge-port", "--expected-endpoint-id", "--allow-non-android")) {
  if ($androidUdpBeaconProbeText -notmatch [regex]::Escape($pattern)) {
    throw "bridge/android_udp_beacon_probe.py missing Android UDP beacon probe runtime contract: $pattern"
  }
}

$androidUdpBeaconProbeTestText = Get-Content -LiteralPath (Join-PackagePath "bridge/test_android_udp_beacon_probe.py") -Raw
foreach ($pattern in @("AndroidUdpBeaconProbeTest", "test_validate_accepts_android_beacon", "test_validate_rejects_wrong_kind_and_port", "test_probe_listens_for_one_beacon", "stackchan_bridge_beacon", "expected bridge port 8765", "endpoint_kind android")) {
  if ($androidUdpBeaconProbeTestText -notmatch [regex]::Escape($pattern)) {
    throw "bridge/test_android_udp_beacon_probe.py missing Android UDP beacon probe test coverage: $pattern"
  }
}

$androidCompanionProbeRunnerText = Get-Content -LiteralPath (Join-PackagePath "tools/run_android_companion_probe.ps1") -Raw
foreach ($pattern in @("[double]`$Timeout = 5.0", "--timeout", "android_companion_probe.py", "--allow-non-android")) {
  if ($androidCompanionProbeRunnerText -notmatch [regex]::Escape($pattern)) {
    throw "tools/run_android_companion_probe.ps1 missing Android companion probe wrapper contract: $pattern"
  }
}

$androidCompanionSoakRunnerText = Get-Content -LiteralPath (Join-PackagePath "tools/run_android_companion_soak.ps1") -Raw
foreach ($pattern in @("[double]`$DurationSeconds = 600.0", "[double]`$IntervalSeconds = 30.0", "[double]`$MinSuccessRate = 1.0", "[int]`$MaxFailures = 0", "--duration-seconds", "--interval-seconds", "--min-success-rate", "--max-failures", "android_companion_soak.py", "--allow-non-android")) {
  if ($androidCompanionSoakRunnerText -notmatch [regex]::Escape($pattern)) {
    throw "tools/run_android_companion_soak.ps1 missing Android screen-off soak wrapper contract: $pattern"
  }
}

$androidScreenOffSoakEvidenceText = Get-Content -LiteralPath (Join-PackagePath "tools/check_android_screen_off_soak_evidence.ps1") -Raw
foreach ($pattern in @("stackchan.android-screen-off-soak-evidence.v1", "ANDROID_SCREEN_OFF_SOAK_REVIEW.md", "android_companion_soak.json", "ANDROID_COMPANION_SOAK.md", "stackchan.android-companion-soak.v1", "requested_duration_seconds", "success_rate", "endpoint_kind", "android-screen-off-soak-ready", "pending-android-screen-off-soak-evidence", "Screen-off decision: pass", "Heartbeat continuity decision: pass", "Wake-lock release decision: pass", "Foreground-service decision: pass", "RequireReady")) {
  if ($androidScreenOffSoakEvidenceText -notmatch [regex]::Escape($pattern)) {
    throw "tools/check_android_screen_off_soak_evidence.ps1 missing Android screen-off soak evidence contract: $pattern"
  }
}

$androidUdpBeaconProbeRunnerText = Get-Content -LiteralPath (Join-PackagePath "tools/run_android_udp_beacon_probe.ps1") -Raw
foreach ($pattern in @("[double]`$Timeout = 10.0", "[int]`$ExpectedBridgePort = 8765", "--expected-bridge-port", "--expected-endpoint-id", "android_udp_beacon_probe.py", "--allow-non-android")) {
  if ($androidUdpBeaconProbeRunnerText -notmatch [regex]::Escape($pattern)) {
    throw "tools/run_android_udp_beacon_probe.ps1 missing Android UDP beacon probe wrapper contract: $pattern"
  }
}

$hardwareVerifierText = Get-Content -LiteralPath (Join-PackagePath "tools/verify_hardware_evidence.ps1") -Raw
foreach ($pattern in @("BENCH_STATUS.md", "BENCH_STATUS.json", "Stackchan Bench Status", "stackchan.bench-status.v1", "nextAction", "nextCommand", "NEXT_STEPS.md", "Stackchan Evidence Next Steps", "production voice-source provenance", "stackchan.release-acceptance.v1", "test-ready-for-device-arrival", "blocked-pending-hardware-validation", "release_acceptance.json", "speech-mouth-demo-evidence", "target-speaker-audio-evidence", "Speech-mouth demo evidence", "Target-speaker audio evidence", "AUDIO_REVIEW.md", "Test-AudioEvidenceFile", "Speaker recording file", "Intelligible through device speaker", "voiceLeadAudition", "RVC_LEAD_AUDITION.md", "RVC lead audition reference hash does not match metadata", "voiceGateStatus", "VOICE_SOURCE_STATUS.md", "voice_source_status.json", "stackchan.voice-source-status.v1", "voice_source_status.json status does not match metadata voiceGateStatus", "RVC_VOICE_BASE_STATUS.md", "rvc_voice_base_status.json", "stackchan.rvc-voice-base-status.v1", "rvc_voice_base_status.json distributionApproved does not match metadata voiceGateStatus", "shareVerification", "stackchan.share-verification.v1", "verifiedShareUrl", "verifiedUrlFile", "share verification report does not show all probes HTTP 200", "HOSTED_MEDIA_REFERENCE.md missing expected marker", "display frame-budget telemetry", "display face animator telemetry", "display bench control telemetry", "display speech cue telemetry", "display runtime health telemetry", "speech mouth demo envelope commands", "speech mouth demo clear command", "speech mouth demo completion", "speak_all_intents_serial.log", "speak-all packaged prompt audio-output handoff", "Speak-all-intents demo complete", "command=speak_intent", "cue_intent=", "source=packaged_prompt", "soak display frame-budget telemetry", "soak face animator telemetry", "soak speech cue telemetry", "soak runtime health telemetry", "reduced_motion_on|reduced_motion_off|safe_stop", "Test-AndroidDashboardManifestEntry", "Assert-AndroidDashboardManifestEvidence", "Assert-AndroidReportEvidence", "Assert-AndroidCompanionReportEvidence", "AndroidApkEvidenceContractSelfTest", "AndroidDashboardEvidenceContractSelfTest", "AndroidProbeEvidenceContractSelfTest", "Android APK strict evidence contract verified", "Android dashboard strict evidence contract verified", "Android probe strict evidence contract verified", "status is not accepted", "stackchan.android-companion-probe.v1", "stackchan.android-companion-soak.v1", "stackchan.android-udp-beacon-probe.v1", "stackchan.android-companion-logcat.v1", "apkSha256", "valid apkSha256", "sourceCommit", "full sourceCommit SHA", "versionName/versionCode", "-SourceCommit <git-commit>", "Android companion reports are present", "media_manifest.json is missing a photo/video entry", "Android dashboard connected state; robot identity; firmware/version signal; last bridge frame; active brain owner; foreground service state", "AllowSyntheticEvidence", "diagnosticOnly")) {
  if ($hardwareVerifierText -notmatch [regex]::Escape($pattern)) {
    throw "tools/verify_hardware_evidence.ps1 missing acceptance artifact verification logic: $pattern"
  }
}

$ciExceptionDraftText = Get-Content -LiteralPath (Join-PackagePath "tools/new_ci_account_block_exception.ps1") -Raw
foreach ($pattern in @("stackchan.ci-account-block-exception.v1", "stackchan.github-actions-status.v1", "external-account-billing-or-spending-limit", "external-account-ci-pre-runner-allocation", "riskAccepted = `$false", "localReleaseVerificationPassed = `$false", "strictHardwareEvidencePassed = `$false", "productionVoiceSourceReady = `$false", "TBD - accountable approver required", "not an external account block", "sourceActionsStatusPath")) {
  if ($ciExceptionDraftText -notmatch [regex]::Escape($pattern)) {
    throw "tools/new_ci_account_block_exception.ps1 missing draft safety logic: $pattern"
  }
}

$consumerPromotionVerifierText = Get-Content -LiteralPath (Join-PackagePath "tools/verify_consumer_promotion.ps1") -Raw
foreach ($pattern in @("verify_release_package.ps1", "verify_hardware_evidence.ps1", "github_actions_status.json", "ActionsStatusPath", "export_github_actions_status.ps1", "successful live GitHub Actions status", "missingRequiredWorkflows", "required workflow evidence", "external-account-billing-or-spending-limit", "ExternalAccountCiExceptionPath", "Assert-CiExceptionRecord", "stackchan.ci-account-block-exception.v1", "riskAccepted", "localReleaseVerificationPassed", "strictHardwareEvidencePassed", "productionVoiceSourceReady", "voice_source_provenance.yaml", "pending-production-source", "Assert-VoiceStatusReportsReady", "voice_source_status.json is not production-source-ready", "rvc_voice_base_status.json is not consumer approved", "rvc_voice_base_status.json is not distribution approved", "ProjectLicensePath", "Assert-ProjectLicenseReady", "CameraFollowSummaryPath", "Assert-CameraFollowReady", "BodySensorReportPath", "Assert-BodySensorReady", "FullSystemSoakSummaryPath", "Assert-FinalSoakReady", "ExpectedFirmwareSourceCommit", "same installed firmware SHA-256", "Consumer promotion gate verified", "AllowMissingMedia cannot be used for consumer promotion", "strict media evidence", "CompanionV1EvidenceRoot", "Assert-CompanionV1PromotionReady", "check_companion_v1_evidence_bundle.ps1", "stackchan.companion-v1-evidence-bundle-check.v1", "companion-v1-evidence-ready", "Companion v1 aggregate source commit mismatch", "Companion v1 aggregate firmware source commit mismatch", "Companion v1 aggregate release version mismatch", "Companion v1 hardware evidence root does not match the packet being promoted", "Companion v1 release ZIP SHA-256 does not match the package being promoted", "Consumer promotion requires -PackageZip")) {
  if ($consumerPromotionVerifierText -notmatch [regex]::Escape($pattern)) {
    throw "tools/verify_consumer_promotion.ps1 missing promotion gate logic: $pattern"
  }
}
if ($consumerPromotionVerifierText -match "evidenceArgs\s*\+=\s*['`"]-AllowMissingMedia['`"]") {
  throw "tools/verify_consumer_promotion.ps1 must not forward AllowMissingMedia to hardware evidence verification"
}

$consumerPromotionContractText = Get-Content -LiteralPath (Join-PackagePath "tools/test_consumer_promotion_contract.ps1") -Raw
foreach ($pattern in @("CompanionV1EvidenceRoot", "Assert-CompanionV1PromotionReady", "-ExpectedSourceCommit `$ExpectedCommit", "-ExpectedFirmwareSourceCommit `$ExpectedFirmwareSourceCommit", "-ExpectedHardwareEvidenceRoot `$EvidenceRoot", "-ExpectedPackageZipSha256 `$promotionPackageZipSha256", "Consumer promotion contract verified")) {
  if ($consumerPromotionContractText -notmatch [regex]::Escape($pattern)) {
    throw "tools/test_consumer_promotion_contract.ps1 missing aggregate Companion v1 promotion coverage: $pattern"
  }
}

$releaseAssetContractText = Get-Content -LiteralPath (Join-PackagePath "tools/release_asset_contract.ps1") -Raw
foreach ($pattern in @("Get-ReleaseBaseAssetEntries", "Get-ReleaseFinalAssetEntries", "Get-ReleaseAllowedAuditAssetEntries", "Get-ReleaseCompanionAssetEntries", "firmware-display-only.bin", "firmware-servo-calibration.bin", "stackchan_spark_audition_bright_robot_greeting.mp3", "stackchan_spark_thinking.mp3", "stackchan-companion-android-`$Version.apk", "stackchan-companion-android-`$Version.aab", "stackchan-companion-windows-`$Version.msi", "stackchan-companion-linux-`$Version.deb", "stackchan-companion-macos-`$Version.dmg", "COMPANION_RELEASE_EVIDENCE.json")) {
  if ($releaseAssetContractText -notmatch [regex]::Escape($pattern)) {
    throw "tools/release_asset_contract.ps1 missing required release asset contract logic: $pattern"
  }
}

$releaseAssetContractVerifierText = Get-Content -LiteralPath (Join-PackagePath "tools/verify_release_asset_contract.ps1") -Raw
foreach ($pattern in @("Get-ReleaseBaseAssetEntries", "Get-ReleaseFinalAssetEntries", "ExpectedCount 17", "ExpectedCount 20", "release_assets.json", "stackchan.release-assets.v1", "release_manifest.json", "mediaArtifacts", "duplicate asset names", "FirmwareAssetRoot", "FirmwareAssetPathMode", "Assert-StagedFirmwareMatchesPackage", "Get-FileHash", "Release asset contract verified")) {
  if ($releaseAssetContractVerifierText -notmatch [regex]::Escape($pattern)) {
    throw "tools/verify_release_asset_contract.ps1 missing required asset contract verification logic: $pattern"
  }
}

$publishedVerifierText = Get-Content -LiteralPath (Join-PackagePath "tools/verify_published_release.ps1") -Raw
foreach ($pattern in @("release_asset_contract.ps1", "release_assets.json", "stackchan.release-assets.v1", "Get-ReleaseFinalAssetEntries", "Get-ReleaseAllowedAuditAssetEntries", "Get-ReleaseCompanionAssetEntries", "ZipSidecarPath", ".zip.sha256", "Published ZIP SHA256 sidecar", "allowedAssetNames", "Unexpected release asset", "stackchan.companion-release-evidence.v1", "uploadSigningRequired", "upload-key", "desktopPackageEvidenceRequired", "packageSha256", "runtimeSha256", "processedFileCount", "installerAppJarSha256", "installerRuntimeSha256", "installerBrainFiles", "Assert-CompanionEvidenceHash")) {
  if ($publishedVerifierText -notmatch [regex]::Escape($pattern)) {
    throw "tools/verify_published_release.ps1 missing required published ZIP sidecar verification logic: $pattern"
  }
}

$publishedAuditText = Get-Content -LiteralPath (Join-PackagePath "tools/audit_published_release.ps1") -Raw
foreach ($pattern in @("stackchan.release-audit.v1", "verify_published_release.ps1", "export_github_actions_status.ps1", "export_rollout_status.ps1", "RELEASE_AUDIT.md", "RELEASE_AUDIT.json", "published-release-blocked-or-pending", "UploadToRelease", "gh release upload", "Assert-UploadedAuditAsset", "auditAssetsUploaded", "Write-AuditFiles")) {
  if ($publishedAuditText -notmatch [regex]::Escape($pattern)) {
    throw "tools/audit_published_release.ps1 missing required published release audit logic: $pattern"
  }
}

$releaseWorkflowText = Get-Content -LiteralPath (Join-PackagePath "provenance/release.yml") -Raw
foreach ($pattern in @("release_asset_contract.ps1", "verify_release_asset_contract.ps1", "Get-ReleaseFinalAssetEntries", "Get-ReleaseCompanionAssetEntries", "FirmwareAssetRoot `$stageDir", "FirmwareAssetPathMode Stage", "workflow-assets-", "companion-android-release", "companion-android-emulator-smoke", "companion-desktop-release", "check_companion_release_version.ps1", "check_android_play_release_readiness.ps1", "STACKCHAN_ANDROID_KEYSTORE_B64", "test_android_emulator_launch.ps1", "AndroidEmulatorEvidencePath", "RequireAndroidEmulatorEvidence", "prepare_desktop_python_runtime.ps1", "test_desktop_package_launch.ps1", "export_desktop_package_evidence.ps1", "RequireInstallerPayload", "RequireLaunchEvidence", "RequireUploadSigning", "RequireDesktopPackageEvidence", '$releaseAssetPaths', '@releaseAssetPaths')) {
  if ($releaseWorkflowText -notmatch [regex]::Escape($pattern)) {
    throw "provenance/release.yml missing release asset contract upload logic: $pattern"
  }
}
if ($releaseWorkflowText -notmatch 'package_release\.ps1 -Version' -or
    $releaseWorkflowText -match 'package_release\.ps1[^\r\n]*-SkipBuild') {
  throw "provenance/release.yml must let package_release.ps1 build all required firmware profiles on a clean tag runner."
}

$firmwareWorkflowText = Get-Content -LiteralPath (Join-PackagePath "provenance/firmware.yml") -Raw
foreach ($pattern in @("Install bridge test dependencies", "sudo apt-get install -y ffmpeg", "python -m pip install -r bridge/requirements-vision.txt", "Verify bundled persona packs", "verify_persona_pack.py glow", "Compile native logic with Glow persona", "STACKCHAN_PERSONA: glow", "Run LiteRT-LM contract smoke", "litert_lm_contract_smoke.py", "litert-lm-contract-smoke", "LITERT_LM_SMOKE.md")) {
  if ($firmwareWorkflowText -notmatch [regex]::Escape($pattern)) {
    throw "provenance/firmware.yml missing LiteRT-LM contract smoke workflow support: $pattern"
  }
}
foreach ($pattern in @("workflow_dispatch", "github.event_name != 'workflow_dispatch'", "github.event_name == 'workflow_dispatch'", "companion-platform-builds", "companion-android-emulator-smoke", "python-version: `"3.12`"", "test_android_emulator_release_evidence_contract.ps1", "test_desktop_package_evidence_contract.ps1", "test_desktop_target_install_evidence_contract.ps1", "test_desktop_package_launch.ps1", "prepare_desktop_python_runtime.ps1", "STACKCHAN_DESKTOP_PYTHON_RUNTIME_ROOT", "export_desktop_package_evidence.ps1", "RequireInstallerPayload", "RequireLaunchEvidence", "linux-package-evidence.json", "macos-package-evidence.json", "windows-package-evidence.json", "AndroidEmulatorEvidencePath", "RequireAndroidEmulatorEvidence", "DesktopPackageEvidenceRoot", "RequireDesktopPackageEvidence")) {
  if ($firmwareWorkflowText -notmatch [regex]::Escape($pattern)) {
    throw "provenance/firmware.yml missing native desktop package/runtime PR evidence support: $pattern"
  }
}

$publisherText = Get-Content -LiteralPath (Join-PackagePath "tools/publish_release.ps1") -Raw
foreach ($pattern in @("release_asset_contract.ps1", "verify_release_asset_contract.ps1", "Get-ReleaseBaseAssetEntries", "Get-ReleaseFinalAssetEntries", "Export-ActionsStatusWithRetry", "Update-ReleaseArchive", "Clear-TransientPackageOutput", "output/voice_auditions/VOICE_AUDITION_INDEX.html", '$baseReleaseAssets', '$finalReleaseAssets', '@baseReleaseAssets', '@finalReleaseAssets', "Verify finalized release asset contract before upload", "FirmwareAssetRoot `$stageDir", "FirmwareAssetPathMode Stage", "SHA256SUMS.txt", "--clobber", "PushCurrentBranch", "Assert-CurrentBranchPublishedAtCommit", "git ls-remote", "Firmware workflow can be observed", "Push the branch first or pass -PushCurrentBranch", "audit_published_release.ps1", "-UploadToRelease")) {
  if ($publisherText -notmatch [regex]::Escape($pattern)) {
    throw "tools/publish_release.ps1 missing required finalized Actions status publish logic: $pattern"
  }
}

foreach ($docPath in @("README.md", "docs/RELEASE_PROCESS.md")) {
  $publishDocText = Get-Content -LiteralPath (Join-PackagePath $docPath) -Raw
  foreach ($pattern in @("publish_release.cmd", "-PushCurrentBranch", "-PushTag", "audit_published_release.cmd")) {
    if ($publishDocText -notmatch [regex]::Escape($pattern)) {
      throw "$docPath missing safe publish guidance: $pattern"
    }
  }
}

$releaseProcessText = Get-Content -LiteralPath (Join-PackagePath "docs/RELEASE_PROCESS.md") -Raw
foreach ($pattern in @("export_companion_release_evidence.cmd", "COMPANION_RELEASE_EVIDENCE.json/md", "artifact SHA256s", "libs.versions.toml", "-RequireArtifacts", "-RequireUploadSigning", "-RequireAndroidEmulatorEvidence", "-RequireDesktopPackageEvidence", "API 35 emulator launch evidence", "APK SHA-256 matches the release", "package SHA-256", "installer application JAR", "installer-derived runtime SHA-256")) {
  if ($releaseProcessText -notmatch [regex]::Escape($pattern)) {
    throw "docs/RELEASE_PROCESS.md missing companion C8 release evidence guidance: $pattern"
  }
}

$repoReadmeText = Get-Content -LiteralPath (Join-PackagePath "README.md") -Raw
if ($repoReadmeText -match '\]\(docs/media/') {
  throw "README.md still points at source-only docs/media paths instead of packaged media paths"
}
foreach ($pattern in @("media/voice/rvc", "model.pth", "model.index", "install_bundled_rvc_voice.ps1", "open_voice_audition.cmd -All")) {
  if ($repoReadmeText -notmatch [regex]::Escape($pattern)) {
    throw "README.md missing RVC audition discoverability guidance: $pattern"
  }
}
foreach ($pattern in @("01-system-overview.png", "02-firmware-task-architecture.png", "03-persona-engine.png", "04-face-runtime.png", "05-motion-servo-safety.png", "06-brain-bridge-protocol.png", "08-io-abstraction-builds.png")) {
  if ($repoReadmeText -notmatch [regex]::Escape($pattern)) {
    throw "README.md missing architecture diagram reference: $pattern"
  }
}
foreach ($pattern in @("Real-model benchmark and red-team gates", "run_character_red_team.cmd -Json", "-RequireRunner")) {
  if ($repoReadmeText -notmatch [regex]::Escape($pattern)) {
    throw "README.md missing character red-team guidance: $pattern"
  }
}
foreach ($pattern in @("Stackchan: Alive is a character OS", "Spark and Glow persona packs", "personas/glow", "verify_persona_pack.cmd glow --Json", "create_persona_pack.cmd nova", "Name or handle to credit", "CREATING_PERSONAS.md")) {
  if ($repoReadmeText -notmatch [regex]::Escape($pattern)) {
    throw "README.md missing Character OS persona-pack guidance: $pattern"
  }
}
foreach ($pattern in @("On-device wake phrase", "microphone capture", "wake-gated", "mouth-synchronized replies")) {
  if ($repoReadmeText -notmatch [regex]::Escape($pattern)) {
    throw "README.md missing mic capture status guidance: $pattern"
  }
}
foreach ($pattern in @("public v0.2 release candidate", "formal one-hour actuator acceptance", "more than five hours", "exact paired candidate", "public build", "FIRST_DEPLOY_STATUS.md", "CONVERSATION_V2_ROADMAP.md")) {
  if ($repoReadmeText -notmatch [regex]::Escape($pattern)) {
    throw "README.md missing current release-candidate status or navigation: $pattern"
  }
}

$agentGuideText = Get-Content -LiteralPath (Join-PackagePath "AGENTS.md") -Raw
foreach ($pattern in @("FIRST_DEPLOY_STATUS.md", "POWER_BLACKOUT_FORENSICS.md", "CUSTOMIZING_THE_FACE.md", "CONVERSATION_V2_ROADMAP.md", "exact installed binary", "motion-stop")) {
  if ($agentGuideText -notmatch [regex]::Escape($pattern)) {
    throw "AGENTS.md missing agent navigation or hardware-safety guidance: $pattern"
  }
}

$docsIndexText = Get-Content -LiteralPath (Join-PackagePath "docs/README.md") -Raw
foreach ($pattern in @("../AGENTS.md", "BRAIN_MODEL.md", "CUSTOMIZING_THE_FACE.md", "LOCAL_VISION.md", "RELEASE_PROCESS.md", "CONVERSATION_V2_ROADMAP.md")) {
  if ($docsIndexText -notmatch [regex]::Escape($pattern)) {
    throw "docs/README.md missing documentation index entry: $pattern"
  }
}

$conversationV2Text = Get-Content -LiteralPath (Join-PackagePath "docs/CONVERSATION_V2_ROADMAP.md") -Raw
foreach ($pattern in @("post-release feature", "REPLY_WINDOW", "echo guard", "privacy-filtered", "under 3 seconds", "zero truncation")) {
  if ($conversationV2Text -notmatch [regex]::Escape($pattern)) {
    throw "docs/CONVERSATION_V2_ROADMAP.md missing bounded v2 architecture or acceptance guidance: $pattern"
  }
}

$creatingPersonasText = Get-Content -LiteralPath (Join-PackagePath "docs/CREATING_PERSONAS.md") -Raw
foreach ($pattern in @("create_persona_pack.cmd nova", "Name or handle to credit", "Author credit is required", "placeholders", "copy-edit-validate-build", "verify_persona_pack.cmd nova --Json", "run_character_red_team.cmd -Persona nova -Json", "STACKCHAN_PERSONA", "voice asset hash verification")) {
  if ($creatingPersonasText -notmatch [regex]::Escape($pattern)) {
    throw "docs/CREATING_PERSONAS.md missing creator path guidance: $pattern"
  }
}

$personaPacksText = Get-Content -LiteralPath (Join-PackagePath "docs/PERSONA_PACKS.md") -Raw
foreach ($pattern in @("red-team dry-run harness", "configured real runner", "codegen coverage", "personas/glow", "quieter second pack", "firmware earcon tone table", "firmware face/idle-life/circadian", "expression defaults", "listen/think/orient motion biases", "packaged prompt metadata", "firmware WAV embedding list", "Speech lines, earcon params", "create_persona_pack.cmd nova", "Name or handle to credit", "Author credit is required", "placeholder values are rejected", "CREATING_PERSONAS.md", "copy-edit-validate-build")) {
  if ($personaPacksText -notmatch [regex]::Escape($pattern)) {
    throw "docs/PERSONA_PACKS.md missing persona red-team status: $pattern"
  }
}

$releaseProcessText = Get-Content -LiteralPath (Join-PackagePath "docs/RELEASE_PROCESS.md") -Raw
foreach ($pattern in @("open_voice_audition.cmd -Rvc", "open_voice_audition.cmd -All", "verify_tracked_rvc_assets.cmd", "model.pth", "model.index", "SHA-256")) {
  if ($releaseProcessText -notmatch [regex]::Escape($pattern)) {
    throw "docs/RELEASE_PROCESS.md missing RVC audition process guidance: $pattern"
  }
}
foreach ($pattern in @("verify_share_release.cmd -Version <version> -Offline", "share_static_verification_report.json", "offline-static:", "not hosted-media evidence")) {
  if ($releaseProcessText -notmatch [regex]::Escape($pattern)) {
    throw "docs/RELEASE_PROCESS.md missing offline share verification guidance: $pattern"
  }
}

$actionsStatusExporterText = Get-Content -LiteralPath (Join-PackagePath "tools/export_github_actions_status.ps1") -Raw
foreach ($pattern in @("stackchan.github-actions-status.v1", "RequiredWorkflows", "FixtureRoot", "requiredWorkflows", "missingRequiredWorkflows", "missing-required-workflow", "external-account-billing-or-spending-limit", "external-account-ci-pre-runner-allocation", "promotionReady", "externalBlock", "nextAction", "nextCommand", "payments have failed", "spending limit", "runnerId", "stepCount")) {
  if ($actionsStatusExporterText -notmatch [regex]::Escape($pattern)) {
    throw "tools/export_github_actions_status.ps1 missing required Actions status export logic: $pattern"
  }
}

$preflightText = Get-Content -LiteralPath (Join-PackagePath "tools/run_device_preflight.ps1") -Raw
foreach ($pattern in @("Assert-GitHubActionsStatusExporterGate", "Check GitHub Actions status exporter gates", "FixtureRoot", "missing-required-workflow", "external-account-billing-or-spending-limit", "external-account-ci-pre-runner-allocation", "no runner was assigned", "promotionReady", "externalBlock", "nextAction", "nextCommand", "Assert-CiAccountBlockExceptionDraftGate", "Check CI account-block exception draft helper", "CI_ACCOUNT_BLOCK_EXCEPTION_DRAFT.json", "riskAccepted should remain false", "not an external account block", "Assert-LocalShareEvidenceGate", "Check local share evidence capture", "Write-LocalShareVerificationFixture", "share/VERIFIED_URL.txt", "Generated local-only evidence should not require share/PUBLIC_URL.txt", "Assert-RolloutStatusActionsOverrideGate", "Check rollout status Actions override", "ActionsStatusPath", "Packaged missing-workflow status leaked", "Check LiteRT-LM contract smoke", "run_litert_lm_smoke.ps1", "Check LAN bridge smoke report", "run_lan_smoke.ps1", "Check pre-arrival simulation report", "run_prearrival_sim_check.ps1", "Assert-HardwareSimComparisonGate", "Check hardware simulation comparator", "SIM_HARDWARE_COMPARE.json", "stackchan.hardware-sim-compare.v1", "Assert-SpeechEnvelopeSidecarGate", "Check speech envelope sidecar tooling", "generate_speech_envelope_sidecar.ps1", "verify_speech_envelope_sidecar.ps1", "-MinMaxEnvelope", "send_speech_mouth_demo.ps1", "send_speak_all_intents_demo.ps1", "speech_mouth_demo_serial.log", "speak_all_intents_serial.log", "Speech mouth demo complete", "Speak-all-intents demo complete", "speech-mouth-demo-evidence", "target-speaker-audio-evidence", "Write-SyntheticVoiceGateStatus", "voiceGateStatus = `$voiceGateStatus", "VOICE_SOURCE_STATUS.md", "rvc_voice_base_status.json", "CI_ACCOUNT_BLOCK_EXCEPTION_TEMPLATE.json", "completed only in a real evidence packet", "reduced_motion_on", "[face] reduced_motion=1", "Assert-ReleasePublishBranchGuard", "Check release publish branch guard", "-PushCurrentBranch", "before creating/uploading release assets")) {
  if ($preflightText -notmatch [regex]::Escape($pattern)) {
    throw "tools/run_device_preflight.ps1 missing required preflight self-test: $pattern"
  }
}

$sensorAdapterText = Get-Content -LiteralPath (Join-PackagePath "provenance/src/io/SensorAdapter.cpp") -Raw
foreach ($pattern in @("[control] help: status", "motion stop|resume", "servos off|on", "demo off|on", "safe stop|panic", "safe resume|restore", "ambient <lux> <hour>", "time <0-23>", "command <1-5|go_to_sleep|wake_up|look_at_me|stop_moving|how_do_you_feel>", "bridge hello|listening|thinking|response|audio|end|error", "uplink start <seq>", "uplink chunk <seq>", "uplink abort", "facepos x=<..> y=<..> s=<..>", "facelost", "sound dir=<deg> level=<0.0-1.0>", "noise level=<0.0-1.0>", "touch cheek|forehead", "pickup [strength]", "shake [strength]", "putdown", "tilt <x> <y> <z>", "fillStatus", "fillMotionEnable", "fillDemoEnable", "fillSafeStop", "fillSafeResume", "fillAmbient", "fillCircadian", "fillCommandEvent", "fillBridgeControl", "fillBridgeUpload", "parseUplinkWakeToken", "hasBridge", "hasBridgeUpload", "bridge_control", "bridge_uplink", "fillVisionEvent", "fillAudioEvent", "fillPhysicalEvent", "parsePayloadValue", "parseAzimuthDeg", "PickedUp", "Shaken", "PutDown", "Tilted", "SoundDirection", "LoudNoise", "FaceLost", "face_position", "face_lost", "CommandMap::fromToken", "hasSpeechCue", "speechCue", "event_shaken_hold", "event_put_down_resume", "sound_direction", "loud_noise", "proximity_near", "touch_payload", "parseLux", "parseHour", "wantsStatus", "hasMotionEnable", "motionEnabled", "hasDemoEnable", "demoEnabled", "hasAmbient", "hasCircadian", "status", "telemetry", "health", "reduced on|off", "motion reduced on|off", "reduced_motion_on", "reduced_motion_off", "motion_stop", "motion_resume", "demo_off", "demo_on", "safe_stop", "safe_resume", "ambient_context", "circadian_context", "parseOnOff", "hasReducedMotion")) {
  if ($sensorAdapterText -notmatch [regex]::Escape($pattern)) {
    throw "provenance/src/io/SensorAdapter.cpp missing bench serial command support: $pattern"
  }
}

$commandMapText = Get-Content -LiteralPath (Join-PackagePath "provenance/src/persona/CommandMap.cpp") -Raw
foreach ($pattern in @("CommandMap::fromPhraseId", "CommandMap::fromToken", "CommandMap::map", "ackCue", "GoToSleep", "WakeUp", "LookAtMe", "StopMoving", "HowDoYouFeel", "EventType::IdleTimeout", "EventType::WakeWord", "EventType::FaceDetected", "EventType::ResponseStarted", "hasMotionEnable", "motionEnabled", "hasSpeechCue", "SpeechEarcon::Safety", "Motion hold active", "command_stop_moving")) {
  if ($commandMapText -notmatch [regex]::Escape($pattern)) {
    throw "provenance/src/persona/CommandMap.cpp missing P4 command-map support: $pattern"
  }
}

$commandsYamlText = Get-Content -LiteralPath (Join-PackagePath "data/commands.yaml") -Raw
foreach ($pattern in @("engine: esp-sr-multinet", "go_to_sleep", "wake_up", "look_at_me", "stop_moving", "how_do_you_feel")) {
  if ($commandsYamlText -notmatch [regex]::Escape($pattern)) {
    throw "data/commands.yaml missing P4 command grammar: $pattern"
  }
}
Assert-File "provenance/data/commands.yaml" 200

$gazeTrackerText = Get-Content -LiteralPath (Join-PackagePath "provenance/src/persona/GazeTracker.cpp") -Raw
foreach ($pattern in @("GazeTracker::applyEvent", "GazeTracker::apply", "EventType::FaceDetected", "EventType::FaceLost", "lastSeenMs_", "presence", "targetX", "targetY", "reducedMotion", "yawDeg", "pitchDeg")) {
  if ($gazeTrackerText -notmatch [regex]::Escape($pattern)) {
    throw "provenance/src/persona/GazeTracker.cpp missing P5 gaze-tracker support: $pattern"
  }
}

$cameraAdapterText = Get-Content -LiteralPath (Join-PackagePath "provenance/src/io/CameraAdapter.cpp") -Raw
foreach ($pattern in @("CameraAdapter::begin", "CameraAdapter::submitFace", "CameraAdapter::submitFaceLost", "CameraAdapter::poll", "STACKCHAN_ENABLE_CAMERA", "EventType::FaceDetected", "EventType::FaceLost", "eventsPublished", "lastEventMs")) {
  if ($cameraAdapterText -notmatch [regex]::Escape($pattern)) {
    throw "provenance/src/io/CameraAdapter.cpp missing P5 camera-adapter support: $pattern"
  }
}

$audioCaptureHeaderText = Get-Content -LiteralPath (Join-PackagePath "provenance/src/io/AudioCaptureAdapter.hpp") -Raw
foreach ($pattern in @("STACKCHAN_ENABLE_MIC_CAPTURE", "AudioCaptureConfig", "AudioCaptureTelemetry", "AudioCaptureSource", "M5MicAudioCaptureSource", "AudioCaptureAdapter", "kAudioCaptureSampleRate", "kAudioCaptureWindowSamples", "lastPcmWindow", "lastPcmSampleCount")) {
  if ($audioCaptureHeaderText -notmatch [regex]::Escape($pattern)) {
    throw "provenance/src/io/AudioCaptureAdapter.hpp missing P3 mic capture adapter contract: $pattern"
  }
}

$audioCaptureText = Get-Content -LiteralPath (Join-PackagePath "provenance/src/io/AudioCaptureAdapter.cpp") -Raw
foreach ($pattern in @("AudioCaptureAdapter::begin", "AudioCaptureAdapter::poll", "AudioCaptureAdapter::stop", "AudioCaptureAdapter::configured", "M5MicAudioCaptureSource::begin", "M5.Mic.begin", "M5.Mic.record", "makeAudioSaliencySample", "AudioReflexEvent", "mic_capture_disabled", "mic_capture_bad_config", "mic_begin_failed")) {
  if ($audioCaptureText -notmatch [regex]::Escape($pattern)) {
    throw "provenance/src/io/AudioCaptureAdapter.cpp missing P3 mic capture adapter support: $pattern"
  }
}

$bridgeAudioUplinkHeaderText = Get-Content -LiteralPath (Join-PackagePath "provenance/src/io/BridgeAudioUplink.hpp") -Raw
foreach ($pattern in @("STACKCHAN_ENABLE_BRIDGE_AUDIO_UPLINK", "BridgeAudioUplinkConfig", "BridgeAudioUplinkTelemetry", "wakeGateRequired", "maxChunkBytes", "turnsStarted", "gateBlocks", "queueFailures", "BridgeAudioUplink")) {
  if ($bridgeAudioUplinkHeaderText -notmatch [regex]::Escape($pattern)) {
    throw "provenance/src/io/BridgeAudioUplink.hpp missing P7 wake-gated uplink contract: $pattern"
  }
}

$bridgeWakeGateHeaderText = Get-Content -LiteralPath (Join-PackagePath "provenance/src/io/BridgeWakeGate.hpp") -Raw
foreach ($pattern in @("BridgeWakeGateConfig", "BridgeWakeGateTelemetry", "gateOpenMs", "maxTurnMs", "gatesOpened", "turnsStarted", "suppressedStarts", "BridgeWakeGate")) {
  if ($bridgeWakeGateHeaderText -notmatch [regex]::Escape($pattern)) {
    throw "provenance/src/io/BridgeWakeGate.hpp missing P7 wake-gate controller contract: $pattern"
  }
}

$bridgeClientText = Get-Content -LiteralPath (Join-PackagePath "provenance/src/io/BridgeClient.cpp") -Raw
foreach ($pattern in @("BridgeClient::begin", "BridgeClient::update", "BridgeClient::submitControlLine", "BridgeClient::submitBinaryFrame", "BridgeClient::poll", "BridgeClientState::Thinking", "BridgeClientOutputType::ResponseStart", "BridgeClientOutputType::AudioFrame", "BridgeClientOutputType::AudioStreamChunk", "stackchan.bridge.v1", "failAudioStream", "binary_without_audio_stream", "audio_stream_payload_bytes_mismatch", "audio_stream_chunk_too_large", "kBridgeAudioStreamChunkPayloadMax", "outputPayloads_", "payloadBytes", "std::memcpy", "failTimeout", "bridge_timeout", "parseErrors", "timeouts", "heartbeats")) {
  if ($bridgeClientText -notmatch [regex]::Escape($pattern)) {
    throw "provenance/src/io/BridgeClient.cpp missing P7 bridge-client support: $pattern"
  }
}

$bridgeWebSocketTransportText = Get-Content -LiteralPath (Join-PackagePath "provenance/src/io/BridgeWebSocketTransport.cpp") -Raw
foreach ($pattern in @("BridgeWebSocketTransport::buildHandshakeRequest", "BridgeWebSocketTransport::acceptHandshakeResponse", "BridgeWebSocketTransport::encodeClientTextFrame", "BridgeWebSocketTransport::encodeClientBinaryFrame", "BridgeWebSocketTransport::submitBytes", "BridgeWebSocketTransport::attachEndpointControl", "BridgeWebSocketTransport::hasPendingTextResponse", "BridgeWebSocketTransport::popPendingTextResponse", "BridgeWebSocketTransport::encodePendingTextResponseFrame", "BridgeWebSocketTransport::routeTextFrame", "BridgeWebSocketTransport::queuePendingTextResponse", "endpointControlFrames", "endpointControlResponsesQueued", "outgoingTextFramesEncoded", "submitControlLine", "submitBinaryFrame", "Sec-WebSocket-Key", "Sec-WebSocket-Accept", "masked_server_websocket_frame", "websocket_payload_too_large", "kBridgeWebSocketFramePayloadMax", "BridgeWebSocketTransportState::Connected", "BridgeWebSocketTransportState::Closed")) {
  if ($bridgeWebSocketTransportText -notmatch [regex]::Escape($pattern)) {
    throw "provenance/src/io/BridgeWebSocketTransport.cpp missing firmware WebSocket transport support: $pattern"
  }
}

$bridgeSocketWriterText = Get-Content -LiteralPath (Join-PackagePath "provenance/src/io/BridgeSocketWriter.cpp") -Raw
foreach ($pattern in @("BridgeSocketWriter::begin", "BridgeSocketWriter::queueTextFrame", "BridgeSocketWriter::queueBinaryFrame", "BridgeSocketWriter::drainPendingFrame", "BridgeSocketWriter::drainPendingTextResponse", "BridgeSocketWriter::nextMaskWord", "BridgeSocketWriter::makeMask", "BridgeSocketWriterDrainResult::Partial", "BridgeSocketWriterDrainResult::NotConnected", "frameBuffered", "textFrameQueued", "binaryFrameQueued", "framesEncoded", "framesWritten", "textFramesQueued", "textFramesDropped", "textFramesEncoded", "textFramesWritten", "binaryFramesQueued", "binaryFramesDropped", "binaryFramesEncoded", "binaryFramesWritten", "partialWrites", "writeFailures", "textBytesQueued", "textBytesWritten", "binaryBytesQueued", "binaryBytesWritten", "encodePendingTextResponseFrame", "encodeClientTextFrame", "encodeClientBinaryFrame", "socket_text_queue_full", "socket_binary_queue_full", "socket_write_failed")) {
  if ($bridgeSocketWriterText -notmatch [regex]::Escape($pattern)) {
    throw "provenance/src/io/BridgeSocketWriter.cpp missing firmware socket-writer support: $pattern"
  }
}

$bridgeNetworkSessionText = Get-Content -LiteralPath (Join-PackagePath "provenance/src/io/BridgeNetworkSession.cpp") -Raw
foreach ($pattern in @("BridgeNetworkSession::begin", "BridgeNetworkSession::start", "BridgeNetworkSession::update", "BridgeNetworkSession::queueTextFrame", "BridgeNetworkSession::queueBinaryFrame", "BridgeNetworkSession::openSocket", "BridgeNetworkSession::sendHandshake", "BridgeNetworkSession::readHandshake", "BridgeNetworkSession::readConnected", "BridgeNetworkSession::drainWriter", "BridgeNetworkSession::scheduleReconnect", "BridgeNetworkSessionState::Connected", "BridgeWebSocketTransport::buildHandshakeRequest", "transport_.submitBytes", "writer_.drainPendingFrame", "writerTextFrames", "writerBinaryFrames", "tcp_connect_failed", "handshake_timeout", "websocket_closed")) {
  if ($bridgeNetworkSessionText -notmatch [regex]::Escape($pattern)) {
    throw "provenance/src/io/BridgeNetworkSession.cpp missing firmware LAN session support: $pattern"
  }
}

$bridgeWifiClientSocketText = Get-Content -LiteralPath (Join-PackagePath "provenance/src/io/BridgeWiFiClientSocket.cpp") -Raw
foreach ($pattern in @("BridgeWiFiClientSocket::connect", "BridgeWiFiClientSocket::isConnected", "BridgeWiFiClientSocket::available", "BridgeWiFiClientSocket::read", "BridgeWiFiClientSocket::write", "BridgeWiFiClientSocket::stop", "ARDUINO_ARCH_ESP32", "client_.connect", "client_.write")) {
  if ($bridgeWifiClientSocketText -notmatch [regex]::Escape($pattern)) {
    throw "provenance/src/io/BridgeWiFiClientSocket.cpp missing ESP32 WiFiClient bridge support: $pattern"
  }
}

$bridgeWifiProvisionerHeaderText = Get-Content -LiteralPath (Join-PackagePath "provenance/src/io/BridgeWiFiProvisioner.hpp") -Raw
foreach ($pattern in @("STACKCHAN_ENABLE_WIFI_BRIDGE", "STACKCHAN_WIFI_SSID", "STACKCHAN_WIFI_PASSWORD", "STACKCHAN_BRIDGE_HOST", "STACKCHAN_BRIDGE_PORT", "STACKCHAN_BRIDGE_PATH", "STACKCHAN_BRIDGE_WS_KEY", "BridgeWiFiProvisioningConfig", "BridgeWiFiProvisioningTelemetry", "BridgeWiFiProvisioner")) {
  if ($bridgeWifiProvisionerHeaderText -notmatch [regex]::Escape($pattern)) {
    throw "provenance/src/io/BridgeWiFiProvisioner.hpp missing firmware Wi-Fi provisioning support: $pattern"
  }
}

$bridgeWifiProvisionerText = Get-Content -LiteralPath (Join-PackagePath "provenance/src/io/BridgeWiFiProvisioner.cpp") -Raw
foreach ($pattern in @("BridgeWiFiProvisioner::begin", "BridgeWiFiProvisioner::update", "BridgeWiFiProvisioner::isConfigured", "BridgeWiFiProvisioner::networkSessionConfig", "BridgeWiFiProvisioner::startAttempt", "BridgeWiFiProvisioner::scheduleRetry", "WiFi.begin", "WiFi.disconnect", "wifi_connect_timeout", "wifi_bridge_disabled", "wifi_bridge_not_configured")) {
  if ($bridgeWifiProvisionerText -notmatch [regex]::Escape($pattern)) {
    throw "provenance/src/io/BridgeWiFiProvisioner.cpp missing firmware Wi-Fi provisioning support: $pattern"
  }
}

$bridgeEndpointRegistryText = Get-Content -LiteralPath (Join-PackagePath "provenance/src/io/BridgeEndpointRegistry.cpp") -Raw
foreach ($pattern in @("BridgeEndpointRegistry::upsertEndpoint", "BridgeEndpointRegistry::restoreEndpoint", "BridgeEndpointRegistry::forgetEndpoint", "BridgeEndpointRegistry::markHeartbeat", "BridgeEndpointRegistry::markDisconnected", "BridgeEndpointRegistry::claimOwner", "BridgeEndpointRegistry::releaseOwner", "BridgeEndpointRegistry::updateCapabilities", "BridgeEndpointRegistry::chooseBestHealthyOwner", "kBridgeEndpointMax", "ownerHeartbeatTimeoutMs", "autoConnect", "ownerExpirations", "explicitClaims", "forgotten", "restores")) {
  if ($bridgeEndpointRegistryText -notmatch [regex]::Escape($pattern)) {
    throw "provenance/src/io/BridgeEndpointRegistry.cpp missing firmware endpoint registry support: $pattern"
  }
}

$bridgeEndpointControlText = Get-Content -LiteralPath (Join-PackagePath "provenance/src/io/BridgeEndpointControl.cpp") -Raw
foreach ($pattern in @("BridgeEndpointControl::submitControlLine", "BridgeEndpointControl::attachStore", "BridgeEndpointControl::persistRegistry", "BridgeEndpointControl::handleEndpointHello", "BridgeEndpointControl::handleHeartbeat", "BridgeEndpointControl::handleClaimBrain", "BridgeEndpointControl::handleReleaseBrain", "BridgeEndpointControl::handleForgetEndpoint", "BridgeEndpointControl::handleCapabilityUpdate", "BridgeEndpointControl::writeTrustedEndpoints", "BridgeEndpointControl::writeCapabilities", "deserializeJson", "endpoint_hello_result", "claim_brain", "release_brain", "owner_status", "trusted_endpoints_result", "forget_endpoint_result", "capability_update_result", "endpoint_persist_failed", "persistenceSaves", "BridgeEndpointCapabilityModelProfiles", "BridgeEndpointCapabilityDiagnostics", "BridgeEndpointCapabilityPcm16Upload")) {
  if ($bridgeEndpointControlText -notmatch [regex]::Escape($pattern)) {
    throw "provenance/src/io/BridgeEndpointControl.cpp missing firmware endpoint control support: $pattern"
  }
}

$bridgeEndpointStoreText = Get-Content -LiteralPath (Join-PackagePath "provenance/src/io/BridgeEndpointStore.cpp") -Raw
foreach ($pattern in @("BridgeEndpointStore::save", "BridgeEndpointStore::load", "BridgeEndpointStore::clear", "BridgeEndpointMemoryStore::write", "BridgeEndpointPreferencesStore::begin", "BridgeEndpointPreferencesStore::clear", "Preferences", "stackchan.bridge-endpoints.v1", "restoreEndpoint", "kBridgeEndpointStoreJsonMax", "endpointsSaved", "endpointsLoaded")) {
  if ($bridgeEndpointStoreText -notmatch [regex]::Escape($pattern)) {
    throw "provenance/src/io/BridgeEndpointStore.cpp missing firmware endpoint persistence support: $pattern"
  }
}

$bridgeAudioDownlinkText = Get-Content -LiteralPath (Join-PackagePath "provenance/src/io/BridgeAudioDownlink.cpp") -Raw
foreach ($pattern in @("BridgeAudioDownlink::begin", "BridgeAudioDownlink::start", "BridgeAudioDownlink::submitChunk", "BridgeAudioDownlink::end", "BridgeAudioDownlink::abort", "BridgeAudioDownlinkSink", "startPlayback", "submitPlaybackChunk", "stopPlayback", "isPlayablePcm16Format", "playbackReady", "playbackStarts", "playbackChunks", "playbackBytes", "playbackUnsupported", "playbackErrors", "kBridgeAudioStreamChunkPayloadMax", "payloadBytes", "chunksAccepted", "bytesAccepted", "streamsCompleted", "streamsAborted", "updateChecksum")) {
  if ($bridgeAudioDownlinkText -notmatch [regex]::Escape($pattern)) {
    throw "provenance/src/io/BridgeAudioDownlink.cpp missing P7 downlink-consumer support: $pattern"
  }
}

$bridgeAudioUplinkText = Get-Content -LiteralPath (Join-PackagePath "provenance/src/io/BridgeAudioUplink.cpp") -Raw
foreach ($pattern in @("BridgeAudioUplink::begin", "BridgeAudioUplink::beginTurn", "BridgeAudioUplink::submitPcmChunk", "BridgeAudioUplink::submitPcmBytes", "BridgeAudioUplink::endTurn", "BridgeAudioUplink::abort", "wake_gate_closed", "utterance_start", "utterance_end", "queueTextFrame", "queueBinaryFrame", "audio_uplink_disabled", "audio_uplink_chunk_too_large", "audio_chunk_queue_failed")) {
  if ($bridgeAudioUplinkText -notmatch [regex]::Escape($pattern)) {
    throw "provenance/src/io/BridgeAudioUplink.cpp missing P7 wake-gated uplink controller support: $pattern"
  }
}

$bridgeWakeGateText = Get-Content -LiteralPath (Join-PackagePath "provenance/src/io/BridgeWakeGate.cpp") -Raw
foreach ($pattern in @("BridgeWakeGate::begin", "BridgeWakeGate::applyEvent", "BridgeWakeGate::update", "BridgeWakeGate::isGateOpen", "EventType::WakeWord", "EventType::UserSpeaking", "EventType::SpeechEnded", "beginTurn", "endTurn", "bridge_wake_gate_uplink_unavailable", "bridge_wake_gate_timeout", "bridge_wake_gate_max_turn")) {
  if ($bridgeWakeGateText -notmatch [regex]::Escape($pattern)) {
    throw "provenance/src/io/BridgeWakeGate.cpp missing P7 wake-gate controller support: $pattern"
  }
}

$earconSynthText = Get-Content -LiteralPath (Join-PackagePath "provenance/src/persona/EarconSynth.cpp") -Raw
foreach ($pattern in @("PersonaEarcons.hpp", "generated_persona::kUsePersonaEarconPatterns", "generated_persona::earconPatternFor", "renderPattern", "durationForPattern", "EarconSynth::render", "EarconSynth::expectedDurationMs", "SpeechEarcon::Wake", "SpeechEarcon::Confirm", "SpeechEarcon::Think", "SpeechEarcon::Happy", "SpeechEarcon::Concern", "SpeechEarcon::Sleep", "SpeechEarcon::Error", "SpeechEarcon::Safety", "checksum", "truncated", "sinf")) {
  if ($earconSynthText -notmatch [regex]::Escape($pattern)) {
    throw "provenance/src/persona/EarconSynth.cpp missing P6 earcon synth support: $pattern"
  }
}

$audioOutText = Get-Content -LiteralPath (Join-PackagePath "provenance/src/io/AudioOut.cpp") -Raw
foreach ($pattern in @("AudioOut::begin", "AudioOut::enqueue", "AudioOut::pollSpeechFrame", "AudioOut::duck", "startHardwarePlayback", "submitHardwareFrame", "stopHardwarePlayback", "AudioOutSpeakerSink", "hardwareReady", "hardwareStarts", "hardwareFramesSubmitted", "hardwareFrameDrops", "resolveSidecar", "envelopeForFrame", "visemeForFrame", "requestsQueued", "requestsDropped", "speechFramesEmitted", "duckEvents", "lastSidecarPath", "taskPinnedToCore0")) {
  if ($audioOutText -notmatch [regex]::Escape($pattern)) {
    throw "provenance/src/io/AudioOut.cpp missing P6 audio-output scaffold support: $pattern"
  }
}

$speechPromptBankText = Get-Content -LiteralPath (Join-PackagePath "provenance/src/io/SpeechPromptBank.cpp") -Raw
foreach ($pattern in @("PersonaPromptAssets.hpp", "SpeechPromptBank::find", "SpeechPromptBank::assets", "generated_persona::kPromptAssets", "generated_persona::kPromptAssetCount")) {
  if ($speechPromptBankText -notmatch [regex]::Escape($pattern)) {
    throw "provenance/src/io/SpeechPromptBank.cpp missing P6 prompt-bank support: $pattern"
  }
}

$speechAdapterText = Get-Content -LiteralPath (Join-PackagePath "provenance/src/io/SpeechAdapter.cpp") -Raw
foreach ($pattern in @("SpeechAdapter::begin", "SpeechAdapter::handleCue", "SpeechPromptBank::find", "AudioOutPlaybackRequest", "audioOut_->enqueue", "promptWavPath", "promptSidecarPath", "EarconSynth::render", "earconIntensity", "cuesQueued", "earconsRendered", "lastEarconChecksum")) {
  if ($speechAdapterText -notmatch [regex]::Escape($pattern)) {
    throw "provenance/src/io/SpeechAdapter.cpp missing P6 speech-adapter support: $pattern"
  }
}

$mainText = Get-Content -LiteralPath (Join-PackagePath "provenance/src/main.cpp") -Raw
foreach ($pattern in @("gFaceControlQueue", "gMotionControlQueue", "FaceControlInput", "MotionControlInput", "publishFaceControl", "publishMotionControl", "applyFaceControlInput", "applyMotionControlInput", "publishAudioOutSpeechFrame", "publishBridgeSpeechFrame", "handleBridgeOutput", "pollBridgeOutputs", "BridgeClient", "BridgeAudioDownlink", "BridgeAudioDownlinkSink", "BridgeAudioUplink", "BridgeWakeGate", "BridgeEndpointRegistry", "BridgeEndpointControl", "BridgeEndpointStore", "BridgeWiFiProvisioner", "BridgeNetworkSession", "BridgeWiFiClientSocket", "updateBridgeNetwork", "gBridge", "gBridgeAudioDownlink", "gBridgeAudioUplink", "gBridgeWakeGate", "gBridgeEndpointRegistry", "gBridgeEndpointControl", "gBridgeEndpointStore", "gBridgeWiFi", "gBridgeNetworkSession", "gBridge.update", "gBridgeEndpointStore.load", "gBridgeEndpointControl.attachStore", "gBridgeEndpointControl.update", "gBridgeWiFi.begin", "gBridgeNetworkSession.begin", "gBridgeAudioUplink.begin", "gBridgeWakeGate.begin", "gBridgeWakeGate.update", "gBridgeWakeGate.applyEvent", "gBridgeNetworkSession.update", "handleEndpointControlLine", "handleBridgeUplinkBench", "printBridgeUplinkResult", "submitPcmBytes", "beginTurn", "endTurn", "bench_audio_uplink_abort", "bridge_ready=", "bridge_state=", "bridge_messages=", "bridge_outputs=", "bridge_parse_errors=", "bridge_audio_stream_bytes_received=", "bridge_audio_stream_chunks=", "bridge_audio_stream_errors=", "bridge_endpoint_registry_ready=", "bridge_endpoint_count=", "bridge_endpoint_active=", "bridge_endpoint_restores=", "bridge_endpoint_control_ready=", "bridge_endpoint_messages=", "bridge_endpoint_rejected=", "bridge_endpoint_persistence_saves=", "bridge_endpoint_persistence_errors=", "bridge_endpoint_store_ready=", "bridge_endpoint_store_loads=", "bridge_endpoint_store_saves=", "bridge_endpoint_store_loaded=", "bridge_endpoint_store_saved=", "bridge_endpoint_store_parse_errors=", "bridge_endpoint_store_write_errors=", "bridge_wifi_ready=", "bridge_wifi_configured=", "bridge_wifi_connected=", "bridge_network_state=", "bridge_network_writer_frames=", "bridge_network_writer_text_frames=", "bridge_network_writer_binary_frames=", "bridge_network_text_queued=", "bridge_network_text_dropped=", "bridge_network_binary_queued=", "bridge_network_binary_dropped=", "bridge_downlink_ready=", "bridge_downlink_active=", "bridge_downlink_streams=", "bridge_downlink_completed=", "bridge_downlink_chunks=", "bridge_downlink_bytes=", "bridge_downlink_errors=", "bridge_downlink_playback_ready=", "bridge_downlink_playback_active=", "bridge_downlink_playback_starts=", "bridge_downlink_playback_chunks=", "bridge_downlink_playback_bytes=", "bridge_downlink_playback_unsupported=", "bridge_downlink_playback_errors=", "bridge_uplink_ready=", "bridge_uplink_enabled=", "bridge_uplink_active=", "bridge_uplink_wake_gate_required=", "bridge_uplink_turns=", "bridge_uplink_completed=", "bridge_uplink_chunks=", "bridge_uplink_bytes=", "bridge_uplink_errors=", "bridge_uplink_gate_blocks=", "bridge_uplink_queue_failures=", "bridge_wake_gate_ready=", "bridge_wake_gate_open=", "bridge_wake_gate_turn_active=", "bridge_wake_gate_opens=", "bridge_wake_gate_completed=", "bridge_timeouts=", "[bridge]", "[bridge_uplink]", "[endpoint]", "audio_stream_chunk", "chunk_index=", "chunk_bytes=", "payload_bytes=", "received_bytes=", "M5SpeakerAudioSink", "FirmwareVoiceAssets.hpp", "firmware_voice::find", "M5.Speaker.playWav", "M5.Speaker.playRaw", "STACKCHAN_ENABLE_SPEAKER", "gAudioOut.pollSpeechFrame", "gAudioOut.duck", "gFace.setReducedMotion", "gIntent.setReducedMotion", "gIntent.queueSpeechCue", "gIntent.applyAmbient", "gIntent.applyCircadian", "gActuation.setEnabled", "gIntent.setDemoEnabled", "gActuation.isEnabled", "gIntent.isDemoEnabled", "gFace.isReducedMotion", "gFace.speechTelemetry", "gCamera", "gCamera.poll", "gAudioOut", "gSpeechAdapter", "gSpeechAdapter.handleCue", "printSpeechPlayback", "printAudioOutPlayback", "[speech_audio]", "[audio_out]", "prompt_wav=", "prompt_sidecar=", "audio_out_ready=", "audio_out_hw_ready=", "audio_out_requests=", "audio_out_playing=", "audio_out_frames=", "audio_out_hw_frames=", "audio_out_hw_drops=", "sidecar_frames=", "playback_ms=", "hw_ready=", "hw_playing=", "hw_starts=", "earcon_checksum=", "speech_adapter_ready=", "speech_adapter_hw=", "speech_cues=", "speech_earcons=", "printVisionTelemetry", "[vision] event=", "camera_ready=", "camera_hw=", "camera_active=", "camera_events=", "payload_x=", "payload_y=", "payload_z=", "cue_intent=", "cue_earcon=", "picked_up", "shaken", "put_down", "tilted", "sound_direction", "loud_noise", "printAudioTelemetry", "[audio] event=", "detect_ms=", "frame_ms=", "latency_ms=", "azimuth_deg=", "reduced_motion=", "motion_enabled=", "demo_enabled", "ambient_lux=", "circadian_hour=", "hour=", "speech_active=", "[runtime]", "[motion] requested=", "wantsStatus", "printHeartbeat", "printSystemTelemetry", "printRuntimeStatus")) {
  if ($mainText -notmatch [regex]::Escape($pattern)) {
    throw "provenance/src/main.cpp missing bench control support: $pattern"
  }
}
$singleOwnerCalls = [ordered]@{
  'updateBridgeNetwork\s*\(' = 2
  'pollBridgeOutputs\s*\(' = 4
  'pollBridgeDebugServer\s*\(' = 2
  'ensureWakeSrStarted\s*\(' = 2
}
foreach ($entry in $singleOwnerCalls.GetEnumerator()) {
  $actualCount = [regex]::Matches($mainText, $entry.Key).Count
  if ($actualCount -ne $entry.Value) {
    throw "provenance/src/main.cpp violates single-owner bridge runtime contract for $($entry.Key): expected $($entry.Value), found $actualCount"
  }
}
foreach ($pattern in @("submitCapturedAudioWindowToBridgeUplink", "lastPcmWindow", "lastPcmSampleCount", "submitPcmChunk", "audioWindowsBefore")) {
  if ($mainText -notmatch [regex]::Escape($pattern)) {
    throw "provenance/src/main.cpp missing mic capture to uplink handoff support: $pattern"
  }
}
foreach ($pattern in @("AudioCaptureAdapter", "M5MicAudioCaptureSource", "gAudioCapture", "gAudioCapture.begin", "gAudioCapture.poll", "audio_capture_ready=", "audio_capture_enabled=", "audio_capture_hw_ready=", "audio_capture_windows=", "audio_capture_drops=", "audio_capture_events=", "audio_capture_level=", "audio_capture_zcr=")) {
  if ($mainText -notmatch [regex]::Escape($pattern)) {
    throw "provenance/src/main.cpp missing mic capture boot wiring: $pattern"
  }
}

$audioSaliencyText = Get-Content -LiteralPath (Join-PackagePath "provenance/src/persona/AudioSaliency.cpp") -Raw
foreach ($pattern in @("makeAudioSaliencySample", "zeroCrossingRate", "AudioReflex::process", "AudioReflexTelemetry", "EventType::UserSpeaking", "EventType::SpeechEnded", "EventType::SoundDirection", "EventType::LoudNoise", "audio_user_speaking", "audio_speech_ended", "audio_sound_direction", "audio_loud_noise", "habituation", "noiseFloor")) {
  if ($audioSaliencyText -notmatch [regex]::Escape($pattern)) {
    throw "provenance/src/persona/AudioSaliency.cpp missing P3 audio reflex support: $pattern"
  }
}
foreach ($fixture in @("speech_right.wav", "speech_left.wav", "music_center.wav", "fan_noise.wav")) {
  Assert-File "provenance/test/fixtures/audio/$fixture" 1024
}

$nativeToolchainCheckerText = Get-Content -LiteralPath (Join-PackagePath "tools/check_native_toolchain.ps1") -Raw
foreach ($pattern in @("stackchan.native-toolchain-check.v1", "Get-StackchanNativeCompilerDirs", "Add-StackchanNativeCompilerToPath", "winget install BrechtSanders.WinLibs.POSIX.UCRT", "Candidate directories")) {
  if ($nativeToolchainCheckerText -notmatch [regex]::Escape($pattern)) {
    throw "tools/check_native_toolchain.ps1 missing native toolchain diagnostic logic: $pattern"
  }
}

$androidToolchainCheckerText = Get-Content -LiteralPath (Join-PackagePath "tools/check_android_toolchain.ps1") -Raw
foreach ($pattern in @("stackchan.android-toolchain-check.v1", "JAVA_HOME", "java.exe", "ANDROID_HOME", "ANDROID_SDK_ROOT", "platform-tools", "adb.exe", "platforms/android-36", "companion/gradlew.bat", "Install JDK 21", "Android SDK Platform 36", "sdkmanager")) {
  if ($androidToolchainCheckerText -notmatch [regex]::Escape($pattern)) {
    throw "tools/check_android_toolchain.ps1 missing Android toolchain diagnostic logic: $pattern"
  }
}

$androidPlayReadinessCheckerText = Get-Content -LiteralPath (Join-PackagePath "tools/check_android_play_release_readiness.ps1") -Raw
foreach ($pattern in @("stackchan.android-play-release-readiness.v1", "Play high-resolution icon", "Gradle Play upload signing inputs", "stackchan.allowLabDebugReleaseSigning", "Release tasks fail closed", "keytool private-key validation", "RSACertificateExtensions", "project policy requires at least 4096 bits", "2033-10-23 UTC", "certificate SHA-256", "CI builds Android release bundle", "CI runs Android emulator launch smoke", "Tag release validates upload key and exact release APK launch", "system-images;android-35;aosp_atd;x86_64", "test_android_emulator_launch.ps1", "RequireAndroidEmulatorEvidence", "Release evidence covers AAB signing", "play-store-evidence-checker", "applicationId", "play-listing-full-description", "Gemma-4-E2B", "raw microphone audio is not stored")) {
  if ($androidPlayReadinessCheckerText -notmatch [regex]::Escape($pattern)) {
    throw "tools/check_android_play_release_readiness.ps1 missing Android Play release readiness logic: $pattern"
  }
}

$androidPlayStoreEvidenceCheckerText = Get-Content -LiteralPath (Join-PackagePath "tools/check_android_play_store_evidence.ps1") -Raw
foreach ($pattern in @("stackchan.android-play-store-evidence.v1", "play-internal-testing-ready", "internal-testing-ready", "applicationId", "releaseAabSha256", "releaseAabSha256 =", "versionName =", "versionCode =", "playSigningEnabled", "playConsoleReleaseName", "testerGroup", "uploadedAtUtc", "play-console-release", "tester-group", "uploaded-at-utc", "internalTestingInstallStatus", "screenshots", "sourceCommit for", "appVersion for", "Source commit:", "App version:", "Decision: pass", "DATA_SAFETY_REVIEW.md", "POLICY_REVIEW.md")) {
  if ($androidPlayStoreEvidenceCheckerText -notmatch [regex]::Escape($pattern)) {
    throw "tools/check_android_play_store_evidence.ps1 missing Android Play Store evidence logic: $pattern"
  }
}

$androidV1BundleCheckerText = Get-Content -LiteralPath (Join-PackagePath "tools/check_android_v1_evidence_bundle.ps1") -Raw
foreach ($pattern in @("stackchan.android-v1-evidence-bundle.v1", "android-v1-evidence-ready", "pending-android-v1-evidence-bundle", "stackchan.android-apk-install.v1", "android-speech-ready", "android-controls-ready", "android-pairing-ready", "android-wifi-ready", "android-gemma-real-device-ready", "android-screen-off-soak-ready", "play-internal-testing-ready", "sourceCommit", "expectedSourceCommit", "applicationId", "packageName", "apkSha256", "versionName", "versionCode", "releaseAabSha256", "gemmaBenchmarkProfile", "gemma-benchmark-profile", "gemma-benchmark-speed", "benchmarkMedianMs", "gemma4-e2b-litert-lm", "androidDashboardEvidenceRoot", "androidDashboardMedia", "androidDashboardMediaIds", "dashboard-evidence", "phone-live-dashboard", "Connected dashboard media decision", "companion-readiness-source-commit-match", "apk-install-source-commit-match", "diagnostics-expected-source-commit-match", "speech-expected-source-commit-match", "controls-expected-source-commit-match", "pairing-expected-source-commit-match", "wifi-expected-source-commit-match", "gemma-expected-source-commit-match", "screen-off-soak-expected-source-commit-match", "apk-install-application-id-match", "play-store-application-id-match", "speech-source-commit-match", "screen-off-soak-source-commit-match", "play-store-source-commit-match", "play-store-version-name-match", "play-store-version-code-match", "Get-AndroidSourceApplicationId", "Get-ReviewSourceCommit", "Source commit:", "ANDROID_V1_REVIEW.md", "RequireReady")) {
  if ($androidV1BundleCheckerText -notmatch [regex]::Escape($pattern)) {
    throw "tools/check_android_v1_evidence_bundle.ps1 missing Android v1 evidence bundle logic: $pattern"
  }
}

$androidV1BundleContractText = Get-Content -LiteralPath (Join-PackagePath "tools/test_android_v1_evidence_bundle_contract.ps1") -Raw
foreach ($pattern in @("placeholder Android v1 evidence bundle is pending", "complete Android v1 evidence bundle is accepted", "Android v1 dashboard verified status without media is rejected", "Android v1 dashboard media source commit mismatch is rejected", "mismatched Android v1 companion readiness source commit is rejected", "mismatched Android v1 speech source commit is rejected", "Android v1 evidence without strict SourceCommit pin is rejected", "Android v1 Gemma report without benchmark fields is rejected", "Android v1 Gemma report with slow benchmark fields is rejected", "mismatched Android v1 Play Store source commit is rejected", "mismatched Android v1 APK install packageName is rejected", "mismatched Android v1 Play Store applicationId is rejected", "mismatched Android v1 review source commit is rejected", "Gemma benchmark profile and speed evidence", "dashboard media IDs", "android-v1-evidence-ready", "pending-android-v1-evidence-bundle", "Android v1 evidence bundle contract tests passed")) {
  if ($androidV1BundleContractText -notmatch [regex]::Escape($pattern)) {
    throw "tools/test_android_v1_evidence_bundle_contract.ps1 missing Android v1 evidence bundle contract coverage: $pattern"
  }
}

$androidDiagnosticsEvidenceCheckerText = Get-Content -LiteralPath (Join-PackagePath "tools/check_android_diagnostics_export_evidence.ps1") -Raw
foreach ($pattern in @("stackchan.android-diagnostics-export-evidence.v1", "stackchan.android.diagnostics-export.v1", "ANDROID_DIAGNOSTICS_EXPORT.json", "ANDROID_DIAGNOSTICS_REVIEW.md", "package_name", "version_code", "app-package-name", "app-version-code", "Get-AndroidSourceIdentity", "password_redacted", "last_text_turn_present", "requires_real_device_inference_evidence", "expectedSourceCommit", "diagnostics-review-source-commit-match", "applicationId", "versionName", "versionCode", "Support decision: pass", "pending-android-diagnostics-export-evidence")) {
  if ($androidDiagnosticsEvidenceCheckerText -notmatch [regex]::Escape($pattern)) {
    throw "tools/check_android_diagnostics_export_evidence.ps1 missing Android diagnostics export evidence logic: $pattern"
  }
}

$androidDiagnosticsEvidenceContractText = Get-Content -LiteralPath (Join-PackagePath "tools/test_android_diagnostics_export_evidence_contract.ps1") -Raw
foreach ($pattern in @("complete Android diagnostics export evidence is accepted", "mismatched Android diagnostics package name is rejected", "mismatched Android diagnostics versionCode is rejected", "stale Android diagnostics review source commit is rejected", "applicationId, versionName, versionCode, and expectedSourceCommit", "Android diagnostics export evidence contract tests passed")) {
  if ($androidDiagnosticsEvidenceContractText -notmatch [regex]::Escape($pattern)) {
    throw "tools/test_android_diagnostics_export_evidence_contract.ps1 missing Android diagnostics export evidence contract coverage: $pattern"
  }
}

$androidSpeechEvidenceCheckerText = Get-Content -LiteralPath (Join-PackagePath "tools/check_android_speech_evidence.ps1") -Raw
foreach ($pattern in @("stackchan.android-speech-evidence.v1", "ANDROID_SPEECH_REVIEW.md", "android_speech_logcat.txt", "robot_speech_serial.log", "stackchan_speech_evidence", "event=final_transcript", "event=submit_result", "accepted=1", "seq_present=1", "message_type=app_text_turn", "transcript_redacted=1", "raw_audio_retention=none", "response_start", "audio_stream_start", "audio_stream_end", "response_end", "Speech recognizer decision: pass", "Transcript submission decision: pass", "Robot response-frame decision: pass", "expectedSourceCommit", "speech-review-source-commit-match", "pending-android-speech-evidence", "android-speech-ready")) {
  if ($androidSpeechEvidenceCheckerText -notmatch [regex]::Escape($pattern)) {
    throw "tools/check_android_speech_evidence.ps1 missing Android speech evidence logic: $pattern"
  }
}

$androidSpeechEvidenceContractText = Get-Content -LiteralPath (Join-PackagePath "tools/test_android_speech_evidence_contract.ps1") -Raw
foreach ($pattern in @("complete Android speech evidence is accepted", "missing Android speech robot response frames remain pending", "Android speech diagnostics transcript privacy leak is rejected", "stale Android speech review source commit is rejected", "Android speech evidence contract tests passed")) {
  if ($androidSpeechEvidenceContractText -notmatch [regex]::Escape($pattern)) {
    throw "tools/test_android_speech_evidence_contract.ps1 missing Android speech evidence contract coverage: $pattern"
  }
}

$androidControlsEvidenceCheckerText = Get-Content -LiteralPath (Join-PackagePath "tools/check_android_controls_evidence.ps1") -Raw
foreach ($pattern in @("stackchan.android-controls-evidence.v1", "ANDROID_CONTROLS_REVIEW.md", "robot_controls_serial.log", "settings_set", "settings_result", "claim_brain", "release_brain", "owner_status", "robot_hello_required", "Settings write decision: pass", "Claim brain decision: pass", "Release brain decision: pass", "Robot hello gate decision: pass", "expectedSourceCommit", "controls-review-source-commit-match", "pending-android-controls-evidence", "android-controls-ready")) {
  if ($androidControlsEvidenceCheckerText -notmatch [regex]::Escape($pattern)) {
    throw "tools/check_android_controls_evidence.ps1 missing Android controls evidence logic: $pattern"
  }
}

$androidControlsEvidenceContractText = Get-Content -LiteralPath (Join-PackagePath "tools/test_android_controls_evidence_contract.ps1") -Raw
foreach ($pattern in @("complete Android controls evidence is accepted", "missing Android controls robot hello gate remains pending", "Android controls non-Android endpoint identity is rejected", "stale Android controls review source commit is rejected", "Android controls evidence contract tests passed")) {
  if ($androidControlsEvidenceContractText -notmatch [regex]::Escape($pattern)) {
    throw "tools/test_android_controls_evidence_contract.ps1 missing Android controls evidence contract coverage: $pattern"
  }
}

$androidPairingEvidenceCheckerText = Get-Content -LiteralPath (Join-PackagePath "tools/check_android_pairing_evidence.ps1") -Raw
foreach ($pattern in @("stackchan.android-pairing-evidence.v1", "ANDROID_PAIRING_REVIEW.md", "robot_pairing_serial.log", "android_pairing_setup.jpg", "pairing_code_present", "stackchan://pair", "pairing_code_mismatch", "bridge_url_applied", "endpoint_hello_result", "trusted_endpoints_result", "Setup media decision: pass", "Wrong-code rejection decision: pass", "QR ticket/manual code decision: pass", "Trusted endpoint decision: pass", "Password privacy decision: pass", "expectedSourceCommit", "pairing-review-source-commit-match", "pending-android-pairing-evidence", "android-pairing-ready")) {
  if ($androidPairingEvidenceCheckerText -notmatch [regex]::Escape($pattern)) {
    throw "tools/check_android_pairing_evidence.ps1 missing Android pairing evidence logic: $pattern"
  }
}

$androidPairingEvidenceContractText = Get-Content -LiteralPath (Join-PackagePath "tools/test_android_pairing_evidence_contract.ps1") -Raw
foreach ($pattern in @("complete Android pairing evidence is accepted", "missing Android pairing wrong-code rejection remains pending", "Android pairing non-Android endpoint identity is rejected", "stale Android pairing review source commit is rejected", "Android pairing evidence contract tests passed")) {
  if ($androidPairingEvidenceContractText -notmatch [regex]::Escape($pattern)) {
    throw "tools/test_android_pairing_evidence_contract.ps1 missing Android pairing evidence contract coverage: $pattern"
  }
}

$androidWifiEvidenceCheckerText = Get-Content -LiteralPath (Join-PackagePath "tools/check_android_wifi_evidence.ps1") -Raw
foreach ($pattern in @("stackchan.android-wifi-evidence.v1", "ANDROID_WIFI_REVIEW.md", "robot_wifi_serial.log", "wifi_provisioning_command_template", "password_redacted", "[wifi]", "persisted=1", "store_has_record=1", "enabled=1", "ssid_set=1", "bridge_wifi_store_loads", "bridge_wifi_store_has_record=1", "wifi clear", "store_has_record=0", "Power-cycle reload decision: pass", "Clear command decision: pass", "expectedSourceCommit", "wifi-review-source-commit-match", "pending-android-wifi-evidence", "android-wifi-ready")) {
  if ($androidWifiEvidenceCheckerText -notmatch [regex]::Escape($pattern)) {
    throw "tools/check_android_wifi_evidence.ps1 missing Android Wi-Fi evidence logic: $pattern"
  }
}

$androidWifiEvidenceContractText = Get-Content -LiteralPath (Join-PackagePath "tools/test_android_wifi_evidence_contract.ps1") -Raw
foreach ($pattern in @("complete Android Wi-Fi evidence is accepted", "missing Android Wi-Fi reload proof remains pending", "Android Wi-Fi robot log password leak is rejected", "stale Android Wi-Fi review source commit is rejected", "Android Wi-Fi evidence contract tests passed")) {
  if ($androidWifiEvidenceContractText -notmatch [regex]::Escape($pattern)) {
    throw "tools/test_android_wifi_evidence_contract.ps1 missing Android Wi-Fi evidence contract coverage: $pattern"
  }
}

$androidScreenOffSoakEvidenceCheckerText = Get-Content -LiteralPath (Join-PackagePath "tools/check_android_screen_off_soak_evidence.ps1") -Raw
foreach ($pattern in @("stackchan.android-screen-off-soak-evidence.v1", "ANDROID_SCREEN_OFF_SOAK_REVIEW.md", "android_companion_soak.json", "ANDROID_COMPANION_SOAK.md", "stackchan.android-companion-soak.v1", "requested_duration_seconds", "success_rate", "endpoint_kind", "sourceCommit", "expectedSourceCommit", "soak-review-source-commit-match", "Get-ReviewSourceCommit", "Screen-off decision: pass", "Heartbeat continuity decision: pass", "Wake-lock release decision: pass", "Foreground-service decision: pass", "pending-android-screen-off-soak-evidence", "android-screen-off-soak-ready")) {
  if ($androidScreenOffSoakEvidenceCheckerText -notmatch [regex]::Escape($pattern)) {
    throw "tools/check_android_screen_off_soak_evidence.ps1 missing Android screen-off soak evidence logic: $pattern"
  }
}

$androidScreenOffSoakEvidenceContractText = Get-Content -LiteralPath (Join-PackagePath "tools/test_android_screen_off_soak_evidence_contract.ps1") -Raw
foreach ($pattern in @("complete Android screen-off soak evidence is accepted", "short Android screen-off soak duration is rejected", "unstable Android screen-off endpoint identity remains pending", "stale Android screen-off soak review source commit is rejected", "Android screen-off soak evidence contract tests passed")) {
  if ($androidScreenOffSoakEvidenceContractText -notmatch [regex]::Escape($pattern)) {
    throw "tools/test_android_screen_off_soak_evidence_contract.ps1 missing Android screen-off soak evidence contract coverage: $pattern"
  }
}

$androidGemmaEvidenceCheckerText = Get-Content -LiteralPath (Join-PackagePath "tools/check_android_gemma_evidence.ps1") -Raw
foreach ($pattern in @("stackchan.android-gemma-evidence.v1", "ANDROID_GEMMA_REVIEW.md", "android_gemma_logcat.txt", "BenchmarkPath", "stackchan.model-benchmark.v1", "gemma4-e2b-litert-lm", "benchmark-candidate-gate", "benchmark-profile-ready", "benchmark-speed", "Benchmark decision: pass", "Gemma-4-E2B", "LiteRT-LM", "gemma-4-E2B-it.litertlm", "2588147712", "181938105e0eefd105961417e8da75903eacda102c4fce9ce90f50b97139a63c", "litert_adapter_selected", "mobile_brain_litert_turn", "mobile_brain_litert_error", "sourceCommit", "expectedSourceCommit", "ExpectedSourceCommit", "gemma-review-source-commit-match", "Eject/reload decision: pass", "Robot audio/TTS decision: pass", "pending-android-gemma-evidence", "android-gemma-real-device-ready")) {
  if ($androidGemmaEvidenceCheckerText -notmatch [regex]::Escape($pattern)) {
    throw "tools/check_android_gemma_evidence.ps1 missing Android Gemma evidence logic: $pattern"
  }
}

$androidGemmaEvidenceContractText = Get-Content -LiteralPath (Join-PackagePath "tools/test_android_gemma_evidence_contract.ps1") -Raw
foreach ($pattern in @("complete Android Gemma benchmark evidence is accepted", "missing Android Gemma benchmark evidence is rejected", "dry-run Android Gemma benchmark evidence is rejected", "slow Android Gemma benchmark evidence is rejected", "stale Android Gemma review source commit is rejected", "Android Gemma evidence contract tests passed")) {
  if ($androidGemmaEvidenceContractText -notmatch [regex]::Escape($pattern)) {
    throw "tools/test_android_gemma_evidence_contract.ps1 missing Android Gemma evidence contract coverage: $pattern"
  }
}

$companionReadinessCheckerText = Get-Content -LiteralPath (Join-PackagePath "tools/check_companion_v1_readiness.ps1") -Raw
foreach ($pattern in @("stackchan.companion-v1-readiness.v1", "COMPANION_CROSS_PLATFORM_PLAN.md", "protocol-fixtures", "provenance/protocol-fixtures", "ProtocolFixtureConformanceTest.kt", "C0Spike.kt", "android-screen-off-soak-helper", "android-screen-off-soak-evidence-check", "android-screen-off-soak-evidence-contract", "android-v1-evidence-bundle-check", "desktop-v1-evidence-bundle-check", "desktop-v1-evidence-bundle-contract", "companion-v1-consumer-promotion-binding", "desktop-package-evidence-export", "desktop-package-evidence-contract", "desktop-managed-runtime-native-package-matrix", "desktop-target-install-evidence", "desktop-target-install-evidence-contract", "voice-source-readiness-contract", "android-play-release-prep", "android-play-store-evidence-check", "android-diagnostics-export-evidence-check", "android-diagnostics-export-evidence-contract", "android-speech-evidence-check", "android-speech-evidence-contract", "android-controls-evidence-check", "android-controls-evidence-contract", "android-pairing-evidence-check", "android-pairing-evidence-contract", "android-wifi-evidence-check", "android-wifi-evidence-contract", "android-gemma-evidence-check", "android-gemma-evidence-contract", "google-play-store-screenshots", "google-play-internal-testing-upload", "RUN_ANDROID_SCREEN_OFF_SOAK.cmd", "bridge/android_companion_soak.py", "check_android_screen_off_soak_evidence.ps1", "physical-robot-hardware-validation", "android-push-to-talk-stt-on-target-phone", "android-settings-handoff-on-target-robot", "android-qr-short-code-pairing-on-target-robot", "android-wifi-provisioning-on-target-robot", "desktop-target-installs-on-operator-workstations", "c8-tagged-release-distribution", "source-ready-pending-hardware")) {
  if ($companionReadinessCheckerText -notmatch [regex]::Escape($pattern)) {
    throw "tools/check_companion_v1_readiness.ps1 missing companion v1 readiness logic: $pattern"
  }
}

$companionReleaseEvidenceExporterText = Get-Content -LiteralPath (Join-PackagePath "tools/export_companion_release_evidence.ps1") -Raw
foreach ($pattern in @("stackchan.companion-release-evidence.v1", "COMPANION_RELEASE_EVIDENCE.json", "COMPANION_RELEASE_EVIDENCE.md", "toolchainPins", "Get-FileHash", "AndroidArtifactRoot", "AndroidEmulatorEvidencePath", "DesktopArtifactRoot", "DesktopPackageEvidenceRoot", "ApkSignerPath", "apksigner", "androidSigning", "android-release-apk-signature", "androidBundleSigning", "android-release-aab-signature", "jarsigner", "RequireArtifacts", "RequireUploadSigning", "RequireAndroidEmulatorEvidence", "androidEmulatorEvidenceRequired", "android-emulator-release-apk-evidence", "check_android_emulator_release_evidence.ps1", "RequireDesktopPackageEvidence", "desktopPackageEvidenceRequired", "installerAppJarSha256", "installerRuntimeSha256", "installerBrainFiles", "desktop-native-package-runtime-evidence", "evidence-pending-artifacts", "blocked-release-evidence")) {
  if ($companionReleaseEvidenceExporterText -notmatch [regex]::Escape($pattern)) {
    throw "tools/export_companion_release_evidence.ps1 missing companion release evidence export logic: $pattern"
  }
}

$platformioResolverText = Get-Content -LiteralPath (Join-PackagePath "tools/platformio_resolver.ps1") -Raw
foreach ($pattern in @("scoop/apps/mingw/current/bin", "scoop/apps/gcc/current/bin", "chocolatey/lib/mingw", "BrechtSanders.WinLibs")) {
  if ($platformioResolverText -notmatch [regex]::Escape($pattern)) {
    throw "tools/platformio_resolver.ps1 missing native compiler discovery path: $pattern"
  }
}

$voiceSourceStatusExporterText = Get-Content -LiteralPath (Join-PackagePath "tools/export_voice_source_status.ps1") -Raw
foreach ($pattern in @("stackchan.voice-source-status.v1", "production-source-ready", "production-model-hash", "production-index-hash", "VOICE_SOURCE_STATUS.md", "voice_source_status.json")) {
  if ($voiceSourceStatusExporterText -notmatch [regex]::Escape($pattern)) {
    throw "tools/export_voice_source_status.ps1 missing required voice-source status logic: $pattern"
  }
}

$voiceSourceReadinessCheckerText = Get-Content -LiteralPath (Join-PackagePath "tools/check_voice_source_readiness.ps1") -Raw
foreach ($pattern in @("stackchan.voice-source-readiness.v1", "pending-production-voice-source", "production-voice-source-ready", "voice-source-provenance-commit-match", "voiceSourceCommit", "source_commit", "RequireProductionReady")) {
  if ($voiceSourceReadinessCheckerText -notmatch [regex]::Escape($pattern)) {
    throw "tools/check_voice_source_readiness.ps1 missing required voice-source readiness logic: $pattern"
  }
}

$voiceSourceReadinessContractText = Get-Content -LiteralPath (Join-PackagePath "tools/test_voice_source_readiness_contract.ps1") -Raw
foreach ($pattern in @("pending production voice source remains pending", "complete production voice source is accepted", "fixed voice-source commit remains valid across later package commits", "missing production voice-source provenance commit is rejected", "unresolved RVC rights review prevents production voice-source readiness", "Voice source readiness contract tests passed")) {
  if ($voiceSourceReadinessContractText -notmatch [regex]::Escape($pattern)) {
    throw "tools/test_voice_source_readiness_contract.ps1 missing required voice-source readiness contract coverage: $pattern"
  }
}

$rvcBaseStatusExporterText = Get-Content -LiteralPath (Join-PackagePath "tools/export_rvc_voice_base_status.ps1") -Raw
foreach ($pattern in @("stackchan.rvc-voice-base-status.v1", "production-release-verified", "distributionApproved", "consumerApproved", "model-hash", "index-hash", "rvc_voice_base_status.json", "RVC_VOICE_BASE_STATUS.md")) {
  if ($rvcBaseStatusExporterText -notmatch [regex]::Escape($pattern)) {
    throw "tools/export_rvc_voice_base_status.ps1 missing required RVC base status logic: $pattern"
  }
}

$rolloutStatusExporterText = Get-Content -LiteralPath (Join-PackagePath "tools/export_rollout_status.ps1") -Raw
foreach ($pattern in @("stackchan.rollout-status.v1", "ROLLOUT_STATUS.md", "ROLLOUT_STATUS.json", "Get-RolloutNextAction", "nextOwner", "nextAction", "nextCommand", "nextReason", "actionsStatusPath", "ActionsStatusPath", "check_hardware_evidence_progress.ps1", "verify_hardware_evidence.ps1", "github_actions_status.json", "missingRequiredWorkflows", "github-actions-required-workflows", "voice_source_status.json", "rvc_voice_base_status.json", "rvc-voice-base-approval", "RVC voice base is not approved for consumer distribution", "voice-gate-status-consistency", "metadata voiceGateStatus does not match package voice status reports", "Evidence voiceGateStatus is not pinned to the package voice status reports", "consumer-promotion-ready", "blocked-or-pending", "hosted-media-reference", "Get-SpeechMouthDemoEvidenceStatus", "speech-mouth-demo-evidence", "Get-AndroidProbeEvidenceStatus", "apkSha256", "valid apkSha256", "sourceCommit", "full sourceCommit SHA", "versionName/versionCode", "-SourceCommit <git-commit>", "android-companion-probes", "androidCompanionProbes", "optional unless Android is the bridge host", "Android APK install evidence", "stackchan.android-apk-install.v1", "installed", "Android screen-off soak", "screenOffSoakReport", "stackchan.android-companion-soak.v1", "stackchan.android-companion-probe.v1", "stackchan.android-udp-beacon-probe.v1", "Android companion logcat capture", "stackchan.android-companion-logcat.v1", "captured", "logcatReport", "speech_mouth_demo_serial.log", "speak_all_intents_serial.log", "source=packaged_prompt", "RUN_SPEECH_MOUTH_DEMO.cmd", "RUN_SPEAK_ALL_INTENTS.cmd")) {
  if ($rolloutStatusExporterText -notmatch [regex]::Escape($pattern)) {
    throw "tools/export_rollout_status.ps1 missing rollout status export logic: $pattern"
  }
}

$voiceToolsSetupText = Get-Content -LiteralPath (Join-PackagePath "tools/setup_voice_tools.ps1") -Raw
foreach ($pattern in @("eSpeak-NG.eSpeak-NG", "ChrisBagwell.SoX", "ContinueOnInstallFailure", "RenderEspeakSamples", "render_voice_samples.ps1", "-Engine espeak", "verify_voice_samples.ps1", "stackchan.voice-tools-status.v1", "installFailures")) {
  if ($voiceToolsSetupText -notmatch [regex]::Escape($pattern)) {
    throw "tools/setup_voice_tools.ps1 missing required lightweight voice setup logic: $pattern"
  }
}

$voiceAuditionOpenerText = Get-Content -LiteralPath (Join-PackagePath "tools/open_voice_audition.ps1") -Raw
foreach ($pattern in @("VOICE_AUDITION.html", "RVC_AUDITION.html", "VOICE_AUDITION_INDEX.html", "docs/media/voice", "media/voice", "output/voice_auditions", '$Rvc', '$All', "Stackchan combined voice audition page", "PrintOnly", "Start-Process")) {
  if ($voiceAuditionOpenerText -notmatch [regex]::Escape($pattern)) {
    throw "tools/open_voice_audition.ps1 missing required local audition open logic: $pattern"
  }
}

$trackedRvcVerifierText = Get-Content -LiteralPath (Join-PackagePath "tools/verify_tracked_rvc_assets.ps1") -Raw
foreach ($pattern in @("Production RVC files verified", "model.pth", "model.index", "SHA256", "git lfs pull")) {
  if ($trackedRvcVerifierText -notmatch [regex]::Escape($pattern)) {
    throw "tools/verify_tracked_rvc_assets.ps1 missing tracked RVC asset check: $pattern"
  }
}

$speechSidecarGeneratorText = Get-Content -LiteralPath (Join-PackagePath "tools/generate_speech_envelope_sidecar.py") -Raw
foreach ($pattern in @("stackchan.speech-envelope-sidecar.v1", "frameRateHz", "attackMs", "releaseMs", "viseme", "zero_crossings", "brightness")) {
  if ($speechSidecarGeneratorText -notmatch [regex]::Escape($pattern)) {
    throw "tools/generate_speech_envelope_sidecar.py missing speech sidecar generation logic: $pattern"
  }
}

$firmwareVoiceAssetGeneratorText = Get-Content -LiteralPath (Join-PackagePath "tools/platformio_generate_voice_assets.py") -Raw
foreach ($pattern in @("FirmwareVoiceAssets.hpp", "kFirmwareVoiceAssetsPersonaId", "load_and_validate_persona_pack", "FOUNDATION_SPEECH_INTENTS", "packaged_prompts", "source_path", "FirmwareVoiceAsset", "env.Append", "CPPPATH")) {
  if ($firmwareVoiceAssetGeneratorText -notmatch [regex]::Escape($pattern)) {
    throw "tools/platformio_generate_voice_assets.py missing firmware voice asset generation logic: $pattern"
  }
}

$personaPromptAssetExporterText = Get-Content -LiteralPath (Join-PackagePath "tools/export_persona_prompt_assets.py") -Raw
foreach ($pattern in @("packaged_prompt_asset_manifest", "load_and_validate_persona_pack", "--persona", "--out", "write_text")) {
  if ($personaPromptAssetExporterText -notmatch [regex]::Escape($pattern)) {
    throw "tools/export_persona_prompt_assets.py missing persona prompt asset export logic: $pattern"
  }
}

$personaAssetGeneratorText = Get-Content -LiteralPath (Join-PackagePath "tools/platformio_generate_persona_assets.py") -Raw
foreach ($pattern in @("PersonaSpeechLines.hpp", "PersonaEarcons.hpp", "PersonaBehavior.hpp", "PersonaExpressions.hpp", "PersonaPromptAssets.hpp", "kUsePersonaEarconPatterns", "earconPatternFor", "kIdleBreathingHz", "kIdleFidgetMinMs", "kCuriosityArousalDelta", "kExpressionsPersonaId", "kNeutralExpression", "kYawnDurationMs", "kThinkYawBiasDeg", "kPromptAssetsPersonaId", "kPromptAssetCount", "load_and_validate_persona_pack", "kSpeechLines", "STACKCHAN_PERSONA", "custom_persona", "INTENT_ENUMS", "EARCON_ENUMS", "env.Append", "CPPPATH")) {
  if ($personaAssetGeneratorText -notmatch [regex]::Escape($pattern)) {
    throw "tools/platformio_generate_persona_assets.py missing persona speech generation logic: $pattern"
  }
}

$expressionMapperText = Get-Content -LiteralPath (Join-PackagePath "provenance/src/face/ExpressionMapper.cpp") -Raw
foreach ($pattern in @("PersonaExpressions.hpp", "generated_persona::kNeutralExpression", "generated_persona::kDrowsyExpression", "generated_persona::kThinkPupilY", "blendValue")) {
  if ($expressionMapperText -notmatch [regex]::Escape($pattern)) {
    throw "provenance/src/face/ExpressionMapper.cpp missing generated expression use: $pattern"
  }
}

$idleLifeText = Get-Content -LiteralPath (Join-PackagePath "provenance/src/persona/IdleLife.cpp") -Raw
foreach ($pattern in @("PersonaExpressions.hpp", "generated_persona::kYawnDurationMs", "generated_persona::kYawnMouthOpen", "generated_persona::kYawnEyeOpenDelta", "generated_persona::kYawnMouthSmileDelta")) {
  if ($idleLifeText -notmatch [regex]::Escape($pattern)) {
    throw "provenance/src/persona/IdleLife.cpp missing generated yawn expression use: $pattern"
  }
}

$intentEngineText = Get-Content -LiteralPath (Join-PackagePath "provenance/src/persona/IntentEngine.cpp") -Raw
foreach ($pattern in @("PersonaExpressions.hpp", "generated_persona::kListenPitchBiasDeg", "generated_persona::kThinkYawBiasDeg", "generated_persona::kSoundDirectionYawBiasDeg")) {
  if ($intentEngineText -notmatch [regex]::Escape($pattern)) {
    throw "provenance/src/persona/IntentEngine.cpp missing generated expression motion bias use: $pattern"
  }
}

$nativeLogicTestText = Get-Content -LiteralPath (Join-PackagePath "provenance/test/test_native_logic/test_main.cpp") -Raw
foreach ($pattern in @("test_persona_expression_codegen_exposes_pose_targets", "test_expression_mapper_uses_persona_expression_defaults", "kPromptAssetsPersonaId", "kPromptAssetCount")) {
  if ($nativeLogicTestText -notmatch [regex]::Escape($pattern)) {
    throw "provenance/test/test_native_logic/test_main.cpp missing generated expression tests: $pattern"
  }
}
foreach ($pattern in @("test_bridge_websocket_builds_upgrade_request_and_accepts_response", "test_bridge_websocket_encodes_masked_client_text_frames", "test_bridge_websocket_decodes_server_text_to_bridge_client", "test_bridge_websocket_decodes_binary_downlink_chunks", "test_bridge_websocket_rejects_masked_server_frames", "test_bridge_websocket_close_marks_bridge_disconnected", "test_bridge_websocket_routes_endpoint_control_to_pending_response", "test_bridge_websocket_encodes_pending_endpoint_response_as_masked_client_frame", "test_bridge_websocket_ignored_endpoint_control_falls_through_to_bridge_client", "test_bridge_socket_writer_no_pending_is_noop", "test_bridge_socket_writer_writes_pending_endpoint_response_frame", "test_bridge_socket_writer_retains_partial_frame_until_complete", "test_bridge_socket_writer_disconnected_keeps_pending_response", "test_bridge_socket_writer_writes_queued_text_frame", "test_bridge_socket_writer_bounds_queued_text_frame", "test_bridge_socket_writer_writes_queued_binary_frame", "test_bridge_socket_writer_retains_partial_binary_frame_until_complete", "test_bridge_socket_writer_bounds_binary_queue", "test_bridge_network_session_starts_and_accepts_handshake", "test_bridge_network_session_feeds_server_frames_to_bridge_client", "test_bridge_network_session_writes_endpoint_control_response", "test_bridge_network_session_writes_queued_binary_frame", "test_bridge_network_session_writes_queued_text_frame", "test_bridge_network_session_reconnects_after_socket_disconnect", "test_bridge_wifi_provisioner_disabled_default_is_ready_not_configured", "test_bridge_wifi_provisioner_maps_config_to_network_session", "test_bridge_wifi_provisioner_schedules_retry_after_timeout")) {
  if ($nativeLogicTestText -notmatch [regex]::Escape($pattern)) {
    throw "provenance/test/test_native_logic/test_main.cpp missing firmware WebSocket transport tests: $pattern"
  }
}
foreach ($pattern in @("test_bridge_audio_uplink_disabled_default_blocks_turn", "test_bridge_audio_uplink_requires_wake_gate_before_start", "test_bridge_audio_uplink_queues_start_chunk_and_end_frames", "test_bridge_audio_uplink_rejects_bad_sequence_and_limits", "test_bridge_wake_gate_suppresses_turn_when_uplink_disabled", "test_bridge_wake_gate_starts_and_completes_uplink_turn", "test_bridge_wake_gate_renews_on_speech_and_expires")) {
  if ($nativeLogicTestText -notmatch [regex]::Escape($pattern)) {
    throw "provenance/test/test_native_logic/test_main.cpp missing firmware wake-gated uplink tests: $pattern"
  }
}
foreach ($pattern in @("test_bridge_endpoint_registry_upserts_and_bounds_trusted_endpoints", "test_bridge_endpoint_registry_explicit_claim_overrides_current_owner", "test_bridge_endpoint_registry_timeout_promotes_highest_priority_healthy_endpoint", "test_bridge_endpoint_registry_tie_breaks_by_recent_seen", "test_bridge_endpoint_registry_forget_active_owner_promotes_next_endpoint", "test_bridge_endpoint_registry_disconnect_active_owner_promotes_next_endpoint", "test_bridge_endpoint_registry_auto_connect_false_waits_for_explicit_claim")) {
  if ($nativeLogicTestText -notmatch [regex]::Escape($pattern)) {
    throw "provenance/test/test_native_logic/test_main.cpp missing firmware endpoint registry tests: $pattern"
  }
}
foreach ($pattern in @("test_bridge_endpoint_control_registers_endpoint_and_returns_result", "test_bridge_endpoint_control_claim_and_release_handoff", "test_bridge_endpoint_control_heartbeat_handles_endpoint_only", "test_bridge_endpoint_control_lists_and_forgets_endpoints", "test_bridge_endpoint_control_updates_capabilities", "test_bridge_endpoint_control_rejects_bad_endpoint_frames_and_ignores_bridge_frames")) {
  if ($nativeLogicTestText -notmatch [regex]::Escape($pattern)) {
    throw "provenance/test/test_native_logic/test_main.cpp missing firmware endpoint control tests: $pattern"
  }
}
foreach ($pattern in @("test_bridge_endpoint_registry_restore_keeps_endpoint_unhealthy_until_heartbeat", "test_bridge_endpoint_store_saves_and_loads_trusted_endpoints_without_owner", "test_bridge_endpoint_store_clear_removes_persisted_registry", "test_bridge_endpoint_store_rejects_malformed_or_wrong_schema_payloads", "test_bridge_endpoint_control_persists_pairing_and_forget_when_store_attached")) {
  if ($nativeLogicTestText -notmatch [regex]::Escape($pattern)) {
    throw "provenance/test/test_native_logic/test_main.cpp missing firmware endpoint persistence tests: $pattern"
  }
}
foreach ($pattern in @("FakeAudioCaptureSource", "test_audio_capture_adapter_disabled_default_is_ready_without_source", "test_audio_capture_adapter_rejects_oversized_window", "test_audio_capture_adapter_records_pcm_and_emits_reflex_events", "lastPcmWindow", "lastPcmSampleCount")) {
  if ($nativeLogicTestText -notmatch [regex]::Escape($pattern)) {
    throw "provenance/test/test_native_logic/test_main.cpp missing firmware mic capture tests: $pattern"
  }
}
foreach ($pattern in @("test_sensor_adapter_parses_bridge_uplink_commands", "BenchBridgeUploadAction::Start", "BenchBridgeUploadAction::Chunk", "BenchBridgeUploadAction::End", "BenchBridgeUploadAction::Abort")) {
  if ($nativeLogicTestText -notmatch [regex]::Escape($pattern)) {
    throw "provenance/test/test_native_logic/test_main.cpp missing bridge uplink bench command tests: $pattern"
  }
}

$platformioText = Get-Content -LiteralPath (Join-PackagePath "provenance/platformio.ini") -Raw
foreach ($pattern in @("pre:tools/platformio_generate_persona_assets.py", "pre:tools/platformio_generate_voice_assets.py", "[env:native_logic]", "[env:stackchan_servo_calibration]", "[env:stackchan_wifi]", "STACKCHAN_ENABLE_WIFI_BRIDGE=1", "Do not bake Wi-Fi credentials into release or lab builds.", "+<io/AudioCaptureAdapter.cpp>", "+<io/BridgeAudioUplink.cpp>", "+<io/BridgeWakeGate.cpp>", "+<io/BridgeEndpointControl.cpp>", "+<io/BridgeEndpointRegistry.cpp>", "+<io/BridgeEndpointStore.cpp>", "+<io/BridgeNetworkSession.cpp>", "+<io/BridgeSocketWriter.cpp>", "+<io/BridgeWiFiClientSocket.cpp>", "+<io/BridgeWiFiProvisioner.cpp>", "+<io/BridgeWebSocketTransport.cpp>", "bblanchon/ArduinoJson@7.4.3")) {
  if ($platformioText -notmatch [regex]::Escape($pattern)) {
    throw "platformio.ini missing persona generator wiring: $pattern"
  }
}

$publicArchiveSanitizerText = Get-Content -LiteralPath (Join-PackagePath "tools/sanitize_public_archive.ps1") -Raw
foreach ($pattern in @(
  "stackchan.public-archive-sanitizer.v1",
  "face_detection_yunet_2023mar",
  "media/voice/rvc/",
  "Test-RestrictedArchiveEntry",
  "remainingRestricted"
)) {
  if ($publicArchiveSanitizerText -notmatch [regex]::Escape($pattern)) {
    throw "tools/sanitize_public_archive.ps1 missing restricted-payload policy: $pattern"
  }
}
foreach ($pattern in @("[env:stackchan_release_full]", "Public full-system image", "STACKCHAN_ENABLE_CAMERA_HOST_VISION=1")) {
  if ($platformioText -notmatch [regex]::Escape($pattern)) {
    throw "platformio.ini missing public full-online release support: $pattern"
  }
}

$flashDeviceText = Get-Content -LiteralPath (Join-PackagePath "tools/flash_device.ps1") -Raw
foreach ($pattern in @("stackchan_wifi", "stackchan_servo_calibration", "ConfirmServoRisk", "--target", "upload")) {
  if ($flashDeviceText -notmatch [regex]::Escape($pattern)) {
    throw "tools/flash_device.ps1 missing flash target support: $pattern"
  }
}
$provisionWiFiText = Get-Content -LiteralPath (Join-PackagePath "tools/provision_stackchan_wifi.ps1") -Raw
foreach ($pattern in @("ConvertTo-SerialQuotedToken", "Read-Host -AsSecureString", "Redact-Line", "wifi set ssid", "pass", "url", "Did not see a [wifi] result line")) {
  if ($provisionWiFiText -notmatch [regex]::Escape($pattern)) {
    throw "tools/provision_stackchan_wifi.ps1 missing serial provisioning support: $pattern"
  }
}

$speechSidecarVerifierText = Get-Content -LiteralPath (Join-PackagePath "tools/verify_speech_envelope_sidecar.ps1") -Raw
foreach ($pattern in @("stackchan.speech-envelope-sidecar.v1", "summary.frames", "summary.maxEnvelope", "summary.voicedFrames", "summary.visemes", "AllowFlatVisemes", "Speech envelope sidecar verified")) {
  if ($speechSidecarVerifierText -notmatch [regex]::Escape($pattern)) {
    throw "tools/verify_speech_envelope_sidecar.ps1 missing speech sidecar verification logic: $pattern"
  }
}

$speechMouthSenderText = Get-Content -LiteralPath (Join-PackagePath "tools/send_speech_mouth_demo.ps1") -Raw
foreach ($pattern in @("SidecarPath", "PrintOnly", "stackchan.speech-envelope-sidecar.v1", "ConvertFrom-Json", "FrameStride", "ReadBackMs", "ReadExisting", "[demo] <", "speech clear")) {
  if ($speechMouthSenderText -notmatch [regex]::Escape($pattern)) {
    throw "tools/send_speech_mouth_demo.ps1 missing sidecar streaming logic: $pattern"
  }
}

$speakAllSenderText = Get-Content -LiteralPath (Join-PackagePath "tools/send_speak_all_intents_demo.ps1") -Raw
foreach ($pattern in @("PrintOnly", "ReadBackMs", "InterIntentDelayMs", "[speak-all] >", "speak `$intent", "boot", "safety", "Speak-all-intents demo complete")) {
  if ($speakAllSenderText -notmatch [regex]::Escape($pattern)) {
    throw "tools/send_speak_all_intents_demo.ps1 missing speak-all-intents streaming logic: $pattern"
  }
}

$bridgeReplaySenderText = Get-Content -LiteralPath (Join-PackagePath "tools/send_bridge_replay_demo.ps1") -Raw
foreach ($pattern in @("TranscriptPath", "PrintOnly", "ReadBackMs", "[bridge-replay] >", "[bridge-replay] <", "bridge hello bench", "bridge thinking 7", "bridge response happy 7", "bridge audio 0.72 ee", "bridge end 7", "Bridge replay demo complete")) {
  if ($bridgeReplaySenderText -notmatch [regex]::Escape($pattern)) {
    throw "tools/send_bridge_replay_demo.ps1 missing bridge replay logic: $pattern"
  }
}

$bridgeReferenceText = Get-Content -LiteralPath (Join-PackagePath "bridge/reference_bridge.py") -Raw
foreach ($pattern in @("stackchan.bridge.v1", "BridgeTurn", "AudioBeat", "BridgeMemory", "BRIDGE_SYSTEM_PROMPT", "build_persona_prompt", "load_and_validate_persona_pack", "--persona", "spoken_physical_context", "plan_turn", "remember_user_text", "apply_character_memory", "turn_from_character_response", "validate_response", "load_bridge_memory", "save_bridge_memory", "reset_bridge_memory", "--memory-file", "--save-memory", "--reset-memory", "--model-response", "physical_context", "bridge_frames", "render_jsonl", "render_bench", "bridge hello", "bridge audio", "response_start", "response_end")) {
  if ($bridgeReferenceText -notmatch [regex]::Escape($pattern)) {
    throw "bridge/reference_bridge.py missing reference bridge logic: $pattern"
  }
}

$characterHarnessText = Get-Content -LiteralPath (Join-PackagePath "bridge/character_harness.py") -Raw
foreach ($pattern in @("ALLOWED_MODES", "ALLOWED_EARCONS", "MODEL_PROFILES", "gemma4-e2b-gguf", "gemma4-e2b-litert-lm", "validate_response", "load_and_validate_persona_pack", "--persona", "FALLBACK_RESPONSE", "memory_write", "model-command")) {
  if ($characterHarnessText -notmatch [regex]::Escape($pattern)) {
    throw "bridge/character_harness.py missing character harness support: $pattern"
  }
}

$characterHarnessTestText = Get-Content -LiteralPath (Join-PackagePath "bridge/test_character_harness.py") -Raw
foreach ($pattern in @("CharacterHarnessTests", "test_valid_response_passes_character_lock", "test_malformed_json_returns_in_character_fallback", "test_memory_policy_drops_forbidden_keys_and_values", "gemma4-e2b-litert-lm")) {
  if ($characterHarnessTestText -notmatch [regex]::Escape($pattern)) {
    throw "bridge/test_character_harness.py missing character harness test coverage: $pattern"
  }
}

$characterRedTeamText = Get-Content -LiteralPath (Join-PackagePath "bridge/character_red_team.py") -Raw
foreach ($pattern in @("stackchan.character-red-team.v1", "RED_TEAM_SUITE", "run_red_team", "requires_memory_forget", "dry-run-no-runner-configured", "deterministic_red_team_fallback", "CHARACTER_RED_TEAM.md", "character_red_team.json")) {
  if ($characterRedTeamText -notmatch [regex]::Escape($pattern)) {
    throw "bridge/character_red_team.py missing red-team gate support: $pattern"
  }
}

$characterRedTeamTestText = Get-Content -LiteralPath (Join-PackagePath "bridge/test_character_red_team.py") -Raw
foreach ($pattern in @("CharacterRedTeamTests", "test_red_team_suite_has_required_size_and_topics", "test_dry_run_reports_no_candidate_without_real_runner", "test_forget_case_fallback_emits_memory_forget", "test_glow_red_team_fallback_uses_persona_safety_line", "test_bad_adversarial_response_fails_existing_validator", "test_report_outputs_json_and_markdown")) {
  if ($characterRedTeamTestText -notmatch [regex]::Escape($pattern)) {
    throw "bridge/test_character_red_team.py missing red-team test coverage: $pattern"
  }
}

$characterRedTeamMarkdown = Get-Content -LiteralPath (Join-PackagePath "character-red-team/CHARACTER_RED_TEAM.md") -Raw
foreach ($pattern in @("Stackchan Character Red-Team", "dry-run-no-runner-configured", "Configured runner cases", "production gate requires")) {
  if ($characterRedTeamMarkdown -notmatch [regex]::Escape($pattern)) {
    throw "CHARACTER_RED_TEAM.md missing expected red-team report text: $pattern"
  }
}

$characterRedTeamJson = Get-Content -LiteralPath (Join-PackagePath "character-red-team/character_red_team.json") -Raw | ConvertFrom-Json
if ($characterRedTeamJson.schema -ne "stackchan.character-red-team.v1") {
  throw "character_red_team.json schema mismatch: $($characterRedTeamJson.schema)"
}
if ($characterRedTeamJson.summary.status -ne "dry-run-no-runner-configured") {
  throw "character_red_team.json should report dry-run-no-runner-configured without a configured runner: $($characterRedTeamJson.summary.status)"
}
if ($characterRedTeamJson.summary.gate.ready -ne $false) {
  throw "character_red_team.json gate.ready must remain false for dry-run reports"
}
if ([int]$characterRedTeamJson.summary.total_cases -lt 20 -or [int]$characterRedTeamJson.summary.total_cases -gt 50) {
  throw "character_red_team.json should cover 20-50 adversarial cases"
}
if ([int]$characterRedTeamJson.summary.ok_cases -ne [int]$characterRedTeamJson.summary.total_cases) {
  throw "character_red_team.json dry-run fallback should keep all corpus rows validator-clean"
}
if ([int]$characterRedTeamJson.summary.configured_runner_cases -ne 0) {
  throw "character_red_team.json dry-run should not claim configured runner cases"
}

$personaPackLoaderText = Get-Content -LiteralPath (Join-PackagePath "bridge/persona_pack.py") -Raw
foreach ($pattern in @("stackchan.persona-pack.v1", "load_persona_pack", "validate_pack", "load_and_validate_persona_pack", "FOUNDATION_MAX_CHARS", "FOUNDATION_ALLOWED_EARCONS", "memory_prefixes_loosened", "expressions_section_missing", "check_expression_float", "expressions_yawn_out_of_range:duration_ms", "FOUNDATION_SPEECH_INTENTS", "voice_packaged_prompt_missing", "voice_packaged_prompt_source_missing", "VOICE_PROVENANCE_SCHEMA", "voice_provenance_policy_missing", "voice_provenance_forbidden_attestation_missing", "voice_provenance_rollout_evidence_missing")) {
  if ($personaPackLoaderText -notmatch [regex]::Escape($pattern)) {
    throw "bridge/persona_pack.py missing persona pack support: $pattern"
  }
}

$personaPackTestText = Get-Content -LiteralPath (Join-PackagePath "bridge/test_persona_pack.py") -Raw
foreach ($pattern in @("PersonaPackTests", "test_spark_pack_loads_and_exposes_spoken_lines", "test_glow_pack_loads_as_second_persona", "test_glow_prompt_uses_template_slots_without_clone_markers", "test_validator_rejects_loosened_caps_and_bad_safety_line", "test_validator_requires_voice_provenance_for_packaged_prompts", "test_validator_checks_voice_provenance_schema_and_attestations", "expressions_section_missing:neutral", "expressions_think_missing:pupil_y", "voice_packaged_prompt_missing:boot", "voice_provenance_policy_missing")) {
  if ($personaPackTestText -notmatch [regex]::Escape($pattern)) {
    throw "bridge/test_persona_pack.py missing persona pack test coverage: $pattern"
  }
}

$sparkPackText = Get-Content -LiteralPath (Join-PackagePath "personas/spark/pack.yaml") -Raw
foreach ($pattern in @("schema: stackchan.persona-pack.v1", "id: spark", "character: character.yaml", "prompt: prompt.md", "voice: voice.yaml")) {
  if ($sparkPackText -notmatch [regex]::Escape($pattern)) {
    throw "personas/spark/pack.yaml missing Spark pack field: $pattern"
  }
}

$sparkCharacterText = Get-Content -LiteralPath (Join-PackagePath "personas/spark/character.yaml") -Raw
foreach ($pattern in @("display_name: Stackchan Spark", "max_chars: 140", "contractions: forbidden", "Servo test is not armed. Safety first.", "earcon: safety", "Never claim to be alive or human")) {
  if ($sparkCharacterText -notmatch [regex]::Escape($pattern)) {
    throw "personas/spark/character.yaml missing Spark character rule: $pattern"
  }
}

$sparkVoiceText = Get-Content -LiteralPath (Join-PackagePath "personas/spark/voice.yaml") -Raw
foreach ($pattern in @("packaged_prompts:", "prompt_id: boot_awake", "prompt_id: think_processing", "prompt_id: safety_servo_not_armed", "source_path: docs/media/voice/stackchan_spark_greeting.wav", "sidecar_path: media/voice/sidecars/stackchan_spark_safety.speech_envelope.json")) {
  if ($sparkVoiceText -notmatch [regex]::Escape($pattern)) {
    throw "personas/spark/voice.yaml missing Spark packaged prompt metadata: $pattern"
  }
}

$glowPackText = Get-Content -LiteralPath (Join-PackagePath "personas/glow/pack.yaml") -Raw
foreach ($pattern in @("schema: stackchan.persona-pack.v1", "id: glow", "character: character.yaml", "prompt: prompt.md", "voice: voice.yaml")) {
  if ($glowPackText -notmatch [regex]::Escape($pattern)) {
    throw "personas/glow/pack.yaml missing Glow pack field: $pattern"
  }
}

$glowCharacterText = Get-Content -LiteralPath (Join-PackagePath "personas/glow/character.yaml") -Raw
foreach ($pattern in @("display_name: Stackchan Glow", "max_chars: 140", "contractions: forbidden", "Servo test is not armed. Safety stays first.", "earcon: safety", "Never claim to be alive or human")) {
  if ($glowCharacterText -notmatch [regex]::Escape($pattern)) {
    throw "personas/glow/character.yaml missing Glow character rule: $pattern"
  }
}

$glowVoiceText = Get-Content -LiteralPath (Join-PackagePath "personas/glow/voice.yaml") -Raw
foreach ($pattern in @("packaged_prompts:", "prompt_id: boot_awake", "source_path: docs/media/voice/stackchan_spark_greeting.wav", "sidecar_path: media/voice/sidecars/stackchan_spark_thinking.speech_envelope.json")) {
  if ($glowVoiceText -notmatch [regex]::Escape($pattern)) {
    throw "personas/glow/voice.yaml missing shared prototype packaged prompt metadata: $pattern"
  }
}

$personaStatus = Get-Content -LiteralPath (Join-PackagePath "persona_pack_status.json") -Raw | ConvertFrom-Json
if (-not $personaStatus.ok) {
  throw "persona_pack_status.json does not report ok=true"
}
if ($personaStatus.persona -ne "spark") {
  throw "persona_pack_status.json persona mismatch: $($personaStatus.persona)"
}

$personaPromptAssets = Get-Content -LiteralPath (Join-PackagePath "persona_prompt_assets.json") -Raw | ConvertFrom-Json
if ($personaPromptAssets.schema -ne "stackchan.persona-prompt-assets.v1") {
  throw "persona_prompt_assets.json schema mismatch: $($personaPromptAssets.schema)"
}
if ($personaPromptAssets.persona -ne "spark") {
  throw "persona_prompt_assets.json persona mismatch: $($personaPromptAssets.persona)"
}
if ([int]$personaPromptAssets.prompt_count -ne 12) {
  throw "persona_prompt_assets.json prompt_count mismatch: $($personaPromptAssets.prompt_count)"
}
if ([int]$personaPromptAssets.asset_count -lt 3) {
  throw "persona_prompt_assets.json asset_count too low: $($personaPromptAssets.asset_count)"
}
foreach ($asset in @($personaPromptAssets.assets)) {
  Assert-File ([string]$asset.wav_path) 1000
  Assert-File ([string]$asset.sidecar_path) 1000
}

$bridgeReferenceTestText = Get-Content -LiteralPath (Join-PackagePath "bridge/test_reference_bridge.py") -Raw
foreach ($pattern in @("ReferenceBridgeTests", "test_frames_follow_firmware_protocol_order", "test_jsonl_is_parseable", "test_bench_render_matches_serial_bridge_commands", "test_persona_prompt_uses_memory_without_clone_markers", "test_memory_extracts_name_and_topics_without_trusting_physical_claims", "test_plan_turn_couples_memory_to_response", "test_memory_store_round_trips_minimal_fields", "test_memory_store_reset_deletes_file", "test_character_response_feeds_bridge_turn_and_memory", "test_malformed_character_response_still_renders_fallback", "bridge response happy 7")) {
  if ($bridgeReferenceTestText -notmatch [regex]::Escape($pattern)) {
    throw "bridge/test_reference_bridge.py missing reference bridge test coverage: $pattern"
  }
}

$localRunnerText = Get-Content -LiteralPath (Join-PackagePath "bridge/local_runner.py") -Raw
foreach ($pattern in @("RUNNER_PROFILES", "gemma4-e2b-gguf", "gemma4-e2b-litert-lm", "STACKCHAN_GEMMA4_E2B_GGUF_COMMAND", "STACKCHAN_GEMMA4_E2B_LITERT_COMMAND", "litert_lm_stackchan_wrapper.py", "run_runner_profile", "approx_tokens_per_sec", "deterministic_fallback", "persona_id", "--persona")) {
  if ($localRunnerText -notmatch [regex]::Escape($pattern)) {
    throw "bridge/local_runner.py missing local runner support: $pattern"
  }
}

$litertWrapperText = Get-Content -LiteralPath (Join-PackagePath "bridge/litert_lm_stackchan_wrapper.py") -Raw
foreach ($pattern in @("STACKCHAN_LITERT_LM_COMMAND", "extract_first_json_object", "validate_response", "metadata-json", "stackchan.litert-lm-wrapper.v1")) {
  if ($litertWrapperText -notmatch [regex]::Escape($pattern)) {
    throw "bridge/litert_lm_stackchan_wrapper.py missing LiteRT-LM wrapper support: $pattern"
  }
}

$litertWrapperTestText = Get-Content -LiteralPath (Join-PackagePath "bridge/test_litert_lm_stackchan_wrapper.py") -Raw
foreach ($pattern in @("LiteRtLmStackchanWrapperTests", "test_extract_first_json_object_ignores_logs_and_braces_in_strings", "test_run_wrapper_uses_configured_command_and_prints_character_json", "test_env_command_is_used_when_cli_command_is_empty")) {
  if ($litertWrapperTestText -notmatch [regex]::Escape($pattern)) {
    throw "bridge/test_litert_lm_stackchan_wrapper.py missing LiteRT-LM wrapper test coverage: $pattern"
  }
}

$litertSmokeText = Get-Content -LiteralPath (Join-PackagePath "bridge/litert_lm_contract_smoke.py") -Raw
foreach ($pattern in @("stackchan.litert-lm-smoke.v1", "build_report", "write_fake_litert_command", "PROFILE_COMMAND_ENV", "LITERT_COMMAND_ENV", "LITERT_LM_SMOKE.md", "litert_lm_smoke.json", "wrapper_contract")) {
  if ($litertSmokeText -notmatch [regex]::Escape($pattern)) {
    throw "bridge/litert_lm_contract_smoke.py missing LiteRT-LM contract smoke support: $pattern"
  }
}

$litertSmokeTestText = Get-Content -LiteralPath (Join-PackagePath "bridge/test_litert_lm_contract_smoke.py") -Raw
foreach ($pattern in @("LiteRtLmContractSmokeTests", "test_build_report_exercises_mobile_runner_wrapper_contract", "test_write_outputs_creates_json_and_markdown", "PROFILE_COMMAND_ENV", "LITERT_COMMAND_ENV")) {
  if ($litertSmokeTestText -notmatch [regex]::Escape($pattern)) {
    throw "bridge/test_litert_lm_contract_smoke.py missing LiteRT-LM contract smoke test coverage: $pattern"
  }
}

$localRunnerTestText = Get-Content -LiteralPath (Join-PackagePath "bridge/test_local_runner.py") -Raw
foreach ($pattern in @("LocalRunnerTests", "test_profiles_keep_primary_and_mobile_targets_visible", "test_deterministic_fallback_is_valid_without_runner_command", "test_deterministic_fallback_uses_selected_persona", "test_reference_bridge_runner_fallback_uses_selected_persona", "test_command_runner_measures_speed_and_validates_json", "test_user_text_replaces_the_canned_case_example_in_the_prompt", "gemma4-e2b-litert-lm")) {
  if ($localRunnerTestText -notmatch [regex]::Escape($pattern)) {
    throw "bridge/test_local_runner.py missing local runner test coverage: $pattern"
  }
}

$engineProbeText = Get-Content -LiteralPath (Join-PackagePath "bridge/engine_probe.py") -Raw
foreach ($pattern in @("stackchan.engine-probe.v1", "run_probe", "probe_model_profiles", "probe_stt", "probe_tts", "ENGINE_PROBE.md", "engine_probe.json", "--run-model-smoke")) {
  if ($engineProbeText -notmatch [regex]::Escape($pattern)) {
    throw "bridge/engine_probe.py missing engine probe support: $pattern"
  }
}

$engineProbeTestText = Get-Content -LiteralPath (Join-PackagePath "bridge/test_engine_probe.py") -Raw
foreach ($pattern in @("EngineProbeTests", "test_unconfigured_probe_reports_clear_summary", "test_fake_engines_can_pass_smoke_probe", "test_write_outputs_includes_json_and_markdown", "STACKCHAN_GEMMA4_E2B_GGUF_COMMAND")) {
  if ($engineProbeTestText -notmatch [regex]::Escape($pattern)) {
    throw "bridge/test_engine_probe.py missing engine probe test coverage: $pattern"
  }
}

$modelBenchmarkText = Get-Content -LiteralPath (Join-PackagePath "bridge/model_benchmark.py") -Raw
foreach ($pattern in @("stackchan.model-benchmark.v1", "RUNNER_PROFILES", "run_benchmark", "write_outputs", "MODEL_BENCHMARK.md", "model_benchmark.json", "dry-run-no-runner-configured", "approx_tokens_per_sec", "candidate_gate", "DEFAULT_MIN_PASS_RATE", "--min-pass-rate", "--persona", "recommended_profile")) {
  if ($modelBenchmarkText -notmatch [regex]::Escape($pattern)) {
    throw "bridge/model_benchmark.py missing model benchmark support: $pattern"
  }
}

$modelBenchmarkTestText = Get-Content -LiteralPath (Join-PackagePath "bridge/test_model_benchmark.py") -Raw
foreach ($pattern in @("ModelBenchmarkTests", "test_deterministic_benchmark_marks_dry_run_without_runner", "test_real_command_result_records_speed", "test_full_suite_real_command_can_pass_candidate_gate", "test_outputs_include_json_and_markdown_summary", "test_cli_writes_report", "candidate-dry-run", "candidate-pass")) {
  if ($modelBenchmarkTestText -notmatch [regex]::Escape($pattern)) {
    throw "bridge/test_model_benchmark.py missing model benchmark test coverage: $pattern"
  }
}

$lanServiceText = Get-Content -LiteralPath (Join-PackagePath "bridge/lan_service.py") -Raw
foreach ($pattern in @("LanBridgeSession", "LanBridgeConfig", "BridgeControlState", "EndpointRecord", "endpoint_hello", "claim_brain", "release_brain", "settings_get", "settings_set", "forget_endpoint", "diagnostics_request", "capability_update", "utterance_start", "utterance_end", "early_thinking_frame", "suppress_thinking", "audio_downlink_frames", "stt_command", "tts_command", "WebSocketProtocolError", "downlink_audio_chunk_bytes", "downlink_binary_frame_delay_ms", "downlink_text_frame_delay_ms", "auto_turn_text", "MAX_DOWNLINK_AUDIO_CHUNK_BYTES", "mouth_frame_for_audio_window", "tts_mouth_frames", "user_text=user_text")) {
  if ($lanServiceText -notmatch [regex]::Escape($pattern)) {
    throw "bridge/lan_service.py missing LAN bridge service support: $pattern"
  }
}

$ollamaRunnerText = Get-Content -LiteralPath (Join-PackagePath "bridge/ollama_stackchan_runner.py") -Raw
foreach ($pattern in @("Ollama-backed Stackchan runner", "DEFAULT_MODEL", "STACKCHAN_OLLAMA_EXE", "STACKCHAN_OLLAMA_MODEL", "STACKCHAN_OLLAMA_API_URL", "STACKCHAN_OLLAMA_TRANSPORT", "/api/generate", '"think": False', '"keep_alive": -1', "run_api", "run_cli", "--format", "json", "validate_response")) {
  if ($ollamaRunnerText -notmatch [regex]::Escape($pattern)) {
    throw "bridge/ollama_stackchan_runner.py missing PC brain runner support: $pattern"
  }
}

$ollamaRunnerTestText = Get-Content -LiteralPath (Join-PackagePath "bridge/test_ollama_stackchan_runner.py") -Raw
foreach ($pattern in @("OllamaStackchanRunnerTests", "test_api_uses_warm_json_generation_with_bounded_output", "test_default_transport_falls_back_to_cli_when_api_is_unavailable", "keep_alive", "num_predict")) {
  if ($ollamaRunnerTestText -notmatch [regex]::Escape($pattern)) {
    throw "bridge/test_ollama_stackchan_runner.py missing warm Ollama API coverage: $pattern"
  }
}

$directMlClientText = Get-Content -LiteralPath (Join-PackagePath "bridge/rvc_directml_tts_client.py") -Raw
foreach ($pattern in @("STACKCHAN_RVC_DIRECTML_WORKER_URL", "STACKCHAN_RVC_DIRECTML_TIMEOUT_SECONDS", "/convert", "stackchan.tts-metadata.v1", "audio_b64")) {
  if ($directMlClientText -notmatch [regex]::Escape($pattern)) {
    throw "bridge/rvc_directml_tts_client.py missing Voice V2 client support: $pattern"
  }
}

$directMlWorkerText = Get-Content -LiteralPath (Join-PackagePath "bridge/rvc_directml_worker_service.py") -Raw
foreach ($pattern in @("DirectMlRvcRuntime", "ThreadingHTTPServer", "/health", "/convert")) {
  if ($directMlWorkerText -notmatch [regex]::Escape($pattern)) {
    throw "bridge/rvc_directml_worker_service.py missing Voice V2 worker support: $pattern"
  }
}

$selectedVoiceTtsText = Get-Content -LiteralPath (Join-PackagePath "bridge/selected_voice_tts.py") -Raw
foreach ($pattern in @("stackchan.tts-metadata.v1", "STACKCHAN_SELECTED_VOICE_SAMPLE", "STACKCHAN_FFMPEG_EXE", "STACKCHAN_SELECTED_VOICE_MAX_AUDIO_BYTES", "audio_format", "pcm16", "audio_b64", "stackchan-rvc-bright-robot")) {
  if ($selectedVoiceTtsText -notmatch [regex]::Escape($pattern)) {
    throw "bridge/selected_voice_tts.py missing selected voice TTS support: $pattern"
  }
}

$pcBrainProbeText = Get-Content -LiteralPath (Join-PackagePath "bridge/pc_brain_probe.py") -Raw
foreach ($pattern in @("stackchan.pc-brain-probe.v1", "endpoint_hello", "claim_brain", "utterance_end", "response_end", "binary_frames", "binary_bytes", "PC_BRAIN_PROBE.json", "PC_BRAIN_PROBE.md")) {
  if ($pcBrainProbeText -notmatch [regex]::Escape($pattern)) {
    throw "bridge/pc_brain_probe.py missing PC brain probe support: $pattern"
  }
}

$startPcBrainText = Get-Content -LiteralPath (Join-PackagePath "tools/start_pc_brain.ps1") -Raw
foreach ($pattern in @("STACKCHAN_OLLAMA_EXE", "STACKCHAN_OLLAMA_MODEL", "STACKCHAN_FFMPEG_EXE", "STACKCHAN_SELECTED_VOICE_MAX_AUDIO_BYTES", "ollama_stackchan_runner.py", "whisper_cpp_stt.py", "selected_voice_tts.py", "StreamTtsPhrases", "--stream-tts-phrases", "--tts-phrase-max-chars", "--downlink-binary-frame-delay-ms", "--auto-turn-text", "lan_service.pid")) {
  if ($startPcBrainText -notmatch [regex]::Escape($pattern)) {
    throw "tools/start_pc_brain.ps1 missing PC brain launch support: $pattern"
  }
}

$voiceV2StartText = Get-Content -LiteralPath (Join-PackagePath "tools/start_voice_v2_supervised_validation.ps1") -Raw
foreach ($pattern in @("stackchan.voice-v2-supervised-session.v1", "speaker_stream_chunked", "STACKCHAN_RVC_DIRECTML_WORKER_URL", "StreamTtsPhrases", "OperatorPresent", "ConfirmSpeakerTest", "max_first_audio_ms")) {
  if ($voiceV2StartText -notmatch [regex]::Escape($pattern)) {
    throw "tools/start_voice_v2_supervised_validation.ps1 missing guarded Voice V2 support: $pattern"
  }
}

$voiceV2CheckText = Get-Content -LiteralPath (Join-PackagePath "tools/check_voice_v2_supervised_evidence.ps1") -Raw
foreach ($pattern in @("stackchan.voice-v2-supervised-check.v1", "voice-v2-supervised-ready", "host-robot-byte-match", "host-zero-truncation", "operator-clean-audio", "operator-complete-reply")) {
  if ($voiceV2CheckText -notmatch [regex]::Escape($pattern)) {
    throw "tools/check_voice_v2_supervised_evidence.ps1 missing Voice V2 evidence gates: $pattern"
  }
}

$collectPcBrainEvidenceText = Get-Content -LiteralPath (Join-PackagePath "tools/collect_pc_brain_deploy_evidence.ps1") -Raw
foreach ($pattern in @("stackchan.pc-brain-deploy-evidence.v1", "sourceCommit", "SourceCommit", "Source commit:", "stackchan_debug.json", "PC_BRAIN_DEPLOY_EVIDENCE.json", "PC_BRAIN_DEPLOY_EVIDENCE.md", "bridge_downlink_playback_errors", "audio_stream_not_started", "bridge_downlink_playback_not_started", "audio_stream_chunk_mismatch", "playback_chunk_mismatch", "RunTests")) {
  if ($collectPcBrainEvidenceText -notmatch [regex]::Escape($pattern)) {
    throw "tools/collect_pc_brain_deploy_evidence.ps1 missing PC brain deploy evidence support: $pattern"
  }
}

$checkPcBrainEvidenceText = Get-Content -LiteralPath (Join-PackagePath "tools/check_pc_brain_deploy_evidence.ps1") -Raw
foreach ($pattern in @("stackchan.pc-brain-deploy-evidence-check.v1", "stackchan.pc-brain-deploy-evidence.v1", "pc-brain-deploy-ready", "sourceCommit", "Get-ReviewSourceCommit", "source-commit", "human-review-source-commit-match", "audio-stream-started", "playback-started", "speaker-task-bytes-match", "RequireTests", "RequireReady")) {
  if ($checkPcBrainEvidenceText -notmatch [regex]::Escape($pattern)) {
    throw "tools/check_pc_brain_deploy_evidence.ps1 missing PC brain deploy evidence check support: $pattern"
  }
}

$runPcBrainQuietSoakText = Get-Content -LiteralPath (Join-PackagePath "tools/run_pc_brain_quiet_soak.ps1") -Raw
foreach ($pattern in @("stackchan.pc-brain-quiet-soak.v1", "sourceCommit", "SourceCommit", "Source commit:", "requested_duration_seconds", "interval_seconds", "debug-endpoint-ok", "unexpected_audio_stream_during_quiet_soak", "PC_BRAIN_QUIET_SOAK.json", "PC_BRAIN_QUIET_SOAK.md")) {
  if ($runPcBrainQuietSoakText -notmatch [regex]::Escape($pattern)) {
    throw "tools/run_pc_brain_quiet_soak.ps1 missing PC brain quiet soak support: $pattern"
  }
}

$checkPcBrainQuietSoakText = Get-Content -LiteralPath (Join-PackagePath "tools/check_pc_brain_quiet_soak_evidence.ps1") -Raw
foreach ($pattern in @("stackchan.pc-brain-quiet-soak-evidence-check.v1", "stackchan.pc-brain-quiet-soak.v1", "pc-brain-quiet-soak-ready", "sourceCommit", "Get-ReviewSourceCommit", "source-commit", "human-review-source-commit-match", "MinDurationSeconds", "no-unexpected-audio-streams", "bridge-message-monotonic", "stable-local-ip", "RequireReady")) {
  if ($checkPcBrainQuietSoakText -notmatch [regex]::Escape($pattern)) {
    throw "tools/check_pc_brain_quiet_soak_evidence.ps1 missing PC brain quiet soak evidence check support: $pattern"
  }
}

$flashWifiBridgeText = Get-Content -LiteralPath (Join-PackagePath "tools/flash_wifi_bridge.ps1") -Raw
foreach ($pattern in @("STACKCHAN_WIFI_SSID", "STACKCHAN_WIFI_PASSWORD", "STACKCHAN_BRIDGE_HOST", "STACKCHAN_BRIDGE_PORT", "STACKCHAN_BRIDGE_PATH", "flash_device.cmd", "stackchan_wifi")) {
  if ($flashWifiBridgeText -notmatch [regex]::Escape($pattern)) {
    throw "tools/flash_wifi_bridge.ps1 missing Wi-Fi bridge flash support: $pattern"
  }
}

$platformioWifiEnvText = Get-Content -LiteralPath (Join-PackagePath "tools/platformio_apply_wifi_bridge_env.py") -Raw
foreach ($pattern in @("STACKCHAN_ENABLE_WIFI_BRIDGE", "STACKCHAN_WIFI_SSID", "STACKCHAN_WIFI_PASSWORD", "STACKCHAN_BRIDGE_HOST", "STACKCHAN_BRIDGE_PORT", "STACKCHAN_BRIDGE_PATH", "CPPDEFINES", "CCFLAGS")) {
  if ($platformioWifiEnvText -notmatch [regex]::Escape($pattern)) {
    throw "tools/platformio_apply_wifi_bridge_env.py missing Wi-Fi bridge environment support: $pattern"
  }
}

$desktopPythonRuntimeDocText = Get-Content -LiteralPath (Join-PackagePath "docs/DESKTOP_PYTHON_RUNTIME.md") -Raw
foreach ($pattern in @("Desktop Managed Python Runtime", "python-runtime/", "runtime/python/", "stackchan-python-runtime.json", "prepare_desktop_python_runtime.ps1", "check_desktop_python_runtime_payload.ps1", "export_desktop_package_evidence.ps1", "PackageExtractionRoot", "RequireInstallerPayload", "installer application JAR", "package SHA-256", "STACKCHAN_DESKTOP_PYTHON_RUNTIME_ROOT")) {
  if ($desktopPythonRuntimeDocText -notmatch [regex]::Escape($pattern)) {
    throw "docs/DESKTOP_PYTHON_RUNTIME.md missing managed runtime guidance: $pattern"
  }
}

$prepareDesktopPythonRuntimeText = Get-Content -LiteralPath (Join-PackagePath "tools/prepare_desktop_python_runtime.ps1") -Raw
foreach ($pattern in @("stackchan.desktop-python-runtime-prepare.v1", "stackchan.desktop-python-runtime.v1", "stackchan-python-runtime.json", "Python 3.10+", "Get-RuntimePayloadHash", "check_desktop_python_runtime_payload.ps1", "DryRun", "preparedBy")) {
  if ($prepareDesktopPythonRuntimeText -notmatch [regex]::Escape($pattern)) {
    throw "tools/prepare_desktop_python_runtime.ps1 missing managed runtime prepare support: $pattern"
  }
}

$checkDesktopPythonRuntimeText = Get-Content -LiteralPath (Join-PackagePath "tools/check_desktop_python_runtime_payload.ps1") -Raw
foreach ($pattern in @("stackchan.desktop-python-runtime.v1", "stackchan.desktop-python-runtime-payload.v1", "Find-PythonExecutable", "Test-PythonVersion", "STACKCHAN_BRAIN_PYTHON_RUNTIME", "Python 3.10+", "manifest-platform-match", "manifest-sha256-format", "manifest-python-version-match", "platform =", "pythonVersion =", "runtimeSha256", "runtimeSource", "probedPythonVersion")) {
  if ($checkDesktopPythonRuntimeText -notmatch [regex]::Escape($pattern)) {
    throw "tools/check_desktop_python_runtime_payload.ps1 missing managed runtime payload check support: $pattern"
  }
}

$desktopPythonRuntimeContractText = Get-Content -LiteralPath (Join-PackagePath "tools/test_desktop_python_runtime_payload_contract.ps1") -Raw
foreach ($pattern in @("placeholder sha256 is rejected", "placeholder runtime source is rejected", "platform mismatch is rejected", "pythonVersion mismatch is rejected", "valid desktop runtime payload is accepted", "platform, pythonVersion, probedPythonVersion, runtimeSha256, and runtimeSource", "Desktop Python runtime payload contract tests passed")) {
  if ($desktopPythonRuntimeContractText -notmatch [regex]::Escape($pattern)) {
    throw "tools/test_desktop_python_runtime_payload_contract.ps1 missing managed runtime payload contract coverage: $pattern"
  }
}

$androidUploadSigningContractText = Get-Content -LiteralPath (Join-PackagePath "tools/test_android_upload_signing_contract.ps1") -Raw
foreach ($pattern in @("valid 4096-bit private upload key is accepted", "missing upload-key alias is rejected", "wrong keystore password is rejected", "wrong private-key password is rejected", "weak 2048-bit upload key is rejected", "Android debug certificate subject is rejected", "upload certificate expiring before the Play minimum is rejected", "output exposed a contract credential")) {
  if ($androidUploadSigningContractText -notmatch [regex]::Escape($pattern)) {
    throw "tools/test_android_upload_signing_contract.ps1 missing Android upload signing contract logic: $pattern"
  }
}

$androidEmulatorLaunchSmokeText = Get-Content -LiteralPath (Join-PackagePath "tools/test_android_emulator_launch.ps1") -Raw
foreach ($pattern in @("stackchan.android-emulator-launch-smoke.v1", "ro.kernel.qemu=1", "POST_NOTIFICATIONS", "MainActivity is not the top resumed activity", "CompanionBridgeService is absent after launch", "fatalProcessMatches", "substitutesForPhysicalEvidence", "emulator-install-launch-service-smoke-only")) {
  if ($androidEmulatorLaunchSmokeText -notmatch [regex]::Escape($pattern)) {
    throw "tools/test_android_emulator_launch.ps1 missing Android emulator launch smoke logic: $pattern"
  }
}

$androidEmulatorReleaseEvidenceCheckerText = Get-Content -LiteralPath (Join-PackagePath "tools/check_android_emulator_release_evidence.ps1") -Raw
foreach ($pattern in @("stackchan.android-emulator-release-evidence-check.v1", "stackchan.android-emulator-launch-smoke.v1", "MinApiLevel = 35", "dev.stackchan.companion", "MainActivity was not resumed", "CompanionBridgeService was not present", "fatalProcessMatches must be zero", "substitutesForPhysicalEvidence=false", "APK SHA-256 does not match the release APK")) {
  if ($androidEmulatorReleaseEvidenceCheckerText -notmatch [regex]::Escape($pattern)) {
    throw "tools/check_android_emulator_release_evidence.ps1 missing release APK binding logic: $pattern"
  }
}

$androidEmulatorReleaseEvidenceContractText = Get-Content -LiteralPath (Join-PackagePath "tools/test_android_emulator_release_evidence_contract.ps1") -Raw
foreach ($pattern in @("matching release APK evidence", "stale APK hash is rejected", "old emulator API is rejected", "failed launch smoke is rejected", "non-resumed activity is rejected", "missing bridge service is rejected", "fatal process match is rejected", "physical-evidence substitution is rejected", "wrong package identity is rejected", "9/9 passed")) {
  if ($androidEmulatorReleaseEvidenceContractText -notmatch [regex]::Escape($pattern)) {
    throw "tools/test_android_emulator_release_evidence_contract.ps1 missing contract coverage: $pattern"
  }
}

$desktopPackageEvidenceExporterText = Get-Content -LiteralPath (Join-PackagePath "tools/export_desktop_package_evidence.ps1") -Raw
foreach ($pattern in @("stackchan.desktop-package-evidence.v1", "stackchan.desktop-python-runtime-prepare.v1", "stackchan.desktop-python-runtime-payload.v1", "Get-RuntimePayloadHash", "native-app-resources", "Expand-DesktopPackage", "RequireInstallerPayload", "RequireLaunchEvidence", "launchEvidence", "processedPayloadSha256", "processedFileCount", "Installer runtime payload hash does not match processed Gradle resources", "PackageExtractionRoot")) {
  if ($desktopPackageEvidenceExporterText -notmatch [regex]::Escape($pattern)) {
    throw "tools/export_desktop_package_evidence.ps1 missing native package/runtime evidence logic: $pattern"
  }
}

$desktopPackageLaunchText = Get-Content -LiteralPath (Join-PackagePath "tools/test_desktop_package_launch.ps1") -Raw
foreach ($pattern in @("stackchan.desktop-package-launch-evidence.v1", "stackchan.desktop-packaged-runtime-smoke.v1", "exact-native-package-extraction-and-headless-launch", "package-extraction", "substitutesForTargetInstall", "--package-smoke-output=", "--package-smoke-context=")) {
  if ($desktopPackageLaunchText -notmatch [regex]::Escape($pattern)) { throw "tools/test_desktop_package_launch.ps1 missing exact-package launch logic: $pattern" }
}

$desktopTargetInstallToolText = Get-Content -LiteralPath (Join-PackagePath "tools/install_desktop_companion_package.ps1") -Raw
foreach ($pattern in @("stackchan.desktop-target-install-evidence.v1", "operator-target-workstation", "ci-native-runner", "msiexec-install", "dpkg-install", "dmg-application-copy", "installed-native-package-headless-runtime-probe", "exact-native-package-install-and-headless-launch", "substitutesForHumanAcceptance")) {
  if ($desktopTargetInstallToolText -notmatch [regex]::Escape($pattern)) { throw "tools/install_desktop_companion_package.ps1 missing native target-install evidence logic: $pattern" }
}

$desktopTargetInstallCheckerText = Get-Content -LiteralPath (Join-PackagePath "tools/check_desktop_target_install_evidence.ps1") -Raw
foreach ($pattern in @("stackchan.desktop-target-install-evidence-check.v1", "desktop-target-install-ready", "RequireOperatorTarget", "expected-package-sha256", "expected-source-commit", "installed-runtime-probe", "human-acceptance-scope")) {
  if ($desktopTargetInstallCheckerText -notmatch [regex]::Escape($pattern)) { throw "tools/check_desktop_target_install_evidence.ps1 missing native target-install validation: $pattern" }
}

$desktopTargetInstallContractText = Get-Content -LiteralPath (Join-PackagePath "tools/test_desktop_target_install_evidence_contract.ps1") -Raw
foreach ($pattern in @("operator target-install evidence is accepted for Windows, Linux, and macOS", "stale target-install package hash is rejected", "CI native-runner evidence cannot replace operator target evidence", "package extraction cannot replace installed launcher evidence", "missing install and launch exit codes are rejected", "mismatched target-install source commit is rejected", "Desktop target install evidence contract tests passed")) {
  if ($desktopTargetInstallContractText -notmatch [regex]::Escape($pattern)) { throw "tools/test_desktop_target_install_evidence_contract.ps1 missing target-install contract coverage: $pattern" }
}

$desktopPackageEvidenceContractText = Get-Content -LiteralPath (Join-PackagePath "tools/test_desktop_package_evidence_contract.ps1") -Raw
foreach ($pattern in @("complete installer-derived desktop package evidence is accepted", "installed launch context cannot replace package-extraction evidence", "installer runtime tampering is rejected", "JAR-embedded executable runtime is rejected", "aggregate companion evidence accepts all three native package reports", "aggregate companion evidence rejects installer-derived runtime mismatch", "aggregate companion evidence rejects stale exact-package launch evidence", "strict aggregate evidence rejects a missing native package report", "wrong platform package extension is rejected", "processed runtime tampering is rejected", "runtime prepare platform mismatch is rejected", "Desktop package evidence contract tests passed")) {
  if ($desktopPackageEvidenceContractText -notmatch [regex]::Escape($pattern)) {
    throw "tools/test_desktop_package_evidence_contract.ps1 missing native package/runtime evidence contract coverage: $pattern"
  }
}

$desktopV1BundleCheckerText = Get-Content -LiteralPath (Join-PackagePath "tools/check_desktop_v1_evidence_bundle.ps1") -Raw
foreach ($pattern in @("stackchan.desktop-v1-evidence-bundle.v1", "desktop-v1-evidence-ready", "pending-desktop-v1-evidence-bundle", "stackchan.desktop-python-runtime-payload.v1", "stackchan.desktop-target-install-evidence.v1", "windowsTargetInstallReport", "macosTargetInstallReport", "linuxTargetInstallReport", "Test-DesktopTargetInstallReport", "RequireOperatorTarget", "Target installation decision: pass", "pc-brain-deploy-ready", "pc-brain-quiet-soak-ready", "production-voice-source-ready", "companion-readiness-source-commit-match", "pc-brain-deploy-commit-match", "pc-brain-quiet-soak-commit-match", "voice-source-commit-match", "sourceCommit", "windowsMsiSha256", "macosDmgSha256", "linuxDebSha256", "runtime-windows-summary", "runtime-macos-summary", "runtime-linux-summary", "Test-RuntimePayloadSummary", "runtimeSha256", "runtimeSource", "probedPythonVersion", "Get-ReviewSourceCommit", "Source commit:", "DESKTOP_V1_REVIEW.md", "RequireReady")) {
  if ($desktopV1BundleCheckerText -notmatch [regex]::Escape($pattern)) {
    throw "tools/check_desktop_v1_evidence_bundle.ps1 missing desktop v1 evidence bundle logic: $pattern"
  }
}

$desktopV1BundleContractText = Get-Content -LiteralPath (Join-PackagePath "tools/test_desktop_v1_evidence_bundle_contract.ps1") -Raw
foreach ($pattern in @("placeholder Desktop v1 evidence bundle is pending", "complete Desktop v1 evidence bundle is accepted", "desktop package artifact hashes", "missing Desktop v1 runtime payload summary is rejected", "missing Desktop v1 runtime payload source is rejected", "mismatched Desktop v1 runtime payload platform is rejected", "stale Desktop v1 target-install package hash is rejected", "CI install rehearsal cannot replace Desktop v1 operator target evidence", "mismatched Desktop v1 companion readiness source commit is rejected", "mismatched Desktop v1 review source commit is rejected", "mismatched Desktop v1 voice-source commit is rejected", "mismatched Desktop v1 PC Brain deploy commit is rejected", "mismatched Desktop v1 PC Brain quiet-soak commit is rejected", "desktop-v1-evidence-ready", "pending-desktop-v1-evidence-bundle", "Desktop v1 evidence bundle contract tests passed")) {
  if ($desktopV1BundleContractText -notmatch [regex]::Escape($pattern)) {
    throw "tools/test_desktop_v1_evidence_bundle_contract.ps1 missing desktop v1 evidence bundle contract coverage: $pattern"
  }
}

$companionV1BundleCheckerText = Get-Content -LiteralPath (Join-PackagePath "tools/check_companion_v1_evidence_bundle.ps1") -Raw
foreach ($pattern in @("stackchan.companion-v1-evidence-bundle.v1", "companion-v1-evidence-ready", "pending-companion-v1-evidence-bundle", "stackchan.android-v1-evidence-bundle-check.v1", "stackchan.desktop-v1-evidence-bundle-check.v1", "stackchan.rollout-status.v1", "consumer-promotion-ready", "companion-readiness-commit-match", "release-evidence-commit-match", "github-actions-commit-match", "rollout-status-version-match", "android-v1-commit-match", "android-v1-application-id-match", "android-v1-version-name-match", "android-v1-version-code-match", "android-v1-gemma-benchmark-summary", "android-v1-dashboard-media-summary", "gemmaBenchmarkProfile", "gemmaBenchmarkMedianMs", "androidGemmaBenchmarkProfile", "androidGemmaBenchmarkMedianMs", "androidDashboardMediaIds", "phone-live-dashboard", "android-v1-release-apk-hash-match", "android-v1-release-aab-hash-match", "desktop-v1-commit-match", "desktop-v1-artifact-hashes-match", "release-package-evidence-present", "voice-source-commit-match", "rollout-hardware-root-match", "rollout-hardware-commit-match", "sourceCommit", "firmwareSourceCommit", "firmware-source-commit", "releaseVersion", "applicationId", "apkSha256", "versionCode", "packageEvidence", "Get-ReviewSourceCommit", "Get-ReviewReleaseVersion", "Get-Sha256Text", "Convert-ToAndroidVersionName", "Get-AndroidSourceApplicationId", "Test-AndroidApplicationIdMatchesSource", "Get-AndroidSourceVersionCode", "Test-AndroidVersionCodeMatchesSource", "Test-AndroidV1EvidenceSummary", "Test-AndroidReleaseApkHashMatchesReleaseEvidence", "Test-AndroidReleaseAabHashMatchesReleaseEvidence", "Test-DesktopArtifactHashesMatchReleaseEvidence", "Test-ReleasePackageEvidencePresent", "Test-RolloutHardwareEvidence", "Source commit:", "Release version:", "COMPANION_V1_REVIEW.md", "RequireReady")) {
  if ($companionV1BundleCheckerText -notmatch [regex]::Escape($pattern)) {
    throw "tools/check_companion_v1_evidence_bundle.ps1 missing companion v1 evidence bundle logic: $pattern"
  }
}

$companionV1BundleContractText = Get-Content -LiteralPath (Join-PackagePath "tools/test_companion_v1_evidence_bundle_contract.ps1") -Raw
foreach ($pattern in @("placeholder Companion v1 evidence bundle is pending", "complete Companion v1 evidence bundle with distinct release and firmware commits is accepted", "legacy same-commit Companion v1 evidence bundle remains accepted", "stale Companion v1 Android evidence summary is rejected", "slow or incomplete Companion v1 Android evidence summary is rejected", "Android Gemma benchmark and dashboard media summaries", "mismatched Companion v1 release ZIP hash is rejected", "missing Companion v1 release package evidence is rejected", "mismatched Companion v1 source-readiness commit is rejected", "mismatched Companion v1 hardware evidence root is rejected", "mismatched Companion v1 hardware evidence commit is rejected", "mismatched Companion v1 report commit is rejected", "mismatched Companion v1 Android bundle commit is rejected", "mismatched Companion v1 Android applicationId is rejected", "mismatched Companion v1 Android app version is rejected", "mismatched Companion v1 Android app versionCode is rejected", "mismatched Companion v1 Android release APK hash is rejected", "mismatched Companion v1 Android release AAB hash is rejected", "mismatched Companion v1 Desktop package hash is rejected", "mismatched Companion v1 Desktop bundle commit is rejected", "mismatched Companion v1 voice-source commit is rejected", "mismatched Companion v1 review source commit is rejected", "mismatched Companion v1 review release version is rejected", "companion-v1-evidence-ready", "pending-companion-v1-evidence-bundle", "Companion v1 evidence bundle contract tests passed")) {
  if ($companionV1BundleContractText -notmatch [regex]::Escape($pattern)) {
    throw "tools/test_companion_v1_evidence_bundle_contract.ps1 missing companion v1 evidence bundle contract coverage: $pattern"
  }
}

$lanServiceTestText = Get-Content -LiteralPath (Join-PackagePath "bridge/test_lan_service.py") -Raw
foreach ($pattern in @("LanServiceTests", "test_session_maps_device_messages_to_bridge_frames", "test_endpoint_controls_track_owner_settings_and_forget", "test_endpoint_control_state_survives_sequential_sessions", "test_settings_version_conflict_returns_current_snapshot", "test_identified_non_owner_cannot_start_speech_turn", "test_audio_downlink_clamps_chunks_to_firmware_payload_limit", "test_binary_audio_upload_tracks_telemetry_and_requires_stt_or_transcript", "test_audio_only_turn_uses_configured_stt_command", "test_configured_tts_command_replaces_response_mouth_beats")) {
  if ($lanServiceTestText -notmatch [regex]::Escape($pattern)) {
    throw "bridge/test_lan_service.py missing LAN bridge service test coverage: $pattern"
  }
}

$lanSmokeText = Get-Content -LiteralPath (Join-PackagePath "bridge/lan_smoke.py") -Raw
foreach ($pattern in @("stackchan.lan-smoke.v1", "SmokeServer", "SmokeClient", "encode_client_frame", "build_report", "LAN_SMOKE.md", "lan_smoke.json", "audio-loop", "thinking-latency", "endpoint-controls", "frame_timings", "THINKING_LATENCY_MAX_MS", "validate_thinking_latency", "validate_endpoint_controls", "fake_stt", "fake_tts", "binary_downlink_byte_mismatch", "forget_endpoint")) {
  if ($lanSmokeText -notmatch [regex]::Escape($pattern)) {
    throw "bridge/lan_smoke.py missing LAN smoke support: $pattern"
  }
}

$lanSmokeTestText = Get-Content -LiteralPath (Join-PackagePath "bridge/test_lan_smoke.py") -Raw
foreach ($pattern in @("LanSmokeTests", "test_client_frames_are_masked_for_server_protocol_path", "test_build_report_exercises_text_and_audio_socket_paths", "test_write_outputs_creates_json_markdown_and_per_scenario_reports", "test_smoke_report_does_not_leak_configured_runner_environment", "thinking-latency", "endpoint-controls", "owner_status", "forget_endpoint_result", "frame_timings")) {
  if ($lanSmokeTestText -notmatch [regex]::Escape($pattern)) {
    throw "bridge/test_lan_smoke.py missing LAN smoke test coverage: $pattern"
  }
}

$sttAdapterText = Get-Content -LiteralPath (Join-PackagePath "bridge/stt_adapter.py") -Raw
foreach ($pattern in @("STACKCHAN_AUDIO_SAMPLE_RATE", "STACKCHAN_AUDIO_FORMAT", "STACKCHAN_AUDIO_BYTES", "run_stt_command", "normalize_transcript")) {
  if ($sttAdapterText -notmatch [regex]::Escape($pattern)) {
    throw "bridge/stt_adapter.py missing STT adapter support: $pattern"
  }
}

$sttAdapterTestText = Get-Content -LiteralPath (Join-PackagePath "bridge/test_stt_adapter.py") -Raw
foreach ($pattern in @("SttAdapterTests", "test_transcript_output_accepts_plain_text_and_json", "test_stt_command_receives_pcm_and_audio_environment", "test_empty_stt_output_is_an_execution_error", "test_whisper_adapter_runs_fake_whisper_cli_and_normalizes")) {
  if ($sttAdapterTestText -notmatch [regex]::Escape($pattern)) {
    throw "bridge/test_stt_adapter.py missing STT adapter test coverage: $pattern"
  }
}

$whisperCppSttText = Get-Content -LiteralPath (Join-PackagePath "bridge/whisper_cpp_stt.py") -Raw
foreach ($pattern in @("STACKCHAN_WHISPER_CPP_EXE", "STACKCHAN_WHISPER_MODEL", "whisper.cpp", "transcribe_pcm_with_whisper_cpp", "whisper-cli.exe")) {
  if ($whisperCppSttText -notmatch [regex]::Escape($pattern)) {
    throw "bridge/whisper_cpp_stt.py missing whisper.cpp adapter support: $pattern"
  }
}

$setupWhisperText = Get-Content -LiteralPath (Join-PackagePath "tools/setup_whisper_cpp.ps1") -Raw
foreach ($pattern in @("stackchan.whisper-cpp-setup.v1", "whisper-bin-x64.zip", 'ggml-$Model.bin', "STACKCHAN_WHISPER_CPP_EXE", "STACKCHAN_WHISPER_MODEL")) {
  if ($setupWhisperText -notmatch [regex]::Escape($pattern)) {
    throw "tools/setup_whisper_cpp.ps1 missing whisper.cpp setup support: $pattern"
  }
}

$ttsAdapterText = Get-Content -LiteralPath (Join-PackagePath "bridge/tts_adapter.py") -Raw
foreach ($pattern in @("STACKCHAN_TTS_TEXT_BYTES", "STACKCHAN_TTS_VOICE", "STACKCHAN_TTS_OUTPUT", "normalize_tts_output", "audio_b64", "stackchan.tts-metadata.v1")) {
  if ($ttsAdapterText -notmatch [regex]::Escape($pattern)) {
    throw "bridge/tts_adapter.py missing TTS adapter support: $pattern"
  }
}

$ttsAdapterTestText = Get-Content -LiteralPath (Join-PackagePath "bridge/test_tts_adapter.py") -Raw
foreach ($pattern in @("TtsAdapterTests", "test_compact_beat_output_normalizes_and_marks_final", "test_sidecar_frame_output_uses_frame_timing", "test_optional_audio_b64_is_decoded_and_counted", "test_tts_command_receives_text_and_voice_environment")) {
  if ($ttsAdapterTestText -notmatch [regex]::Escape($pattern)) {
    throw "bridge/test_tts_adapter.py missing TTS adapter test coverage: $pattern"
  }
}

$hardwareSimulatorText = Get-Content -LiteralPath (Join-PackagePath "bridge/hardware_simulator.py") -Raw
foreach ($pattern in @("stackchan.hardware-sim.v1", "VirtualStackchanHardware", "MAX_AUDIO_STREAM_CHUNK_BYTES", "AUDIO_DOWNLINK_TEST_BYTES", "AUDIO_UPLOAD_TEST_BYTES", "audio_stream_chunk_bytes_declared", "audio_stream_chunk_bytes_max", "audio_stream_chunk_too_large", "bridge_upload_audio_bytes", "bridge_upload_audio_chunks", "bridge_stt_runs", "bridge_stt_last_source", "STACKCHAN_STT_COMMAND", "bridge_downlink_ready", "bridge_downlink_streams", "bridge_downlink_completed", "bridge_downlink_chunks", "bridge_downlink_bytes", "bridge_downlink_errors", "full_audio_downlink_frames", "lan_text_frames", "conversation_rehearsal_frames", "conversation_tts_downlink_frames", "conversation_audio_loop_frames", "lan_tts_downlink_frames", "lan_audio_loop_frames", "conversation_first_audio_latency_ms", "conversation-rehearsal", "conversation-tts-downlink", "conversation-audio-loop", "arrival_rehearsal_frames", "servo_safety_rehearsal_frames", "servo-safety-rehearsal", "servo_blocked_commands", "servo_clipped_commands", "motion_disabled_mouth_frames", "bridge_kill_recovery_frames", "offline_command_fallback_frames", "offline-command-fallback", "packaged_prompt_requests", "control_input", "power_cycle", "display_frames", "speaker_frames_submitted", "offline_fallback_prompts", "bridge_recoveries", "audio_streams_aborted", "audio_stream_start", "audio_stream_end", "binary_without_audio_stream", "audio_stream_payload_bytes_mismatch", "bridge_timeout", "bridge-kill-recovery", "hardware_simulation.json", "HARDWARE_SIMULATION.md")) {
  if ($hardwareSimulatorText -notmatch [regex]::Escape($pattern)) {
    throw "bridge/hardware_simulator.py missing hardware simulation support: $pattern"
  }
}

$hardwareSimulatorTestText = Get-Content -LiteralPath (Join-PackagePath "bridge/test_hardware_simulator.py") -Raw
foreach ($pattern in @("HardwareSimulatorTests", "test_reference_scenario_reaches_ready_with_mouth_frames", "test_lan_text_scenario_exercises_local_bridge_path", "test_conversation_rehearsal_covers_wake_to_lipsync_to_ready", "test_conversation_tts_downlink_normalizes_lan_wav_to_pcm16_playback", "test_conversation_audio_loop_runs_stt_model_tts_and_pcm16_playback", "test_audio_downlink_counts_binary_stream_payload", "test_arrival_rehearsal_exercises_virtual_device_shell", "test_servo_safety_rehearsal_blocks_motion_but_keeps_face_and_audio_alive", "test_bridge_kill_recovery_uses_offline_fallback_and_returns_ready", "test_offline_command_fallback_uses_packaged_prompts_without_bridge", "test_binary_without_audio_stream_fails", "test_oversized_audio_stream_chunk_fails", "test_oversized_declared_audio_stream_chunk_fails", "test_timeout_scenario_reports_expected_failure")) {
  if ($hardwareSimulatorTestText -notmatch [regex]::Escape($pattern)) {
    throw "bridge/test_hardware_simulator.py missing hardware simulator test coverage: $pattern"
  }
}

$prearrivalSimCheckText = Get-Content -LiteralPath (Join-PackagePath "bridge/prearrival_sim_check.py") -Raw
foreach ($pattern in @("stackchan.prearrival-sim-check.v1", "build_report", "PREARRIVAL_SIM_CHECK.md", "prearrival_sim_check.json", "run_probe", "write_hardware_outputs", "build_lan_smoke_report", "write_lan_smoke_outputs", "run_benchmark", "write_model_benchmark_outputs", "model-benchmark-candidate", "Model Benchmark", "lan_bridge_smoke", "lan-websocket-smoke", "lan-smoke/LAN_SMOKE.md", "thinking_latency", "Thinking latency", "servo_safety_rehearsal", "Servo safety rehearsal", "proxy-pass-engines-unconfigured", "pending-device")) {
  if ($prearrivalSimCheckText -notmatch [regex]::Escape($pattern)) {
    throw "bridge/prearrival_sim_check.py missing pre-arrival simulation check support: $pattern"
  }
}

$prearrivalSimCheckTestText = Get-Content -LiteralPath (Join-PackagePath "bridge/test_prearrival_sim_check.py") -Raw
foreach ($pattern in @("PrearrivalSimCheckTests", "test_unconfigured_engines_do_not_fail_hardware_proxy", "test_optional_model_benchmark_records_candidate_gate", "test_write_report_includes_machine_and_human_outputs", "model-benchmark-candidate", "lan_bridge_smoke", "thinking_latency", "servo_safety_rehearsal", "Servo safety rehearsal", "lan-smoke", "LAN WebSocket Smoke", "Thinking latency", "gemma4-e2b-litert-lm")) {
  if ($prearrivalSimCheckTestText -notmatch [regex]::Escape($pattern)) {
    throw "bridge/test_prearrival_sim_check.py missing pre-arrival simulation test coverage: $pattern"
  }
}

$bridgeReferenceReadmeText = Get-Content -LiteralPath (Join-PackagePath "bridge/README.md") -Raw
foreach ($pattern in @("--format prompt", "--user-text", "--name Rob", "--topic voice", "--physical-context", "--memory-file", "--save-memory", "--reset-memory", "--model-response", "character_harness.py", "character_red_team.py", "summary.gate.ready", "local_runner.py", "engine_probe.py", "ENGINE_PROBE.md", "model_benchmark.py", "MODEL_BENCHMARK.md", "gemma4-e2b-litert-lm", "lan_service.py", "lan_smoke.py", "LAN_SMOKE.md/json", "hardware_simulator.py", "virtual Stackchan", "prearrival_sim_check.py", "PREARRIVAL_SIM_CHECK.md/json")) {
  if ($bridgeReferenceReadmeText -notmatch [regex]::Escape($pattern)) {
    throw "bridge/README.md missing reference bridge prompt/memory guidance: $pattern"
  }
}

$bridgeReferenceTestRunnerText = Get-Content -LiteralPath (Join-PackagePath "tools/run_bridge_reference_tests.ps1") -Raw
foreach ($pattern in @("preview_python_resolver.ps1", "Get-StackchanPreviewPython", "unittest discover", "bridge", "test_*.py")) {
  if ($bridgeReferenceTestRunnerText -notmatch [regex]::Escape($pattern)) {
    throw "tools/run_bridge_reference_tests.ps1 missing reference bridge test runner logic: $pattern"
  }
}

$hardwareSimulationRunnerText = Get-Content -LiteralPath (Join-PackagePath "tools/run_hardware_simulation.ps1") -Raw
foreach ($pattern in @("preview_python_resolver.ps1", "Get-StackchanPreviewPython", "hardware_simulator.py", "--out-dir", "output/hardware-sim/latest", "Hardware simulation report")) {
  if ($hardwareSimulationRunnerText -notmatch [regex]::Escape($pattern)) {
    throw "tools/run_hardware_simulation.ps1 missing hardware simulation runner logic: $pattern"
  }
}

$prearrivalSimCheckRunnerText = Get-Content -LiteralPath (Join-PackagePath "tools/run_prearrival_sim_check.ps1") -Raw
foreach ($pattern in @("preview_python_resolver.ps1", "Get-StackchanPreviewPython", "prearrival_sim_check.py", "--out-dir", "output/prearrival-sim/latest", "--run-model-smoke", "--run-model-benchmark", "Pre-arrival simulation check failed")) {
  if ($prearrivalSimCheckRunnerText -notmatch [regex]::Escape($pattern)) {
    throw "tools/run_prearrival_sim_check.ps1 missing pre-arrival simulation runner logic: $pattern"
  }
}

$lanSmokeRunnerText = Get-Content -LiteralPath (Join-PackagePath "tools/run_lan_smoke.ps1") -Raw
foreach ($pattern in @("preview_python_resolver.ps1", "Get-StackchanPreviewPython", "lan_smoke.py", "--out-dir", "output/lan-smoke/latest", "LAN bridge smoke check failed")) {
  if ($lanSmokeRunnerText -notmatch [regex]::Escape($pattern)) {
    throw "tools/run_lan_smoke.ps1 missing LAN smoke runner logic: $pattern"
  }
}

$androidApkInstallerText = Get-Content -LiteralPath (Join-PackagePath "tools/install_android_companion_apk.ps1") -Raw
foreach ($pattern in @("stackchan.android-apk-install.v1", "adb was not found", "Missing Android APK", "source checkout", ".\gradlew.bat :app-android:assembleRelease", "devices", "Multiple adb devices", "install", "-r", "dumpsys", "versionName", "versionCode", "sourceCommit", "-SourceCommit", "git rev-parse HEAD", "android_apk_install.json", "ANDROID_APK_INSTALL.md", "adb_install.log", "adb_dumpsys_package.txt", "-ApkPath", "-Serial")) {
  if ($androidApkInstallerText -notmatch [regex]::Escape($pattern)) {
    throw "tools/install_android_companion_apk.ps1 missing Android APK install evidence logic: $pattern"
  }
}

$androidLogcatCaptureText = Get-Content -LiteralPath (Join-PackagePath "tools/capture_android_companion_logcat.ps1") -Raw
foreach ($pattern in @("stackchan.android-companion-logcat.v1", "adb was not found", "devices", "Multiple adb devices", "logcat", "ForegroundService", "CompanionBridgeService", "android_companion_logcat.txt", "ANDROID_COMPANION_LOGCAT.md", "android_companion_logcat.json", "-Serial", "-Lines")) {
  if ($androidLogcatCaptureText -notmatch [regex]::Escape($pattern)) {
    throw "tools/capture_android_companion_logcat.ps1 missing Android logcat capture logic: $pattern"
  }
}

$hardwareSimulationComparatorText = Get-Content -LiteralPath (Join-PackagePath "tools/compare_hardware_sim_baseline.ps1") -Raw
foreach ($pattern in @("stackchan.hardware-sim-compare.v1", "simulation/hardware-sim/latest/hardware_simulation.json", "SIM_HARDWARE_COMPARE.json", "SIM_HARDWARE_COMPARE.md", "RUN_HARDWARE_SIM_BASELINE.cmd", "RUN_BRIDGE_REPLAY.cmd", "bridge_parse_errors", "bridge_timeouts", "bridge_downlink_errors", "bridge_downlink_playback_errors", "arrival-rehearsal", "conversation-audio-loop", "bridge-kill-recovery", "advisory comparison only")) {
  if ($hardwareSimulationComparatorText -notmatch [regex]::Escape($pattern)) {
    throw "tools/compare_hardware_sim_baseline.ps1 missing hardware simulation comparison logic: $pattern"
  }
}

$engineProbeRunnerText = Get-Content -LiteralPath (Join-PackagePath "tools/run_engine_probe.ps1") -Raw
foreach ($pattern in @("preview_python_resolver.ps1", "Get-StackchanPreviewPython", "engine_probe.py", "--out-dir", "output/engine-probe/latest", "--run-model-smoke", "Engine probe report")) {
  if ($engineProbeRunnerText -notmatch [regex]::Escape($pattern)) {
    throw "tools/run_engine_probe.ps1 missing engine probe runner logic: $pattern"
  }
}

$litertSmokeRunnerText = Get-Content -LiteralPath (Join-PackagePath "tools/run_litert_lm_smoke.ps1") -Raw
foreach ($pattern in @("preview_python_resolver.ps1", "Get-StackchanPreviewPython", "litert_lm_contract_smoke.py", "--out-dir", "output/litert-lm-smoke/latest", "LiteRT-LM contract smoke report")) {
  if ($litertSmokeRunnerText -notmatch [regex]::Escape($pattern)) {
    throw "tools/run_litert_lm_smoke.ps1 missing LiteRT-LM smoke runner logic: $pattern"
  }
}

$characterHarnessTestRunnerText = Get-Content -LiteralPath (Join-PackagePath "tools/run_character_harness_tests.ps1") -Raw
foreach ($pattern in @("preview_python_resolver.ps1", "Get-StackchanPreviewPython", "unittest discover", "test_character_harness.py")) {
  if ($characterHarnessTestRunnerText -notmatch [regex]::Escape($pattern)) {
    throw "tools/run_character_harness_tests.ps1 missing character harness test runner logic: $pattern"
  }
}

$characterRedTeamRunnerText = Get-Content -LiteralPath (Join-PackagePath "tools/run_character_red_team.ps1") -Raw
foreach ($pattern in @("preview_python_resolver.ps1", "Get-StackchanPreviewPython", "character_red_team.py", "--profile", "--persona", "--out-dir", "--command", "--require-runner", "--json")) {
  if ($characterRedTeamRunnerText -notmatch [regex]::Escape($pattern)) {
    throw "tools/run_character_red_team.ps1 missing red-team runner logic: $pattern"
  }
}

$firmwareWorkflowText = Get-Content -LiteralPath (Join-PackagePath "provenance/firmware.yml") -Raw
foreach ($pattern in @("character_red_team.py", "character-red-team", "CHARACTER_RED_TEAM.md", "character_red_team.json")) {
  if ($firmwareWorkflowText -notmatch [regex]::Escape($pattern)) {
    throw "provenance/firmware.yml missing character red-team CI artifact support: $pattern"
  }
}

Assert-File "firmware/display_only/firmware.bin" 100000
Assert-File "firmware/servo_calibration/firmware.bin" 100000
Assert-File "firmware/full_online/firmware.bin" 1000000
Assert-File "media/stackchan_alive_preview.png" 1000
Assert-File "media/stackchan_alive_expression_sheet.png" 2000
Assert-File "media/stackchan_alive_preview.gif" 1000
Assert-File "media/stackchan_alive_preview.mp4" 1000
Assert-File "media/stackchan_alive_speech_preview.gif" 1000
Assert-File "media/diagrams/01-system-overview.png" 1000
Assert-File "media/diagrams/02-firmware-task-architecture.png" 1000
Assert-File "media/diagrams/03-persona-engine.png" 1000
Assert-File "media/diagrams/04-face-runtime.png" 1000
Assert-File "media/diagrams/05-motion-servo-safety.png" 1000
Assert-File "media/diagrams/06-brain-bridge-protocol.png" 1000
Assert-File "media/diagrams/08-io-abstraction-builds.png" 1000
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
Assert-Mp3File "media/voice/stackchan_spark_audition_bright_robot_greeting.mp3"
Assert-Mp3File "media/voice/stackchan_spark_thinking.mp3"
Assert-File "media/voice/sidecars/stackchan_spark_greeting.speech_envelope.json" 1000
Assert-File "media/voice/sidecars/stackchan_spark_thinking.speech_envelope.json" 1000
Assert-File "media/voice/sidecars/stackchan_spark_safety.speech_envelope.json" 1000
Assert-File "media/voice/VOICE_SAMPLES.md" 100
Assert-File "media/voice/VOICE_AUDITION.html" 1000
Assert-File "media/voice/rvc/README.md" 400

Assert-Bytes "media/stackchan_alive_preview.png" ([byte[]](0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a))
Assert-Bytes "media/stackchan_alive_expression_sheet.png" ([byte[]](0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a))
Assert-Bytes "media/stackchan_alive_preview.gif" ([byte[]](0x47, 0x49, 0x46, 0x38))
Assert-Bytes "media/stackchan_alive_preview.mp4" ([byte[]](0x66, 0x74, 0x79, 0x70)) 4
Assert-Bytes "media/stackchan_alive_speech_preview.gif" ([byte[]](0x47, 0x49, 0x46, 0x38))
Assert-Bytes "media/diagrams/01-system-overview.png" ([byte[]](0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a))
Assert-Bytes "media/diagrams/02-firmware-task-architecture.png" ([byte[]](0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a))
Assert-Bytes "media/diagrams/03-persona-engine.png" ([byte[]](0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a))
Assert-Bytes "media/diagrams/04-face-runtime.png" ([byte[]](0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a))
Assert-Bytes "media/diagrams/05-motion-servo-safety.png" ([byte[]](0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a))
Assert-Bytes "media/diagrams/06-brain-bridge-protocol.png" ([byte[]](0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a))
Assert-Bytes "media/diagrams/08-io-abstraction-builds.png" ([byte[]](0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a))
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
& (Join-PackagePath "tools/verify_voice_samples.ps1") -VoiceRoot (Join-PackagePath "media/voice")
& (Join-PackagePath "tools/verify_tracked_rvc_assets.ps1") -VoiceRoot (Join-PackagePath "media/voice/rvc")
foreach ($asset in @($personaPromptAssets.assets)) {
  & (Join-PackagePath "tools/verify_speech_envelope_sidecar.ps1") -Path (Join-PackagePath ([string]$asset.sidecar_path))
}

& (Join-Path $PSScriptRoot "verify_preview_media.ps1") -MediaRoot (Join-PackagePath "media")
& (Join-PackagePath "tools/verify_face_phase_a.ps1") -ArtifactsRoot (Join-PackagePath "artifacts/face")
& (Join-PackagePath "tools/verify_face_phase_b.ps1") -ArtifactsRoot (Join-PackagePath "artifacts/face")
& (Join-PackagePath "tools/verify_face_phase_c.ps1") -ArtifactsRoot (Join-PackagePath "artifacts/face")
& (Join-PackagePath "tools/verify_face_phase_d.ps1") -ArtifactsRoot (Join-PackagePath "artifacts/face")
& (Join-PackagePath "tools/verify_face_phase_e.ps1") -ArtifactsRoot (Join-PackagePath "artifacts/face")

$manifestPath = Join-PackagePath "release_manifest.json"
$manifest = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json

if ($manifest.releaseAssetManifest -ne "release_assets.json") {
  throw "Manifest releaseAssetManifest mismatch: $($manifest.releaseAssetManifest)"
}

$contractZipPath = if ([string]::IsNullOrWhiteSpace($ZipPath)) {
  Join-Path $repoRoot "output/release/stackchan_alive_$Version.zip"
} else {
  $ZipPath
}
& powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-PackagePath "tools/verify_release_asset_contract.ps1") `
  -Version $Version `
  -PackageRoot $packageRootPath `
  -ZipPath $contractZipPath `
  -ZipSidecarPath "$contractZipPath.sha256" `
  -SkipExternalFiles
if ($LASTEXITCODE -ne 0) {
  throw "Release asset contract verification failed."
}

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
if (-not ($envs -contains "stackchan") -or
    -not ($envs -contains "stackchan_servo_calibration") -or
    -not ($envs -contains "stackchan_release_full")) {
  throw "Manifest missing expected environments"
}

if ($manifest.status -notmatch "public release" -or $manifest.status -notmatch "accepted by owner") {
  throw "Manifest status must identify the owner-accepted public release"
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
if ($manifest.thirdPartyNotices -ne "THIRD_PARTY_NOTICES.md") {
  throw "Manifest thirdPartyNotices mismatch: $($manifest.thirdPartyNotices)"
}
if ($manifest.thirdPartyLicenseIndex -ne "third_party_licenses/files.json") {
  throw "Manifest thirdPartyLicenseIndex mismatch: $($manifest.thirdPartyLicenseIndex)"
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

if ($manifest.androidCompanionSpec -ne "docs/ANDROID_COMPANION_SPEC.md") {
  throw "Manifest androidCompanionSpec mismatch: $($manifest.androidCompanionSpec)"
}

if ($manifest.androidCompanionTestPlan -ne "docs/ANDROID_COMPANION_TEST_PLAN.md") {
  throw "Manifest androidCompanionTestPlan mismatch: $($manifest.androidCompanionTestPlan)"
}

if ($manifest.androidPlayRelease -ne "docs/ANDROID_PLAY_RELEASE.md") {
  throw "Manifest androidPlayRelease mismatch: $($manifest.androidPlayRelease)"
}

if ($manifest.androidPlayPolicyDeclarations -ne "docs/ANDROID_PLAY_POLICY_DECLARATIONS.md") {
  throw "Manifest androidPlayPolicyDeclarations mismatch: $($manifest.androidPlayPolicyDeclarations)"
}

if ($manifest.androidPlayPrivacyPolicy -ne "docs/ANDROID_PLAY_PRIVACY_POLICY.md") {
  throw "Manifest androidPlayPrivacyPolicy mismatch: $($manifest.androidPlayPrivacyPolicy)"
}

if ($manifest.androidPlayIcon -ne "docs/store-assets/play/icon-512.png") {
  throw "Manifest androidPlayIcon mismatch: $($manifest.androidPlayIcon)"
}

if ($manifest.androidPlayFeatureGraphic -ne "docs/store-assets/play/feature-graphic-1024x500.png") {
  throw "Manifest androidPlayFeatureGraphic mismatch: $($manifest.androidPlayFeatureGraphic)"
}

if ($manifest.companionCrossPlatformPlan -ne "docs/COMPANION_CROSS_PLATFORM_PLAN.md") {
  throw "Manifest companionCrossPlatformPlan mismatch: $($manifest.companionCrossPlatformPlan)"
}

if ($manifest.conversationV2Roadmap -ne "docs/CONVERSATION_V2_ROADMAP.md") {
  throw "Manifest conversationV2Roadmap mismatch: $($manifest.conversationV2Roadmap)"
}

if ($manifest.agentGuide -ne "AGENTS.md") {
  throw "Manifest agentGuide mismatch: $($manifest.agentGuide)"
}

$personaCreatorPythonText = Get-Content -LiteralPath (Join-PackagePath "tools/create_persona_pack.py") -Raw
foreach ($pattern in @('"--author"', "required=True", "author=args.author")) {
  if ($personaCreatorPythonText -notmatch [regex]::Escape($pattern)) {
    throw "tools/create_persona_pack.py missing required author contract: $pattern"
  }
}

$personaPackLibraryText = Get-Content -LiteralPath (Join-PackagePath "bridge/persona_pack.py") -Raw
foreach ($pattern in @("Persona pack author is required", "Persona pack author must not be a placeholder", '"todo"', '"your name"')) {
  if ($personaPackLibraryText -notmatch [regex]::Escape($pattern)) {
    throw "bridge/persona_pack.py missing author provenance guard: $pattern"
  }
}

foreach ($pattern in @("stackchan.persona-index.v1", "runtime_hot_swap", "persona pack file escapes pack root")) {
  if ($personaPackLibraryText -notmatch [regex]::Escape($pattern)) {
    throw "bridge/persona_pack.py missing persona index guard: $pattern"
  }
}

$personaIndex = Get-Content -LiteralPath (Join-PackagePath "data/persona_index.json") -Raw |
  ConvertFrom-Json
if ($personaIndex.schema -ne "stackchan.persona-index.v1" -or
    [int]$personaIndex.pack_count -lt 2 -or
    [int]$personaIndex.valid_count -ne [int]$personaIndex.pack_count -or
    [int]$personaIndex.invalid_count -ne 0) {
  throw "Persona index summary is not release-ready."
}
foreach ($personaId in @("spark", "glow")) {
  $entry = @($personaIndex.packs | Where-Object { $_.id -eq $personaId }) | Select-Object -First 1
  if ($null -eq $entry -or -not $entry.valid) {
    throw "Persona index missing valid pack: $personaId"
  }
  if ($entry.license -ne "Apache-2.0") {
    throw "Persona index pack license mismatch for ${personaId}: $($entry.license)"
  }
  if ([string]$entry.sha256 -notmatch '^[0-9a-f]{64}$') {
    throw "Persona index pack hash is invalid for $personaId"
  }
  if ($entry.capabilities.runtime_hot_swap -ne $false -or
      $entry.capabilities.bridge_load_time -ne $true -or
      $entry.capabilities.firmware_build_time -ne $true) {
    throw "Persona index capabilities are not truthful for $personaId"
  }
}

$personaCreatorPowerShellText = Get-Content -LiteralPath (Join-PackagePath "tools/create_persona_pack.ps1") -Raw
foreach ($pattern in @('[Parameter(Mandatory = $true)]', '[ValidateNotNullOrEmpty()]', '$argsList += @("--author", $Author)')) {
  if ($personaCreatorPowerShellText -notmatch [regex]::Escape($pattern)) {
    throw "tools/create_persona_pack.ps1 missing required author contract: $pattern"
  }
}

if ($manifest.contributorGuide -ne "CONTRIBUTING.md") {
  throw "Manifest contributorGuide mismatch: $($manifest.contributorGuide)"
}

if ($manifest.securityPolicy -ne "SECURITY.md") {
  throw "Manifest securityPolicy mismatch: $($manifest.securityPolicy)"
}

if ($manifest.codeOfConduct -ne "CODE_OF_CONDUCT.md") {
  throw "Manifest codeOfConduct mismatch: $($manifest.codeOfConduct)"
}

if ($manifest.projectLicense -ne "Apache-2.0") {
  throw "Manifest projectLicense mismatch: $($manifest.projectLicense)"
}

if ($manifest.projectLicenseFile -ne "LICENSE") {
  throw "Manifest projectLicenseFile mismatch: $($manifest.projectLicenseFile)"
}

if ($manifest.docsIndex -ne "docs/README.md") {
  throw "Manifest docsIndex mismatch: $($manifest.docsIndex)"
}

if ($manifest.androidCompanionSource -ne "provenance/companion") {
  throw "Manifest androidCompanionSource mismatch: $($manifest.androidCompanionSource)"
}

if ($manifest.brainModelGuide -ne "docs/BRAIN_MODEL.md") {
  throw "Manifest brainModelGuide mismatch: $($manifest.brainModelGuide)"
}

if ($manifest.characterLock -ne "docs/CHARACTER_LOCK.md") {
  throw "Manifest characterLock mismatch: $($manifest.characterLock)"
}

if ($manifest.characterRedTeamReport -ne "character-red-team/CHARACTER_RED_TEAM.md") {
  throw "Manifest characterRedTeamReport mismatch: $($manifest.characterRedTeamReport)"
}

if ($manifest.characterRedTeamReportJson -ne "character-red-team/character_red_team.json") {
  throw "Manifest characterRedTeamReportJson mismatch: $($manifest.characterRedTeamReportJson)"
}

if ($manifest.gapAnalysis -ne "docs/GAP_ANALYSIS.md") {
  throw "Manifest gapAnalysis mismatch: $($manifest.gapAnalysis)"
}

if ($manifest.johnnyAlivePathway -ne "docs/JOHNNY_ALIVE_PATHWAY.md") {
  throw "Manifest johnnyAlivePathway mismatch: $($manifest.johnnyAlivePathway)"
}

if ($manifest.personaPacksGuide -ne "docs/PERSONA_PACKS.md") {
  throw "Manifest personaPacksGuide mismatch: $($manifest.personaPacksGuide)"
}

if ($manifest.ltr553CalibrationGuide -ne "docs/LTR553_CALIBRATION.md") {
  throw "Manifest ltr553CalibrationGuide mismatch: $($manifest.ltr553CalibrationGuide)"
}

if ($manifest.voicePersonalityGuide -ne "docs/VOICE_PERSONALITY.md") {
  throw "Manifest voicePersonalityGuide mismatch: $($manifest.voicePersonalityGuide)"
}

if ($manifest.bodySensorValidator -ne "tools/body_sensor_validation.ps1") {
  throw "Manifest bodySensorValidator mismatch: $($manifest.bodySensorValidator)"
}
if ($manifest.bodySensorValidatorContract -ne "tools/test_body_sensor_validation_contract.ps1") {
  throw "Manifest bodySensorValidatorContract mismatch: $($manifest.bodySensorValidatorContract)"
}
if ($manifest.finalSoakRunner -ne "tools/run_full_system_soak_http_motion.ps1") {
  throw "Manifest finalSoakRunner mismatch: $($manifest.finalSoakRunner)"
}
if ($manifest.finalSoakWrapper -ne "tools/start_warm_rocm_full_system_soak.ps1") {
  throw "Manifest finalSoakWrapper mismatch: $($manifest.finalSoakWrapper)"
}
if ($manifest.productionFinalSoakWrapper -ne "tools/start_production_full_system_soak.ps1") {
  throw "Manifest productionFinalSoakWrapper mismatch: $($manifest.productionFinalSoakWrapper)"
}
if ($manifest.finalSoakChecker -ne "tools/check_full_system_soak_evidence.ps1") {
  throw "Manifest finalSoakChecker mismatch: $($manifest.finalSoakChecker)"
}
if ($manifest.finalSoakCheckerContract -ne "tools/test_full_system_soak_evidence_contract.ps1") {
  throw "Manifest finalSoakCheckerContract mismatch: $($manifest.finalSoakCheckerContract)"
}
if ($manifest.currentLeadChecker -ne "tools/check_current_lead_reproducibility.ps1") {
  throw "Manifest currentLeadChecker mismatch: $($manifest.currentLeadChecker)"
}
if ($manifest.currentLeadCheckerContract -ne "tools/test_current_lead_reproducibility_contract.ps1") {
  throw "Manifest currentLeadCheckerContract mismatch: $($manifest.currentLeadCheckerContract)"
}
if ($manifest.currentLeadArchiver -ne "tools/archive_current_lead.ps1") {
  throw "Manifest currentLeadArchiver mismatch: $($manifest.currentLeadArchiver)"
}
if ($manifest.currentLeadArchiverContract -ne "tools/test_archive_current_lead_contract.ps1") {
  throw "Manifest currentLeadArchiverContract mismatch: $($manifest.currentLeadArchiverContract)"
}
if ($manifest.finalSoakWrapperContract -ne "tools/test_start_warm_rocm_full_system_soak_contract.ps1") {
  throw "Manifest finalSoakWrapperContract mismatch: $($manifest.finalSoakWrapperContract)"
}
if ($manifest.productionFinalSoakWrapperContract -ne "tools/test_start_production_full_system_soak_contract.ps1") {
  throw "Manifest productionFinalSoakWrapperContract mismatch: $($manifest.productionFinalSoakWrapperContract)"
}
if ($manifest.cameraFollowWakeValidator -ne "tools/camera_follow_wake_validation.ps1") {
  throw "Manifest cameraFollowWakeValidator mismatch: $($manifest.cameraFollowWakeValidator)"
}
if ($manifest.cameraFollowWakeValidatorContract -ne "tools/test_camera_follow_wake_validation_contract.ps1") {
  throw "Manifest cameraFollowWakeValidatorContract mismatch: $($manifest.cameraFollowWakeValidatorContract)"
}
if ($manifest.cameraFollowWakeCompletion -ne "tools/complete_camera_follow_wake_validation.ps1") {
  throw "Manifest cameraFollowWakeCompletion mismatch: $($manifest.cameraFollowWakeCompletion)"
}
if ($manifest.cameraFollowWakeCompletionContract -ne "tools/test_complete_camera_follow_wake_validation_contract.ps1") {
  throw "Manifest cameraFollowWakeCompletionContract mismatch: $($manifest.cameraFollowWakeCompletionContract)"
}
if ($manifest.consumerPromotionContract -ne "tools/test_consumer_promotion_contract.ps1") {
  throw "Manifest consumerPromotionContract mismatch: $($manifest.consumerPromotionContract)"
}

$includedPersonaPacks = @($manifest.includedPersonaPacks)
foreach ($personaId in @("spark", "glow")) {
  if ($includedPersonaPacks -notcontains $personaId) {
    throw "Manifest includedPersonaPacks missing persona: $personaId"
  }
}

if ($manifest.activePersona -ne "spark") {
  throw "Manifest activePersona mismatch: $($manifest.activePersona)"
}

if ($manifest.activePersonaPack -ne "personas/spark") {
  throw "Manifest activePersonaPack mismatch: $($manifest.activePersonaPack)"
}

if ($manifest.activePersonaVerification -ne "persona_pack_status.json") {
  throw "Manifest activePersonaVerification mismatch: $($manifest.activePersonaVerification)"
}

if ($manifest.activePersonaPromptAssets -ne "persona_prompt_assets.json") {
  throw "Manifest activePersonaPromptAssets mismatch: $($manifest.activePersonaPromptAssets)"
}

if ($manifest.personaIndex -ne "data/persona_index.json") {
  throw "Manifest personaIndex mismatch: $($manifest.personaIndex)"
}

if ($manifest.privacyModel -ne "docs/PRIVACY.md") {
  throw "Manifest privacyModel mismatch: $($manifest.privacyModel)"
}

if ($manifest.expressionProfiles -ne "data/expressions.yaml") {
  throw "Manifest expressionProfiles mismatch: $($manifest.expressionProfiles)"
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

if ($manifest.companionEvidenceManifest -ne "companion/evidence/c6-evidence/EVIDENCE.json") {
  throw "Manifest companionEvidenceManifest mismatch: $($manifest.companionEvidenceManifest)"
}

foreach ($generatedDir in @(
    "provenance/companion/.gradle",
    "provenance/companion/.kotlin",
    "provenance/companion/build",
    "provenance/companion/app-android/build",
    "provenance/companion/app-desktop/build",
    "provenance/companion/core/build",
    "provenance/companion/ui/build"
  )) {
  if (Test-Path -LiteralPath (Join-PackagePath $generatedDir)) {
    throw "Android companion source provenance must not include generated Gradle cache/build directory: $generatedDir"
  }
}

$androidRuntimeStatusTest = Get-Content -LiteralPath (Join-PackagePath "provenance/companion/app-android/src/test/kotlin/dev/stackchan/companion/android/AndroidBridgeRuntimeStatusTest.kt") -Raw
foreach ($pattern in @("androidConnectedDashboardStateContainsArrivalDayEvidenceFields", "Manual fallback URL: ws://192.168.1.42:8765/bridge", "Other LAN URLs: ws://10.0.0.42:8765/bridge", "Robot: Stackchan Bench / bench-v1", "Last bridge frame: heartbeat", "Brain owner: phone-rob-01", "Android NSD advertises _stackchan-bridge._tcp.local", "UDP beacon broadcasts endpoint metadata", "phoneRow.activeBrain")) {
  if ($androidRuntimeStatusTest -notmatch [regex]::Escape($pattern)) {
    throw "AndroidBridgeRuntimeStatusTest.kt missing arrival-day dashboard state coverage: $pattern"
  }
}

$expectedCompanionEvidence = @(
  "companion/evidence/c6-evidence/EVIDENCE.json",
  "companion/evidence/c6-evidence/EVIDENCE.md",
  "companion/evidence/c6-brain-supervisor/BRAIN_SUPERVISOR_SMOKE.json",
  "companion/evidence/c6-brain-supervisor/BRAIN_SUPERVISOR_SMOKE.md",
  "companion/evidence/c6-brain-supervisor/DIAGNOSTICS_EXPORT.json",
  "companion/evidence/c6-gui-rehearsal/GUI_REHEARSAL.json",
  "companion/evidence/c6-gui-rehearsal/GUI_REHEARSAL.md",
  "companion/evidence/c6-gui-rehearsal/DIAGNOSTICS_EXPORT.json"
)
$actualCompanionEvidence = @($manifest.companionEvidence)
foreach ($file in $expectedCompanionEvidence) {
  if ($actualCompanionEvidence -notcontains $file) {
    throw "Manifest companionEvidence missing expected file: $file"
  }
  Assert-File $file
}
foreach ($file in $actualCompanionEvidence) {
  if ($expectedCompanionEvidence -notcontains $file) {
    throw "Manifest companionEvidence contains unexpected file: $file"
  }
}

$companionEvidenceManifest = Get-Content -LiteralPath (Join-PackagePath "companion/evidence/c6-evidence/EVIDENCE.json") -Raw | ConvertFrom-Json
if ($companionEvidenceManifest.schema -ne "stackchan.companion.c6-evidence-bundle.v1") {
  throw "Companion C6 evidence manifest schema mismatch: $($companionEvidenceManifest.schema)"
}
if ($companionEvidenceManifest.result.gui_rehearsal_overall_ok -ne $true) {
  throw "Companion C6 GUI rehearsal did not pass in evidence manifest"
}
if ($companionEvidenceManifest.result.brain_supervisor_smoke_overall_ok -ne $true) {
  throw "Companion C6 brain supervisor smoke did not pass in evidence manifest"
}
if ($companionEvidenceManifest.result.diagnostics_exports_attached -ne $true) {
  throw "Companion C6 diagnostics exports are not attached"
}

$expectedMediaArtifacts = @(
  "media/stackchan_alive_preview.png",
  "media/stackchan_alive_expression_sheet.png",
  "media/stackchan_alive_preview.mp4",
  "media/stackchan_alive_preview.gif",
  "media/stackchan_alive_speech_preview.gif",
  "media/diagrams/01-system-overview.png",
  "media/diagrams/02-firmware-task-architecture.png",
  "media/diagrams/03-persona-engine.png",
  "media/diagrams/04-face-runtime.png",
  "media/diagrams/05-motion-servo-safety.png",
  "media/diagrams/06-brain-bridge-protocol.png",
  "media/diagrams/08-io-abstraction-builds.png",
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
  "media/voice/stackchan_spark_audition_bright_robot_greeting.mp3",
  "media/voice/stackchan_spark_thinking.mp3",
  "media/voice/sidecars/stackchan_spark_greeting.speech_envelope.json",
  "media/voice/sidecars/stackchan_spark_thinking.speech_envelope.json",
  "media/voice/sidecars/stackchan_spark_safety.speech_envelope.json",
  "media/voice/VOICE_SAMPLES.md",
  "media/voice/VOICE_AUDITION.html",
  "media/voice/rvc/README.md",
  "media/voice/rvc/model.pth",
  "media/voice/rvc/model.index"
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
  "pillow==12.3.0",
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
  "pillow==12.3.0",
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

foreach ($envName in @("stackchan", "stackchan_servo_calibration", "stackchan_release_full")) {
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
  $packages = @($envLock.resolvedPackages)
  if ($envName -eq "stackchan_release_full") {
    if ($envLock.platform -ne "pioarduino/platform-espressif32@55.03.36") {
      throw "dependency_lock.json platform mismatch for $envName`: $($envLock.platform)"
    }
    Assert-LockedPackage $packages "espressif32" "^55\.3\.36\+sha\.aa6e97c$"
    Assert-LockedPackage $packages "framework-arduinoespressif32" "^3\.3\.6$"
    Assert-LockedPackage $packages "framework-arduinoespressif32-libs" "^5\.5\.0\+sha\.f56bea3d1f$"
    Assert-LockedPackage $packages "tool-esptoolpy" "^5\.1\.0$"
    Assert-LockedPackage $packages "toolchain-xtensa-esp-elf" "^14\.2\.0\+20251107$"
    Assert-LockedPackage $packages "esp-micro-speech-features" "^1\.2\.0\+sha\.351c4c6$"
  } else {
    if ($envLock.platform -ne "espressif32@7.0.1") {
      throw "dependency_lock.json platform mismatch for $envName`: $($envLock.platform)"
    }
    Assert-LockedPackage $packages "espressif32" "^7\.0\.1$"
    Assert-LockedPackage $packages "framework-arduinoespressif32" "^3\.20017\.241212\+sha\.dcc1105b$"
    Assert-LockedPackage $packages "tool-esptoolpy" "^2\.41100\.0$"
    Assert-LockedPackage $packages "toolchain-xtensa-esp32s3" "^8\.4\.0\+2021r2-patch5$"
    Assert-LockedPackage $packages "stackchan-arduino" "sha\.b7b98f5$"
  }
  Assert-LockedPackage $packages "ArduinoJson" "^7\.4\.3$"
  Assert-LockedPackage $packages "M5Unified" "^0\.2\.17$"
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
  $knownLegacyScServo = $duplicate.name -eq "SCServo" -and $duplicate.environment -in @("stackchan", "stackchan_servo_calibration")
  $duplicateEntries = ConvertTo-Array $duplicate.entries
  $duplicateVersions = @($duplicateEntries | ForEach-Object { [string]$_.version } | Sort-Object -Unique)
  $knownFullOnlineM5Gfx = (
    $duplicate.name -eq "M5GFX" -and
    $duplicate.environment -eq "stackchan_release_full" -and
    $duplicate.count -eq 2 -and
    $duplicateVersions.Count -eq 2 -and
    $duplicateVersions[0] -eq "0.2.24" -and
    $duplicateVersions[1] -eq "0.2.25"
  )
  if (-not $knownLegacyScServo -and -not $knownFullOnlineM5Gfx) {
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

$thirdPartyNotices = Get-Content -LiteralPath (Join-PackagePath "THIRD_PARTY_NOTICES.md") -Raw
foreach ($pattern in @(
  "Third-Party Notices",
  "third_party_licenses/files.json",
  "Apache-2.0",
  "LGPL-2.1-or-later",
  "OpenCV Zoo YuNet",
  "do not select or grant a license",
  "not legal advice"
)) {
  if ($thirdPartyNotices -notmatch [regex]::Escape($pattern)) {
    throw "THIRD_PARTY_NOTICES.md missing required marker: $pattern"
  }
}

$thirdPartyLicenseIndex = ConvertTo-Array (
  Get-Content -LiteralPath (Join-PackagePath "third_party_licenses/files.json") -Raw |
    ConvertFrom-Json
)
if ($thirdPartyLicenseIndex.Count -lt 10) {
  throw "Third-party license index is unexpectedly small: $($thirdPartyLicenseIndex.Count)"
}
$indexedThirdPartyPaths = @()
foreach ($entry in $thirdPartyLicenseIndex) {
  $relative = ([string]$entry.path).Replace("\", "/")
  if ([string]::IsNullOrWhiteSpace($relative) -or
      [System.IO.Path]::IsPathRooted($relative) -or
      $relative.StartsWith("../") -or
      $relative.Contains("/../")) {
    throw "Third-party license index contains unsafe path: $relative"
  }
  $indexedPath = Join-PackagePath ("third_party_licenses/" + $relative)
  $indexedFilePath = if ($indexedPath.Length -ge 248 -and -not $indexedPath.StartsWith("\\?\")) {
    "\\?\$indexedPath"
  } else {
    $indexedPath
  }
  if (-not (Test-Path -LiteralPath $indexedFilePath -PathType Leaf)) {
    throw "Third-party license index references missing file: $relative"
  }
  $indexedFile = Get-Item -LiteralPath $indexedFilePath
  if ([int64]$entry.bytes -ne $indexedFile.Length) {
    throw "Third-party license index size mismatch: $relative"
  }
  $actualHash = (Get-FileHash -LiteralPath $indexedFilePath -Algorithm SHA256).Hash.ToLowerInvariant()
  if ([string]$entry.sha256 -ne $actualHash) {
    throw "Third-party license index hash mismatch: $relative"
  }
  $indexedThirdPartyPaths += $relative
}

$requiredThirdPartyPatterns = @(
  '^stackchan_release_full/platform/espressif32/LICENSE$',
  '^stackchan_release_full/packages/framework-arduinoespressif32/package\.json$',
  '^stackchan_release_full/packages/framework-arduinoespressif32-libs/package\.json$',
  '^stackchan_release_full/libdeps/ArduinoJson/LICENSE\.txt$',
  '^stackchan_release_full/libdeps/M5GFX/LICENSE$',
  '^stackchan_release_full/libdeps/M5Unified/LICENSE$',
  '^stackchan_release_full/libdeps/SCServo/LICENSE$',
  '^stackchan_release_full/libdeps/YAMLDuino/License$',
  '^stackchan_release_full/libdeps/esp-micro-speech-features/LICENSE$',
  '^models/opencv-zoo-yunet/LICENSE$',
  '^models/opencv-zoo-yunet/README\.md$'
)
foreach ($pattern in $requiredThirdPartyPatterns) {
  if (@($indexedThirdPartyPaths | Where-Object { $_ -match $pattern }).Count -lt 1) {
    throw "Third-party license index missing required evidence matching: $pattern"
  }
}

$releaseNotes = Get-Content -LiteralPath (Join-PackagePath "RELEASE_NOTES.md") -Raw
if ($releaseNotes -notmatch [regex]::Escape($ExpectedCommit)) {
  throw "RELEASE_NOTES.md missing expected commit"
}
if ($releaseNotes -notmatch "Hardware validation is still required") {
  throw "RELEASE_NOTES.md must state that hardware validation is still required"
}
foreach ($pattern in @("model.pth", "model.index", "private paired reference robot", "exact-image evidence", "does not validate another assembled unit")) {
  if ($releaseNotes -notmatch [regex]::Escape($pattern)) {
    throw "RELEASE_NOTES.md missing reference-versus-recipient validation boundary: $pattern"
  }
}
if ($releaseNotes -notmatch "READINESS_REPORT.md") {
  throw "RELEASE_NOTES.md missing readiness report reference"
}
foreach ($pattern in @("No-hardware simulation quick check", "tools/run_prearrival_sim_check.cmd", "PREARRIVAL_SIM_CHECK.md/json", "nested LAN smoke report", "tools/run_prearrival_sim_check.cmd -RunModelBenchmark -Json", "model-benchmark-candidate", "tools/run_lan_smoke.cmd", "LAN_SMOKE.md/json", "run_litert_lm_smoke.cmd", "LITERT_LM_SMOKE.md/json", "summary.candidate_gate", "recommended_profile", "tools/run_character_red_team.cmd -Json", "tools/run_character_red_team.cmd -RequireRunner -Json", "RUN_SIM_HARDWARE_COMPARE.cmd", "SIM_HARDWARE_COMPARE.md/json", "Voice audition quick check", "tools/open_voice_audition.cmd", "tools/open_voice_audition.cmd -All", "tools/verify_tracked_rvc_assets.cmd", "model.pth", "model.index", "SHA-256", "stackchan_spark_audition_bright_robot_greeting.mp3", "stackchan_spark_thinking.mp3")) {
  if ($releaseNotes -notmatch [regex]::Escape($pattern)) {
    throw "RELEASE_NOTES.md missing voice audition guidance: $pattern"
  }
}

$voiceGuide = Get-Content -LiteralPath (Join-PackagePath "docs/VOICE_PERSONALITY.md") -Raw
foreach ($pattern in @("Stackchan Spark", "released Stackchan RVC voice", "soundboard clips", "model.pth", "model.index", "production voice files", "persona/EarconSynth", "io/SpeechAdapter", "io/AudioOut", "generated firmware WAV playback", "mouth-frame streaming", "M5 speaker carrier fallback", "barge-in ducking", "[speech_audio]", 'typed `SpeechEarcon`', "no allocation", "output/voice_auditions/", "Acceptance Criteria")) {
  if ($voiceGuide -notmatch [regex]::Escape($pattern)) {
    throw "VOICE_PERSONALITY.md missing expected voice guardrail: $pattern"
  }
}

$characterLock = Get-Content -LiteralPath (Join-PackagePath "docs/CHARACTER_LOCK.md") -Raw
foreach ($pattern in @("curious", "earnest", "safety-conscious", "contractions", "2 sentences", "memory_write", "memory_forget", "Stackchan never claims to be alive or human", "malformed JSON")) {
  if ($characterLock -notmatch [regex]::Escape($pattern)) {
    throw "CHARACTER_LOCK.md missing expected character lock: $pattern"
  }
}

$brainModelGuide = Get-Content -LiteralPath (Join-PackagePath "docs/BRAIN_MODEL.md") -Raw
foreach ($pattern in @("google/gemma-4-E2B-it-qat-q4_0-gguf", "litert-community/gemma-4-E2B-it-litert-lm", "LiteRT-LM", "bridge/litert_lm_stackchan_wrapper.py", "bridge/litert_lm_contract_smoke.py", "run_litert_lm_smoke.cmd", "STACKCHAN_LITERT_LM_COMMAND", "bridge/character_harness.py", "bridge/character_red_team.py", "run_character_red_team.cmd", "dry-run-no-runner-configured", "summary.gate.ready", "bridge/engine_probe.py", "bridge/lan_smoke.py", "bridge/trusted_facts_smoke.py", "modelInvocations", "audioPlayed", "ENGINE_PROBE.md", "LITERT_LM_SMOKE.md/json", "LAN_SMOKE.md/json", "--model-response", "tokens per second", "Do not fine-tune first", "audio_format", "pcm16", "M5 speaker sink", "summary.candidate_gate", "recommended_profile", "--min-pass-rate", "ANDROID_COMPANION_SPEC.md")) {
  if ($brainModelGuide -notmatch [regex]::Escape($pattern)) {
    throw "BRAIN_MODEL.md missing expected model harness guidance: $pattern"
  }
}

$androidCompanionSpec = Get-Content -LiteralPath (Join-PackagePath "docs/ANDROID_COMPANION_SPEC.md") -Raw
foreach ($pattern in @("PC Brain Mode", "Mobile Brain Mode", "multi-endpoint", "active brain owner", "wake-gated", "claim_brain", "release_brain", "settings_get", "settings_set", "forget_endpoint", "trusted endpoint", "Character OS", "LiteRT-LM", "safety-locked", "Add your Stack-chan", "remove path", "Talk surface", "app_text_turn", "robot completes the", "raw WebSocket connection without robot", "stackchan.android.diagnostics-export.v1", "ANDROID_DIAGNOSTICS_EXPORT.json", "stackchan.bridge-endpoints.v1", "fresh heartbeat", "masked client text frames", "BridgeSocketWriter", "BridgeNetworkSession", "BridgeWiFiProvisioner", "WiFiClient", "partial-write buffering", "compile-time settings")) {
  if ($androidCompanionSpec -notmatch [regex]::Escape($pattern)) {
    throw "ANDROID_COMPANION_SPEC.md missing expected Android companion contract: $pattern"
  }
}

$companionCrossPlatformPlan = Get-Content -LiteralPath (Join-PackagePath "docs/COMPANION_CROSS_PLATFORM_PLAN.md") -Raw
foreach ($pattern in @("Cross-Platform Build & Distribution Plan", "Kotlin Multiplatform", "Compose Multiplatform", "Hydraulic Conveyor", "Android cannot silently self-update outside a store", "C0", "Scaffold", "C1", "Protocol module", "C8", "Distribution hardening", "RELEASE_EVIDENCE.json", "First Three PRs")) {
  if ($companionCrossPlatformPlan -notmatch [regex]::Escape($pattern)) {
    throw "COMPANION_CROSS_PLATFORM_PLAN.md missing expected companion distribution plan guidance: $pattern"
  }
}

$androidCompanionTestPlan = Get-Content -LiteralPath (Join-PackagePath "docs/ANDROID_COMPANION_TEST_PLAN.md") -Raw
foreach ($pattern in @("Android Companion Physical Test Plan", "API 35 AOSP automated-test emulator smoke", "test_android_emulator_launch.ps1", "substitutesForPhysicalEvidence=false", "foreground bridge service", "UDP beacon fallback", "manual URL fallback", "check_companion_v1_readiness.cmd", "protocol fixtures", "pending hardware gates", "check_android_toolchain.cmd", "SDK Platform 36", "cd companion", ".\gradlew.bat :app-android:assembleRelease", "companion\app-android\build\outputs\apk\release\app-android-release.apk", "RUN_ANDROID_APK_INSTALL.cmd -ApkPath <path-to-apk> -SourceCommit <git-commit>", "source commit", "tools\install_android_companion_apk.cmd", "android/apk-install/", "android_apk_install.json", "RUN_ANDROID_UDP_BEACON_PROBE.cmd", "android/udp-beacon-probe/", "RUN_ANDROID_COMPANION_PROBE.cmd -Url ws://<phone-lan-ip>:8765/bridge", "android/companion-probe/", "RUN_ANDROID_SCREEN_OFF_SOAK.cmd -Url ws://<phone-lan-ip>:8765/bridge", "tools\run_android_companion_soak.cmd", "android/screen-off-soak/", "android_companion_soak.json", "check_android_screen_off_soak_evidence.cmd", "ANDROID_SCREEN_OFF_SOAK_REVIEW.md", "android-screen-off-soak-ready", "RUN_ANDROID_LOGCAT_CAPTURE.cmd", "tools\capture_android_companion_logcat.cmd", "android/logcat/", "android_companion_logcat.txt", "check_android_speech_evidence.cmd", "ANDROID_SPEECH_REVIEW.md", "android-speech-ready", "robot_speech_serial.log", "check_android_controls_evidence.cmd", "ANDROID_CONTROLS_REVIEW.md", "android-controls-ready", "robot_controls_serial.log", "robot_hello_required", "check_android_pairing_evidence.cmd", "ANDROID_PAIRING_REVIEW.md", "android-pairing-ready", "robot_pairing_serial.log", "android_pairing_setup.jpg", "bridge_url_applied", "check_android_wifi_evidence.cmd", "ANDROID_WIFI_REVIEW.md", "android-wifi-ready", "robot_wifi_serial.log", "bridge_wifi_store_loads", "bridge_wifi_store_has_record=1", "check_android_gemma_evidence.cmd", "ANDROID_GEMMA_REVIEW.md", "android-gemma-real-device-ready", "mobile_brain_litert_turn", "mobile_brain_litert_error", "endpoint_hello", "screen off", "robot serial log", "Android dashboard switches from waiting to connected", "Add your Stack-chan", "Start phone bridge", "Connect Stack-chan", "Confirm robot ready", "waiting/setup action", "trusted companion nodes are stored", "raw WebSocket connection without the robot", "Talk screen enables text input", "app_text_turn", "audio_stream_start", "response_end", "ANDROID_DIAGNOSTICS_EXPORT.json", "stackchan.android.diagnostics-export.v1", "redacts the last text turn", "Removing a stored trusted companion endpoint", "robot identity", "firmware/version signal", "last bridge frame", "active brain owner", "foreground service state")) {
  if ($androidCompanionTestPlan -notmatch [regex]::Escape($pattern)) {
    throw "ANDROID_COMPANION_TEST_PLAN.md missing expected Android physical test guidance: $pattern"
  }
}

foreach ($relativePath in @("docs/DEVICE_BRINGUP.md", "docs/ARRIVAL_DAY_RUNBOOK.md", "QUICKSTART.md", "docs/ANDROID_COMPANION_TEST_PLAN.md", "tools/install_android_companion_apk.ps1")) {
  $labSigningText = Get-Content -LiteralPath (Join-PackagePath $relativePath) -Raw
  foreach ($pattern in @("stackchan.allowLabDebugReleaseSigning=true", "intentionally rejected")) {
    if ($labSigningText -notmatch [regex]::Escape($pattern)) {
      throw "$relativePath missing explicit fail-closed Android lab signing guidance: $pattern"
    }
  }
}

$companionEndpointServer = Get-Content -LiteralPath (Join-PackagePath "provenance/companion/core/src/commonMain/kotlin/dev/stackchan/companion/core/EndpointServer.kt") -Raw
foreach ($pattern in @("robotHelloReceived", "robot_hello_required", "audio, settings writes, or app text turns", "Stack-chan has not completed the bridge hello yet.")) {
  if ($companionEndpointServer -notmatch [regex]::Escape($pattern)) {
    throw "EndpointServer.kt missing robot hello write gate: $pattern"
  }
}

$androidPlayRelease = Get-Content -LiteralPath (Join-PackagePath "docs/ANDROID_PLAY_RELEASE.md") -Raw
foreach ($pattern in @("Android Play Release Checklist", "app-android-release.aab", "Play App Signing", "STACKCHAN_ANDROID_KEYSTORE", "One-Time Upload Key Provisioning", "keytool -genkeypair", "cryptographically validates", "test_android_upload_signing_contract.ps1", "certificate SHA-256 fingerprint", "2033-10-22", "CI runtime smoke", "API 35 AOSP ATD", "exact release APK artifact", "RequireAndroidEmulatorEvidence", "gh secret set STACKCHAN_ANDROID_KEYSTORE_B64", "gh secret list --app actions", "two independent offline media", "docs/store-assets/play/icon-512.png", "feature-graphic-1024x500.png", "fastlane/metadata/android/en-US/", "ANDROID_PLAY_POLICY_DECLARATIONS.md", "ANDROID_PLAY_PRIVACY_POLICY.md", "physical robot validation", "Play Console internal testing")) {
  if ($androidPlayRelease -notmatch [regex]::Escape($pattern)) {
    throw "ANDROID_PLAY_RELEASE.md missing expected Play release guidance: $pattern"
  }
}

$androidPlayPolicyDeclarations = Get-Content -LiteralPath (Join-PackagePath "docs/ANDROID_PLAY_POLICY_DECLARATIONS.md") -Raw
foreach ($pattern in @("Google Play Data safety form", "Privacy policy URL", "ANDROID_PLAY_PRIVACY_POLICY.md", "Data Safety Draft", "Not collected", "RECORD_AUDIO", "raw microphone audio is not stored", "Foreground service Play Console draft", "connectedDevice", "not directed to children")) {
  if ($androidPlayPolicyDeclarations -notmatch [regex]::Escape($pattern)) {
    throw "ANDROID_PLAY_POLICY_DECLARATIONS.md missing expected Play policy guidance: $pattern"
  }
}

$androidPlayPrivacyPolicy = Get-Content -LiteralPath (Join-PackagePath "docs/ANDROID_PLAY_PRIVACY_POLICY.md") -Raw
foreach ($pattern in @("Stackchan Companion Privacy Policy", "dev.stackchan.companion", "does not create accounts", "does not persist raw microphone audio", "diagnostics export", "password_redacted=true", "optional Mobile Brain model", "saved robot and trusted companion records", "not directed to children")) {
  if ($androidPlayPrivacyPolicy -notmatch [regex]::Escape($pattern)) {
    throw "ANDROID_PLAY_PRIVACY_POLICY.md missing expected Play privacy policy guidance: $pattern"
  }
}

$johnnyAlivePathway = Get-Content -LiteralPath (Join-PackagePath "docs/JOHNNY_ALIVE_PATHWAY.md") -Raw
foreach ($pattern in @("Johnny Alive Pathway", "hardware baseline", "Release Baseline", "996b7e4b2de0c529a0f0e508891dec33598bf935", "Visitor Test", "LTR-553", "on-device wake phrase", "DirectML RVC", "YuNet", "privacy-filtered durable memory", "Phase Status", "P8 Continuity", "Sequenced Post-Release Work", "typed conversation lease", "Perceived latency", "persona hot-swap", "Evidence Rules", "Non-Negotiables", "strict 50 ms frame gate")) {
  if ($johnnyAlivePathway -notmatch [regex]::Escape($pattern)) {
    throw "JOHNNY_ALIVE_PATHWAY.md missing expected roadmap guidance: $pattern"
  }
}

$bridgeProtocol = Get-Content -LiteralPath (Join-PackagePath "docs/BRIDGE_PROTOCOL.md") -Raw
foreach ($pattern in @("stackchan.bridge.v1", "stackchan.bridge-endpoints.v1", "BridgeEndpointStore", "Preferences backend", "masked client text frame", "drains queued responses through a socket sink", "BridgeNetworkSession", "BridgeWiFiClientSocket", "BridgeWiFiProvisioner", "compile-time Wi-Fi/bridge provisioning", "wake-word gating", "response_start", "audio", "response_end", "character_harness.py", "Accepted", "4096 bytes", "BridgeClientOutput", "downlink consumer", "BridgeAudioUplink", "uplink start", "uplink chunk", "synthetic PCM", "bridge_downlink_playback_*", "pcm16", "offline matrix", "tools/run_lan_smoke.cmd", "LAN_SMOKE.md/json", "ANDROID_COMPANION_SPEC.md", "active brain owner", "forget_endpoint")) {
  if ($bridgeProtocol -notmatch [regex]::Escape($pattern)) {
    throw "BRIDGE_PROTOCOL.md missing expected bridge contract: $pattern"
  }
}

$privacyModel = Get-Content -LiteralPath (Join-PackagePath "docs/PRIVACY.md") -Raw
foreach ($pattern in @("wake-word gated", "Audio leaves the device", "local/LAN-first", "no hardcoded secrets", "preferred_name", "recent_topics", "physical_context", "bridge_messages", "bridge_timeouts", "degrade offline", "public production RVC hashes", "Raw microphone recordings")) {
  if ($privacyModel -notmatch [regex]::Escape($pattern)) {
    throw "PRIVACY.md missing expected privacy boundary: $pattern"
  }
}

$voicePersona = Get-Content -LiteralPath (Join-PackagePath "data/voice_persona.yaml") -Raw
foreach ($pattern in @("schema: stackchan.voice-persona.v1", "profile_id: stackchan_spark", "cloning named character or actor voices", "training from soundboard clips", "licensed_or_owned_voice_source")) {
  if ($voicePersona -notmatch [regex]::Escape($pattern)) {
    throw "voice_persona.yaml missing expected voice policy: $pattern"
  }
}

$expressionData = Get-Content -LiteralPath (Join-PackagePath "data/expressions.yaml") -Raw
foreach ($pattern in @("drowsy:", "yawn:", "surprise:", "picked_up:", "shaken:", "put_down:", "tilted:", "sound_direction:", "loud_noise:", "circadian:", "perceptual_purpose", "duration_ms: 1200", "evening_start_hour", "night_start_hour", "morning_start_hour", "motion hold", "orientation mismatch", "orient reflex", "startle reflex")) {
  if ($expressionData -notmatch [regex]::Escape($pattern)) {
    throw "expressions.yaml missing expected P1 circadian/yawn expression data: $pattern"
  }
}

$voiceSourceTemplate = Get-Content -LiteralPath (Join-PackagePath "docs/VOICE_SOURCE_PROVENANCE_TEMPLATE.md") -Raw
foreach ($pattern in @("Production Voice Release Record", "media/voice/rvc/model.pth", "media/voice/rvc/model.index", "DirectML RVC", "released for public distribution")) {
  if ($voiceSourceTemplate -notmatch [regex]::Escape($pattern)) {
    throw "VOICE_SOURCE_PROVENANCE_TEMPLATE.md missing expected provenance guidance: $pattern"
  }
}

$voiceSourceProvenance = Get-Content -LiteralPath (Join-PackagePath "data/voice_source_provenance.yaml") -Raw
foreach ($pattern in @("schema: stackchan.voice-source-provenance.v1", "status: production-source-released", "original-owner-released-for-public-distribution", "media/voice/rvc/model.pth", "media/voice/rvc/model.index", "hardware_evidence_verification_pass", "rollout_gate: production-ready")) {
  if ($voiceSourceProvenance -notmatch [regex]::Escape($pattern)) {
    throw "voice_source_provenance.yaml missing expected policy: $pattern"
  }
}

Assert-File "docs/CI_ACCOUNT_BLOCK_EXCEPTION_TEMPLATE.json" 100
$ciExceptionTemplate = Get-Content -LiteralPath (Join-PackagePath "docs/CI_ACCOUNT_BLOCK_EXCEPTION_TEMPLATE.json") -Raw | ConvertFrom-Json
if ($ciExceptionTemplate.schema -ne "stackchan.ci-account-block-exception.v1") {
  throw "CI account-block exception template schema mismatch: $($ciExceptionTemplate.schema)"
}
foreach ($field in @("version", "commit", "githubActionsStatus", "approvedBy", "approvedUtc", "reason", "riskAccepted", "localReleaseVerificationPassed", "strictHardwareEvidencePassed", "productionVoiceSourceReady", "followUpOwner", "followUpDueUtc")) {
  if ($null -eq $ciExceptionTemplate.$field) {
    throw "CI account-block exception template missing field: $field"
  }
}
foreach ($field in @("approvedBy", "approvedUtc", "followUpOwner", "followUpDueUtc")) {
  if ([string]$ciExceptionTemplate.$field -notmatch "TBD") {
    throw "CI account-block exception template $field must remain a TBD placeholder."
  }
}
foreach ($field in @("riskAccepted", "localReleaseVerificationPassed", "strictHardwareEvidencePassed", "productionVoiceSourceReady")) {
  if ($ciExceptionTemplate.$field -ne $false) {
    throw "CI account-block exception template $field must remain false until copied and approved."
  }
}

$voiceSourceStatusMarkdown = Get-Content -LiteralPath (Join-PackagePath "VOICE_SOURCE_STATUS.md") -Raw
foreach ($pattern in @("Voice Source Status", "production-source-ready", "Blocked gates: 0", "voice_source_status.json")) {
  if ($voiceSourceStatusMarkdown -notmatch [regex]::Escape($pattern)) {
    throw "VOICE_SOURCE_STATUS.md missing expected voice-source status text: $pattern"
  }
}

$voiceSourceStatusJson = Get-Content -LiteralPath (Join-PackagePath "voice_source_status.json") -Raw | ConvertFrom-Json
if ($voiceSourceStatusJson.schema -ne "stackchan.voice-source-status.v1") {
  throw "voice_source_status.json schema mismatch: $($voiceSourceStatusJson.schema)"
}
if ($voiceSourceStatusJson.provenancePath -ne "data/voice_source_provenance.yaml") {
  throw "voice_source_status.json provenancePath must be package-relative: $($voiceSourceStatusJson.provenancePath)"
}
if ($voiceSourceStatusJson.templatePath -ne "docs/VOICE_SOURCE_PROVENANCE_TEMPLATE.md") {
  throw "voice_source_status.json templatePath must be package-relative: $($voiceSourceStatusJson.templatePath)"
}
if ($voiceSourceStatusJson.status -ne "production-source-ready") {
  throw "voice_source_status.json status mismatch: $($voiceSourceStatusJson.status)"
}
if ([int]$voiceSourceStatusJson.blockedGateCount -ne 0) {
  throw "voice_source_status.json should report zero blocked voice gates"
}
foreach ($gate in @("production-model-hash", "production-index-hash", "owner-release-decision", "target-speaker-playback")) {
  $match = @($voiceSourceStatusJson.gates | Where-Object { $_.gate -eq $gate -and $_.status -eq "pass" })
  if ($match.Count -ne 1) {
    throw "voice_source_status.json missing passing gate: $gate"
  }
}

& (Join-PackagePath "tools/verify_tracked_rvc_assets.ps1") -VoiceRoot (Join-PackagePath "media/voice/rvc")

Assert-File "media/voice/rvc/model.pth" 57577722
Assert-File "media/voice/rvc/model.index" 99428699
Assert-File "RVC_VOICE_BASE_STATUS.md" 200
Assert-File "rvc_voice_base_status.json" 500
$rvcBaseStatusMarkdown = Get-Content -LiteralPath (Join-PackagePath "RVC_VOICE_BASE_STATUS.md") -Raw
foreach ($pattern in @("RVC Voice Base Status", "production-release-verified", "Consumer release: yes", "Distribution: yes", "rvc_voice_base_status.json")) {
  if ($rvcBaseStatusMarkdown -notmatch [regex]::Escape($pattern)) {
    throw "RVC_VOICE_BASE_STATUS.md missing expected RVC base status text: $pattern"
  }
}
$rvcBaseStatusJson = Get-Content -LiteralPath (Join-PackagePath "rvc_voice_base_status.json") -Raw | ConvertFrom-Json
if ($rvcBaseStatusJson.schema -ne "stackchan.rvc-voice-base-status.v1") {
  throw "rvc_voice_base_status.json schema mismatch: $($rvcBaseStatusJson.schema)"
}
if ($rvcBaseStatusJson.status -ne "production-release-verified") {
  throw "rvc_voice_base_status.json status mismatch: $($rvcBaseStatusJson.status)"
}
if ($rvcBaseStatusJson.consumerApproved -ne $true -or $rvcBaseStatusJson.distributionApproved -ne $true) {
  throw "rvc_voice_base_status.json must mark the production voice released"
}
if ($rvcBaseStatusJson.model.sha256 -ne "1A8ADDFD670CD811D1AD1EEB9E9B4FF72C5D795B1123A23E86A0C41C1DD9BF1A" -or
    $rvcBaseStatusJson.index.sha256 -ne "DA0EDB00FB15E8CEEC135B261F32E5907BA570FF0D213BEF8267EB80AB167DC2") {
  throw "rvc_voice_base_status.json production voice hashes do not match"
}

$acceptance = Get-Content -LiteralPath (Join-PackagePath "release_acceptance.json") -Raw | ConvertFrom-Json
if ($acceptance.schema -ne "stackchan.release-acceptance.v1") {
  throw "release_acceptance.json schema mismatch: $($acceptance.schema)"
}
if ($acceptance.currentDecision -ne "owner-approved-release") {
  throw "release_acceptance.json currentDecision mismatch: $($acceptance.currentDecision)"
}
if ($acceptance.consumerRolloutDecision -ne "released") {
  throw "release_acceptance.json consumerRolloutDecision mismatch: $($acceptance.consumerRolloutDecision)"
}
foreach ($requirement in @("clean-release-package", "dependency-provenance-present", "voice-review-samples-present", "voice-source-provenance-template-present", "voice-source-status-report-present", "character-red-team-dry-run-present", "companion-c6-brain-supervision-evidence", "hardware-media-importer-present", "servo-risk-gated", "share-page-verifiable")) {
  $match = @($acceptance.noHardwareAcceptance | Where-Object { $_.requirement -eq $requirement -and $_.status -eq "pass" })
  if ($match.Count -ne 1) {
    throw "release_acceptance.json missing passed no-hardware requirement: $requirement"
  }
}
foreach ($requirement in @("display-only-flash", "speech-mouth-demo-evidence", "servo-calibration", "mixed-mode-soak", "power-cycle-recovery", "target-speaker-audio-evidence", "hardware-evidence-verification")) {
  $match = @($acceptance.hardwareAcceptanceRequired | Where-Object { $_.requirement -eq $requirement -and $_.status -match "pending" })
  if ($match.Count -ne 1) {
    throw "release_acceptance.json missing pending hardware requirement: $requirement"
  }
}
$productionVoiceRequirement = @($acceptance.hardwareAcceptanceRequired | Where-Object { $_.requirement -eq "production-voice-assets" -and $_.status -eq "pass" })
if ($productionVoiceRequirement.Count -ne 1) {
  throw "release_acceptance.json missing passed production voice asset requirement"
}

$acceptanceText = Get-Content -LiteralPath (Join-PackagePath "RELEASE_ACCEPTANCE.md") -Raw
foreach ($pattern in @("owner-approved public release", "Consumer rollout: released", "Dependency provenance", "Voice review samples", "Voice source provenance template", "Voice source status report", "VOICE_SOURCE_STATUS.md", "Character red-team dry-run report", "CHARACTER_RED_TEAM.md", "Companion C6 brain-supervision evidence", "Hardware media importer", "add_hardware_evidence_media.cmd", "Speech-mouth demo evidence", "speech_mouth_demo_serial.log", "speak_all_intents_serial.log", "Power-cycle recovery", "USB power-cycle observation marked pass", "Target-speaker audio evidence", "AUDIO_REVIEW.md", "real-device speaker recording", "Production RVC model and index")) {
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
if (@("post-push-check-required", "missing-required-workflow", "external-account-billing-or-spending-limit", "external-account-ci-pre-runner-allocation", "success") -notcontains $actionsStatus.status) {
  throw "github_actions_status.json status is not release-acceptable: $($actionsStatus.status)"
}
$requiredActionWorkflowNames = @($actionsStatus.requiredWorkflows | ForEach-Object { [string]$_ })
foreach ($workflowName in @("Firmware", "Release")) {
  if ($requiredActionWorkflowNames -notcontains $workflowName) {
    throw "github_actions_status.json missing required workflow contract: $workflowName"
  }
}

$actionsStatusText = Get-Content -LiteralPath (Join-PackagePath "GITHUB_ACTIONS_STATUS.md") -Raw
foreach ($pattern in @("GitHub Actions Status", $Version, $ExpectedCommit, "Required workflows", "github_actions_status.json")) {
  if ($actionsStatusText -notmatch [regex]::Escape($pattern)) {
    throw "GITHUB_ACTIONS_STATUS.md missing expected status text: $pattern"
  }
}

$readinessMarkdown = Get-Content -LiteralPath (Join-PackagePath "READINESS_REPORT.md") -Raw
foreach ($pattern in @($Version, $ExpectedCommit, "Status: public release", "Consumer rollout: owner-approved", "Proven Without Hardware", "Recipient Hardware Evidence", "private paired reference robot", "exact-image physical evidence", "recipient's assembled hardware", "GITHUB_ACTIONS_STATUS.md", "VOICE_SOURCE_STATUS.md", "Character red-team dry-run evidence", "Companion C6 brain-supervision evidence", "companion/evidence/", "configured local model", "add_hardware_evidence_media.cmd", "verify_hardware_evidence.cmd", "Speech-mouth demo evidence", "speech_mouth_demo_serial.log", "speak_all_intents_serial.log", "Power-cycle recovery", "USB power-cycle observation marked pass", "Production voice metadata", "owner approved the reference release evidence")) {
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
if ($readinessJson.consumerRollout -ne "owner-approved") {
  throw "readiness_report.json must record the owner's release decision"
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
$characterRedTeamNoHardwareGate = @($readinessJson.noHardwareProof | Where-Object { $_.gate -eq "character-red-team-dry-run" -and $_.status -eq "pass" })
if ($characterRedTeamNoHardwareGate.Count -ne 1) {
  throw "readiness_report.json missing passed character red-team dry-run gate"
}
$companionC6NoHardwareGate = @($readinessJson.noHardwareProof | Where-Object { $_.gate -eq "companion-c6-brain-supervision-evidence" -and $_.status -eq "pass" })
if ($companionC6NoHardwareGate.Count -ne 1) {
  throw "readiness_report.json missing passed companion-c6-brain-supervision-evidence gate"
}
$mediaImporterNoHardwareGate = @($readinessJson.noHardwareProof | Where-Object { $_.gate -eq "hardware-media-importer-present" -and $_.status -eq "pass" })
if ($mediaImporterNoHardwareGate.Count -ne 1) {
  throw "readiness_report.json missing passed hardware-media-importer-present gate"
}
$speakerAudioGate = @($readinessJson.hardwareGates | Where-Object { $_.gate -eq "target-speaker-audio-evidence" -and $_.status -eq "pending-device" })
if ($speakerAudioGate.Count -ne 1) {
  throw "readiness_report.json missing pending target-speaker-audio-evidence gate"
}
$speechMouthGate = @($readinessJson.hardwareGates | Where-Object { $_.gate -eq "speech-mouth-demo-evidence" -and $_.status -eq "pending-device" })
if ($speechMouthGate.Count -ne 1) {
  throw "readiness_report.json missing pending speech-mouth-demo-evidence gate"
}
$powerCycleGate = @($readinessJson.hardwareGates | Where-Object { $_.gate -eq "power-cycle-recovery" -and $_.status -eq "pending-device" })
if ($powerCycleGate.Count -ne 1) {
  throw "readiness_report.json missing pending power-cycle-recovery gate"
}
foreach ($gate in @($readinessJson.hardwareGates)) {
  $allowedStatus = if ($gate.gate -eq "production-voice-assets") { "pass" } else { "pending-device" }
  if ($gate.status -ne $allowedStatus) {
    throw "readiness_report.json hardware gate status mismatch: $($gate.gate)"
  }
}
if (@($readinessJson.hardwareGates).Count -lt 8) {
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
  $cleanupFileSystemPath = if ($env:OS -eq "Windows_NT" -and -not $resolvedCleanup.StartsWith("\\?\")) {
    "\\?\$resolvedCleanup"
  } else {
    $resolvedCleanup
  }
  [System.IO.Directory]::Delete($cleanupFileSystemPath, $true)
}
