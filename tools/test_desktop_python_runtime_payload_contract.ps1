param()

$ErrorActionPreference = "Stop"

$desktopBuildText = Get-Content -LiteralPath (Join-Path $PSScriptRoot "../companion/app-desktop/build.gradle.kts") -Raw
if ($desktopBuildText -notmatch [regex]::Escape("process.waitFor(120, TimeUnit.SECONDS)")) {
  throw "Desktop packaging must allow the managed-runtime validation subprocess a bounded 120-second first-launch window."
}
foreach ($pattern in @("desktop-runtime-validator-output", "outputReader.join(5_000)", "output.append(reader.readText())")) {
  if ($desktopBuildText -notmatch [regex]::Escape($pattern)) {
    throw "Desktop packaging must drain managed-runtime checker output while the subprocess runs: missing $pattern"
  }
}
Write-Host "[ok] desktop packaging runtime validation uses the bounded first-launch window"

$repoRoot = Resolve-Path (Join-Path $PSScriptRoot "..")
$checkScript = Join-Path $PSScriptRoot "check_desktop_python_runtime_payload.ps1"
$createdRoots = New-Object System.Collections.Generic.List[string]

function Get-ExpectedPlatform {
  if ([System.Runtime.InteropServices.RuntimeInformation]::IsOSPlatform([System.Runtime.InteropServices.OSPlatform]::Windows)) {
    return "windows"
  }
  if ([System.Runtime.InteropServices.RuntimeInformation]::IsOSPlatform([System.Runtime.InteropServices.OSPlatform]::OSX)) {
    return "macos"
  }
  return "linux"
}

function Resolve-Python {
  $commands = @("python3", "python")
  if ((Get-ExpectedPlatform) -eq "windows") {
    $commands = @("python", "python3")
  }
  foreach ($command in $commands) {
    $resolved = Get-Command $command -ErrorAction SilentlyContinue
    if ($null -ne $resolved -and -not [string]::IsNullOrWhiteSpace($resolved.Source)) {
      $version = & $resolved.Source --version 2>&1 | Out-String
      if ($LASTEXITCODE -eq 0 -and $version -match "Python\s+3\.(1[0-9]|[2-9][0-9])") {
        return [ordered]@{ path = $resolved.Source; version = $version.Trim() }
      }
    }
  }
  throw "No Python 3.10+ command is available for the desktop runtime contract test."
}

function New-RuntimeRoot {
  $root = Join-Path ([System.IO.Path]::GetTempPath()) ("stackchan-desktop-runtime-contract-" + [guid]::NewGuid().ToString("N"))
  $createdRoots.Add($root) | Out-Null
  New-Item -ItemType Directory -Force -Path $root | Out-Null
  return $root
}

function Copy-PythonExecutable {
  param(
    [string]$RuntimeRoot,
    [string]$PythonPath
  )

  if ((Get-ExpectedPlatform) -eq "windows") {
    Copy-Item -LiteralPath $PythonPath -Destination (Join-Path $RuntimeRoot "python.exe")
  } else {
    $bin = Join-Path $RuntimeRoot "bin"
    New-Item -ItemType Directory -Force -Path $bin | Out-Null
    Copy-Item -LiteralPath $PythonPath -Destination (Join-Path $bin "python3")
    chmod +x (Join-Path $bin "python3")
  }
}

function Write-Manifest {
  param(
    [string]$RuntimeRoot,
    [string]$PythonVersion,
    [string]$Platform,
    [string]$Sha256,
    [string]$Source = "contract-test-runtime"
  )

  [ordered]@{
    schema = "stackchan.desktop-python-runtime.v1"
    pythonVersion = $PythonVersion
    platform = $Platform
    source = $Source
    sha256 = $Sha256
    license = "Python Software Foundation License Version 2 or approved equivalent"
    builtAt = "2026-07-06T00:00:00Z"
  } | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath (Join-Path $RuntimeRoot "stackchan-python-runtime.json") -Encoding UTF8
}

function Invoke-RuntimeCheck {
  param([string]$RuntimeRoot)

  $powerShellExe = (Get-Process -Id $PID).Path
  $oldErrorActionPreference = $ErrorActionPreference
  $ErrorActionPreference = "Continue"
  try {
    $output = & $powerShellExe -NoProfile -ExecutionPolicy Bypass -File $checkScript -RuntimeRoot $RuntimeRoot -Json 2>&1
    $exitCode = $LASTEXITCODE
  } finally {
    $ErrorActionPreference = $oldErrorActionPreference
  }
  $text = ($output | Out-String).Trim()
  $report = if ([string]::IsNullOrWhiteSpace($text)) { $null } else { $text | ConvertFrom-Json }
  return [pscustomobject]@{ exitCode = $exitCode; text = $text; report = $report }
}

function Assert-CheckStatus {
  param(
    [object]$Report,
    [string]$Id,
    [string]$Status
  )

  $check = @($Report.checks | Where-Object { $_.id -eq $Id })
  if ($check.Count -ne 1) {
    throw "Expected exactly one check with id '$Id'."
  }
  if ($check[0].status -ne $Status) {
    throw "Expected check '$Id' to be '$Status', got '$($check[0].status)'. Detail: $($check[0].detail)"
  }
}

function New-Case {
  param(
    [object]$Python,
    [string]$PythonVersion,
    [string]$Platform,
    [string]$Sha256,
    [string]$Source = "contract-test-runtime"
  )

  $root = New-RuntimeRoot
  Copy-PythonExecutable -RuntimeRoot $root -PythonPath $Python.path
  Write-Manifest -RuntimeRoot $root -PythonVersion $PythonVersion -Platform $Platform -Sha256 $Sha256 -Source $Source
  return $root
}

try {
  Set-Location $repoRoot
  $python = Resolve-Python
  $expectedPlatform = Get-ExpectedPlatform
  $otherPlatform = if ($expectedPlatform -eq "windows") { "linux" } else { "windows" }
  $validSha = "a" * 64

  $placeholderHashRoot = New-Case -Python $python -PythonVersion $python.version -Platform $expectedPlatform -Sha256 "<runtime-archive-or-folder-hash>"
  $placeholderHash = Invoke-RuntimeCheck -RuntimeRoot $placeholderHashRoot
  if ([int]$placeholderHash.exitCode -eq 0) {
    throw "Expected placeholder sha256 runtime payload to fail."
  }
  Assert-CheckStatus -Report $placeholderHash.report -Id "manifest-sha256-format" -Status "fail"
  Write-Host "[ok] placeholder sha256 is rejected"

  $placeholderSourceRoot = New-Case -Python $python -PythonVersion $python.version -Platform $expectedPlatform -Sha256 $validSha -Source "<managed-runtime-build-name-or-url>"
  $placeholderSource = Invoke-RuntimeCheck -RuntimeRoot $placeholderSourceRoot
  if ([int]$placeholderSource.exitCode -eq 0) {
    throw "Expected placeholder runtime source payload to fail."
  }
  Assert-CheckStatus -Report $placeholderSource.report -Id "manifest-source-value" -Status "fail"
  Write-Host "[ok] placeholder runtime source is rejected"

  $platformMismatchRoot = New-Case -Python $python -PythonVersion $python.version -Platform $otherPlatform -Sha256 $validSha
  $platformMismatch = Invoke-RuntimeCheck -RuntimeRoot $platformMismatchRoot
  if ([int]$platformMismatch.exitCode -eq 0) {
    throw "Expected platform mismatch runtime payload to fail."
  }
  Assert-CheckStatus -Report $platformMismatch.report -Id "manifest-platform-match" -Status "fail"
  Write-Host "[ok] platform mismatch is rejected"

  $versionMismatchRoot = New-Case -Python $python -PythonVersion "Python 3.99.0" -Platform $expectedPlatform -Sha256 $validSha
  $versionMismatch = Invoke-RuntimeCheck -RuntimeRoot $versionMismatchRoot
  if ([int]$versionMismatch.exitCode -eq 0) {
    throw "Expected pythonVersion mismatch runtime payload to fail."
  }
  Assert-CheckStatus -Report $versionMismatch.report -Id "manifest-python-version-match" -Status "fail"
  Write-Host "[ok] pythonVersion mismatch is rejected"

  $validRoot = New-Case -Python $python -PythonVersion $python.version -Platform $expectedPlatform -Sha256 $validSha
  $valid = Invoke-RuntimeCheck -RuntimeRoot $validRoot
  if ([int]$valid.exitCode -ne 0) {
    throw "Expected valid runtime payload to pass. Output:`n$($valid.text)"
  }
  if ($valid.report.status -ne "ready") {
    throw "Expected valid runtime payload status ready, got $($valid.report.status)."
  }
  if ($valid.report.platform -ne $expectedPlatform -or $valid.report.runtimeSha256 -ne $validSha -or [string]$valid.report.runtimeSource -ne "contract-test-runtime" -or [string]::IsNullOrWhiteSpace([string]$valid.report.pythonVersion) -or [string]::IsNullOrWhiteSpace([string]$valid.report.probedPythonVersion)) {
    throw "Expected valid runtime payload report to emit platform, pythonVersion, probedPythonVersion, runtimeSha256, and runtimeSource."
  }
  foreach ($id in @("manifest-platform-match", "manifest-sha256-format", "manifest-source-value", "manifest-python-version-match", "python-version")) {
    Assert-CheckStatus -Report $valid.report -Id $id -Status "pass"
  }
  Write-Host "[ok] valid desktop runtime payload is accepted"

  Write-Host "Desktop Python runtime payload contract tests passed."
} finally {
  foreach ($root in $createdRoots) {
    if ([string]::IsNullOrWhiteSpace($root)) {
      continue
    }
    $resolvedRoot = Resolve-Path -LiteralPath $root -ErrorAction SilentlyContinue
    if ($null -ne $resolvedRoot -and $resolvedRoot.Path.StartsWith([System.IO.Path]::GetTempPath(), [System.StringComparison]::OrdinalIgnoreCase)) {
      Remove-Item -LiteralPath $resolvedRoot.Path -Recurse -Force
    }
  }
}
exit 0
