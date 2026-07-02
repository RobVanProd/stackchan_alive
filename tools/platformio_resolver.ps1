function Format-StackchanCommand {
  param([string[]]$Parts)

  return ($Parts | ForEach-Object {
    if ($_ -match "\s") {
      '"' + ($_ -replace '"', '\"') + '"'
    } else {
      $_
    }
  }) -join " "
}

function Get-StackchanPlatformioCandidates {
  $candidates = @()

  if (-not [string]::IsNullOrWhiteSpace($env:PLATFORMIO_EXE)) {
    $candidates += $env:PLATFORMIO_EXE
  }

  foreach ($commandName in @("platformio", "pio")) {
    $candidates += @(
      Get-Command $commandName -All -ErrorAction SilentlyContinue |
        Select-Object -ExpandProperty Source
    )
  }

  if (-not [string]::IsNullOrWhiteSpace($env:LOCALAPPDATA)) {
    $pythonRoots = Join-Path $env:LOCALAPPDATA "Programs/Python"
    if (Test-Path -LiteralPath $pythonRoots) {
      $pythonDirs = @(
        Get-ChildItem -LiteralPath $pythonRoots -Directory -Filter "Python*" -ErrorAction SilentlyContinue |
          Sort-Object Name -Descending
      )
      foreach ($pythonDir in $pythonDirs) {
        $candidates += Join-Path $pythonDir.FullName "Scripts/platformio.exe"
        $candidates += Join-Path $pythonDir.FullName "Scripts/pio.exe"
      }
    }
  }

  if (-not [string]::IsNullOrWhiteSpace($env:USERPROFILE)) {
    $candidates += Join-Path $env:USERPROFILE ".platformio/penv/Scripts/platformio.exe"
    $candidates += Join-Path $env:USERPROFILE ".platformio/penv/Scripts/pio.exe"
  }

  return @(
    $candidates |
      Where-Object { -not [string]::IsNullOrWhiteSpace($_) } |
      Select-Object -Unique
  )
}

function Get-StackchanPlatformioCommand {
  if (-not [string]::IsNullOrWhiteSpace($script:StackchanPlatformioCommand)) {
    return $script:StackchanPlatformioCommand
  }

  foreach ($candidate in Get-StackchanPlatformioCandidates) {
    $commandPath = $candidate
    if (Test-Path -LiteralPath $candidate) {
      $commandPath = (Resolve-Path $candidate).Path
    }

    try {
      $version = & $commandPath --version 2>$null
      if ($LASTEXITCODE -eq 0 -and (($version | Out-String) -match "PlatformIO")) {
        $script:StackchanPlatformioCommand = $commandPath
        return $script:StackchanPlatformioCommand
      }
    } catch {
      continue
    }
  }

  $searched = (Get-StackchanPlatformioCandidates) -join [Environment]::NewLine
  throw "Required command is not available: PlatformIO. Install it with a real Python 3 environment, add platformio/pio to PATH, or set PLATFORMIO_EXE to platformio.exe. Searched:$([Environment]::NewLine)$searched"
}

function Invoke-StackchanPlatformio {
  $platformio = Get-StackchanPlatformioCommand
  & $platformio @args
}

function Get-StackchanPlatformioCoreDir {
  if (-not [string]::IsNullOrWhiteSpace($env:PLATFORMIO_CORE_DIR)) {
    return $env:PLATFORMIO_CORE_DIR
  }

  try {
    $platformio = Get-StackchanPlatformioCommand
    $info = & $platformio system info 2>$null
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

function Get-StackchanNativeCompilerDirs {
  $dirs = @()

  foreach ($commandName in @("gcc", "g++")) {
    $dirs += @(
      Get-Command $commandName -All -ErrorAction SilentlyContinue |
        Select-Object -ExpandProperty Source |
        ForEach-Object { Split-Path $_ -Parent }
    )
  }

  foreach ($candidateDir in @(
    "C:/msys64/mingw64/bin",
    "C:/msys64/ucrt64/bin",
    "C:/mingw64/bin",
    "C:/mingw/bin",
    "C:/ProgramData/chocolatey/lib/mingw/tools/install/mingw64/bin",
    "C:/ProgramData/chocolatey/bin"
  )) {
    $dirs += $candidateDir
  }

  if (-not [string]::IsNullOrWhiteSpace($env:USERPROFILE)) {
    $dirs += Join-Path $env:USERPROFILE "scoop/apps/mingw/current/bin"
    $dirs += Join-Path $env:USERPROFILE "scoop/apps/gcc/current/bin"
    $dirs += Join-Path $env:USERPROFILE "scoop/shims"
  }

  if (-not [string]::IsNullOrWhiteSpace($env:LOCALAPPDATA)) {
    $wingetPackages = Join-Path $env:LOCALAPPDATA "Microsoft/WinGet/Packages"
    if (Test-Path -LiteralPath $wingetPackages) {
      $dirs += @(
        Get-ChildItem -LiteralPath $wingetPackages -Directory -Filter "BrechtSanders.WinLibs*" -ErrorAction SilentlyContinue |
          Sort-Object LastWriteTime -Descending |
          ForEach-Object {
            @(
              Join-Path $_.FullName "mingw64/bin"
              Join-Path $_.FullName "ucrt64/bin"
            )
          }
      )
    }
  }

  return @(
    $dirs |
      Where-Object { -not [string]::IsNullOrWhiteSpace($_) } |
      Select-Object -Unique
  )
}

function Add-StackchanNativeCompilerToPath {
  foreach ($dir in Get-StackchanNativeCompilerDirs) {
    if (-not (Test-Path -LiteralPath $dir)) {
      continue
    }

    $gcc = Join-Path $dir "gcc.exe"
    $gxx = Join-Path $dir "g++.exe"
    if ((Test-Path -LiteralPath $gcc) -and (Test-Path -LiteralPath $gxx)) {
      $pathParts = @($env:PATH -split [regex]::Escape([System.IO.Path]::PathSeparator))
      if ($pathParts -notcontains $dir) {
        $env:PATH = $dir + [System.IO.Path]::PathSeparator + $env:PATH
      }
      return (Resolve-Path $dir).Path
    }
  }

  $searched = (Get-StackchanNativeCompilerDirs) -join [Environment]::NewLine
  throw "Required native compiler toolchain is not available: gcc/g++. Install MinGW/WinLibs or add gcc and g++ to PATH. Searched:$([Environment]::NewLine)$searched"
}
