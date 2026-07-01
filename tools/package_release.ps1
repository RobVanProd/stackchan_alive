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
  $dirtyFiles | Where-Object { $_ -match "^\s*M docs/media/stackchan_alive_preview\.(gif|mp4|png)$" }
)
$sourceDirtyFiles = @(
  $dirtyFiles | Where-Object { $_ -notmatch "^\s*M docs/media/stackchan_alive_preview\.(gif|mp4|png)$" }
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
$docsDir = Join-Path $outDir "docs"
$dataDir = Join-Path $outDir "data"
$provenanceDir = Join-Path $outDir "provenance"
$toolsDir = Join-Path $outDir "tools"
New-Item -ItemType Directory -Force -Path $displayFirmwareDir, $servoFirmwareDir, $mediaDir, $docsDir, $dataDir, $provenanceDir, $toolsDir | Out-Null

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
  "docs/media/stackchan_alive_preview.mp4",
  "docs/media/stackchan_alive_preview.gif"
)

foreach ($file in $mediaFiles) {
  if (-not (Test-Path -LiteralPath $file)) {
    throw "Missing preview artifact: $file"
  }
  Copy-Item -LiteralPath $file -Destination $mediaDir
}

Copy-Item -LiteralPath "README.md" -Destination $docsDir
Copy-Item -LiteralPath "docs/DEVICE_BRINGUP.md" -Destination $docsDir
Copy-Item -LiteralPath "docs/PRODUCTION_READINESS.md" -Destination $docsDir
Copy-Item -LiteralPath "docs/RELEASE_QUICKSTART.md" -Destination (Join-Path $outDir "QUICKSTART.md")
Copy-Item -LiteralPath "docs/RELEASE_PROCESS.md" -Destination $docsDir
Copy-Item -LiteralPath "docs/ROLLOUT_CHECKLIST.md" -Destination $docsDir
Copy-Item -LiteralPath "data/calibration.yaml" -Destination $dataDir

$releaseTools = @(
  "tools/flash_device.cmd",
  "tools/flash_device.ps1",
  "tools/flash_release_firmware.cmd",
  "tools/flash_release_firmware.ps1",
  "tools/platformio_resolver.ps1",
  "tools/preview_python_resolver.ps1",
  "tools/publish_release.cmd",
  "tools/publish_release.ps1",
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
  "tools/verify_published_release.cmd",
  "tools/verify_published_release.ps1",
  "tools/verify_architecture.cmd",
  "tools/verify_architecture.ps1",
  "tools/verify_preview_media.cmd",
  "tools/verify_preview_media.ps1",
  "tools/verify_release_package.cmd",
  "tools/verify_release_package.ps1"
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
  includedTools = @(
    "tools/flash_device.cmd",
    "tools/flash_device.ps1",
    "tools/flash_release_firmware.cmd",
    "tools/flash_release_firmware.ps1",
    "tools/platformio_resolver.ps1",
    "tools/preview_python_resolver.ps1",
    "tools/publish_release.cmd",
    "tools/publish_release.ps1",
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
    "tools/verify_published_release.cmd",
    "tools/verify_published_release.ps1",
    "tools/verify_architecture.cmd",
    "tools/verify_architecture.ps1",
    "tools/verify_preview_media.cmd",
    "tools/verify_preview_media.ps1",
    "tools/verify_release_package.cmd",
    "tools/verify_release_package.ps1"
  )
  provenanceFiles = @(
    "provenance/platformio.ini",
    "provenance/requirements-preview.txt",
    "provenance/firmware.yml",
    "provenance/release.yml",
    "provenance/src/main.cpp"
  )
}

$manifest | ConvertTo-Json -Depth 4 | Set-Content -Path (Join-Path $outDir "release_manifest.json") -Encoding UTF8

@"
# Stackchan Alive $Version

Commit: $commit

This is a device-ready prerelease package. It is built, native-tested, compile-checked, includes preview media, and keeps servo output disabled by default.

Dependency provenance is recorded in ``DEPENDENCIES.md`` and ``dependency_lock.json``, with copied build inputs under ``provenance/``. Preflight, flashing, manual publishing, evidence capture, hardware evidence verification, and package verification helpers are included under ``tools/``.

Hardware validation is still required before consumer rollout:

1. Display-only flash and 10-minute idle run.
2. Supervised servo-enable test.
3. Yaw classification and calibration.
4. 30-minute mixed idle/listen/speak soak.
5. USB power-cycle recovery test.

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

Write-Host "Release package:"
Write-Host $outDir
Write-Host $zipPath
