param(
  [string]$RuntimeRoot = "",
  [switch]$Json,
  [switch]$WriteTemplate
)

$ErrorActionPreference = "Stop"

$script:IsWindowsPlatform = [System.Runtime.InteropServices.RuntimeInformation]::IsOSPlatform(
  [System.Runtime.InteropServices.OSPlatform]::Windows
)
$script:IsMacOSPlatform = [System.Runtime.InteropServices.RuntimeInformation]::IsOSPlatform(
  [System.Runtime.InteropServices.OSPlatform]::OSX
)

function Add-Check {
  param(
    [string]$Id,
    [ValidateSet("pass", "fail", "pending")]
    [string]$Status,
    [string]$Detail
  )

  $script:checks += [ordered]@{
    id = $Id
    status = $Status
    detail = $Detail
  }
}

function Find-PythonExecutable {
  param([string]$Root)

  $candidates = if ($script:IsWindowsPlatform) {
    @(
      (Join-Path $Root "python.exe"),
      (Join-Path $Root "python\python.exe"),
      (Join-Path $Root "bin\python3"),
      (Join-Path $Root "bin\python"),
      (Join-Path $Root "python3"),
      (Join-Path $Root "python")
    )
  } else {
    @(
      (Join-Path $Root "bin/python3"),
      (Join-Path $Root "bin/python"),
      (Join-Path $Root "python3"),
      (Join-Path $Root "python"),
      (Join-Path $Root "python.exe"),
      (Join-Path $Root "python/python.exe")
    )
  }

  foreach ($candidate in $candidates) {
    if (Test-Path -LiteralPath $candidate -PathType Leaf) {
      return (Resolve-Path $candidate).Path
    }
  }

  return ""
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
  $match = [regex]::Match($version, "Python\s+(\d+)\.(\d+)")
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

$checks = @()

if ([string]::IsNullOrWhiteSpace($RuntimeRoot)) {
  $RuntimeRoot = $env:STACKCHAN_BRAIN_PYTHON_RUNTIME
}

if ([string]::IsNullOrWhiteSpace($RuntimeRoot)) {
  Add-Check "runtime-root" "pending" "Pass -RuntimeRoot or set STACKCHAN_BRAIN_PYTHON_RUNTIME."
  $rootPath = ""
} else {
  $rootPath = $RuntimeRoot
}

if ($WriteTemplate) {
  if ([string]::IsNullOrWhiteSpace($rootPath)) {
    throw "-WriteTemplate requires -RuntimeRoot or STACKCHAN_BRAIN_PYTHON_RUNTIME."
  }
  New-Item -ItemType Directory -Force -Path $rootPath | Out-Null
  $template = [ordered]@{
    schema = "stackchan.desktop-python-runtime.v1"
    pythonVersion = "3.12.x"
    platform = if ($script:IsWindowsPlatform) { "windows" } elseif ($script:IsMacOSPlatform) { "macos" } else { "linux" }
    source = "<managed-runtime-build-name-or-url>"
    sha256 = "<runtime-archive-or-folder-hash>"
    license = "Python Software Foundation License Version 2 or approved equivalent"
    builtAt = (Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")
  }
  $template | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath (Join-Path $rootPath "stackchan-python-runtime.json") -Encoding UTF8
}

if (-not [string]::IsNullOrWhiteSpace($rootPath)) {
  if (Test-Path -LiteralPath $rootPath -PathType Container) {
    Add-Check "runtime-root" "pass" "Runtime root exists: $rootPath"
  } else {
    Add-Check "runtime-root" "fail" "Runtime root does not exist: $rootPath"
  }

  $manifestPath = Join-Path $rootPath "stackchan-python-runtime.json"
  if (Test-Path -LiteralPath $manifestPath -PathType Leaf) {
    try {
      $manifest = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json
      if ($manifest.schema -eq "stackchan.desktop-python-runtime.v1") {
        Add-Check "manifest-schema" "pass" "Manifest schema is stackchan.desktop-python-runtime.v1."
      } else {
        Add-Check "manifest-schema" "fail" "Unexpected manifest schema: $($manifest.schema)"
      }
      foreach ($field in @("pythonVersion", "platform", "source", "sha256", "license", "builtAt")) {
        if ($null -ne $manifest.$field -and -not [string]::IsNullOrWhiteSpace([string]$manifest.$field)) {
          Add-Check "manifest-$field" "pass" "Manifest field $field is present."
        } else {
          Add-Check "manifest-$field" "fail" "Manifest field $field is required."
        }
      }
    } catch {
      Add-Check "manifest-schema" "fail" "Manifest is not valid JSON: $($_.Exception.Message)"
    }
  } else {
    Add-Check "manifest-schema" "fail" "Missing stackchan-python-runtime.json."
  }

  $pythonPath = Find-PythonExecutable $rootPath
  if ([string]::IsNullOrWhiteSpace($pythonPath)) {
    Add-Check "python-executable" "fail" "No platform Python executable found."
  } else {
    Add-Check "python-executable" "pass" "Python executable found: $pythonPath"
    $versionCheck = Test-PythonVersion $pythonPath
    Add-Check "python-version" ($(if ($versionCheck.ok) { "pass" } else { "fail" })) "$($versionCheck.version) $($versionCheck.detail)"
  }
}

$failed = @($checks | Where-Object { $_.status -eq "fail" })
$pending = @($checks | Where-Object { $_.status -eq "pending" })
$status = if ($failed.Count -gt 0) { "not-ready" } elseif ($pending.Count -gt 0) { "pending-runtime-root" } else { "ready" }

$result = [ordered]@{
  schema = "stackchan.desktop-python-runtime-payload.v1"
  status = $status
  runtimeRoot = $rootPath
  checks = $checks
}

if ($Json) {
  $result | ConvertTo-Json -Depth 5
} else {
  Write-Host "Desktop Python runtime payload: $status"
  foreach ($check in $checks) {
    Write-Host "[$($check.status)] $($check.id): $($check.detail)"
  }
}

if ($failed.Count -gt 0) {
  exit 1
}
