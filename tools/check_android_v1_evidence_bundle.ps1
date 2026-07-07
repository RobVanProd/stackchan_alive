param(
  [string]$Root = "",
  [string]$EvidenceRoot = "output/android-v1-evidence/latest",
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

function Test-Hash {
  param([string]$Value)
  return $Value -match "^[a-fA-F0-9]{64}$"
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

function Convert-ToDoubleOrNull {
  param([object]$Value)

  if ($null -eq $Value -or [string]::IsNullOrWhiteSpace([string]$Value)) {
    return $null
  }

  try {
    return [double]$Value
  } catch {
    return $null
  }
}

function Test-NonPlaceholder {
  param([string]$Value)
  return -not [string]::IsNullOrWhiteSpace($Value) -and $Value -notmatch "<|>|pending|TBD"
}

function Read-JsonOrNull {
  param([string]$Path)

  if ([string]::IsNullOrWhiteSpace($Path) -or -not (Test-Path -LiteralPath $Path -PathType Leaf)) {
    return $null
  }
  return Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json
}

function Test-MediaPath {
  param([string]$Path)

  if ([string]::IsNullOrWhiteSpace($Path)) {
    return "Media path is blank."
  }
  $fullPath = Resolve-EvidencePath $Path
  if (-not (Test-Path -LiteralPath $fullPath -PathType Leaf)) {
    return "Missing media file: $Path"
  }
  if ($fullPath -notmatch "\.(png|jpg|jpeg)$") {
    return "Media evidence must be PNG or JPEG: $Path"
  }
  if ((Get-Item -LiteralPath $fullPath).Length -lt 1024) {
    return "Media file is too small to be credible: $Path"
  }
  return ""
}

function Get-MediaId {
  param([object]$Media)

  $id = [string](Get-Field $Media "id")
  if (-not [string]::IsNullOrWhiteSpace($id)) {
    return $id
  }

  $path = [string](Get-Field $Media "path")
  if ([string]::IsNullOrWhiteSpace($path)) {
    return ""
  }
  return [System.IO.Path]::GetFileNameWithoutExtension($path)
}

function Test-AndroidDashboardEvidence {
  param([object]$Bundle)

  $status = [string](Get-Field $Bundle "androidDashboardEvidenceStatus")
  $root = [string](Get-Field $Bundle "androidDashboardEvidenceRoot")
  $media = @((Get-Field $Bundle "androidDashboardMedia") | Where-Object { $null -ne $_ })
  $requiredIds = @((Get-Field $Bundle "requiredScreenshotIds"))
  if ($requiredIds.Count -eq 0) {
    $requiredIds = @("phone-pairing-setup", "phone-live-dashboard", "phone-brain-model", "phone-personas-diagnostics")
  }

  $mediaIds = @($media | ForEach-Object { Get-MediaId $_ })
  $script:androidDashboardMediaIds = @($mediaIds | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) })
  $missingIds = @($requiredIds | Where-Object { $_ -notin $mediaIds })
  $issues = @()

  if ($status -notin @("verified", "pass", "passed")) {
    $issues += "Set androidDashboardEvidenceStatus to verified/pass only after final-build media review."
  }
  if (-not (Test-NonPlaceholder $root)) {
    $issues += "Record androidDashboardEvidenceRoot for the captured media packet."
  }
  if ($media.Count -eq 0) {
    $issues += "Record androidDashboardMedia entries."
  }
  if ($missingIds.Count -gt 0) {
    $issues += ("Missing required media IDs: " + ($missingIds -join ", "))
  }
  foreach ($item in $media) {
    $mediaId = Get-MediaId $item
    $issue = Test-MediaPath ([string](Get-Field $item "path"))
    if (-not [string]::IsNullOrWhiteSpace($issue)) {
      $issues += "${mediaId}: $issue"
    }
    if ([string](Get-Field $item "sourceCommit") -ne [string](Get-Field $Bundle "sourceCommit")) {
      $issues += "Media sourceCommit for $mediaId does not match bundle sourceCommit."
    }
    if ([string]::IsNullOrWhiteSpace([string](Get-Field $item "notes"))) {
      $issues += "Media notes are blank for $mediaId."
    }
  }

  if ($issues.Count -eq 0) {
    Add-Check "dashboard-evidence" "Android connected dashboard media" "pass" "ANDROID_V1_EVIDENCE_BUNDLE.json" "All required final-build dashboard/media IDs are present."
  } elseif ($status -in @("verified", "pass", "passed")) {
    Add-Check "dashboard-evidence" "Android connected dashboard media" "fail" "ANDROID_V1_EVIDENCE_BUNDLE.json" ($issues -join "; ")
  } else {
    Add-Check "dashboard-evidence" "Android connected dashboard media" "pending" "ANDROID_V1_EVIDENCE_BUNDLE.json" ($issues -join "; ")
  }
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
    Add-Check $Id $Name "pending" "" "Record $Field in ANDROID_V1_EVIDENCE_BUNDLE.json."
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
    $statusType = if ([string]$report.status -like "pending*" -or [string]$report.status -eq "not-ready") { "pending" } else { "fail" }
    Add-Check $Id $Name $statusType (Convert-ToRelativePath $path) "Expected status $ExpectedStatus, got $($report.status)."
    return
  }

  Add-Check $Id $Name "pass" (Convert-ToRelativePath $path) "Report is $ExpectedStatus."
}

function Test-GemmaBenchmarkEvidence {
  param([object]$Reports)

  $relativePath = [string](Get-Field $Reports "gemmaCheckReport")
  $path = Resolve-EvidencePath $relativePath
  if ([string]::IsNullOrWhiteSpace($relativePath)) {
    Add-Check "gemma-benchmark-profile" "Android Gemma benchmark profile evidence" "pending" "" "Record reports.gemmaCheckReport in ANDROID_V1_EVIDENCE_BUNDLE.json."
    Add-Check "gemma-benchmark-speed" "Android Gemma benchmark speed evidence" "pending" "" "Record reports.gemmaCheckReport in ANDROID_V1_EVIDENCE_BUNDLE.json."
    return
  }
  if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
    Add-Check "gemma-benchmark-profile" "Android Gemma benchmark profile evidence" "pending" (Convert-ToRelativePath $path) "Missing Gemma evidence report."
    Add-Check "gemma-benchmark-speed" "Android Gemma benchmark speed evidence" "pending" (Convert-ToRelativePath $path) "Missing Gemma evidence report."
    return
  }

  try {
    $report = Read-JsonOrNull $path
  } catch {
    Add-Check "gemma-benchmark-profile" "Android Gemma benchmark profile evidence" "fail" (Convert-ToRelativePath $path) "Gemma report JSON does not parse: $($_.Exception.Message)"
    Add-Check "gemma-benchmark-speed" "Android Gemma benchmark speed evidence" "fail" (Convert-ToRelativePath $path) "Gemma report JSON does not parse: $($_.Exception.Message)"
    return
  }

  $profile = [string](Get-Field $report "benchmarkProfile")
  $recommendedProfile = [string](Get-Field $report "benchmarkRecommendedProfile")
  $medianMs = Convert-ToDoubleOrNull (Get-Field $report "benchmarkMedianMs")
  $medianTokensPerSec = Convert-ToDoubleOrNull (Get-Field $report "benchmarkMedianTokensPerSec")
  $script:gemmaBenchmarkProfile = $profile
  $script:gemmaBenchmarkMedianMs = $medianMs
  $script:gemmaBenchmarkMedianTokensPerSec = $medianTokensPerSec

  if ($profile -eq "gemma4-e2b-litert-lm" -and $recommendedProfile -eq "gemma4-e2b-litert-lm") {
    Add-Check "gemma-benchmark-profile" "Android Gemma benchmark profile evidence" "pass" (Convert-ToRelativePath $path) "Gemma evidence report carries the required LiteRT-LM benchmark profile."
  } else {
    Add-Check "gemma-benchmark-profile" "Android Gemma benchmark profile evidence" "fail" (Convert-ToRelativePath $path) "Expected benchmarkProfile and benchmarkRecommendedProfile to be gemma4-e2b-litert-lm."
  }

  if ($null -ne $medianMs -and $medianMs -le 2500.0 -and $null -ne $medianTokensPerSec -and $medianTokensPerSec -ge 5.0) {
    Add-Check "gemma-benchmark-speed" "Android Gemma benchmark speed evidence" "pass" (Convert-ToRelativePath $path) "Gemma benchmark speed fields meet the Android v1 threshold."
  } else {
    Add-Check "gemma-benchmark-speed" "Android Gemma benchmark speed evidence" "fail" (Convert-ToRelativePath $path) "Expected benchmarkMedianMs <= 2500 and benchmarkMedianTokensPerSec >= 5."
  }
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
    Add-Check $Id $Name "pending" "ANDROID_V1_EVIDENCE_BUNDLE.json" "Record $ExpectedLabel before checking report consistency."
    return
  }
  if ([string]::IsNullOrWhiteSpace($relativePath)) {
    Add-Check $Id $Name "pending" "" "Record reports.$Field in ANDROID_V1_EVIDENCE_BUNDLE.json."
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

function Get-AndroidSourceApplicationId {
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
  $matches = [regex]::Matches($text, '(?m)^\s*applicationId\s*=\s*"([^"]+)"\s*$')
  if ($matches.Count -ne 1) {
    return [ordered]@{
      status = "fail"
      value = ""
      evidence = Convert-ToRelativePath $gradlePath
      detail = "Expected exactly one literal Android applicationId declaration."
    }
  }

  return [ordered]@{
    status = "pass"
    value = $matches[0].Groups[1].Value
    evidence = Convert-ToRelativePath $gradlePath
    detail = "Android source applicationId parsed."
  }
}

function Write-AndroidV1EvidenceTemplate {
  New-Item -ItemType Directory -Force -Path $EvidenceRoot | Out-Null
  New-Item -ItemType Directory -Force -Path (Join-Path $EvidenceRoot "reports") | Out-Null

  $template = [ordered]@{
    schema = "stackchan.android-v1-evidence-bundle.v1"
    status = "pending"
    sourceCommit = "<40-character git commit>"
    targetPhone = "<phone model and Android version>"
    releaseBuild = "app-android-release.apk / app-android-release.aab"
    hardwareEvidenceStatus = "pending"
    hardwareEvidenceRoot = "<output/hardware-evidence/...>"
    androidDashboardEvidenceStatus = "pending"
    androidDashboardEvidenceRoot = "screenshots"
    androidDashboardMedia = @(
      [ordered]@{
        id = "phone-pairing-setup"
        path = "screenshots/phone-pairing-setup.png"
        sourceCommit = "<40-character git commit>"
        notes = "Final-build setup media showing pairing code or QR ticket, bridge status, and saved robot add/remove affordance."
      },
      [ordered]@{
        id = "phone-live-dashboard"
        path = "screenshots/phone-live-dashboard.png"
        sourceCommit = "<40-character git commit>"
        notes = "Final-build connected dashboard media showing robot identity, square Stack-chan face preview, active brain owner, and honest telemetry labels."
      },
      [ordered]@{
        id = "phone-brain-model"
        path = "screenshots/phone-brain-model.png"
        sourceCommit = "<40-character git commit>"
        notes = "Final-build Brain/model media showing Gemma-4-E2B download, load, eject, checksum, and settings controls."
      },
      [ordered]@{
        id = "phone-personas-diagnostics"
        path = "screenshots/phone-personas-diagnostics.png"
        sourceCommit = "<40-character git commit>"
        notes = "Final-build persona/diagnostics media showing import/export and diagnostics export without private values."
      }
    )
    reports = [ordered]@{
      apkInstallReport = "reports/android_apk_install.json"
      companionReadinessReport = "reports/companion_v1_readiness.json"
      diagnosticsCheckReport = "reports/android_diagnostics_check.json"
      speechCheckReport = "reports/android_speech_check.json"
      controlsCheckReport = "reports/android_controls_check.json"
      pairingCheckReport = "reports/android_pairing_check.json"
      wifiCheckReport = "reports/android_wifi_check.json"
      gemmaCheckReport = "reports/android_gemma_check.json"
      screenOffSoakCheckReport = "reports/android_screen_off_soak_check.json"
      playStoreCheckReport = "reports/android_play_store_check.json"
    }
    reviewPath = "ANDROID_V1_REVIEW.md"
    requiredScreenshotIds = @(
      "phone-pairing-setup",
      "phone-live-dashboard",
      "phone-brain-model",
      "phone-personas-diagnostics"
    )
    notes = "Copy each individual checker JSON into reports/, then rerun this aggregate gate."
  }
  $template | ConvertTo-Json -Depth 8 | Set-Content -Path (Join-Path $EvidenceRoot "ANDROID_V1_EVIDENCE_BUNDLE.json") -Encoding UTF8

  @"
# Android V1 Evidence Bundle

This packet is the final aggregate Android companion evidence gate. It does not replace the
individual evidence checkers; it proves their outputs have all been collected for the same
release candidate.

Required ready statuses:

- ``stackchan.android-apk-install.v1``: ``installed``
- ``stackchan.companion-v1-readiness.v1``: ``source-ready-pending-hardware`` with zero failures
- ``stackchan.android-diagnostics-export-evidence.v1``: ``android-diagnostics-export-ready``
- ``stackchan.android-speech-evidence.v1``: ``android-speech-ready``
- ``stackchan.android-controls-evidence.v1``: ``android-controls-ready``
- ``stackchan.android-pairing-evidence.v1``: ``android-pairing-ready``
- ``stackchan.android-wifi-evidence.v1``: ``android-wifi-ready``
- ``stackchan.android-gemma-evidence.v1``: ``android-gemma-real-device-ready``
- ``stackchan.android-screen-off-soak-evidence.v1``: ``android-screen-off-soak-ready``
- ``stackchan.android-play-store-evidence-check.v1``: ``play-internal-testing-ready``
- Every Android hardware evidence report and the Play Store evidence-check JSON must match
  this bundle's ``sourceCommit``.
- Every Android hardware evidence report that supports strict collection must also carry
  ``expectedSourceCommit`` matching this bundle's ``sourceCommit``, proving it was run with
  ``-SourceCommit <git-commit>``.
- The target-phone APK install ``packageName`` and Play Store evidence-check
  ``applicationId`` must match the source Gradle ``applicationId``.
- The Play Store evidence-check ``versionName`` and ``versionCode`` must match the
  target-phone APK install report, so internal-testing evidence cannot come from a
  different uploaded app version.

Run:

````powershell
tools/check_android_v1_evidence_bundle.cmd -EvidenceRoot output/android-v1-evidence/latest -RequireReady -Json
````
"@ | Set-Content -Path (Join-Path $EvidenceRoot "ANDROID_V1_EVIDENCE_BUNDLE.md") -Encoding UTF8

  @"
# Android V1 Review

Complete after the target-phone and physical-robot evidence is assembled.

- Reviewer:
- Review date:
- Source commit:
- Overall Android v1 decision: pending
- Target phone install decision: pending
- Connected dashboard media decision: pending
- Physical robot pairing decision: pending
- Push-to-talk/STT decision: pending
- Settings and handoff decision: pending
- Wi-Fi provisioning decision: pending
- Mobile Gemma decision: pending
- Screen-off bridge soak decision: pending
- Play internal testing decision: pending
"@ | Set-Content -Path (Join-Path $EvidenceRoot "ANDROID_V1_REVIEW.md") -Encoding UTF8
}

if ($WriteTemplate) {
  Write-AndroidV1EvidenceTemplate
}

$bundle = $null
$apk = $null
$playStore = $null
$gemmaBenchmarkProfile = ""
$gemmaBenchmarkMedianMs = $null
$gemmaBenchmarkMedianTokensPerSec = $null
$androidDashboardMediaIds = @()

$bundlePath = Join-Path $EvidenceRoot "ANDROID_V1_EVIDENCE_BUNDLE.json"
if (-not (Test-Path -LiteralPath $bundlePath -PathType Leaf)) {
  Add-Check "bundle-json" "Android v1 evidence bundle JSON" "pending" (Convert-ToRelativePath $bundlePath) "Run with -WriteTemplate, then fill the bundle after target-phone validation."
} else {
  Add-Check "bundle-json" "Android v1 evidence bundle JSON" "pass" (Convert-ToRelativePath $bundlePath) "Bundle JSON exists."
  try {
    $bundle = Read-JsonOrNull $bundlePath
  } catch {
    Add-Check "bundle-json-parse" "Android v1 evidence bundle JSON parses" "fail" (Convert-ToRelativePath $bundlePath) $_.Exception.Message
    $bundle = $null
  }

  if ($null -ne $bundle) {
    if ($bundle.schema -eq "stackchan.android-v1-evidence-bundle.v1") {
      Add-Check "bundle-schema" "Bundle schema" "pass" "ANDROID_V1_EVIDENCE_BUNDLE.json" "Schema matches."
    } else {
      Add-Check "bundle-schema" "Bundle schema" "fail" "ANDROID_V1_EVIDENCE_BUNDLE.json" "Unexpected schema: $($bundle.schema)."
    }

    if (Test-Commit ([string]$bundle.sourceCommit)) {
      Add-Check "source-commit" "Source commit" "pass" "ANDROID_V1_EVIDENCE_BUNDLE.json" "Full source commit recorded."
    } else {
      Add-Check "source-commit" "Source commit" "pending" "ANDROID_V1_EVIDENCE_BUNDLE.json" "Record a full 40-character source commit."
    }

    if ([string]$bundle.hardwareEvidenceStatus -in @("verified", "pass", "passed") -and [string]$bundle.hardwareEvidenceRoot -notmatch "<|pending|TBD") {
      Add-Check "hardware-evidence" "Physical robot hardware evidence" "pass" "ANDROID_V1_EVIDENCE_BUNDLE.json" "Hardware evidence is recorded as verified."
    } else {
      Add-Check "hardware-evidence" "Physical robot hardware evidence" "pending" "ANDROID_V1_EVIDENCE_BUNDLE.json" "Record verified hardware evidence root after tools/verify_hardware_evidence.cmd passes."
    }

    Test-AndroidDashboardEvidence $bundle

    $reports = Get-Field $bundle "reports"
    $apkPath = Resolve-EvidencePath ([string](Get-Field $reports "apkInstallReport"))
    if ([string]::IsNullOrWhiteSpace([string](Get-Field $reports "apkInstallReport"))) {
      Add-Check "apk-install" "Target phone APK install report" "pending" "" "Record reports.apkInstallReport."
    } elseif (-not (Test-Path -LiteralPath $apkPath -PathType Leaf)) {
      Add-Check "apk-install" "Target phone APK install report" "pending" (Convert-ToRelativePath $apkPath) "Missing APK install report."
    } else {
      try {
        $apk = Read-JsonOrNull $apkPath
        if ($apk.schema -ne "stackchan.android-apk-install.v1") {
          Add-Check "apk-install" "Target phone APK install report" "fail" (Convert-ToRelativePath $apkPath) "Unexpected schema: $($apk.schema)."
        } elseif ($apk.status -ne "installed") {
          Add-Check "apk-install" "Target phone APK install report" "pending" (Convert-ToRelativePath $apkPath) "Expected installed, got $($apk.status)."
        } elseif (-not (Test-Hash ([string]$apk.apkSha256)) -or -not (Test-Commit ([string]$apk.sourceCommit))) {
          Add-Check "apk-install" "Target phone APK install report" "fail" (Convert-ToRelativePath $apkPath) "APK install report must include valid apkSha256 and sourceCommit."
        } elseif ([string]::IsNullOrWhiteSpace([string]$apk.packageName)) {
          Add-Check "apk-install" "Target phone APK install report" "fail" (Convert-ToRelativePath $apkPath) "APK install report must include installed packageName."
        } else {
          Add-Check "apk-install" "Target phone APK install report" "pass" (Convert-ToRelativePath $apkPath) "Target phone install is recorded."
        }
      } catch {
        Add-Check "apk-install" "Target phone APK install report" "fail" (Convert-ToRelativePath $apkPath) "Report JSON does not parse: $($_.Exception.Message)"
      }
    }

    Test-ReportStatus "companion-readiness" "Companion source readiness report" $reports "companionReadinessReport" "stackchan.companion-v1-readiness.v1" "source-ready-pending-hardware"
    Test-ReportStatus "diagnostics-ready" "Android diagnostics evidence report" $reports "diagnosticsCheckReport" "stackchan.android-diagnostics-export-evidence.v1" "android-diagnostics-export-ready"
    Test-ReportStatus "speech-ready" "Android speech evidence report" $reports "speechCheckReport" "stackchan.android-speech-evidence.v1" "android-speech-ready"
    Test-ReportStatus "controls-ready" "Android controls evidence report" $reports "controlsCheckReport" "stackchan.android-controls-evidence.v1" "android-controls-ready"
    Test-ReportStatus "pairing-ready" "Android pairing evidence report" $reports "pairingCheckReport" "stackchan.android-pairing-evidence.v1" "android-pairing-ready"
    Test-ReportStatus "wifi-ready" "Android Wi-Fi evidence report" $reports "wifiCheckReport" "stackchan.android-wifi-evidence.v1" "android-wifi-ready"
    Test-ReportStatus "gemma-ready" "Android Gemma evidence report" $reports "gemmaCheckReport" "stackchan.android-gemma-evidence.v1" "android-gemma-real-device-ready"
    Test-GemmaBenchmarkEvidence $reports
    Test-ReportStatus "screen-off-soak-ready" "Android screen-off soak evidence report" $reports "screenOffSoakCheckReport" "stackchan.android-screen-off-soak-evidence.v1" "android-screen-off-soak-ready"
    Test-ReportStatus "play-store-ready" "Android Play Store evidence report" $reports "playStoreCheckReport" "stackchan.android-play-store-evidence-check.v1" "play-internal-testing-ready"
    Test-ReportFieldEquals "companion-readiness-source-commit-match" "Companion source readiness source commit matches bundle" $reports "companionReadinessReport" "sourceCommit" ([string]$bundle.sourceCommit) "sourceCommit"
    Test-ReportFieldEquals "apk-install-source-commit-match" "APK install source commit matches bundle" $reports "apkInstallReport" "sourceCommit" ([string]$bundle.sourceCommit) "sourceCommit"
    Test-ReportFieldEquals "diagnostics-source-commit-match" "Android diagnostics source commit matches bundle" $reports "diagnosticsCheckReport" "sourceCommit" ([string]$bundle.sourceCommit) "sourceCommit"
    Test-ReportFieldEquals "speech-source-commit-match" "Android speech source commit matches bundle" $reports "speechCheckReport" "sourceCommit" ([string]$bundle.sourceCommit) "sourceCommit"
    Test-ReportFieldEquals "controls-source-commit-match" "Android controls source commit matches bundle" $reports "controlsCheckReport" "sourceCommit" ([string]$bundle.sourceCommit) "sourceCommit"
    Test-ReportFieldEquals "pairing-source-commit-match" "Android pairing source commit matches bundle" $reports "pairingCheckReport" "sourceCommit" ([string]$bundle.sourceCommit) "sourceCommit"
    Test-ReportFieldEquals "wifi-source-commit-match" "Android Wi-Fi source commit matches bundle" $reports "wifiCheckReport" "sourceCommit" ([string]$bundle.sourceCommit) "sourceCommit"
    Test-ReportFieldEquals "gemma-source-commit-match" "Android Gemma source commit matches bundle" $reports "gemmaCheckReport" "sourceCommit" ([string]$bundle.sourceCommit) "sourceCommit"
    Test-ReportFieldEquals "screen-off-soak-source-commit-match" "Android screen-off soak source commit matches bundle" $reports "screenOffSoakCheckReport" "sourceCommit" ([string]$bundle.sourceCommit) "sourceCommit"
    Test-ReportFieldEquals "play-store-source-commit-match" "Play Store evidence source commit matches bundle" $reports "playStoreCheckReport" "sourceCommit" ([string]$bundle.sourceCommit) "sourceCommit"
    Test-ReportFieldEquals "diagnostics-expected-source-commit-match" "Android diagnostics strict SourceCommit matches bundle" $reports "diagnosticsCheckReport" "expectedSourceCommit" ([string]$bundle.sourceCommit) "sourceCommit"
    Test-ReportFieldEquals "speech-expected-source-commit-match" "Android speech strict SourceCommit matches bundle" $reports "speechCheckReport" "expectedSourceCommit" ([string]$bundle.sourceCommit) "sourceCommit"
    Test-ReportFieldEquals "controls-expected-source-commit-match" "Android controls strict SourceCommit matches bundle" $reports "controlsCheckReport" "expectedSourceCommit" ([string]$bundle.sourceCommit) "sourceCommit"
    Test-ReportFieldEquals "pairing-expected-source-commit-match" "Android pairing strict SourceCommit matches bundle" $reports "pairingCheckReport" "expectedSourceCommit" ([string]$bundle.sourceCommit) "sourceCommit"
    Test-ReportFieldEquals "wifi-expected-source-commit-match" "Android Wi-Fi strict SourceCommit matches bundle" $reports "wifiCheckReport" "expectedSourceCommit" ([string]$bundle.sourceCommit) "sourceCommit"
    Test-ReportFieldEquals "gemma-expected-source-commit-match" "Android Gemma strict SourceCommit matches bundle" $reports "gemmaCheckReport" "expectedSourceCommit" ([string]$bundle.sourceCommit) "sourceCommit"
    Test-ReportFieldEquals "screen-off-soak-expected-source-commit-match" "Android screen-off soak strict SourceCommit matches bundle" $reports "screenOffSoakCheckReport" "expectedSourceCommit" ([string]$bundle.sourceCommit) "sourceCommit"
    $sourceApplicationId = Get-AndroidSourceApplicationId
    if ($sourceApplicationId.status -ne "pass") {
      Add-Check "apk-install-application-id-match" "APK install packageName matches source applicationId" $sourceApplicationId.status $sourceApplicationId.evidence $sourceApplicationId.detail
      Add-Check "play-store-application-id-match" "Play Store applicationId matches target-phone APK install" $sourceApplicationId.status $sourceApplicationId.evidence $sourceApplicationId.detail
    } elseif ($null -ne $apk) {
      Test-ReportFieldEquals "apk-install-application-id-match" "APK install packageName matches source applicationId" $reports "apkInstallReport" "packageName" ([string]$sourceApplicationId.value) "source applicationId"
      Test-ReportFieldEquals "play-store-application-id-match" "Play Store applicationId matches target-phone APK install" $reports "playStoreCheckReport" "applicationId" ([string]$apk.packageName) "APK install packageName"
    } else {
      Add-Check "apk-install-application-id-match" "APK install packageName matches source applicationId" "pending" "ANDROID_V1_EVIDENCE_BUNDLE.json" "Record a valid target-phone APK install report before checking applicationId consistency."
      Add-Check "play-store-application-id-match" "Play Store applicationId matches target-phone APK install" "pending" "ANDROID_V1_EVIDENCE_BUNDLE.json" "Record a valid target-phone APK install report before checking Play applicationId consistency."
    }
    $playStorePath = Resolve-EvidencePath ([string](Get-Field $reports "playStoreCheckReport"))
    if (-not [string]::IsNullOrWhiteSpace($playStorePath) -and (Test-Path -LiteralPath $playStorePath -PathType Leaf)) {
      try {
        $playStore = Read-JsonOrNull $playStorePath
      } catch {
        $playStore = $null
      }
    }
    if ($null -ne $apk) {
      Test-ReportFieldEquals "play-store-version-name-match" "Play Store evidence versionName matches target-phone APK install" $reports "playStoreCheckReport" "versionName" ([string]$apk.versionName) "APK install versionName"
      Test-ReportFieldEquals "play-store-version-code-match" "Play Store evidence versionCode matches target-phone APK install" $reports "playStoreCheckReport" "versionCode" ([string]$apk.versionCode) "APK install versionCode"
    } else {
      Add-Check "play-store-version-name-match" "Play Store evidence versionName matches target-phone APK install" "pending" "ANDROID_V1_EVIDENCE_BUNDLE.json" "Record a valid target-phone APK install report before checking Play versionName consistency."
      Add-Check "play-store-version-code-match" "Play Store evidence versionCode matches target-phone APK install" "pending" "ANDROID_V1_EVIDENCE_BUNDLE.json" "Record a valid target-phone APK install report before checking Play versionCode consistency."
    }

    $reviewPath = Resolve-EvidencePath ([string]$bundle.reviewPath)
    if ([string]::IsNullOrWhiteSpace([string]$bundle.reviewPath) -or -not (Test-Path -LiteralPath $reviewPath -PathType Leaf)) {
      Add-Check "android-v1-review" "Android v1 human review" "pending" (Convert-ToRelativePath $reviewPath) "Complete ANDROID_V1_REVIEW.md."
    } else {
      $review = Get-Content -LiteralPath $reviewPath -Raw
      $requiredReviewPatterns = @(
        "Reviewer:",
        "Review date:",
        "Source commit:",
        "Overall Android v1 decision: pass",
        "Target phone install decision: pass",
        "Connected dashboard media decision: pass",
        "Physical robot pairing decision: pass",
        "Push-to-talk/STT decision: pass",
        "Settings and handoff decision: pass",
        "Wi-Fi provisioning decision: pass",
        "Mobile Gemma decision: pass",
        "Screen-off bridge soak decision: pass",
        "Play internal testing decision: pass"
      )
      $missing = @($requiredReviewPatterns | Where-Object { $review -notmatch [regex]::Escape($_) })
      $reviewSourceCommit = Get-ReviewSourceCommit $review
      if ($missing.Count -eq 0 -and (Test-Commit $reviewSourceCommit) -and $reviewSourceCommit -eq [string]$bundle.sourceCommit) {
        Add-Check "android-v1-review" "Android v1 human review" "pass" (Convert-ToRelativePath $reviewPath) "All Android v1 decisions are pass."
      } elseif ((Test-Commit $reviewSourceCommit) -and $reviewSourceCommit -ne [string]$bundle.sourceCommit) {
        Add-Check "android-v1-review" "Android v1 human review" "fail" (Convert-ToRelativePath $reviewPath) "Review Source commit $reviewSourceCommit does not match bundle sourceCommit $($bundle.sourceCommit)."
      } else {
        $missingDetail = if ($missing.Count -eq 0) { "Source commit must be a full 40-character SHA matching bundle sourceCommit." } else { "Missing review markers: " + ($missing -join ", ") }
        Add-Check "android-v1-review" "Android v1 human review" "pending" (Convert-ToRelativePath $reviewPath) $missingDetail
      }
    }
  }
}

$failedChecks = @($checks | Where-Object { $_.status -eq "fail" })
$pendingChecks = @($checks | Where-Object { $_.status -eq "pending" })
$passedChecks = @($checks | Where-Object { $_.status -eq "pass" })
$status = if ($failedChecks.Count -gt 0) { "not-ready" } elseif ($pendingChecks.Count -gt 0) { "pending-android-v1-evidence-bundle" } else { "android-v1-evidence-ready" }

$report = [ordered]@{
  schema = "stackchan.android-v1-evidence-bundle-check.v1"
  status = $status
  root = [string]$Root
  evidenceRoot = Convert-ToRelativePath $EvidenceRoot
  sourceCommit = if ($null -ne $bundle) { [string]$bundle.sourceCommit } else { "" }
  applicationId = if ($null -ne $apk) { [string]$apk.packageName } else { "" }
  apkSha256 = if ($null -ne $apk) { [string]$apk.apkSha256 } else { "" }
  versionName = if ($null -ne $apk) { [string]$apk.versionName } else { "" }
  versionCode = if ($null -ne $apk) { [string]$apk.versionCode } else { "" }
  releaseAabSha256 = if ($null -ne $playStore) { [string]$playStore.releaseAabSha256 } else { "" }
  gemmaBenchmarkProfile = $gemmaBenchmarkProfile
  gemmaBenchmarkMedianMs = $gemmaBenchmarkMedianMs
  gemmaBenchmarkMedianTokensPerSec = $gemmaBenchmarkMedianTokensPerSec
  androidDashboardMediaIds = @($androidDashboardMediaIds)
  passed = $passedChecks.Count
  failed = $failedChecks.Count
  pending = $pendingChecks.Count
  checks = @($checks)
}

if ($Json) {
  $report | ConvertTo-Json -Depth 8
} else {
  Write-Host "Android v1 evidence bundle: $status"
  Write-Host "Evidence root: $(Convert-ToRelativePath $EvidenceRoot)"
  Write-Host "Passed: $($passedChecks.Count)  Failed: $($failedChecks.Count)  Pending: $($pendingChecks.Count)"
  foreach ($check in $checks) {
    $prefix = if ($check.status -eq "pass") { "PASS" } elseif ($check.status -eq "pending") { "PENDING" } else { "FAIL" }
    Write-Host "[$prefix] $($check.name) - $($check.detail)"
  }
}

if ($failedChecks.Count -gt 0 -or ($RequireReady -and $status -ne "android-v1-evidence-ready")) {
  exit 1
}
