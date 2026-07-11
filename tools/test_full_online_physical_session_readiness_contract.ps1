$ErrorActionPreference = "Stop"

$RepoRoot = Resolve-Path (Join-Path $PSScriptRoot "..")
Set-Location $RepoRoot

function Write-Json {
  param([string]$Path, $Object)
  $Object | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $Path -Encoding UTF8
}

function New-BaseFixture {
  param([string]$Root)
  New-Item -ItemType Directory -Force -Path $Root | Out-Null
  $validationPath = Join-Path $Root "FULL_ONLINE_VALIDATION_CHECK.json"
  $statusPath = Join-Path $Root "STACKCHAN_FULL_ONLINE_STATUS.json"
  $supervisedPath = Join-Path $Root "FULL_ONLINE_SUPERVISED_FLASH.json"
  $nextPath = Join-Path $Root "FULL_ONLINE_NEXT_ACTIONS.md"
  $bodyPath = Join-Path $Root "BODY_CLEAR_ATTESTATION.json"
  $debugPath = Join-Path $Root "debug.json"
  $reportRoot = Join-Path $Root "readiness"

  Write-Json $validationPath ([ordered]@{
      schema = "stackchan.full-online-validation-check.v1"
      status = "full-online-validation-pending-evidence"
      machineReady = $true
      failed = 0
      pending = 8
    })
  Write-Json $statusPath ([ordered]@{
      schema = "stackchan.full-online-status.v1"
      status = "stackchan-full-online-pending-validation"
      generatedAt = ([datetimeoffset]::Now.ToString("o"))
      failed = 0
      pending = 1
    })
  Write-Json $supervisedPath ([ordered]@{
      schema = "stackchan.full-online-supervised-flash.v1"
      status = "full-online-supervised-flash-complete"
      failed = 0
      pending = 0
    })
  @"
# next actions

.\tools\start_full_online_physical_validation_session.cmd -EvidenceRoot output\pc-brain\full-online-validation-latest -DeviceHost 192.168.1.238 -Port COM4 -OperatorPresent -BodyClear -ConfirmServoRisk -LoggerDebugOnly
.\tools\send_stackchan_serial_command.cmd -EvidenceRoot output\pc-brain\full-online-validation-latest -Port COM4 -Command "motion stop" -OperatorPresent -Json
"@ | Set-Content -LiteralPath $nextPath -Encoding UTF8
  Write-Json $bodyPath ([ordered]@{
      schema = "stackchan.body-clear-attestation.v1"
      stillRequiresLiveOperatorConfirmation = $true
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
      compiled_enable_mic_capture = $true
      bridge_uplink_enabled = $true
      bridge_wake_gate_ready = $true
      compiled_enable_servos = $true
      motion_enabled = $true
    })

  return [ordered]@{
    validationPath = $validationPath
    statusPath = $statusPath
    supervisedPath = $supervisedPath
    nextPath = $nextPath
    bodyPath = $bodyPath
    debugPath = $debugPath
    reportRoot = $reportRoot
  }
}

$tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("stackchan-full-online-physical-readiness-" + [guid]::NewGuid().ToString("N"))

try {
  $fixture = New-BaseFixture $tempRoot

  $readyOutput = & "tools\check_full_online_physical_session_readiness.ps1" `
    -ValidationPath $fixture.validationPath `
    -StatusPath $fixture.statusPath `
    -SupervisedFlashPath $fixture.supervisedPath `
    -NextActionsPath $fixture.nextPath `
    -BodyClearAttestationPath $fixture.bodyPath `
    -DebugJsonPath $fixture.debugPath `
    -ReportDir $fixture.reportRoot `
    -Port COM4 `
    -PortNames COM4 `
    -Json
  if (-not $?) {
    throw "Expected ready fixture to pass: $readyOutput"
  }
  $ready = $readyOutput | ConvertFrom-Json
  if ($ready.schema -ne "stackchan.full-online-physical-session-readiness.v1") {
    throw "Unexpected schema $($ready.schema)."
  }
  if ($ready.status -ne "full-online-physical-session-ready" -or $ready.readyForPhysicalSession -ne $true) {
    throw "Expected physical session ready, got status=$($ready.status) ready=$($ready.readyForPhysicalSession)."
  }
  if ($ready.nextCommand -notmatch "start_full_online_physical_validation_session.cmd") {
    throw "Expected guided session next command, got $($ready.nextCommand)."
  }
  foreach ($snippet in @("-SuggestedVoicePrompt", "hello stackchan")) {
    if ($ready.nextCommand -notmatch [regex]::Escape($snippet)) {
      throw "Expected readiness next command to include $snippet."
    }
  }
  foreach ($file in @("FULL_ONLINE_PHYSICAL_SESSION_READINESS.json", "FULL_ONLINE_PHYSICAL_SESSION_READINESS.md")) {
    if (-not (Test-Path -LiteralPath (Join-Path $fixture.reportRoot $file) -PathType Leaf)) {
      throw "Expected report artifact $file."
    }
  }
  $readinessMd = Get-Content -LiteralPath (Join-Path $fixture.reportRoot "FULL_ONLINE_PHYSICAL_SESSION_READINESS.md") -Raw
  foreach ($snippet in @("Ready for physical session", "start_full_online_physical_validation_session.cmd", "hello stackchan", "send_stackchan_serial_command.cmd")) {
    if ($readinessMd -notmatch [regex]::Escape($snippet)) {
      throw "Expected readiness markdown to mention $snippet."
    }
  }

  $debug = Get-Content -LiteralPath $fixture.debugPath -Raw | ConvertFrom-Json
  $debug.audio_stream_active = $true
  Write-Json $fixture.debugPath $debug
  $audioActiveOutput = & "tools\check_full_online_physical_session_readiness.ps1" `
    -ValidationPath $fixture.validationPath `
    -StatusPath $fixture.statusPath `
    -SupervisedFlashPath $fixture.supervisedPath `
    -NextActionsPath $fixture.nextPath `
    -BodyClearAttestationPath $fixture.bodyPath `
    -DebugJsonPath $fixture.debugPath `
    -ReportDir $fixture.reportRoot `
    -Port COM4 `
    -PortNames COM4 `
    -Json
  if ($?) {
    throw "Expected audio-active fixture to fail."
  }
  $audioActive = $audioActiveOutput | ConvertFrom-Json
  if ($audioActive.status -ne "full-online-physical-session-not-ready") {
    throw "Expected not-ready for active audio, got $($audioActive.status)."
  }
  $debug.audio_stream_active = $false
  Write-Json $fixture.debugPath $debug

  $serialOpenRefusalOutput = & "tools\check_full_online_physical_session_readiness.ps1" `
    -ValidationPath $fixture.validationPath `
    -StatusPath $fixture.statusPath `
    -SupervisedFlashPath $fixture.supervisedPath `
    -NextActionsPath $fixture.nextPath `
    -BodyClearAttestationPath $fixture.bodyPath `
    -DebugJsonPath $fixture.debugPath `
    -ReportDir $fixture.reportRoot `
    -Port COM4 `
    -PortNames COM4 `
    -CheckSerialOpen `
    -Json
  if ($?) {
    throw "Expected serial-open check without operator to fail."
  }
  $serialOpenRefusal = $serialOpenRefusalOutput | ConvertFrom-Json
  $operatorCheck = @($serialOpenRefusal.checks | Where-Object { $_.id -eq "serial-open-operator-present" })[0]
  if ($null -eq $operatorCheck -or $operatorCheck.status -ne "fail") {
    throw "Expected serial-open-operator-present failure."
  }

  $validation = Get-Content -LiteralPath $fixture.validationPath -Raw | ConvertFrom-Json
  $validation.status = "full-online-validation-ready"
  $validation.pending = 0
  Write-Json $fixture.validationPath $validation
  $validatedOutput = & "tools\check_full_online_physical_session_readiness.ps1" `
    -ValidationPath $fixture.validationPath `
    -StatusPath $fixture.statusPath `
    -SupervisedFlashPath $fixture.supervisedPath `
    -NextActionsPath $fixture.nextPath `
    -BodyClearAttestationPath $fixture.bodyPath `
    -DebugJsonPath $fixture.debugPath `
    -ReportDir $fixture.reportRoot `
    -Port COM4 `
    -PortNames COM4 `
    -Json
  if (-not $?) {
    throw "Expected already validated fixture to pass: $validatedOutput"
  }
  $validated = $validatedOutput | ConvertFrom-Json
  if ($validated.status -ne "full-online-physical-validation-already-ready" -or $validated.physicalValidated -ne $true -or $validated.readyForPhysicalSession -ne $false) {
    throw "Expected already-ready validation state, got status=$($validated.status) validated=$($validated.physicalValidated) ready=$($validated.readyForPhysicalSession)."
  }
} finally {
  Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Host "Full-online physical session readiness contract tests passed."
