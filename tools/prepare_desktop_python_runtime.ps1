param(
  [string]$SourcePython = "",
  [string]$RuntimeRoot = "",
  [string]$SourceName = "local-python-runtime",
  [switch]$Force,
  [switch]$DryRun,
  [switch]$Json
)

$ErrorActionPreference = "Stop"
$materializedSymlinkCount = 0

$repoRoot = Resolve-Path (Join-Path $PSScriptRoot "..")
$platform = if ([System.Runtime.InteropServices.RuntimeInformation]::IsOSPlatform([System.Runtime.InteropServices.OSPlatform]::Windows)) {
  "windows"
} elseif ([System.Runtime.InteropServices.RuntimeInformation]::IsOSPlatform([System.Runtime.InteropServices.OSPlatform]::OSX)) {
  "macos"
} else {
  "linux"
}

if ([string]::IsNullOrWhiteSpace($RuntimeRoot)) {
  $RuntimeRoot = Join-Path $repoRoot "output/desktop-python-runtime/$platform"
}

function Resolve-CommandPath {
  param([string]$Command)

  if ([string]::IsNullOrWhiteSpace($Command)) {
    return ""
  }
  if (Test-Path -LiteralPath $Command -PathType Leaf) {
    return (Resolve-Path -LiteralPath $Command).Path
  }

  $resolved = Get-Command $Command -ErrorAction SilentlyContinue
  if ($null -ne $resolved -and -not [string]::IsNullOrWhiteSpace($resolved.Source)) {
    return $resolved.Source
  }
  return ""
}

function Get-PythonCandidates {
  $candidates = @()
  if (-not [string]::IsNullOrWhiteSpace($SourcePython)) { $candidates += $SourcePython }
  if (-not [string]::IsNullOrWhiteSpace($env:STACKCHAN_BRAIN_PYTHON)) { $candidates += $env:STACKCHAN_BRAIN_PYTHON }
  $candidates += @("python3", "python")

  if ($platform -eq "windows") {
    $localPrograms = Join-Path $env:LOCALAPPDATA "Programs/Python"
    if (Test-Path -LiteralPath $localPrograms -PathType Container) {
      $candidates += Get-ChildItem -LiteralPath $localPrograms -Directory -Filter "Python*" -ErrorAction SilentlyContinue |
        Sort-Object Name -Descending |
        ForEach-Object { Join-Path $_.FullName "python.exe" }
    }
  }

  $seen = @{}
  foreach ($candidate in $candidates) {
    $path = Resolve-CommandPath $candidate
    if ([string]::IsNullOrWhiteSpace($path)) { continue }
    $key = $path.ToLowerInvariant()
    if ($seen.ContainsKey($key)) { continue }
    $seen[$key] = $true
    $path
  }
}

function Test-PythonVersion {
  param([string]$PythonPath)

  try {
    $output = & $PythonPath --version 2>&1 | Out-String
    $exit = $LASTEXITCODE
  } catch {
    return [ordered]@{ ok = $false; version = ""; detail = $_.Exception.Message }
  }

  $version = $output.Trim()
  $match = [regex]::Match($version, "Python\s+(\d+)\.(\d+)(?:\.(\d+))?")
  if ($exit -ne 0 -or -not $match.Success) {
    return [ordered]@{ ok = $false; version = $version; detail = "Python executable did not report a parseable version." }
  }

  $major = [int]$match.Groups[1].Value
  $minor = [int]$match.Groups[2].Value
  $ok = $major -gt 3 -or ($major -eq 3 -and $minor -ge 10)
  return [ordered]@{
    ok = $ok
    version = $version
    detail = if ($ok) { "Python version satisfies 3.10+." } else { "Python 3.10+ is required." }
  }
}

function Get-PythonInstallRoot {
  param([string]$PythonPath)

  $parent = Split-Path -Parent $PythonPath
  $leaf = Split-Path -Leaf $parent
  if ($leaf -in @("bin", "Scripts")) {
    return (Resolve-Path (Join-Path $parent "..")).Path
  }
  return (Resolve-Path $parent).Path
}

function Assert-SafeRuntimeRoot {
  param(
    [string]$Target,
    [string]$SourceRoot
  )

  $targetFull = [System.IO.Path]::GetFullPath($Target)
  $sourceFull = [System.IO.Path]::GetFullPath($SourceRoot)
  $repoFull = [System.IO.Path]::GetFullPath($repoRoot)
  $homeFull = [System.IO.Path]::GetFullPath([Environment]::GetFolderPath("UserProfile"))
  $driveRoot = [System.IO.Path]::GetPathRoot($targetFull)

  if ($targetFull.TrimEnd("\", "/") -eq $sourceFull.TrimEnd("\", "/")) {
    throw "RuntimeRoot must not be the same folder as the source Python runtime."
  }
  if ($targetFull.TrimEnd("\", "/") -eq $repoFull.TrimEnd("\", "/")) {
    throw "RuntimeRoot must not be the repository root."
  }
  if ($targetFull.TrimEnd("\", "/") -eq $homeFull.TrimEnd("\", "/")) {
    throw "RuntimeRoot must not be the user home directory."
  }
  if ($targetFull.TrimEnd("\", "/") -eq $driveRoot.TrimEnd("\", "/")) {
    throw "RuntimeRoot must not be a drive root."
  }
}

function Copy-RuntimeDirectory {
  param(
    [string]$SourceRoot,
    [string]$TargetRoot
  )

  if (Test-Path -LiteralPath $TargetRoot) {
    $existing = @(Get-ChildItem -LiteralPath $TargetRoot -Force -ErrorAction SilentlyContinue)
    if ($existing.Count -gt 0 -and -not $Force) {
      throw "RuntimeRoot already exists and is not empty. Pass -Force to replace it: $TargetRoot"
    }
    if ($existing.Count -gt 0) {
      Remove-Item -LiteralPath $TargetRoot -Recurse -Force
    }
  }
  New-Item -ItemType Directory -Force -Path $TargetRoot | Out-Null

  $excludedDirectoryNames = @{
    "__pycache__" = $true
    ".git" = $true
    ".mypy_cache" = $true
    ".pytest_cache" = $true
  }

  function Copy-Directory {
    param(
      [string]$CurrentSource,
      [string]$CurrentTarget
    )

    New-Item -ItemType Directory -Force -Path $CurrentTarget | Out-Null
    Get-ChildItem -LiteralPath $CurrentSource -File -Force | ForEach-Object {
      if ($_.Name -eq ".gitignore") { return }
      $destination = Join-Path $CurrentTarget $_.Name
      $isUnixFileLink = $platform -ne "windows" -and -not [string]::IsNullOrWhiteSpace([string]$_.LinkType)
      if ($isUnixFileLink) {
        [System.IO.File]::Copy($_.FullName, $destination, $true)
        $sourceMode = [System.IO.File]::GetUnixFileMode($_.FullName)
        [System.IO.File]::SetUnixFileMode($destination, $sourceMode)
        $script:materializedSymlinkCount++
      } else {
        Copy-Item -LiteralPath $_.FullName -Destination $destination
      }
    }
    Get-ChildItem -LiteralPath $CurrentSource -Directory -Force | ForEach-Object {
      if ($excludedDirectoryNames.ContainsKey($_.Name)) { return }
      Copy-Directory -CurrentSource $_.FullName -CurrentTarget (Join-Path $CurrentTarget $_.Name)
    }
  }

  Copy-Directory -CurrentSource $SourceRoot -CurrentTarget $TargetRoot
}

function Get-RuntimePayloadHash {
  param([string]$Root)

  $rootFull = [System.IO.Path]::GetFullPath($Root).TrimEnd("\", "/")
  $prefix = $rootFull + [System.IO.Path]::DirectorySeparatorChar
  $sha = [System.Security.Cryptography.SHA256]::Create()
  $utf8 = [System.Text.Encoding]::UTF8

  $files = Get-ChildItem -LiteralPath $Root -File -Recurse -Force |
    Where-Object {
      $_.Name -ne "stackchan-python-runtime.json" -and
      $_.FullName -notmatch "([\\/])__pycache__([\\/])"
    } |
    Sort-Object FullName

  foreach ($file in $files) {
    $full = [System.IO.Path]::GetFullPath($file.FullName)
    if (-not $full.StartsWith($prefix, [System.StringComparison]::OrdinalIgnoreCase)) {
      throw "Refusing to hash file outside runtime root: $full"
    }
    $relative = $full.Substring($prefix.Length).Replace("\", "/")
    $pathBytes = $utf8.GetBytes("$relative`n")
    $null = $sha.TransformBlock($pathBytes, 0, $pathBytes.Length, $pathBytes, 0)
    $fileHash = (Get-FileHash -LiteralPath $full -Algorithm SHA256).Hash.ToLowerInvariant()
    $hashBytes = $utf8.GetBytes("$fileHash`n")
    $null = $sha.TransformBlock($hashBytes, 0, $hashBytes.Length, $hashBytes, 0)
  }

  $empty = [byte[]]@()
  $null = $sha.TransformFinalBlock($empty, 0, 0)
  return (($sha.Hash | ForEach-Object { $_.ToString("x2") }) -join "")
}

$selectedPython = ""
$versionCheck = $null
foreach ($candidate in Get-PythonCandidates) {
  $check = Test-PythonVersion $candidate
  if ($check.ok) {
    $selectedPython = $candidate
    $versionCheck = $check
    break
  }
}

if ([string]::IsNullOrWhiteSpace($selectedPython)) {
  throw "No usable Python 3.10+ runtime found. Pass -SourcePython or set STACKCHAN_BRAIN_PYTHON."
}

$sourceRoot = Get-PythonInstallRoot $selectedPython
Assert-SafeRuntimeRoot -Target $RuntimeRoot -SourceRoot $sourceRoot

$result = [ordered]@{
  schema = "stackchan.desktop-python-runtime-prepare.v1"
  status = if ($DryRun) { "dry-run-ready" } else { "ready" }
  platform = $platform
  sourcePython = $selectedPython
  sourceRoot = $sourceRoot
  runtimeRoot = [System.IO.Path]::GetFullPath($RuntimeRoot)
  pythonVersion = $versionCheck.version
  source = $SourceName
  dryRun = [bool]$DryRun
  materializedSymlinkCount = $materializedSymlinkCount
}

if (-not $DryRun) {
  Copy-RuntimeDirectory -SourceRoot $sourceRoot -TargetRoot $RuntimeRoot
  $result.materializedSymlinkCount = $materializedSymlinkCount
  $payloadHash = Get-RuntimePayloadHash $RuntimeRoot
  $manifest = [ordered]@{
    schema = "stackchan.desktop-python-runtime.v1"
    pythonVersion = $versionCheck.version
    platform = $platform
    source = $SourceName
    sha256 = $payloadHash
    license = "Python Software Foundation License Version 2 or approved equivalent"
    builtAt = (Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")
    preparedBy = "tools/prepare_desktop_python_runtime.ps1"
    sourcePython = $selectedPython
  }
  $manifest | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath (Join-Path $RuntimeRoot "stackchan-python-runtime.json") -Encoding UTF8

  $checker = Join-Path $PSScriptRoot "check_desktop_python_runtime_payload.ps1"
  $checkJson = & $checker -RuntimeRoot $RuntimeRoot -Json
  $result.payloadSha256 = $payloadHash
  $result.validation = $checkJson | ConvertFrom-Json
}

if ($Json) {
  $result | ConvertTo-Json -Depth 8
} else {
  Write-Host "Desktop Python runtime prepare: $($result.status)"
  Write-Host "Source Python: $selectedPython"
  Write-Host "Runtime root: $RuntimeRoot"
  Write-Host "Version: $($versionCheck.version)"
  if ($DryRun) {
    Write-Host "Dry run only; no files copied."
  } else {
    Write-Host "Payload SHA-256: $($result.payloadSha256)"
  }
}
