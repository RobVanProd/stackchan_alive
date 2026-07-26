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
  "[string]`$ExpectedFirmwareSha256",
  "[string]`$ExpectedFirmwareSourceCommit",
  "`$RequiredFirmwareBaselineCommit",
  "6d39af7605aa6a4dc88d137e03c344dbfc8f53ce",
  "verify_release_package.ps1",
  '$Archive.GetEntry("release_manifest.json")',
  '$Archive.GetEntry("./release_manifest.json")',
  "docs/FIRST_DEPLOY_STATUS.md",
  "git diff --quiet origin/main",
  "`$FirmwareInputPaths",
  "partitions_esp_sr_16.csv",
  "test/test_native_logic",
  "personas",
  "media/voice",
  "bridge/persona_pack.py",
  "tools/platformio_*.py",
  "Firmware build inputs must be clean",
  "requires firmware build inputs identical to origin/main",
  "git merge-base --is-ancestor",
  "accepted-main-firmware-status.md",
  "robot_firmware_accepted_main_mismatch",
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
  "bridge-ai-supervised-session.v3"
)) {
  if (-not $StartText.Contains($Required)) {
    throw "Bridge AI qualification start script missing contract token: $Required"
  }
}
if ($StartText.Contains("firmware/full_online/firmware.bin") -or
    $StartText.Contains("robot_firmware_package_mismatch")) {
  throw "Bridge AI qualification must not bind the accepted main firmware to the bridge package binary."
}
if ($StartText.Contains("Stop-Process") -or $StartText.Contains("/motion-resume") -or
    $StartText.Contains("/motion-stop")) {
  throw "Bridge AI qualification start must be passive and must not stop processes or control motion."
}

$CompleteText = Get-Content -LiteralPath $CompletePath -Raw
foreach ($Required in @(
  "ConfirmOneWakeMultiTurn",
  "ConfirmConversationNatural",
  "ConfirmEchoFree",
  "ConfirmBargeInStoppedAudio",
  "ConfirmBridgeLossLocalRecovery",
  "ConfirmResearchGrounded",
  "ConfirmVisualContextGrounded",
  "ConfirmGrayscaleLimitationTruthful",
  "ConfirmMemoryRecallAccurate",
  "ConfirmNoUnrelatedMemoryHijack",
  "ConfirmInitiativeIgnoredBackoff",
  "ConfirmInitiativeNightSuppressed",
  "ConfirmPersonNoticingGrounded",
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
