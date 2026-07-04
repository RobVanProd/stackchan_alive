param()

$ErrorActionPreference = "Stop"

$repoRoot = Resolve-Path (Join-Path $PSScriptRoot "..")
$captureScript = Join-Path $PSScriptRoot "capture_android_companion_logcat.ps1"
$createdRoots = New-Object System.Collections.Generic.List[string]

function New-TempRoot {
  param([string]$Prefix)

  $root = Join-Path ([System.IO.Path]::GetTempPath()) ($Prefix + "-" + [guid]::NewGuid().ToString("N"))
  $createdRoots.Add($root) | Out-Null
  New-Item -ItemType Directory -Force -Path $root | Out-Null
  return $root
}

function New-FakeAdb {
  param([string]$Root)

  $fakeAdbPath = Join-Path $Root "fake-adb.ps1"
  @'
$argv = @($args)
if ($argv.Count -ge 2 -and $argv[0] -eq "-s") {
  $argv = @($argv | Select-Object -Skip 2)
}

if ($argv.Count -eq 0) {
  exit 1
}

if ($argv[0] -eq "devices") {
  "List of devices attached"
  "FAKE123	device"
  exit 0
}

if ($argv[0] -eq "shell" -and $argv.Count -ge 3 -and $argv[1] -eq "getprop") {
  if ($argv[2] -eq "ro.product.model") {
    "Pixel Contract"
    exit 0
  }
  if ($argv[2] -eq "ro.build.version.release") {
    "16"
    exit 0
  }
  if ($argv[2] -eq "ro.build.version.sdk") {
    "36"
    exit 0
  }
}

if ($argv[0] -eq "shell" -and $argv.Count -ge 3 -and $argv[1] -eq "pidof") {
  "1234"
  exit 0
}

if ($argv[0] -eq "logcat") {
  "07-04 09:00:00.000  999  999 I unrelated: ignored line"
  "07-04 09:00:01.000 1234 1234 I dev.stackchan.companion: CompanionBridgeService started"
  "07-04 09:00:02.000 1234 1234 I ForegroundService: foreground service active"
  "07-04 09:00:03.000 2222 2222 E AndroidRuntime: FATAL EXCEPTION synthetic"
  exit 0
}

exit 1
'@ | Set-Content -Path $fakeAdbPath -Encoding UTF8

  return $fakeAdbPath
}

function Invoke-LogcatCapture {
  param(
    [string]$AdbPath,
    [string]$OutputDir
  )

  $powerShellExe = (Get-Process -Id $PID).Path
  $output = & $powerShellExe `
    -NoProfile `
    -ExecutionPolicy Bypass `
    -File $captureScript `
    -AdbPath $AdbPath `
    -OutputDir $OutputDir `
    -Lines 100 `
    -IncludeRaw 2>&1

  if ($LASTEXITCODE -ne 0) {
    throw "Logcat capture exited with $LASTEXITCODE.`n$($output | Out-String)"
  }
}

function Assert-FileContains {
  param(
    [string]$Path,
    [string]$Needle
  )

  if (-not (Test-Path -LiteralPath $Path)) {
    throw "Missing expected file: $Path"
  }
  $text = Get-Content -LiteralPath $Path -Raw
  if ($text -notlike "*$Needle*") {
    throw "Expected $Path to contain '$Needle'."
  }
}

try {
  Set-Location $repoRoot

  $root = New-TempRoot -Prefix "stackchan-logcat-capture-contract"
  $fakeAdb = New-FakeAdb -Root $root
  $outDir = Join-Path $root "out"

  Invoke-LogcatCapture -AdbPath $fakeAdb -OutputDir $outDir

  $jsonPath = Join-Path $outDir "android_companion_logcat.json"
  $summaryPath = Join-Path $outDir "ANDROID_COMPANION_LOGCAT.md"
  $excerptPath = Join-Path $outDir "android_companion_logcat.txt"
  $rawPath = Join-Path $outDir "android_companion_logcat_raw.txt"

  foreach ($path in @($jsonPath, $summaryPath, $excerptPath, $rawPath)) {
    if (-not (Test-Path -LiteralPath $path)) {
      throw "Expected logcat capture artifact was not written: $path"
    }
  }

  $report = Get-Content -LiteralPath $jsonPath -Raw | ConvertFrom-Json
  if ($report.schema -ne "stackchan.android-companion-logcat.v1") {
    throw "Logcat report schema mismatch: $($report.schema)"
  }
  if ($report.status -ne "captured") {
    throw "Logcat report status mismatch: $($report.status)"
  }
  if ($report.deviceSerial -ne "FAKE123") {
    throw "Logcat report selected unexpected device serial: $($report.deviceSerial)"
  }
  if ($report.model -ne "Pixel Contract" -or $report.androidRelease -ne "16" -or $report.androidSdk -ne "36") {
    throw "Logcat report device properties were not captured."
  }
  if ($report.packagePid -ne "1234") {
    throw "Logcat report packagePid mismatch: $($report.packagePid)"
  }
  if ([int]$report.requestedLines -ne 100 -or [int]$report.rawLineCount -ne 4 -or [int]$report.excerptLineCount -lt 3) {
    throw "Logcat report line counts are unexpected."
  }
  if ($report.raw -ne "android_companion_logcat_raw.txt") {
    throw "Logcat report did not reference the raw capture file."
  }

  Assert-FileContains -Path $excerptPath -Needle "CompanionBridgeService started"
  Assert-FileContains -Path $excerptPath -Needle "ForegroundService"
  Assert-FileContains -Path $excerptPath -Needle "FATAL EXCEPTION synthetic"
  Assert-FileContains -Path $rawPath -Needle "unrelated: ignored line"
  Assert-FileContains -Path $summaryPath -Needle "Android Companion Logcat Capture"
  Assert-FileContains -Path $summaryPath -Needle "android_companion_logcat_raw.txt"

  Write-Host "Android logcat capture contract tests passed."
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
