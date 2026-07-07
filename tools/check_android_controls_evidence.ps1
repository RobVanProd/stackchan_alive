param(
  [string]$Root = "",
  [string]$DiagnosticsExportPath = "output/android-controls/latest/ANDROID_DIAGNOSTICS_EXPORT.json",
  [string]$RobotLogPath = "output/android-controls/latest/robot_controls_serial.log",
  [string]$ReviewPath = "output/android-controls/latest/ANDROID_CONTROLS_REVIEW.md",
  [Alias("SourceCommit")]
  [string]$ExpectedSourceCommit = "",
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

foreach ($name in @("DiagnosticsExportPath", "RobotLogPath", "ReviewPath")) {
  $value = Get-Variable -Name $name -ValueOnly
  if (-not [System.IO.Path]::IsPathRooted($value)) {
    Set-Variable -Name $name -Value (Join-Path $Root $value)
  }
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

function Test-HasField {
  param(
    [object]$Object,
    [string]$Name
  )

  return $null -ne $Object -and $null -ne $Object.PSObject.Properties[$Name]
}

function Test-TrueField {
  param(
    [object]$Object,
    [string]$Name
  )

  return (Test-HasField $Object $Name) -and ((Get-Field $Object $Name) -eq $true)
}

function Test-StringPresent {
  param([object]$Value)

  return -not [string]::IsNullOrWhiteSpace([string]$Value)
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

function Add-ExactFieldCheck {
  param(
    [string]$Id,
    [string]$Name,
    [object]$Actual,
    [object]$Expected,
    [string]$Evidence
  )

  if ($Actual -eq $Expected) {
    Add-Check $Id $Name "pass" $Evidence "Value matches expected release contract."
  } else {
    Add-Check $Id $Name "fail" $Evidence "Expected '$Expected' but found '$Actual'."
  }
}

function Add-RequiredTextPatterns {
  param(
    [string]$Id,
    [string]$Name,
    [string]$Text,
    [string[]]$Patterns,
    [string]$Evidence,
    [string]$MissingDetail
  )

  $missing = @()
  foreach ($pattern in $Patterns) {
    if ($Text -notmatch [regex]::Escape($pattern)) {
      $missing += $pattern
    }
  }

  if ($missing.Count -gt 0) {
    Add-Check $Id $Name "pending" $Evidence ($MissingDetail + " Missing: " + ($missing -join ", "))
  } else {
    Add-Check $Id $Name "pass" $Evidence "Required markers are present."
  }
}

function Write-ControlsReviewTemplate {
  $reviewDirectory = Split-Path -Parent $ReviewPath
  if (-not [string]::IsNullOrWhiteSpace($reviewDirectory)) {
    New-Item -ItemType Directory -Force -Path $reviewDirectory | Out-Null
  }

  @"
# Android Protected Controls Evidence Review

Complete this after running the final Android build on a real phone with the physical Stack-chan connected.

- Reviewer:
- Review date:
- Support decision: pending
- Android device:
- Android version:
- App version:
- Source commit:
- Diagnostics export path: ANDROID_DIAGNOSTICS_EXPORT.json
- Robot control log path: robot_controls_serial.log
- Settings write decision: pending
- Claim brain decision: pending
- Release brain decision: pending
- Robot hello gate decision: pending
- Privacy decision: pending

Required review:

- Before robot `hello`, protected settings writes and manual claim/release stay blocked or return `robot_hello_required`.
- After robot `hello`, Android protected settings changes send `settings_set` and the robot replies with `settings_result`.
- Manual Claim sends `claim_brain`; the robot replies with `owner_status` naming the phone as active brain owner.
- Manual Release sends `release_brain`; the robot replies with `owner_status` released/idle or naming the promoted owner.
- Diagnostics export shows a connected robot socket, robot identity, active brain owner state, and no raw audio retention.
"@ | Set-Content -Path $ReviewPath -Encoding UTF8
}

if ($WriteTemplate) {
  Write-ControlsReviewTemplate
}

$exportEvidence = Convert-ToRelativePath $DiagnosticsExportPath
$robotEvidence = Convert-ToRelativePath $RobotLogPath
$reviewEvidence = Convert-ToRelativePath $ReviewPath
$sourceCommit = ""
$expectedSourceCommitValue = [string]$ExpectedSourceCommit

if (-not (Test-Path -LiteralPath $DiagnosticsExportPath -PathType Leaf)) {
  Add-Check "diagnostics-export-json" "Android diagnostics export JSON" "pending" $exportEvidence "Share ANDROID_DIAGNOSTICS_EXPORT.json after settings and handoff controls are exercised on a connected robot."
} else {
  Add-Check "diagnostics-export-json" "Android diagnostics export JSON" "pass" $exportEvidence "Diagnostics export JSON exists."
  try {
    $diagnostics = Get-Content -LiteralPath $DiagnosticsExportPath -Raw | ConvertFrom-Json
  } catch {
    Add-Check "diagnostics-export-json-parse" "Android diagnostics export parses" "fail" $exportEvidence $_.Exception.Message
    $diagnostics = $null
  }

  if ($null -ne $diagnostics) {
    Add-ExactFieldCheck "schema" "Diagnostics export schema" (Get-Field $diagnostics "schema") "stackchan.android.diagnostics-export.v1" $exportEvidence

    $bridge = Get-Field $diagnostics "bridge"
    $robot = Get-Field $diagnostics "robot"
    $endpoint = Get-Field $diagnostics "endpoint"
    $privacy = Get-Field $diagnostics "privacy"

    if ((Test-TrueField $bridge "robot_socket_connected") -and (Test-TrueField $robot "connected")) {
      Add-Check "robot-connected" "Robot connected during controls run" "pass" $exportEvidence "Diagnostics show a connected robot session."
    } else {
      Add-Check "robot-connected" "Robot connected during controls run" "pending" $exportEvidence "Capture diagnostics after the physical robot hello while the Android bridge is connected."
    }

    if ((Test-StringPresent (Get-Field $robot "device_id")) -and (Test-StringPresent (Get-Field $robot "firmware_version"))) {
      Add-Check "robot-identity" "Robot identity present" "pass" $exportEvidence "Robot device id and firmware version are present."
    } else {
      Add-Check "robot-identity" "Robot identity present" "pending" $exportEvidence "Capture diagnostics after robot hello so identity and firmware fields are present."
    }

    if ((Get-Field $endpoint "endpoint_kind") -eq "android" -and (Test-StringPresent (Get-Field $endpoint "endpoint_id"))) {
      Add-Check "android-endpoint" "Android endpoint identity present" "pass" $exportEvidence "Android endpoint id and kind are present."
    } else {
      Add-Check "android-endpoint" "Android endpoint identity present" "fail" $exportEvidence "Diagnostics export must identify the Android endpoint that claimed brain ownership."
    }

    if (Test-StringPresent (Get-Field $bridge "active_brain_owner")) {
      Add-Check "active-brain-owner" "Active brain owner field present" "pass" $exportEvidence "Diagnostics include active_brain_owner for handoff review."
    } else {
      Add-Check "active-brain-owner" "Active brain owner field present" "pending" $exportEvidence "Capture diagnostics after Claim or Release so active_brain_owner is reviewable."
    }

    Add-ExactFieldCheck "raw-audio-retention" "Raw audio retention" (Get-Field $privacy "raw_audio_retention") "none" $exportEvidence
  }
}

if (-not (Test-Path -LiteralPath $RobotLogPath -PathType Leaf)) {
  Add-Check "robot-controls-log" "Robot protected controls log" "pending" $robotEvidence "Capture robot serial/control log for settings_set, settings_result, claim_brain, release_brain, and owner_status."
} else {
  $robotText = Get-Content -LiteralPath $RobotLogPath -Raw
  Add-RequiredTextPatterns `
    -Id "robot-controls-round-trip" `
    -Name "Robot protected controls round trip" `
    -Text $robotText `
    -Patterns @("settings_set", "settings_result", "claim_brain", "owner_status", "release_brain") `
    -Evidence $robotEvidence `
    -MissingDetail "Capture the protected settings and manual handoff round trip."

  Add-RequiredTextPatterns `
    -Id "robot-hello-gate" `
    -Name "Robot hello gate evidence" `
    -Text $robotText `
    -Patterns @("robot_hello_required") `
    -Evidence $robotEvidence `
    -MissingDetail "Capture the pre-hello blocked state before exercising protected controls."
}

if (-not (Test-Path -LiteralPath $ReviewPath -PathType Leaf)) {
  Add-Check "controls-review" "Android controls human review packet" "pending" $reviewEvidence "Run with -WriteTemplate and complete the controls review after the real-device run."
} else {
  $reviewText = Get-Content -LiteralPath $ReviewPath -Raw
  $sourceCommit = Get-ReviewSourceCommit $reviewText
  $reviewerOk = $reviewText -match "(?im)^-\s*Reviewer:\s*\S+"
  $dateOk = $reviewText -match "(?im)^-\s*Review date:\s*\d{4}-\d{2}-\d{2}\s*$"
  $sourceCommitOk = Test-Commit $sourceCommit
  $supportOk = $reviewText -match "(?im)^-\s*Support decision:\s*pass\s*$"
  $settingsOk = $reviewText -match "(?im)^-\s*Settings write decision:\s*pass\s*$"
  $claimOk = $reviewText -match "(?im)^-\s*Claim brain decision:\s*pass\s*$"
  $releaseOk = $reviewText -match "(?im)^-\s*Release brain decision:\s*pass\s*$"
  $helloGateOk = $reviewText -match "(?im)^-\s*Robot hello gate decision:\s*pass\s*$"
  $privacyOk = $reviewText -match "(?im)^-\s*Privacy decision:\s*pass\s*$"
  if ($reviewerOk -and $dateOk -and $sourceCommitOk -and $supportOk -and $settingsOk -and $claimOk -and $releaseOk -and $helloGateOk -and $privacyOk) {
    Add-Check "controls-review" "Android controls human review packet" "pass" $reviewEvidence "Reviewer, date, support, settings, claim, release, hello gate, and privacy decisions are pass."
  } else {
    Add-Check "controls-review" "Android controls human review packet" "pending" $reviewEvidence "Complete Reviewer, Review date (YYYY-MM-DD), Source commit: <40-character SHA>, Support decision: pass, Settings write decision: pass, Claim brain decision: pass, Release brain decision: pass, Robot hello gate decision: pass, and Privacy decision: pass."
  }

  if (Test-Commit $expectedSourceCommitValue) {
    if ($sourceCommitOk -and $sourceCommit -eq $expectedSourceCommitValue) {
      Add-Check "controls-review-source-commit-match" "Android controls review source commit matches expected commit" "pass" $reviewEvidence "Review source commit matches expected SourceCommit."
    } elseif ($sourceCommitOk) {
      Add-Check "controls-review-source-commit-match" "Android controls review source commit matches expected commit" "fail" $reviewEvidence "Review source commit $sourceCommit does not match expected SourceCommit $expectedSourceCommitValue."
    } else {
      Add-Check "controls-review-source-commit-match" "Android controls review source commit matches expected commit" "fail" $reviewEvidence "Review must record a full 40-character Source commit before strict evidence collection."
    }
  }
}

$failCount = @($checks | Where-Object { $_.status -eq "fail" }).Count
$pendingCount = @($checks | Where-Object { $_.status -eq "pending" }).Count
$passCount = @($checks | Where-Object { $_.status -eq "pass" }).Count
$status = if ($failCount -gt 0) { "not-ready" } elseif ($pendingCount -gt 0) { "pending-android-controls-evidence" } else { "android-controls-ready" }

$report = [ordered]@{
  schema = "stackchan.android-controls-evidence.v1"
  status = $status
  sourceCommit = $sourceCommit
  expectedSourceCommit = $expectedSourceCommitValue
  root = [string]$Root
  diagnosticsExportPath = Convert-ToRelativePath $DiagnosticsExportPath
  robotLogPath = Convert-ToRelativePath $RobotLogPath
  reviewPath = Convert-ToRelativePath $ReviewPath
  passCount = $passCount
  failCount = $failCount
  pendingCount = $pendingCount
  requireReady = [bool]$RequireReady
  checks = $checks
}

if ($Json) {
  $report | ConvertTo-Json -Depth 8
} else {
  Write-Host "Android controls evidence status: $status"
  Write-Host "Pass: $passCount  Fail: $failCount  Pending: $pendingCount"
  foreach ($check in $checks) {
    Write-Host ("[{0}] {1} - {2}" -f $check.status, $check.id, $check.detail)
  }
}

if ($failCount -gt 0 -or ($RequireReady -and $pendingCount -gt 0)) {
  exit 1
}
