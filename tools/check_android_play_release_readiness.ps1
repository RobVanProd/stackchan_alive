param(
  [string]$Root = "",
  [switch]$Json
)

$ErrorActionPreference = "Stop"

if ([string]::IsNullOrWhiteSpace($Root)) {
  $Root = Resolve-Path (Join-Path $PSScriptRoot "..")
} else {
  $Root = Resolve-Path $Root
}

$checks = @()

function Add-Check {
  param(
    [string]$Id,
    [string]$Name,
    [ValidateSet("pass", "fail", "pending")]
    [string]$Status,
    [string]$Evidence,
    [string]$Detail
  )

  $script:checks += [ordered]@{
    id = $Id
    name = $Name
    status = $Status
    evidence = $Evidence
    detail = $Detail
  }
}

function Get-ConfiguredValue {
  param([string]$Name)

  $environmentValue = [Environment]::GetEnvironmentVariable($Name)
  if (-not [string]::IsNullOrWhiteSpace($environmentValue)) {
    return [ordered]@{
      source = "environment"
      value = $environmentValue
    }
  }

  $propertiesPath = Join-RootPath "companion/gradle.properties"
  if (Test-Path -LiteralPath $propertiesPath -PathType Leaf) {
    foreach ($line in Get-Content -LiteralPath $propertiesPath) {
      $trimmed = $line.Trim()
      if ($trimmed.StartsWith("#") -or $trimmed -notmatch "^$([regex]::Escape($Name))\s*=\s*(.+)$") {
        continue
      }
      return [ordered]@{
        source = "companion/gradle.properties"
        value = $matches[1].Trim()
      }
    }
  }

  return [ordered]@{
    source = ""
    value = ""
  }
}

function Test-PlayUploadSigningEnvironment {
  $requiredNames = @(
    "STACKCHAN_ANDROID_KEYSTORE",
    "STACKCHAN_ANDROID_KEYSTORE_PASSWORD",
    "STACKCHAN_ANDROID_KEY_ALIAS",
    "STACKCHAN_ANDROID_KEY_PASSWORD"
  )
  $configured = @{}
  $missing = @()
  foreach ($name in $requiredNames) {
    $value = Get-ConfiguredValue $name
    $configured[$name] = $value
    if ([string]::IsNullOrWhiteSpace([string]$value.value)) {
      $missing += $name
    }
  }

  if ($missing.Count -gt 0) {
    Add-Check `
      -Id "play-upload-signing-environment" `
      -Name "Play upload signing environment" `
      -Status "pending" `
      -Evidence "STACKCHAN_ANDROID_KEYSTORE*" `
      -Detail ("Upload signing credentials are not configured yet; missing " + ($missing -join ", ") + ". Lab APK/AAB builds remain debug-certificate signed until these exist.")
    return
  }

  $keystorePath = [string]$configured["STACKCHAN_ANDROID_KEYSTORE"].value
  $resolvedKeystore = if ([System.IO.Path]::IsPathRooted($keystorePath)) { $keystorePath } else { Join-Path $Root $keystorePath }
  if (-not (Test-Path -LiteralPath $resolvedKeystore -PathType Leaf)) {
    Add-Check `
      -Id "play-upload-signing-environment" `
      -Name "Play upload signing environment" `
      -Status "fail" `
      -Evidence "STACKCHAN_ANDROID_KEYSTORE" `
      -Detail "Upload signing variables are present, but the configured keystore file does not exist."
    return
  }

  Add-Check `
    -Id "play-upload-signing-environment" `
    -Name "Play upload signing environment" `
    -Status "pass" `
    -Evidence "STACKCHAN_ANDROID_KEYSTORE*" `
    -Detail "Upload signing variables are configured and the keystore file exists."
}

function Join-RootPath {
  param([string]$RelativePath)
  return Join-Path $Root $RelativePath
}

function Test-FilePresent {
  param(
    [string]$Id,
    [string]$Name,
    [string]$RelativePath
  )

  $path = Join-RootPath $RelativePath
  if (Test-Path -LiteralPath $path -PathType Leaf) {
    Add-Check $Id $Name "pass" $RelativePath "File exists."
  } else {
    Add-Check $Id $Name "fail" $RelativePath "File is missing."
  }
}

function Test-TextPatterns {
  param(
    [string]$Id,
    [string]$Name,
    [string]$RelativePath,
    [string[]]$Patterns
  )

  $path = Join-RootPath $RelativePath
  if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
    Add-Check $Id $Name "fail" $RelativePath "File is missing."
    return
  }
  $text = Get-Content -LiteralPath $path -Raw
  $missing = @($Patterns | Where-Object { $text -notmatch [regex]::Escape($_) })
  if ($missing.Count -eq 0) {
    Add-Check $Id $Name "pass" $RelativePath "All expected patterns are present."
  } else {
    Add-Check $Id $Name "fail" $RelativePath ("Missing: " + ($missing -join ", "))
  }
}

function Get-PngDimensions {
  param([string]$Path)

  $bytes = [System.IO.File]::ReadAllBytes($Path)
  if ($bytes.Length -lt 24) {
    throw "PNG file is too small."
  }
  $signature = @(0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A)
  for ($index = 0; $index -lt $signature.Count; $index++) {
    if ($bytes[$index] -ne $signature[$index]) {
      throw "PNG signature mismatch."
    }
  }
  $widthBytes = $bytes[16..19]
  $heightBytes = $bytes[20..23]
  if ([BitConverter]::IsLittleEndian) {
    [array]::Reverse($widthBytes)
    [array]::Reverse($heightBytes)
  }
  return [ordered]@{
    width = [BitConverter]::ToInt32($widthBytes, 0)
    height = [BitConverter]::ToInt32($heightBytes, 0)
  }
}

function Test-PngSize {
  param(
    [string]$Id,
    [string]$Name,
    [string]$RelativePath,
    [int]$ExpectedWidth,
    [int]$ExpectedHeight
  )

  $path = Join-RootPath $RelativePath
  if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
    Add-Check $Id $Name "fail" $RelativePath "PNG is missing."
    return
  }
  try {
    $dimensions = Get-PngDimensions $path
    if ($dimensions.width -eq $ExpectedWidth -and $dimensions.height -eq $ExpectedHeight) {
      Add-Check $Id $Name "pass" $RelativePath "PNG is $($dimensions.width)x$($dimensions.height)."
    } else {
      Add-Check $Id $Name "fail" $RelativePath "Expected ${ExpectedWidth}x${ExpectedHeight}; found $($dimensions.width)x$($dimensions.height)."
    }
  } catch {
    Add-Check $Id $Name "fail" $RelativePath $_.Exception.Message
  }
}

Test-TextPatterns `
  -Id "manifest-launcher-icon" `
  -Name "Manifest launcher icon wiring" `
  -RelativePath "companion/app-android/src/main/AndroidManifest.xml" `
  -Patterns @('android:icon="@mipmap/ic_launcher"', 'android:roundIcon="@mipmap/ic_launcher_round"', 'android:label="Stackchan Companion"')

Test-FilePresent "adaptive-icon" "Adaptive launcher icon" "companion/app-android/src/main/res/mipmap-anydpi-v26/ic_launcher.xml"
Test-FilePresent "round-adaptive-icon" "Round adaptive launcher icon" "companion/app-android/src/main/res/mipmap-anydpi-v26/ic_launcher_round.xml"
Test-FilePresent "icon-foreground" "Launcher foreground vector" "companion/app-android/src/main/res/drawable/ic_launcher_foreground.xml"
Test-FilePresent "icon-monochrome" "Launcher monochrome vector" "companion/app-android/src/main/res/drawable/ic_launcher_monochrome.xml"
Test-PngSize "play-icon-png" "Play high-resolution icon" "docs/store-assets/play/icon-512.png" 512 512
Test-PngSize "play-feature-graphic" "Play feature graphic" "docs/store-assets/play/feature-graphic-1024x500.png" 1024 500

Test-TextPatterns `
  -Id "gradle-play-signing" `
  -Name "Gradle Play upload signing inputs" `
  -RelativePath "companion/app-android/build.gradle.kts" `
  -Patterns @("STACKCHAN_ANDROID_KEYSTORE", "STACKCHAN_ANDROID_KEYSTORE_PASSWORD", "STACKCHAN_ANDROID_KEY_ALIAS", "STACKCHAN_ANDROID_KEY_PASSWORD", "playRelease", "isDebuggable = false")

Test-PlayUploadSigningEnvironment

Test-TextPatterns `
  -Id "ci-aab-build" `
  -Name "CI builds Android release bundle" `
  -RelativePath ".github/workflows/firmware.yml" `
  -Patterns @(":app-android:bundleRelease", "companion/app-android/build/outputs/bundle/release/*.aab")

Test-TextPatterns `
  -Id "release-evidence-aab" `
  -Name "Release evidence covers AAB signing" `
  -RelativePath "tools/export_companion_release_evidence.ps1" `
  -Patterns @("*.aab", "androidBundleSigning", "android-release-aab-signature", "jarsigner")

Test-TextPatterns `
  -Id "play-store-evidence-checker" `
  -Name "Play Store evidence checker" `
  -RelativePath "tools/check_android_play_store_evidence.ps1" `
  -Patterns @("stackchan.android-play-store-evidence.v1", "releaseAabSha256", "playSigningEnabled", "internalTestingInstallStatus", "screenshots", "DATA_SAFETY_REVIEW.md", "POLICY_REVIEW.md")

Test-TextPatterns `
  -Id "play-release-doc" `
  -Name "Play release checklist" `
  -RelativePath "docs/ANDROID_PLAY_RELEASE.md" `
  -Patterns @("Android Play Release Checklist", "app-android-release.aab", "Play App Signing", "feature-graphic-1024x500.png", "check_android_play_store_evidence.cmd", "Play Console internal testing", "RECORD_AUDIO")

foreach ($relativePath in @(
  "fastlane/metadata/android/en-US/title.txt",
  "fastlane/metadata/android/en-US/short_description.txt",
  "fastlane/metadata/android/en-US/full_description.txt",
  "fastlane/metadata/android/en-US/changelogs/1.txt"
)) {
  Test-FilePresent ("metadata-" + ($relativePath -replace "[^A-Za-z0-9]+", "-").Trim("-")) "Play listing metadata" $relativePath
}

$failedChecks = @($checks | Where-Object { $_.status -eq "fail" })
$pendingChecks = @($checks | Where-Object { $_.status -eq "pending" })
$status = if ($failedChecks.Count -gt 0) {
  "not-ready"
} elseif ($pendingChecks.Count -gt 0) {
  "source-ready-pending-upload-signing"
} else {
  "source-ready"
}
$report = [ordered]@{
  schema = "stackchan.android-play-release-readiness.v1"
  status = $status
  root = [string]$Root
  passed = @($checks | Where-Object { $_.status -eq "pass" }).Count
  pending = $pendingChecks.Count
  failed = $failedChecks.Count
  checks = @($checks)
}

if ($Json) {
  $report | ConvertTo-Json -Depth 8
} else {
  Write-Host "Android Play release readiness: $status"
  Write-Host "Passed: $($report.passed)  Pending: $($report.pending)  Failed: $($report.failed)"
  foreach ($check in $checks) {
    $prefix = if ($check.status -eq "pass") { "PASS" } elseif ($check.status -eq "pending") { "PENDING" } else { "FAIL" }
    Write-Host "[$prefix] $($check.name) - $($check.detail)"
  }
}

if ($failedChecks.Count -gt 0) {
  exit 1
}
