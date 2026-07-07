param(
  [string]$Root = "",
  [string]$DiagnosticsExportPath = "output/android-pairing/latest/ANDROID_DIAGNOSTICS_EXPORT.json",
  [string]$RobotLogPath = "output/android-pairing/latest/robot_pairing_serial.log",
  [string]$PairingMediaPath = "output/android-pairing/latest/android_pairing_setup.jpg",
  [string]$ReviewPath = "output/android-pairing/latest/ANDROID_PAIRING_REVIEW.md",
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

foreach ($name in @("DiagnosticsExportPath", "RobotLogPath", "PairingMediaPath", "ReviewPath")) {
  $value = Get-Variable -Name $name -ValueOnly
  if (-not [System.IO.Path]::IsPathRooted($value)) {
    Set-Variable -Name $name -Value (Join-Path $Root $value)
  }
}

$expectedSourceCommitValue = [string]$ExpectedSourceCommit
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

function Test-SupportedMediaFile {
  param([string]$Path)

  $extension = [System.IO.Path]::GetExtension($Path).ToLowerInvariant()
  return $extension -in @(".jpg", ".jpeg", ".png", ".webp", ".mp4", ".mov")
}

function Write-PairingReviewTemplate {
  $reviewDirectory = Split-Path -Parent $ReviewPath
  if (-not [string]::IsNullOrWhiteSpace($reviewDirectory)) {
    New-Item -ItemType Directory -Force -Path $reviewDirectory | Out-Null
  }

  @"
# Android Pairing Evidence Review

Complete this after running the final Android build on a real phone with the physical Stack-chan connected.

- Reviewer:
- Review date:
- Support decision: pending
- Android device:
- Android version:
- App version:
- Source commit:
- Diagnostics export path: ANDROID_DIAGNOSTICS_EXPORT.json
- Robot pairing log path: robot_pairing_serial.log
- Pairing media path: android_pairing_setup.jpg
- Setup media decision: pending
- Wrong-code rejection decision: pending
- QR ticket/manual code decision: pending
- Trusted endpoint decision: pending
- Password privacy decision: pending

Required review:

- Android setup media shows the Add your Stack-chan flow with pairing code, phone fingerprint, bridge URL, and scannable `stackchan://pair` QR ticket or equivalent phone-side QR payload.
- A firmware pairing gate rejects a missing or wrong `endpoint_hello.pairing_code` with `pairing_code_mismatch`.
- Entering `pair ticket <stackchan://pair?...>` or the raw `stackchan://pair?...` payload applies the pairing code and bridge URL without containing or printing a Wi-Fi password.
- The correct Android `endpoint_hello.pairing_code` is accepted and the robot reports the phone in `trusted_endpoints_result`.
- Diagnostics export shows `pairing_code_present=true`, `pairing_qr_scheme=stackchan://pair`, a connected robot session, and `password_redacted=true`.
"@ | Set-Content -Path $ReviewPath -Encoding UTF8
}

if ($WriteTemplate) {
  Write-PairingReviewTemplate
}

$exportEvidence = Convert-ToRelativePath $DiagnosticsExportPath
$robotEvidence = Convert-ToRelativePath $RobotLogPath
$mediaEvidence = Convert-ToRelativePath $PairingMediaPath
$reviewEvidence = Convert-ToRelativePath $ReviewPath
$sourceCommit = ""

if (-not (Test-Path -LiteralPath $DiagnosticsExportPath -PathType Leaf)) {
  Add-Check "diagnostics-export-json" "Android diagnostics export JSON" "pending" $exportEvidence "Share ANDROID_DIAGNOSTICS_EXPORT.json after pairing a physical robot from Android."
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

    $endpoint = Get-Field $diagnostics "endpoint"
    $pairing = Get-Field $diagnostics "pairing"
    $bridge = Get-Field $diagnostics "bridge"
    $robot = Get-Field $diagnostics "robot"

    if ((Get-Field $endpoint "endpoint_kind") -eq "android" -and (Test-StringPresent (Get-Field $endpoint "endpoint_id"))) {
      Add-Check "android-endpoint" "Android endpoint identity present" "pass" $exportEvidence "Android endpoint id and kind are present."
    } else {
      Add-Check "android-endpoint" "Android endpoint identity present" "fail" $exportEvidence "Diagnostics export must identify the Android endpoint used for pairing."
    }

    if (Test-TrueField $pairing "pairing_code_present") {
      Add-Check "pairing-code-present" "Pairing code present" "pass" $exportEvidence "Diagnostics show the Android endpoint has a displayed pairing code."
    } else {
      Add-Check "pairing-code-present" "Pairing code present" "fail" $exportEvidence "Diagnostics must show pairing_code_present=true for QR/short-code evidence."
    }
    Add-ExactFieldCheck "pairing-qr-scheme" "Pairing QR scheme" (Get-Field $pairing "pairing_qr_scheme") "stackchan://pair" $exportEvidence
    if (Test-TrueField $pairing "password_redacted") {
      Add-Check "password-redacted" "Pairing privacy redacts Wi-Fi password" "pass" $exportEvidence "password_redacted=true."
    } else {
      Add-Check "password-redacted" "Pairing privacy redacts Wi-Fi password" "fail" $exportEvidence "Pairing diagnostics must never expose a Wi-Fi password."
    }

    if ((Test-TrueField $bridge "robot_socket_connected") -and (Test-TrueField $robot "connected") -and (Test-StringPresent (Get-Field $robot "device_id"))) {
      Add-Check "robot-connected" "Paired robot connected" "pass" $exportEvidence "Diagnostics show a connected robot after pairing."
    } else {
      Add-Check "robot-connected" "Paired robot connected" "pending" $exportEvidence "Capture diagnostics after the Android pairing flow reaches robot hello."
    }
  }
}

if (-not (Test-Path -LiteralPath $PairingMediaPath -PathType Leaf)) {
  Add-Check "pairing-media" "Android pairing setup media" "pending" $mediaEvidence "Attach a photo/video/screenshot showing the Add your Stack-chan QR/short-code setup surface."
} elseif (-not (Test-SupportedMediaFile $PairingMediaPath)) {
  Add-Check "pairing-media" "Android pairing setup media" "fail" $mediaEvidence "Use .jpg, .jpeg, .png, .webp, .mp4, or .mov media for the pairing evidence artifact."
} else {
  Add-Check "pairing-media" "Android pairing setup media" "pass" $mediaEvidence "Pairing setup media file exists with a supported extension."
}

if (-not (Test-Path -LiteralPath $RobotLogPath -PathType Leaf)) {
  Add-Check "robot-pairing-log" "Robot pairing serial log" "pending" $robotEvidence "Capture robot serial log for wrong-code rejection, QR ticket/manual code entry, and trusted endpoint acceptance."
} else {
  $robotText = Get-Content -LiteralPath $RobotLogPath -Raw
  Add-RequiredTextPatterns `
    -Id "wrong-code-rejection" `
    -Name "Wrong pairing code rejection" `
    -Text $robotText `
    -Patterns @("pairing_code_mismatch") `
    -Evidence $robotEvidence `
    -MissingDetail "Capture the firmware rejecting a missing or wrong endpoint_hello.pairing_code."

  Add-RequiredTextPatterns `
    -Id "qr-ticket-entry" `
    -Name "QR ticket or manual code setup entry" `
    -Text $robotText `
    -Patterns @("stackchan://pair?", "pairing_code", "bridge_url_applied") `
    -Evidence $robotEvidence `
    -MissingDetail "Capture the robot setup path applying the Android pairing ticket or equivalent manual QR payload."

  Add-RequiredTextPatterns `
    -Id "trusted-endpoint-acceptance" `
    -Name "Trusted Android endpoint acceptance" `
    -Text $robotText `
    -Patterns @("endpoint_hello", "endpoint_hello_result", "trusted_endpoints_result") `
    -Evidence $robotEvidence `
    -MissingDetail "Capture the correct Android endpoint hello and trusted endpoint registry result."

  if ($robotText -match "(?i)pass=|pass\s+`"|<network-password>") {
    Add-Check "robot-log-password-privacy" "Robot pairing log does not expose Wi-Fi password" "fail" $robotEvidence "Robot pairing log contains password-like text; redact or recapture without Wi-Fi password disclosure."
  } else {
    Add-Check "robot-log-password-privacy" "Robot pairing log does not expose Wi-Fi password" "pass" $robotEvidence "No password-like text found in the pairing log."
  }
}

if (-not (Test-Path -LiteralPath $ReviewPath -PathType Leaf)) {
  Add-Check "pairing-review" "Android pairing human review packet" "pending" $reviewEvidence "Run with -WriteTemplate and complete the pairing review after the real-device run."
} else {
  $reviewText = Get-Content -LiteralPath $ReviewPath -Raw
  $sourceCommit = Get-ReviewSourceCommit $reviewText
  $reviewerOk = $reviewText -match "(?im)^-\s*Reviewer:\s*\S+"
  $dateOk = $reviewText -match "(?im)^-\s*Review date:\s*\d{4}-\d{2}-\d{2}\s*$"
  $sourceCommitOk = Test-Commit $sourceCommit
  $supportOk = $reviewText -match "(?im)^-\s*Support decision:\s*pass\s*$"
  $mediaOk = $reviewText -match "(?im)^-\s*Setup media decision:\s*pass\s*$"
  $wrongCodeOk = $reviewText -match "(?im)^-\s*Wrong-code rejection decision:\s*pass\s*$"
  $ticketOk = $reviewText -match "(?im)^-\s*QR ticket/manual code decision:\s*pass\s*$"
  $trustedOk = $reviewText -match "(?im)^-\s*Trusted endpoint decision:\s*pass\s*$"
  $privacyOk = $reviewText -match "(?im)^-\s*Password privacy decision:\s*pass\s*$"
  if ($reviewerOk -and $dateOk -and $sourceCommitOk -and $supportOk -and $mediaOk -and $wrongCodeOk -and $ticketOk -and $trustedOk -and $privacyOk) {
    Add-Check "pairing-review" "Android pairing human review packet" "pass" $reviewEvidence "Reviewer, date, support, setup media, wrong-code, QR/manual, trusted endpoint, and privacy decisions are pass."
  } else {
    Add-Check "pairing-review" "Android pairing human review packet" "pending" $reviewEvidence "Complete Reviewer, Review date (YYYY-MM-DD), Source commit: <40-character SHA>, Support decision: pass, Setup media decision: pass, Wrong-code rejection decision: pass, QR ticket/manual code decision: pass, Trusted endpoint decision: pass, and Password privacy decision: pass."
  }

  if (-not [string]::IsNullOrWhiteSpace($expectedSourceCommitValue)) {
    if ($sourceCommitOk -and $sourceCommit -eq $expectedSourceCommitValue) {
      Add-Check "pairing-review-source-commit-match" "Android pairing review source commit matches expected commit" "pass" $reviewEvidence "Review source commit matches expected release source commit."
    } elseif ($sourceCommitOk) {
      Add-Check "pairing-review-source-commit-match" "Android pairing review source commit matches expected commit" "fail" $reviewEvidence "Review Source commit $sourceCommit does not match expected source commit $expectedSourceCommitValue."
    } else {
      Add-Check "pairing-review-source-commit-match" "Android pairing review source commit matches expected commit" "fail" $reviewEvidence "Review Source commit must be a full 40-character SHA matching expected source commit $expectedSourceCommitValue."
    }
  }
}

$failCount = @($checks | Where-Object { $_.status -eq "fail" }).Count
$pendingCount = @($checks | Where-Object { $_.status -eq "pending" }).Count
$passCount = @($checks | Where-Object { $_.status -eq "pass" }).Count
$status = if ($failCount -gt 0) { "not-ready" } elseif ($pendingCount -gt 0) { "pending-android-pairing-evidence" } else { "android-pairing-ready" }

$report = [ordered]@{
  schema = "stackchan.android-pairing-evidence.v1"
  status = $status
  sourceCommit = $sourceCommit
  expectedSourceCommit = $expectedSourceCommitValue
  root = [string]$Root
  diagnosticsExportPath = Convert-ToRelativePath $DiagnosticsExportPath
  robotLogPath = Convert-ToRelativePath $RobotLogPath
  pairingMediaPath = Convert-ToRelativePath $PairingMediaPath
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
  Write-Host "Android pairing evidence status: $status"
  Write-Host "Pass: $passCount  Fail: $failCount  Pending: $pendingCount"
  foreach ($check in $checks) {
    Write-Host ("[{0}] {1} - {2}" -f $check.status, $check.id, $check.detail)
  }
}

if ($failCount -gt 0 -or ($RequireReady -and $pendingCount -gt 0)) {
  exit 1
}
