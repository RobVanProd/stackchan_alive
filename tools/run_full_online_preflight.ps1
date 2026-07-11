param(
  [string]$DeviceHost = "192.168.1.238",
  [string]$Port = "COM4",
  [string]$OutDir = "output\pc-brain\full-online-preflight-latest",
  [string]$EvidenceRoot = "output\hardware-evidence\pc-brain-first-deploy-20260706T144047Z",
  [switch]$SkipBuild,
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
    [int]$ExitCode,
    [string]$LogPath,
    [string]$Detail
  )
  $script:steps += [ordered]@{
    id = $Id
    status = $Status
    exitCode = $ExitCode
    logPath = $LogPath
    detail = $Detail
  }
}

function Invoke-LoggedCommand {
  param(
    [string]$Id,
    [string]$LogName,
    [scriptblock]$Script,
    [int[]]$AcceptExitCodes = @(0),
    [string]$Detail = ""
  )
  $logPath = Join-Path $ResolvedOutDir $LogName
  $global:LASTEXITCODE = 0
  try {
    $output = & $Script 2>&1
    $exitCode = if ($null -ne $LASTEXITCODE) { [int]$LASTEXITCODE } else { 0 }
    $output | Out-String | Set-Content -LiteralPath $logPath -Encoding UTF8
    $status = if ($AcceptExitCodes -contains $exitCode) { "pass" } else { "fail" }
    Add-Step $Id $status $exitCode $logPath $Detail
    return [pscustomobject]@{
      exitCode = $exitCode
      output = $output
      logPath = $logPath
      status = $status
    }
  } catch {
    $_ | Out-String | Set-Content -LiteralPath $logPath -Encoding UTF8
    Add-Step $Id "fail" 1 $logPath $_.Exception.Message
    return [pscustomobject]@{
      exitCode = 1
      output = @($_.Exception.Message)
      logPath = $logPath
      status = "fail"
    }
  }
}

$runtimeReportDir = Join-Path $ResolvedOutDir "runtime"
$sttReportDir = Join-Path $ResolvedOutDir "stt"

if (-not $SkipBuild) {
  Invoke-LoggedCommand `
    -Id "full-online-build" `
    -LogName "full_online_build.log" `
    -Script { pio run -e stackchan_full_online } `
    -Detail "Builds stackchan_full_online without uploading." | Out-Null
} else {
  Add-Step "full-online-build" "pending" 0 "" "Skipped by -SkipBuild."
}

Invoke-LoggedCommand `
  -Id "flash-dry-run" `
  -LogName "flash_full_online_dry_run.log" `
  -Script { & "tools\flash_device.cmd" -Environment stackchan_full_online -Port $Port -DryRun -ConfirmServoRisk } `
  -Detail "Dry-runs the full-online upload command with servo-risk confirmation." | Out-Null

Invoke-LoggedCommand `
  -Id "pc-brain-runtime" `
  -LogName "pc_brain_runtime_check.log" `
  -Script { & "tools\check_pc_brain_runtime.cmd" -DeviceHost $DeviceHost -ReportDir $runtimeReportDir -Json } `
  -Detail "Verifies live PC brain selected voice, STT, runner, logs, and robot debug." | Out-Null

Invoke-LoggedCommand `
  -Id "pc-brain-stt-model-tts" `
  -LogName "pc_brain_stt_preflight.log" `
  -Script { & "tools\run_pc_brain_stt_preflight.cmd" -OutDir $sttReportDir -Json } `
  -Detail "Verifies configured local STT, real model smoke, and selected voice TTS on PC." | Out-Null

Invoke-LoggedCommand `
  -Id "first-deploy-bench-check" `
  -LogName "first_deploy_bench_check.log" `
  -Script { & "tools\check_first_pc_brain_deploy.cmd" -EvidenceRoot $EvidenceRoot -DeviceHost $DeviceHost -ReportDir $EvidenceRoot -Json } `
  -Detail "Rechecks current bench deploy evidence and live debug." | Out-Null

$fullOnlineProbe = Invoke-LoggedCommand `
  -Id "full-online-live-gate" `
  -LogName "full_online_live_gate.log" `
  -Script { & "tools\check_first_pc_brain_deploy.cmd" -EvidenceRoot $EvidenceRoot -DeviceHost $DeviceHost -RequireFullOnline -Json } `
  -AcceptExitCodes @(0, 1) `
  -Detail "Records whether current firmware already satisfies full-online live debug gates."

$fullOnlineGateStatus = "unknown"
try {
  $fullOnlineJson = ($fullOnlineProbe.output | Out-String) | ConvertFrom-Json
  $fullOnlineGateStatus = [string]$fullOnlineJson.status
  $step = $steps | Where-Object { $_.id -eq "full-online-live-gate" } | Select-Object -First 1
  if ($null -ne $step) {
    if ($fullOnlineJson.machineReady -eq $true -and [int]$fullOnlineJson.failed -eq 0) {
      $step.detail = "Current firmware already satisfies full-online live debug gates."
    } else {
      $step.status = "pending"
      $step.detail = "Current firmware is not full-online yet; this is expected before flashing stackchan_full_online. status=$fullOnlineGateStatus failed=$($fullOnlineJson.failed)"
    }
  }
} catch {
  $step = $steps | Where-Object { $_.id -eq "full-online-live-gate" } | Select-Object -First 1
  if ($null -ne $step) {
    $step.status = "fail"
    $step.detail = "Could not parse full-online live gate output: $($_.Exception.Message)"
  }
}

$failed = @($steps | Where-Object { $_.status -eq "fail" })
$pending = @($steps | Where-Object { $_.status -eq "pending" })
$status = if ($failed.Count -gt 0) {
  "full-online-preflight-not-ready"
} elseif ($pending.Count -gt 0) {
  "full-online-preflight-ready-to-flash"
} else {
  "full-online-preflight-ready"
}

$report = [ordered]@{
  schema = "stackchan.full-online-preflight.v1"
  generatedAt = (Get-Date).ToString("o")
  status = $status
  readyToFlash = ($failed.Count -eq 0)
  deviceHost = $DeviceHost
  port = $Port
  evidenceRoot = $EvidenceRoot
  fullOnlineGateStatus = $fullOnlineGateStatus
  passed = @($steps | Where-Object { $_.status -eq "pass" }).Count
  failed = $failed.Count
  pending = $pending.Count
  steps = $steps
}

$jsonPath = Join-Path $ResolvedOutDir "FULL_ONLINE_PREFLIGHT.json"
$markdownPath = Join-Path $ResolvedOutDir "FULL_ONLINE_PREFLIGHT.md"
$report | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $jsonPath -Encoding UTF8

$lines = @(
  "# Stackchan Full-Online Preflight",
  "",
  "- Schema: ``$($report.schema)``",
  "- Status: ``$($report.status)``",
  "- Ready to flash: ``$($report.readyToFlash)``",
  "- Device host: ``$DeviceHost``",
  "- Port: ``$Port``",
  "- Full-online gate status: ``$fullOnlineGateStatus``",
  "",
  "## Steps",
  ""
)
foreach ($step in $steps) {
  $lines += "- ``$($step.status)`` ``$($step.id)``: $($step.detail) Log: ``$($step.logPath)``"
}
$lines += ""
$lines += "## Next Physical Step"
$lines += ""
if ($report.readyToFlash) {
  $lines += "- With the body clear and an operator present, flash with ``tools\flash_device.cmd -Environment stackchan_full_online -Port $Port -ConfirmServoRisk``."
} else {
  $lines += "- Resolve failed preflight steps before flashing."
}
$lines | Set-Content -LiteralPath $markdownPath -Encoding UTF8

if ($Json) {
  $report | ConvertTo-Json -Depth 8
} else {
  Write-Host "Full-online preflight: $status"
  Write-Host "Report: $markdownPath"
}

if ($failed.Count -gt 0) {
  exit 1
}
