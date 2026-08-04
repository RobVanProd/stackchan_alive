param(
  [ValidateSet("display_only", "servo_calibration", "full_online")]
  [string]$Firmware = "display_only",
  [string]$Version = "",
  [string]$PackageRoot = "",
  [string]$PackageZip = "",
  [string]$ExpectedCommit = "",
  [string]$Port = "",
  [int]$Baud = 921600,
  [switch]$Monitor,
  [switch]$ConfirmServoRisk,
  [switch]$AllowDirtyPackage,
  [switch]$DryRun,
  [string]$ToolchainAllowlistPath = "",
  [string]$GitExecutable = "",
  [string]$PythonExecutable = "",
  [string]$PlatformioExecutable = "",
  [string]$LegacyCoreDir = "",
  [string]$ReleaseCoreDir = ""
)

$ErrorActionPreference = "Stop"

$root = Resolve-Path (Join-Path $PSScriptRoot "..")
Set-Location $root

function Assert-File {
  param([string]$Path)
  if (-not (Test-Path -LiteralPath $Path)) {
    throw "Missing file: $Path"
  }
}

function Format-Command {
  param([string[]]$Parts)
  return ($Parts | ForEach-Object {
    if ($_ -match "\s") {
      '"' + ($_ -replace '"', '\"') + '"'
    } else {
      $_
    }
  }) -join " "
}

function Get-PythonCandidates {
  $candidates = @()
  $candidates += @(Get-Command "python" -All -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Source)

  if (-not [string]::IsNullOrWhiteSpace($env:LOCALAPPDATA)) {
    $pythonRoots = Join-Path $env:LOCALAPPDATA "Programs/Python"
    if (Test-Path -LiteralPath $pythonRoots) {
      $candidates += @(
        Get-ChildItem -LiteralPath $pythonRoots -Directory -Filter "Python*" -ErrorAction SilentlyContinue |
          Sort-Object Name -Descending |
          ForEach-Object { Join-Path $_.FullName "python.exe" }
      )
    }
  }

  if (-not [string]::IsNullOrWhiteSpace($env:USERPROFILE)) {
    $candidates += Join-Path $env:USERPROFILE ".platformio/penv/Scripts/python.exe"
    $candidates += Join-Path $env:USERPROFILE ".cache/codex-runtimes/codex-primary-runtime/dependencies/python/python.exe"
  }

  return @($candidates | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Select-Object -Unique)
}

function Get-PlatformioCoreDir {
  return Get-StackchanPlatformioCoreDir
}

function Get-EsptoolScripts {
  $scripts = @()
  $coreDir = Get-PlatformioCoreDir
  if (-not [string]::IsNullOrWhiteSpace($coreDir)) {
    $scripts += Join-Path $coreDir "packages/tool-esptoolpy/esptool.py"
  }
  if (-not [string]::IsNullOrWhiteSpace($env:USERPROFILE)) {
    $scripts += Join-Path $env:USERPROFILE ".platformio/packages/tool-esptoolpy/esptool.py"
  }
  return @($scripts | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Select-Object -Unique)
}

function Get-EsptoolInvocation {
  foreach ($pythonPath in Get-PythonCandidates) {
    if (-not (Test-Path -LiteralPath $pythonPath) -or $pythonPath -match "\\WindowsApps\\python\.exe$") {
      continue
    }

    foreach ($scriptPath in Get-EsptoolScripts) {
      if (-not (Test-Path -LiteralPath $scriptPath)) {
        continue
      }

      try {
        $probe = & $pythonPath $scriptPath version 2>$null
        if ($LASTEXITCODE -eq 0 -and (($probe | Out-String) -match "esptool")) {
          return [pscustomobject]@{
            Python = (Resolve-Path $pythonPath).Path
            BaseArgs = @((Resolve-Path $scriptPath).Path)
          }
        }
      } catch {
        continue
      }
    }

    try {
      $probe = & $pythonPath -m esptool version 2>$null
      if ($LASTEXITCODE -eq 0 -and (($probe | Out-String) -match "esptool")) {
        return [pscustomobject]@{
          Python = (Resolve-Path $pythonPath).Path
          BaseArgs = @("-m", "esptool")
        }
      }
    } catch {
      continue
    }
  }

  throw "No usable esptool runtime found. Install PlatformIO and run a firmware build once so tool-esptoolpy is installed, or install esptool into a real Python 3 environment."
}

if (-not [string]::IsNullOrWhiteSpace($PackageZip) -and
    -not [string]::IsNullOrWhiteSpace($PackageRoot)) {
  throw "Pass only one of -PackageZip or -PackageRoot."
}
if (-not [string]::IsNullOrWhiteSpace($PackageRoot)) {
  throw "Operational flashing requires -PackageZip so one private verified snapshot is the sole flash source."
}
if ([string]::IsNullOrWhiteSpace($PackageZip)) {
  throw "Operational flashing requires an explicit -PackageZip."
}

if (-not [string]::IsNullOrWhiteSpace($PackageZip) -and
    [string]::IsNullOrWhiteSpace($Version)) {
  $zipName = [System.IO.Path]::GetFileName($PackageZip)
  if ($zipName -notmatch "^stackchan_alive_(.+)\.zip$") {
    throw "Pass -Version when -PackageZip does not match stackchan_alive_<version>.zip"
  }
  $Version = $Matches[1]
}

if ([string]::IsNullOrWhiteSpace($Version)) {
  $Version = (& git -c core.hooksPath=NUL -c core.fsmonitor=false `
    -c maintenance.auto=false -c core.untrackedCache=false `
    describe --tags --always 2>$null | Out-String).Trim()
  if ([string]::IsNullOrWhiteSpace($Version)) {
    throw "Pass -Version because it could not be resolved from trusted Git state."
  }
}

if ([string]::IsNullOrWhiteSpace($ExpectedCommit)) {
  $ExpectedCommit = (& git -c core.hooksPath=NUL -c core.fsmonitor=false `
    -c maintenance.auto=false -c core.untrackedCache=false `
    rev-parse HEAD 2>$null | Out-String).Trim()
  if ([string]::IsNullOrWhiteSpace($ExpectedCommit)) {
    throw "Pass -ExpectedCommit because it could not be resolved from trusted Git state."
  }
}

$verifyScript = Join-Path $PSScriptRoot "verify_release_package.ps1"
$verifyArgs = @(
  "-NoProfile", "-ExecutionPolicy", "Bypass", "-File", $verifyScript,
  "-Version", $Version, "-ExpectedCommit", $ExpectedCommit,
  "-RequireReleaseEligible",
  "-ToolchainAllowlistPath", $ToolchainAllowlistPath,
  "-GitExecutable", $GitExecutable,
  "-PythonExecutable", $PythonExecutable,
  "-PlatformioExecutable", $PlatformioExecutable,
  "-LegacyCoreDir", $LegacyCoreDir,
  "-ReleaseCoreDir", $ReleaseCoreDir
)
Assert-File $PackageZip
$PackageZip = (Resolve-Path -LiteralPath $PackageZip).Path
$verifyArgs += @("-ZipPath", $PackageZip)
if ($AllowDirtyPackage) {
  $verifyArgs += "-AllowDirtyPackage"
}
& powershell.exe @verifyArgs
if ($LASTEXITCODE -ne 0) {
  throw "Operational release package verification failed before flash preparation."
}

. (Join-Path $PSScriptRoot "platformio_resolver.ps1")
. (Join-Path $PSScriptRoot "release_zip_safety.ps1")
. (Join-Path $PSScriptRoot "release_ota_selector_policy.ps1")

function Copy-ReleaseZipSnapshot {
  param(
    [Parameter(Mandatory = $true)][string]$SourcePath,
    [Parameter(Mandatory = $true)][string]$DestinationPath
  )

  $sourceStream = [System.IO.FileStream]::new(
    $SourcePath, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read,
    [System.IO.FileShare]::Read, 1MB, [System.IO.FileOptions]::SequentialScan)
  $destinationStream = $null
  $transitionStream = $null
  $lockedReadStream = $null
  try {
    $destinationStream = [System.IO.FileStream]::new(
      $DestinationPath, [System.IO.FileMode]::CreateNew, [System.IO.FileAccess]::ReadWrite,
      [System.IO.FileShare]::Read, 1MB, [System.IO.FileOptions]::SequentialScan)
    $sourceStream.CopyTo($destinationStream)
    $destinationStream.Flush($true)
    $transitionStream = [System.IO.FileStream]::new(
      $DestinationPath, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read,
      [System.IO.FileShare]::ReadWrite, 4096, [System.IO.FileOptions]::SequentialScan)
    $destinationStream.Dispose()
    $destinationStream = $null
    $lockedReadStream = [System.IO.FileStream]::new(
      $DestinationPath, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read,
      [System.IO.FileShare]::Read, 1MB, [System.IO.FileOptions]::SequentialScan)
    $transitionStream.Dispose()
    $transitionStream = $null
    return $lockedReadStream
  } catch {
    if ($null -ne $destinationStream) { $destinationStream.Dispose() }
    if ($null -ne $transitionStream) { $transitionStream.Dispose() }
    if ($null -ne $lockedReadStream) { $lockedReadStream.Dispose() }
    throw
  } finally {
    $sourceStream.Dispose()
  }
}

function Get-LockedReleasePayloadSha256 {
  param([Parameter(Mandatory = $true)][System.IO.FileStream]$Stream)

  $Stream.Position = 0
  $hasher = [System.Security.Cryptography.SHA256]::Create()
  try {
    return ([System.BitConverter]::ToString($hasher.ComputeHash($Stream)) -replace '-', '').ToUpperInvariant()
  } finally {
    $hasher.Dispose()
    $Stream.Position = 0
  }
}

function Get-LockedReleaseZipChecksumRecords {
  param([Parameter(Mandatory = $true)][System.IO.FileStream]$SnapshotStream)

  Add-Type -AssemblyName System.IO.Compression -ErrorAction Stop
  $SnapshotStream.Position = 0
  $archive = [System.IO.Compression.ZipArchive]::new(
    $SnapshotStream, [System.IO.Compression.ZipArchiveMode]::Read, $true)
  try {
    $checksumEntries = @($archive.Entries | Where-Object {
      [string]$_.FullName -ceq 'SHA256SUMS.txt'
    })
    if ($checksumEntries.Count -ne 1 -or
        [long]$checksumEntries[0].Length -lt 68 -or
        [long]$checksumEntries[0].Length -gt 10MB) {
      throw 'Locked release ZIP does not contain one bounded canonical SHA256SUMS.txt entry.'
    }
    $entryStream = $checksumEntries[0].Open()
    $reader = [System.IO.StreamReader]::new(
      $entryStream, [System.Text.Encoding]::ASCII, $false, 4096, $false)
    try {
      $checksumText = $reader.ReadToEnd()
    } finally {
      $reader.Dispose()
    }
  } finally {
    $archive.Dispose()
    $SnapshotStream.Position = 0
  }

  $records = @{}
  foreach ($line in @($checksumText -split '\r?\n')) {
    if ([string]::IsNullOrWhiteSpace($line)) { continue }
    if ($line -notmatch '^([a-f0-9]{64})  (.+)$') {
      throw "Invalid locked-snapshot checksum record: $line"
    }
    if ($records.ContainsKey($Matches[2])) {
      throw "Duplicate locked-snapshot checksum record: $($Matches[2])"
    }
    $records[$Matches[2]] = $Matches[1].ToUpperInvariant()
  }
  if ($records.Count -eq 0) {
    throw 'Locked release ZIP checksum authority is empty.'
  }
  return $records
}

function Get-ReleaseFlashWriteArguments {
  param(
    [Parameter(Mandatory = $true)][string]$Bootloader,
    [Parameter(Mandatory = $true)][string]$Partitions,
    [Parameter(Mandatory = $true)][string]$OtaSelector,
    [Parameter(Mandatory = $true)][string]$FirmwareBin
  )

  return @(
    '0x0', $Bootloader,
    '0x8000', $Partitions,
    '0xe000', $OtaSelector,
    '0x10000', $FirmwareBin
  )
}

if ($Firmware -in @("servo_calibration", "full_online")) {
  Write-Warning "$Firmware firmware contains motor support. Keep the body clear and powered safely."
  if (-not $ConfirmServoRisk) {
    throw "Refusing to flash $Firmware package firmware without -ConfirmServoRisk. Run display-only firmware first, clear the body, and supervise the test."
  }
}

$tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) "stackchan-release-flash"
$cleanupDir = $null
$snapshotLock = $null
try {
  $cleanupDir = Join-Path $tempRoot ([System.Guid]::NewGuid().ToString("N"))
  New-Item -ItemType Directory -Force -Path $cleanupDir | Out-Null
  $snapshotZip = Join-Path $cleanupDir 'verified-input.zip'
  $snapshotLock = Copy-ReleaseZipSnapshot `
    -SourcePath $PackageZip -DestinationPath $snapshotZip
  $snapshotSha256 = (Get-LockedReleasePayloadSha256 -Stream $snapshotLock).ToLowerInvariant()
  [System.IO.File]::WriteAllText(
    "$snapshotZip.sha256", "$snapshotSha256  verified-input.zip`n",
    [System.Text.Encoding]::ASCII)

  $snapshotVerifyArgs = @(
    "-NoProfile", "-ExecutionPolicy", "Bypass", "-File", $verifyScript,
    "-Version", $Version, "-ExpectedCommit", $ExpectedCommit,
    "-RequireReleaseEligible", "-ZipPath", $snapshotZip,
    "-ToolchainAllowlistPath", $ToolchainAllowlistPath,
    "-GitExecutable", $GitExecutable,
    "-PythonExecutable", $PythonExecutable,
    "-PlatformioExecutable", $PlatformioExecutable,
    "-LegacyCoreDir", $LegacyCoreDir,
    "-ReleaseCoreDir", $ReleaseCoreDir
  )
  if ($AllowDirtyPackage) {
    $snapshotVerifyArgs += "-AllowDirtyPackage"
  }
  & powershell.exe @snapshotVerifyArgs
  if ($LASTEXITCODE -ne 0) {
    throw "Private release ZIP snapshot failed eligibility verification."
  }
  $checksumRecords = Get-LockedReleaseZipChecksumRecords -SnapshotStream $snapshotLock

  $PackageRoot = Join-Path $cleanupDir 'package'
  Expand-StackchanReleaseZipSafely `
    -ZipPath $snapshotZip -DestinationPath $PackageRoot

  Assert-File $PackageRoot
  $manifestPath = Join-Path $PackageRoot "release_manifest.json"
  Assert-File $manifestPath
  $manifest = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json

  if ([string]$manifest.version -ne $Version -or
      ([string]$manifest.commit).ToLowerInvariant() -ne $ExpectedCommit.ToLowerInvariant()) {
    throw "Verified package identity changed before flash preparation."
  }

  $firmwareDir = Join-Path $PackageRoot "firmware/$Firmware"
  $bootloader = Join-Path $firmwareDir "bootloader.bin"
  $partitions = Join-Path $firmwareDir "partitions.bin"
  $otaSelector = Join-Path $firmwareDir "boot_app0.bin"
  $firmwareBin = Join-Path $firmwareDir "firmware.bin"
  Assert-File $bootloader
  Assert-File $partitions
  Assert-File $otaSelector
  Assert-File $firmwareBin
  $flashPayloads = @(
    [ordered]@{ relative = "firmware/$Firmware/bootloader.bin"; path = $bootloader },
    [ordered]@{ relative = "firmware/$Firmware/partitions.bin"; path = $partitions },
    [ordered]@{ relative = "firmware/$Firmware/boot_app0.bin"; path = $otaSelector },
    [ordered]@{ relative = "firmware/$Firmware/firmware.bin"; path = $firmwareBin }
  )
  $payloadLocks = New-Object System.Collections.Generic.List[System.IO.FileStream]
  $payloadLocksByRelative = @{}
  try {
    foreach ($payload in $flashPayloads) {
      $payloadLock = [System.IO.FileStream]::new(
        [string]$payload.path, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read,
        [System.IO.FileShare]::Read, 4096, [System.IO.FileOptions]::SequentialScan)
      $payloadLocks.Add($payloadLock)
      $payloadLocksByRelative[[string]$payload.relative] = $payloadLock
    }
    if ($payloadLocksByRelative["firmware/$Firmware/boot_app0.bin"].Length -ne 8192) {
      throw "Packaged OTA selector must be exactly 8192 bytes."
    }
    $selectorEnvironment = switch ($Firmware) {
      'display_only' { 'stackchan' }
      'servo_calibration' { 'stackchan_servo_calibration' }
      'full_online' { 'stackchan_release_full' }
    }
    Assert-StackchanReleaseOtaSelectorBytes `
      -Environment $selectorEnvironment -LiteralPath $otaSelector | Out-Null

    foreach ($payload in $flashPayloads) {
      if (-not $checksumRecords.ContainsKey([string]$payload.relative)) {
        throw "Package checksum is missing flash payload: $([string]$payload.relative)"
      }
      $actualPayloadHash = Get-LockedReleasePayloadSha256 `
        -Stream $payloadLocksByRelative[[string]$payload.relative]
      if ($actualPayloadHash -cne [string]$checksumRecords[[string]$payload.relative]) {
        throw "Flash payload changed after snapshot verification: $([string]$payload.relative)"
      }
    }

  $esptool = Get-EsptoolInvocation
  $esptoolArgs = @($esptool.BaseArgs) + @(
    "--chip",
    "esp32s3",
    "--baud",
    [string]$Baud,
    "--before",
    "default_reset",
    "--after",
    "hard_reset"
  )

  if (-not [string]::IsNullOrWhiteSpace($Port)) {
    $esptoolArgs += @("--port", $Port)
  }

  $esptoolArgs += @(
    "write_flash",
    "-z",
    "--flash_mode",
    "dio",
    "--flash_freq",
    "80m",
    "--flash_size",
    "16MB"
  )
  $esptoolArgs += Get-ReleaseFlashWriteArguments `
    -Bootloader $bootloader -Partitions $partitions `
    -OtaSelector $otaSelector -FirmwareBin $firmwareBin

    if ($DryRun) {
      Write-Host "Dry run: $(Format-Command @($esptool.Python)) $(Format-Command $esptoolArgs)"
    } else {
      & $esptool.Python @esptoolArgs
      if ($LASTEXITCODE -ne 0) {
        throw "esptool flashing failed with exit code $LASTEXITCODE"
      }
    }
  } finally {
    foreach ($payloadLock in $payloadLocks) { $payloadLock.Dispose() }
  }

  if ($Monitor) {
    $monitorArgs = @("device", "monitor", "--baud", "115200")
    if (-not [string]::IsNullOrWhiteSpace($Port)) {
      $monitorArgs += @("--port", $Port)
    }

    if ($DryRun) {
      Write-Host "Dry run: platformio $(Format-Command $monitorArgs)"
    } else {
      Invoke-StackchanPlatformio @monitorArgs
      if ($LASTEXITCODE -ne 0) {
        throw "PlatformIO monitor failed with exit code $LASTEXITCODE"
      }
    }
  }
} finally {
  if ($null -ne $snapshotLock) {
    $snapshotLock.Dispose()
    $snapshotLock = $null
  }
  if ($cleanupDir -and (Test-Path -LiteralPath $cleanupDir)) {
    $resolvedCleanup = (Resolve-Path $cleanupDir).Path
    $resolvedTempRoot = (Resolve-Path $tempRoot).Path
    if (-not $resolvedCleanup.StartsWith($resolvedTempRoot, [System.StringComparison]::OrdinalIgnoreCase)) {
      throw "Refusing to clean unexpected flash extraction directory: $resolvedCleanup"
    }
    Remove-Item -LiteralPath $resolvedCleanup -Recurse -Force
  }
}
