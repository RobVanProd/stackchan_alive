param(
  [string]$Root = "",
  [string]$ExportPath = "output/android-diagnostics/latest/ANDROID_DIAGNOSTICS_EXPORT.json",
  [string]$ReviewPath = "output/android-diagnostics/latest/ANDROID_DIAGNOSTICS_REVIEW.md",
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

if (-not [System.IO.Path]::IsPathRooted($ExportPath)) {
  $ExportPath = Join-Path $Root $ExportPath
}
if (-not [System.IO.Path]::IsPathRooted($ReviewPath)) {
  $ReviewPath = Join-Path $Root $ReviewPath
}

$ExpectedModelFile = "gemma-4-E2B-it.litertlm"
$ExpectedModelBytes = 2588147712
$ExpectedModelSha256 = "181938105e0eefd105961417e8da75903eacda102c4fce9ce90f50b97139a63c"
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

function Convert-ToInt64OrNull {
  param([object]$Value)

  if ($null -eq $Value -or [string]::IsNullOrWhiteSpace([string]$Value)) {
    return $null
  }

  try {
    return [int64]$Value
  } catch {
    return $null
  }
}

function Add-RequiredFieldCheck {
  param(
    [string]$Id,
    [string]$Name,
    [object]$Object,
    [string[]]$Fields,
    [string]$Evidence
  )

  $missing = @()
  foreach ($field in $Fields) {
    if (-not (Test-HasField $Object $field)) {
      $missing += $field
    }
  }

  if ($missing.Count -gt 0) {
    Add-Check $Id $Name "fail" $Evidence ("Missing required fields: " + ($missing -join ", "))
  } else {
    Add-Check $Id $Name "pass" $Evidence "Required fields are present."
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

function Write-DiagnosticsReviewTemplate {
  $reviewDirectory = Split-Path -Parent $ReviewPath
  if (-not [string]::IsNullOrWhiteSpace($reviewDirectory)) {
    New-Item -ItemType Directory -Force -Path $reviewDirectory | Out-Null
  }

  @"
# Android Diagnostics Export Review

Complete this after sharing `ANDROID_DIAGNOSTICS_EXPORT.json` from the final Android build
while connected to the physical Stack-chan.

- Reviewer:
- Review date:
- Support decision: pending
- Device:
- Android version:
- App version:
- Source commit:
- Robot evidence packet:
- Diagnostics export path: ANDROID_DIAGNOSTICS_EXPORT.json

Required review:

- Schema is `stackchan.android.diagnostics-export.v1`.
- Robot socket and robot hello are connected.
- Robot identity and firmware version are present.
- Wi-Fi provisioning command uses placeholders and `password_redacted=true`.
- Last text turn is redacted to presence-only.
- No raw audio, transcript text, Wi-Fi password, private key, or local secret is present.
- Gemma-4-E2B fields show the expected LiteRT-LM artifact, bytes, checksum, load state,
  and success/failure intents.
- Saved robot and trusted endpoint arrays are present and do not expose secrets.
"@ | Set-Content -Path $ReviewPath -Encoding UTF8
}

if ($WriteTemplate) {
  Write-DiagnosticsReviewTemplate
}

$exportEvidence = Convert-ToRelativePath $ExportPath
$reviewEvidence = Convert-ToRelativePath $ReviewPath

if (-not (Test-Path -LiteralPath $ExportPath -PathType Leaf)) {
  Add-Check "diagnostics-export-json" "Android diagnostics export JSON" "pending" $exportEvidence "Share ANDROID_DIAGNOSTICS_EXPORT.json from the Android app after a physical robot session."
} else {
  Add-Check "diagnostics-export-json" "Android diagnostics export JSON" "pass" $exportEvidence "Diagnostics export JSON exists."

  try {
    $diagnostics = Get-Content -LiteralPath $ExportPath -Raw | ConvertFrom-Json
  } catch {
    Add-Check "diagnostics-export-json-parse" "Android diagnostics export parses" "fail" $exportEvidence $_.Exception.Message
    $diagnostics = $null
  }

  if ($null -ne $diagnostics) {
    Add-ExactFieldCheck "schema" "Diagnostics export schema" (Get-Field $diagnostics "schema") "stackchan.android.diagnostics-export.v1" $exportEvidence
    foreach ($section in @("endpoint", "bridge", "pairing", "robot", "model", "saved_robots", "trusted_endpoints", "privacy")) {
      if (Test-HasField $diagnostics $section) {
        Add-Check "section-$section" "Diagnostics section '$section'" "pass" $exportEvidence "Section is present."
      } else {
        Add-Check "section-$section" "Diagnostics section '$section'" "fail" $exportEvidence "Missing section."
      }
    }

    $endpoint = Get-Field $diagnostics "endpoint"
    $bridge = Get-Field $diagnostics "bridge"
    $pairing = Get-Field $diagnostics "pairing"
    $robot = Get-Field $diagnostics "robot"
    $model = Get-Field $diagnostics "model"
    $privacy = Get-Field $diagnostics "privacy"

    Add-RequiredFieldCheck "endpoint-fields" "Android endpoint identity fields" $endpoint @("endpoint_id", "endpoint_name", "endpoint_kind", "app_version", "priority", "supports_binary_audio", "capabilities") $exportEvidence
    Add-ExactFieldCheck "endpoint-kind" "Android endpoint kind" (Get-Field $endpoint "endpoint_kind") "android" $exportEvidence

    Add-RequiredFieldCheck "bridge-fields" "Android bridge state fields" $bridge @("service_status", "primary_bridge_url", "manual_bridge_urls", "connection_label", "robot_socket_connected", "robot_state", "last_message_type", "active_brain_owner", "text_turns_submitted", "last_text_turn_present") $exportEvidence
    if (Test-TrueField $bridge "robot_socket_connected") {
      Add-Check "bridge-robot-socket-connected" "Bridge robot socket connected" "pass" $exportEvidence "Export was captured while the Android bridge had a robot socket."
    } else {
      Add-Check "bridge-robot-socket-connected" "Bridge robot socket connected" "pending" $exportEvidence "Capture the export while the physical robot is connected to the Android bridge."
    }

    if ((Get-Field $bridge "last_text_turn_present") -eq $true) {
      Add-Check "last-text-turn-redacted" "Last text turn redacted to presence-only" "pass" $exportEvidence "Text turn content is represented only as last_text_turn_present=true."
    } else {
      Add-Check "last-text-turn-redacted" "Last text turn redacted to presence-only" "pending" $exportEvidence "Run a Talk turn before exporting so the redacted presence-only flag is exercised."
    }

    Add-RequiredFieldCheck "pairing-fields" "Pairing and Wi-Fi provisioning fields" $pairing @("pairing_code_present", "pairing_qr_scheme", "wifi_provisioning_command_template", "wifi_clear_command", "password_redacted") $exportEvidence
    Add-ExactFieldCheck "pairing-qr-scheme" "Pairing QR scheme" (Get-Field $pairing "pairing_qr_scheme") "stackchan://pair" $exportEvidence
    Add-ExactFieldCheck "wifi-clear-command" "Wi-Fi clear command" (Get-Field $pairing "wifi_clear_command") "wifi clear" $exportEvidence
    if (Test-TrueField $pairing "password_redacted") {
      Add-Check "wifi-password-redacted" "Wi-Fi password redacted" "pass" $exportEvidence "password_redacted=true."
    } else {
      Add-Check "wifi-password-redacted" "Wi-Fi password redacted" "fail" $exportEvidence "Diagnostics export must never include a real Wi-Fi password."
    }
    $wifiTemplate = [string](Get-Field $pairing "wifi_provisioning_command_template")
    if ($wifiTemplate -match 'wifi set ssid "?<network-name>"? pass "?<network-password>"? url ' -or $wifiTemplate -eq "Start the phone bridge first, then rerun diagnostics to generate the Wi-Fi command template.") {
      Add-Check "wifi-command-template" "Wi-Fi provisioning command template" "pass" $exportEvidence "Template uses placeholders or explains why bridge URL is not available."
    } else {
      Add-Check "wifi-command-template" "Wi-Fi provisioning command template" "fail" $exportEvidence "Wi-Fi command template must use placeholder credentials."
    }

    Add-RequiredFieldCheck "robot-fields" "Robot identity fields" $robot @("socket_connected", "connected", "device_id", "device_name", "display_name", "firmware_version", "fingerprint", "saved_on_phone") $exportEvidence
    if ((Test-TrueField $robot "socket_connected") -and (Test-TrueField $robot "connected") -and (Test-StringPresent (Get-Field $robot "device_id")) -and (Test-StringPresent (Get-Field $robot "firmware_version"))) {
      Add-Check "robot-session-evidence" "Connected robot session evidence" "pass" $exportEvidence "Robot socket, hello state, identity, and firmware version are present."
    } else {
      Add-Check "robot-session-evidence" "Connected robot session evidence" "pending" $exportEvidence "Capture diagnostics after the physical robot hello so identity and firmware fields are present."
    }

    Add-RequiredFieldCheck "model-fields" "Gemma LiteRT model fields" $model @("model_id", "runtime", "expected_file", "expected_bytes", "expected_sha256", "source_url", "local_path", "bytes", "downloaded", "loaded", "checksum_verified", "download_in_progress", "download_id_present", "runner_status", "success_intent", "failure_intent", "requires_real_device_inference_evidence") $exportEvidence
    Add-ExactFieldCheck "model-id" "Gemma model id" (Get-Field $model "model_id") "Gemma-4-E2B" $exportEvidence
    Add-ExactFieldCheck "model-runtime" "Gemma runtime" (Get-Field $model "runtime") "LiteRT-LM" $exportEvidence
    Add-ExactFieldCheck "model-file" "Gemma expected file" (Get-Field $model "expected_file") $ExpectedModelFile $exportEvidence
    Add-ExactFieldCheck "model-bytes" "Gemma expected bytes" (Convert-ToInt64OrNull (Get-Field $model "expected_bytes")) $ExpectedModelBytes $exportEvidence
    Add-ExactFieldCheck "model-sha256" "Gemma expected SHA-256" (Get-Field $model "expected_sha256") $ExpectedModelSha256 $exportEvidence
    Add-ExactFieldCheck "model-success-intent" "Gemma success intent" (Get-Field $model "success_intent") "mobile_brain_litert_turn" $exportEvidence
    Add-ExactFieldCheck "model-failure-intent" "Gemma failure intent" (Get-Field $model "failure_intent") "mobile_brain_litert_error" $exportEvidence
    $actualModelBytes = Convert-ToInt64OrNull (Get-Field $model "bytes")
    if ((Test-TrueField $model "downloaded") -and (Test-TrueField $model "loaded") -and (Test-TrueField $model "checksum_verified") -and ($actualModelBytes -eq $ExpectedModelBytes)) {
      Add-Check "model-real-device-state" "Gemma real-device loaded state" "pass" $exportEvidence "Export shows downloaded, loaded, checksum-verified Gemma LiteRT asset."
    } else {
      Add-Check "model-real-device-state" "Gemma real-device loaded state" "pending" $exportEvidence "Use the Android Brain screen to download, verify, and load Gemma-4-E2B before final v1 evidence."
    }

    Add-RequiredFieldCheck "privacy-fields" "Diagnostics privacy fields" $privacy @("local_first", "raw_audio_retention", "transcript_export") $exportEvidence
    Add-ExactFieldCheck "privacy-local-first" "Privacy local-first flag" (Get-Field $privacy "local_first") $true $exportEvidence
    Add-ExactFieldCheck "privacy-raw-audio" "Privacy raw audio retention" (Get-Field $privacy "raw_audio_retention") "none" $exportEvidence
    Add-ExactFieldCheck "privacy-transcript" "Privacy transcript export" (Get-Field $privacy "transcript_export") "last text turn redacted to presence only" $exportEvidence
  }
}

if (-not (Test-Path -LiteralPath $ReviewPath -PathType Leaf)) {
  Add-Check "support-review" "Support review packet" "pending" $reviewEvidence "Run with -WriteTemplate and complete the support review after hardware capture."
} else {
  $reviewText = Get-Content -LiteralPath $ReviewPath -Raw
  $reviewerOk = $reviewText -match "(?im)^-\s*Reviewer:\s*\S+"
  $dateOk = $reviewText -match "(?im)^-\s*Review date:\s*\d{4}-\d{2}-\d{2}\s*$"
  $decisionOk = $reviewText -match "(?im)^-\s*Support decision:\s*pass\s*$"
  if ($reviewerOk -and $dateOk -and $decisionOk) {
    Add-Check "support-review" "Support review packet" "pass" $reviewEvidence "Reviewer, review date, and Support decision: pass are recorded."
  } else {
    Add-Check "support-review" "Support review packet" "pending" $reviewEvidence "Complete Reviewer, Review date (YYYY-MM-DD), and Support decision: pass after inspecting the export."
  }
}

$failCount = @($checks | Where-Object { $_.status -eq "fail" }).Count
$pendingCount = @($checks | Where-Object { $_.status -eq "pending" }).Count
$passCount = @($checks | Where-Object { $_.status -eq "pass" }).Count
$status = if ($failCount -gt 0) { "not-ready" } elseif ($pendingCount -gt 0) { "pending-android-diagnostics-export-evidence" } else { "android-diagnostics-export-ready" }

$report = [ordered]@{
  schema = "stackchan.android-diagnostics-export-evidence.v1"
  status = $status
  root = [string]$Root
  exportPath = Convert-ToRelativePath $ExportPath
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
  Write-Host "Android diagnostics export evidence status: $status"
  Write-Host "Pass: $passCount  Fail: $failCount  Pending: $pendingCount"
  foreach ($check in $checks) {
    Write-Host ("[{0}] {1} - {2}" -f $check.status, $check.id, $check.detail)
  }
}

if ($failCount -gt 0 -or ($RequireReady -and $pendingCount -gt 0)) {
  exit 1
}
