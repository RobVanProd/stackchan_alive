param(
  [string]$OutputDir = "output/android-logcat/latest",
  [string]$PackageName = "dev.stackchan.companion",
  [string]$AdbPath = "adb",
  [string]$Serial = "",
  [int]$Lines = 1200,
  [switch]$IncludeRaw
)

$ErrorActionPreference = "Stop"

if ($Lines -lt 100) {
  throw "-Lines must be at least 100 so the excerpt can include Android service lifecycle context."
}

function Invoke-Adb {
  param([string[]]$Arguments)

  $adbArgs = @()
  if ($Serial -ne "") {
    $adbArgs += @("-s", $Serial)
  }
  $adbArgs += $Arguments

  & $AdbPath @adbArgs
}

function Get-AdbOutput {
  param([string[]]$Arguments)

  $output = @(Invoke-Adb -Arguments $Arguments 2>&1)
  if ($LASTEXITCODE -ne 0) {
    throw "adb $($Arguments -join ' ') failed with exit code $LASTEXITCODE. Output: $($output -join ' ')"
  }
  return $output
}

if (-not (Get-Command $AdbPath -ErrorAction SilentlyContinue)) {
  throw "adb was not found. Install Android platform-tools or pass -AdbPath."
}

New-Item -ItemType Directory -Force -Path $OutputDir | Out-Null

$devicesOutput = @(Get-AdbOutput -Arguments @("devices"))
$connectedDevices = @(
  $devicesOutput |
    Select-Object -Skip 1 |
    Where-Object { $_ -match "\sdevice$" } |
    ForEach-Object { ($_ -split "\s+")[0] }
)

if ($connectedDevices.Count -eq 0) {
  throw "No adb device is connected and authorized."
}
if ($Serial -eq "" -and $connectedDevices.Count -gt 1) {
  throw "Multiple adb devices are connected. Re-run with -Serial <device-serial>."
}

$selectedSerial = if ($Serial -ne "") { $Serial } else { $connectedDevices[0] }
$capturedUtc = (Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")

$model = (@(Get-AdbOutput -Arguments @("shell", "getprop", "ro.product.model")) -join "`n").Trim()
$androidRelease = (@(Get-AdbOutput -Arguments @("shell", "getprop", "ro.build.version.release")) -join "`n").Trim()
$androidSdk = (@(Get-AdbOutput -Arguments @("shell", "getprop", "ro.build.version.sdk")) -join "`n").Trim()

$pidOutput = @(Invoke-Adb -Arguments @("shell", "pidof", $PackageName) 2>$null)
$packagePid = ""
if ($LASTEXITCODE -eq 0) {
  $packagePid = ($pidOutput -join " ").Trim()
}

$logcatArgs = @("logcat", "-d", "-v", "threadtime", "-t", "$Lines")
$rawLines = @(Get-AdbOutput -Arguments $logcatArgs)

$matchPattern = [regex]::Escape($PackageName) +
  "|dev\.stackchan|Stackchan|CompanionBridgeService|stackchan_companion_bridge|StackchanCompanion:BridgeSession|ForegroundService|foreground service|AndroidRuntime|FATAL EXCEPTION|ANR in"
if ($packagePid -ne "") {
  $pidAlternates = @(
    $packagePid -split "\s+" |
      Where-Object { $_ -match "^\d+$" } |
      ForEach-Object { "\s$([regex]::Escape($_))\s" }
  )
  if ($pidAlternates.Count -gt 0) {
    $matchPattern += "|" + ($pidAlternates -join "|")
  }
}

$excerptLines = @($rawLines | Where-Object { $_ -match $matchPattern })
$status = "captured"
if ($excerptLines.Count -eq 0) {
  $status = "captured-no-matching-lines"
  $excerptLines = @(
    "No Stackchan companion, foreground service, crash, ANR, or package-pid lines matched in the latest $Lines logcat lines.",
    "Re-run with a larger -Lines value or -IncludeRaw immediately after reproducing the issue."
  )
}

$excerptPath = Join-Path $OutputDir "android_companion_logcat.txt"
$summaryPath = Join-Path $OutputDir "ANDROID_COMPANION_LOGCAT.md"
$jsonPath = Join-Path $OutputDir "android_companion_logcat.json"
$rawPath = Join-Path $OutputDir "android_companion_logcat_raw.txt"

$excerptLines | Set-Content -Path $excerptPath -Encoding UTF8
if ($IncludeRaw) {
  $rawLines | Set-Content -Path $rawPath -Encoding UTF8
}

$rawReportPath = $null
if ($IncludeRaw) {
  $rawReportPath = "android_companion_logcat_raw.txt"
}
$packagePidText = "not running or unavailable"
if ($packagePid -ne "") {
  $packagePidText = $packagePid
}

$report = [ordered]@{
  schema = "stackchan.android-companion-logcat.v1"
  status = $status
  capturedUtc = $capturedUtc
  packageName = $PackageName
  deviceSerial = $selectedSerial
  model = $model
  androidRelease = $androidRelease
  androidSdk = $androidSdk
  packagePid = $packagePid
  requestedLines = $Lines
  rawLineCount = $rawLines.Count
  excerptLineCount = $excerptLines.Count
  excerpt = "android_companion_logcat.txt"
  raw = $rawReportPath
}
$report | ConvertTo-Json -Depth 4 | Set-Content -Path $jsonPath -Encoding UTF8

$markdown = @(
  "# Android Companion Logcat Capture",
  "",
  "- Schema: stackchan.android-companion-logcat.v1",
  "- Status: $status",
  "- Captured UTC: $capturedUtc",
  "- Device: $model ($selectedSerial)",
  "- Android: $androidRelease / SDK $androidSdk",
  "- Package: $PackageName",
  "- Package PID: $packagePidText",
  "- Requested logcat lines: $Lines",
  "- Raw lines scanned: $($rawLines.Count)",
  "- Excerpt lines saved: $($excerptLines.Count)",
  "",
  "Use this excerpt when the Android bridge service stops, crashes, loses foreground status, or fails to stay reachable during a screen-off robot session.",
  "",
  "Files:",
  "",
  "- android_companion_logcat.txt",
  "- android_companion_logcat.json"
)
if ($IncludeRaw) {
  $markdown += "- android_companion_logcat_raw.txt"
}
$markdown += @(
  "",
  "Capture command:",
  "",
  '```powershell',
  ".\tools\capture_android_companion_logcat.ps1 -OutputDir '$OutputDir' -Lines $Lines",
  '```'
)

$markdown | Set-Content -Path $summaryPath -Encoding UTF8

Write-Host "Android companion logcat capture:"
Write-Output $summaryPath
