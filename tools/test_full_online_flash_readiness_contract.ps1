$ErrorActionPreference = "Stop"

$RepoRoot = Resolve-Path (Join-Path $PSScriptRoot "..")
Set-Location $RepoRoot

function Write-Json {
  param([string]$Path, $Object)
  $Object | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $Path -Encoding UTF8
}

function Read-Json {
  param([string]$Path)
  return Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json
}

$tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("stackchan-flash-readiness-" + [guid]::NewGuid().ToString("N"))
$validationRoot = Join-Path $tempRoot "validation"
$reportRoot = Join-Path $tempRoot "report"
$preflightPath = Join-Path $tempRoot "FULL_ONLINE_PREFLIGHT.json"
$runtimePath = Join-Path $tempRoot "PC_BRAIN_RUNTIME_CHECK.json"
$debugPath = Join-Path $tempRoot "debug.json"

try {
  New-Item -ItemType Directory -Force -Path $validationRoot | Out-Null
  Write-Json $preflightPath ([ordered]@{
      schema = "stackchan.full-online-preflight.v1"
      status = "full-online-preflight-ready-to-flash"
      readyToFlash = $true
      failed = 0
      pending = 1
      port = "COM4"
      fullOnlineGateStatus = "first-pc-brain-deploy-not-ready"
      steps = @(
        @{ id = "full-online-build"; status = "pass" },
        @{ id = "flash-dry-run"; status = "pass" },
        @{ id = "pc-brain-runtime"; status = "pass" },
        @{ id = "pc-brain-stt-model-tts"; status = "pass" },
        @{ id = "full-online-live-gate"; status = "pending" }
      )
    })
  Write-Json $runtimePath ([ordered]@{
      schema = "stackchan.pc-brain-runtime-check.v1"
      status = "pc-brain-runtime-ready"
      machineReady = $true
      failed = 0
      checks = @(
        @{ id = "stt-command"; status = "pass" },
        @{ id = "tts-command"; status = "pass" },
        @{ id = "tts-voice"; status = "pass" },
        @{ id = "runner-command"; status = "pass" },
        @{ id = "live-debug-ready"; status = "pass" }
      )
    })
  Write-Json $debugPath ([ordered]@{
      schema = "stackchan.bridge-debug.v1"
      network_state = "connected"
      bridge_state = "ready"
      network_error = ""
      speaker_volume = 150
      audio_stream_active = $false
      bridge_downlink_playback_errors = 0
      speaker_stream_play_raw_failed = 0
    })
  @(
    "# Stackchan Full-Online Review",
    "",
    "- Full-online firmware flashed: pending"
  ) | Set-Content -LiteralPath (Join-Path $validationRoot "FULL_ONLINE_REVIEW.md") -Encoding UTF8
  @(
    "# Stackchan Full-Online Next Actions",
    "",
    '- After flashing `stackchan_full_online`, continue physical validation.'
  ) | Set-Content -LiteralPath (Join-Path $validationRoot "FULL_ONLINE_NEXT_ACTIONS.md") -Encoding UTF8
  Write-Json (Join-Path $validationRoot "FULL_ONLINE_VALIDATION_CHECK.json") ([ordered]@{
      schema = "stackchan.full-online-validation-check.v1"
      status = "full-online-validation-pending-evidence"
      machineReady = $true
      failed = 0
      pending = 16
    })

  $output = & "tools\check_full_online_flash_readiness.ps1" `
    -PreflightPath $preflightPath `
    -ValidationRoot $validationRoot `
    -RuntimeJsonPath $runtimePath `
    -DebugJsonPath $debugPath `
    -ReportDir $reportRoot `
    -Json
  if (-not $?) {
    throw "Expected ready flash check to exit 0: $output"
  }
  $ready = $output | ConvertFrom-Json
  if ($ready.status -ne "full-online-flash-ready" -or $ready.readyToFlash -ne $true) {
    throw "Expected full-online-flash-ready, got status=$($ready.status) ready=$($ready.readyToFlash)."
  }
  if ($ready.nextPhysicalCommand -notmatch "flash_full_online_when_ready.cmd" -or $ready.nextPhysicalCommand -notmatch "OperatorPresent") {
    throw "Expected guarded wrapper as next physical command, got $($ready.nextPhysicalCommand)."
  }
  if ($ready.rawUploadCommand -notmatch "flash_device.cmd" -or $ready.rawUploadCommand -notmatch "stackchan_full_online") {
    throw "Expected raw upload command for traceability, got $($ready.rawUploadCommand)."
  }
  $currentGate = @($ready.checks | Where-Object { $_.id -eq "current-firmware-not-full-online" })[0]
  if ($null -eq $currentGate -or $currentGate.status -ne "pending") {
    throw "Expected current firmware not-full-online check to remain pending."
  }
  foreach ($file in @("FULL_ONLINE_FLASH_READINESS.json", "FULL_ONLINE_FLASH_READINESS.md")) {
    if (-not (Test-Path -LiteralPath (Join-Path $reportRoot $file) -PathType Leaf)) {
      throw "Expected readiness report $file."
    }
  }

  $badPreflight = Read-Json $preflightPath
  $badPreflight.readyToFlash = $false
  $badPreflight.failed = 1
  Write-Json $preflightPath $badPreflight
  $failedOutput = & "tools\check_full_online_flash_readiness.ps1" `
    -PreflightPath $preflightPath `
    -ValidationRoot $validationRoot `
    -RuntimeJsonPath $runtimePath `
    -DebugJsonPath $debugPath `
    -ReportDir $reportRoot `
    -Json
  if ($?) {
    throw "Expected failed flash check to exit nonzero."
  }
  $notReady = $failedOutput | ConvertFrom-Json
  if ($notReady.status -ne "full-online-flash-not-ready") {
    throw "Expected full-online-flash-not-ready, got $($notReady.status)."
  }
} finally {
  Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Host "Full-online flash readiness contract tests passed."
