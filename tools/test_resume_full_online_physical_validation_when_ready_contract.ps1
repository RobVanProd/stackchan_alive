$ErrorActionPreference = "Stop"

$RepoRoot = Resolve-Path (Join-Path $PSScriptRoot "..")
Set-Location $RepoRoot

function Write-Json {
  param([string]$Path, $Object)
  $Object | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $Path -Encoding UTF8
}

$tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("stackchan-full-online-resume-" + [guid]::NewGuid().ToString("N"))
$evidenceRoot = Join-Path $tempRoot "evidence"
$readyPath = Join-Path $tempRoot "READY.json"
$notReadyPath = Join-Path $tempRoot "NOT_READY.json"

try {
  New-Item -ItemType Directory -Force -Path $tempRoot | Out-Null
  Write-Json $readyPath ([ordered]@{
      schema = "stackchan.full-online-physical-session-readiness.v1"
      status = "full-online-physical-session-ready"
      readyForPhysicalSession = $true
      failed = 0
      pending = 0
    })
  Write-Json $notReadyPath ([ordered]@{
      schema = "stackchan.full-online-physical-session-readiness.v1"
      status = "full-online-physical-session-not-ready"
      readyForPhysicalSession = $false
      failed = 1
      pending = 0
    })

  $dryRunOutput = & "tools\resume_full_online_physical_validation_when_ready.ps1" `
    -EvidenceRoot $evidenceRoot `
    -ReadinessJsonPath $readyPath `
    -DeviceHost 192.168.1.238 `
    -Port COM4 `
    -OperatorPresent `
    -BodyClear `
    -ConfirmServoRisk `
    -DryRun `
    -Json
  if (-not $?) {
    throw "Expected guarded dry run to pass: $dryRunOutput"
  }
  $dryRun = $dryRunOutput | ConvertFrom-Json
  if ($dryRun.schema -ne "stackchan.full-online-physical-validation-resume.v1") {
    throw "Unexpected schema: $($dryRun.schema)."
  }
  if ($dryRun.status -ne "full-online-physical-validation-resume-dry-run-ready") {
    throw "Expected dry-run-ready, got $($dryRun.status)."
  }
  if ($dryRun.sessionCommand -notmatch "start_full_online_physical_validation_session.cmd" -or $dryRun.sessionCommand -notmatch "LoggerDebugOnly") {
    throw "Expected guided session command with LoggerDebugOnly, got $($dryRun.sessionCommand)."
  }
  foreach ($snippet in @("-SuggestedVoicePrompt", "hello stackchan", "-TurnLogFile", "turns.jsonl")) {
    if ($dryRun.sessionCommand -notmatch [regex]::Escape($snippet)) {
      throw "Expected guided session command to include $snippet."
    }
  }
  $statusRefresh = @($dryRun.steps | Where-Object { $_.id -eq "status-refresh" })[0]
  if ($null -eq $statusRefresh -or $statusRefresh.status -ne "pending" -or $statusRefresh.detail -notmatch "ReadinessJsonPath") {
    throw "Expected status refresh to be skipped when a readiness fixture is supplied."
  }
  foreach ($file in @("FULL_ONLINE_PHYSICAL_VALIDATION_RESUME.json", "FULL_ONLINE_PHYSICAL_VALIDATION_RESUME.md")) {
    if (-not (Test-Path -LiteralPath (Join-Path $evidenceRoot $file) -PathType Leaf)) {
      throw "Expected resume artifact $file."
    }
  }

  $missingSafetyOutput = & "tools\resume_full_online_physical_validation_when_ready.ps1" `
    -EvidenceRoot $evidenceRoot `
    -ReadinessJsonPath $readyPath `
    -DeviceHost 192.168.1.238 `
    -Port COM4 `
    -DryRun `
    -Json
  if ($?) {
    throw "Expected missing safety confirmations to fail."
  }
  $missingSafety = $missingSafetyOutput | ConvertFrom-Json
  if ($missingSafety.status -ne "full-online-physical-validation-resume-not-ready") {
    throw "Expected missing safety not-ready, got $($missingSafety.status)."
  }
  foreach ($id in @("operator-present", "body-clear", "servo-risk-confirmed")) {
    $step = @($missingSafety.steps | Where-Object { $_.id -eq $id })[0]
    if ($null -eq $step -or $step.status -ne "fail") {
      throw "Expected $id to fail when omitted."
    }
  }

  $notReadyOutput = & "tools\resume_full_online_physical_validation_when_ready.ps1" `
    -EvidenceRoot $evidenceRoot `
    -ReadinessJsonPath $notReadyPath `
    -DeviceHost 192.168.1.238 `
    -Port COM4 `
    -OperatorPresent `
    -BodyClear `
    -ConfirmServoRisk `
    -DryRun `
    -Json
  if ($?) {
    throw "Expected not-ready readiness report to fail."
  }
  $notReady = $notReadyOutput | ConvertFrom-Json
  if ($notReady.status -ne "full-online-physical-validation-resume-not-ready") {
    throw "Expected not-ready status, got $($notReady.status)."
  }
  $readyStep = @($notReady.steps | Where-Object { $_.id -eq "readiness-ready" })[0]
  if ($null -eq $readyStep -or $readyStep.status -ne "fail") {
    throw "Expected readiness-ready to fail for not-ready report."
  }

  $fullSerialOutput = & "tools\resume_full_online_physical_validation_when_ready.ps1" `
    -EvidenceRoot $evidenceRoot `
    -ReadinessJsonPath $readyPath `
    -DeviceHost 192.168.1.238 `
    -Port COM4 `
    -OperatorPresent `
    -BodyClear `
    -ConfirmServoRisk `
    -FullSerialLogger `
    -DryRun `
    -Json
  if (-not $?) {
    throw "Expected full-serial dry run to pass: $fullSerialOutput"
  }
  $fullSerial = $fullSerialOutput | ConvertFrom-Json
  if ($fullSerial.sessionCommand -match "LoggerDebugOnly") {
    throw "Full serial logger command should not include LoggerDebugOnly."
  }

  $reviewWithoutModeOutput = & "tools\resume_full_online_physical_validation_when_ready.ps1" `
    -EvidenceRoot $evidenceRoot `
    -ReadinessJsonPath $readyPath `
    -DeviceHost 192.168.1.238 `
    -Port COM4 `
    -OperatorPresent `
    -BodyClear `
    -ConfirmServoRisk `
    -ObservedTranscript "hello stackchan" `
    -DryRun `
    -Json
  if ($?) {
    throw "Expected review fields without CompleteReview to fail."
  }
  $reviewWithoutMode = $reviewWithoutModeOutput | ConvertFrom-Json
  $reviewModeStep = @($reviewWithoutMode.steps | Where-Object { $_.id -eq "review-mode" })[0]
  if ($null -eq $reviewModeStep -or $reviewModeStep.status -ne "fail") {
    throw "Expected review-mode to fail when review fields are supplied without CompleteReview."
  }

  $reviewDryRunOutput = & "tools\resume_full_online_physical_validation_when_ready.ps1" `
    -EvidenceRoot $evidenceRoot `
    -ReadinessJsonPath $readyPath `
    -DeviceHost 192.168.1.238 `
    -Port COM4 `
    -OperatorPresent `
    -BodyClear `
    -ConfirmServoRisk `
    -CompleteReview `
    -Operator "Rob" `
    -ExactSpokenPrompt "hello stackchan" `
    -ObservedTranscript "hello stackchan" `
    -ServoMotionObserved "pitch nodded once and stopped" `
    -SafeStopCommand "motion stop" `
    -ConfirmMicUplink `
    -ConfirmStt `
    -ConfirmSelectedVoice `
    -ConfirmVoiceMatch `
    -ConfirmServoControlled `
    -ConfirmSafeStop `
    -ConfirmNoServoRisk `
    -ConfirmNoAudioRisk `
    -DryRun `
    -Json
  if (-not $?) {
    throw "Expected review dry run to pass: $reviewDryRunOutput"
  }
  $reviewDryRun = $reviewDryRunOutput | ConvertFrom-Json
  if ($reviewDryRun.completeReview -ne $true) {
    throw "Expected completeReview=true in review dry run."
  }
  foreach ($snippet in @("-CompleteReview", "-ObservedTranscript", "hello stackchan", "-ConfirmMicUplink", "-ConfirmNoAudioRisk")) {
    if ($reviewDryRun.sessionCommand -notmatch [regex]::Escape($snippet)) {
      throw "Expected review dry-run command to include $snippet."
    }
  }
} finally {
  Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Host "Full-online physical validation resume contract tests passed."
