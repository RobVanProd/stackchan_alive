param()

$ErrorActionPreference = "Stop"

$repoRoot = Resolve-Path (Join-Path $PSScriptRoot "..")
$checkScript = Join-Path $PSScriptRoot "check_android_diagnostics_export_evidence.ps1"
$createdRoots = New-Object System.Collections.Generic.List[string]
$sourceCommit = "abcdef1234567890abcdef1234567890abcdef12"

function New-TempEvidenceRoot {
  $root = Join-Path ([System.IO.Path]::GetTempPath()) ("stackchan-android-diagnostics-contract-" + [guid]::NewGuid().ToString("N"))
  $createdRoots.Add($root) | Out-Null
  New-Item -ItemType Directory -Force -Path $root | Out-Null
  return $root
}

function Write-JsonFile {
  param(
    [string]$Path,
    [object]$Value
  )

  $dir = Split-Path -Parent $Path
  if (-not [string]::IsNullOrWhiteSpace($dir)) {
    New-Item -ItemType Directory -Force -Path $dir | Out-Null
  }
  $Value | ConvertTo-Json -Depth 12 | Set-Content -Path $Path -Encoding UTF8
}

function Write-Review {
  param([string]$Path)

  @"
# Android Diagnostics Export Review

- Reviewer: Contract Test
- Review date: 2026-07-06
- Support decision: pass
- Device: Pixel contract
- Android version: 15
- App version: 1.0.0
- Source commit: $sourceCommit
- Robot evidence packet: contract
- Diagnostics export path: ANDROID_DIAGNOSTICS_EXPORT.json
"@ | Set-Content -Path $Path -Encoding UTF8
}

function New-ReadyExport {
  return [ordered]@{
    schema = "stackchan.android.diagnostics-export.v1"
    generated_at = "2026-07-06T00:00:00Z"
    app = [ordered]@{
      package_name = "dev.stackchan.companion"
      version_name = "1.0.0"
      version_code = 1
    }
    endpoint = [ordered]@{
      endpoint_id = "phone-contract"
      endpoint_name = "Rob's Phone"
      endpoint_kind = "android"
      app_version = "1.0.0"
      priority = 80
      supports_binary_audio = $true
      capabilities = @("settings", "diagnostics", "brain_owner")
    }
    bridge = [ordered]@{
      service_status = "Foreground"
      primary_bridge_url = "ws://192.168.1.42:8765/bridge"
      manual_bridge_urls = @("ws://192.168.1.42:8765/bridge")
      connection_label = "Connected: Stackchan Bench"
      robot_socket_connected = $true
      robot_state = "heartbeat"
      last_message_type = "app_text_turn"
      active_brain_owner = "phone-contract"
      text_turns_submitted = 1
      last_text_turn_present = $true
    }
    pairing = [ordered]@{
      pairing_code_present = $true
      pairing_qr_scheme = "stackchan://pair"
      wifi_provisioning_command_template = 'wifi set ssid "<network-name>" pass "<network-password>" url "ws://192.168.1.42:8765/bridge"'
      wifi_clear_command = "wifi clear"
      password_redacted = $true
    }
    robot = [ordered]@{
      socket_connected = $true
      connected = $true
      device_id = "stackchan-bench-01"
      device_name = "Stackchan Bench"
      display_name = "Stackchan Bench"
      firmware_version = "bench-v1"
      fingerprint = "bench-v1"
      saved_on_phone = $true
    }
    model = [ordered]@{
      model_id = "Gemma-4-E2B"
      runtime = "LiteRT-LM"
      expected_file = "gemma-4-E2B-it.litertlm"
      expected_bytes = 2588147712
      expected_sha256 = "181938105e0eefd105961417e8da75903eacda102c4fce9ce90f50b97139a63c"
      source_url = "https://huggingface.co/litert-community/gemma-4-E2B-it-litert-lm/resolve/main/gemma-4-E2B-it.litertlm"
      local_path = "/storage/emulated/0/Android/data/dev.stackchan.companion/files/Download/models/gemma-4-E2B-it.litertlm"
      bytes = 2588147712
      downloaded = $true
      loaded = $true
      checksum_verified = $true
      download_in_progress = $false
      download_id_present = $false
      runner_status = "litert_adapter_selected"
      success_intent = "mobile_brain_litert_turn"
      failure_intent = "mobile_brain_litert_error"
      requires_real_device_inference_evidence = $true
    }
    saved_robots = @()
    trusted_endpoints = @()
    privacy = [ordered]@{
      local_first = $true
      raw_audio_retention = "none"
      transcript_export = "last text turn redacted to presence only"
    }
  }
}

function Invoke-DiagnosticsCheck {
  param([string]$EvidenceRoot)

  $powerShellExe = (Get-Process -Id $PID).Path
  $arguments = @(
    "-NoProfile",
    "-ExecutionPolicy",
    "Bypass",
    "-File",
    $checkScript,
    "-ExportPath",
    (Join-Path $EvidenceRoot "ANDROID_DIAGNOSTICS_EXPORT.json"),
    "-ReviewPath",
    (Join-Path $EvidenceRoot "ANDROID_DIAGNOSTICS_REVIEW.md"),
    "-RequireReady",
    "-Json"
  )

  $oldErrorActionPreference = $ErrorActionPreference
  $ErrorActionPreference = "Continue"
  try {
    $output = & $powerShellExe @arguments 2>&1
    $exitCode = $LASTEXITCODE
  } finally {
    $ErrorActionPreference = $oldErrorActionPreference
  }

  $text = ($output | Out-String).Trim()
  $report = if ([string]::IsNullOrWhiteSpace($text)) { $null } else { $text | ConvertFrom-Json }
  return [pscustomobject]@{ exitCode = $exitCode; text = $text; report = $report }
}

function Assert-CheckStatus {
  param(
    [object]$Report,
    [string]$Id,
    [string]$Status
  )

  $check = @($Report.checks | Where-Object { $_.id -eq $Id })
  if ($check.Count -ne 1) {
    throw "Expected exactly one check with id '$Id'."
  }
  if ($check[0].status -ne $Status) {
    throw "Expected check '$Id' to be '$Status', got '$($check[0].status)'. Detail: $($check[0].detail)"
  }
}

try {
  Set-Location $repoRoot

  $readyRoot = New-TempEvidenceRoot
  Write-JsonFile -Path (Join-Path $readyRoot "ANDROID_DIAGNOSTICS_EXPORT.json") -Value (New-ReadyExport)
  Write-Review -Path (Join-Path $readyRoot "ANDROID_DIAGNOSTICS_REVIEW.md")
  $readyResult = Invoke-DiagnosticsCheck -EvidenceRoot $readyRoot
  if ([int]$readyResult.exitCode -ne 0 -or $readyResult.report.status -ne "android-diagnostics-export-ready") {
    throw "Expected complete Android diagnostics export evidence to be ready. Output: $($readyResult.text)"
  }
  if ($readyResult.report.applicationId -ne "dev.stackchan.companion" -or $readyResult.report.versionName -ne "1.0.0" -or [string]$readyResult.report.versionCode -ne "1") {
    throw "Expected diagnostics evidence report to emit applicationId, versionName, and versionCode."
  }
  foreach ($id in @("app-fields", "app-package-name", "app-version-name", "app-version-code", "support-review")) {
    Assert-CheckStatus -Report $readyResult.report -Id $id -Status "pass"
  }
  Write-Host "[ok] complete Android diagnostics export evidence is accepted"

  $packageMismatchRoot = New-TempEvidenceRoot
  $packageMismatchExport = New-ReadyExport
  $packageMismatchExport.app.package_name = "dev.stackchan.wrong"
  Write-JsonFile -Path (Join-Path $packageMismatchRoot "ANDROID_DIAGNOSTICS_EXPORT.json") -Value $packageMismatchExport
  Write-Review -Path (Join-Path $packageMismatchRoot "ANDROID_DIAGNOSTICS_REVIEW.md")
  $packageMismatchResult = Invoke-DiagnosticsCheck -EvidenceRoot $packageMismatchRoot
  if ([int]$packageMismatchResult.exitCode -eq 0) {
    throw "Expected mismatched diagnostics package name to fail."
  }
  Assert-CheckStatus -Report $packageMismatchResult.report -Id "app-package-name" -Status "fail"
  Write-Host "[ok] mismatched Android diagnostics package name is rejected"

  $versionMismatchRoot = New-TempEvidenceRoot
  $versionMismatchExport = New-ReadyExport
  $versionMismatchExport.app.version_code = 99
  Write-JsonFile -Path (Join-Path $versionMismatchRoot "ANDROID_DIAGNOSTICS_EXPORT.json") -Value $versionMismatchExport
  Write-Review -Path (Join-Path $versionMismatchRoot "ANDROID_DIAGNOSTICS_REVIEW.md")
  $versionMismatchResult = Invoke-DiagnosticsCheck -EvidenceRoot $versionMismatchRoot
  if ([int]$versionMismatchResult.exitCode -eq 0) {
    throw "Expected mismatched diagnostics versionCode to fail."
  }
  Assert-CheckStatus -Report $versionMismatchResult.report -Id "app-version-code" -Status "fail"
  Write-Host "[ok] mismatched Android diagnostics versionCode is rejected"

  Write-Host "Android diagnostics export evidence contract tests passed."
} finally {
  foreach ($root in $createdRoots) {
    if (Test-Path -LiteralPath $root) {
      Remove-Item -LiteralPath $root -Recurse -Force
    }
  }
}
