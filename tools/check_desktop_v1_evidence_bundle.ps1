param(
  [string]$Root = "",
  [string]$EvidenceRoot = "output/desktop-v1-evidence/latest",
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
    Add-Check $Id $Name "pending" "" "Record reports.$Field in DESKTOP_V1_EVIDENCE_BUNDLE.json."
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
    Add-Check $Id $Name "pending" "DESKTOP_V1_EVIDENCE_BUNDLE.json" "Record $ExpectedLabel before checking report consistency."
    return
  }
  if ([string]::IsNullOrWhiteSpace($relativePath)) {
    Add-Check $Id $Name "pending" "" "Record reports.$Field in DESKTOP_V1_EVIDENCE_BUNDLE.json."
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

function Test-C6Report {
  param(
    [string]$Id,
    [string]$Name,
    [object]$Reports,
    [string]$Field,
    [string]$ExpectedSchema
  )

  $relativePath = [string](Get-Field $Reports $Field)
  $path = Resolve-EvidencePath $relativePath
  if ([string]::IsNullOrWhiteSpace($relativePath)) {
    Add-Check $Id $Name "pending" "" "Record reports.$Field in DESKTOP_V1_EVIDENCE_BUNDLE.json."
    return
  }
  if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
    Add-Check $Id $Name "pending" (Convert-ToRelativePath $path) "Missing C6 report file."
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
  } elseif ($report.overall_ok -eq $true) {
    Add-Check $Id $Name "pass" (Convert-ToRelativePath $path) "C6 report overall_ok=true."
  } else {
    Add-Check $Id $Name "fail" (Convert-ToRelativePath $path) "C6 report must have overall_ok=true."
  }
}

function Test-DesktopArtifact {
  param(
    [string]$Id,
    [string]$Name,
    [object]$Artifacts,
    [string]$Field,
    [string]$ExpectedExtension
  )

  $artifact = Get-Field $Artifacts $Field
  if ($null -eq $artifact) {
    Add-Check $Id $Name "pending" "" "Record artifacts.$Field in DESKTOP_V1_EVIDENCE_BUNDLE.json."
    return
  }

  $path = [string](Get-Field $artifact "path")
  $sha256 = [string](Get-Field $artifact "sha256")
  if ([string]::IsNullOrWhiteSpace($path) -or $path -match "<|TBD|pending") {
    Add-Check $Id $Name "pending" "DESKTOP_V1_EVIDENCE_BUNDLE.json" "Record the final $Field package path."
  } elseif (-not $path.EndsWith($ExpectedExtension, [System.StringComparison]::OrdinalIgnoreCase)) {
    Add-Check $Id $Name "fail" "DESKTOP_V1_EVIDENCE_BUNDLE.json" "Expected $ExpectedExtension artifact path, got $path."
  } elseif ([string]::IsNullOrWhiteSpace($sha256) -or $sha256 -match "<|TBD|pending") {
    Add-Check $Id $Name "pending" "DESKTOP_V1_EVIDENCE_BUNDLE.json" "Record the final $Field package SHA-256."
  } elseif (-not (Test-Hash $sha256)) {
    Add-Check $Id $Name "fail" "DESKTOP_V1_EVIDENCE_BUNDLE.json" "Record a valid 64-character SHA-256 for $Field."
  } else {
    Add-Check $Id $Name "pass" "DESKTOP_V1_EVIDENCE_BUNDLE.json" "$Field artifact hash is recorded."
  }
}

function Write-DesktopV1EvidenceTemplate {
  New-Item -ItemType Directory -Force -Path $EvidenceRoot | Out-Null
  New-Item -ItemType Directory -Force -Path (Join-Path $EvidenceRoot "reports") | Out-Null

  $template = [ordered]@{
    schema = "stackchan.desktop-v1-evidence-bundle.v1"
    status = "pending"
    sourceCommit = "<40-character git commit>"
    releaseBuild = "desktop Windows MSI / macOS DMG / Linux DEB"
    hardwareEvidenceStatus = "pending"
    hardwareEvidenceRoot = "<output/hardware-evidence/...>"
    desktopRuntimePayloadStatus = "pending"
    pcBrainLabStatus = "pending"
    artifacts = [ordered]@{
      windowsMsi = [ordered]@{ path = "artifacts/stackchan-companion.msi"; sha256 = "<64-character sha256>" }
      macosDmg = [ordered]@{ path = "artifacts/stackchan-companion.dmg"; sha256 = "<64-character sha256>" }
      linuxDeb = [ordered]@{ path = "artifacts/stackchan-companion.deb"; sha256 = "<64-character sha256>" }
    }
    reports = [ordered]@{
      companionReadinessReport = "reports/companion_v1_readiness.json"
      c6BrainSupervisorSmokeReport = "reports/BRAIN_SUPERVISOR_SMOKE.json"
      c6GuiRehearsalReport = "reports/GUI_REHEARSAL.json"
      windowsRuntimePayloadReport = "reports/desktop_runtime_windows.json"
      macosRuntimePayloadReport = "reports/desktop_runtime_macos.json"
      linuxRuntimePayloadReport = "reports/desktop_runtime_linux.json"
      pcBrainDeployCheckReport = "reports/pc_brain_deploy_check.json"
      pcBrainQuietSoakCheckReport = "reports/pc_brain_quiet_soak_check.json"
      voiceSourceReadinessReport = "reports/voice_source_readiness.json"
    }
    reviewPath = "DESKTOP_V1_REVIEW.md"
    notes = "Copy each individual checker JSON into reports/, then rerun this aggregate gate."
  }
  $template | ConvertTo-Json -Depth 8 | Set-Content -Path (Join-Path $EvidenceRoot "DESKTOP_V1_EVIDENCE_BUNDLE.json") -Encoding UTF8

  @"
# Desktop V1 Evidence Bundle

This packet is the final aggregate desktop/PC Brain evidence gate. It does not replace the
individual evidence checkers; it proves their outputs have all been collected for the same
release candidate.

Required ready statuses:

- ``stackchan.companion-v1-readiness.v1``: ``source-ready-pending-hardware`` with zero failures
- ``stackchan.companion.c6-brain-supervisor-smoke.v1``: ``overall_ok=true``
- ``stackchan.companion.c6-gui-rehearsal.v1``: ``overall_ok=true``
- ``stackchan.desktop-python-runtime-payload.v1``: ``ready`` for Windows, macOS, and Linux
- ``stackchan.pc-brain-deploy-evidence-check.v1``: ``pc-brain-deploy-ready`` with matching ``sourceCommit``
- ``stackchan.pc-brain-quiet-soak-evidence-check.v1``: ``pc-brain-quiet-soak-ready`` with matching ``sourceCommit``
- ``stackchan.voice-source-readiness.v1``: ``production-voice-source-ready`` with matching ``sourceCommit``
- Final desktop package hashes for ``.msi``, ``.dmg``, and ``.deb`` artifacts
- Verified physical robot evidence root and desktop PC Brain human review

Run:

````powershell
tools/check_desktop_v1_evidence_bundle.cmd -EvidenceRoot output/desktop-v1-evidence/latest -RequireReady -Json
````
"@ | Set-Content -Path (Join-Path $EvidenceRoot "DESKTOP_V1_EVIDENCE_BUNDLE.md") -Encoding UTF8

  @"
# Desktop V1 Review

Complete after desktop package, runtime payload, and physical PC Brain evidence are assembled.

- Reviewer:
- Review date:
- Source commit:
- Overall desktop v1 decision: pending
- Desktop package artifact decision: pending
- Managed Python runtime decision: pending
- C6 GUI/supervisor evidence decision: pending
- PC Brain deploy audio decision: pending
- PC Brain quiet-soak decision: pending
- Physical robot evidence decision: pending
- Production voice-source decision: pending
"@ | Set-Content -Path (Join-Path $EvidenceRoot "DESKTOP_V1_REVIEW.md") -Encoding UTF8
}

if ($WriteTemplate) {
  Write-DesktopV1EvidenceTemplate
}

$bundlePath = Join-Path $EvidenceRoot "DESKTOP_V1_EVIDENCE_BUNDLE.json"
if (-not (Test-Path -LiteralPath $bundlePath -PathType Leaf)) {
  Add-Check "bundle-json" "Desktop v1 evidence bundle JSON" "pending" (Convert-ToRelativePath $bundlePath) "Run with -WriteTemplate, then fill the bundle after desktop and PC Brain validation."
} else {
  Add-Check "bundle-json" "Desktop v1 evidence bundle JSON" "pass" (Convert-ToRelativePath $bundlePath) "Bundle JSON exists."
  try {
    $bundle = Read-JsonOrNull $bundlePath
  } catch {
    Add-Check "bundle-json-parse" "Desktop v1 evidence bundle JSON parses" "fail" (Convert-ToRelativePath $bundlePath) $_.Exception.Message
    $bundle = $null
  }

  if ($null -ne $bundle) {
    if ($bundle.schema -eq "stackchan.desktop-v1-evidence-bundle.v1") {
      Add-Check "bundle-schema" "Bundle schema" "pass" "DESKTOP_V1_EVIDENCE_BUNDLE.json" "Schema matches."
    } else {
      Add-Check "bundle-schema" "Bundle schema" "fail" "DESKTOP_V1_EVIDENCE_BUNDLE.json" "Unexpected schema: $($bundle.schema)."
    }

    if (Test-Commit ([string]$bundle.sourceCommit)) {
      Add-Check "source-commit" "Source commit" "pass" "DESKTOP_V1_EVIDENCE_BUNDLE.json" "Full source commit recorded."
    } else {
      Add-Check "source-commit" "Source commit" "pending" "DESKTOP_V1_EVIDENCE_BUNDLE.json" "Record a full 40-character source commit."
    }

    if ([string]$bundle.hardwareEvidenceStatus -in @("verified", "pass", "passed") -and [string]$bundle.hardwareEvidenceRoot -notmatch "<|pending|TBD") {
      Add-Check "hardware-evidence" "Physical robot hardware evidence" "pass" "DESKTOP_V1_EVIDENCE_BUNDLE.json" "Hardware evidence is recorded as verified."
    } else {
      Add-Check "hardware-evidence" "Physical robot hardware evidence" "pending" "DESKTOP_V1_EVIDENCE_BUNDLE.json" "Record verified hardware evidence root after tools/verify_hardware_evidence.cmd passes."
    }

    if ([string]$bundle.desktopRuntimePayloadStatus -in @("verified", "pass", "passed", "ready")) {
      Add-Check "runtime-payload-status" "Managed runtime payload status" "pass" "DESKTOP_V1_EVIDENCE_BUNDLE.json" "Managed runtime payload status is recorded as ready."
    } else {
      Add-Check "runtime-payload-status" "Managed runtime payload status" "pending" "DESKTOP_V1_EVIDENCE_BUNDLE.json" "Record platform-native Windows, macOS, and Linux payload readiness."
    }

    if ([string]$bundle.pcBrainLabStatus -in @("verified", "pass", "passed", "ready")) {
      Add-Check "pc-brain-lab-status" "PC Brain lab status" "pass" "DESKTOP_V1_EVIDENCE_BUNDLE.json" "PC Brain lab status is recorded as ready."
    } else {
      Add-Check "pc-brain-lab-status" "PC Brain lab status" "pending" "DESKTOP_V1_EVIDENCE_BUNDLE.json" "Record deploy audio and quiet-soak readiness."
    }

    $artifacts = Get-Field $bundle "artifacts"
    Test-DesktopArtifact "artifact-windows" "Windows desktop package artifact" $artifacts "windowsMsi" ".msi"
    Test-DesktopArtifact "artifact-macos" "macOS desktop package artifact" $artifacts "macosDmg" ".dmg"
    Test-DesktopArtifact "artifact-linux" "Linux desktop package artifact" $artifacts "linuxDeb" ".deb"

    $reports = Get-Field $bundle "reports"
    Test-ReportStatus "companion-readiness" "Companion source readiness report" $reports "companionReadinessReport" "stackchan.companion-v1-readiness.v1" "source-ready-pending-hardware"
    Test-C6Report "c6-brain-supervisor" "C6 brain supervisor smoke report" $reports "c6BrainSupervisorSmokeReport" "stackchan.companion.c6-brain-supervisor-smoke.v1"
    Test-C6Report "c6-gui-rehearsal" "C6 GUI rehearsal report" $reports "c6GuiRehearsalReport" "stackchan.companion.c6-gui-rehearsal.v1"
    Test-ReportStatus "runtime-windows" "Windows managed Python runtime payload report" $reports "windowsRuntimePayloadReport" "stackchan.desktop-python-runtime-payload.v1" "ready"
    Test-ReportStatus "runtime-macos" "macOS managed Python runtime payload report" $reports "macosRuntimePayloadReport" "stackchan.desktop-python-runtime-payload.v1" "ready"
    Test-ReportStatus "runtime-linux" "Linux managed Python runtime payload report" $reports "linuxRuntimePayloadReport" "stackchan.desktop-python-runtime-payload.v1" "ready"
    Test-ReportStatus "pc-brain-deploy" "PC Brain deploy audio evidence report" $reports "pcBrainDeployCheckReport" "stackchan.pc-brain-deploy-evidence-check.v1" "pc-brain-deploy-ready"
    Test-ReportStatus "pc-brain-quiet-soak" "PC Brain quiet-soak evidence report" $reports "pcBrainQuietSoakCheckReport" "stackchan.pc-brain-quiet-soak-evidence-check.v1" "pc-brain-quiet-soak-ready"
    Test-ReportStatus "voice-source-ready" "Production voice-source readiness report" $reports "voiceSourceReadinessReport" "stackchan.voice-source-readiness.v1" "production-voice-source-ready"
    Test-ReportFieldEquals "pc-brain-deploy-commit-match" "PC Brain deploy evidence matches bundle commit" $reports "pcBrainDeployCheckReport" "sourceCommit" ([string]$bundle.sourceCommit) "sourceCommit"
    Test-ReportFieldEquals "pc-brain-quiet-soak-commit-match" "PC Brain quiet-soak evidence matches bundle commit" $reports "pcBrainQuietSoakCheckReport" "sourceCommit" ([string]$bundle.sourceCommit) "sourceCommit"
    Test-ReportFieldEquals "voice-source-commit-match" "Production voice-source readiness matches bundle commit" $reports "voiceSourceReadinessReport" "sourceCommit" ([string]$bundle.sourceCommit) "sourceCommit"

    $reviewPath = Resolve-EvidencePath ([string]$bundle.reviewPath)
    if ([string]::IsNullOrWhiteSpace([string]$bundle.reviewPath) -or -not (Test-Path -LiteralPath $reviewPath -PathType Leaf)) {
      Add-Check "desktop-v1-review" "Desktop v1 human review" "pending" (Convert-ToRelativePath $reviewPath) "Complete DESKTOP_V1_REVIEW.md."
    } else {
      $review = Get-Content -LiteralPath $reviewPath -Raw
      $requiredReviewPatterns = @(
        "Reviewer:",
        "Review date:",
        "Source commit:",
        "Overall desktop v1 decision: pass",
        "Desktop package artifact decision: pass",
        "Managed Python runtime decision: pass",
        "C6 GUI/supervisor evidence decision: pass",
        "PC Brain deploy audio decision: pass",
        "PC Brain quiet-soak decision: pass",
        "Physical robot evidence decision: pass",
        "Production voice-source decision: pass"
      )
      $missing = @($requiredReviewPatterns | Where-Object { $review -notmatch [regex]::Escape($_) })
      $reviewSourceCommit = Get-ReviewSourceCommit $review
      if ($missing.Count -eq 0 -and (Test-Commit $reviewSourceCommit) -and $reviewSourceCommit -eq [string]$bundle.sourceCommit) {
        Add-Check "desktop-v1-review" "Desktop v1 human review" "pass" (Convert-ToRelativePath $reviewPath) "All desktop v1 decisions are pass."
      } elseif ((Test-Commit $reviewSourceCommit) -and $reviewSourceCommit -ne [string]$bundle.sourceCommit) {
        Add-Check "desktop-v1-review" "Desktop v1 human review" "fail" (Convert-ToRelativePath $reviewPath) "Review Source commit $reviewSourceCommit does not match bundle sourceCommit $($bundle.sourceCommit)."
      } else {
        $missingDetail = if ($missing.Count -eq 0) { "Source commit must be a full 40-character SHA matching bundle sourceCommit." } else { "Missing review markers: " + ($missing -join ", ") }
        Add-Check "desktop-v1-review" "Desktop v1 human review" "pending" (Convert-ToRelativePath $reviewPath) $missingDetail
      }
    }
  }
}

$failedChecks = @($checks | Where-Object { $_.status -eq "fail" })
$pendingChecks = @($checks | Where-Object { $_.status -eq "pending" })
$passedChecks = @($checks | Where-Object { $_.status -eq "pass" })
$status = if ($failedChecks.Count -gt 0) { "not-ready" } elseif ($pendingChecks.Count -gt 0) { "pending-desktop-v1-evidence-bundle" } else { "desktop-v1-evidence-ready" }

$report = [ordered]@{
  schema = "stackchan.desktop-v1-evidence-bundle-check.v1"
  status = $status
  root = [string]$Root
  evidenceRoot = Convert-ToRelativePath $EvidenceRoot
  sourceCommit = if ($null -ne $bundle) { [string]$bundle.sourceCommit } else { "" }
  passed = $passedChecks.Count
  failed = $failedChecks.Count
  pending = $pendingChecks.Count
  checks = @($checks)
}

if ($Json) {
  $report | ConvertTo-Json -Depth 8
} else {
  Write-Host "Desktop v1 evidence bundle: $status"
  Write-Host "Evidence root: $(Convert-ToRelativePath $EvidenceRoot)"
  Write-Host "Passed: $($passedChecks.Count)  Failed: $($failedChecks.Count)  Pending: $($pendingChecks.Count)"
  foreach ($check in $checks) {
    $prefix = if ($check.status -eq "pass") { "PASS" } elseif ($check.status -eq "pending") { "PENDING" } else { "FAIL" }
    Write-Host "[$prefix] $($check.name) - $($check.detail)"
  }
}

if ($failedChecks.Count -gt 0 -or ($RequireReady -and $status -ne "desktop-v1-evidence-ready")) {
  exit 1
}
