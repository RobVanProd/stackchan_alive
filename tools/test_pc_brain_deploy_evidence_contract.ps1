param()

$ErrorActionPreference = "Stop"

$repoRoot = Resolve-Path (Join-Path $PSScriptRoot "..")
$collectorPath = Join-Path $PSScriptRoot "collect_pc_brain_deploy_evidence.ps1"
$checkerPath = Join-Path $PSScriptRoot "check_pc_brain_deploy_evidence.ps1"
$tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("stackchan-pc-brain-deploy-contract-" + [guid]::NewGuid().ToString("N"))

function Write-JsonFile {
  param(
    [string]$Path,
    [object]$Value
  )
  $Value | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $Path -Encoding UTF8
}

function Copy-Value {
  param([object]$Value)
  return ($Value | ConvertTo-Json -Depth 12 | ConvertFrom-Json)
}

function Invoke-EvidenceCheck {
  param(
    [object]$Evidence,
    [string]$Name
  )
  $caseDir = Join-Path $tempRoot $Name
  New-Item -ItemType Directory -Force -Path $caseDir | Out-Null
  $jsonPath = Join-Path $caseDir "PC_BRAIN_DEPLOY_EVIDENCE.json"
  $markdownPath = Join-Path $caseDir "PC_BRAIN_DEPLOY_EVIDENCE.md"
  Write-JsonFile -Path $jsonPath -Value $Evidence
  @"
# Stackchan PC Brain Deploy Evidence

- Status: ``pass``
- Source commit: ``$($Evidence.sourceCommit)``
- Playback: starts=``2`` stops=``2`` completions=``2`` signals=``2``
- Playback payload: chunks=``8`` bytes=``32768`` errors=``0``
- Speaker sink: raw_ok=``8`` raw_failed=``0`` running=``False``
"@ | Set-Content -LiteralPath $markdownPath -Encoding UTF8

  $powerShellExe = (Get-Process -Id $PID).Path
  $oldErrorActionPreference = $ErrorActionPreference
  $ErrorActionPreference = "Continue"
  try {
    $output = & $powerShellExe -NoProfile -ExecutionPolicy Bypass -File $checkerPath `
      -EvidenceJsonPath $jsonPath -EvidenceMarkdownPath $markdownPath -RequireReady -Json 2>&1
    $exitCode = $LASTEXITCODE
  } finally {
    $ErrorActionPreference = $oldErrorActionPreference
  }
  $text = ($output | Out-String).Trim()
  $report = if ([string]::IsNullOrWhiteSpace($text)) { $null } else { $text | ConvertFrom-Json }
  return [pscustomobject]@{
    exitCode = $exitCode
    report = $report
    text = $text
  }
}

function Assert-CheckStatus {
  param(
    [object]$Result,
    [string]$Id,
    [string]$Status
  )
  $checks = @($Result.report.checks | Where-Object { $_.id -eq $Id })
  if ($checks.Count -ne 1) {
    throw "Expected exactly one '$Id' check, found $($checks.Count). Output:`n$($Result.text)"
  }
  if ($checks[0].status -ne $Status) {
    throw "Expected '$Id'=$Status, got $($checks[0].status). Detail: $($checks[0].detail)"
  }
}

try {
  New-Item -ItemType Directory -Force -Path $tempRoot | Out-Null
  Set-Location $repoRoot

  $collectorText = Get-Content -LiteralPath $collectorPath -Raw
  if (-not $collectorText.Contains('$DebugUri = "http://$DeviceHost`:$DebugPort/debug"')) {
    throw "Collector does not fetch the exact /debug route."
  }
  if ($collectorText.Contains('$DebugUri = "http://$DeviceHost`:$DebugPort/"')) {
    throw "Collector still contains the obsolete root status route."
  }
  if (-not $collectorText.Contains('"- Device debug: ``$DebugUri``"')) {
    throw "Collector Markdown does not record its exact /debug URI."
  }
  Write-Host "[ok] collector freezes the exact /debug route in capture and Markdown"

  foreach ($staticContractPath in @(
    (Join-Path $PSScriptRoot "check_companion_v1_readiness.ps1"),
    (Join-Path $PSScriptRoot "verify_release_package.ps1")
  )) {
    $staticContractText = Get-Content -LiteralPath $staticContractPath -Raw
    foreach ($marker in @("playback-started", "playback-completed", "playback-drained", "speaker-playback-chunks-match")) {
      if (-not $staticContractText.Contains($marker)) {
        throw "$staticContractPath does not preserve the current deploy evidence marker '$marker'."
      }
    }
    foreach ($collectorMarker in @(
      "device_debug_schema_invalid",
      "device_debug_route_invalid",
      "bridge_downlink_playback_not_started",
      "bridge_downlink_playback_not_completed",
      "bridge_downlink_playback_not_drained",
      "speaker_playback_chunk_mismatch"
    )) {
      if (-not $staticContractText.Contains($collectorMarker)) {
        throw "$staticContractPath does not preserve the current collector marker '$collectorMarker'."
      }
    }
  }
  Write-Host "[ok] readiness and release-package static contracts require current collector and checker markers"

  $productionCommand = '"C:\Python310\python.exe" bridge\lan_service.py --tts-command "python bridge\rvc_production_tts_client.py" --tts-voice stackchan-rvc-directml-v2 --runner-command "python bridge\ollama_stackchan_runner.py" --require-runner --in-process-directml-tts'
  $debug = [ordered]@{
    schema = "stackchan.bridge-debug.v1"
    debug_request_route = "debug"
    debug_request_result = "debug"
    wifi_connected = $true
    network_state = "connected"
    bridge_state = "ready"
    speaker_enabled = $true
    speaker_volume = 96
    audio_stream_active = $false
    bridge_downlink_playback_starts = 2
    bridge_downlink_playback_chunks = 8
    bridge_downlink_playback_bytes = 32768
    bridge_downlink_playback_stops = 2
    bridge_downlink_playback_awaiting_drain = $false
    bridge_downlink_playback_completion_pending = $false
    bridge_downlink_playback_completions = 2
    bridge_downlink_playback_completion_signals = 2
    bridge_downlink_playback_errors = 0
    speaker_stream_play_raw_ok = 8
    speaker_stream_play_raw_failed = 0
    speaker_stream_forced_stops = 0
    speaker_stream_orphan_stops = 0
    speaker_running = $false
    speaker_channel_state = 0
  }
  $evidence = [ordered]@{
    schema = "stackchan.pc-brain-deploy-evidence.v1"
    status = "pass"
    sourceCommit = "1362453cdd136b4a74297b045055a5114226b814"
    issues = @()
    pc_brain_process = [ordered]@{
      pid = 1234
      command_line = $productionCommand
    }
    device_debug = $debug
    tests = @()
  }

  $passing = Invoke-EvidenceCheck -Evidence $evidence -Name "passing-production-directml"
  if ($passing.exitCode -ne 0 -or $passing.report.status -ne "pc-brain-deploy-ready") {
    throw "Expected current production DirectML evidence without legacy counters to pass. Output:`n$($passing.text)"
  }
  foreach ($id in @(
    "pc-brain-command-tts",
    "debug-schema",
    "debug-route",
    "debug-result",
    "playback-started",
    "playback-completed",
    "playback-completion-signaled",
    "playback-drained",
    "speaker-playback-chunks-match",
    "speaker-playback-idle"
  )) {
    Assert-CheckStatus -Result $passing -Id $id -Status "pass"
  }
  Write-Host "[ok] current production DirectML command and current /debug telemetry pass without legacy fields"

  $selectedVoiceEvidence = Copy-Value $evidence
  $selectedVoiceEvidence.pc_brain_process.command_line = '"C:\Python310\python.exe" bridge\lan_service.py --tts-command "python bridge\selected_voice_tts.py" --runner-command "python bridge\ollama_stackchan_runner.py" --require-runner'
  $selectedVoice = Invoke-EvidenceCheck -Evidence $selectedVoiceEvidence -Name "passing-selected-voice-smoke"
  if ($selectedVoice.exitCode -ne 0) {
    throw "Expected exact selected-voice smoke command to remain accepted. Output:`n$($selectedVoice.text)"
  }
  Assert-CheckStatus -Result $selectedVoice -Id "pc-brain-command-tts" -Status "pass"
  Write-Host "[ok] exact selected-voice smoke command remains accepted"

  $missingModeEvidence = Copy-Value $evidence
  $missingModeEvidence.pc_brain_process.command_line = $productionCommand -replace " --in-process-directml-tts", ""
  $missingMode = Invoke-EvidenceCheck -Evidence $missingModeEvidence -Name "missing-directml-mode"
  if ($missingMode.exitCode -eq 0) { throw "Production TTS without --in-process-directml-tts unexpectedly passed." }
  Assert-CheckStatus -Result $missingMode -Id "pc-brain-command-tts" -Status "fail"
  Write-Host "[ok] production TTS without in-process DirectML mode is rejected"

  $spoofedTtsEvidence = Copy-Value $evidence
  $spoofedTtsEvidence.pc_brain_process.command_line = '"C:\Python310\python.exe" bridge\lan_service.py --tts-command "python bridge\unknown_tts.py" --tts-voice stackchan-rvc-directml-v2 --runner-command "python bridge\ollama_stackchan_runner.py" --require-runner --in-process-directml-tts --note ''--tts-command "python bridge\rvc_production_tts_client.py"'''
  $spoofedTts = Invoke-EvidenceCheck -Evidence $spoofedTtsEvidence -Name "spoofed-tts-substring"
  if ($spoofedTts.exitCode -eq 0) { throw "An allowed TTS filename outside --tts-command unexpectedly passed." }
  Assert-CheckStatus -Result $spoofedTts -Id "pc-brain-command-tts" -Status "fail"
  Write-Host "[ok] an allowed filename outside the exact --tts-command value cannot spoof the TTS gate"

  $rootRouteEvidence = Copy-Value $evidence
  $rootRouteEvidence.device_debug.schema = "stackchan.bridge-status.v1"
  $rootRouteEvidence.device_debug.debug_request_route = "root"
  $rootRouteEvidence.device_debug.debug_request_result = "status"
  $rootRoute = Invoke-EvidenceCheck -Evidence $rootRouteEvidence -Name "root-route"
  if ($rootRoute.exitCode -eq 0) { throw "Root status evidence unexpectedly passed as /debug evidence." }
  foreach ($id in @("debug-schema", "debug-route", "debug-result")) {
    Assert-CheckStatus -Result $rootRoute -Id $id -Status "fail"
  }
  Write-Host "[ok] root bridge-status evidence is rejected"

  $missingFieldEvidence = Copy-Value $evidence
  $missingFieldEvidence.device_debug.PSObject.Properties.Remove("bridge_downlink_playback_completions")
  $missingField = Invoke-EvidenceCheck -Evidence $missingFieldEvidence -Name "missing-required-field"
  if ($missingField.exitCode -eq 0) { throw "Missing required playback telemetry unexpectedly passed." }
  Assert-CheckStatus -Result $missingField -Id "device-debug-field-bridge_downlink_playback_completions" -Status "fail"
  Write-Host "[ok] missing required fields fail instead of defaulting to zero"

  $incompleteEvidence = Copy-Value $evidence
  $incompleteEvidence.device_debug.bridge_downlink_playback_completions = 0
  $incompleteEvidence.device_debug.bridge_downlink_playback_completion_signals = 0
  $incomplete = Invoke-EvidenceCheck -Evidence $incompleteEvidence -Name "incomplete-playback"
  if ($incomplete.exitCode -eq 0) { throw "Incomplete playback unexpectedly passed." }
  Assert-CheckStatus -Result $incomplete -Id "playback-completed" -Status "fail"
  Write-Host "[ok] incomplete playback is rejected"

  $errorEvidence = Copy-Value $evidence
  $errorEvidence.device_debug.bridge_downlink_playback_errors = 1
  $playbackError = Invoke-EvidenceCheck -Evidence $errorEvidence -Name "playback-error"
  if ($playbackError.exitCode -eq 0) { throw "Nonzero playback errors unexpectedly passed." }
  Assert-CheckStatus -Result $playbackError -Id "bridge_downlink_playback_errors" -Status "fail"
  Write-Host "[ok] explicit playback errors are rejected"

  $mismatchEvidence = Copy-Value $evidence
  $mismatchEvidence.device_debug.speaker_stream_play_raw_ok = 7
  $mismatch = Invoke-EvidenceCheck -Evidence $mismatchEvidence -Name "speaker-chunk-mismatch"
  if ($mismatch.exitCode -eq 0) { throw "Speaker/playback chunk mismatch unexpectedly passed." }
  Assert-CheckStatus -Result $mismatch -Id "speaker-playback-chunks-match" -Status "fail"
  Write-Host "[ok] speaker/playback chunk mismatch is rejected"

  Write-Host "PC Brain deploy evidence contract tests passed."
} finally {
  Set-Location $repoRoot
  if (Test-Path -LiteralPath $tempRoot) {
    $resolvedTempRoot = (Resolve-Path -LiteralPath $tempRoot).Path
    if ($resolvedTempRoot.StartsWith([System.IO.Path]::GetTempPath(), [System.StringComparison]::OrdinalIgnoreCase)) {
      Remove-Item -LiteralPath $resolvedTempRoot -Recurse -Force
    }
  }
}
