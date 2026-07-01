param(
  [string]$PackageZip = "",
  [string]$Version = "",
  [string]$ExpectedCommit = "",
  [switch]$AllowDirty
)

$ErrorActionPreference = "Stop"

$repoRoot = Resolve-Path (Join-Path $PSScriptRoot "..")
Set-Location $repoRoot

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
    $dirtyFiles | Where-Object { $_ -match "^\s*M docs/media/stackchan_alive_preview\.(gif|mp4|png)$" }
  )
  $sourceDirtyFiles = @(
    $dirtyFiles | Where-Object { $_ -notmatch "^\s*M docs/media/stackchan_alive_preview\.(gif|mp4|png)$" }
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
  Assert-Command platformio
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

Invoke-Step "Run native logic tests" {
  platformio test -e native_logic
}

Invoke-Step "Compile embedded test firmware" {
  platformio test -e stackchan --without-uploading --without-testing
}

Invoke-Step "Build display-only and servo-calibration firmware" {
  platformio run -e stackchan -e stackchan_servo_calibration
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
