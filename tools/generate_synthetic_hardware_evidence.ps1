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
  "Release: $Version",
  "Commit: $ExpectedCommit"
) | Set-Content -Path (Join-Path $outDir "README.md") -Encoding UTF8

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
  "[servo] dry-run mode; set STACKCHAN_ENABLE_SERVOS=1 after calibration",
  "[heartbeat] stackchan_alive mode=display_only uptime_ms=10000",
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

$commandFiles = @{
  "RUN_DISPLAY_ONLY.cmd" = "echo Synthetic diagnostic packet. Do not flash hardware from this fixture."
  "RUN_SERVO_CALIBRATION.cmd" = "echo Synthetic diagnostic packet. Do not move servos from this fixture."
  "RUN_SOAK_MONITOR.cmd" = "echo Synthetic diagnostic packet. Do not use as a real soak log."
  "RUN_PACKAGE_VERIFY.cmd" = "powershell.exe -NoProfile -ExecutionPolicy Bypass -File `"%~dp0..\..\..\tools\verify_release_package.ps1`" -Version $Version"
  "RUN_PROGRESS_CHECK.cmd" = "powershell.exe -NoProfile -ExecutionPolicy Bypass -File `"%~dp0..\..\..\tools\check_hardware_evidence_progress.ps1`" -EvidenceRoot `"%~dp0.`""
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
  requiredLogs = $requiredLogs
  requiredRecords = @(
    "CHECKLIST.md",
    "RELEASE_ACCEPTANCE.md",
    "release_acceptance.json",
    "OBSERVATIONS.md",
    "AUDIO_REVIEW.md",
    "calibration/calibration.yaml",
    "RUN_DISPLAY_ONLY.cmd",
    "RUN_SERVO_CALIBRATION.cmd",
    "RUN_SOAK_MONITOR.cmd",
    "RUN_PACKAGE_VERIFY.cmd",
    "RUN_PROGRESS_CHECK.cmd",
    "RUN_EVIDENCE_VERIFY.cmd",
    "RUN_CONSUMER_PROMOTION_CHECK.cmd"
  )
  promotionVerifier = "tools/verify_consumer_promotion.ps1"
  hardwareEvidenceVerifier = "tools/verify_hardware_evidence.ps1"
}
$metadata | ConvertTo-Json -Depth 6 | Set-Content -Path (Join-Path $outDir "metadata.json") -Encoding UTF8

Write-Host "Synthetic hardware evidence packet:"
Write-Host $outDir

if ($Verify) {
  & powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $PSScriptRoot "verify_hardware_evidence.ps1") -EvidenceRoot $outDir -AllowSyntheticEvidence
  if ($LASTEXITCODE -ne 0) {
    throw "Synthetic hardware evidence packet failed verifier."
  }
}
