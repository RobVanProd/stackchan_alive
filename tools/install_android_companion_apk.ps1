param(
  [string]$ApkPath = "companion/app-android/build/outputs/apk/release/app-android-release.apk",
  [string]$OutputDir = "output/android-apk-install/latest",
  [string]$PackageName = "dev.stackchan.companion",
  [string]$AdbPath = "adb",
  [string]$Serial = "",
  [string]$SourceCommit = "",
  [switch]$AllowDowngrade
)

$ErrorActionPreference = "Stop"

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

function Get-RegexValue {
  param(
    [string]$Text,
    [string]$Pattern
  )

  $match = [regex]::Match($Text, $Pattern)
  if (-not $match.Success) {
    return ""
  }
  return $match.Groups[1].Value
}

function Get-GitCommitOrEmpty {
  try {
    $output = & git rev-parse HEAD 2>$null
  } catch {
    return ""
  }
  if ($LASTEXITCODE -ne 0) {
    return ""
  }
  return ($output | Out-String).Trim()
}

if (-not (Get-Command $AdbPath -ErrorAction SilentlyContinue)) {
  throw "adb was not found. Install Android platform-tools or pass -AdbPath."
}

if (-not (Test-Path -LiteralPath $ApkPath)) {
  throw "Missing Android APK: $ApkPath. From the source checkout, build one with cd companion; .\gradlew.bat :app-android:assembleRelease, then pass the generated APK path with -ApkPath."
}

$apkItem = Get-Item -LiteralPath $ApkPath
$apkHash = Get-FileHash -Algorithm SHA256 -LiteralPath $apkItem.FullName
$recordedSourceCommit = $SourceCommit.Trim()
if ([string]::IsNullOrWhiteSpace($recordedSourceCommit)) {
  $recordedSourceCommit = Get-GitCommitOrEmpty
}
if ([string]::IsNullOrWhiteSpace($recordedSourceCommit)) {
  $recordedSourceCommit = "not-recorded"
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

$installArgs = @("install", "-r")
if ($AllowDowngrade) {
  $installArgs += "-d"
}
$installArgs += $apkItem.FullName
$installOutput = @(Get-AdbOutput -Arguments $installArgs)

$dumpsysOutput = @(Get-AdbOutput -Arguments @("shell", "dumpsys", "package", $PackageName))
$dumpsysText = $dumpsysOutput -join "`n"
$versionName = Get-RegexValue -Text $dumpsysText -Pattern "(?m)^\s*versionName=([^\r\n]+)"
$versionCode = Get-RegexValue -Text $dumpsysText -Pattern "(?m)^\s*versionCode=(\d+)"
$firstInstallTime = Get-RegexValue -Text $dumpsysText -Pattern "(?m)^\s*firstInstallTime=([^\r\n]+)"
$lastUpdateTime = Get-RegexValue -Text $dumpsysText -Pattern "(?m)^\s*lastUpdateTime=([^\r\n]+)"

$summaryPath = Join-Path $OutputDir "ANDROID_APK_INSTALL.md"
$jsonPath = Join-Path $OutputDir "android_apk_install.json"
$installLogPath = Join-Path $OutputDir "adb_install.log"
$packageLogPath = Join-Path $OutputDir "adb_dumpsys_package.txt"

$installOutput | Set-Content -Path $installLogPath -Encoding UTF8
$dumpsysOutput | Set-Content -Path $packageLogPath -Encoding UTF8

$report = [ordered]@{
  schema = "stackchan.android-apk-install.v1"
  status = "installed"
  capturedUtc = $capturedUtc
  packageName = $PackageName
  deviceSerial = $selectedSerial
  model = $model
  androidRelease = $androidRelease
  androidSdk = $androidSdk
  apkPath = $apkItem.FullName
  apkFileName = $apkItem.Name
  apkSizeBytes = $apkItem.Length
  apkSha256 = $apkHash.Hash.ToLowerInvariant()
  sourceCommit = $recordedSourceCommit
  allowDowngrade = [bool]$AllowDowngrade
  versionName = $versionName
  versionCode = $versionCode
  firstInstallTime = $firstInstallTime
  lastUpdateTime = $lastUpdateTime
  installLog = "adb_install.log"
  packageDump = "adb_dumpsys_package.txt"
}
$report | ConvertTo-Json -Depth 4 | Set-Content -Path $jsonPath -Encoding UTF8

$markdown = @(
  "# Android APK Install Evidence",
  "",
  "- Schema: stackchan.android-apk-install.v1",
  "- Status: installed",
  "- Captured UTC: $capturedUtc",
  "- Device: $model ($selectedSerial)",
  "- Android: $androidRelease / SDK $androidSdk",
  "- Package: $PackageName",
  "- Installed version: $versionName / code $versionCode",
  "- APK: $($apkItem.FullName)",
  "- APK SHA256: $($apkHash.Hash.ToLowerInvariant())",
  "- APK size: $($apkItem.Length) bytes",
  "- Source commit: $recordedSourceCommit",
  "",
  "Use this record as the arrival-day proof of which Android companion APK was installed before LAN bridge probing or robot connection testing.",
  "",
  "Files:",
  "",
  "- android_apk_install.json",
  "- adb_install.log",
  "- adb_dumpsys_package.txt",
  "",
  "Install command:",
  "",
  '```powershell',
  ".\tools\install_android_companion_apk.ps1 -ApkPath '$($apkItem.FullName)' -OutputDir '$OutputDir' -SourceCommit '$recordedSourceCommit'",
  '```'
)

$markdown | Set-Content -Path $summaryPath -Encoding UTF8

Write-Host "Android APK install evidence:"
Write-Output $summaryPath
