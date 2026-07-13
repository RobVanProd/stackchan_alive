param(
  [string]$ApkPath = "companion/app-android/build/outputs/apk/release/app-android-release.apk",
  [string]$OutputDir = "output/android-emulator-smoke/latest",
  [string]$PackageName = "dev.stackchan.companion",
  [string]$ActivityName = "dev.stackchan.companion.android.MainActivity",
  [string]$ServiceName = "dev.stackchan.companion.android.CompanionBridgeService",
  [string]$AdbPath = "adb",
  [string]$Serial = "",
  [int]$SettleSeconds = 10,
  [switch]$Json
)

$ErrorActionPreference = "Stop"

function Invoke-Adb {
  param([string[]]$Arguments)

  $adbArguments = @()
  if (-not [string]::IsNullOrWhiteSpace($Serial)) {
    $adbArguments += @("-s", $Serial)
  }
  $adbArguments += $Arguments

  $oldErrorActionPreference = $ErrorActionPreference
  $ErrorActionPreference = "Continue"
  try {
    $output = @(& $AdbPath @adbArguments 2>&1)
    $exitCode = $LASTEXITCODE
  } finally {
    $ErrorActionPreference = $oldErrorActionPreference
  }

  return [pscustomobject]@{
    exitCode = $exitCode
    output = @($output | ForEach-Object { [string]$_ })
  }
}

function Assert-AdbSuccess {
  param(
    [object]$Result,
    [string]$Operation
  )

  if ($Result.exitCode -ne 0) {
    throw "$Operation failed with adb exit code $($Result.exitCode): $($Result.output -join ' ')"
  }
  return @($Result.output)
}

function Get-RegexValue {
  param(
    [string]$Text,
    [string]$Pattern
  )

  $match = [regex]::Match($Text, $Pattern)
  if ($match.Success) {
    return $match.Groups[1].Value.Trim()
  }
  return ""
}

if ($SettleSeconds -lt 1 -or $SettleSeconds -gt 120) {
  throw "SettleSeconds must be between 1 and 120."
}
if (-not (Get-Command $AdbPath -ErrorAction SilentlyContinue)) {
  throw "adb was not found. Install Android platform-tools or pass -AdbPath."
}
if (-not (Test-Path -LiteralPath $ApkPath -PathType Leaf)) {
  throw "Missing Android APK: $ApkPath"
}

$apk = Get-Item -LiteralPath $ApkPath
New-Item -ItemType Directory -Force -Path $OutputDir | Out-Null

$devicesResult = Invoke-Adb -Arguments @("devices")
$devicesOutput = Assert-AdbSuccess -Result $devicesResult -Operation "adb devices"
$connectedDevices = @(
  $devicesOutput |
    Select-Object -Skip 1 |
    Where-Object { $_ -match "\sdevice$" } |
    ForEach-Object { ($_ -split "\s+")[0] }
)
if ($connectedDevices.Count -eq 0) {
  throw "No adb emulator is connected and authorized."
}
if ([string]::IsNullOrWhiteSpace($Serial)) {
  if ($connectedDevices.Count -ne 1) {
    throw "Expected exactly one adb device; found $($connectedDevices.Count). Pass -Serial to select the emulator."
  }
  $Serial = $connectedDevices[0]
} elseif ($connectedDevices -notcontains $Serial) {
  throw "Requested adb serial '$Serial' is not connected and authorized."
}

$qemuResult = Invoke-Adb -Arguments @("shell", "getprop", "ro.kernel.qemu")
$qemuValue = (Assert-AdbSuccess -Result $qemuResult -Operation "read emulator identity" | Out-String).Trim()
if ($qemuValue -ne "1") {
  throw "Android launch smoke requires an emulator; serial '$Serial' did not report ro.kernel.qemu=1. Physical-device evidence must use the dedicated Android evidence workflow."
}

$installLogPath = Join-Path $OutputDir "adb_install.log"
$startLogPath = Join-Path $OutputDir "am_start.log"
$activityLogPath = Join-Path $OutputDir "dumpsys_activity.txt"
$serviceLogPath = Join-Path $OutputDir "dumpsys_services.txt"
$packageLogPath = Join-Path $OutputDir "dumpsys_package.txt"
$logcatPath = Join-Path $OutputDir "logcat.txt"
$jsonPath = Join-Path $OutputDir "android_emulator_launch_smoke.json"
$markdownPath = Join-Path $OutputDir "ANDROID_EMULATOR_LAUNCH_SMOKE.md"

$installResult = Invoke-Adb -Arguments @("install", "-r", $apk.FullName)
$installResult.output | Set-Content -LiteralPath $installLogPath -Encoding UTF8
Assert-AdbSuccess -Result $installResult -Operation "install emulator APK" | Out-Null

$grantResult = Invoke-Adb -Arguments @("shell", "pm", "grant", $PackageName, "android.permission.POST_NOTIFICATIONS")
Assert-AdbSuccess -Result $grantResult -Operation "grant emulator notification permission" | Out-Null
Assert-AdbSuccess -Result (Invoke-Adb -Arguments @("shell", "am", "force-stop", $PackageName)) -Operation "force-stop app before cold launch" | Out-Null
Assert-AdbSuccess -Result (Invoke-Adb -Arguments @("logcat", "-c")) -Operation "clear emulator logcat" | Out-Null

$component = "$PackageName/$ActivityName"
$activityStateName = if ($ActivityName.StartsWith("$PackageName.")) { $ActivityName.Substring($PackageName.Length) } else { $ActivityName }
$serviceStateName = if ($ServiceName.StartsWith("$PackageName.")) { $ServiceName.Substring($PackageName.Length) } else { $ServiceName }
$startResult = Invoke-Adb -Arguments @("shell", "am", "start", "-W", "-n", $component)
$startResult.output | Set-Content -LiteralPath $startLogPath -Encoding UTF8
Assert-AdbSuccess -Result $startResult -Operation "cold-launch MainActivity" | Out-Null
Start-Sleep -Seconds $SettleSeconds

$processResult = Invoke-Adb -Arguments @("shell", "pidof", $PackageName)
$processId = if ($processResult.exitCode -eq 0) { ($processResult.output -join "").Trim() } else { "" }
$activityResult = Invoke-Adb -Arguments @("shell", "dumpsys", "activity", "activities")
$activityOutput = Assert-AdbSuccess -Result $activityResult -Operation "capture activity state"
$activityOutput | Set-Content -LiteralPath $activityLogPath -Encoding UTF8
$activityText = $activityOutput -join "`n"

$serviceResult = Invoke-Adb -Arguments @("shell", "dumpsys", "activity", "services", $PackageName)
$serviceOutput = Assert-AdbSuccess -Result $serviceResult -Operation "capture service state"
$serviceOutput | Set-Content -LiteralPath $serviceLogPath -Encoding UTF8
$serviceText = $serviceOutput -join "`n"

$packageResult = Invoke-Adb -Arguments @("shell", "dumpsys", "package", $PackageName)
$packageOutput = Assert-AdbSuccess -Result $packageResult -Operation "capture package state"
$packageOutput | Set-Content -LiteralPath $packageLogPath -Encoding UTF8
$packageText = $packageOutput -join "`n"

$logcatResult = Invoke-Adb -Arguments @("logcat", "-d", "-v", "threadtime")
$logcatOutput = Assert-AdbSuccess -Result $logcatResult -Operation "capture post-launch logcat"
$logcatOutput | Set-Content -LiteralPath $logcatPath -Encoding UTF8
$logcatText = $logcatOutput -join "`n"

$model = (Assert-AdbSuccess -Result (Invoke-Adb -Arguments @("shell", "getprop", "ro.product.model")) -Operation "read emulator model" | Out-String).Trim()
$apiLevel = (Assert-AdbSuccess -Result (Invoke-Adb -Arguments @("shell", "getprop", "ro.build.version.sdk")) -Operation "read emulator API" | Out-String).Trim()
$versionName = Get-RegexValue -Text $packageText -Pattern "(?m)^\s*versionName=([^\r\n]+)"
$versionCode = Get-RegexValue -Text $packageText -Pattern "(?m)^\s*versionCode=(\d+)"
$launchState = Get-RegexValue -Text ($startResult.output -join "`n") -Pattern "(?m)^LaunchState:\s*([^\r\n]+)"
$totalTimeMs = Get-RegexValue -Text ($startResult.output -join "`n") -Pattern "(?m)^TotalTime:\s*(\d+)"
$mainActivityResumed = $activityText -match ("(?m)(topResumedActivity|ResumedActivity:).*" + [regex]::Escape("$PackageName/$activityStateName"))
$bridgeServicePresent = $serviceText -match [regex]::Escape("$PackageName/$serviceStateName")
$fatalProcessMatches = @(
  [regex]::Matches($logcatText, "(?m)Process:\s*" + [regex]::Escape($PackageName) + "(?:,|\s|$)")
).Count + @(
  [regex]::Matches($logcatText, "(?m)Fatal signal.*" + [regex]::Escape($PackageName))
).Count

$issues = New-Object System.Collections.Generic.List[string]
if ([string]::IsNullOrWhiteSpace($processId)) {
  $issues.Add("app process is not alive after launch")
}
if (-not $mainActivityResumed) {
  $issues.Add("MainActivity is not the top resumed activity")
}
if (-not $bridgeServicePresent) {
  $issues.Add("CompanionBridgeService is absent after launch")
}
if ($fatalProcessMatches -gt 0) {
  $issues.Add("post-launch logcat contains $fatalProcessMatches app fatal-process match(es)")
}
if ([string]::IsNullOrWhiteSpace($versionName) -or [string]::IsNullOrWhiteSpace($versionCode)) {
  $issues.Add("installed package version identity is incomplete")
}

$status = if ($issues.Count -eq 0) { "pass" } else { "fail" }
$report = [ordered]@{
  schema = "stackchan.android-emulator-launch-smoke.v1"
  status = $status
  capturedUtc = (Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")
  serial = $Serial
  model = $model
  apiLevel = $apiLevel
  packageName = $PackageName
  versionName = $versionName
  versionCode = $versionCode
  apkFileName = $apk.Name
  apkSizeBytes = $apk.Length
  apkSha256 = (Get-FileHash -Algorithm SHA256 -LiteralPath $apk.FullName).Hash.ToLowerInvariant()
  processId = $processId
  launchState = $launchState
  totalTimeMs = if ($totalTimeMs -match "^\d+$") { [int]$totalTimeMs } else { $null }
  mainActivityResumed = [bool]$mainActivityResumed
  bridgeServicePresent = [bool]$bridgeServicePresent
  fatalProcessMatches = $fatalProcessMatches
  notificationPermissionPregranted = $true
  scope = "emulator-install-launch-service-smoke-only"
  substitutesForPhysicalEvidence = $false
  issues = @($issues)
  files = [ordered]@{
    installLog = "adb_install.log"
    startLog = "am_start.log"
    activityState = "dumpsys_activity.txt"
    serviceState = "dumpsys_services.txt"
    packageState = "dumpsys_package.txt"
    logcat = "logcat.txt"
  }
}
$report | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $jsonPath -Encoding UTF8

$markdown = @(
  "# Android Emulator Launch Smoke",
  "",
  "- Status: $status",
  "- Captured UTC: $($report.capturedUtc)",
  "- Emulator: $model / API $apiLevel / $Serial",
  "- Package: $PackageName $versionName ($versionCode)",
  "- APK SHA-256: $($report.apkSha256)",
  "- Launch: $launchState / $($report.totalTimeMs) ms",
  "- Process alive: $(-not [string]::IsNullOrWhiteSpace($processId))",
  "- MainActivity resumed: $mainActivityResumed",
  "- CompanionBridgeService present: $bridgeServicePresent",
  "- Fatal process matches: $fatalProcessMatches",
  "",
  "This is an emulator-only install, cold-launch, foreground-service, and crash smoke. It does not replace target-phone, physical robot, screen-off, microphone, Gemma accelerator, or Play internal-testing evidence."
)
if ($issues.Count -gt 0) {
  $markdown += @("", "Issues:", "")
  $markdown += @($issues | ForEach-Object { "- $_" })
}
$markdown | Set-Content -LiteralPath $markdownPath -Encoding UTF8

if ($Json) {
  $report | ConvertTo-Json -Depth 6
} else {
  Write-Host "Android emulator launch smoke: $status"
  Write-Host "Package: $PackageName $versionName ($versionCode)"
  Write-Host "Launch: $launchState / $($report.totalTimeMs) ms"
  Write-Host "Evidence: $jsonPath"
}

if ($status -ne "pass") {
  exit 1
}
