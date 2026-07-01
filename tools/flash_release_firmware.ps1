param(
  [ValidateSet("display_only", "servo_calibration")]
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
  [switch]$DryRun
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
  if (-not [string]::IsNullOrWhiteSpace($env:PLATFORMIO_CORE_DIR)) {
    return $env:PLATFORMIO_CORE_DIR
  }

  if (-not (Get-Command "platformio" -ErrorAction SilentlyContinue)) {
    return ""
  }

  try {
    $info = & platformio system info 2>$null
    if ($LASTEXITCODE -eq 0) {
      foreach ($line in $info) {
        if ($line -match "PlatformIO Core Directory\s+(.+)$") {
          return $Matches[1].Trim()
        }
      }
    }
  } catch {
    return ""
  }

  return ""
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

if ($Firmware -eq "servo_calibration") {
  Write-Warning "Servo calibration firmware enables motor output. Keep the body clear and powered safely."
  if (-not $ConfirmServoRisk) {
    throw "Refusing to flash servo calibration package firmware without -ConfirmServoRisk. Run display-only firmware first, clear the body, and supervise the test."
  }
}

$cleanupDir = $null
try {
  if (-not [string]::IsNullOrWhiteSpace($PackageZip)) {
    Assert-File $PackageZip
    if ([string]::IsNullOrWhiteSpace($Version)) {
      $zipName = [System.IO.Path]::GetFileName($PackageZip)
      if ($zipName -match "^stackchan_alive_(.+)\.zip$") {
        $Version = $Matches[1]
      } else {
        throw "Pass -Version when -PackageZip does not match stackchan_alive_<version>.zip"
      }
    }

    $tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) "stackchan-release-flash"
    $cleanupDir = Join-Path $tempRoot ([System.Guid]::NewGuid().ToString("N"))
    New-Item -ItemType Directory -Force -Path $cleanupDir | Out-Null
    Expand-Archive -LiteralPath $PackageZip -DestinationPath $cleanupDir
    $PackageRoot = $cleanupDir
  }

  if ([string]::IsNullOrWhiteSpace($PackageRoot)) {
    $candidateManifest = Join-Path $root "release_manifest.json"
    if (Test-Path -LiteralPath $candidateManifest) {
      $PackageRoot = $root
    } else {
      if ([string]::IsNullOrWhiteSpace($Version)) {
        $Version = (git describe --tags --always --dirty).Trim()
      }
      $PackageRoot = Join-Path $root "output/release/$Version"
    }
  }

  Assert-File $PackageRoot
  $manifestPath = Join-Path $PackageRoot "release_manifest.json"
  Assert-File $manifestPath
  $manifest = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json

  if ([string]::IsNullOrWhiteSpace($Version)) {
    $Version = [string]$manifest.version
  }

  if ([string]::IsNullOrWhiteSpace($ExpectedCommit)) {
    $ExpectedCommit = [string]$manifest.commit
  }

  $verifyScript = Join-Path $PSScriptRoot "verify_release_package.ps1"
  if ($AllowDirtyPackage) {
    & $verifyScript -Version $Version -PackageRoot $PackageRoot -ExpectedCommit $ExpectedCommit -AllowDirtyPackage
  } else {
    & $verifyScript -Version $Version -PackageRoot $PackageRoot -ExpectedCommit $ExpectedCommit
  }

  $firmwareDir = Join-Path $PackageRoot "firmware/$Firmware"
  $bootloader = Join-Path $firmwareDir "bootloader.bin"
  $partitions = Join-Path $firmwareDir "partitions.bin"
  $firmwareBin = Join-Path $firmwareDir "firmware.bin"
  Assert-File $bootloader
  Assert-File $partitions
  Assert-File $firmwareBin

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
    "16MB",
    "0x0",
    $bootloader,
    "0x8000",
    $partitions,
    "0x10000",
    $firmwareBin
  )

  if ($DryRun) {
    Write-Host "Dry run: $(Format-Command @($esptool.Python)) $(Format-Command $esptoolArgs)"
  } else {
    & $esptool.Python @esptoolArgs
    if ($LASTEXITCODE -ne 0) {
      throw "esptool flashing failed with exit code $LASTEXITCODE"
    }
  }

  if ($Monitor) {
    $monitorArgs = @("device", "monitor", "--baud", "115200")
    if (-not [string]::IsNullOrWhiteSpace($Port)) {
      $monitorArgs += @("--port", $Port)
    }

    if ($DryRun) {
      Write-Host "Dry run: platformio $(Format-Command $monitorArgs)"
    } else {
      platformio @monitorArgs
      if ($LASTEXITCODE -ne 0) {
        throw "PlatformIO monitor failed with exit code $LASTEXITCODE"
      }
    }
  }
} finally {
  if ($cleanupDir -and (Test-Path -LiteralPath $cleanupDir)) {
    $resolvedCleanup = (Resolve-Path $cleanupDir).Path
    $resolvedTempRoot = (Resolve-Path $tempRoot).Path
    if (-not $resolvedCleanup.StartsWith($resolvedTempRoot, [System.StringComparison]::OrdinalIgnoreCase)) {
      throw "Refusing to clean unexpected flash extraction directory: $resolvedCleanup"
    }
    Remove-Item -LiteralPath $resolvedCleanup -Recurse -Force
  }
}
