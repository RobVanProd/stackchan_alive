param(
  [string]$Version,
  [switch]$SkipBuild,
  [switch]$AllowDirty
)

$ErrorActionPreference = "Stop"

$physicalRepoRoot = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
if (
  $env:OS -eq "Windows_NT" -and
  -not $env:STACKCHAN_RELEASE_SHORT_PATH_ACTIVE -and
  $physicalRepoRoot.Length -gt 60
) {
  $shortDrive = @("R:", "Q:", "P:", "O:") |
    Where-Object { -not (Test-Path $_) } |
    Select-Object -First 1
  if (-not $shortDrive) {
    throw "Release packaging needs a free temporary drive letter (R:, Q:, P:, or O:) for this deeply nested checkout."
  }

  $driveName = $shortDrive.TrimEnd("\")
  & subst.exe $driveName $physicalRepoRoot
  if ($LASTEXITCODE -ne 0) { throw "Could not create temporary release path $driveName" }

  $childExit = 1
  try {
    $env:STACKCHAN_RELEASE_SHORT_PATH_ACTIVE = "1"
    $childArgs = @(
      "-NoProfile",
      "-ExecutionPolicy", "Bypass",
      "-File", "$driveName\tools\package_release.ps1"
    )
    if ($Version) { $childArgs += @("-Version", $Version) }
    if ($SkipBuild) { $childArgs += "-SkipBuild" }
    if ($AllowDirty) { $childArgs += "-AllowDirty" }
    & powershell.exe @childArgs
    $childExit = $LASTEXITCODE
  } finally {
    Remove-Item Env:\STACKCHAN_RELEASE_SHORT_PATH_ACTIVE -ErrorAction SilentlyContinue
    Set-Location $env:TEMP
    & subst.exe $driveName /D | Out-Null
  }
  exit $childExit
}

$repoRoot = Resolve-Path (Join-Path $PSScriptRoot "..")
Set-Location $repoRoot
. (Join-Path $PSScriptRoot "platformio_resolver.ps1")
. (Join-Path $PSScriptRoot "preview_python_resolver.ps1")
. (Join-Path $PSScriptRoot "release_asset_contract.ps1")

$releaseLegacyPlatformioCore = Get-StackchanPlatformioCoreDir
$releasePlatformioCoreRoot = if ($env:OS -eq "Windows_NT") {
  # The repository may be running through a temporary subst drive. Keep the
  # pioarduino core on the physical system drive so it survives that mapping
  # and retains the intentionally short path used by release builds.
  Join-Path ([System.IO.Path]::GetPathRoot($env:SystemRoot)) "spio"
} else {
  Join-Path ([System.IO.Path]::GetTempPath()) "stackchan-pio-release-cores"
}

function Get-ReleasePlatformioCoreDir {
  param([string]$Environment)

  if ($Environment -eq "stackchan_release_full") {
    return Join-Path $releasePlatformioCoreRoot "pioarduino"
  }
  return $releaseLegacyPlatformioCore
}

function Invoke-StackchanReleasePlatformio {
  param(
    [string]$Environment,
    [string[]]$Arguments
  )

  $previousCoreDir = $env:PLATFORMIO_CORE_DIR
  try {
    $env:PLATFORMIO_CORE_DIR = Get-ReleasePlatformioCoreDir -Environment $Environment
    Invoke-StackchanPlatformio @Arguments
  } finally {
    if ($null -eq $previousCoreDir) {
      Remove-Item Env:\PLATFORMIO_CORE_DIR -ErrorAction SilentlyContinue
    } else {
      $env:PLATFORMIO_CORE_DIR = $previousCoreDir
    }
  }
}

if ([string]::IsNullOrWhiteSpace($Version)) {
  $Version = (git describe --tags --always --dirty).Trim()
}

$firmwareArtifactNames = @(
  "firmware.bin",
  "firmware.elf",
  "bootloader.bin",
  "partitions.bin"
)

function Copy-BuildArtifacts {
  param(
    [string]$BuildDir,
    [string]$Destination
  )

  New-Item -ItemType Directory -Force -Path $Destination | Out-Null
  foreach ($file in $firmwareArtifactNames) {
    $source = Join-Path $BuildDir $file
    if (-not (Test-Path -LiteralPath $source)) {
      throw "Missing build artifact: $source"
    }
    Copy-Item -LiteralPath $source -Destination $Destination -Force
  }
}

$releaseOutputRoot = Join-Path $repoRoot "output/release"
Get-ChildItem -LiteralPath $releaseOutputRoot -Directory -Force -Filter ".firmware-build-cache-*" -ErrorAction SilentlyContinue |
  Remove-Item -Recurse -Force

$builtFirmwareCache = $null
if (-not $SkipBuild) {
  # These profiles intentionally span the legacy Espressif platform and the
  # pioarduino/Arduino 3.3.6 platform. Building them in one PlatformIO process
  # lets the shared framework package name replace the active toolchain. The
  # replacement can also invalidate prior .pio/build trees, so snapshot every
  # successful environment before installing the next framework family.
  $builtFirmwareCache = Join-Path $repoRoot "output/release/.firmware-build-cache-$PID"
  if (Test-Path -LiteralPath $builtFirmwareCache) {
    Remove-Item -LiteralPath $builtFirmwareCache -Recurse -Force
  }
  foreach ($environment in @("stackchan", "stackchan_servo_calibration", "stackchan_release_full")) {
    Invoke-StackchanReleasePlatformio `
      -Environment $environment `
      -Arguments @("run", "-e", $environment)
    Copy-BuildArtifacts `
      -BuildDir (Join-Path $repoRoot ".pio/build/$environment") `
      -Destination (Join-Path $builtFirmwareCache $environment)
  }
  $previewPython = Get-StackchanPreviewPython
  & $previewPython tools/render_preview.py
  if ($LASTEXITCODE -ne 0) {
    throw "Preview media generation failed with exit code $LASTEXITCODE"
  }
}

$dirtyFiles = @(git status --porcelain)
$generatedMediaDirtyFiles = @(
  $dirtyFiles | Where-Object { $_ -match "^\s*(M|\?\?) docs/media/stackchan_alive_(preview\.(gif|mp4|png)|speech_preview\.gif|expression_sheet\.png)$" }
)
$sourceDirtyFiles = @(
  $dirtyFiles | Where-Object { $_ -notmatch "^\s*(M|\?\?) docs/media/stackchan_alive_(preview\.(gif|mp4|png)|speech_preview\.gif|expression_sheet\.png)$" }
)

if ($sourceDirtyFiles.Count -gt 0 -and -not $AllowDirty) {
  $dirtyList = ($sourceDirtyFiles -join [Environment]::NewLine)
  throw "Refusing to package a dirty source worktree. Commit or discard changes first, or pass -AllowDirty for local diagnostic packages. Dirty files:$([Environment]::NewLine)$dirtyList"
}

$commit = (git rev-parse HEAD).Trim()
$shortCommit = (git rev-parse --short HEAD).Trim()
$outDir = Join-Path $repoRoot "output/release/$Version"
$zipPath = Join-Path $repoRoot "output/release/stackchan_alive_$Version.zip"
$zipSidecarPath = "$zipPath.sha256"

if (Test-Path -LiteralPath $outDir) {
  Remove-Item -LiteralPath $outDir -Recurse -Force
}
New-Item -ItemType Directory -Force -Path $outDir | Out-Null

$firmwareDir = Join-Path $outDir "firmware"
$displayFirmwareDir = Join-Path $firmwareDir "display_only"
$servoFirmwareDir = Join-Path $firmwareDir "servo_calibration"
$fullOnlineFirmwareDir = Join-Path $firmwareDir "full_online"
$mediaDir = Join-Path $outDir "media"
$faceArtifactDir = Join-Path $outDir "artifacts/face"
$docsDir = Join-Path $outDir "docs"
$dataDir = Join-Path $outDir "data"
$bridgeDir = Join-Path $outDir "bridge"
$bridgeModelsDir = Join-Path $bridgeDir "models"
$companionEvidenceDir = Join-Path $outDir "companion/evidence"
$provenanceDir = Join-Path $outDir "provenance"
$thirdPartyLicensesDir = Join-Path $outDir "third_party_licenses"
$toolsDir = Join-Path $outDir "tools"
New-Item -ItemType Directory -Force -Path $displayFirmwareDir, $servoFirmwareDir, $fullOnlineFirmwareDir, $mediaDir, $faceArtifactDir, $docsDir, $dataDir, $bridgeDir, $bridgeModelsDir, $companionEvidenceDir, $provenanceDir, $thirdPartyLicensesDir, $toolsDir | Out-Null

$releaseRootPrefix = [System.IO.Path]::GetFullPath($outDir).TrimEnd("\", "/") + [System.IO.Path]::DirectorySeparatorChar

function Join-ReleasePackagePath {
  param([string]$RelativePath)

  $normalized = $RelativePath.Replace("\", "/").TrimStart("/")
  if ([System.IO.Path]::IsPathRooted($normalized) -or $normalized.StartsWith("../") -or $normalized.Contains("/../")) {
    throw "Refusing unsafe package-relative path: $RelativePath"
  }
  $absolutePath = [System.IO.Path]::GetFullPath((Join-Path $outDir $normalized))
  if (-not $absolutePath.StartsWith($releaseRootPrefix, [System.StringComparison]::OrdinalIgnoreCase)) {
    throw "Refusing package path outside release root: $RelativePath"
  }
  return $absolutePath
}

function Copy-SourceTree {
  param(
    [string]$SourceRoot,
    [string]$DestinationRoot,
    [string[]]$ExcludedDirectoryNames = @()
  )

  function ConvertTo-ExtendedPath {
    param([string]$Path)
    $fullPath = [System.IO.Path]::GetFullPath($Path)
    if ($env:OS -eq "Windows_NT" -and -not $fullPath.StartsWith("\\?\")) {
      return "\\?\$fullPath"
    }
    return $fullPath
  }

  $sourcePath = (Resolve-Path $SourceRoot).Path
  [void][System.IO.Directory]::CreateDirectory((ConvertTo-ExtendedPath $DestinationRoot))
  $excluded = @{}
  foreach ($name in $ExcludedDirectoryNames) {
    $excluded[$name] = $true
  }

  function Copy-SourceTreeDirectory {
    param(
      [string]$CurrentSource,
      [string]$CurrentDestination
    )

    [void][System.IO.Directory]::CreateDirectory((ConvertTo-ExtendedPath $CurrentDestination))
    Get-ChildItem -LiteralPath $CurrentSource -File -Force | ForEach-Object {
      $destinationFile = Join-Path $CurrentDestination $_.Name
      [System.IO.File]::Copy(
        (ConvertTo-ExtendedPath $_.FullName),
        (ConvertTo-ExtendedPath $destinationFile),
        $true
      )
    }
    Get-ChildItem -LiteralPath $CurrentSource -Directory -Force | ForEach-Object {
      if ($excluded.ContainsKey($_.Name)) {
        return
      }
      Copy-SourceTreeDirectory -CurrentSource $_.FullName -CurrentDestination (Join-Path $CurrentDestination $_.Name)
    }
  }

  Copy-SourceTreeDirectory -CurrentSource $sourcePath -CurrentDestination $DestinationRoot
}

function Copy-FirmwareSet {
  param(
    [string]$BuildDir,
    [string]$Destination
  )

  Copy-BuildArtifacts -BuildDir $BuildDir -Destination $Destination
}

$firmwareSourceRoot = if ($builtFirmwareCache) {
  $builtFirmwareCache
} else {
  Join-Path $repoRoot ".pio/build"
}
Copy-FirmwareSet -BuildDir (Join-Path $firmwareSourceRoot "stackchan") -Destination $displayFirmwareDir
Copy-FirmwareSet -BuildDir (Join-Path $firmwareSourceRoot "stackchan_servo_calibration") -Destination $servoFirmwareDir
Copy-FirmwareSet -BuildDir (Join-Path $firmwareSourceRoot "stackchan_release_full") -Destination $fullOnlineFirmwareDir
if ($builtFirmwareCache -and (Test-Path -LiteralPath $builtFirmwareCache)) {
  Remove-Item -LiteralPath $builtFirmwareCache -Recurse -Force
  $builtFirmwareCache = $null
}

$mediaFiles = @(
  "docs/media/stackchan_alive_preview.png",
  "docs/media/stackchan_alive_expression_sheet.png",
  "docs/media/stackchan_alive_preview.mp4",
  "docs/media/stackchan_alive_preview.gif",
  "docs/media/stackchan_alive_speech_preview.gif"
)

$diagramFiles = @(
  "docs/media/diagrams/01-system-overview.png",
  "docs/media/diagrams/02-firmware-task-architecture.png",
  "docs/media/diagrams/03-persona-engine.png",
  "docs/media/diagrams/04-face-runtime.png",
  "docs/media/diagrams/05-motion-servo-safety.png",
  "docs/media/diagrams/06-brain-bridge-protocol.png",
  "docs/media/diagrams/08-io-abstraction-builds.png"
)

$windowsPowerShell = Join-Path $env:SystemRoot "System32/WindowsPowerShell/v1.0/powershell.exe"
if (-not (Test-Path -LiteralPath $windowsPowerShell)) {
  $windowsPowerShell = "powershell.exe"
}
& $windowsPowerShell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $PSScriptRoot "render_voice_samples.ps1")
if ($LASTEXITCODE -ne 0) {
  throw "Voice sample rendering failed."
}

foreach ($file in $mediaFiles) {
  if (-not (Test-Path -LiteralPath $file)) {
    throw "Missing preview artifact: $file"
  }
  Copy-Item -LiteralPath $file -Destination $mediaDir
}

$diagramMediaDir = Join-Path $mediaDir "diagrams"
New-Item -ItemType Directory -Force -Path $diagramMediaDir | Out-Null
foreach ($file in $diagramFiles) {
  if (-not (Test-Path -LiteralPath $file)) {
    throw "Missing architecture diagram: $file"
  }
  Copy-Item -LiteralPath $file -Destination $diagramMediaDir
}

$faceArtifactFiles = @(
  "artifacts/face/phase_a_idle_10s.gif",
  "artifacts/face/phase_a_blink_filmstrip_50ms.png",
  "artifacts/face/phase_a_unlabeled_expression_sheet.png",
  "artifacts/face/phase_b_unlabeled_expression_sheet.png",
  "artifacts/face/phase_c_idle_10s.gif",
  "artifacts/face/phase_d_idle_to_listen_filmstrip_50ms.png",
  "artifacts/face/phase_d_think_to_speak_filmstrip_50ms.png",
  "artifacts/face/phase_d_idle_to_sleep_filmstrip_50ms.png",
  "artifacts/face/phase_e_speech_reactive_6s.gif"
)

foreach ($file in $faceArtifactFiles) {
  if (-not (Test-Path -LiteralPath $file)) {
    throw "Missing Phase A face artifact: $file"
  }
  Copy-Item -LiteralPath $file -Destination $faceArtifactDir
}

$voiceMediaDir = Join-Path $mediaDir "voice"
$voiceRvcMediaDir = Join-Path $voiceMediaDir "rvc"
$voiceSidecarDir = Join-Path $voiceMediaDir "sidecars"
New-Item -ItemType Directory -Force -Path $voiceMediaDir | Out-Null
New-Item -ItemType Directory -Force -Path $voiceRvcMediaDir | Out-Null
New-Item -ItemType Directory -Force -Path $voiceSidecarDir | Out-Null
$personaPromptAssetsPath = Join-Path $outDir "persona_prompt_assets.json"
$personaPromptPython = Get-StackchanPreviewPython
& $personaPromptPython tools/export_persona_prompt_assets.py --persona spark --out $personaPromptAssetsPath | Out-Null
if ($LASTEXITCODE -ne 0) {
  throw "Persona prompt asset export failed."
}
$personaPromptAssets = Get-Content -LiteralPath $personaPromptAssetsPath -Raw | ConvertFrom-Json

foreach ($asset in @($personaPromptAssets.assets)) {
  $sourcePath = Join-Path $repoRoot ([string]$asset.source_path)
  $promptWavPath = Join-ReleasePackagePath ([string]$asset.wav_path)
  $promptSidecarPath = Join-ReleasePackagePath ([string]$asset.sidecar_path)
  if (-not (Test-Path -LiteralPath $sourcePath)) {
    throw "Missing persona packaged prompt source: $sourcePath"
  }
  New-Item -ItemType Directory -Force -Path (Split-Path -Parent $promptWavPath), (Split-Path -Parent $promptSidecarPath) | Out-Null
  Copy-Item -LiteralPath $sourcePath -Destination $promptWavPath -Force
  & $windowsPowerShell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $PSScriptRoot "generate_speech_envelope_sidecar.ps1") `
    -InputWav $promptWavPath `
    -OutputJson $promptSidecarPath
  if ($LASTEXITCODE -ne 0) {
    throw "Packaged prompt sidecar generation failed for $($asset.wav_path)."
  }
  & $windowsPowerShell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $PSScriptRoot "verify_speech_envelope_sidecar.ps1") `
    -Path $promptSidecarPath
  if ($LASTEXITCODE -ne 0) {
    throw "Packaged prompt sidecar verification failed for $($asset.sidecar_path)."
  }
}

$voiceMediaFiles = @(
  "docs/media/voice/stackchan_spark_audition_warm_slow_greeting.wav",
  "docs/media/voice/stackchan_spark_audition_bright_robot_greeting.wav",
  "docs/media/voice/stackchan_spark_audition_bright_robot_greeting.mp3",
  "docs/media/voice/stackchan_spark_thinking.mp3",
  "docs/media/voice/VOICE_SAMPLES.md",
  "docs/media/voice/VOICE_AUDITION.html"
)

foreach ($file in $voiceMediaFiles) {
  if (-not (Test-Path -LiteralPath $file)) {
    throw "Missing voice artifact: $file"
  }
  Copy-Item -LiteralPath $file -Destination $voiceMediaDir
}

& $windowsPowerShell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $PSScriptRoot "verify_tracked_rvc_assets.ps1") `
  -VoiceRoot "media/voice/rvc"
if ($LASTEXITCODE -ne 0) {
  throw "Tracked RVC audition asset verification failed."
}

$voiceRvcFiles = @(
  "media/voice/rvc/README.md"
)

foreach ($file in $voiceRvcFiles) {
  if (-not (Test-Path -LiteralPath $file)) {
    throw "Missing public RVC BYOM policy: $file"
  }
  Copy-Item -LiteralPath $file -Destination $voiceRvcMediaDir
}

Copy-Item -LiteralPath "README.md" -Destination $outDir
Copy-Item -LiteralPath "AGENTS.md" -Destination $outDir
Copy-Item -LiteralPath "docs/README.md" -Destination $docsDir
$packageReadmePath = Join-Path $outDir "README.md"
$packageReadmeText = [System.IO.File]::ReadAllText($packageReadmePath)
$packageReadmeText = $packageReadmeText.Replace("](docs/media/", "](media/")
[System.IO.File]::WriteAllText(
  $packageReadmePath,
  $packageReadmeText,
  (New-Object System.Text.UTF8Encoding($false))
)
Copy-Item -LiteralPath "docs/ANDROID_COMPANION_SPEC.md" -Destination $docsDir
Copy-Item -LiteralPath "docs/ANDROID_COMPANION_TEST_PLAN.md" -Destination $docsDir
Copy-Item -LiteralPath "docs/ANDROID_PLAY_RELEASE.md" -Destination $docsDir
Copy-Item -LiteralPath "docs/ANDROID_PLAY_POLICY_DECLARATIONS.md" -Destination $docsDir
Copy-Item -LiteralPath "docs/ANDROID_PLAY_PRIVACY_POLICY.md" -Destination $docsDir
Copy-Item -LiteralPath "docs/BRAIN_MODEL.md" -Destination $docsDir
Copy-Item -LiteralPath "docs/COMPANION_CROSS_PLATFORM_PLAN.md" -Destination $docsDir
Copy-Item -LiteralPath "docs/CONVERSATION_V2_ROADMAP.md" -Destination $docsDir
Copy-Item -LiteralPath "docs/CHARACTER_LOCK.md" -Destination $docsDir
Copy-Item -LiteralPath "docs/CREATING_PERSONAS.md" -Destination $docsDir
Copy-Item -LiteralPath "docs/CUSTOMIZING_THE_FACE.md" -Destination $docsDir
Copy-Item -LiteralPath "docs/DESKTOP_PYTHON_RUNTIME.md" -Destination $docsDir
Copy-Item -LiteralPath "docs/GAP_ANALYSIS.md" -Destination $docsDir
Copy-Item -LiteralPath "docs/JOHNNY_ALIVE_PATHWAY.md" -Destination $docsDir
Copy-Item -LiteralPath "docs/PERSONA_PACKS.md" -Destination $docsDir
Copy-Item -LiteralPath "docs/HARDWARE_SIMULATION.md" -Destination $docsDir
Copy-Item -LiteralPath "docs/HARDWARE_FEATURE_ROADMAP.md" -Destination $docsDir
Copy-Item -LiteralPath "docs/LOCAL_RESEARCH_TOOLING.md" -Destination $docsDir
Copy-Item -LiteralPath "docs/LOCAL_VISION.md" -Destination $docsDir
Copy-Item -LiteralPath "docs/LAN_OTA.md" -Destination $docsDir
Copy-Item -LiteralPath "docs/POWER_BLACKOUT_FORENSICS.md" -Destination $docsDir
Copy-Item -LiteralPath "docs/SPEAKER_AUDIO_RESEARCH.md" -Destination $docsDir
Copy-Item -LiteralPath "docs/VOICE_V2_DIRECTML.md" -Destination $docsDir
Copy-Item -LiteralPath "docs/DEVICE_BRINGUP.md" -Destination $docsDir
Copy-Item -LiteralPath "docs/BRIDGE_PROTOCOL.md" -Destination $docsDir
Copy-Item -LiteralPath "docs/FIRST_DEPLOY_STATUS.md" -Destination $docsDir
Copy-Item -LiteralPath "docs/ARRIVAL_DAY_RUNBOOK.md" -Destination $docsDir
Copy-Item -LiteralPath "docs/stackchan_procedural_runtime_design.pdf" -Destination $docsDir
Copy-Item -LiteralPath "docs/PRIVACY.md" -Destination $docsDir
Copy-Item -LiteralPath "docs/PRODUCTION_READINESS.md" -Destination $docsDir
Copy-Item -LiteralPath "docs/ARRIVAL_DAY_RUNBOOK.md" -Destination (Join-Path $outDir "ARRIVAL_DAY_RUNBOOK.md")
Copy-Item -LiteralPath "docs/RELEASE_QUICKSTART.md" -Destination (Join-Path $outDir "QUICKSTART.md")
Copy-Item -LiteralPath "docs/RELEASE_PROCESS.md" -Destination $docsDir
Copy-Item -LiteralPath "docs/ROLLOUT_CHECKLIST.md" -Destination $docsDir
Copy-Item -LiteralPath "docs/VOICE_PERSONALITY.md" -Destination $docsDir
Copy-Item -LiteralPath "docs/VOICE_SOURCE_PROVENANCE_TEMPLATE.md" -Destination $docsDir
Copy-Item -LiteralPath "docs/CI_ACCOUNT_BLOCK_EXCEPTION_TEMPLATE.json" -Destination $docsDir
Copy-Item -LiteralPath "docs/store-assets" -Destination $docsDir -Recurse
Copy-Item -LiteralPath "data/calibration.yaml" -Destination $dataDir
Copy-Item -LiteralPath "data/expressions.yaml" -Destination $dataDir
Copy-Item -LiteralPath "data/commands.yaml" -Destination $dataDir
Copy-Item -LiteralPath "data/voice_persona.yaml" -Destination $dataDir
Copy-Item -LiteralPath "data/voice_source_provenance.yaml" -Destination $dataDir
Copy-Item -LiteralPath "data/voice_rvc_base.yaml" -Destination $dataDir
Copy-Item -LiteralPath "data/voice_rvc_base_metadata.json" -Destination $dataDir
$bridgePackageFiles = @(
  "README.md",
  "bridge_memory.py",
  "test_bridge_memory.py",
  "memory_maintenance.py",
  "test_memory_maintenance.py",
  "character_harness.py",
  "test_character_harness.py",
  "character_red_team.py",
  "test_character_red_team.py",
  "persona_pack.py",
  "test_persona_pack.py",
  "reference_bridge.py",
  "test_reference_bridge.py",
  "research_broker.py",
  "test_research_broker.py",
  "robot_embodiment.py",
  "test_robot_embodiment.py",
  "local_facts.py",
  "test_local_facts.py",
  "trusted_facts_smoke.py",
  "test_trusted_facts_smoke.py",
  "local_runner.py",
  "test_local_runner.py",
  "litert_lm_stackchan_wrapper.py",
  "test_litert_lm_stackchan_wrapper.py",
  "litert_lm_contract_smoke.py",
  "test_litert_lm_contract_smoke.py",
  "engine_probe.py",
  "test_engine_probe.py",
  "model_benchmark.py",
  "test_model_benchmark.py",
  "stt_normalization.py",
  "stt_adapter.py",
  "windows_speech_stt.py",
  "whisper_cpp_stt.py",
  "test_stt_adapter.py",
  "tts_adapter.py",
  "test_tts_adapter.py",
  "lan_service.py",
  "test_lan_service.py",
  "ollama_stackchan_runner.py",
  "test_ollama_stackchan_runner.py",
  "pc_brain_probe.py",
  "selected_voice_tts.py",
  "windows_speech_tts.py",
  "rvc_tts.py",
  "rvc_tts_client.py",
  "rvc_worker_service.py",
  "rvc_directml_tts_client.py",
  "rvc_directml_worker_service.py",
  "rvc_production_tts_client.py",
  "test_rvc_production_tts_client.py",
  "voice_v2_directml_runtime.py",
  "voice_v2_directml_benchmark.py",
  "voice_v2_wire_benchmark.py",
  "vision_service.py",
  "test_vision_service.py",
  "requirements-vision.txt",
  "lan_smoke.py",
  "test_lan_smoke.py",
  "android_companion_probe.py",
  "test_android_companion_probe.py",
  "android_companion_soak.py",
  "test_android_companion_soak.py",
  "android_udp_beacon_probe.py",
  "test_android_udp_beacon_probe.py",
  "test_android_dashboard_media_gate.py",
  "hardware_simulator.py",
  "test_hardware_simulator.py",
  "prearrival_sim_check.py",
  "test_prearrival_sim_check.py"
)
foreach ($bridgeFile in $bridgePackageFiles) {
  Copy-Item -LiteralPath (Join-Path "bridge" $bridgeFile) -Destination $bridgeDir
}
Copy-Item -LiteralPath "bridge/models/README.md" -Destination $bridgeModelsDir
Copy-Item -LiteralPath "bridge/models/LICENSE" -Destination $bridgeModelsDir
Copy-Item -LiteralPath "bridge/models/face_detection_yunet_2023mar.onnx" -Destination $bridgeModelsDir

Copy-Item -LiteralPath "personas" -Destination (Join-Path $outDir "personas") -Recurse

$personaVerifierPython = Get-StackchanPreviewPython
$personaStatus = & $personaVerifierPython tools/verify_persona_pack.py spark --json
$personaStatusExit = $LASTEXITCODE
$personaStatusPath = Join-Path $outDir "persona_pack_status.json"
$personaStatus | Set-Content -Path $personaStatusPath -Encoding UTF8
if ($personaStatusExit -ne 0) {
  throw "Persona pack verification failed."
}
$glowPersonaStatus = & $personaVerifierPython tools/verify_persona_pack.py glow --json
if ($LASTEXITCODE -ne 0) {
  throw "Glow persona pack verification failed: $glowPersonaStatus"
}

$characterRedTeamOutDir = Join-Path $outDir "character-red-team"
$characterRedTeamPython = Get-StackchanPreviewPython
& $characterRedTeamPython bridge/character_red_team.py --out-dir $characterRedTeamOutDir --json | Out-Null
if ($LASTEXITCODE -ne 0) {
  throw "Character red-team dry run failed."
}

& $windowsPowerShell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $PSScriptRoot "export_voice_source_status.ps1") `
  -VoiceSourceProvenancePath (Join-Path $dataDir "voice_source_provenance.yaml") `
  -VoiceSourceProvenanceDisplayPath "data/voice_source_provenance.yaml" `
  -TemplatePath (Join-Path $docsDir "VOICE_SOURCE_PROVENANCE_TEMPLATE.md") `
  -TemplateDisplayPath "docs/VOICE_SOURCE_PROVENANCE_TEMPLATE.md" `
  -OutputDir $outDir
if ($LASTEXITCODE -ne 0) {
  throw "Voice source status export failed."
}

& $windowsPowerShell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $PSScriptRoot "export_rvc_voice_base_status.ps1") `
  -ManifestPath (Join-Path $dataDir "voice_rvc_base.yaml") `
  -MetadataPath (Join-Path $dataDir "voice_rvc_base_metadata.json") `
  -OutputDir $outDir
if ($LASTEXITCODE -ne 0) {
  throw "RVC voice base status export failed."
}

$companionEvidenceFiles = @(
  "output/companion/c6-evidence/EVIDENCE.json",
  "output/companion/c6-evidence/EVIDENCE.md",
  "output/companion/c6-brain-supervisor/BRAIN_SUPERVISOR_SMOKE.json",
  "output/companion/c6-brain-supervisor/BRAIN_SUPERVISOR_SMOKE.md",
  "output/companion/c6-brain-supervisor/DIAGNOSTICS_EXPORT.json",
  "output/companion/c6-gui-rehearsal/GUI_REHEARSAL.json",
  "output/companion/c6-gui-rehearsal/GUI_REHEARSAL.md",
  "output/companion/c6-gui-rehearsal/DIAGNOSTICS_EXPORT.json"
)

foreach ($file in $companionEvidenceFiles) {
  if (-not (Test-Path -LiteralPath $file)) {
    throw "Missing companion C6 evidence artifact: $file"
  }
  $destination = Join-ReleasePackagePath ("companion/evidence/" + $file.Substring("output/companion/".Length))
  New-Item -ItemType Directory -Force -Path (Split-Path -Parent $destination) | Out-Null
  Copy-Item -LiteralPath $file -Destination $destination
}

$releaseTools = @(
  "tools/flash_device.cmd",
  "tools/flash_device.ps1",
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
  "tools/check_android_play_store_evidence.cmd",
  "tools/check_android_play_store_evidence.ps1",
  "tools/check_android_v1_evidence_bundle.cmd",
  "tools/check_android_v1_evidence_bundle.ps1",
  "tools/check_android_diagnostics_export_evidence.cmd",
  "tools/check_android_diagnostics_export_evidence.ps1",
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
  "tools/release_asset_contract.ps1",
  "tools/verify_release_asset_contract.cmd",
  "tools/verify_release_asset_contract.ps1",
  "tools/export_github_actions_status.cmd",
  "tools/export_github_actions_status.ps1",
  "tools/new_ci_account_block_exception.cmd",
  "tools/new_ci_account_block_exception.ps1",
  "tools/export_voice_source_status.cmd",
  "tools/export_voice_source_status.ps1",
  "tools/export_rvc_voice_base_status.cmd",
  "tools/export_rvc_voice_base_status.ps1",
  "tools/export_rollout_status.cmd",
  "tools/export_rollout_status.ps1",
  "tools/setup_voice_tools.cmd",
  "tools/setup_voice_tools.ps1",
  "tools/open_voice_audition.cmd",
  "tools/open_voice_audition.ps1",
  "tools/render_voice_samples.cmd",
  "tools/render_voice_samples.ps1",
  "tools/render_rvc_audition_mp3s.cmd",
  "tools/render_rvc_audition_mp3s.ps1",
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
  "tools/test_android_gemma_evidence_contract.cmd",
  "tools/test_android_gemma_evidence_contract.ps1",
  "tools/test_android_v1_evidence_bundle_contract.cmd",
  "tools/test_android_v1_evidence_bundle_contract.ps1",
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
  "tools/provision_stackchan_wifi.cmd",
  "tools/provision_stackchan_wifi.ps1",
  "tools/check_android_controls_evidence.cmd",
  "tools/check_android_controls_evidence.ps1",
  "tools/check_android_gemma_evidence.cmd",
  "tools/check_android_gemma_evidence.ps1",
  "tools/check_android_pairing_evidence.cmd",
  "tools/check_android_pairing_evidence.ps1",
  "tools/check_android_screen_off_soak_evidence.cmd",
  "tools/check_android_screen_off_soak_evidence.ps1",
  "tools/check_android_speech_evidence.cmd",
  "tools/check_android_speech_evidence.ps1",
  "tools/check_android_wifi_evidence.cmd",
  "tools/check_android_wifi_evidence.ps1",
  "tools/test_android_controls_evidence_contract.cmd",
  "tools/test_android_controls_evidence_contract.ps1",
  "tools/test_android_diagnostics_export_evidence_contract.cmd",
  "tools/test_android_diagnostics_export_evidence_contract.ps1",
  "tools/test_android_pairing_evidence_contract.cmd",
  "tools/test_android_pairing_evidence_contract.ps1",
  "tools/test_android_screen_off_soak_evidence_contract.cmd",
  "tools/test_android_screen_off_soak_evidence_contract.ps1",
  "tools/test_android_speech_evidence_contract.cmd",
  "tools/test_android_speech_evidence_contract.ps1",
  "tools/test_android_wifi_evidence_contract.cmd",
  "tools/test_android_wifi_evidence_contract.ps1",
  "tools/check_voice_source_readiness.ps1",
  "tools/test_voice_source_readiness_contract.ps1"
)

foreach ($file in $releaseTools) {
  if (-not (Test-Path -LiteralPath $file)) {
    throw "Missing release tool: $file"
  }
  Copy-Item -LiteralPath $file -Destination $toolsDir
}

Copy-Item -LiteralPath "platformio.ini" -Destination $provenanceDir
Copy-Item -LiteralPath "partitions_esp_sr_16.csv" -Destination $provenanceDir
Copy-Item -LiteralPath "requirements-preview.txt" -Destination $provenanceDir
Copy-Item -LiteralPath ".github/workflows/firmware.yml" -Destination $provenanceDir
Copy-Item -LiteralPath ".github/workflows/release.yml" -Destination $provenanceDir
Copy-Item -LiteralPath "src" -Destination (Join-Path $provenanceDir "src") -Recurse
Copy-Item -LiteralPath "bridge" -Destination (Join-Path $provenanceDir "bridge") -Recurse
Copy-Item -LiteralPath "protocol-fixtures" -Destination (Join-Path $provenanceDir "protocol-fixtures") -Recurse
Copy-Item -LiteralPath "personas" -Destination (Join-Path $provenanceDir "personas") -Recurse
Copy-Item -LiteralPath "test" -Destination (Join-Path $provenanceDir "test") -Recurse
Copy-SourceTree -SourceRoot "companion" -DestinationRoot (Join-Path $provenanceDir "companion") -ExcludedDirectoryNames @("build", ".gradle", ".kotlin")
$dataProvenanceDir = Join-Path $provenanceDir "data"
New-Item -ItemType Directory -Force -Path $dataProvenanceDir | Out-Null
Copy-Item -LiteralPath "data/commands.yaml" -Destination $dataProvenanceDir
$audioFixtureProvenanceDir = Join-Path $provenanceDir "test/fixtures/audio"
New-Item -ItemType Directory -Force -Path $audioFixtureProvenanceDir | Out-Null
foreach ($fixture in @(
  "test/fixtures/audio/speech_right.wav",
  "test/fixtures/audio/speech_left.wav",
  "test/fixtures/audio/music_center.wav",
  "test/fixtures/audio/fan_noise.wav"
)) {
  if (-not (Test-Path -LiteralPath $fixture)) {
    throw "Missing P3 audio saliency fixture: $fixture"
  }
  Copy-Item -LiteralPath $fixture -Destination $audioFixtureProvenanceDir
}

function Invoke-CapturedText {
  param(
    [scriptblock]$Command
  )

  $oldEncoding = $env:PYTHONIOENCODING
  $env:PYTHONIOENCODING = "utf-8"
  try {
    $output = & $Command 2>&1
    if ($LASTEXITCODE -ne 0) {
      throw "Command failed while generating dependency provenance: $($output | Out-String)"
    }
    return ($output | Out-String).TrimEnd()
  } finally {
    $env:PYTHONIOENCODING = $oldEncoding
  }
}

function Get-DeclaredLibDeps {
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

  return @($libDeps)
}

function Convert-PioPackageList {
  param([string]$Text)

  $entries = @()
  foreach ($line in ($Text -split "`r?`n")) {
    $clean = ($line -replace "^[^A-Za-z0-9]+", "").Trim()
    if ($clean -match "^Platform\s+(.+?)\s+@\s+([^\s]+)\s+\(required:\s*(.+)\)$") {
      $entries += [ordered]@{
        kind = "platform"
        name = $Matches[1]
        version = $Matches[2]
        required = $Matches[3]
      }
    } elseif ($clean -match "^(.+?)\s+@\s+([^\s]+)\s+\(required:\s*(.+)\)$") {
      $entries += [ordered]@{
        kind = "package"
        name = $Matches[1]
        version = $Matches[2]
        required = $Matches[3]
      }
    }
  }

  return @($entries)
}

function Copy-LicenseEvidenceTree {
  param(
    [string]$SourceRoot,
    [string]$DestinationRoot
  )

  if (-not (Test-Path -LiteralPath $SourceRoot -PathType Container)) {
    return 0
  }

  $sourcePath = (Resolve-Path -LiteralPath $SourceRoot).Path.TrimEnd("\", "/")
  $count = 0
  foreach ($file in Get-ChildItem -LiteralPath $sourcePath -Recurse -File -Force -ErrorAction SilentlyContinue) {
    if ($file.Name -notmatch '(?i)^(LICENSE|LICENCE|COPYING|NOTICE)(\..*)?$') {
      continue
    }
    $relative = $file.FullName.Substring($sourcePath.Length + 1)
    $destination = Join-Path $DestinationRoot $relative
    New-Item -ItemType Directory -Force -Path (Split-Path -Parent $destination) | Out-Null
    Copy-Item -LiteralPath $file.FullName -Destination $destination -Force
    $count++
  }
  return $count
}

function Copy-EnvironmentLicenseEvidence {
  param(
    [string]$Environment,
    [object[]]$ResolvedPackages
  )

  $destination = Join-Path $thirdPartyLicensesDir $Environment
  New-Item -ItemType Directory -Force -Path $destination | Out-Null
  $count = Copy-LicenseEvidenceTree `
    -SourceRoot (Join-Path $repoRoot ".pio/libdeps/$Environment") `
    -DestinationRoot (Join-Path $destination "libdeps")

  $coreDir = Get-ReleasePlatformioCoreDir -Environment $Environment
  $platformRoot = Join-Path $coreDir "platforms/espressif32"
  $count += Copy-LicenseEvidenceTree `
    -SourceRoot $platformRoot `
    -DestinationRoot (Join-Path $destination "platform/espressif32")
  foreach ($metadataName in @("platform.json", "package.json")) {
    $metadataPath = Join-Path $platformRoot $metadataName
    if (Test-Path -LiteralPath $metadataPath -PathType Leaf) {
      $metadataDestination = Join-Path $destination "platform/espressif32/$metadataName"
      New-Item -ItemType Directory -Force -Path (Split-Path -Parent $metadataDestination) | Out-Null
      Copy-Item -LiteralPath $metadataPath -Destination $metadataDestination -Force
    }
  }

  $packageNames = @(
    $ResolvedPackages |
      Where-Object { $_.kind -eq "package" } |
      ForEach-Object { [string]$_.name } |
      Sort-Object -Unique
  )
  foreach ($packageName in $packageNames) {
    $packageRoot = Join-Path $coreDir "packages/$packageName"
    if (-not (Test-Path -LiteralPath $packageRoot -PathType Container)) {
      continue
    }
    $packageDestination = Join-Path $destination "packages/$packageName"
    $count += Copy-LicenseEvidenceTree -SourceRoot $packageRoot -DestinationRoot $packageDestination
    $packageMetadata = Join-Path $packageRoot "package.json"
    if (Test-Path -LiteralPath $packageMetadata -PathType Leaf) {
      New-Item -ItemType Directory -Force -Path $packageDestination | Out-Null
      Copy-Item -LiteralPath $packageMetadata -Destination (Join-Path $packageDestination "package.json") -Force
    }
  }

  return $count
}

function Test-GitRequirement {
  param([string]$Value)
  return $Value -match "(?i)(git\+|\.git($|[#@\s])|github\.com/.+\.git)"
}

function Test-PinnedGitRequirement {
  param([string]$Value)
  if (-not (Test-GitRequirement $Value)) {
    return $true
  }
  return $Value -match "#[A-Za-z0-9_.-]+$"
}

function Get-DependencyAudit {
  param(
    [string[]]$DeclaredLibDeps,
    [object[]]$DisplayResolvedPackages,
    [object[]]$ServoResolvedPackages,
    [object[]]$FullResolvedPackages
  )

  $directGitDepsMissingRef = @(
    $DeclaredLibDeps |
      Where-Object { (Test-GitRequirement $_) -and -not (Test-PinnedGitRequirement $_) }
  )

  $allResolved = @()
  foreach ($entry in $DisplayResolvedPackages) {
    $allResolved += [pscustomobject][ordered]@{
      environment = "stackchan"
      kind = $entry.kind
      name = $entry.name
      version = $entry.version
      required = $entry.required
    }
  }
  foreach ($entry in $ServoResolvedPackages) {
    $allResolved += [pscustomobject][ordered]@{
      environment = "stackchan_servo_calibration"
      kind = $entry.kind
      name = $entry.name
      version = $entry.version
      required = $entry.required
    }
  }
  foreach ($entry in $FullResolvedPackages) {
    $allResolved += [pscustomobject][ordered]@{
      environment = "stackchan_release_full"
      kind = $entry.kind
      name = $entry.name
      version = $entry.version
      required = $entry.required
    }
  }

  $duplicateResolvedPackages = @()
  foreach ($envGroup in ($allResolved | Group-Object environment)) {
    foreach ($nameGroup in ($envGroup.Group | Group-Object name)) {
      if ($nameGroup.Count -gt 1) {
        $duplicateResolvedPackages += [pscustomobject][ordered]@{
          environment = $envGroup.Name
          name = $nameGroup.Name
          count = $nameGroup.Count
          entries = @($nameGroup.Group)
        }
      }
    }
  }

  $unpinnedGitRequirements = @(
    $allResolved |
      Where-Object { (Test-GitRequirement $_.required) -and -not (Test-PinnedGitRequirement $_.required) }
  )

  $gitResolvedWithoutSha = @(
    $allResolved |
      Where-Object { (Test-GitRequirement $_.required) -and $_.version -notmatch "sha\.[0-9a-fA-F]+" }
  )

  return [ordered]@{
    policy = "Direct Git dependencies must include a ref; resolved Git dependencies must record a SHA. Known upstream transitive Git declarations are recorded for review."
    directGitDepsMissingRef = @($directGitDepsMissingRef)
    duplicateResolvedPackages = @($duplicateResolvedPackages)
    unpinnedGitRequirements = @($unpinnedGitRequirements)
    gitResolvedWithoutSha = @($gitResolvedWithoutSha)
  }
}

$platformioVersion = Invoke-CapturedText {
  Invoke-StackchanReleasePlatformio -Environment "stackchan" -Arguments @("--version")
}
$displayDeps = Invoke-CapturedText {
  Invoke-StackchanReleasePlatformio -Environment "stackchan" -Arguments @("pkg", "list", "-e", "stackchan")
}
$displayResolvedPackages = Convert-PioPackageList $displayDeps
$displayLicenseCount = Copy-EnvironmentLicenseEvidence `
  -Environment "stackchan" `
  -ResolvedPackages $displayResolvedPackages
$servoDeps = Invoke-CapturedText {
  Invoke-StackchanReleasePlatformio -Environment "stackchan_servo_calibration" -Arguments @("pkg", "list", "-e", "stackchan_servo_calibration")
}
$servoResolvedPackages = Convert-PioPackageList $servoDeps
$servoLicenseCount = Copy-EnvironmentLicenseEvidence `
  -Environment "stackchan_servo_calibration" `
  -ResolvedPackages $servoResolvedPackages
$fullDeps = Invoke-CapturedText {
  Invoke-StackchanReleasePlatformio -Environment "stackchan_release_full" -Arguments @("pkg", "list", "-e", "stackchan_release_full")
}
$fullResolvedPackages = Convert-PioPackageList $fullDeps
$fullLicenseCount = Copy-EnvironmentLicenseEvidence `
  -Environment "stackchan_release_full" `
  -ResolvedPackages $fullResolvedPackages
$visionLicenseDir = Join-Path $thirdPartyLicensesDir "models/opencv-zoo-yunet"
New-Item -ItemType Directory -Force -Path $visionLicenseDir | Out-Null
Copy-Item -LiteralPath "bridge/models/LICENSE" -Destination (Join-Path $visionLicenseDir "LICENSE") -Force
Copy-Item -LiteralPath "bridge/models/README.md" -Destination (Join-Path $visionLicenseDir "README.md") -Force

$thirdPartyLicenseFiles = @(
  Get-ChildItem -LiteralPath $thirdPartyLicensesDir -Recurse -File -Force |
    Sort-Object FullName
)
$thirdPartyLicenseIndex = @($thirdPartyLicenseFiles | ForEach-Object {
  [ordered]@{
    path = $_.FullName.Substring($thirdPartyLicensesDir.Length + 1).Replace("\", "/")
    bytes = $_.Length
    sha256 = (Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash.ToLowerInvariant()
  }
})
$thirdPartyLicenseIndex | ConvertTo-Json -Depth 5 | Set-Content `
  -LiteralPath (Join-Path $thirdPartyLicensesDir "files.json") `
  -Encoding UTF8

@"
# Third-Party Notices

This release package includes third-party source and binary components. Their installed license,
licence, copying, notice, and package-metadata files are preserved under
``third_party_licenses/`` and hash-indexed in ``third_party_licenses/files.json``.

- ``stackchan`` captured license files: $displayLicenseCount
- ``stackchan_servo_calibration`` captured license files: $servoLicenseCount
- ``stackchan_release_full`` captured license files: $fullLicenseCount
- OpenCV Zoo YuNet model: verbatim MIT license and source/hash record included

The pioarduino platform declares Apache-2.0. Arduino-ESP32 3.3.6 package metadata declares
LGPL-2.1-or-later. Direct libraries include MIT and Apache-2.0 components; M5GFX also carries
embedded BSD and font-license notices, which are retained from its installed tree.

These notices describe third-party components only. They do not select or grant a license for
Stackchan: Alive itself. Review ``dependency_lock.json`` for exact versions and resolved sources.
This inventory is release evidence, not legal advice.
"@ | Set-Content -LiteralPath (Join-Path $outDir "THIRD_PARTY_NOTICES.md") -Encoding UTF8

$previewRequirements = (Get-Content -LiteralPath "requirements-preview.txt" -Raw).TrimEnd()
$previewRequirementEntries = @(
  Get-Content -LiteralPath "requirements-preview.txt" |
    ForEach-Object { $_.Trim() } |
    Where-Object { -not [string]::IsNullOrWhiteSpace($_) -and -not $_.StartsWith("#") }
)
$declaredLibDeps = Get-DeclaredLibDeps
$dependencyAudit = Get-DependencyAudit `
  -DeclaredLibDeps $declaredLibDeps `
  -DisplayResolvedPackages $displayResolvedPackages `
  -ServoResolvedPackages $servoResolvedPackages `
  -FullResolvedPackages $fullResolvedPackages

@"
# Dependency Provenance

Version: $Version
Commit: $commit
Generated UTC: $((Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ"))

This report records the dependency state used to generate this prerelease package. The source configuration files are copied under ``provenance/``.

## Tooling

``````text
$platformioVersion
``````

## Preview Python Requirements

``````text
$previewRequirements
``````

## PlatformIO Dependencies: stackchan

``````text
$displayDeps
``````

## PlatformIO Dependencies: stackchan_servo_calibration

``````text
$servoDeps
``````

## PlatformIO Dependencies: stackchan_release_full

``````text
$fullDeps
``````

## Dependency Audit

Policy: $($dependencyAudit.policy)

Direct Git dependencies missing refs: $(@($dependencyAudit.directGitDepsMissingRef).Count)

Duplicate resolved package names: $(@($dependencyAudit.duplicateResolvedPackages).Count)

Unpinned upstream Git requirements: $(@($dependencyAudit.unpinnedGitRequirements).Count)

Resolved Git packages without SHA evidence: $(@($dependencyAudit.gitResolvedWithoutSha).Count)

The current upstream ``stackchan-arduino`` manifest declares ``SCServo`` through an unpinned Git URL. This project also declares ``SCServo#ee6ee4a`` directly, and the release verifier requires every resolved Git package to record a SHA in ``dependency_lock.json``.
"@ | Set-Content -Path (Join-Path $outDir "DEPENDENCIES.md") -Encoding UTF8

$dependencyLock = [ordered]@{
  schema = "stackchan.dependency-lock.v1"
  version = $Version
  commit = $commit
  generatedUtc = (Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")
  platformioCore = $platformioVersion
  previewRequirements = @($previewRequirementEntries)
  declaredLibDeps = @($declaredLibDeps)
  environments = [ordered]@{
    stackchan = [ordered]@{
      board = "m5stack-cores3"
      framework = "arduino"
      platform = "espressif32@7.0.1"
      resolvedPackages = @($displayResolvedPackages)
    }
    stackchan_servo_calibration = [ordered]@{
      board = "m5stack-cores3"
      framework = "arduino"
      platform = "espressif32@7.0.1"
      resolvedPackages = @($servoResolvedPackages)
    }
    stackchan_release_full = [ordered]@{
      board = "m5stack-cores3"
      framework = "arduino"
      platform = "pioarduino/platform-espressif32@55.03.36"
      resolvedPackages = @($fullResolvedPackages)
    }
  }
  dependencyAudit = $dependencyAudit
}
$dependencyLock | ConvertTo-Json -Depth 8 | Set-Content -Path (Join-Path $outDir "dependency_lock.json") -Encoding UTF8

$manifest = [ordered]@{
  version = $Version
  commit = $commit
  shortCommit = $shortCommit
  generatedUtc = (Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")
  board = "m5stack-cores3"
  defaultEnvironment = "stackchan"
  includedEnvironments = @("stackchan", "stackchan_servo_calibration", "stackchan_release_full")
  servoDefault = "display-only build disables servos; calibration and full-online builds require explicit servo-risk acknowledgement"
  status = "device-ready prerelease; hardware validation pending"
  dirty = ($sourceDirtyFiles.Count -gt 0)
  dirtyFiles = @($sourceDirtyFiles)
  generatedMediaDirtyFiles = @($generatedMediaDirtyFiles)
  dependencyReport = "DEPENDENCIES.md"
  dependencyLock = "dependency_lock.json"
  thirdPartyNotices = "THIRD_PARTY_NOTICES.md"
  thirdPartyLicenseIndex = "third_party_licenses/files.json"
  readinessReport = "READINESS_REPORT.md"
  readinessReportJson = "readiness_report.json"
  ciStatusReport = "GITHUB_ACTIONS_STATUS.md"
  ciStatusReportJson = "github_actions_status.json"
  releaseAssetManifest = "release_assets.json"
  acceptanceChecklist = "RELEASE_ACCEPTANCE.md"
  acceptanceChecklistJson = "release_acceptance.json"
  androidCompanionSpec = "docs/ANDROID_COMPANION_SPEC.md"
  androidCompanionTestPlan = "docs/ANDROID_COMPANION_TEST_PLAN.md"
  androidPlayRelease = "docs/ANDROID_PLAY_RELEASE.md"
  androidPlayPolicyDeclarations = "docs/ANDROID_PLAY_POLICY_DECLARATIONS.md"
  androidPlayPrivacyPolicy = "docs/ANDROID_PLAY_PRIVACY_POLICY.md"
  androidPlayIcon = "docs/store-assets/play/icon-512.png"
  androidPlayFeatureGraphic = "docs/store-assets/play/feature-graphic-1024x500.png"
  companionCrossPlatformPlan = "docs/COMPANION_CROSS_PLATFORM_PLAN.md"
  conversationV2Roadmap = "docs/CONVERSATION_V2_ROADMAP.md"
  androidCompanionSource = "provenance/companion"
  agentGuide = "AGENTS.md"
  docsIndex = "docs/README.md"
  brainModelGuide = "docs/BRAIN_MODEL.md"
  characterLock = "docs/CHARACTER_LOCK.md"
  faceCustomizationGuide = "docs/CUSTOMIZING_THE_FACE.md"
  gapAnalysis = "docs/GAP_ANALYSIS.md"
  johnnyAlivePathway = "docs/JOHNNY_ALIVE_PATHWAY.md"
  personaPacksGuide = "docs/PERSONA_PACKS.md"
  voicePersonalityGuide = "docs/VOICE_PERSONALITY.md"
  voiceV2Guide = "docs/VOICE_V2_DIRECTML.md"
  hardwareFeatureRoadmap = "docs/HARDWARE_FEATURE_ROADMAP.md"
  localResearchTooling = "docs/LOCAL_RESEARCH_TOOLING.md"
  localVisionGuide = "docs/LOCAL_VISION.md"
  bodySensorValidator = "tools/body_sensor_validation.ps1"
  bodySensorValidatorContract = "tools/test_body_sensor_validation_contract.ps1"
  finalSoakRunner = "tools/run_full_system_soak_http_motion.ps1"
  finalSoakWrapper = "tools/start_warm_rocm_full_system_soak.ps1"
  productionFinalSoakWrapper = "tools/start_production_full_system_soak.ps1"
  finalSoakChecker = "tools/check_full_system_soak_evidence.ps1"
  finalSoakCheckerContract = "tools/test_full_system_soak_evidence_contract.ps1"
  currentLeadChecker = "tools/check_current_lead_reproducibility.ps1"
  currentLeadCheckerContract = "tools/test_current_lead_reproducibility_contract.ps1"
  currentLeadArchiver = "tools/archive_current_lead.ps1"
  currentLeadArchiverContract = "tools/test_archive_current_lead_contract.ps1"
  finalSoakWrapperContract = "tools/test_start_warm_rocm_full_system_soak_contract.ps1"
  productionFinalSoakWrapperContract = "tools/test_start_production_full_system_soak_contract.ps1"
  cameraFollowWakeValidator = "tools/camera_follow_wake_validation.ps1"
  cameraFollowWakeValidatorContract = "tools/test_camera_follow_wake_validation_contract.ps1"
  cameraFollowWakeCompletion = "tools/complete_camera_follow_wake_validation.ps1"
  cameraFollowWakeCompletionContract = "tools/test_complete_camera_follow_wake_validation_contract.ps1"
  consumerPromotionContract = "tools/test_consumer_promotion_contract.ps1"
  visionWorker = "bridge/vision_service.py"
  visionRequirements = "bridge/requirements-vision.txt"
  visionModel = "bridge/models/face_detection_yunet_2023mar.onnx"
  visionModelSha256 = "8f2383e4dd3cfbb4553ea8718107fc0423210dc964f9f4280604804ed2552fa4"
  includedPersonaPacks = @("spark", "glow")
  activePersona = "spark"
  activePersonaPack = "personas/spark"
  activePersonaVerification = "persona_pack_status.json"
  activePersonaPromptAssets = "persona_prompt_assets.json"
  characterRedTeamReport = "character-red-team/CHARACTER_RED_TEAM.md"
  characterRedTeamReportJson = "character-red-team/character_red_team.json"
  bridgeProtocol = "docs/BRIDGE_PROTOCOL.md"
  privacyModel = "docs/PRIVACY.md"
  expressionProfiles = "data/expressions.yaml"
  voicePersona = "data/voice_persona.yaml"
  voiceSourceProvenanceTemplate = "docs/VOICE_SOURCE_PROVENANCE_TEMPLATE.md"
  voiceSourceProvenance = "data/voice_source_provenance.yaml"
  ciAccountBlockExceptionTemplate = "docs/CI_ACCOUNT_BLOCK_EXCEPTION_TEMPLATE.json"
  voiceSourceStatusReport = "VOICE_SOURCE_STATUS.md"
  voiceSourceStatusReportJson = "voice_source_status.json"
  voiceRvcBase = "data/voice_rvc_base.yaml"
  voiceRvcBaseMetadata = "data/voice_rvc_base_metadata.json"
  voiceRvcBaseStatusReport = "RVC_VOICE_BASE_STATUS.md"
  voiceRvcBaseStatusReportJson = "rvc_voice_base_status.json"
  companionEvidenceManifest = "companion/evidence/c6-evidence/EVIDENCE.json"
  companionEvidence = @(
    "companion/evidence/c6-evidence/EVIDENCE.json",
    "companion/evidence/c6-evidence/EVIDENCE.md",
    "companion/evidence/c6-brain-supervisor/BRAIN_SUPERVISOR_SMOKE.json",
    "companion/evidence/c6-brain-supervisor/BRAIN_SUPERVISOR_SMOKE.md",
    "companion/evidence/c6-brain-supervisor/DIAGNOSTICS_EXPORT.json",
    "companion/evidence/c6-gui-rehearsal/GUI_REHEARSAL.json",
    "companion/evidence/c6-gui-rehearsal/GUI_REHEARSAL.md",
    "companion/evidence/c6-gui-rehearsal/DIAGNOSTICS_EXPORT.json"
  )
  mediaArtifacts = @(
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
    "media/voice/rvc/README.md"
  )
  includedTools = @(
    "tools/flash_device.cmd",
    "tools/flash_device.ps1",
    "tools/flash_release_firmware.cmd",
    "tools/flash_release_firmware.ps1",
    "tools/flash_wifi_bridge.cmd",
    "tools/flash_wifi_bridge.ps1",
    "tools/platformio_apply_wifi_bridge_env.py",
    "tools/prepare_desktop_python_runtime.cmd",
    "tools/prepare_desktop_python_runtime.ps1",
    "tools/check_desktop_python_runtime_payload.cmd",
    "tools/check_desktop_python_runtime_payload.ps1",
    "tools/test_desktop_python_runtime_payload_contract.cmd",
    "tools/test_desktop_python_runtime_payload_contract.ps1",
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
    "tools/check_android_play_store_evidence.cmd",
    "tools/check_android_play_store_evidence.ps1",
    "tools/check_android_v1_evidence_bundle.cmd",
    "tools/check_android_v1_evidence_bundle.ps1",
    "tools/check_android_diagnostics_export_evidence.cmd",
    "tools/check_android_diagnostics_export_evidence.ps1",
    "tools/check_companion_v1_readiness.cmd",
    "tools/check_companion_v1_readiness.ps1",
    "tools/export_companion_release_evidence.cmd",
    "tools/export_companion_release_evidence.ps1",
    "tools/preview_python_resolver.ps1",
    "tools/render_preview.py",
    "tools/render_rvc_auditions.ps1",
    "tools/audit_published_release.cmd",
    "tools/audit_published_release.ps1",
    "tools/publish_release.cmd",
    "tools/publish_release.ps1",
    "tools/release_asset_contract.ps1",
    "tools/verify_release_asset_contract.cmd",
    "tools/verify_release_asset_contract.ps1",
    "tools/export_github_actions_status.cmd",
    "tools/export_github_actions_status.ps1",
    "tools/new_ci_account_block_exception.cmd",
    "tools/new_ci_account_block_exception.ps1",
    "tools/export_voice_source_status.cmd",
    "tools/export_voice_source_status.ps1",
    "tools/export_rvc_voice_base_status.cmd",
    "tools/export_rvc_voice_base_status.ps1",
    "tools/export_rollout_status.cmd",
    "tools/export_rollout_status.ps1",
    "tools/open_voice_audition.cmd",
    "tools/open_voice_audition.ps1",
    "tools/render_rvc_audition_mp3s.cmd",
    "tools/render_rvc_audition_mp3s.ps1",
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
    "tools/test_android_gemma_evidence_contract.cmd",
    "tools/test_android_gemma_evidence_contract.ps1",
    "tools/test_android_v1_evidence_bundle_contract.cmd",
    "tools/test_android_v1_evidence_bundle_contract.ps1",
    "tools/prepare_device_arrival.cmd",
    "tools/prepare_device_arrival.ps1",
    "tools/run_device_preflight.cmd",
    "tools/run_device_preflight.ps1",
    "tools/run_character_harness_tests.cmd",
    "tools/run_character_harness_tests.ps1",
    "tools/run_character_red_team.cmd",
    "tools/run_character_red_team.ps1",
    "tools/run_bridge_reference_tests.cmd",
    "tools/run_bridge_reference_tests.ps1",
    "tools/run_engine_probe.cmd",
    "tools/run_engine_probe.ps1",
    "tools/run_litert_lm_smoke.cmd",
    "tools/run_litert_lm_smoke.ps1",
    "tools/run_lan_smoke.cmd",
    "tools/run_lan_smoke.ps1",
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
    "tools/verify_rvc_auditions.cmd",
    "tools/verify_rvc_auditions.ps1",
    "tools/verify_tracked_rvc_assets.cmd",
    "tools/verify_tracked_rvc_assets.ps1",
    "tools/verify_rvc_voice_base.cmd",
    "tools/verify_rvc_voice_base.ps1",
    "tools/verify_release_package.cmd",
    "tools/verify_release_package.ps1",
    "tools/verify_share_release.cmd",
    "tools/verify_share_release.ps1",
    "tools/provision_stackchan_wifi.cmd",
    "tools/provision_stackchan_wifi.ps1",
    "tools/check_android_controls_evidence.cmd",
    "tools/check_android_controls_evidence.ps1",
    "tools/check_android_gemma_evidence.cmd",
    "tools/check_android_gemma_evidence.ps1",
    "tools/check_android_pairing_evidence.cmd",
    "tools/check_android_pairing_evidence.ps1",
    "tools/check_android_screen_off_soak_evidence.cmd",
    "tools/check_android_screen_off_soak_evidence.ps1",
    "tools/check_android_speech_evidence.cmd",
    "tools/check_android_speech_evidence.ps1",
    "tools/check_android_wifi_evidence.cmd",
    "tools/check_android_wifi_evidence.ps1",
    "tools/test_android_controls_evidence_contract.cmd",
    "tools/test_android_controls_evidence_contract.ps1",
    "tools/test_android_diagnostics_export_evidence_contract.cmd",
    "tools/test_android_diagnostics_export_evidence_contract.ps1",
    "tools/test_android_pairing_evidence_contract.cmd",
    "tools/test_android_pairing_evidence_contract.ps1",
    "tools/test_android_screen_off_soak_evidence_contract.cmd",
    "tools/test_android_screen_off_soak_evidence_contract.ps1",
    "tools/test_android_speech_evidence_contract.cmd",
    "tools/test_android_speech_evidence_contract.ps1",
    "tools/test_android_wifi_evidence_contract.cmd",
    "tools/test_android_wifi_evidence_contract.ps1",
    "tools/check_voice_source_readiness.ps1",
    "tools/test_voice_source_readiness_contract.ps1",
    "tools/compare_hardware_sim_baseline.cmd",
    "tools/compare_hardware_sim_baseline.ps1",
    "tools/create_persona_pack.cmd",
    "tools/create_persona_pack.ps1",
    "tools/create_persona_pack.py",
    "tools/export_persona_prompt_assets.py",
    "tools/render_voice_samples.cmd",
    "tools/render_voice_samples.ps1",
    "tools/setup_voice_tools.cmd",
    "tools/setup_voice_tools.ps1",
    "tools/setup_whisper_cpp.cmd",
    "tools/setup_whisper_cpp.ps1",
    "tools/verify_persona_pack.cmd",
    "tools/verify_persona_pack.ps1",
    "tools/verify_persona_pack.py",
    "tools/verify_voice_samples.cmd",
    "tools/verify_voice_samples.ps1"
  )
  provenanceFiles = @(
    "provenance/platformio.ini",
    "provenance/partitions_esp_sr_16.csv",
    "provenance/requirements-preview.txt",
    "provenance/bridge/README.md",
    "provenance/bridge/export_protocol_fixtures.py",
    "provenance/bridge/test_protocol_fixtures.py",
    "provenance/bridge/persona_pack.py",
    "provenance/bridge/test_persona_pack.py",
    "provenance/bridge/character_red_team.py",
    "provenance/bridge/test_character_red_team.py",
    "provenance/bridge/reference_bridge.py",
    "provenance/bridge/test_reference_bridge.py",
    "provenance/bridge/local_runner.py",
    "provenance/bridge/test_local_runner.py",
    "provenance/bridge/litert_lm_stackchan_wrapper.py",
    "provenance/bridge/test_litert_lm_stackchan_wrapper.py",
    "provenance/bridge/litert_lm_contract_smoke.py",
    "provenance/bridge/test_litert_lm_contract_smoke.py",
    "provenance/bridge/engine_probe.py",
    "provenance/bridge/test_engine_probe.py",
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
    "provenance/bridge/hardware_simulator.py",
    "provenance/bridge/test_hardware_simulator.py",
    "provenance/bridge/prearrival_sim_check.py",
    "provenance/bridge/test_prearrival_sim_check.py",
    "provenance/protocol-fixtures/endpoint_hello.json",
    "provenance/protocol-fixtures/owner_status.json",
    "provenance/protocol-fixtures/settings_get.json",
    "provenance/protocol-fixtures/settings_set.json",
    "provenance/protocol-fixtures/invalid/missing_type.json",
    "provenance/protocol-fixtures/invalid/wrong_protocol.json",
    "provenance/firmware.yml",
    "provenance/release.yml",
    "provenance/data/commands.yaml",
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
    "provenance/personas/glow/voice.yaml",
    "provenance/src/main.cpp",
    "provenance/src/persona/SpeechPlanner.hpp",
    "provenance/src/persona/SpeechPlanner.cpp",
    "provenance/src/persona/CommandMap.hpp",
    "provenance/src/persona/CommandMap.cpp",
    "provenance/src/persona/GazeTracker.hpp",
    "provenance/src/persona/GazeTracker.cpp",
    "provenance/src/persona/EarconSynth.hpp",
    "provenance/src/persona/EarconSynth.cpp",
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
    "provenance/src/io/AudioOut.hpp",
    "provenance/src/io/AudioOut.cpp",
    "provenance/src/io/SpeechPromptBank.hpp",
    "provenance/src/io/SpeechPromptBank.cpp",
    "provenance/src/io/SpeechAdapter.hpp",
    "provenance/src/io/SpeechAdapter.cpp",
    "provenance/test/fixtures/audio/speech_right.wav",
    "provenance/test/fixtures/audio/speech_left.wav",
    "provenance/test/fixtures/audio/music_center.wav",
    "provenance/test/fixtures/audio/fan_noise.wav"
  )
}

$manifest | ConvertTo-Json -Depth 4 | Set-Content -Path (Join-Path $outDir "release_manifest.json") -Encoding UTF8

$ciStatus = [ordered]@{
  schema = "stackchan.github-actions-status.v1"
  version = $Version
  commit = $commit
  repo = "RobVanProd/stackchan_alive"
  generatedUtc = (Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")
  status = "post-push-check-required"
  interpretation = "This package was generated before the matching GitHub Actions runs could be observed. After pushing main and the release tag, run tools/export_github_actions_status.cmd to replace this placeholder with the observed GitHub Actions result."
  requiredWorkflows = @("Firmware", "Release")
  missingRequiredWorkflows = @("Firmware", "Release")
  workflows = @()
}
$ciStatus | ConvertTo-Json -Depth 8 | Set-Content -Path (Join-Path $outDir "github_actions_status.json") -Encoding UTF8

@"
# GitHub Actions Status

Release: $Version
Commit: $commit
Repository: RobVanProd/stackchan_alive
Status: post-push-check-required
Required workflows: Firmware, Release

This package was generated before the matching GitHub Actions runs could be observed. After pushing main and the release tag, run:

    .\tools\export_github_actions_status.cmd -Version $Version -Commit $commit -OutputDir .

If GitHub reports that jobs did not start because of account billing or spending limits, keep the exported report with the release evidence and use local release verification plus device preflight as the available technical evidence until the account issue is fixed.

Machine-readable status: ``github_actions_status.json``
"@ | Set-Content -Path (Join-Path $outDir "GITHUB_ACTIONS_STATUS.md") -Encoding UTF8

$readinessReport = [ordered]@{
  schema = "stackchan.readiness-report.v1"
  version = $Version
  commit = $commit
  generatedUtc = (Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")
  status = "device-ready-prerelease"
  consumerRollout = "blocked-pending-hardware-validation"
  noHardwareProof = @(
    [ordered]@{ gate = "release-package-created"; status = "pass"; evidence = "release_manifest.json" },
    [ordered]@{ gate = "firmware-binaries-present"; status = "pass"; evidence = "firmware/display_only and firmware/servo_calibration" },
    [ordered]@{ gate = "preview-media-present"; status = "pass"; evidence = "media/stackchan_alive_preview.png, media/stackchan_alive_preview.mp4, media/stackchan_alive_preview.gif" },
    [ordered]@{ gate = "voice-samples-present"; status = "pass"; evidence = "media/voice/stackchan_spark_greeting.wav, media/voice/stackchan_spark_thinking.wav, media/voice/stackchan_spark_safety.wav, warm-slow and bright-robot WAV variants, plus MP3 quick auditions" },
    [ordered]@{ gate = "voice-source-provenance-template-present"; status = "pass"; evidence = "docs/VOICE_SOURCE_PROVENANCE_TEMPLATE.md and data/voice_source_provenance.yaml" },
    [ordered]@{ gate = "voice-source-status-report-present"; status = "pass"; evidence = "VOICE_SOURCE_STATUS.md and voice_source_status.json" },
    [ordered]@{ gate = "rvc-voice-base-status-report-present"; status = "pass"; evidence = "RVC_VOICE_BASE_STATUS.md and rvc_voice_base_status.json; review-only until production voice-source rights clear" },
    [ordered]@{ gate = "character-red-team-dry-run"; status = "pass"; evidence = "character-red-team/CHARACTER_RED_TEAM.md and character_red_team.json; real gate still requires a configured model runner" },
    [ordered]@{ gate = "companion-c6-brain-supervision-evidence"; status = "pass"; evidence = "companion/evidence/c6-evidence/EVIDENCE.json plus C6 brain supervisor, GUI rehearsal, and diagnostics exports" },
    [ordered]@{ gate = "expression-sheet-present"; status = "pass"; evidence = "media/stackchan_alive_expression_sheet.png" },
    [ordered]@{ gate = "dependency-provenance-present"; status = "pass"; evidence = "DEPENDENCIES.md and dependency_lock.json" },
    [ordered]@{ gate = "checksums-present"; status = "pass"; evidence = "SHA256SUMS.txt" },
    [ordered]@{ gate = "github-actions-status-report-present"; status = "pass"; evidence = "GITHUB_ACTIONS_STATUS.md and github_actions_status.json" },
    [ordered]@{ gate = "arrival-tools-present"; status = "pass"; evidence = "tools/prepare_device_arrival.cmd, tools/start_hardware_evidence.cmd, and tools/check_hardware_evidence_progress.cmd" },
    [ordered]@{ gate = "hardware-media-importer-present"; status = "pass"; evidence = "tools/add_hardware_evidence_media.cmd validates phone media and writes media_manifest.json" },
    [ordered]@{ gate = "servo-risk-acknowledgement-required"; status = "pass"; evidence = "tools/flash_release_firmware.ps1 requires -ConfirmServoRisk for servo_calibration" }
  )
  hardwareGates = @(
    [ordered]@{ gate = "display-only-flash"; status = "pending-device"; requiredEvidence = "display-only serial log, real photo/video, 10-minute idle observation" },
    [ordered]@{ gate = "speech-mouth-demo-evidence"; status = "pending-device"; requiredEvidence = "logs/speech_mouth_demo_serial.log with streamed speech envelope commands, speech clear, and completion; logs/speak_all_intents_serial.log with every packaged speech intent, earcon, and audio-output handoff" },
    [ordered]@{ gate = "servo-calibration"; status = "pending-device"; requiredEvidence = "supervised servo log, yaw classification, calibration values" },
    [ordered]@{ gate = "mixed-mode-soak"; status = "pending-device"; requiredEvidence = "30-minute soak log with heartbeat and runtime health markers" },
    [ordered]@{ gate = "power-cycle-recovery"; status = "pending-device"; requiredEvidence = "USB power-cycle observation marked pass" },
    [ordered]@{ gate = "target-speaker-audio-evidence"; status = "pending-device"; requiredEvidence = "completed AUDIO_REVIEW.md plus a real-device speaker recording under audio/" },
    [ordered]@{ gate = "hardware-evidence-verification"; status = "pending-device"; requiredEvidence = "tools/verify_hardware_evidence.cmd passes on the completed packet" },
    [ordered]@{ gate = "production-voice-source"; status = "pending-before-consumer-rollout"; requiredEvidence = "completed docs/VOICE_SOURCE_PROVENANCE_TEMPLATE.md plus licensed or owned production source" }
  )
  promotionRule = "Do not mark consumer-ready or non-prerelease until all hardware gates pass with evidence."
  nextOperatorCommand = ".\tools\prepare_device_arrival.cmd -Port COM3 -Operator `"Your Name`" -DeviceId STACKCHAN-001"
}

$readinessReport | ConvertTo-Json -Depth 8 | Set-Content -Path (Join-Path $outDir "readiness_report.json") -Encoding UTF8

$acceptanceChecklist = [ordered]@{
  schema = "stackchan.release-acceptance.v1"
  version = $Version
  commit = $commit
  generatedUtc = (Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")
  releaseClass = "device-ready-prerelease"
  currentDecision = "test-ready-for-device-arrival"
  consumerRolloutDecision = "blocked-pending-hardware-validation"
  noHardwareAcceptance = @(
    [ordered]@{ requirement = "clean-release-package"; status = "pass"; evidence = "release_manifest.json" },
    [ordered]@{ requirement = "firmware-artifacts-present"; status = "pass"; evidence = "firmware/display_only and firmware/servo_calibration" },
    [ordered]@{ requirement = "dependency-provenance-present"; status = "pass"; evidence = "DEPENDENCIES.md and dependency_lock.json" },
    [ordered]@{ requirement = "checksums-present"; status = "pass"; evidence = "SHA256SUMS.txt" },
    [ordered]@{ requirement = "github-actions-status-report-present"; status = "pass"; evidence = "GITHUB_ACTIONS_STATUS.md and github_actions_status.json" },
    [ordered]@{ requirement = "visual-review-media-present"; status = "pass"; evidence = "media/stackchan_alive_preview.png, media/stackchan_alive_expression_sheet.png, media/stackchan_alive_preview.mp4" },
    [ordered]@{ requirement = "voice-review-samples-present"; status = "pass"; evidence = "media/voice/stackchan_spark_greeting.wav, media/voice/stackchan_spark_thinking.wav, media/voice/stackchan_spark_safety.wav, warm-slow and bright-robot WAV variants, plus MP3 quick auditions" },
    [ordered]@{ requirement = "voice-source-provenance-template-present"; status = "pass"; evidence = "docs/VOICE_SOURCE_PROVENANCE_TEMPLATE.md and data/voice_source_provenance.yaml" },
    [ordered]@{ requirement = "voice-source-status-report-present"; status = "pass"; evidence = "VOICE_SOURCE_STATUS.md and voice_source_status.json" },
    [ordered]@{ requirement = "rvc-voice-base-status-report-present"; status = "pass"; evidence = "RVC_VOICE_BASE_STATUS.md and rvc_voice_base_status.json; confirms review-only RVC base cache/hash status when available" },
    [ordered]@{ requirement = "character-red-team-dry-run-present"; status = "pass"; evidence = "character-red-team/CHARACTER_RED_TEAM.md and character_red_team.json" },
    [ordered]@{ requirement = "companion-c6-brain-supervision-evidence"; status = "pass"; evidence = "companion/evidence/c6-evidence/EVIDENCE.json plus C6 brain supervisor, GUI rehearsal, and diagnostics exports" },
    [ordered]@{ requirement = "arrival-tools-present"; status = "pass"; evidence = "tools/prepare_device_arrival.cmd, tools/start_hardware_evidence.cmd, tools/check_hardware_evidence_progress.cmd, tools/verify_hardware_evidence.cmd" },
    [ordered]@{ requirement = "hardware-media-importer-present"; status = "pass"; evidence = "tools/add_hardware_evidence_media.cmd validates imported photos/videos/audio and records hashes" },
    [ordered]@{ requirement = "servo-risk-gated"; status = "pass"; evidence = "tools/flash_release_firmware.ps1 requires -ConfirmServoRisk for servo_calibration" },
    [ordered]@{ requirement = "share-page-verifiable"; status = "pass"; evidence = "tools/share_release.cmd and tools/verify_share_release.cmd" }
  )
  hardwareAcceptanceRequired = @(
    [ordered]@{ requirement = "display-only-flash"; status = "pending-device"; requiredEvidence = "display-only serial log, real photo/video, 10-minute idle observation" },
    [ordered]@{ requirement = "speech-mouth-demo-evidence"; status = "pending-device"; requiredEvidence = "logs/speech_mouth_demo_serial.log with streamed speech envelope commands, speech clear, and completion; logs/speak_all_intents_serial.log with every packaged speech intent, earcon, and audio-output handoff" },
    [ordered]@{ requirement = "servo-calibration"; status = "pending-device"; requiredEvidence = "supervised servo log, yaw classification, calibration values" },
    [ordered]@{ requirement = "mixed-mode-soak"; status = "pending-device"; requiredEvidence = "30-minute soak log with heartbeat and runtime health markers" },
    [ordered]@{ requirement = "power-cycle-recovery"; status = "pending-device"; requiredEvidence = "USB power-cycle observation marked pass" },
    [ordered]@{ requirement = "target-speaker-audio-evidence"; status = "pending-device"; requiredEvidence = "completed AUDIO_REVIEW.md plus a real-device speaker recording under audio/" },
    [ordered]@{ requirement = "hardware-evidence-verification"; status = "pending-device"; requiredEvidence = "tools/verify_hardware_evidence.cmd passes on the completed packet" },
    [ordered]@{ requirement = "production-voice-source"; status = "pending-before-consumer-rollout"; requiredEvidence = "completed docs/VOICE_SOURCE_PROVENANCE_TEMPLATE.md plus licensed or owned production voice source" }
  )
  promotionRule = "Keep prerelease status until every hardwareAcceptanceRequired item is pass with evidence."
}

$acceptanceChecklist | ConvertTo-Json -Depth 8 | Set-Content -Path (Join-Path $outDir "release_acceptance.json") -Encoding UTF8

@"
# Release Acceptance Checklist

Release: $Version
Commit: $commit
Decision: test-ready for device arrival
Consumer rollout: blocked pending hardware validation

## Accepted Without Hardware

- [x] Clean release package: ``release_manifest.json``
- [x] Firmware artifacts present: ``firmware/display_only`` and ``firmware/servo_calibration``
- [x] Dependency provenance present: ``DEPENDENCIES.md`` and ``dependency_lock.json``
- [x] Checksums present: ``SHA256SUMS.txt``
- [x] GitHub Actions status report present: ``GITHUB_ACTIONS_STATUS.md`` and ``github_actions_status.json``
- [x] Visual review media present: preview image, expression sheet, and preview video
- [x] Voice review samples present: Stackchan Spark greeting, thinking, safety, warm-slow audition, and bright-robot audition WAVs
- [x] Voice source provenance template present: ``docs/VOICE_SOURCE_PROVENANCE_TEMPLATE.md`` and ``data/voice_source_provenance.yaml``
- [x] Voice source status report present: ``VOICE_SOURCE_STATUS.md`` and ``voice_source_status.json``
- [x] Character red-team dry-run report present: ``character-red-team/CHARACTER_RED_TEAM.md`` and ``character-red-team/character_red_team.json``
- [x] Companion C6 brain-supervision evidence present: ``companion/evidence/c6-evidence/EVIDENCE.json``
- [x] Arrival tools present: prepare, evidence capture, and evidence verification scripts
- [x] Hardware media importer present: ``tools/add_hardware_evidence_media.cmd`` validates imported photos/videos/audio and records hashes
- [x] Evidence progress checker present: ``tools/check_hardware_evidence_progress.cmd``
- [x] Servo risk gated by explicit ``-ConfirmServoRisk``
- [x] Share page can be verified by ``tools/verify_share_release.cmd``

## Still Required Before Consumer Rollout

- [ ] Display-only flash with serial log, real photo/video, and 10-minute idle observation
- [ ] Speech-mouth demo evidence: ``logs/speech_mouth_demo_serial.log`` with streamed speech envelope commands, ``speech clear``, and completion, plus ``logs/speak_all_intents_serial.log`` proving every packaged speech intent, earcon, and audio-output handoff
- [ ] Supervised servo calibration with yaw classification and calibration values
- [ ] 30-minute mixed idle/listen/think/speak soak with heartbeat and runtime health markers
- [ ] Power-cycle recovery: USB power-cycle observation marked pass
- [ ] Target-speaker audio evidence: completed ``AUDIO_REVIEW.md`` plus a real-device speaker recording under ``audio/``
- [ ] Completed hardware evidence packet that passes ``tools/verify_hardware_evidence.cmd``
- [ ] Completed voice-source provenance with a licensed or owned production voice source

Machine-readable checklist: ``release_acceptance.json``
"@ | Set-Content -Path (Join-Path $outDir "RELEASE_ACCEPTANCE.md") -Encoding UTF8

@"
# Readiness Report

Release: $Version
Commit: $commit
Status: device-ready prerelease
Consumer rollout: blocked pending hardware validation

## Proven Without Hardware

- Release package is generated with a clean manifest: ``release_manifest.json``.
- Display-only and servo-calibration firmware binaries are present under ``firmware/``.
- Preview image, animation, video, and expression QA sheet are present under ``media/``.
- Dependency provenance is present in ``DEPENDENCIES.md`` and ``dependency_lock.json``.
- Package checksums are present in ``SHA256SUMS.txt`` and verified by ``tools/verify_release_package.cmd``.
- GitHub Actions status is recorded in ``GITHUB_ACTIONS_STATUS.md`` and ``github_actions_status.json``. If hosted jobs cannot start because of account billing or spending limits, local release verification and device preflight are the available technical evidence until billing is fixed.
- Voice source provenance is staged in ``docs/VOICE_SOURCE_PROVENANCE_TEMPLATE.md`` and ``data/voice_source_provenance.yaml``; ``VOICE_SOURCE_STATUS.md`` and ``voice_source_status.json`` list the blocked production-voice gates. Current WAVs and audition variants remain prototype review samples until a licensed or owned production source is recorded.
- Character red-team dry-run evidence is present in ``character-red-team/CHARACTER_RED_TEAM.md`` and ``character-red-team/character_red_team.json``. It proves the adversarial corpus and validator path; the gate only passes after the same suite runs with ``--require-runner`` against a configured local model.
- Companion C6 brain-supervision evidence is present under ``companion/evidence/`` and proves the desktop GUI can start the Python brain, drive simulated robot turns, stop, restart, and export diagnostics before the physical robot arrives.
- Arrival-day helpers are included under ``tools/``, including the progress checker and strict evidence verifier.
- Hardware media import helper is included as ``tools/add_hardware_evidence_media.cmd`` for copying phone photos/videos and speaker recordings into evidence packets with SHA256 hashes.
- Servo calibration flashing requires explicit ``-ConfirmServoRisk`` acknowledgement.

## Pending Device Evidence

- Display-only flash, visible procedural face, and 10-minute idle run.
- Speech-mouth demo evidence: ``logs/speech_mouth_demo_serial.log`` with streamed speech envelope commands, ``speech clear``, and completion, plus ``logs/speak_all_intents_serial.log`` proving every packaged speech intent, earcon, and audio-output handoff.
- Supervised servo calibration, yaw classification, and calibration values.
- 30-minute mixed idle/listen/think/speak soak.
- Power-cycle recovery: USB power-cycle observation marked pass.
- Target-speaker audio evidence: completed ``AUDIO_REVIEW.md`` plus a real-device speaker recording under ``audio/``.
- Completed hardware evidence packet that passes ``tools/verify_hardware_evidence.cmd``.
- Completed voice-source provenance with licensed or owned production source.

Do not mark this release consumer-ready or non-prerelease until every pending device gate has explicit evidence.

Recommended arrival command from the extracted package:

    $($readinessReport.nextOperatorCommand)
"@ | Set-Content -Path (Join-Path $outDir "READINESS_REPORT.md") -Encoding UTF8

@"
# Stackchan: Alive $Version

Commit: $commit

This is a device-ready prerelease package for Stackchan: Alive, a character OS for Stackchan hardware. It is built, native-tested, compile-checked, includes preview media plus an expression QA sheet, and keeps servo output disabled by default.

Dependency provenance is recorded in ``DEPENDENCIES.md`` and ``dependency_lock.json``, with copied build inputs under ``provenance/``. Voice source provenance is staged in ``docs/VOICE_SOURCE_PROVENANCE_TEMPLATE.md`` and ``data/voice_source_provenance.yaml``; voice approval status is summarized in ``VOICE_SOURCE_STATUS.md`` and ``voice_source_status.json``. Readiness status is recorded in ``READINESS_REPORT.md`` and ``readiness_report.json``. GitHub Actions status is recorded in ``GITHUB_ACTIONS_STATUS.md`` and ``github_actions_status.json``. Preflight, hardware simulation, pre-arrival simulation check, sim-vs-hardware comparison, flashing, manual publishing, evidence capture, evidence progress checking, hardware evidence verification, and package verification helpers are included under ``tools/``.

Engine readiness quick check:

- Run ``tools/run_engine_probe.cmd -Json`` to check whether local model, STT, and TTS commands are configured.
- Run ``tools/run_engine_probe.cmd -RunModelSmoke -Json`` after exporting a runner command to capture the first real smoke result. This is setup evidence; full model selection still requires ``bridge/model_benchmark.py --require-runner`` with a passing ``summary.candidate_gate`` and recorded ``recommended_profile``.
- Run ``python bridge/model_benchmark.py --profile gemma4-e2b-gguf --require-runner --json`` after the real runner is configured to write ``MODEL_BENCHMARK.md/json`` with candidate blockers, ``ready_profiles``, and the fastest ready profile recommendation.
- Run ``tools/run_character_red_team.cmd -Json`` to regenerate the dry-run Character Lock red-team report. After a real runner is configured, run ``tools/run_character_red_team.cmd -RequireRunner -Json`` so the B7 gate is backed by an actual model instead of deterministic fallback responses.
- For the mobile/low-footprint brain path, configure ``STACKCHAN_LITERT_LM_COMMAND`` and use ``bridge/litert_lm_stackchan_wrapper.py`` as ``STACKCHAN_GEMMA4_E2B_LITERT_COMMAND`` before running the LiteRT-LM profile benchmark.

No-hardware simulation quick check:

- Run ``tools/run_prearrival_sim_check.cmd`` to create ``output/prearrival-sim/latest/PREARRIVAL_SIM_CHECK.md/json`` with the combined virtual CoreS3/LAN/audio proxy status, nested LAN smoke report, and engine-readiness status.
- After a real runner command is configured, run ``tools/run_prearrival_sim_check.cmd -RunModelBenchmark -Json`` to include nested ``model-benchmark/MODEL_BENCHMARK.md/json`` output and the ``model-benchmark-candidate`` gate in the same pre-arrival report.
- Run ``tools/run_lan_smoke.cmd`` to create ``output/lan-smoke/latest/LAN_SMOKE.md/json`` with a real local TCP/WebSocket bridge handshake, text turn, fake mic upload, fake STT, fake TTS, PCM16 binary downlink check, and visible ``thinking-latency`` timing while delayed speech is still running.
- Run ``tools/run_litert_lm_smoke.cmd`` to create ``output/litert-lm-smoke/latest/LITERT_LM_SMOKE.md/json`` with a deterministic two-layer LiteRT-LM wrapper contract check.
- Run ``tools/run_hardware_simulation.cmd`` to exercise the virtual Stackchan bridge proxy before the physical unit is available.
- The simulator proves bridge frame ordering, LAN text turns, fake mic PCM upload through fake STT, conversation timing, fake WAV TTS normalization to PCM16 downlink, speech-envelope handoff, binary TTS audio stream accounting, virtual CoreS3 input/display/speaker counters, offline command fallback, power-cycle recovery, bridge-kill recovery, and timeout failure behavior. It does not replace real hardware evidence.
- After an evidence packet has simulator output plus real display, speech, and bridge replay logs, run ``RUN_SIM_HARDWARE_COMPARE.cmd`` inside that packet to write advisory ``SIM_HARDWARE_COMPARE.md/json`` reports.

Voice audition quick check:

- Run ``tools/open_voice_audition.cmd`` from the extracted package to open the local MP3 audition page.
- Run ``tools/open_voice_audition.cmd -All`` only after supplying an authorized local RVC model and generating local audition output.
- Published prereleases upload ``stackchan_spark_audition_bright_robot_greeting.mp3`` and ``stackchan_spark_thinking.mp3`` as standalone release assets for one-click review.
- Optional RVC is bring-your-own-model and local-only. Release packages contain only ``media/voice/rvc/README.md``; model weights, indexes, converted audio, and RVC audition pages are forbidden.
- Run ``tools/verify_tracked_rvc_assets.cmd`` to verify the BYOM policy and absence of bundled RVC payloads.
- These are prototype voice-direction samples; consumer rollout still requires licensed or owned production voice-source provenance.

Hardware validation is still required before consumer rollout:

1. Display-only flash and 10-minute idle run.
2. Speech-mouth demo evidence: ``logs/speech_mouth_demo_serial.log`` with streamed speech envelope commands, ``speech clear``, and completion, plus ``logs/speak_all_intents_serial.log`` proving every packaged speech intent, earcon, and audio-output handoff.
3. Supervised servo-enable test.
4. Yaw classification and calibration.
5. 30-minute mixed idle/listen/speak soak.
6. Power-cycle recovery: USB power-cycle observation marked pass.
7. Target-speaker audio evidence: completed ``AUDIO_REVIEW.md`` plus a real-device speaker recording under ``audio/``.
8. Licensed or owned production voice source.

See ``docs/DEVICE_BRINGUP.md`` and ``docs/PRODUCTION_READINESS.md``.
"@ | Set-Content -Path (Join-Path $outDir "RELEASE_NOTES.md") -Encoding UTF8

$packageRootPrefix = $outDir.TrimEnd("\", "/") + [System.IO.Path]::DirectorySeparatorChar
function Get-PackageRelativePath {
  param([string]$Path)

  $absolutePath = [System.IO.Path]::GetFullPath($Path)
  if (-not $absolutePath.StartsWith($packageRootPrefix, [System.StringComparison]::OrdinalIgnoreCase)) {
    return ""
  }
  return $absolutePath.Substring($packageRootPrefix.Length).Replace("\", "/")
}

$releaseAssetEntries = Get-ReleaseFinalAssetEntries -Version $Version -PackageRoot $outDir -ZipPath $zipPath -ZipSidecarPath $zipSidecarPath
$allowedAuditEntries = Get-ReleaseAllowedAuditAssetEntries -AuditRoot "output/release-audit/$Version"
$releaseAssets = @($releaseAssetEntries | ForEach-Object {
  $relativePath = Get-PackageRelativePath -Path $_.Path
  [ordered]@{
    name = $_.Name
    phase = $_.Phase
    packagePath = $relativePath
    external = [string]::IsNullOrWhiteSpace($relativePath)
  }
})
$allowedAuditAssets = @($allowedAuditEntries | ForEach-Object {
  [ordered]@{
    name = $_.Name
    phase = $_.Phase
  }
})
$releaseAssetManifest = [ordered]@{
  schema = "stackchan.release-assets.v1"
  version = $Version
  commit = $commit
  generatedUtc = (Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")
  contract = "tools/release_asset_contract.ps1"
  releaseAssets = $releaseAssets
  allowedAuditAssets = $allowedAuditAssets
  counts = [ordered]@{
    releaseAssets = @($releaseAssets).Count
    allowedAuditAssets = @($allowedAuditAssets).Count
  }
}
$releaseAssetManifest | ConvertTo-Json -Depth 6 | Set-Content -Path (Join-Path $outDir "release_assets.json") -Encoding UTF8

function Assert-NoRestrictedVoicePayload {
  param([Parameter(Mandatory = $true)][string]$RootPath)

  $rootPrefix = [System.IO.Path]::GetFullPath($RootPath).TrimEnd('\') + '\'
  $violations = @(
    Get-ChildItem -LiteralPath $RootPath -File -Recurse | Where-Object {
      $relative = $_.FullName.Substring($rootPrefix.Length).Replace('\', '/')
      $extension = $_.Extension.ToLowerInvariant()
      $allowedVisionModel = $relative -match '(?i)^(provenance/)?bridge/models/face_detection_yunet_2023mar\.onnx$'
      ($extension -in @('.pth', '.index')) -or
      ($extension -eq '.onnx' -and -not $allowedVisionModel) -or
      ($_.Name -match '(?i)weightsgg|weights\.gg') -or
      ($relative -match '(?i)(^|/)media/voice/rvc/(?!README\.md$)') -or
      ($_.Name -match '(?i)rvc.*\.(wav|mp3|html)$')
    } | ForEach-Object {
      $_.FullName.Substring($rootPrefix.Length).Replace('\', '/')
    }
  )
  if ($violations.Count -gt 0) {
    throw "Release package contains restricted RVC/model payloads: $($violations -join ', ')"
  }
}

Assert-NoRestrictedVoicePayload -RootPath $outDir

$hashLines = Get-ChildItem -LiteralPath $outDir -File -Recurse |
  Where-Object { $_.Name -ne "SHA256SUMS.txt" } |
  Sort-Object FullName |
  ForEach-Object {
    $relative = $_.FullName.Substring($outDir.Length + 1).Replace("\", "/")
    $hash = Get-FileHash -Algorithm SHA256 -LiteralPath $_.FullName
    "$($hash.Hash.ToLowerInvariant())  $relative"
  }

$hashLines | Set-Content -Path (Join-Path $outDir "SHA256SUMS.txt") -Encoding ASCII

if (Test-Path -LiteralPath $zipPath) {
  Remove-Item -LiteralPath $zipPath -Force
}
& tar.exe -a -cf $zipPath -C $outDir .
if ($LASTEXITCODE -ne 0) {
  throw "Release ZIP creation failed with exit code $LASTEXITCODE"
}
$zipEntries = @(& tar.exe -tf $zipPath)
if ($LASTEXITCODE -ne 0) {
  throw "Release ZIP inspection failed with exit code $LASTEXITCODE"
}
$restrictedZipEntries = @($zipEntries | Where-Object {
  $allowedVisionModel = $_ -match '(?i)(^|/)(provenance/)?bridge/models/face_detection_yunet_2023mar\.onnx$'
  $_ -match '(?i)(^|/)[^/]+\.(pth|index)$' -or
  ($_ -match '(?i)(^|/)[^/]+\.onnx$' -and -not $allowedVisionModel) -or
  $_ -match '(?i)weightsgg|weights\.gg' -or
  $_ -match '(?i)(^|/)media/voice/rvc/(?!README\.md$).+' -or
  $_ -match '(?i)(^|/)[^/]*rvc[^/]*\.(wav|mp3|html)$'
})
if ($restrictedZipEntries.Count -gt 0) {
  throw "Release ZIP contains restricted RVC/model payloads: $($restrictedZipEntries -join ', ')"
}
$zipHash = (Get-FileHash -Algorithm SHA256 -LiteralPath $zipPath).Hash.ToLowerInvariant()
"$zipHash  $(Split-Path -Leaf $zipPath)" | Set-Content -Path $zipSidecarPath -Encoding ASCII

$packageVerifyLog = Join-Path $releaseOutputRoot "$Version-package-verify.log"
$packageVerifyArgs = @(
  "-NoProfile",
  "-ExecutionPolicy", "Bypass",
  "-File", (Join-Path $PSScriptRoot "verify_release_package.ps1"),
  "-Version", $Version,
  "-ZipPath", $zipPath,
  "-ExpectedCommit", $commit
)
if ($AllowDirty) {
  $packageVerifyArgs += "-AllowDirtyPackage"
}
$packageVerifyOutput = @(& $windowsPowerShell @packageVerifyArgs 2>&1)
$packageVerifyExit = $LASTEXITCODE
$packageVerifyOutput | ForEach-Object { [string]$_ } |
  Set-Content -LiteralPath $packageVerifyLog -Encoding UTF8
if ($packageVerifyExit -ne 0) {
  throw "Release ZIP verification failed with exit code $packageVerifyExit. See $packageVerifyLog"
}

Write-Host "Release package:"
Write-Host $outDir
Write-Host $zipPath
Write-Host $zipSidecarPath
Write-Host $packageVerifyLog
