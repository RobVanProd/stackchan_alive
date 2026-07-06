param(
  [string]$Root = "",
  [string]$EvidenceRoot = "output/android-play-store/latest",
  [switch]$WriteTemplate,
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
    [ValidateSet("pass", "fail")]
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

function Test-Hash {
  param([string]$Value)
  return $Value -match "^[a-fA-F0-9]{64}$"
}

function Test-Commit {
  param([string]$Value)
  return $Value -match "^[a-fA-F0-9]{40}$"
}

function Test-HttpsUrl {
  param([string]$Value)
  return $Value -match "^https://[^<>\s]+$"
}

function Test-NonPlaceholder {
  param([string]$Value)
  return -not [string]::IsNullOrWhiteSpace($Value) -and $Value -notmatch "<|>|pending|TBD"
}

function Test-UtcTimestamp {
  param([string]$Value)

  if ($Value -notmatch "^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z$") {
    return $false
  }

  $parsed = [DateTimeOffset]::MinValue
  return [DateTimeOffset]::TryParse($Value, [ref]$parsed)
}

function Get-ReviewSourceCommit {
  param([string]$Text)

  $match = [regex]::Match($Text, "(?im)^\s*-?\s*Source commit:\s*([a-fA-F0-9]{40})\s*$")
  if ($match.Success) {
    return $match.Groups[1].Value
  }
  return ""
}

function Get-ReviewAppVersion {
  param([string]$Text)

  $match = [regex]::Match($Text, "(?im)^\s*-?\s*App version:\s*(\S+)\s*$")
  if ($match.Success) {
    return $match.Groups[1].Value
  }
  return ""
}

function Test-ImagePath {
  param([string]$Path)

  if ([string]::IsNullOrWhiteSpace($Path)) {
    return "Screenshot path is blank."
  }
  $fullPath = if ([System.IO.Path]::IsPathRooted($Path)) { $Path } else { Join-Path $EvidenceRoot $Path }
  if (-not (Test-Path -LiteralPath $fullPath -PathType Leaf)) {
    return "Missing screenshot file: $Path"
  }
  if ($fullPath -notmatch "\.(png|jpg|jpeg)$") {
    return "Screenshot must be PNG or JPEG: $Path"
  }
  if ((Get-Item -LiteralPath $fullPath).Length -lt 1024) {
    return "Screenshot file is too small to be credible: $Path"
  }
  return ""
}

function Get-ScreenshotId {
  param([object]$Screenshot)

  $id = [string]$Screenshot.id
  if (-not [string]::IsNullOrWhiteSpace($id)) {
    return $id
  }

  $path = [string]$Screenshot.path
  if ([string]::IsNullOrWhiteSpace($path)) {
    return ""
  }
  return [System.IO.Path]::GetFileNameWithoutExtension($path)
}

function Write-PlayStoreEvidenceTemplate {
  New-Item -ItemType Directory -Force -Path $EvidenceRoot | Out-Null
  New-Item -ItemType Directory -Force -Path (Join-Path $EvidenceRoot "screenshots") | Out-Null

  $template = [ordered]@{
    schema = "stackchan.android-play-store-evidence.v1"
    status = "pending"
    applicationId = "dev.stackchan.companion"
    versionName = "1.0.0"
    versionCode = 1
    sourceCommit = "<40-character git commit>"
    releaseAabSha256 = "<64-character app-android-release.aab sha256>"
    playSigningEnabled = $false
    privacyPolicyUrl = "https://<hosted-final-privacy-policy-url>"
    privacyPolicySourcePath = "docs/ANDROID_PLAY_PRIVACY_POLICY.md"
    track = "internal"
    uploadStatus = "pending"
    internalTestingInstallStatus = "pending"
    playConsoleReleaseName = ""
    testerGroup = ""
    uploadedAtUtc = ""
    screenshots = @(
      [ordered]@{
        id = "phone-pairing-setup"
        required = $true
        path = "screenshots/phone-pairing-setup.png"
        device = "<phone model>"
        androidVersion = "<android version>"
        appVersion = "1.0.0"
        sourceCommit = "<40-character git commit>"
        notes = "Guided setup screen with bridge status, pairing short code or QR ticket, saved robot add/remove affordance, and current next step."
      },
      [ordered]@{
        id = "phone-live-dashboard"
        required = $true
        path = "screenshots/phone-live-dashboard.png"
        device = "<phone model>"
        androidVersion = "<android version>"
        appVersion = "1.0.0"
        sourceCommit = "<40-character git commit>"
        notes = "Connected live dashboard with robot identity or connection status, square Stack-chan face preview, active brain owner, and honest telemetry labels."
      },
      [ordered]@{
        id = "phone-brain-model"
        required = $true
        path = "screenshots/phone-brain-model.png"
        device = "<phone model>"
        androidVersion = "<android version>"
        appVersion = "1.0.0"
        sourceCommit = "<40-character git commit>"
        notes = "Brain/model controls with Gemma-4-E2B download/load/eject state, checksum or staged status, and model settings entry point."
      },
      [ordered]@{
        id = "phone-personas-diagnostics"
        required = $true
        path = "screenshots/phone-personas-diagnostics.png"
        device = "<phone model>"
        androidVersion = "<android version>"
        appVersion = "1.0.0"
        sourceCommit = "<40-character git commit>"
        notes = "Persona import/export or diagnostics export screen from the final build with no private data or local secrets visible."
      }
    )
    dataSafetyReviewPath = "DATA_SAFETY_REVIEW.md"
    policyReviewPath = "POLICY_REVIEW.md"
    notes = "Replace placeholders after uploading the release AAB to Play Console internal testing."
  }
  $template | ConvertTo-Json -Depth 8 | Set-Content -Path (Join-Path $EvidenceRoot "PLAY_STORE_EVIDENCE.json") -Encoding UTF8

  @"
# Android Play Store Evidence

Fill this packet after the final Android build is uploaded to Play Console.

Required proof:

- Play Console internal testing release uses ``app-android-release.aab`` from the vetted CI run.
- ``releaseAabSha256`` matches the CI release evidence.
- Play App Signing is enabled.
- The hosted privacy policy URL points to the final reviewed
  ``docs/ANDROID_PLAY_PRIVACY_POLICY.md`` content.
- Internal test install succeeds on the target phone.
- Four final-build screenshots cover setup, live dashboard, Brain/model controls,
  and persona/diagnostics support workflows.
- Data safety and permission/policy notes are reviewed against actual app behavior.

Run:

````powershell
tools/check_android_play_store_evidence.cmd -EvidenceRoot output/android-play-store/latest -Json
````
"@ | Set-Content -Path (Join-Path $EvidenceRoot "PLAY_STORE_EVIDENCE.md") -Encoding UTF8

  @"
# Data Safety Review

Complete before Play submission. Start from
``docs/ANDROID_PLAY_POLICY_DECLARATIONS.md`` and verify every answer against the
uploaded build.

- Network behavior: Local WebSocket bridge, mDNS/UDP discovery, no cloud endpoint controlled by the app.
- Audio or microphone behavior: Explicit Push-to-talk uses Android SpeechRecognizer transcript capture; raw microphone audio is not stored or exported by app diagnostics.
- Diagnostics/logging behavior: User-initiated diagnostics share sheet only; last text turn is redacted to presence-only; Wi-Fi provisioning uses placeholders.
- User data collected: None collected by developer. Local-only saved robots, trusted endpoints, settings, model state, and diagnostics stay on device unless the user shares an export.
- User data shared: None by the app except user-initiated Android share-sheet export.
- Retention/deletion notes: Forget/Remove clear phone-side robot and trusted endpoint records; uninstall removes app-private stores; robot-side unpair remains firmware-managed.
- Reviewer:
- Review date:
- Source commit:
- App version:
- Decision: pending
"@ | Set-Content -Path (Join-Path $EvidenceRoot "DATA_SAFETY_REVIEW.md") -Encoding UTF8

  @"
# Policy Review

Complete before Play submission. Start from
``docs/ANDROID_PLAY_POLICY_DECLARATIONS.md`` and verify every answer against the
uploaded build.

- Foreground service declaration: Type ``connectedDevice``; hosts the user-visible local Stack-chan bridge while the phone is the active companion.
- Battery optimization request explanation: Optional screen-off reliability prompt for robot bridge testing; not required for ordinary browsing.
- Local-network/discovery explanation: INTERNET, ACCESS_NETWORK_STATE, and CHANGE_WIFI_MULTICAST_STATE support local LAN bridge, mDNS, UDP discovery, and manual URL pairing.
- Notification behavior: Foreground service status notification for the active bridge on Android 13+.
- Microphone behavior: RECORD_AUDIO is requested only for explicit Push-to-talk; denial records a not-sent mic message.
- Target audience: Not directed to children; requires paired Stack-chan hardware for connected flows.
- Reviewer:
- Review date:
- Source commit:
- App version:
- Decision: pending
"@ | Set-Content -Path (Join-Path $EvidenceRoot "POLICY_REVIEW.md") -Encoding UTF8

  @"
# Screenshots

Place final Play listing screenshots in this directory and reference them from
``PLAY_STORE_EVIDENCE.json``. Use real final-build screenshots, not simulator
mockups, once physical robot validation is complete.

Required IDs:

- ``phone-pairing-setup``
- ``phone-live-dashboard``
- ``phone-brain-model``
- ``phone-personas-diagnostics``
"@ | Set-Content -Path (Join-Path $EvidenceRoot "screenshots/README.md") -Encoding UTF8
}

if ($WriteTemplate) {
  Write-PlayStoreEvidenceTemplate
}

$evidenceJsonPath = Join-Path $EvidenceRoot "PLAY_STORE_EVIDENCE.json"
if (-not (Test-Path -LiteralPath $evidenceJsonPath -PathType Leaf)) {
  Add-Check "evidence-json" "Play evidence JSON" "fail" (Convert-ToRelativePath $evidenceJsonPath) "Run with -WriteTemplate, then fill the evidence after Play Console upload."
} else {
  Add-Check "evidence-json" "Play evidence JSON" "pass" (Convert-ToRelativePath $evidenceJsonPath) "Evidence JSON exists."
  $evidence = Get-Content -LiteralPath $evidenceJsonPath -Raw | ConvertFrom-Json

  if ($evidence.schema -eq "stackchan.android-play-store-evidence.v1") {
    Add-Check "schema" "Evidence schema" "pass" "PLAY_STORE_EVIDENCE.json" "Schema matches."
  } else {
    Add-Check "schema" "Evidence schema" "fail" "PLAY_STORE_EVIDENCE.json" "Unexpected schema: $($evidence.schema)"
  }

  if ($evidence.applicationId -eq "dev.stackchan.companion") {
    Add-Check "application-id" "Application ID" "pass" "PLAY_STORE_EVIDENCE.json" "Application ID matches the Android package."
  } else {
    Add-Check "application-id" "Application ID" "fail" "PLAY_STORE_EVIDENCE.json" "Expected dev.stackchan.companion, got $($evidence.applicationId)."
  }

  if ($evidence.status -eq "internal-testing-ready") {
    Add-Check "evidence-status" "Play evidence packet status" "pass" "PLAY_STORE_EVIDENCE.json" "Evidence packet is marked internal-testing-ready."
  } else {
    Add-Check "evidence-status" "Play evidence packet status" "fail" "PLAY_STORE_EVIDENCE.json" "Set status to internal-testing-ready only after Play internal testing upload, install, screenshots, and reviews are complete."
  }

  if ((Test-NonPlaceholder ([string]$evidence.versionName)) -and ([int]$evidence.versionCode -gt 0)) {
    Add-Check "app-version" "Play app version identity" "pass" "PLAY_STORE_EVIDENCE.json" "Version name and code are recorded."
  } else {
    Add-Check "app-version" "Play app version identity" "fail" "PLAY_STORE_EVIDENCE.json" "Record a non-placeholder versionName and positive versionCode for the uploaded build."
  }

  if (Test-Commit ([string]$evidence.sourceCommit)) {
    Add-Check "source-commit" "Source commit" "pass" "PLAY_STORE_EVIDENCE.json" "Full source commit recorded."
  } else {
    Add-Check "source-commit" "Source commit" "fail" "PLAY_STORE_EVIDENCE.json" "sourceCommit must be a full 40-character SHA."
  }

  if (Test-Hash ([string]$evidence.releaseAabSha256)) {
    Add-Check "release-aab-sha" "Release AAB SHA256" "pass" "PLAY_STORE_EVIDENCE.json" "Release AAB hash recorded."
  } else {
    Add-Check "release-aab-sha" "Release AAB SHA256" "fail" "PLAY_STORE_EVIDENCE.json" "releaseAabSha256 must be a 64-character SHA256."
  }

  if ($evidence.playSigningEnabled -eq $true) {
    Add-Check "play-signing" "Play App Signing" "pass" "PLAY_STORE_EVIDENCE.json" "Play App Signing is recorded as enabled."
  } else {
    Add-Check "play-signing" "Play App Signing" "fail" "PLAY_STORE_EVIDENCE.json" "Set playSigningEnabled to true after confirming Play App Signing."
  }

  if ((Test-HttpsUrl ([string]$evidence.privacyPolicyUrl)) -and ([string]$evidence.privacyPolicyUrl -notmatch "<|hosted-final")) {
    Add-Check "privacy-policy-url" "Hosted privacy policy URL" "pass" "PLAY_STORE_EVIDENCE.json" "Hosted HTTPS privacy policy URL recorded."
  } else {
    Add-Check "privacy-policy-url" "Hosted privacy policy URL" "fail" "PLAY_STORE_EVIDENCE.json" "Record the hosted HTTPS privacy policy URL after publishing docs/ANDROID_PLAY_PRIVACY_POLICY.md."
  }

  if ($evidence.privacyPolicySourcePath -eq "docs/ANDROID_PLAY_PRIVACY_POLICY.md") {
    Add-Check "privacy-policy-source" "Privacy policy source document" "pass" "PLAY_STORE_EVIDENCE.json" "Privacy policy source path recorded."
  } else {
    Add-Check "privacy-policy-source" "Privacy policy source document" "fail" "PLAY_STORE_EVIDENCE.json" "privacyPolicySourcePath must be docs/ANDROID_PLAY_PRIVACY_POLICY.md."
  }

  if ($evidence.track -eq "internal") {
    Add-Check "track" "Play track" "pass" "PLAY_STORE_EVIDENCE.json" "Internal testing track recorded."
  } else {
    Add-Check "track" "Play track" "fail" "PLAY_STORE_EVIDENCE.json" "Expected track 'internal', got '$($evidence.track)'."
  }

  if ($evidence.uploadStatus -in @("uploaded", "rolled-out", "available-to-testers")) {
    Add-Check "upload-status" "AAB upload status" "pass" "PLAY_STORE_EVIDENCE.json" "AAB upload status is $($evidence.uploadStatus)."
  } else {
    Add-Check "upload-status" "AAB upload status" "fail" "PLAY_STORE_EVIDENCE.json" "Record uploadStatus as uploaded, rolled-out, or available-to-testers after Play Console upload."
  }

  if ($evidence.internalTestingInstallStatus -in @("installed", "passed")) {
    Add-Check "internal-install" "Internal testing install" "pass" "PLAY_STORE_EVIDENCE.json" "Internal testing install is $($evidence.internalTestingInstallStatus)."
  } else {
    Add-Check "internal-install" "Internal testing install" "fail" "PLAY_STORE_EVIDENCE.json" "Record internalTestingInstallStatus as installed or passed after installing from Play."
  }

  if ((Test-NonPlaceholder ([string]$evidence.playConsoleReleaseName)) -and ([string]$evidence.playConsoleReleaseName -match [regex]::Escape([string]$evidence.versionName))) {
    Add-Check "play-console-release" "Play Console release identity" "pass" "PLAY_STORE_EVIDENCE.json" "Play Console release name includes the uploaded app version."
  } else {
    Add-Check "play-console-release" "Play Console release identity" "fail" "PLAY_STORE_EVIDENCE.json" "Record a Play Console release name that includes the uploaded versionName."
  }

  if (Test-NonPlaceholder ([string]$evidence.testerGroup)) {
    Add-Check "tester-group" "Internal tester group" "pass" "PLAY_STORE_EVIDENCE.json" "Internal tester group is recorded."
  } else {
    Add-Check "tester-group" "Internal tester group" "fail" "PLAY_STORE_EVIDENCE.json" "Record the Play internal testing tester group."
  }

  if (Test-UtcTimestamp ([string]$evidence.uploadedAtUtc)) {
    Add-Check "uploaded-at-utc" "Play upload timestamp" "pass" "PLAY_STORE_EVIDENCE.json" "Play upload timestamp is an ISO-8601 UTC instant."
  } else {
    Add-Check "uploaded-at-utc" "Play upload timestamp" "fail" "PLAY_STORE_EVIDENCE.json" "Record uploadedAtUtc as yyyy-MM-ddTHH:mm:ssZ after Play Console upload."
  }

  $screenshots = @($evidence.screenshots)
  $requiredScreenshotIds = @(
    "phone-pairing-setup",
    "phone-live-dashboard",
    "phone-brain-model",
    "phone-personas-diagnostics"
  )
  $screenshotIds = @($screenshots | ForEach-Object { Get-ScreenshotId $_ })
  $missingScreenshotIds = @($requiredScreenshotIds | Where-Object { $_ -notin $screenshotIds })
  $screenshotIssues = @()
  foreach ($screenshot in $screenshots) {
    $screenshotId = Get-ScreenshotId $screenshot
    $issue = Test-ImagePath ([string]$screenshot.path)
    if (-not [string]::IsNullOrWhiteSpace($issue)) {
      $screenshotIssues += $issue
    }
    if ([string]::IsNullOrWhiteSpace([string]$screenshot.device)) {
      $screenshotIssues += "Screenshot device is blank for $screenshotId."
    }
    if ([string]::IsNullOrWhiteSpace([string]$screenshot.notes)) {
      $screenshotIssues += "Screenshot notes are blank for $screenshotId."
    }
    if ([string]$screenshot.sourceCommit -ne [string]$evidence.sourceCommit) {
      $screenshotIssues += "Screenshot sourceCommit for $screenshotId does not match PLAY_STORE_EVIDENCE.json sourceCommit."
    }
    if ([string]$screenshot.appVersion -ne [string]$evidence.versionName) {
      $screenshotIssues += "Screenshot appVersion for $screenshotId does not match PLAY_STORE_EVIDENCE.json versionName."
    }
  }
  if ($missingScreenshotIds.Count -gt 0) {
    $screenshotIssues += ("Missing required screenshot IDs: " + ($missingScreenshotIds -join ", "))
  }
  if ($screenshots.Count -ge 4 -and $screenshotIssues.Count -eq 0) {
    Add-Check "screenshots" "Play screenshots" "pass" "PLAY_STORE_EVIDENCE.json" "All required final-build screenshot files are present."
  } else {
    $detail = if ($screenshots.Count -lt 4) { "Four required screenshots are expected for v1." } else { $screenshotIssues -join "; " }
    Add-Check "screenshots" "Play screenshots" "fail" "PLAY_STORE_EVIDENCE.json" $detail
  }

  foreach ($review in @(
    @{ id = "data-safety"; name = "Data safety review"; path = [string]$evidence.dataSafetyReviewPath },
    @{ id = "policy-review"; name = "Policy review"; path = [string]$evidence.policyReviewPath }
  )) {
    $reviewPath = if ([System.IO.Path]::IsPathRooted($review.path)) { $review.path } else { Join-Path $EvidenceRoot $review.path }
    if (-not (Test-Path -LiteralPath $reviewPath -PathType Leaf)) {
      Add-Check $review.id $review.name "fail" (Convert-ToRelativePath $reviewPath) "Review file is missing."
      continue
    }

    $reviewText = Get-Content -LiteralPath $reviewPath -Raw
    $reviewIssues = @()
    foreach ($pattern in @("Reviewer:", "Review date:", "Source commit:", "App version:", "Decision: pass")) {
      if ($reviewText -notmatch [regex]::Escape($pattern)) {
        $reviewIssues += "Missing $pattern"
      }
    }
    $reviewSourceCommit = Get-ReviewSourceCommit $reviewText
    $reviewAppVersion = Get-ReviewAppVersion $reviewText
    if ($reviewSourceCommit -ne [string]$evidence.sourceCommit) {
      $reviewIssues += "Review Source commit does not match PLAY_STORE_EVIDENCE.json sourceCommit."
    }
    if ($reviewAppVersion -ne [string]$evidence.versionName) {
      $reviewIssues += "Review App version does not match PLAY_STORE_EVIDENCE.json versionName."
    }

    if ($reviewIssues.Count -eq 0) {
      Add-Check $review.id $review.name "pass" (Convert-ToRelativePath $reviewPath) "Review decision is pass for this source commit and app version."
    } else {
      Add-Check $review.id $review.name "fail" (Convert-ToRelativePath $reviewPath) ($reviewIssues -join "; ")
    }
  }
}

$failedChecks = @($checks | Where-Object { $_.status -eq "fail" })
$passedChecks = @($checks | Where-Object { $_.status -eq "pass" })
$status = if ($failedChecks.Count -gt 0) { "pending-play-store-evidence" } else { "play-internal-testing-ready" }
$report = [ordered]@{
  schema = "stackchan.android-play-store-evidence-check.v1"
  status = $status
  sourceCommit = if ($null -ne $evidence) { [string]$evidence.sourceCommit } else { "" }
  root = [string]$Root
  evidenceRoot = Convert-ToRelativePath $EvidenceRoot
  passed = $passedChecks.Count
  failed = $failedChecks.Count
  checks = @($checks)
}

if ($Json) {
  $report | ConvertTo-Json -Depth 8
} else {
  Write-Host "Android Play Store evidence: $status"
  Write-Host "Evidence root: $(Convert-ToRelativePath $EvidenceRoot)"
  Write-Host "Passed: $($passedChecks.Count)  Failed: $($failedChecks.Count)"
  foreach ($check in $checks) {
    $prefix = if ($check.status -eq "pass") { "PASS" } else { "FAIL" }
    Write-Host "[$prefix] $($check.name) - $($check.detail)"
  }
}

if ($failedChecks.Count -gt 0) {
  exit 1
}
