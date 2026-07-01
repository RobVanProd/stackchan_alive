param(
  [string]$PackageZip = "",
  [string]$Version = "",
  [string]$ExpectedCommit = "",
  [switch]$AllowDirty
)

$ErrorActionPreference = "Stop"

$repoRoot = Resolve-Path (Join-Path $PSScriptRoot "..")
Set-Location $repoRoot
. (Join-Path $PSScriptRoot "platformio_resolver.ps1")

function Invoke-Step {
  param(
    [string]$Name,
    [scriptblock]$Command
  )

  Write-Host ""
  Write-Host "==> $Name"
  & $Command
  if ($LASTEXITCODE -ne 0) {
    throw "Step failed: $Name"
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

  New-Item -ItemType Directory -Force -Path $logsDir, $photosDir, $audioDir, $calibrationDir | Out-Null

  try {
    "ready" | Set-Content -Path (Join-Path $evidenceRoot "README.md") -Encoding UTF8
    "- [x] synthetic gate" | Set-Content -Path (Join-Path $evidenceRoot "CHECKLIST.md") -Encoding UTF8
    "ready" | Set-Content -Path (Join-Path $evidenceRoot "DEVICE_BRINGUP.md") -Encoding UTF8
    "ready" | Set-Content -Path (Join-Path $evidenceRoot "PRODUCTION_READINESS.md") -Encoding UTF8
    $releaseTag = if ([string]::IsNullOrWhiteSpace($Version)) { "v0.0.0-selftest" } else { $Version }
    Write-SyntheticAcceptanceArtifacts -EvidenceRoot $evidenceRoot -ReleaseTag $releaseTag -Commit $ExpectedCommit

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
      "- Sample played: synthetic greeting",
      "- Voice variant: stackchan_spark_greeting",
      "- Speaker recording file: audio/speaker.wav",
      "- Intelligible through device speaker: yes",
      "- Clipping or distortion observed: no",
      "- Volume adequate at normal listening distance: yes",
      "- Delay or playback dropout observed: no",
      "- Selected voice direction: synthetic preflight fixture"
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
      "[servo] dry-run mode; set STACKCHAN_ENABLE_SERVOS=1 after calibration",
      "[heartbeat] stackchan_alive mode=display_only uptime_ms=10000",
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
      requiredLogs = @(
        "logs/display_only_serial.log",
        "logs/servo_calibration_serial.log",
        "logs/soak_serial.log"
      )
      requiredRecords = @(
        "CHECKLIST.md",
        "RELEASE_ACCEPTANCE.md",
        "release_acceptance.json",
        "OBSERVATIONS.md",
        "AUDIO_REVIEW.md",
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

  New-Item -ItemType Directory -Force -Path $logsDir, $photosDir, $audioDir, $calibrationDir | Out-Null

  try {
    "ready" | Set-Content -Path (Join-Path $evidenceRoot "README.md") -Encoding UTF8
    "- [x] synthetic gate" | Set-Content -Path (Join-Path $evidenceRoot "CHECKLIST.md") -Encoding UTF8
    "ready" | Set-Content -Path (Join-Path $evidenceRoot "DEVICE_BRINGUP.md") -Encoding UTF8
    "ready" | Set-Content -Path (Join-Path $evidenceRoot "PRODUCTION_READINESS.md") -Encoding UTF8
    $releaseTag = if ([string]::IsNullOrWhiteSpace($Version)) { "v0.0.0-selftest" } else { $Version }
    Write-SyntheticAcceptanceArtifacts -EvidenceRoot $evidenceRoot -ReleaseTag $releaseTag -Commit $ExpectedCommit

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
      "- Sample played: synthetic greeting",
      "- Voice variant: stackchan_spark_greeting",
      "- Speaker recording file: audio/speaker.wav",
      "- Intelligible through device speaker: yes",
      "- Clipping or distortion observed: no",
      "- Volume adequate at normal listening distance: yes",
      "- Delay or playback dropout observed: no",
      "- Selected voice direction: synthetic preflight fixture"
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
      "[servo] dry-run mode; set STACKCHAN_ENABLE_SERVOS=1 after calibration",
      "[heartbeat] stackchan_alive mode=display_only uptime_ms=10000",
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
      requiredLogs = @(
        "logs/display_only_serial.log",
        "logs/servo_calibration_serial.log",
        "logs/soak_serial.log"
      )
      requiredRecords = @(
        "CHECKLIST.md",
        "RELEASE_ACCEPTANCE.md",
        "release_acceptance.json",
        "OBSERVATIONS.md",
        "AUDIO_REVIEW.md",
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

  Invoke-Step "Check release binary flash helper" {
    Assert-ReleaseFlashHelperSafety $PackageZip -AllowDirtyPackage:$AllowDirty
  }
}

Write-Host ""
Write-Host "Device preflight passed for commit $ExpectedCommit"
