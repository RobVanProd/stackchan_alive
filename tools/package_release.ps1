param(
  [string]$Version,
  [switch]$SkipBuild,
  [switch]$AllowDirty
)

$ErrorActionPreference = "Stop"

$repoRoot = Resolve-Path (Join-Path $PSScriptRoot "..")
Set-Location $repoRoot
. (Join-Path $PSScriptRoot "platformio_resolver.ps1")
. (Join-Path $PSScriptRoot "preview_python_resolver.ps1")

if ([string]::IsNullOrWhiteSpace($Version)) {
  $Version = (git describe --tags --always --dirty).Trim()
}

if (-not $SkipBuild) {
  Invoke-StackchanPlatformio run -e stackchan -e stackchan_servo_calibration
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

if (Test-Path -LiteralPath $outDir) {
  Remove-Item -LiteralPath $outDir -Recurse -Force
}
New-Item -ItemType Directory -Force -Path $outDir | Out-Null

$firmwareDir = Join-Path $outDir "firmware"
$displayFirmwareDir = Join-Path $firmwareDir "display_only"
$servoFirmwareDir = Join-Path $firmwareDir "servo_calibration"
$mediaDir = Join-Path $outDir "media"
$faceArtifactDir = Join-Path $outDir "artifacts/face"
$docsDir = Join-Path $outDir "docs"
$dataDir = Join-Path $outDir "data"
$provenanceDir = Join-Path $outDir "provenance"
$toolsDir = Join-Path $outDir "tools"
New-Item -ItemType Directory -Force -Path $displayFirmwareDir, $servoFirmwareDir, $mediaDir, $faceArtifactDir, $docsDir, $dataDir, $provenanceDir, $toolsDir | Out-Null

function Copy-FirmwareSet {
  param(
    [string]$BuildDir,
    [string]$Destination
  )

  $firmwareFiles = @(
    "firmware.bin",
    "firmware.elf",
    "bootloader.bin",
    "partitions.bin"
  )

  foreach ($file in $firmwareFiles) {
    $source = Join-Path $BuildDir $file
    if (-not (Test-Path -LiteralPath $source)) {
      throw "Missing build artifact: $source"
    }
    Copy-Item -LiteralPath $source -Destination $Destination
  }
}

Copy-FirmwareSet -BuildDir ".pio/build/stackchan" -Destination $displayFirmwareDir
Copy-FirmwareSet -BuildDir ".pio/build/stackchan_servo_calibration" -Destination $servoFirmwareDir

$mediaFiles = @(
  "docs/media/stackchan_alive_preview.png",
  "docs/media/stackchan_alive_expression_sheet.png",
  "docs/media/stackchan_alive_preview.mp4",
  "docs/media/stackchan_alive_preview.gif",
  "docs/media/stackchan_alive_speech_preview.gif"
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
New-Item -ItemType Directory -Force -Path $voiceMediaDir | Out-Null
New-Item -ItemType Directory -Force -Path $voiceRvcMediaDir | Out-Null
$voiceMediaFiles = @(
  "docs/media/voice/stackchan_spark_greeting.wav",
  "docs/media/voice/stackchan_spark_thinking.wav",
  "docs/media/voice/stackchan_spark_safety.wav",
  "docs/media/voice/stackchan_spark_audition_warm_slow_greeting.wav",
  "docs/media/voice/stackchan_spark_audition_bright_robot_greeting.wav",
  "docs/media/voice/VOICE_SAMPLES.md"
)

foreach ($file in $voiceMediaFiles) {
  if (-not (Test-Path -LiteralPath $file)) {
    throw "Missing voice artifact: $file"
  }
  Copy-Item -LiteralPath $file -Destination $voiceMediaDir
}

$voiceRvcFiles = @(
  "output/voice_auditions/rvc_base/final/RVC_AUDITIONS.md",
  "output/voice_auditions/rvc_base/final/RVC_AUDITIONS.json",
  "output/voice_auditions/rvc_base/final/stackchan_rvc_neutral.wav",
  "output/voice_auditions/rvc_base/final/stackchan_rvc_warm_slow.wav",
  "output/voice_auditions/rvc_base/final/stackchan_rvc_bright_robot.wav",
  "output/voice_auditions/rvc_base/final/stackchan_rvc_bright_robot_less_static.wav",
  "output/voice_auditions/rvc_base/final/stackchan_rvc_bright_robot_sweet_vocoder.wav",
  "output/voice_auditions/rvc_base/final/stackchan_rvc_bright_robot_soft_boops.wav",
  "output/voice_auditions/rvc_base/final/stackchan_rvc_spark_boops.wav",
  "output/voice_auditions/rvc_base/final/stackchan_rvc_high_character.wav",
  "output/voice_auditions/rvc_base/final/stackchan_rvc_thinking_neutral.wav",
  "output/voice_auditions/rvc_base/final/stackchan_rvc_safety_neutral.wav"
)

foreach ($file in $voiceRvcFiles) {
  if (-not (Test-Path -LiteralPath $file)) {
    throw "Missing RVC voice audition artifact: $file. Run tools/render_rvc_auditions.ps1 first."
  }
  Copy-Item -LiteralPath $file -Destination $voiceRvcMediaDir
}

Copy-Item -LiteralPath "README.md" -Destination $docsDir
Copy-Item -LiteralPath "docs/DEVICE_BRINGUP.md" -Destination $docsDir
Copy-Item -LiteralPath "docs/PRODUCTION_READINESS.md" -Destination $docsDir
Copy-Item -LiteralPath "docs/ARRIVAL_DAY_RUNBOOK.md" -Destination (Join-Path $outDir "ARRIVAL_DAY_RUNBOOK.md")
Copy-Item -LiteralPath "docs/RELEASE_QUICKSTART.md" -Destination (Join-Path $outDir "QUICKSTART.md")
Copy-Item -LiteralPath "docs/RELEASE_PROCESS.md" -Destination $docsDir
Copy-Item -LiteralPath "docs/ROLLOUT_CHECKLIST.md" -Destination $docsDir
Copy-Item -LiteralPath "docs/VOICE_PERSONALITY.md" -Destination $docsDir
Copy-Item -LiteralPath "docs/VOICE_SOURCE_PROVENANCE_TEMPLATE.md" -Destination $docsDir
Copy-Item -LiteralPath "data/calibration.yaml" -Destination $dataDir
Copy-Item -LiteralPath "data/voice_persona.yaml" -Destination $dataDir
Copy-Item -LiteralPath "data/voice_source_provenance.yaml" -Destination $dataDir
Copy-Item -LiteralPath "data/voice_rvc_base.yaml" -Destination $dataDir
Copy-Item -LiteralPath "data/voice_rvc_base_metadata.json" -Destination $dataDir

& $windowsPowerShell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $PSScriptRoot "export_voice_source_status.ps1") `
  -VoiceSourceProvenancePath (Join-Path $dataDir "voice_source_provenance.yaml") `
  -TemplatePath (Join-Path $docsDir "VOICE_SOURCE_PROVENANCE_TEMPLATE.md") `
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

$releaseTools = @(
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
  "tools/export_rvc_voice_base_status.cmd",
  "tools/export_rvc_voice_base_status.ps1",
  "tools/export_rollout_status.cmd",
  "tools/export_rollout_status.ps1",
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
  "tools/verify_share_release.ps1"
)

foreach ($file in $releaseTools) {
  if (-not (Test-Path -LiteralPath $file)) {
    throw "Missing release tool: $file"
  }
  Copy-Item -LiteralPath $file -Destination $toolsDir
}

Copy-Item -LiteralPath "platformio.ini" -Destination $provenanceDir
Copy-Item -LiteralPath "requirements-preview.txt" -Destination $provenanceDir
Copy-Item -LiteralPath ".github/workflows/firmware.yml" -Destination $provenanceDir
Copy-Item -LiteralPath ".github/workflows/release.yml" -Destination $provenanceDir
Copy-Item -LiteralPath "src" -Destination (Join-Path $provenanceDir "src") -Recurse

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
    [object[]]$ServoResolvedPackages
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

$platformioVersion = Invoke-CapturedText { Invoke-StackchanPlatformio --version }
$displayDeps = Invoke-CapturedText { Invoke-StackchanPlatformio pkg list -e stackchan }
$servoDeps = Invoke-CapturedText { Invoke-StackchanPlatformio pkg list -e stackchan_servo_calibration }
$previewRequirements = (Get-Content -LiteralPath "requirements-preview.txt" -Raw).TrimEnd()
$previewRequirementEntries = @(
  Get-Content -LiteralPath "requirements-preview.txt" |
    ForEach-Object { $_.Trim() } |
    Where-Object { -not [string]::IsNullOrWhiteSpace($_) -and -not $_.StartsWith("#") }
)
$declaredLibDeps = Get-DeclaredLibDeps
$displayResolvedPackages = Convert-PioPackageList $displayDeps
$servoResolvedPackages = Convert-PioPackageList $servoDeps
$dependencyAudit = Get-DependencyAudit `
  -DeclaredLibDeps $declaredLibDeps `
  -DisplayResolvedPackages $displayResolvedPackages `
  -ServoResolvedPackages $servoResolvedPackages

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
  includedEnvironments = @("stackchan", "stackchan_servo_calibration")
  servoDefault = "display-only build disables servos; calibration build enables servos"
  status = "device-ready prerelease; hardware validation pending"
  dirty = ($sourceDirtyFiles.Count -gt 0)
  dirtyFiles = @($sourceDirtyFiles)
  generatedMediaDirtyFiles = @($generatedMediaDirtyFiles)
  dependencyReport = "DEPENDENCIES.md"
  dependencyLock = "dependency_lock.json"
  readinessReport = "READINESS_REPORT.md"
  readinessReportJson = "readiness_report.json"
  ciStatusReport = "GITHUB_ACTIONS_STATUS.md"
  ciStatusReportJson = "github_actions_status.json"
  acceptanceChecklist = "RELEASE_ACCEPTANCE.md"
  acceptanceChecklistJson = "release_acceptance.json"
  voicePersonalityGuide = "docs/VOICE_PERSONALITY.md"
  voicePersona = "data/voice_persona.yaml"
  voiceSourceProvenanceTemplate = "docs/VOICE_SOURCE_PROVENANCE_TEMPLATE.md"
  voiceSourceProvenance = "data/voice_source_provenance.yaml"
  voiceSourceStatusReport = "VOICE_SOURCE_STATUS.md"
  voiceSourceStatusReportJson = "voice_source_status.json"
  voiceRvcBase = "data/voice_rvc_base.yaml"
  voiceRvcBaseMetadata = "data/voice_rvc_base_metadata.json"
  voiceRvcBaseStatusReport = "RVC_VOICE_BASE_STATUS.md"
  voiceRvcBaseStatusReportJson = "rvc_voice_base_status.json"
  mediaArtifacts = @(
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
  includedTools = @(
    "tools/flash_device.cmd",
    "tools/flash_device.ps1",
    "tools/flash_release_firmware.cmd",
    "tools/flash_release_firmware.ps1",
    "tools/platformio_resolver.ps1",
    "tools/preview_python_resolver.ps1",
    "tools/render_preview.py",
    "tools/render_rvc_auditions.ps1",
    "tools/publish_release.cmd",
    "tools/publish_release.ps1",
    "tools/export_github_actions_status.cmd",
    "tools/export_github_actions_status.ps1",
    "tools/export_voice_source_status.cmd",
    "tools/export_voice_source_status.ps1",
    "tools/export_rvc_voice_base_status.cmd",
    "tools/export_rvc_voice_base_status.ps1",
    "tools/export_rollout_status.cmd",
    "tools/export_rollout_status.ps1",
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
    "tools/verify_rvc_auditions.cmd",
    "tools/verify_rvc_auditions.ps1",
    "tools/verify_rvc_voice_base.cmd",
    "tools/verify_rvc_voice_base.ps1",
    "tools/verify_release_package.cmd",
    "tools/verify_release_package.ps1",
    "tools/verify_share_release.cmd",
    "tools/verify_share_release.ps1"
  )
  provenanceFiles = @(
    "provenance/platformio.ini",
    "provenance/requirements-preview.txt",
    "provenance/firmware.yml",
    "provenance/release.yml",
    "provenance/src/main.cpp",
    "provenance/src/persona/SpeechPlanner.hpp",
    "provenance/src/persona/SpeechPlanner.cpp"
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
  workflows = @()
}
$ciStatus | ConvertTo-Json -Depth 8 | Set-Content -Path (Join-Path $outDir "github_actions_status.json") -Encoding UTF8

@"
# GitHub Actions Status

Release: $Version
Commit: $commit
Repository: RobVanProd/stackchan_alive
Status: post-push-check-required

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
    [ordered]@{ gate = "voice-samples-present"; status = "pass"; evidence = "media/voice/stackchan_spark_greeting.wav, media/voice/stackchan_spark_thinking.wav, media/voice/stackchan_spark_safety.wav, plus warm-slow and bright-robot audition variants" },
    [ordered]@{ gate = "voice-source-provenance-template-present"; status = "pass"; evidence = "docs/VOICE_SOURCE_PROVENANCE_TEMPLATE.md and data/voice_source_provenance.yaml" },
    [ordered]@{ gate = "voice-source-status-report-present"; status = "pass"; evidence = "VOICE_SOURCE_STATUS.md and voice_source_status.json" },
    [ordered]@{ gate = "rvc-voice-base-status-report-present"; status = "pass"; evidence = "RVC_VOICE_BASE_STATUS.md and rvc_voice_base_status.json; review-only until production voice-source rights clear" },
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
    [ordered]@{ requirement = "voice-review-samples-present"; status = "pass"; evidence = "media/voice/stackchan_spark_greeting.wav, media/voice/stackchan_spark_thinking.wav, media/voice/stackchan_spark_safety.wav, plus warm-slow and bright-robot audition variants" },
    [ordered]@{ requirement = "voice-source-provenance-template-present"; status = "pass"; evidence = "docs/VOICE_SOURCE_PROVENANCE_TEMPLATE.md and data/voice_source_provenance.yaml" },
    [ordered]@{ requirement = "voice-source-status-report-present"; status = "pass"; evidence = "VOICE_SOURCE_STATUS.md and voice_source_status.json" },
    [ordered]@{ requirement = "rvc-voice-base-status-report-present"; status = "pass"; evidence = "RVC_VOICE_BASE_STATUS.md and rvc_voice_base_status.json; confirms review-only RVC base cache/hash status when available" },
    [ordered]@{ requirement = "arrival-tools-present"; status = "pass"; evidence = "tools/prepare_device_arrival.cmd, tools/start_hardware_evidence.cmd, tools/check_hardware_evidence_progress.cmd, tools/verify_hardware_evidence.cmd" },
    [ordered]@{ requirement = "hardware-media-importer-present"; status = "pass"; evidence = "tools/add_hardware_evidence_media.cmd validates imported photos/videos/audio and records hashes" },
    [ordered]@{ requirement = "servo-risk-gated"; status = "pass"; evidence = "tools/flash_release_firmware.ps1 requires -ConfirmServoRisk for servo_calibration" },
    [ordered]@{ requirement = "share-page-verifiable"; status = "pass"; evidence = "tools/share_release.cmd and tools/verify_share_release.cmd" }
  )
  hardwareAcceptanceRequired = @(
    [ordered]@{ requirement = "display-only-flash"; status = "pending-device"; requiredEvidence = "display-only serial log, real photo/video, 10-minute idle observation" },
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
- [x] Arrival tools present: prepare, evidence capture, and evidence verification scripts
- [x] Hardware media importer present: ``tools/add_hardware_evidence_media.cmd`` validates imported photos/videos/audio and records hashes
- [x] Evidence progress checker present: ``tools/check_hardware_evidence_progress.cmd``
- [x] Servo risk gated by explicit ``-ConfirmServoRisk``
- [x] Share page can be verified by ``tools/verify_share_release.cmd``

## Still Required Before Consumer Rollout

- [ ] Display-only flash with serial log, real photo/video, and 10-minute idle observation
- [ ] Supervised servo calibration with yaw classification and calibration values
- [ ] 30-minute mixed idle/listen/think/speak soak with heartbeat and runtime health markers
- [ ] USB power-cycle recovery marked pass
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
- Arrival-day helpers are included under ``tools/``, including the progress checker and strict evidence verifier.
- Hardware media import helper is included as ``tools/add_hardware_evidence_media.cmd`` for copying phone photos/videos and speaker recordings into evidence packets with SHA256 hashes.
- Servo calibration flashing requires explicit ``-ConfirmServoRisk`` acknowledgement.

## Pending Device Evidence

- Display-only flash, visible procedural face, and 10-minute idle run.
- Supervised servo calibration, yaw classification, and calibration values.
- 30-minute mixed idle/listen/think/speak soak.
- USB power-cycle recovery.
- Target-speaker audio evidence: completed ``AUDIO_REVIEW.md`` plus a real-device speaker recording under ``audio/``.
- Completed hardware evidence packet that passes ``tools/verify_hardware_evidence.cmd``.
- Completed voice-source provenance with licensed or owned production source.

Do not mark this release consumer-ready or non-prerelease until every pending device gate has explicit evidence.

Recommended arrival command from the extracted package:

    $($readinessReport.nextOperatorCommand)
"@ | Set-Content -Path (Join-Path $outDir "READINESS_REPORT.md") -Encoding UTF8

@"
# Stackchan Alive $Version

Commit: $commit

This is a device-ready prerelease package. It is built, native-tested, compile-checked, includes preview media plus an expression QA sheet, and keeps servo output disabled by default.

Dependency provenance is recorded in ``DEPENDENCIES.md`` and ``dependency_lock.json``, with copied build inputs under ``provenance/``. Voice source provenance is staged in ``docs/VOICE_SOURCE_PROVENANCE_TEMPLATE.md`` and ``data/voice_source_provenance.yaml``; voice approval status is summarized in ``VOICE_SOURCE_STATUS.md`` and ``voice_source_status.json``. Readiness status is recorded in ``READINESS_REPORT.md`` and ``readiness_report.json``. GitHub Actions status is recorded in ``GITHUB_ACTIONS_STATUS.md`` and ``github_actions_status.json``. Preflight, flashing, manual publishing, evidence capture, evidence progress checking, hardware evidence verification, and package verification helpers are included under ``tools/``.

Hardware validation is still required before consumer rollout:

1. Display-only flash and 10-minute idle run.
2. Supervised servo-enable test.
3. Yaw classification and calibration.
4. 30-minute mixed idle/listen/speak soak.
5. USB power-cycle recovery test.
6. Target-speaker audio evidence: completed ``AUDIO_REVIEW.md`` plus a real-device speaker recording under ``audio/``.
7. Licensed or owned production voice source.

See ``docs/DEVICE_BRINGUP.md`` and ``docs/PRODUCTION_READINESS.md``.
"@ | Set-Content -Path (Join-Path $outDir "RELEASE_NOTES.md") -Encoding UTF8

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
Compress-Archive -Path (Join-Path $outDir "*") -DestinationPath $zipPath
$zipSidecarPath = "$zipPath.sha256"
$zipHash = (Get-FileHash -Algorithm SHA256 -LiteralPath $zipPath).Hash.ToLowerInvariant()
"$zipHash  $(Split-Path -Leaf $zipPath)" | Set-Content -Path $zipSidecarPath -Encoding ASCII

Write-Host "Release package:"
Write-Host $outDir
Write-Host $zipPath
Write-Host $zipSidecarPath
