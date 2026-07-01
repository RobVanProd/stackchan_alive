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
  Assert-Command python
}

Invoke-Step "Check source tree and dependency pins" {
  Assert-CleanSourceTree
  Assert-DependencyPins
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
    & (Join-Path $PSScriptRoot "verify_release_package.ps1") -Version $Version -ZipPath $PackageZip -ExpectedCommit $ExpectedCommit
  }
}

Write-Host ""
Write-Host "Device preflight passed for commit $ExpectedCommit"
