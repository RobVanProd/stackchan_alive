$ErrorActionPreference = "Stop"

$StartPath = Join-Path $PSScriptRoot "start_bridge_ai_supervised_qualification.ps1"
$CompletePath = Join-Path $PSScriptRoot "complete_bridge_ai_supervised_qualification.ps1"
foreach ($Path in @($StartPath, $CompletePath)) {
  $Tokens = $null
  $Errors = $null
  [System.Management.Automation.Language.Parser]::ParseFile(
    $Path,
    [ref]$Tokens,
    [ref]$Errors
  ) | Out-Null
  if ($Errors.Count -ne 0) {
    throw "$Path has PowerShell parse errors: $($Errors -join '; ')"
  }
}

$StartText = Get-Content -LiteralPath $StartPath -Raw
foreach ($Required in @(
  "-OperatorPresent",
  "-ConfirmMotionOff",
  "[string]`$PackageZip",
  "verify_release_package.ps1",
  "firmware/full_online/firmware.bin",
  "robot_firmware_package_mismatch",
  "runtime_manifest.json",
  "--conversation-v2",
  "--enable-initiative",
  "--room-observation",
  "--stt-server-url",
  "--redact-turn-text",
  "private_audio_evidence_enabled",
  "face_vision_worker_not_running",
  "robot_host_vision_never_advanced",
  "vision_service.pid",
  "minReplyWindows",
  "bridge-ai-supervised-session.v2"
)) {
  if (-not $StartText.Contains($Required)) {
    throw "Bridge AI qualification start script missing contract token: $Required"
  }
}
if ($StartText.Contains("Stop-Process") -or $StartText.Contains("/motion-resume") -or
    $StartText.Contains("/motion-stop")) {
  throw "Bridge AI qualification start must be passive and must not stop processes or control motion."
}

$CompleteText = Get-Content -LiteralPath $CompletePath -Raw
foreach ($Required in @(
  "ConfirmOneWakeMultiTurn",
  "ConfirmEchoFree",
  "ConfirmBargeInStoppedAudio",
  "ConfirmBridgeLossLocalRecovery",
  "ConfirmInitiativeIgnoredBackoff",
  "ConfirmInitiativeNightSuppressed",
  "ConfirmRoomOffCleared",
  "ConfirmNoFramePersisted",
  "after-runtime.json",
  "bridge_ai_qualification.py",
  "--require-ready"
)) {
  if (-not $CompleteText.Contains($Required)) {
    throw "Bridge AI qualification completion script missing contract token: $Required"
  }
}
if ($CompleteText.Contains("Stop-Process") -or $CompleteText.Contains("/motion-resume") -or
    $CompleteText.Contains("/motion-stop")) {
  throw "Bridge AI qualification completion must not stop processes or control motion."
}

Write-Host "Bridge AI supervised qualification contract tests passed."
