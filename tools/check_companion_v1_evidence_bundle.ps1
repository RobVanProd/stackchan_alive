param(
  [string]$Root = "",
  [string]$EvidenceRoot = "output/companion-v1-evidence/latest",
  [switch]$WriteTemplate,
  [switch]$RequireReady,
  [switch]$Json
)

$ErrorActionPreference = "Stop"

if ([string]::IsNullOrWhiteSpace($Root)) {
  $Root = Resolve-Path (Join-Path $PSScriptRoot "..")
} else {
  $Root = Resolve-Path $Root
}

Set-Location $Root

if (-not [System.IO.Path]::IsPathRooted($EvidenceRoot)) {
  $EvidenceRoot = Join-Path $Root $EvidenceRoot
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

function Convert-ToRelativePath {
  param([string]$Path)

  if ([string]::IsNullOrWhiteSpace($Path)) {
    return ""
  }

  $full = [System.IO.Path]::GetFullPath($Path)
  $rootFull = [System.IO.Path]::GetFullPath([string]$Root)
  if ($full.StartsWith($rootFull, [System.StringComparison]::OrdinalIgnoreCase)) {
    return $full.Substring($rootFull.Length).TrimStart("\", "/") -replace "\\", "/"
  }
  return $full -replace "\\", "/"
}

function Resolve-EvidencePath {
  param([string]$Path)

  if ([string]::IsNullOrWhiteSpace($Path)) {
    return ""
  }
  if ([System.IO.Path]::IsPathRooted($Path)) {
    return $Path
  }
  return Join-Path $EvidenceRoot $Path
}

function Get-Field {
  param(
    [object]$Object,
    [string]$Name
  )

  if ($null -eq $Object) {
    return $null
  }
  $property = $Object.PSObject.Properties[$Name]
  if ($null -eq $property) {
    return $null
  }
  return $property.Value
}

function Read-JsonOrNull {
  param([string]$Path)

  if ([string]::IsNullOrWhiteSpace($Path) -or -not (Test-Path -LiteralPath $Path -PathType Leaf)) {
    return $null
  }
  return Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json
}

function Test-Hash {
  param([string]$Value)
  return $Value -match "^[a-fA-F0-9]{64}$"
}

function Get-Sha256Text {
  param([string]$Path)

  if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
    return ""
  }
  return (Get-FileHash -Algorithm SHA256 -LiteralPath $Path).Hash.ToLowerInvariant()
}

function Test-Commit {
  param([string]$Value)
  return $Value -match "^[a-fA-F0-9]{40}$"
}

function Get-ReviewSourceCommit {
  param([string]$Text)

  $match = [regex]::Match($Text, "(?im)^-\s*Source commit:\s*([a-fA-F0-9]{40})\s*$")
  if ($match.Success) {
    return $match.Groups[1].Value
  }
  return ""
}

function Get-ReviewReleaseVersion {
  param([string]$Text)

  $match = [regex]::Match($Text, "(?im)^-\s*Release version:\s*(\S+)\s*$")
  if ($match.Success) {
    return $match.Groups[1].Value
  }
  return ""
}

function Test-ReportStatus {
  param(
    [string]$Id,
    [string]$Name,
    [object]$Reports,
    [string]$Field,
    [string]$ExpectedSchema,
    [string]$ExpectedStatus
  )

  $relativePath = [string](Get-Field $Reports $Field)
  $path = Resolve-EvidencePath $relativePath
  if ([string]::IsNullOrWhiteSpace($relativePath)) {
    Add-Check $Id $Name "pending" "" "Record reports.$Field in COMPANION_V1_EVIDENCE_BUNDLE.json."
    return
  }
  if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
    Add-Check $Id $Name "pending" (Convert-ToRelativePath $path) "Missing report file."
    return
  }

  try {
    $report = Read-JsonOrNull $path
  } catch {
    Add-Check $Id $Name "fail" (Convert-ToRelativePath $path) "Report JSON does not parse: $($_.Exception.Message)"
    return
  }

  if ($report.schema -ne $ExpectedSchema) {
    Add-Check $Id $Name "fail" (Convert-ToRelativePath $path) "Expected schema $ExpectedSchema, got $($report.schema)."
    return
  }
  if ($report.status -ne $ExpectedStatus) {
    $statusType = if ([string]$report.status -like "pending*" -or [string]$report.status -like "blocked*" -or [string]$report.status -eq "not-ready") { "pending" } else { "fail" }
    Add-Check $Id $Name $statusType (Convert-ToRelativePath $path) "Expected status $ExpectedStatus, got $($report.status)."
    return
  }

  Add-Check $Id $Name "pass" (Convert-ToRelativePath $path) "Report is $ExpectedStatus."
}

function Test-ReportFieldEquals {
  param(
    [string]$Id,
    [string]$Name,
    [object]$Reports,
    [string]$Field,
    [string]$ReportProperty,
    [string]$ExpectedValue,
    [string]$ExpectedLabel
  )

  $relativePath = [string](Get-Field $Reports $Field)
  $path = Resolve-EvidencePath $relativePath
  if ([string]::IsNullOrWhiteSpace($ExpectedValue) -or $ExpectedValue -match "<|TBD|pending") {
    Add-Check $Id $Name "pending" "COMPANION_V1_EVIDENCE_BUNDLE.json" "Record $ExpectedLabel before checking report consistency."
    return
  }
  if ([string]::IsNullOrWhiteSpace($relativePath)) {
    Add-Check $Id $Name "pending" "" "Record reports.$Field in COMPANION_V1_EVIDENCE_BUNDLE.json."
    return
  }
  if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
    Add-Check $Id $Name "pending" (Convert-ToRelativePath $path) "Missing report file."
    return
  }

  try {
    $report = Read-JsonOrNull $path
  } catch {
    Add-Check $Id $Name "fail" (Convert-ToRelativePath $path) "Report JSON does not parse: $($_.Exception.Message)"
    return
  }

  $actual = [string](Get-Field $report $ReportProperty)
  if ([string]::IsNullOrWhiteSpace($actual)) {
    Add-Check $Id $Name "fail" (Convert-ToRelativePath $path) "Report is missing $ReportProperty."
  } elseif ($actual -eq $ExpectedValue) {
    Add-Check $Id $Name "pass" (Convert-ToRelativePath $path) "Report $ReportProperty matches $ExpectedLabel."
  } else {
    Add-Check $Id $Name "fail" (Convert-ToRelativePath $path) "Expected $ReportProperty=$ExpectedValue, got $actual."
  }
}

function Convert-ToAndroidVersionName {
  param([string]$ReleaseVersion)

  $value = ([string]$ReleaseVersion).Trim()
  if ($value -match "^[vV](?=\d)") {
    return $value.Substring(1)
  }
  return $value
}

function Get-AndroidSourceVersionCode {
  $gradlePath = Join-Path $Root "companion/app-android/build.gradle.kts"
  if (-not (Test-Path -LiteralPath $gradlePath -PathType Leaf)) {
    return [ordered]@{
      status = "pending"
      value = ""
      evidence = Convert-ToRelativePath $gradlePath
      detail = "Missing Android Gradle build file."
    }
  }

  $text = Get-Content -LiteralPath $gradlePath -Raw
  $matches = [regex]::Matches($text, "(?m)^\s*versionCode\s*=\s*([1-9]\d*)\s*$")
  if ($matches.Count -ne 1) {
    return [ordered]@{
      status = "fail"
      value = ""
      evidence = Convert-ToRelativePath $gradlePath
      detail = "Expected exactly one literal Android versionCode declaration."
    }
  }

  return [ordered]@{
    status = "pass"
    value = $matches[0].Groups[1].Value
    evidence = Convert-ToRelativePath $gradlePath
    detail = "Android source versionCode parsed."
  }
}

function Test-AndroidVersionNameMatchesRelease {
  param(
    [object]$Reports,
    [string]$ReleaseVersion
  )

  $expectedVersionName = Convert-ToAndroidVersionName $ReleaseVersion
  $relativePath = [string](Get-Field $Reports "androidV1BundleReport")
  $path = Resolve-EvidencePath $relativePath
  if ([string]::IsNullOrWhiteSpace($expectedVersionName) -or $expectedVersionName -match "<|TBD|pending") {
    Add-Check "android-v1-version-name-match" "Android v1 app version matches release version" "pending" "COMPANION_V1_EVIDENCE_BUNDLE.json" "Record releaseVersion before checking Android app identity."
    return
  }
  if ([string]::IsNullOrWhiteSpace($relativePath)) {
    Add-Check "android-v1-version-name-match" "Android v1 app version matches release version" "pending" "" "Record reports.androidV1BundleReport in COMPANION_V1_EVIDENCE_BUNDLE.json."
    return
  }
  if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
    Add-Check "android-v1-version-name-match" "Android v1 app version matches release version" "pending" (Convert-ToRelativePath $path) "Missing Android v1 bundle report."
    return
  }

  try {
    $report = Read-JsonOrNull $path
  } catch {
    Add-Check "android-v1-version-name-match" "Android v1 app version matches release version" "fail" (Convert-ToRelativePath $path) "Report JSON does not parse: $($_.Exception.Message)"
    return
  }

  $actualVersionName = [string](Get-Field $report "versionName")
  if ([string]::IsNullOrWhiteSpace($actualVersionName)) {
    Add-Check "android-v1-version-name-match" "Android v1 app version matches release version" "fail" (Convert-ToRelativePath $path) "Android v1 bundle report is missing versionName."
  } elseif ($actualVersionName -eq $expectedVersionName) {
    Add-Check "android-v1-version-name-match" "Android v1 app version matches release version" "pass" (Convert-ToRelativePath $path) "Android versionName matches releaseVersion."
  } else {
    Add-Check "android-v1-version-name-match" "Android v1 app version matches release version" "fail" (Convert-ToRelativePath $path) "Expected Android versionName=$expectedVersionName from releaseVersion $ReleaseVersion, got $actualVersionName."
  }
}

function Test-AndroidVersionCodeMatchesSource {
  param([object]$Reports)

  $relativePath = [string](Get-Field $Reports "androidV1BundleReport")
  $path = Resolve-EvidencePath $relativePath
  if ([string]::IsNullOrWhiteSpace($relativePath)) {
    Add-Check "android-v1-version-code-match" "Android v1 app versionCode matches source" "pending" "" "Record reports.androidV1BundleReport in COMPANION_V1_EVIDENCE_BUNDLE.json."
    return
  }
  if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
    Add-Check "android-v1-version-code-match" "Android v1 app versionCode matches source" "pending" (Convert-ToRelativePath $path) "Missing Android v1 bundle report."
    return
  }

  try {
    $report = Read-JsonOrNull $path
  } catch {
    Add-Check "android-v1-version-code-match" "Android v1 app versionCode matches source" "fail" (Convert-ToRelativePath $path) "Report JSON does not parse: $($_.Exception.Message)"
    return
  }

  $actualVersionCode = [string](Get-Field $report "versionCode")
  if ($actualVersionCode -notmatch "^[1-9]\d*$") {
    Add-Check "android-v1-version-code-match" "Android v1 app versionCode matches source" "fail" (Convert-ToRelativePath $path) "Android v1 bundle report is missing a positive numeric versionCode."
    return
  }

  $sourceVersionCode = Get-AndroidSourceVersionCode
  if ($sourceVersionCode.status -ne "pass") {
    Add-Check "android-v1-version-code-match" "Android v1 app versionCode matches source" $sourceVersionCode.status $sourceVersionCode.evidence $sourceVersionCode.detail
    return
  }

  if ($actualVersionCode -eq $sourceVersionCode.value) {
    Add-Check "android-v1-version-code-match" "Android v1 app versionCode matches source" "pass" $sourceVersionCode.evidence "Android versionCode matches the source Gradle release configuration."
  } else {
    Add-Check "android-v1-version-code-match" "Android v1 app versionCode matches source" "fail" (Convert-ToRelativePath $path) "Expected Android versionCode=$($sourceVersionCode.value) from companion/app-android/build.gradle.kts, got $actualVersionCode."
  }
}

function Test-AndroidReleaseAabHashMatchesReleaseEvidence {
  param([object]$Reports)

  $androidRelativePath = [string](Get-Field $Reports "androidV1BundleReport")
  $androidPath = Resolve-EvidencePath $androidRelativePath
  if ([string]::IsNullOrWhiteSpace($androidRelativePath)) {
    Add-Check "android-v1-release-aab-hash-match" "Android v1 release AAB hash matches release evidence" "pending" "" "Record reports.androidV1BundleReport in COMPANION_V1_EVIDENCE_BUNDLE.json."
    return
  }
  if (-not (Test-Path -LiteralPath $androidPath -PathType Leaf)) {
    Add-Check "android-v1-release-aab-hash-match" "Android v1 release AAB hash matches release evidence" "pending" (Convert-ToRelativePath $androidPath) "Missing Android v1 bundle report."
    return
  }

  $releaseRelativePath = [string](Get-Field $Reports "companionReleaseEvidenceReport")
  $releasePath = Resolve-EvidencePath $releaseRelativePath
  if ([string]::IsNullOrWhiteSpace($releaseRelativePath)) {
    Add-Check "android-v1-release-aab-hash-match" "Android v1 release AAB hash matches release evidence" "pending" "" "Record reports.companionReleaseEvidenceReport in COMPANION_V1_EVIDENCE_BUNDLE.json."
    return
  }
  if (-not (Test-Path -LiteralPath $releasePath -PathType Leaf)) {
    Add-Check "android-v1-release-aab-hash-match" "Android v1 release AAB hash matches release evidence" "pending" (Convert-ToRelativePath $releasePath) "Missing Companion release evidence report."
    return
  }

  try {
    $androidReport = Read-JsonOrNull $androidPath
    $releaseReport = Read-JsonOrNull $releasePath
  } catch {
    Add-Check "android-v1-release-aab-hash-match" "Android v1 release AAB hash matches release evidence" "fail" "reports" "Report JSON does not parse: $($_.Exception.Message)"
    return
  }

  $expectedHash = ([string](Get-Field $androidReport "releaseAabSha256")).ToLowerInvariant()
  if (-not (Test-Hash $expectedHash)) {
    Add-Check "android-v1-release-aab-hash-match" "Android v1 release AAB hash matches release evidence" "fail" (Convert-ToRelativePath $androidPath) "Android v1 bundle report is missing a valid releaseAabSha256."
    return
  }

  $releaseAabHashes = @()
  foreach ($group in @($releaseReport.artifacts)) {
    foreach ($entry in @($group.entries)) {
      $entryPath = [string](Get-Field $entry "path")
      $entryName = [string](Get-Field $entry "name")
      if ($entryPath.EndsWith(".aab", [System.StringComparison]::OrdinalIgnoreCase) -or $entryName.EndsWith(".aab", [System.StringComparison]::OrdinalIgnoreCase)) {
        $entrySha = ([string](Get-Field $entry "sha256")).ToLowerInvariant()
        if (Test-Hash $entrySha) {
          $releaseAabHashes += $entrySha
        }
      }
    }
  }

  if ($releaseAabHashes.Count -eq 0) {
    Add-Check "android-v1-release-aab-hash-match" "Android v1 release AAB hash matches release evidence" "fail" (Convert-ToRelativePath $releasePath) "Companion release evidence does not list a release AAB artifact hash."
  } elseif ($releaseAabHashes -contains $expectedHash) {
    Add-Check "android-v1-release-aab-hash-match" "Android v1 release AAB hash matches release evidence" "pass" (Convert-ToRelativePath $releasePath) "Android Play releaseAabSha256 matches the release evidence artifact hash."
  } else {
    Add-Check "android-v1-release-aab-hash-match" "Android v1 release AAB hash matches release evidence" "fail" (Convert-ToRelativePath $releasePath) "Expected release evidence to include AAB SHA-256 $expectedHash."
  }
}

function Test-AndroidReleaseApkHashMatchesReleaseEvidence {
  param([object]$Reports)

  $androidRelativePath = [string](Get-Field $Reports "androidV1BundleReport")
  $androidPath = Resolve-EvidencePath $androidRelativePath
  if ([string]::IsNullOrWhiteSpace($androidRelativePath)) {
    Add-Check "android-v1-release-apk-hash-match" "Android v1 installed APK hash matches release evidence" "pending" "" "Record reports.androidV1BundleReport in COMPANION_V1_EVIDENCE_BUNDLE.json."
    return
  }
  if (-not (Test-Path -LiteralPath $androidPath -PathType Leaf)) {
    Add-Check "android-v1-release-apk-hash-match" "Android v1 installed APK hash matches release evidence" "pending" (Convert-ToRelativePath $androidPath) "Missing Android v1 bundle report."
    return
  }

  $releaseRelativePath = [string](Get-Field $Reports "companionReleaseEvidenceReport")
  $releasePath = Resolve-EvidencePath $releaseRelativePath
  if ([string]::IsNullOrWhiteSpace($releaseRelativePath)) {
    Add-Check "android-v1-release-apk-hash-match" "Android v1 installed APK hash matches release evidence" "pending" "" "Record reports.companionReleaseEvidenceReport in COMPANION_V1_EVIDENCE_BUNDLE.json."
    return
  }
  if (-not (Test-Path -LiteralPath $releasePath -PathType Leaf)) {
    Add-Check "android-v1-release-apk-hash-match" "Android v1 installed APK hash matches release evidence" "pending" (Convert-ToRelativePath $releasePath) "Missing Companion release evidence report."
    return
  }

  try {
    $androidReport = Read-JsonOrNull $androidPath
    $releaseReport = Read-JsonOrNull $releasePath
  } catch {
    Add-Check "android-v1-release-apk-hash-match" "Android v1 installed APK hash matches release evidence" "fail" "reports" "Report JSON does not parse: $($_.Exception.Message)"
    return
  }

  $expectedHash = ([string](Get-Field $androidReport "apkSha256")).ToLowerInvariant()
  if (-not (Test-Hash $expectedHash)) {
    Add-Check "android-v1-release-apk-hash-match" "Android v1 installed APK hash matches release evidence" "fail" (Convert-ToRelativePath $androidPath) "Android v1 bundle report is missing a valid apkSha256."
    return
  }

  $releaseApkHashes = @()
  foreach ($group in @($releaseReport.artifacts)) {
    foreach ($entry in @($group.entries)) {
      $entryPath = [string](Get-Field $entry "path")
      $entryName = [string](Get-Field $entry "name")
      $candidateName = "$entryPath $entryName"
      $isApk = $entryPath.EndsWith(".apk", [System.StringComparison]::OrdinalIgnoreCase) -or $entryName.EndsWith(".apk", [System.StringComparison]::OrdinalIgnoreCase)
      $isRelease = $candidateName -match "(?i)release" -and $candidateName -notmatch "(?i)debug"
      if ($isApk -and $isRelease) {
        $entrySha = ([string](Get-Field $entry "sha256")).ToLowerInvariant()
        if (Test-Hash $entrySha) {
          $releaseApkHashes += $entrySha
        }
      }
    }
  }

  if ($releaseApkHashes.Count -eq 0) {
    Add-Check "android-v1-release-apk-hash-match" "Android v1 installed APK hash matches release evidence" "fail" (Convert-ToRelativePath $releasePath) "Companion release evidence does not list a release APK artifact hash."
  } elseif ($releaseApkHashes -contains $expectedHash) {
    Add-Check "android-v1-release-apk-hash-match" "Android v1 installed APK hash matches release evidence" "pass" (Convert-ToRelativePath $releasePath) "Installed target-phone apkSha256 matches the release APK artifact hash."
  } else {
    Add-Check "android-v1-release-apk-hash-match" "Android v1 installed APK hash matches release evidence" "fail" (Convert-ToRelativePath $releasePath) "Expected release evidence to include release APK SHA-256 $expectedHash."
  }
}

function Test-DesktopArtifactHashesMatchReleaseEvidence {
  param([object]$Reports)

  $desktopRelativePath = [string](Get-Field $Reports "desktopV1BundleReport")
  $desktopPath = Resolve-EvidencePath $desktopRelativePath
  if ([string]::IsNullOrWhiteSpace($desktopRelativePath)) {
    Add-Check "desktop-v1-artifact-hashes-match" "Desktop v1 package hashes match release evidence" "pending" "" "Record reports.desktopV1BundleReport in COMPANION_V1_EVIDENCE_BUNDLE.json."
    return
  }
  if (-not (Test-Path -LiteralPath $desktopPath -PathType Leaf)) {
    Add-Check "desktop-v1-artifact-hashes-match" "Desktop v1 package hashes match release evidence" "pending" (Convert-ToRelativePath $desktopPath) "Missing Desktop v1 bundle report."
    return
  }

  $releaseRelativePath = [string](Get-Field $Reports "companionReleaseEvidenceReport")
  $releasePath = Resolve-EvidencePath $releaseRelativePath
  if ([string]::IsNullOrWhiteSpace($releaseRelativePath)) {
    Add-Check "desktop-v1-artifact-hashes-match" "Desktop v1 package hashes match release evidence" "pending" "" "Record reports.companionReleaseEvidenceReport in COMPANION_V1_EVIDENCE_BUNDLE.json."
    return
  }
  if (-not (Test-Path -LiteralPath $releasePath -PathType Leaf)) {
    Add-Check "desktop-v1-artifact-hashes-match" "Desktop v1 package hashes match release evidence" "pending" (Convert-ToRelativePath $releasePath) "Missing Companion release evidence report."
    return
  }

  try {
    $desktopReport = Read-JsonOrNull $desktopPath
    $releaseReport = Read-JsonOrNull $releasePath
  } catch {
    Add-Check "desktop-v1-artifact-hashes-match" "Desktop v1 package hashes match release evidence" "fail" "reports" "Report JSON does not parse: $($_.Exception.Message)"
    return
  }

  $required = @(
    [ordered]@{ property = "windowsMsiSha256"; extension = ".msi"; label = "Windows MSI" },
    [ordered]@{ property = "macosDmgSha256"; extension = ".dmg"; label = "macOS DMG" },
    [ordered]@{ property = "linuxDebSha256"; extension = ".deb"; label = "Linux DEB" }
  )
  $releaseHashesByExtension = @{}
  foreach ($group in @($releaseReport.artifacts)) {
    foreach ($entry in @($group.entries)) {
      $entryPath = [string](Get-Field $entry "path")
      $entryName = [string](Get-Field $entry "name")
      $entrySha = ([string](Get-Field $entry "sha256")).ToLowerInvariant()
      if (-not (Test-Hash $entrySha)) {
        continue
      }
      foreach ($item in $required) {
        if ($entryPath.EndsWith($item.extension, [System.StringComparison]::OrdinalIgnoreCase) -or $entryName.EndsWith($item.extension, [System.StringComparison]::OrdinalIgnoreCase)) {
          if (-not $releaseHashesByExtension.ContainsKey($item.extension)) {
            $releaseHashesByExtension[$item.extension] = @()
          }
          $releaseHashesByExtension[$item.extension] += $entrySha
        }
      }
    }
  }

  $issues = @()
  foreach ($item in $required) {
    $expectedHash = ([string](Get-Field $desktopReport $item.property)).ToLowerInvariant()
    if (-not (Test-Hash $expectedHash)) {
      $issues += "Desktop v1 bundle report is missing a valid $($item.property)."
      continue
    }
    if (-not $releaseHashesByExtension.ContainsKey($item.extension) -or @($releaseHashesByExtension[$item.extension]).Count -eq 0) {
      $issues += "Companion release evidence does not list a $($item.label) artifact hash."
      continue
    }
    if (@($releaseHashesByExtension[$item.extension]) -notcontains $expectedHash) {
      $issues += "Release evidence does not include $($item.label) SHA-256 $expectedHash."
    }
  }

  if ($issues.Count -eq 0) {
    Add-Check "desktop-v1-artifact-hashes-match" "Desktop v1 package hashes match release evidence" "pass" (Convert-ToRelativePath $releasePath) "Desktop package hashes match release evidence artifacts."
  } else {
    Add-Check "desktop-v1-artifact-hashes-match" "Desktop v1 package hashes match release evidence" "fail" (Convert-ToRelativePath $releasePath) ($issues -join " ")
  }
}

function Test-ReleasePackageEvidencePresent {
  param([object]$Reports)

  $releaseRelativePath = [string](Get-Field $Reports "companionReleaseEvidenceReport")
  $releasePath = Resolve-EvidencePath $releaseRelativePath
  if ([string]::IsNullOrWhiteSpace($releaseRelativePath)) {
    Add-Check "release-package-evidence-present" "Release package evidence is attached to release evidence" "pending" "" "Record reports.companionReleaseEvidenceReport in COMPANION_V1_EVIDENCE_BUNDLE.json."
    return
  }
  if (-not (Test-Path -LiteralPath $releasePath -PathType Leaf)) {
    Add-Check "release-package-evidence-present" "Release package evidence is attached to release evidence" "pending" (Convert-ToRelativePath $releasePath) "Missing Companion release evidence report."
    return
  }

  try {
    $releaseReport = Read-JsonOrNull $releasePath
  } catch {
    Add-Check "release-package-evidence-present" "Release package evidence is attached to release evidence" "fail" (Convert-ToRelativePath $releasePath) "Report JSON does not parse: $($_.Exception.Message)"
    return
  }

  $packageEvidence = Get-Field $releaseReport "packageEvidence"
  $issues = @()
  if ($null -eq $packageEvidence) {
    $issues += "Companion release evidence is missing packageEvidence."
  } elseif ([string](Get-Field $packageEvidence "status") -ne "present") {
    $issues += "packageEvidence.status must be present."
  }

  $requiredFiles = @(
    "release_manifest.json",
    "release_assets.json",
    "COMPANION_RELEASE_EVIDENCE.json",
    "docs/COMPANION_CROSS_PLATFORM_PLAN.md"
  )
  $filesByPath = @{}
  foreach ($file in @((Get-Field $packageEvidence "files"))) {
    $filePath = [string](Get-Field $file "path")
    if (-not [string]::IsNullOrWhiteSpace($filePath)) {
      $filesByPath[$filePath] = $file
    }
  }

  foreach ($requiredFile in $requiredFiles) {
    if (-not $filesByPath.ContainsKey($requiredFile)) {
      $issues += "packageEvidence.files missing $requiredFile."
      continue
    }
    $file = $filesByPath[$requiredFile]
    [int64]$bytes = 0
    [void][int64]::TryParse([string](Get-Field $file "bytes"), [ref]$bytes)
    $sha256 = [string](Get-Field $file "sha256")
    if ($bytes -le 0) {
      $issues += "packageEvidence file $requiredFile has invalid bytes."
    }
    if (-not (Test-Hash $sha256)) {
      $issues += "packageEvidence file $requiredFile has invalid SHA-256."
    }
  }

  if ($issues.Count -eq 0) {
    Add-Check "release-package-evidence-present" "Release package evidence is attached to release evidence" "pass" (Convert-ToRelativePath $releasePath) "Release evidence includes hashed package core files."
  } else {
    Add-Check "release-package-evidence-present" "Release package evidence is attached to release evidence" "fail" (Convert-ToRelativePath $releasePath) ($issues -join " ")
  }
}

function Convert-ToComparablePath {
  param([string]$Path)

  if ([string]::IsNullOrWhiteSpace($Path) -or $Path -match "<|TBD|pending") {
    return ""
  }
  $candidate = if ([System.IO.Path]::IsPathRooted($Path)) { $Path } else { Join-Path $Root $Path }
  return ([System.IO.Path]::GetFullPath($candidate).TrimEnd("\", "/") -replace "\\", "/").ToLowerInvariant()
}

function Test-RolloutHardwareEvidence {
  param(
    [object]$Reports,
    [string]$ExpectedHardwareRoot,
    [string]$ExpectedCommit
  )

  $relativePath = [string](Get-Field $Reports "rolloutStatusReport")
  $path = Resolve-EvidencePath $relativePath
  if ([string]::IsNullOrWhiteSpace($relativePath)) {
    Add-Check "rollout-hardware-root-match" "Rollout hardware evidence root matches bundle" "pending" "" "Record reports.rolloutStatusReport in COMPANION_V1_EVIDENCE_BUNDLE.json."
    Add-Check "rollout-hardware-commit-match" "Rollout hardware evidence commit matches bundle" "pending" "" "Record reports.rolloutStatusReport in COMPANION_V1_EVIDENCE_BUNDLE.json."
    return
  }
  if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
    Add-Check "rollout-hardware-root-match" "Rollout hardware evidence root matches bundle" "pending" (Convert-ToRelativePath $path) "Missing rollout status report."
    Add-Check "rollout-hardware-commit-match" "Rollout hardware evidence commit matches bundle" "pending" (Convert-ToRelativePath $path) "Missing rollout status report."
    return
  }

  try {
    $report = Read-JsonOrNull $path
  } catch {
    Add-Check "rollout-hardware-root-match" "Rollout hardware evidence root matches bundle" "fail" (Convert-ToRelativePath $path) "Report JSON does not parse: $($_.Exception.Message)"
    Add-Check "rollout-hardware-commit-match" "Rollout hardware evidence commit matches bundle" "fail" (Convert-ToRelativePath $path) "Report JSON does not parse: $($_.Exception.Message)"
    return
  }

  $actualHardwareRoot = [string](Get-Field $report "evidenceRoot")
  $expectedComparable = Convert-ToComparablePath $ExpectedHardwareRoot
  $actualComparable = Convert-ToComparablePath $actualHardwareRoot
  if ([string]::IsNullOrWhiteSpace($expectedComparable)) {
    Add-Check "rollout-hardware-root-match" "Rollout hardware evidence root matches bundle" "pending" "COMPANION_V1_EVIDENCE_BUNDLE.json" "Record hardwareEvidenceRoot before checking rollout evidence consistency."
  } elseif ([string]::IsNullOrWhiteSpace($actualComparable)) {
    Add-Check "rollout-hardware-root-match" "Rollout hardware evidence root matches bundle" "fail" (Convert-ToRelativePath $path) "Rollout status report is missing evidenceRoot."
  } elseif ($actualComparable -eq $expectedComparable) {
    Add-Check "rollout-hardware-root-match" "Rollout hardware evidence root matches bundle" "pass" (Convert-ToRelativePath $path) "Rollout status evidenceRoot matches hardwareEvidenceRoot."
  } else {
    Add-Check "rollout-hardware-root-match" "Rollout hardware evidence root matches bundle" "fail" (Convert-ToRelativePath $path) "Expected hardwareEvidenceRoot=$ExpectedHardwareRoot, got $actualHardwareRoot."
  }

  $evidence = Get-Field $report "evidence"
  $metadata = Get-Field $evidence "metadata"
  $actualEvidenceCommit = [string](Get-Field $metadata "commit")
  if ([string]::IsNullOrWhiteSpace($ExpectedCommit) -or $ExpectedCommit -match "<|TBD|pending") {
    Add-Check "rollout-hardware-commit-match" "Rollout hardware evidence commit matches bundle" "pending" "COMPANION_V1_EVIDENCE_BUNDLE.json" "Record sourceCommit before checking rollout hardware evidence consistency."
  } elseif ([string]::IsNullOrWhiteSpace($actualEvidenceCommit)) {
    Add-Check "rollout-hardware-commit-match" "Rollout hardware evidence commit matches bundle" "fail" (Convert-ToRelativePath $path) "Rollout status report is missing evidence.metadata.commit."
  } elseif ($actualEvidenceCommit -eq $ExpectedCommit) {
    Add-Check "rollout-hardware-commit-match" "Rollout hardware evidence commit matches bundle" "pass" (Convert-ToRelativePath $path) "Rollout hardware evidence commit matches sourceCommit."
  } else {
    Add-Check "rollout-hardware-commit-match" "Rollout hardware evidence commit matches bundle" "fail" (Convert-ToRelativePath $path) "Expected evidence.metadata.commit=$ExpectedCommit, got $actualEvidenceCommit."
  }
}

function Write-CompanionV1EvidenceTemplate {
  New-Item -ItemType Directory -Force -Path $EvidenceRoot | Out-Null
  New-Item -ItemType Directory -Force -Path (Join-Path $EvidenceRoot "reports") | Out-Null

  $template = [ordered]@{
    schema = "stackchan.companion-v1-evidence-bundle.v1"
    status = "pending"
    sourceCommit = "<40-character git commit>"
    releaseVersion = "<release version or tag>"
    releasePackage = [ordered]@{
      path = "artifacts/stackchan_alive_<version>.zip"
      sha256 = "<64-character sha256>"
    }
    hardwareEvidenceStatus = "pending"
    hardwareEvidenceRoot = "<output/hardware-evidence/...>"
    androidV1Status = "pending"
    desktopV1Status = "pending"
    reports = [ordered]@{
      companionReadinessReport = "reports/companion_v1_readiness.json"
      companionReleaseEvidenceReport = "reports/COMPANION_RELEASE_EVIDENCE.json"
      githubActionsStatusReport = "reports/github_actions_status.json"
      rolloutStatusReport = "reports/ROLLOUT_STATUS.json"
      androidV1BundleReport = "reports/android_v1_bundle_check.json"
      desktopV1BundleReport = "reports/desktop_v1_bundle_check.json"
      voiceSourceReadinessReport = "reports/voice_source_readiness.json"
    }
    reviewPath = "COMPANION_V1_REVIEW.md"
    notes = "Copy the platform bundle checker JSON, release evidence, CI status, rollout status, and voice-source readiness outputs into reports/, then rerun this aggregate gate."
  }
  $template | ConvertTo-Json -Depth 8 | Set-Content -Path (Join-Path $EvidenceRoot "COMPANION_V1_EVIDENCE_BUNDLE.json") -Encoding UTF8

  @"
# Companion V1 Evidence Bundle

This packet is the final aggregate Stackchan Companion v1 gate. It does not replace the
Android, desktop, hardware, Play, or voice-source gates; it proves their outputs have all
been collected for the same release candidate.

Required ready statuses:

- ``stackchan.companion-v1-readiness.v1``: ``source-ready-pending-hardware``
- ``stackchan.companion-release-evidence.v1``: ``complete``
- ``stackchan.github-actions-status.v1``: ``success``
- ``stackchan.rollout-status.v1``: ``consumer-promotion-ready``
- ``stackchan.android-v1-evidence-bundle-check.v1``: ``android-v1-evidence-ready`` with matching ``sourceCommit``
- ``stackchan.desktop-v1-evidence-bundle-check.v1``: ``desktop-v1-evidence-ready`` with matching ``sourceCommit``
- ``stackchan.voice-source-readiness.v1``: ``production-voice-source-ready`` with matching ``sourceCommit``
- Android ``versionName`` must match the release version, Android ``apkSha256`` must match
  a release APK artifact hash, Android ``versionCode`` must match the source Gradle release
  configuration, and Android ``releaseAabSha256`` must match a release evidence AAB artifact hash.
- Desktop MSI, DMG, and DEB hashes must match release evidence package artifact hashes.
- Release evidence ``packageEvidence`` must include hashed package core files from the extracted release package.
- Final release ZIP attachment with matching SHA-256, verified hardware evidence root, and ``COMPANION_V1_REVIEW.md``

Run:

````powershell
tools/check_companion_v1_evidence_bundle.cmd -EvidenceRoot output/companion-v1-evidence/latest -RequireReady -Json
````
"@ | Set-Content -Path (Join-Path $EvidenceRoot "COMPANION_V1_EVIDENCE_BUNDLE.md") -Encoding UTF8

  @"
# Companion V1 Review

Complete after Android, desktop, hardware, Play, voice-source, release, CI, and rollout
evidence are assembled for the same source commit and release package.

- Reviewer:
- Review date:
- Source commit:
- Release version:
- Overall companion v1 decision: pending
- Source/readiness decision: pending
- Release package decision: pending
- GitHub Actions decision: pending
- Android v1 decision: pending
- Desktop v1 decision: pending
- Physical robot evidence decision: pending
- Production voice-source decision: pending
- Play distribution decision: pending
"@ | Set-Content -Path (Join-Path $EvidenceRoot "COMPANION_V1_REVIEW.md") -Encoding UTF8
}

if ($WriteTemplate) {
  Write-CompanionV1EvidenceTemplate
}

$bundlePath = Join-Path $EvidenceRoot "COMPANION_V1_EVIDENCE_BUNDLE.json"
if (-not (Test-Path -LiteralPath $bundlePath -PathType Leaf)) {
  Add-Check "bundle-json" "Companion v1 evidence bundle JSON" "pending" (Convert-ToRelativePath $bundlePath) "Run with -WriteTemplate, then fill the bundle after Android, desktop, hardware, Play, voice, and release validation."
} else {
  Add-Check "bundle-json" "Companion v1 evidence bundle JSON" "pass" (Convert-ToRelativePath $bundlePath) "Bundle JSON exists."
  try {
    $bundle = Read-JsonOrNull $bundlePath
  } catch {
    Add-Check "bundle-json-parse" "Companion v1 evidence bundle JSON parses" "fail" (Convert-ToRelativePath $bundlePath) $_.Exception.Message
    $bundle = $null
  }

  if ($null -ne $bundle) {
    if ($bundle.schema -eq "stackchan.companion-v1-evidence-bundle.v1") {
      Add-Check "bundle-schema" "Bundle schema" "pass" "COMPANION_V1_EVIDENCE_BUNDLE.json" "Schema matches."
    } else {
      Add-Check "bundle-schema" "Bundle schema" "fail" "COMPANION_V1_EVIDENCE_BUNDLE.json" "Unexpected schema: $($bundle.schema)."
    }

    if (Test-Commit ([string]$bundle.sourceCommit)) {
      Add-Check "source-commit" "Source commit" "pass" "COMPANION_V1_EVIDENCE_BUNDLE.json" "Full source commit recorded."
    } else {
      Add-Check "source-commit" "Source commit" "pending" "COMPANION_V1_EVIDENCE_BUNDLE.json" "Record a full 40-character source commit."
    }

    $releaseVersion = [string]$bundle.releaseVersion
    if ([string]::IsNullOrWhiteSpace($releaseVersion) -or $releaseVersion -match "<|TBD|pending") {
      Add-Check "release-version" "Release version" "pending" "COMPANION_V1_EVIDENCE_BUNDLE.json" "Record the final release version or tag."
    } else {
      Add-Check "release-version" "Release version" "pass" "COMPANION_V1_EVIDENCE_BUNDLE.json" "Release version is recorded."
    }

    $releasePackage = Get-Field $bundle "releasePackage"
    $releasePackagePath = [string](Get-Field $releasePackage "path")
    $releasePackageSha = [string](Get-Field $releasePackage "sha256")
    if ([string]::IsNullOrWhiteSpace($releasePackagePath) -or $releasePackagePath -match "<|TBD|pending") {
      Add-Check "release-package" "Release package hash" "pending" "COMPANION_V1_EVIDENCE_BUNDLE.json" "Record the final release ZIP path."
    } elseif (-not $releasePackagePath.EndsWith(".zip", [System.StringComparison]::OrdinalIgnoreCase)) {
      Add-Check "release-package" "Release package hash" "fail" "COMPANION_V1_EVIDENCE_BUNDLE.json" "Expected a release ZIP path, got $releasePackagePath."
    } elseif ([string]::IsNullOrWhiteSpace($releasePackageSha) -or $releasePackageSha -match "<|TBD|pending") {
      Add-Check "release-package" "Release package hash" "pending" "COMPANION_V1_EVIDENCE_BUNDLE.json" "Record the final release ZIP SHA-256."
    } elseif (-not (Test-Hash $releasePackageSha)) {
      Add-Check "release-package" "Release package hash" "fail" "COMPANION_V1_EVIDENCE_BUNDLE.json" "Record a valid 64-character SHA-256 for the release ZIP."
    } else {
      $resolvedReleasePackagePath = Resolve-EvidencePath $releasePackagePath
      if (-not (Test-Path -LiteralPath $resolvedReleasePackagePath -PathType Leaf)) {
        Add-Check "release-package" "Release package hash" "pending" (Convert-ToRelativePath $resolvedReleasePackagePath) "Attach the final release ZIP under the evidence bundle so its SHA-256 can be verified."
      } else {
        $actualReleasePackageSha = Get-Sha256Text $resolvedReleasePackagePath
        if ($actualReleasePackageSha -eq $releasePackageSha.ToLowerInvariant()) {
          Add-Check "release-package" "Release package hash" "pass" (Convert-ToRelativePath $resolvedReleasePackagePath) "Release package ZIP SHA-256 matches the attached artifact."
        } else {
          Add-Check "release-package" "Release package hash" "fail" (Convert-ToRelativePath $resolvedReleasePackagePath) "Expected SHA-256 $releasePackageSha, got $actualReleasePackageSha."
        }
      }
    }

    if ([string]$bundle.hardwareEvidenceStatus -in @("verified", "pass", "passed") -and [string]$bundle.hardwareEvidenceRoot -notmatch "<|pending|TBD") {
      Add-Check "hardware-evidence" "Physical robot hardware evidence" "pass" "COMPANION_V1_EVIDENCE_BUNDLE.json" "Hardware evidence is recorded as verified."
    } else {
      Add-Check "hardware-evidence" "Physical robot hardware evidence" "pending" "COMPANION_V1_EVIDENCE_BUNDLE.json" "Record verified hardware evidence root after tools/verify_hardware_evidence.cmd passes."
    }

    if ([string]$bundle.androidV1Status -in @("verified", "pass", "passed", "ready")) {
      Add-Check "android-v1-status" "Android v1 status" "pass" "COMPANION_V1_EVIDENCE_BUNDLE.json" "Android v1 status is recorded as ready."
    } else {
      Add-Check "android-v1-status" "Android v1 status" "pending" "COMPANION_V1_EVIDENCE_BUNDLE.json" "Record Android v1 evidence readiness."
    }

    if ([string]$bundle.desktopV1Status -in @("verified", "pass", "passed", "ready")) {
      Add-Check "desktop-v1-status" "Desktop v1 status" "pass" "COMPANION_V1_EVIDENCE_BUNDLE.json" "Desktop v1 status is recorded as ready."
    } else {
      Add-Check "desktop-v1-status" "Desktop v1 status" "pending" "COMPANION_V1_EVIDENCE_BUNDLE.json" "Record desktop v1 evidence readiness."
    }

    $reports = Get-Field $bundle "reports"
    Test-ReportStatus "companion-readiness" "Companion source readiness report" $reports "companionReadinessReport" "stackchan.companion-v1-readiness.v1" "source-ready-pending-hardware"
    Test-ReportStatus "companion-release-evidence" "Companion release evidence report" $reports "companionReleaseEvidenceReport" "stackchan.companion-release-evidence.v1" "complete"
    Test-ReportStatus "github-actions" "GitHub Actions status report" $reports "githubActionsStatusReport" "stackchan.github-actions-status.v1" "success"
    Test-ReportStatus "rollout-status" "Rollout status report" $reports "rolloutStatusReport" "stackchan.rollout-status.v1" "consumer-promotion-ready"
    Test-ReportStatus "android-v1-bundle" "Android v1 evidence bundle report" $reports "androidV1BundleReport" "stackchan.android-v1-evidence-bundle-check.v1" "android-v1-evidence-ready"
    Test-ReportStatus "desktop-v1-bundle" "Desktop v1 evidence bundle report" $reports "desktopV1BundleReport" "stackchan.desktop-v1-evidence-bundle-check.v1" "desktop-v1-evidence-ready"
    Test-ReportStatus "voice-source-ready" "Production voice-source readiness report" $reports "voiceSourceReadinessReport" "stackchan.voice-source-readiness.v1" "production-voice-source-ready"
    Test-ReportFieldEquals "companion-readiness-commit-match" "Companion source readiness report matches bundle commit" $reports "companionReadinessReport" "sourceCommit" ([string]$bundle.sourceCommit) "sourceCommit"
    Test-ReportFieldEquals "release-evidence-commit-match" "Companion release evidence commit matches bundle" $reports "companionReleaseEvidenceReport" "commit" ([string]$bundle.sourceCommit) "sourceCommit"
    Test-ReportFieldEquals "github-actions-commit-match" "GitHub Actions commit matches bundle" $reports "githubActionsStatusReport" "commit" ([string]$bundle.sourceCommit) "sourceCommit"
    Test-ReportFieldEquals "rollout-status-commit-match" "Rollout status commit matches bundle" $reports "rolloutStatusReport" "commit" ([string]$bundle.sourceCommit) "sourceCommit"
    Test-ReportFieldEquals "android-v1-commit-match" "Android v1 bundle report matches bundle commit" $reports "androidV1BundleReport" "sourceCommit" ([string]$bundle.sourceCommit) "sourceCommit"
    Test-ReportFieldEquals "desktop-v1-commit-match" "Desktop v1 bundle report matches bundle commit" $reports "desktopV1BundleReport" "sourceCommit" ([string]$bundle.sourceCommit) "sourceCommit"
    Test-ReportFieldEquals "release-evidence-version-match" "Companion release evidence version matches bundle" $reports "companionReleaseEvidenceReport" "version" $releaseVersion "releaseVersion"
    Test-ReportFieldEquals "github-actions-version-match" "GitHub Actions version matches bundle" $reports "githubActionsStatusReport" "version" $releaseVersion "releaseVersion"
    Test-ReportFieldEquals "rollout-status-version-match" "Rollout status version matches bundle" $reports "rolloutStatusReport" "version" $releaseVersion "releaseVersion"
    Test-ReportFieldEquals "voice-source-commit-match" "Production voice-source readiness matches bundle commit" $reports "voiceSourceReadinessReport" "sourceCommit" ([string]$bundle.sourceCommit) "sourceCommit"
    Test-AndroidVersionNameMatchesRelease $reports $releaseVersion
    Test-AndroidVersionCodeMatchesSource $reports
    Test-AndroidReleaseApkHashMatchesReleaseEvidence $reports
    Test-AndroidReleaseAabHashMatchesReleaseEvidence $reports
    Test-DesktopArtifactHashesMatchReleaseEvidence $reports
    Test-ReleasePackageEvidencePresent $reports
    Test-RolloutHardwareEvidence $reports ([string]$bundle.hardwareEvidenceRoot) ([string]$bundle.sourceCommit)

    $reviewPath = Resolve-EvidencePath ([string]$bundle.reviewPath)
    if ([string]::IsNullOrWhiteSpace([string]$bundle.reviewPath) -or -not (Test-Path -LiteralPath $reviewPath -PathType Leaf)) {
      Add-Check "companion-v1-review" "Companion v1 human review" "pending" (Convert-ToRelativePath $reviewPath) "Complete COMPANION_V1_REVIEW.md."
    } else {
      $review = Get-Content -LiteralPath $reviewPath -Raw
      $requiredReviewPatterns = @(
        "Reviewer:",
        "Review date:",
        "Source commit:",
        "Release version:",
        "Overall companion v1 decision: pass",
        "Source/readiness decision: pass",
        "Release package decision: pass",
        "GitHub Actions decision: pass",
        "Android v1 decision: pass",
        "Desktop v1 decision: pass",
        "Physical robot evidence decision: pass",
        "Production voice-source decision: pass",
        "Play distribution decision: pass"
      )
      $missing = @($requiredReviewPatterns | Where-Object { $review -notmatch [regex]::Escape($_) })
      $reviewSourceCommit = Get-ReviewSourceCommit $review
      $reviewReleaseVersion = Get-ReviewReleaseVersion $review
      if ($missing.Count -eq 0 -and (Test-Commit $reviewSourceCommit) -and $reviewSourceCommit -eq [string]$bundle.sourceCommit -and $reviewReleaseVersion -eq $releaseVersion) {
        Add-Check "companion-v1-review" "Companion v1 human review" "pass" (Convert-ToRelativePath $reviewPath) "All companion v1 decisions are pass."
      } elseif ((Test-Commit $reviewSourceCommit) -and $reviewSourceCommit -ne [string]$bundle.sourceCommit) {
        Add-Check "companion-v1-review" "Companion v1 human review" "fail" (Convert-ToRelativePath $reviewPath) "Review Source commit $reviewSourceCommit does not match bundle sourceCommit $($bundle.sourceCommit)."
      } elseif (-not [string]::IsNullOrWhiteSpace($reviewReleaseVersion) -and $reviewReleaseVersion -ne $releaseVersion) {
        Add-Check "companion-v1-review" "Companion v1 human review" "fail" (Convert-ToRelativePath $reviewPath) "Review Release version $reviewReleaseVersion does not match bundle releaseVersion $releaseVersion."
      } else {
        $missingDetail = if ($missing.Count -eq 0) { "Source commit must be a full 40-character SHA matching bundle sourceCommit and Release version must match bundle releaseVersion." } else { "Missing review markers: " + ($missing -join ", ") }
        Add-Check "companion-v1-review" "Companion v1 human review" "pending" (Convert-ToRelativePath $reviewPath) $missingDetail
      }
    }
  }
}

$failedChecks = @($checks | Where-Object { $_.status -eq "fail" })
$pendingChecks = @($checks | Where-Object { $_.status -eq "pending" })
$passedChecks = @($checks | Where-Object { $_.status -eq "pass" })
$status = if ($failedChecks.Count -gt 0) { "not-ready" } elseif ($pendingChecks.Count -gt 0) { "pending-companion-v1-evidence-bundle" } else { "companion-v1-evidence-ready" }

$report = [ordered]@{
  schema = "stackchan.companion-v1-evidence-bundle-check.v1"
  status = $status
  root = [string]$Root
  evidenceRoot = Convert-ToRelativePath $EvidenceRoot
  sourceCommit = if ($null -ne $bundle) { [string]$bundle.sourceCommit } else { "" }
  releaseVersion = if ($null -ne $bundle) { [string]$bundle.releaseVersion } else { "" }
  passed = $passedChecks.Count
  failed = $failedChecks.Count
  pending = $pendingChecks.Count
  checks = @($checks)
}

if ($Json) {
  $report | ConvertTo-Json -Depth 8
} else {
  Write-Host "Companion v1 evidence bundle: $status"
  Write-Host "Evidence root: $(Convert-ToRelativePath $EvidenceRoot)"
  Write-Host "Passed: $($passedChecks.Count)  Failed: $($failedChecks.Count)  Pending: $($pendingChecks.Count)"
  foreach ($check in $checks) {
    $prefix = if ($check.status -eq "pass") { "PASS" } elseif ($check.status -eq "pending") { "PENDING" } else { "FAIL" }
    Write-Host "[$prefix] $($check.name) - $($check.detail)"
  }
}

if ($failedChecks.Count -gt 0 -or ($RequireReady -and $status -ne "companion-v1-evidence-ready")) {
  exit 1
}
