param(
  [string]$Port = "COM4",
  [string]$DeviceHost = "192.168.1.238",
  [string]$ReadinessJsonPath = "",
  [string]$ReadinessReportDir = "output\pc-brain\full-online-flash-readiness-latest",
  [string]$ValidationRoot = "output\pc-brain\full-online-validation-latest",
  [string]$OutDir = "output\pc-brain\full-online-supervised-flash-latest",
  [int]$MaxReadinessAgeMinutes = 120,
  [switch]$OperatorPresent,
  [switch]$BodyClear,
  [switch]$ConfirmServoRisk,
  [switch]$DryRun,
  [switch]$Json
)

$ErrorActionPreference = "Stop"

$RepoRoot = Resolve-Path (Join-Path $PSScriptRoot "..")
Set-Location $RepoRoot

New-Item -ItemType Directory -Force -Path $OutDir | Out-Null
$ResolvedOutDir = (Resolve-Path $OutDir).Path

$steps = @()

function Add-Step {
  param(
    [string]$Id,
    [ValidateSet("pass", "fail", "pending")]
    [string]$Status,
    [string]$Detail
  )
  $script:steps += [ordered]@{
    id = $Id
    status = $Status
    detail = $Detail
  }
}

function Read-JsonFile {
  param([string]$Path)
  return Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json
}

function Write-JsonFile {
  param([string]$Path, $Value)
  $Value | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $Path -Encoding UTF8
}

function Add-FreshnessStep {
  param(
    [string]$GeneratedAt,
    [int]$MaxAgeMinutes
  )
  if ([string]::IsNullOrWhiteSpace($GeneratedAt)) {
    Add-Step "readiness-fresh" "fail" "Readiness generatedAt is missing."
    return
  }
  try {
    $generated = [datetimeoffset]::Parse($GeneratedAt)
    $ageMinutes = ([datetimeoffset]::Now - $generated).TotalMinutes
    $roundedAge = [math]::Round($ageMinutes, 1)
    $fresh = ($ageMinutes -ge -5 -and $ageMinutes -le $MaxAgeMinutes)
    Add-Step "readiness-fresh" ($(if ($fresh) { "pass" } else { "fail" })) "generatedAt=$GeneratedAt age_minutes=$roundedAge max_minutes=$MaxAgeMinutes"
  } catch {
    Add-Step "readiness-fresh" "fail" "Could not parse readiness generatedAt=$GeneratedAt :: $($_.Exception.Message)"
  }
}

$readiness = $null
if (-not [string]::IsNullOrWhiteSpace($ReadinessJsonPath)) {
  if (Test-Path -LiteralPath $ReadinessJsonPath -PathType Leaf) {
    $readiness = Read-JsonFile $ReadinessJsonPath
    Add-Step "readiness-report" "pass" $ReadinessJsonPath
  } else {
    Add-Step "readiness-report" "fail" "Missing readiness report: $ReadinessJsonPath"
  }
} else {
  $readinessOutput = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $PSScriptRoot "check_full_online_flash_readiness.ps1") `
    -PreflightPath "output\pc-brain\full-online-preflight-latest\FULL_ONLINE_PREFLIGHT.json" `
    -ValidationRoot $ValidationRoot `
    -DeviceHost $DeviceHost `
    -ReportDir $ReadinessReportDir `
    -Json
  if ($LASTEXITCODE -eq 0 -and $readinessOutput) {
    $readiness = $readinessOutput | ConvertFrom-Json
    Add-Step "readiness-report" "pass" "Generated readiness report in $ReadinessReportDir."
  } else {
    Add-Step "readiness-report" "fail" "Flash readiness check failed."
  }
}

if ($null -ne $readiness) {
  Add-Step "readiness-schema" ($(if ($readiness.schema -eq "stackchan.full-online-flash-readiness.v1") { "pass" } else { "fail" })) "schema=$($readiness.schema)"
  Add-Step "readiness-ready" ($(if ($readiness.readyToFlash -eq $true -and [int]$readiness.failed -eq 0) { "pass" } else { "fail" })) "status=$($readiness.status) readyToFlash=$($readiness.readyToFlash) failed=$($readiness.failed)"
  Add-FreshnessStep ([string]$readiness.generatedAt) $MaxReadinessAgeMinutes
}

Add-Step "operator-present" ($(if ($OperatorPresent) { "pass" } else { "fail" })) "Requires -OperatorPresent."
Add-Step "body-clear" ($(if ($BodyClear) { "pass" } else { "fail" })) "Requires -BodyClear."
Add-Step "servo-risk-confirmed" ($(if ($ConfirmServoRisk) { "pass" } else { "fail" })) "Requires -ConfirmServoRisk."

$failedBeforeFlash = @($steps | Where-Object { $_.status -eq "fail" })
$flashExitCode = $null
$flashLogPath = Join-Path $ResolvedOutDir "flash_full_online.log"
$postFlashCollectorLogPath = Join-Path $ResolvedOutDir "post_flash_collector.log"

if ($failedBeforeFlash.Count -eq 0) {
  $flashArgs = @("-Environment", "stackchan_full_online", "-Port", $Port, "-ConfirmServoRisk")
  if ($DryRun) {
    $flashArgs += "-DryRun"
  }

  $flashOutput = & "tools\flash_device.cmd" @flashArgs 2>&1
  $flashExitCode = if ($null -ne $LASTEXITCODE) { [int]$LASTEXITCODE } else { 0 }
  $flashOutput | Out-String | Set-Content -LiteralPath $flashLogPath -Encoding UTF8
  Add-Step "flash-command" ($(if ($flashExitCode -eq 0) { "pass" } else { "fail" })) "$(if ($DryRun) { 'Dry run: ' } else { '' })tools\flash_device.cmd -Environment stackchan_full_online -Port $Port -ConfirmServoRisk"

  if ($flashExitCode -eq 0 -and -not $DryRun) {
    $collectorOutput = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $PSScriptRoot "collect_full_online_validation_evidence.ps1") `
      -EvidenceRoot $ValidationRoot `
      -DeviceHost $DeviceHost `
      -Prepare `
      -CaptureRuntime `
      -CaptureLiveGate `
      -Check `
      -Json 2>&1
    $collectorExitCode = if ($null -ne $LASTEXITCODE) { [int]$LASTEXITCODE } else { 0 }
    $collectorOutput | Out-String | Set-Content -LiteralPath $postFlashCollectorLogPath -Encoding UTF8
    Add-Step "post-flash-collector" ($(if ($collectorExitCode -eq 0) { "pass" } else { "fail" })) "collect_full_online_validation_evidence after upload"
  } elseif ($DryRun) {
    Add-Step "post-flash-collector" "pending" "Skipped by -DryRun."
  }
} else {
  Add-Step "flash-command" "pending" "Skipped because safety/readiness checks failed."
}

$failed = @($steps | Where-Object { $_.status -eq "fail" })
$pending = @($steps | Where-Object { $_.status -eq "pending" })
$status = if ($failed.Count -gt 0) {
  "full-online-supervised-flash-not-run"
} elseif ($DryRun) {
  "full-online-supervised-flash-dry-run-ready"
} else {
  "full-online-supervised-flash-complete"
}

$result = [ordered]@{
  schema = "stackchan.full-online-supervised-flash.v1"
  status = $status
  dryRun = [bool]$DryRun
  generatedAt = (Get-Date).ToString("o")
  port = $Port
  deviceHost = $DeviceHost
  validationRoot = $ValidationRoot
  maxReadinessAgeMinutes = $MaxReadinessAgeMinutes
  readinessStatus = $(if ($null -ne $readiness) { $readiness.status } else { $null })
  readinessGeneratedAt = $(if ($null -ne $readiness) { $readiness.generatedAt } else { $null })
  passed = @($steps | Where-Object { $_.status -eq "pass" }).Count
  failed = $failed.Count
  pending = $pending.Count
  flashLogPath = $flashLogPath
  postFlashCollectorLogPath = $postFlashCollectorLogPath
  steps = $steps
}

$jsonPath = Join-Path $ResolvedOutDir "FULL_ONLINE_SUPERVISED_FLASH.json"
$markdownPath = Join-Path $ResolvedOutDir "FULL_ONLINE_SUPERVISED_FLASH.md"
Write-JsonFile $jsonPath $result

$lines = @(
  "# Stackchan Full-Online Supervised Flash",
  "",
  "- Schema: ``$($result.schema)``",
  "- Status: ``$($result.status)``",
  "- Dry run: ``$($result.dryRun)``",
  "- Port: ``$Port``",
  "- Max readiness age minutes: ``$($result.maxReadinessAgeMinutes)``",
  "- Passed: ``$($result.passed)``",
  "- Failed: ``$($result.failed)``",
  "- Pending: ``$($result.pending)``",
  "",
  "## Steps",
  ""
)
foreach ($step in $steps) {
  $lines += "- ``$($step.status)`` ``$($step.id)``: $($step.detail)"
}
$lines += ""
$lines += "## Next"
$lines += ""
if ($result.status -eq "full-online-supervised-flash-complete") {
  $lines += "- Continue with ``$ValidationRoot\FULL_ONLINE_NEXT_ACTIONS.md``."
} elseif ($result.status -eq "full-online-supervised-flash-dry-run-ready") {
  $lines += "- Dry-run passed. With Rob present and the body clear, rerun without ``-DryRun``."
} else {
  $lines += "- Resolve failed checks before flashing motor-enabled firmware."
}
$lines | Set-Content -LiteralPath $markdownPath -Encoding UTF8

if ($Json) {
  $result | ConvertTo-Json -Depth 8
} else {
  Write-Host "Full-online supervised flash: $status"
  Write-Host "Report: $markdownPath"
}

if ($failed.Count -gt 0) {
  exit 1
}
