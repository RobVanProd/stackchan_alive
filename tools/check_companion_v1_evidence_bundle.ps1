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
