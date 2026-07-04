param(
  [switch]$Json
)

$ErrorActionPreference = "Stop"

$repoRoot = Resolve-Path (Join-Path $PSScriptRoot "..")
Set-Location $repoRoot

$requiredPlatform = "android-36"
$requiredPlatformPath = "platforms/android-36"

function Get-FirstCommandPath {
  param([string]$Name)

  $command = Get-Command $Name -ErrorAction SilentlyContinue | Select-Object -First 1
  if ($null -eq $command) {
    return ""
  }
  return $command.Source
}

function Get-ExistingFilePath {
  param([string[]]$Paths)

  foreach ($path in $Paths) {
    if ([string]::IsNullOrWhiteSpace($path)) {
      continue
    }
    if (Test-Path -LiteralPath $path -PathType Leaf) {
      return $path
    }
  }
  return ""
}

function Get-UniqueNonEmpty {
  param([string[]]$Values)

  $seen = @{}
  $result = @()
  foreach ($value in $Values) {
    if ([string]::IsNullOrWhiteSpace($value)) {
      continue
    }
    if (-not $seen.ContainsKey($value)) {
      $seen[$value] = $true
      $result += $value
    }
  }
  return @($result)
}

function Get-JavaReport {
  $javaHome = $env:JAVA_HOME
  $javaHomeExists = $false
  $javaHomeJava = ""
  $javaHomeStatus = "unset"
  if (-not [string]::IsNullOrWhiteSpace($javaHome)) {
    $javaHomeExists = Test-Path -LiteralPath $javaHome -PathType Container
    $candidateJavaHomeJava = Join-Path (Join-Path $javaHome "bin") "java.exe"
    $candidateJavaHomeJavaNoExtension = Join-Path (Join-Path $javaHome "bin") "java"
    $javaHomeJava = Get-ExistingFilePath @($candidateJavaHomeJava, $candidateJavaHomeJavaNoExtension)
    if ($javaHomeExists -and -not [string]::IsNullOrWhiteSpace($javaHomeJava)) {
      $javaHomeStatus = "ready"
    } else {
      $javaHomeStatus = "invalid-java-home"
    }
  }

  $pathJava = Get-FirstCommandPath "java"
  $selectedJava = if (-not [string]::IsNullOrWhiteSpace($javaHomeJava)) { $javaHomeJava } else { $pathJava }
  $versionText = ""
  $exitCode = $null
  $status = "missing"
  if ($javaHomeStatus -eq "invalid-java-home") {
    $status = "invalid-java-home"
  } elseif ([string]::IsNullOrWhiteSpace($selectedJava)) {
    $status = "no-java-command"
  } else {
    try {
      $versionOutput = & $selectedJava -version 2>&1
      $exitCode = $LASTEXITCODE
      $versionText = (($versionOutput | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Select-Object -First 1) | Out-String).Trim()
      if ($exitCode -eq 0) {
        $status = "ready"
      } else {
        $status = "java-version-failed"
      }
    } catch {
      $status = "java-version-failed"
      $versionText = $_.Exception.Message
    }
  }

  return [ordered]@{
    status = $status
    javaHome = $javaHome
    javaHomeExists = $javaHomeExists
    javaHomeStatus = $javaHomeStatus
    javaHomeJava = $javaHomeJava
    pathJava = $pathJava
    selectedJava = $selectedJava
    version = $versionText
    versionExitCode = $exitCode
  }
}

function Get-AndroidSdkReport {
  $commonSdk = if ([string]::IsNullOrWhiteSpace($env:LOCALAPPDATA)) { "" } else { Join-Path $env:LOCALAPPDATA "Android\Sdk" }
  $candidateRoots = Get-UniqueNonEmpty @($env:ANDROID_HOME, $env:ANDROID_SDK_ROOT, $commonSdk)
  $rootReports = @()
  foreach ($root in $candidateRoots) {
    $exists = Test-Path -LiteralPath $root -PathType Container
    $platformsDir = Join-Path $root "platforms"
    $platformNames = @()
    if (Test-Path -LiteralPath $platformsDir -PathType Container) {
      $platformNames = @(Get-ChildItem -LiteralPath $platformsDir -Directory -ErrorAction SilentlyContinue | Where-Object { $_.Name -like "android-*" } | Select-Object -ExpandProperty Name)
    }
    $adbExe = Join-Path (Join-Path $root "platform-tools") "adb.exe"
    $adbNoExtension = Join-Path (Join-Path $root "platform-tools") "adb"
    $sdkManagerLatest = Join-Path (Join-Path (Join-Path (Join-Path $root "cmdline-tools") "latest") "bin") "sdkmanager.bat"
    $sdkManagerDirect = Join-Path (Join-Path (Join-Path $root "cmdline-tools") "bin") "sdkmanager.bat"
    $rootReports += [ordered]@{
      path = $root
      exists = $exists
      hasPlatformTools = Test-Path -LiteralPath (Join-Path $root "platform-tools") -PathType Container
      adb = Get-ExistingFilePath @($adbExe, $adbNoExtension)
      sdkmanager = Get-ExistingFilePath @($sdkManagerLatest, $sdkManagerDirect)
      platforms = @($platformNames)
      hasRequiredPlatform = ($platformNames -contains $requiredPlatform)
      requiredPlatformPath = $requiredPlatformPath
    }
  }

  $selectedRoot = ""
  foreach ($rootReport in $rootReports) {
    if ($rootReport.exists) {
      $selectedRoot = $rootReport.path
      break
    }
  }

  $selectedRootReport = $rootReports | Where-Object { $_.path -eq $selectedRoot } | Select-Object -First 1
  $pathAdb = Get-FirstCommandPath "adb"
  $selectedAdb = ""
  $selectedSdkManager = ""
  $hasRequiredPlatform = $false
  $platforms = @()
  if ($null -ne $selectedRootReport) {
    $selectedAdb = if (-not [string]::IsNullOrWhiteSpace($selectedRootReport.adb)) { $selectedRootReport.adb } else { $pathAdb }
    $selectedSdkManager = $selectedRootReport.sdkmanager
    $hasRequiredPlatform = $selectedRootReport.hasRequiredPlatform
    $platforms = @($selectedRootReport.platforms)
  } else {
    $selectedAdb = $pathAdb
  }

  $status = "ready"
  if ([string]::IsNullOrWhiteSpace($selectedRoot)) {
    $status = "missing-sdk-root"
  } elseif ([string]::IsNullOrWhiteSpace($selectedAdb)) {
    $status = "missing-adb"
  } elseif (-not $hasRequiredPlatform) {
    $status = "missing-android-36"
  }

  return [ordered]@{
    status = $status
    androidHome = $env:ANDROID_HOME
    androidSdkRoot = $env:ANDROID_SDK_ROOT
    selectedRoot = $selectedRoot
    candidateRoots = @($rootReports)
    pathAdb = $pathAdb
    selectedAdb = $selectedAdb
    sdkmanager = $selectedSdkManager
    platforms = @($platforms)
    requiredPlatform = $requiredPlatform
    requiredPlatformPath = $requiredPlatformPath
    hasRequiredPlatform = $hasRequiredPlatform
  }
}

$gradleWrapperCandidates = @(
  [ordered]@{
    path = Join-Path (Join-Path $repoRoot "companion") "gradlew.bat"
    display = "companion/gradlew.bat"
  },
  [ordered]@{
    path = Join-Path (Join-Path (Join-Path $repoRoot "provenance") "companion") "gradlew.bat"
    display = "provenance/companion/gradlew.bat"
  }
)
$gradleWrapperDisplay = "companion/gradlew.bat"
$hasGradleWrapper = $false
foreach ($candidate in $gradleWrapperCandidates) {
  if (Test-Path -LiteralPath $candidate.path -PathType Leaf) {
    $gradleWrapperDisplay = $candidate.display
    $hasGradleWrapper = $true
    break
  }
}
$javaReport = Get-JavaReport
$sdkReport = Get-AndroidSdkReport

$status = "ready"
$problems = @()
if (-not $hasGradleWrapper) {
  $status = "missing-gradle-wrapper"
  $problems += "Missing $gradleWrapperDisplay."
}
if ($javaReport.status -ne "ready") {
  $status = "not-ready"
  $problems += "Java is not ready: $($javaReport.status)."
}
if ($sdkReport.status -ne "ready") {
  $status = "not-ready"
  $problems += "Android SDK is not ready: $($sdkReport.status)."
}

$report = [ordered]@{
  schema = "stackchan.android-toolchain-check.v1"
  status = $status
  gradleWrapper = [ordered]@{
    path = $gradleWrapperDisplay
    exists = $hasGradleWrapper
    candidates = @($gradleWrapperCandidates | ForEach-Object {
      [ordered]@{
        path = $_.display
        exists = Test-Path -LiteralPath $_.path -PathType Leaf
      }
    })
  }
  java = $javaReport
  androidSdk = $sdkReport
  problems = @($problems)
  installGuidance = @(
    "Install JDK 21 or the Android Studio bundled JBR and set JAVA_HOME to the JDK root.",
    "Install Android Studio or Android SDK command-line tools and set ANDROID_HOME or ANDROID_SDK_ROOT.",
    "Install Android SDK Platform 36 and platform-tools so $requiredPlatformPath and platform-tools/adb.exe exist.",
    "Reopen the terminal after environment changes, then run tools/check_android_toolchain.cmd again."
  )
}

if ($Json) {
  $report | ConvertTo-Json -Depth 8
} else {
  Write-Host "Android companion toolchain: $status"
  Write-Host "Gradle wrapper: $gradleWrapperDisplay ($(if ($hasGradleWrapper) { "found" } else { "missing" }))"
  Write-Host "Java: $($javaReport.status)"
  if (-not [string]::IsNullOrWhiteSpace($javaReport.javaHome)) {
    Write-Host "  JAVA_HOME: $($javaReport.javaHome)"
  }
  if (-not [string]::IsNullOrWhiteSpace($javaReport.selectedJava)) {
    Write-Host "  java.exe: $($javaReport.selectedJava)"
  }
  if (-not [string]::IsNullOrWhiteSpace($javaReport.version)) {
    Write-Host "  version: $($javaReport.version)"
  }
  Write-Host "Android SDK: $($sdkReport.status)"
  if (-not [string]::IsNullOrWhiteSpace($sdkReport.selectedRoot)) {
    Write-Host "  SDK root: $($sdkReport.selectedRoot)"
  }
  if (-not [string]::IsNullOrWhiteSpace($sdkReport.selectedAdb)) {
    Write-Host "  adb.exe: $($sdkReport.selectedAdb)"
  }
  if (-not [string]::IsNullOrWhiteSpace($sdkReport.sdkmanager)) {
    Write-Host "  sdkmanager: $($sdkReport.sdkmanager)"
  }
  Write-Host "  Required platform: $requiredPlatformPath ($(if ($sdkReport.hasRequiredPlatform) { "found" } else { "missing" }))"
  if ($problems.Count -gt 0) {
    Write-Host ""
    Write-Host "Problems:"
    foreach ($problem in $problems) {
      Write-Host "- $problem"
    }
    Write-Host ""
    Write-Host "Install guidance:"
    foreach ($line in $report.installGuidance) {
      Write-Host "- $line"
    }
  }
}

if ($status -ne "ready") {
  exit 2
}
