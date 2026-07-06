param(
  [string]$Root = "",
  [string]$SoakJsonPath = "output/android-companion-soak/latest/android_companion_soak.json",
  [string]$SoakMarkdownPath = "output/android-companion-soak/latest/ANDROID_COMPANION_SOAK.md",
  [string]$ReviewPath = "output/android-companion-soak/latest/ANDROID_SCREEN_OFF_SOAK_REVIEW.md",
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

foreach ($name in @("SoakJsonPath", "SoakMarkdownPath", "ReviewPath")) {
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

function Convert-ToIntOrNull {
  param([object]$Value)

  if ($null -eq $Value -or [string]::IsNullOrWhiteSpace([string]$Value)) {
    return $null
  }
  try {
    return [int]$Value
  } catch {
    return $null
  }
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

function Write-SoakReviewTemplate {
  $reviewDirectory = Split-Path -Parent $ReviewPath
  if (-not [string]::IsNullOrWhiteSpace($reviewDirectory)) {
    New-Item -ItemType Directory -Force -Path $reviewDirectory | Out-Null
  }

  @"
# Android Screen-Off Soak Evidence Review

Complete this after running the final Android build on the target phone with the physical Stack-chan connected.

- Reviewer:
- Review date:
- Support decision: pending
- Android device:
- Android version:
- App version:
- Source commit:
- Soak JSON path: android_companion_soak.json
- Soak summary path: ANDROID_COMPANION_SOAK.md
- Screen-off decision: pending
- Heartbeat continuity decision: pending
- Wake-lock release decision: pending
- Foreground-service decision: pending
- Reopen identity decision: pending

Required review:

- Phone screen stayed off for the full strict 10-minute soak window.
- Soak report status is `pass`, `sample_count` is greater than one, and every sample passed.
- Every sample is from `endpoint_kind=android` with a stable non-empty endpoint id.
- The foreground notification stayed active while the robot session was connected.
- Android session wake lock released after robot disconnect.
- Reopening the app still showed the same endpoint identity and saved robot state.
"@ | Set-Content -Path $ReviewPath -Encoding UTF8
}

if ($WriteTemplate) {
  Write-SoakReviewTemplate
}

$jsonEvidence = Convert-ToRelativePath $SoakJsonPath
$markdownEvidence = Convert-ToRelativePath $SoakMarkdownPath
$reviewEvidence = Convert-ToRelativePath $ReviewPath

if (-not (Test-Path -LiteralPath $SoakJsonPath -PathType Leaf)) {
  Add-Check "soak-json" "Android screen-off soak JSON" "pending" $jsonEvidence "Run tools/run_android_companion_soak.cmd while the Android phone is the active bridge host."
} else {
  Add-Check "soak-json" "Android screen-off soak JSON" "pass" $jsonEvidence "Screen-off soak JSON exists."
  try {
    $soak = Get-Content -LiteralPath $SoakJsonPath -Raw | ConvertFrom-Json
  } catch {
    Add-Check "soak-json-parse" "Android screen-off soak JSON parses" "fail" $jsonEvidence $_.Exception.Message
    $soak = $null
  }

  if ($null -ne $soak) {
    Add-ExactFieldCheck "schema" "Soak report schema" (Get-Field $soak "schema") "stackchan.android-companion-soak.v1" $jsonEvidence
    Add-ExactFieldCheck "status" "Soak report status" (Get-Field $soak "status") "pass" $jsonEvidence

    $duration = Convert-ToDoubleOrNull (Get-Field $soak "requested_duration_seconds")
    if ($null -ne $duration -and $duration -ge 600.0) {
      Add-Check "duration" "Strict soak duration" "pass" $jsonEvidence "Requested duration is at least 600 seconds."
    } else {
      Add-Check "duration" "Strict soak duration" "fail" $jsonEvidence "Expected requested_duration_seconds >= 600."
    }

    $interval = Convert-ToDoubleOrNull (Get-Field $soak "interval_seconds")
    if ($null -ne $interval -and $interval -le 30.0 -and $interval -gt 0.0) {
      Add-Check "interval" "Strict soak sample interval" "pass" $jsonEvidence "Sample interval is no more than 30 seconds."
    } else {
      Add-Check "interval" "Strict soak sample interval" "fail" $jsonEvidence "Expected 0 < interval_seconds <= 30."
    }

    $maxFailures = Convert-ToIntOrNull (Get-Field $soak "max_failures")
    Add-ExactFieldCheck "max-failures" "Strict max failures" $maxFailures 0 $jsonEvidence
    Add-ExactFieldCheck "failed-count" "No failed soak samples" (Convert-ToIntOrNull (Get-Field $soak "failed_count")) 0 $jsonEvidence

    $successRate = Convert-ToDoubleOrNull (Get-Field $soak "success_rate")
    if ($null -ne $successRate -and $successRate -ge 1.0) {
      Add-Check "success-rate" "Full soak success rate" "pass" $jsonEvidence "success_rate is 1.0."
    } else {
      Add-Check "success-rate" "Full soak success rate" "fail" $jsonEvidence "Expected success_rate >= 1.0."
    }

    $samples = @(Get-Field $soak "samples")
    $sampleCount = Convert-ToIntOrNull (Get-Field $soak "sample_count")
    if ($null -ne $sampleCount -and $sampleCount -gt 1 -and $samples.Count -eq $sampleCount) {
      Add-Check "sample-count" "Multiple soak samples captured" "pass" $jsonEvidence "sample_count matches captured samples."
    } else {
      Add-Check "sample-count" "Multiple soak samples captured" "fail" $jsonEvidence "Expected sample_count > 1 and matching samples array."
    }

    $badSamples = @()
    $endpointIds = @{}
    foreach ($sample in $samples) {
      $index = Get-Field $sample "index"
      $status = [string](Get-Field $sample "status")
      $endpointKind = [string](Get-Field $sample "endpoint_kind")
      $endpointId = [string](Get-Field $sample "endpoint_id")
      if ($status -ne "pass" -or $endpointKind -ne "android" -or [string]::IsNullOrWhiteSpace($endpointId)) {
        $badSamples += "sample $index status=$status endpoint_kind=$endpointKind endpoint_id=$endpointId"
      }
      if (-not [string]::IsNullOrWhiteSpace($endpointId)) {
        $endpointIds[$endpointId] = $true
      }
    }

    if ($badSamples.Count -eq 0 -and $samples.Count -gt 0) {
      Add-Check "android-samples" "All soak samples are passing Android endpoint samples" "pass" $jsonEvidence "Every sample passed and reported endpoint_kind=android."
    } else {
      Add-Check "android-samples" "All soak samples are passing Android endpoint samples" "fail" $jsonEvidence ("Invalid samples: " + ($badSamples -join "; "))
    }

    if ($endpointIds.Keys.Count -eq 1) {
      Add-Check "stable-endpoint" "Stable Android endpoint identity" "pass" $jsonEvidence "All samples used the same Android endpoint id."
    } else {
      Add-Check "stable-endpoint" "Stable Android endpoint identity" "pending" $jsonEvidence "Expected all samples to use one stable Android endpoint id."
    }
  }
}

if (-not (Test-Path -LiteralPath $SoakMarkdownPath -PathType Leaf)) {
  Add-Check "soak-summary" "Android screen-off soak markdown summary" "pending" $markdownEvidence "Keep ANDROID_COMPANION_SOAK.md with the JSON report."
} else {
  $summaryText = Get-Content -LiteralPath $SoakMarkdownPath -Raw
  Add-RequiredTextPatterns `
    -Id "soak-summary-markers" `
    -Name "Soak markdown summary markers" `
    -Text $summaryText `
    -Patterns @('# Android Companion Screen-Off Soak', '- Status: `pass`', '- Failed: `0`', 'RUN_ANDROID_LOGCAT_CAPTURE.cmd') `
    -Evidence $markdownEvidence `
    -MissingDetail "Regenerate the soak summary from the strict helper."
}

if (-not (Test-Path -LiteralPath $ReviewPath -PathType Leaf)) {
  Add-Check "soak-review" "Android screen-off soak human review packet" "pending" $reviewEvidence "Run with -WriteTemplate and complete the screen-off soak review after the real-device run."
} else {
  $reviewText = Get-Content -LiteralPath $ReviewPath -Raw
  $reviewerOk = $reviewText -match "(?im)^-\s*Reviewer:\s*\S+"
  $dateOk = $reviewText -match "(?im)^-\s*Review date:\s*\d{4}-\d{2}-\d{2}\s*$"
  $supportOk = $reviewText -match "(?im)^-\s*Support decision:\s*pass\s*$"
  $screenOffOk = $reviewText -match "(?im)^-\s*Screen-off decision:\s*pass\s*$"
  $heartbeatOk = $reviewText -match "(?im)^-\s*Heartbeat continuity decision:\s*pass\s*$"
  $wakeLockOk = $reviewText -match "(?im)^-\s*Wake-lock release decision:\s*pass\s*$"
  $foregroundOk = $reviewText -match "(?im)^-\s*Foreground-service decision:\s*pass\s*$"
  $reopenOk = $reviewText -match "(?im)^-\s*Reopen identity decision:\s*pass\s*$"
  if ($reviewerOk -and $dateOk -and $supportOk -and $screenOffOk -and $heartbeatOk -and $wakeLockOk -and $foregroundOk -and $reopenOk) {
    Add-Check "soak-review" "Android screen-off soak human review packet" "pass" $reviewEvidence "Reviewer, date, support, screen-off, heartbeat, wake-lock, foreground-service, and reopen identity decisions are pass."
  } else {
    Add-Check "soak-review" "Android screen-off soak human review packet" "pending" $reviewEvidence "Complete Reviewer, Review date (YYYY-MM-DD), Support decision: pass, Screen-off decision: pass, Heartbeat continuity decision: pass, Wake-lock release decision: pass, Foreground-service decision: pass, and Reopen identity decision: pass."
  }
}

$failCount = @($checks | Where-Object { $_.status -eq "fail" }).Count
$pendingCount = @($checks | Where-Object { $_.status -eq "pending" }).Count
$passCount = @($checks | Where-Object { $_.status -eq "pass" }).Count
$status = if ($failCount -gt 0) { "not-ready" } elseif ($pendingCount -gt 0) { "pending-android-screen-off-soak-evidence" } else { "android-screen-off-soak-ready" }

$report = [ordered]@{
  schema = "stackchan.android-screen-off-soak-evidence.v1"
  status = $status
  root = [string]$Root
  soakJsonPath = Convert-ToRelativePath $SoakJsonPath
  soakMarkdownPath = Convert-ToRelativePath $SoakMarkdownPath
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
  Write-Host "Android screen-off soak evidence status: $status"
  Write-Host "Pass: $passCount  Fail: $failCount  Pending: $pendingCount"
  foreach ($check in $checks) {
    Write-Host ("[{0}] {1} - {2}" -f $check.status, $check.id, $check.detail)
  }
}

if ($failCount -gt 0 -or ($RequireReady -and $pendingCount -gt 0)) {
  exit 1
}
