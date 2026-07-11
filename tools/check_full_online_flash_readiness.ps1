param(
  [string]$PreflightPath = "output\pc-brain\full-online-preflight-latest\FULL_ONLINE_PREFLIGHT.json",
  [string]$ValidationRoot = "output\pc-brain\full-online-validation-latest",
  [string]$DeviceHost = "192.168.1.238",
  [string]$DebugUrl = "",
  [string]$DebugJsonPath = "",
  [string]$RuntimeJsonPath = "",
  [string]$ReportDir = "output\pc-brain\full-online-flash-readiness-latest",
  [switch]$Json
)

$ErrorActionPreference = "Stop"

$RepoRoot = Resolve-Path (Join-Path $PSScriptRoot "..")
Set-Location $RepoRoot

if ([string]::IsNullOrWhiteSpace($DebugUrl) -and -not [string]::IsNullOrWhiteSpace($DeviceHost)) {
  $DebugUrl = "http://$DeviceHost`:8789/debug"
}

$checks = @()

function Add-Check {
  param(
    [string]$Id,
    [ValidateSet("pass", "fail", "pending")]
    [string]$Status,
    [string]$Detail
  )
  $script:checks += [ordered]@{
    id = $Id
    status = $Status
    detail = $Detail
  }
}

function Read-JsonFile {
  param([string]$Path)
  return Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json
}

function Get-CheckStatus {
  param($Report, [string]$Id)
  $item = @($Report.steps | Where-Object { $_.id -eq $Id })[0]
  if ($null -eq $item) {
    $item = @($Report.checks | Where-Object { $_.id -eq $Id })[0]
  }
  if ($null -eq $item) { return "" }
  return [string]$item.status
}

function Get-IntValue {
  param($Object, [string]$Name, [int]$DefaultValue = 0)
  if ($null -eq $Object) { return $DefaultValue }
  $property = $Object.PSObject.Properties[$Name]
  if ($null -eq $property -or $null -eq $property.Value) { return $DefaultValue }
  return [int]$property.Value
}

$preflight = $null
if (Test-Path -LiteralPath $PreflightPath -PathType Leaf) {
  try {
    $preflight = Read-JsonFile $PreflightPath
    Add-Check "preflight-json" "pass" $PreflightPath
    Add-Check "preflight-schema" ($(if ($preflight.schema -eq "stackchan.full-online-preflight.v1") { "pass" } else { "fail" })) "schema=$($preflight.schema)"
    Add-Check "preflight-ready" ($(if ($preflight.readyToFlash -eq $true -and (Get-IntValue $preflight "failed" 1) -eq 0) { "pass" } else { "fail" })) "readyToFlash=$($preflight.readyToFlash) failed=$($preflight.failed)"
    Add-Check "preflight-build" ($(if ((Get-CheckStatus $preflight "full-online-build") -eq "pass") { "pass" } else { "fail" })) "full-online-build=$((Get-CheckStatus $preflight "full-online-build"))"
    Add-Check "preflight-flash-dry-run" ($(if ((Get-CheckStatus $preflight "flash-dry-run") -eq "pass") { "pass" } else { "fail" })) "flash-dry-run=$((Get-CheckStatus $preflight "flash-dry-run"))"
    Add-Check "preflight-pc-brain" ($(if ((Get-CheckStatus $preflight "pc-brain-runtime") -eq "pass" -and (Get-CheckStatus $preflight "pc-brain-stt-model-tts") -eq "pass") { "pass" } else { "fail" })) "runtime=$((Get-CheckStatus $preflight "pc-brain-runtime")) stt_model_tts=$((Get-CheckStatus $preflight "pc-brain-stt-model-tts"))"
    Add-Check "current-firmware-not-full-online" ($(if ([string]$preflight.fullOnlineGateStatus -eq "first-pc-brain-deploy-ready") { "pass" } else { "pending" })) "fullOnlineGateStatus=$($preflight.fullOnlineGateStatus)"
  } catch {
    Add-Check "preflight-json" "fail" $_.Exception.Message
  }
} else {
  Add-Check "preflight-json" "fail" "Missing preflight report: $PreflightPath"
}

$validationCheckPath = Join-Path $ValidationRoot "FULL_ONLINE_VALIDATION_CHECK.json"
$nextActionsPath = Join-Path $ValidationRoot "FULL_ONLINE_NEXT_ACTIONS.md"
$reviewPath = Join-Path $ValidationRoot "FULL_ONLINE_REVIEW.md"
if (Test-Path -LiteralPath $ValidationRoot -PathType Container) {
  Add-Check "validation-root" "pass" $ValidationRoot
  Add-Check "validation-review-template" ($(if (Test-Path -LiteralPath $reviewPath -PathType Leaf) { "pass" } else { "fail" })) $reviewPath
  Add-Check "validation-next-actions" ($(if (Test-Path -LiteralPath $nextActionsPath -PathType Leaf) { "pass" } else { "fail" })) $nextActionsPath
  if (Test-Path -LiteralPath $validationCheckPath -PathType Leaf) {
    try {
      $validation = Read-JsonFile $validationCheckPath
      Add-Check "validation-check-json" "pass" $validationCheckPath
      Add-Check "validation-staged" ($(if ($validation.status -eq "full-online-validation-pending-evidence" -or $validation.status -eq "full-online-validation-ready") { "pass" } else { "fail" })) "status=$($validation.status)"
      Add-Check "validation-no-machine-failures" ($(if ($validation.machineReady -eq $true -and (Get-IntValue $validation "failed" 1) -eq 0) { "pass" } else { "fail" })) "machineReady=$($validation.machineReady) failed=$($validation.failed)"
    } catch {
      Add-Check "validation-check-json" "fail" $_.Exception.Message
    }
  } else {
    Add-Check "validation-check-json" "fail" "Missing $validationCheckPath"
  }
} else {
  Add-Check "validation-root" "fail" "Missing validation root: $ValidationRoot"
}

$runtime = $null
if (-not [string]::IsNullOrWhiteSpace($RuntimeJsonPath)) {
  if (Test-Path -LiteralPath $RuntimeJsonPath -PathType Leaf) {
    $runtime = Read-JsonFile $RuntimeJsonPath
  } else {
    Add-Check "runtime-json" "fail" "Missing runtime JSON: $RuntimeJsonPath"
  }
} else {
  $runtimeOutDir = Join-Path $ReportDir "runtime"
  $runtimeOutput = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $PSScriptRoot "check_pc_brain_runtime.ps1") -DeviceHost $DeviceHost -ReportDir $runtimeOutDir -Json
  if ($LASTEXITCODE -eq 0 -and $runtimeOutput) {
    $runtime = $runtimeOutput | ConvertFrom-Json
  } else {
    Add-Check "runtime-json" "fail" "Live PC brain runtime check failed."
  }
}
if ($null -ne $runtime) {
  Add-Check "runtime-schema" ($(if ($runtime.schema -eq "stackchan.pc-brain-runtime-check.v1") { "pass" } else { "fail" })) "schema=$($runtime.schema)"
  Add-Check "runtime-ready" ($(if ($runtime.machineReady -eq $true -and (Get-IntValue $runtime "failed" 1) -eq 0) { "pass" } else { "fail" })) "status=$($runtime.status) machineReady=$($runtime.machineReady) failed=$($runtime.failed)"
  foreach ($id in @("stt-command", "tts-command", "tts-voice", "runner-command", "live-debug-ready")) {
    Add-Check "runtime-$id" ($(if ((Get-CheckStatus $runtime $id) -eq "pass") { "pass" } else { "fail" })) "$id=$((Get-CheckStatus $runtime $id))"
  }
}

$debug = $null
if (-not [string]::IsNullOrWhiteSpace($DebugJsonPath)) {
  if (Test-Path -LiteralPath $DebugJsonPath -PathType Leaf) {
    $debug = Read-JsonFile $DebugJsonPath
  } else {
    Add-Check "debug-json" "fail" "Missing debug JSON: $DebugJsonPath"
  }
} elseif (-not [string]::IsNullOrWhiteSpace($DebugUrl)) {
  try {
    $debug = Invoke-RestMethod -Uri $DebugUrl -TimeoutSec 5
  } catch {
    Add-Check "debug-json" "fail" "$DebugUrl :: $($_.Exception.Message)"
  }
} else {
  Add-Check "debug-json" "fail" "Pass -DeviceHost, -DebugUrl, or -DebugJsonPath."
}
if ($null -ne $debug) {
  Add-Check "debug-schema" ($(if ($debug.schema -eq "stackchan.bridge-debug.v1") { "pass" } else { "fail" })) "schema=$($debug.schema)"
  Add-Check "debug-ready" ($(if ($debug.network_state -eq "connected" -and $debug.bridge_state -eq "ready") { "pass" } else { "fail" })) "network=$($debug.network_state) bridge=$($debug.bridge_state)"
  Add-Check "debug-error-clear" ($(if ([string]$debug.network_error -eq "") { "pass" } else { "fail" })) "network_error=$($debug.network_error)"
  Add-Check "debug-volume-150" ($(if ((Get-IntValue $debug "speaker_volume" 0) -eq 150) { "pass" } else { "fail" })) "speaker_volume=$($debug.speaker_volume)"
  Add-Check "debug-audio-idle" ($(if (-not [bool]$debug.audio_stream_active) { "pass" } else { "fail" })) "audio_stream_active=$($debug.audio_stream_active)"
  Add-Check "debug-playback-clean" ($(if ((Get-IntValue $debug "bridge_downlink_playback_errors" 0) -eq 0 -and (Get-IntValue $debug "speaker_stream_play_raw_failed" 0) -eq 0) { "pass" } else { "fail" })) "playback_errors=$($debug.bridge_downlink_playback_errors) speaker_failed=$($debug.speaker_stream_play_raw_failed)"
}

$failed = @($checks | Where-Object { $_.status -eq "fail" })
$pending = @($checks | Where-Object { $_.status -eq "pending" })
$status = if ($failed.Count -gt 0) {
  "full-online-flash-not-ready"
} else {
  "full-online-flash-ready"
}

$port = $(if ($null -ne $preflight -and -not [string]::IsNullOrWhiteSpace([string]$preflight.port)) { [string]$preflight.port } else { "COM4" })
$guardedFlashCommand = ".\tools\flash_full_online_when_ready.cmd -ReadinessJsonPath output\pc-brain\full-online-flash-readiness-latest\FULL_ONLINE_FLASH_READINESS.json -OperatorPresent -BodyClear -ConfirmServoRisk"
$rawUploadCommand = "tools\flash_device.cmd -Environment stackchan_full_online -Port $port -ConfirmServoRisk"

$result = [ordered]@{
  schema = "stackchan.full-online-flash-readiness.v1"
  status = $status
  readyToFlash = ($failed.Count -eq 0)
  generatedAt = (Get-Date).ToString("o")
  preflightPath = $PreflightPath
  validationRoot = $ValidationRoot
  debugUrl = $DebugUrl
  passed = @($checks | Where-Object { $_.status -eq "pass" }).Count
  failed = $failed.Count
  pending = $pending.Count
  checks = $checks
  nextPhysicalCommand = $guardedFlashCommand
  rawUploadCommand = $rawUploadCommand
}

New-Item -ItemType Directory -Force -Path $ReportDir | Out-Null
$resolvedReportDir = (Resolve-Path $ReportDir).Path
$jsonPath = Join-Path $resolvedReportDir "FULL_ONLINE_FLASH_READINESS.json"
$markdownPath = Join-Path $resolvedReportDir "FULL_ONLINE_FLASH_READINESS.md"
$result | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $jsonPath -Encoding UTF8

$lines = @(
  "# Stackchan Full-Online Flash Readiness",
  "",
  "- Schema: ``$($result.schema)``",
  "- Status: ``$($result.status)``",
  "- Ready to flash: ``$($result.readyToFlash)``",
  "- Passed: ``$($result.passed)``",
  "- Failed: ``$($result.failed)``",
  "- Pending: ``$($result.pending)``",
  "",
  "## Checks",
  ""
)
foreach ($check in $checks) {
  $lines += "- ``$($check.status)`` ``$($check.id)``: $($check.detail)"
}
$lines += ""
$lines += "## Supervised Physical Step"
$lines += ""
if ($result.readyToFlash) {
  $lines += "- Body clear and Rob present: ``$($result.nextPhysicalCommand)``"
  $lines += "- Raw upload command used by the wrapper: ``$($result.rawUploadCommand)``"
  $lines += "- After flashing, resume with ``output\pc-brain\full-online-validation-latest\FULL_ONLINE_NEXT_ACTIONS.md``."
} else {
  $lines += "- Resolve failed checks before flashing motor-enabled firmware."
}
$lines | Set-Content -LiteralPath $markdownPath -Encoding UTF8

if ($Json) {
  $result | ConvertTo-Json -Depth 8
} else {
  Write-Host "Full-online flash readiness: $status"
  Write-Host "Report: $markdownPath"
}

if ($failed.Count -gt 0) {
  exit 1
}
