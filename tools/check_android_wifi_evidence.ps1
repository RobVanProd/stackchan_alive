param(
  [string]$Root = "",
  [string]$DiagnosticsExportPath = "output/android-wifi/latest/ANDROID_DIAGNOSTICS_EXPORT.json",
  [string]$RobotLogPath = "output/android-wifi/latest/robot_wifi_serial.log",
  [string]$ReviewPath = "output/android-wifi/latest/ANDROID_WIFI_REVIEW.md",
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

function Write-WifiReviewTemplate {
  $reviewDirectory = Split-Path -Parent $ReviewPath
  if (-not [string]::IsNullOrWhiteSpace($reviewDirectory)) {
    New-Item -ItemType Directory -Force -Path $reviewDirectory | Out-Null
  }

  @"
# Android Wi-Fi Provisioning Evidence Review

Complete this after running the final Android build on a real phone with the physical Stack-chan connected.

- Reviewer:
- Review date:
- Support decision: pending
- Android device:
- Android version:
- App version:
- Source commit:
- Diagnostics export path: ANDROID_DIAGNOSTICS_EXPORT.json
- Robot Wi-Fi log path: robot_wifi_serial.log
- Wi-Fi command decision: pending
- Persistence decision: pending
- Power-cycle reload decision: pending
- Clear command decision: pending
- Password privacy decision: pending

Required review:

- Android diagnostics exposes a Wi-Fi provisioning command template with placeholder credentials and `password_redacted=true`.
- The robot accepts `wifi set ssid "<network-name>" pass "<network-password>" url "ws://<phone-lan-ip>:8765/bridge"` or the helper-generated equivalent.
- The robot reports `[wifi] persisted=1`, `store_has_record=1`, `enabled=1`, and `ssid_set=1` without printing the Wi-Fi password.
- After power cycle, runtime/status telemetry shows the saved bridge Wi-Fi record reloaded, for example `bridge_wifi_store_loads` and `bridge_wifi_store_has_record=1`.
- `wifi clear` returns the robot to the build-time/default bridge target and reports `store_has_record=0`.
"@ | Set-Content -Path $ReviewPath -Encoding UTF8
}

if ($WriteTemplate) {
  Write-WifiReviewTemplate
}

$exportEvidence = Convert-ToRelativePath $DiagnosticsExportPath
$robotEvidence = Convert-ToRelativePath $RobotLogPath
$reviewEvidence = Convert-ToRelativePath $ReviewPath

if (-not (Test-Path -LiteralPath $DiagnosticsExportPath -PathType Leaf)) {
  Add-Check "diagnostics-export-json" "Android diagnostics export JSON" "pending" $exportEvidence "Share ANDROID_DIAGNOSTICS_EXPORT.json after the Android setup card shows the robot Wi-Fi command template."
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

    $pairing = Get-Field $diagnostics "pairing"
    $bridge = Get-Field $diagnostics "bridge"
    $robot = Get-Field $diagnostics "robot"
    $wifiTemplate = [string](Get-Field $pairing "wifi_provisioning_command_template")

    if ($wifiTemplate -match 'wifi set ssid "?<network-name>"? pass "?<network-password>"? url "ws://' -or $wifiTemplate -eq "Start the phone bridge first, then rerun diagnostics to generate the Wi-Fi command template.") {
      Add-Check "wifi-command-template" "Wi-Fi command template uses placeholders" "pass" $exportEvidence "Template uses placeholder credentials or explains why bridge URL is not available."
    } else {
      Add-Check "wifi-command-template" "Wi-Fi command template uses placeholders" "fail" $exportEvidence "Diagnostics Wi-Fi command template must use placeholder credentials and a phone bridge URL."
    }

    Add-ExactFieldCheck "wifi-clear-command" "Wi-Fi clear command" (Get-Field $pairing "wifi_clear_command") "wifi clear" $exportEvidence
    if (Test-TrueField $pairing "password_redacted") {
      Add-Check "diagnostics-password-redacted" "Diagnostics redacts Wi-Fi password" "pass" $exportEvidence "password_redacted=true."
    } else {
      Add-Check "diagnostics-password-redacted" "Diagnostics redacts Wi-Fi password" "fail" $exportEvidence "Diagnostics must never include a real Wi-Fi password."
    }

    if ((Test-StringPresent (Get-Field $bridge "primary_bridge_url")) -or (Test-StringPresent $wifiTemplate)) {
      Add-Check "bridge-url-present" "Phone bridge URL available for provisioning" "pass" $exportEvidence "Diagnostics include bridge URL context for the provisioning template."
    } else {
      Add-Check "bridge-url-present" "Phone bridge URL available for provisioning" "pending" $exportEvidence "Start the Android bridge before exporting diagnostics so the command can target the phone URL."
    }

    if ((Test-TrueField $bridge "robot_socket_connected") -and (Test-TrueField $robot "connected")) {
      Add-Check "robot-connected" "Robot connected after Wi-Fi provisioning" "pass" $exportEvidence "Diagnostics show the robot connected through the Android bridge."
    } else {
      Add-Check "robot-connected" "Robot connected after Wi-Fi provisioning" "pending" $exportEvidence "Capture diagnostics after the robot reconnects through the provisioned Wi-Fi bridge target."
    }
  }
}

if (-not (Test-Path -LiteralPath $RobotLogPath -PathType Leaf)) {
  Add-Check "robot-wifi-log" "Robot Wi-Fi provisioning serial log" "pending" $robotEvidence "Capture robot serial/provisioning log for set, reconnect, power-cycle reload, and clear."
} else {
  $robotText = Get-Content -LiteralPath $RobotLogPath -Raw
  Add-RequiredTextPatterns `
    -Id "wifi-set-result" `
    -Name "Wi-Fi set command persisted" `
    -Text $robotText `
    -Patterns @("[wifi]", "persisted=1", "store_has_record=1", "enabled=1", "ssid_set=1") `
    -Evidence $robotEvidence `
    -MissingDetail "Capture the robot accepting the Wi-Fi provisioning command."

  Add-RequiredTextPatterns `
    -Id "wifi-reload-result" `
    -Name "Wi-Fi store reload after power cycle" `
    -Text $robotText `
    -Patterns @("bridge_wifi_store_loads", "bridge_wifi_store_has_record=1") `
    -Evidence $robotEvidence `
    -MissingDetail "Power-cycle the robot and capture status/runtime telemetry showing the stored bridge target reloaded."

  Add-RequiredTextPatterns `
    -Id "wifi-clear-result" `
    -Name "Wi-Fi clear command removes stored target" `
    -Text $robotText `
    -Patterns @("wifi clear", "store_has_record=0") `
    -Evidence $robotEvidence `
    -MissingDetail "Capture wifi clear and the resulting store_has_record=0 telemetry."

  if ($robotText -match "(?i)pass\s+`"(?!<network-password>|<redacted>)|pass=(?!<network-password>|<redacted>)|password\s+`"(?!<redacted>)|password=(?!<redacted>)") {
    Add-Check "robot-log-password-privacy" "Robot Wi-Fi log does not expose password" "fail" $robotEvidence "Robot Wi-Fi log contains an unredacted password-like token; redact or recapture before release."
  } else {
    Add-Check "robot-log-password-privacy" "Robot Wi-Fi log does not expose password" "pass" $robotEvidence "No unredacted password-like token found in the Wi-Fi provisioning log."
  }
}

if (-not (Test-Path -LiteralPath $ReviewPath -PathType Leaf)) {
  Add-Check "wifi-review" "Android Wi-Fi provisioning human review packet" "pending" $reviewEvidence "Run with -WriteTemplate and complete the Wi-Fi review after the real-device run."
} else {
  $reviewText = Get-Content -LiteralPath $ReviewPath -Raw
  $reviewerOk = $reviewText -match "(?im)^-\s*Reviewer:\s*\S+"
  $dateOk = $reviewText -match "(?im)^-\s*Review date:\s*\d{4}-\d{2}-\d{2}\s*$"
  $supportOk = $reviewText -match "(?im)^-\s*Support decision:\s*pass\s*$"
  $commandOk = $reviewText -match "(?im)^-\s*Wi-Fi command decision:\s*pass\s*$"
  $persistenceOk = $reviewText -match "(?im)^-\s*Persistence decision:\s*pass\s*$"
  $reloadOk = $reviewText -match "(?im)^-\s*Power-cycle reload decision:\s*pass\s*$"
  $clearOk = $reviewText -match "(?im)^-\s*Clear command decision:\s*pass\s*$"
  $privacyOk = $reviewText -match "(?im)^-\s*Password privacy decision:\s*pass\s*$"
  if ($reviewerOk -and $dateOk -and $supportOk -and $commandOk -and $persistenceOk -and $reloadOk -and $clearOk -and $privacyOk) {
    Add-Check "wifi-review" "Android Wi-Fi provisioning human review packet" "pass" $reviewEvidence "Reviewer, date, support, command, persistence, reload, clear, and privacy decisions are pass."
  } else {
    Add-Check "wifi-review" "Android Wi-Fi provisioning human review packet" "pending" $reviewEvidence "Complete Reviewer, Review date (YYYY-MM-DD), Support decision: pass, Wi-Fi command decision: pass, Persistence decision: pass, Power-cycle reload decision: pass, Clear command decision: pass, and Password privacy decision: pass."
  }
}

$failCount = @($checks | Where-Object { $_.status -eq "fail" }).Count
$pendingCount = @($checks | Where-Object { $_.status -eq "pending" }).Count
$passCount = @($checks | Where-Object { $_.status -eq "pass" }).Count
$status = if ($failCount -gt 0) { "not-ready" } elseif ($pendingCount -gt 0) { "pending-android-wifi-evidence" } else { "android-wifi-ready" }

$report = [ordered]@{
  schema = "stackchan.android-wifi-evidence.v1"
  status = $status
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
  Write-Host "Android Wi-Fi provisioning evidence status: $status"
  Write-Host "Pass: $passCount  Fail: $failCount  Pending: $pendingCount"
  foreach ($check in $checks) {
    Write-Host ("[{0}] {1} - {2}" -f $check.status, $check.id, $check.detail)
  }
}

if ($failCount -gt 0 -or ($RequireReady -and $pendingCount -gt 0)) {
  exit 1
}
