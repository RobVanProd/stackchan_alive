param()

$ErrorActionPreference = "Stop"

$repoRoot = Resolve-Path (Join-Path $PSScriptRoot "..")
$checkScript = Join-Path $PSScriptRoot "check_android_speech_evidence.ps1"
$createdRoots = New-Object System.Collections.Generic.List[string]
$sourceCommit = "abcdef1234567890abcdef1234567890abcdef12"

function New-TempEvidenceRoot {
  $root = Join-Path ([System.IO.Path]::GetTempPath()) ("stackchan-android-speech-contract-" + [guid]::NewGuid().ToString("N"))
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
  $Value | ConvertTo-Json -Depth 10 | Set-Content -Path $Path -Encoding UTF8
}

function Invoke-SpeechEvidenceCheck {
  param(
    [string]$EvidenceRoot,
    [string]$ExpectedSourceCommit = $sourceCommit,
    [switch]$RequireReady
  )

  $powerShellExe = (Get-Process -Id $PID).Path
  $arguments = @(
    "-NoProfile",
    "-ExecutionPolicy",
    "Bypass",
    "-File",
    $checkScript,
    "-DiagnosticsExportPath",
    (Join-Path $EvidenceRoot "ANDROID_DIAGNOSTICS_EXPORT.json"),
    "-LogcatPath",
    (Join-Path $EvidenceRoot "android_speech_logcat.txt"),
    "-RobotLogPath",
    (Join-Path $EvidenceRoot "robot_speech_serial.log"),
    "-ReviewPath",
    (Join-Path $EvidenceRoot "ANDROID_SPEECH_REVIEW.md"),
    "-SourceCommit",
    $ExpectedSourceCommit,
    "-Json"
  )
  if ($RequireReady) {
    $arguments += "-RequireReady"
  }

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

function New-ReadyDiagnostics {
  return [ordered]@{
    schema = "stackchan.android.diagnostics-export.v1"
    bridge = [ordered]@{
      last_message_type = "app_text_turn"
      text_turns_submitted = 1
      last_text_turn_present = $true
      robot_socket_connected = $true
    }
    robot = [ordered]@{
      connected = $true
    }
    privacy = [ordered]@{
      raw_audio_retention = "none"
      transcript_export = "last text turn redacted to presence only"
    }
  }
}

function Write-ReadySpeechEvidence {
  param(
    [string]$Root,
    [string]$ReviewSourceCommit = $sourceCommit,
    [switch]$LeakyTranscript,
    [switch]$MissingRobotResponse
  )

  $diagnostics = New-ReadyDiagnostics
  if ($LeakyTranscript) {
    $diagnostics.privacy.transcript_export = "raw transcript text exported"
  }
  Write-JsonFile -Path (Join-Path $Root "ANDROID_DIAGNOSTICS_EXPORT.json") -Value $diagnostics

  @"
stackchan_speech_evidence event=listening_start
stackchan_speech_evidence event=final_transcript transcript_present=1 transcript_redacted=1 raw_audio_retention=none
stackchan_speech_evidence event=submit_result accepted=1 seq_present=1 message_type=app_text_turn
"@ | Set-Content -Path (Join-Path $Root "android_speech_logcat.txt") -Encoding UTF8

  $robotText = if ($MissingRobotResponse) {
    "app_text_turn`nthinking"
  } else {
    "app_text_turn`nthinking`nresponse_start`naudio_stream_start`naudio_stream_end`nresponse_end"
  }
  $robotText | Set-Content -Path (Join-Path $Root "robot_speech_serial.log") -Encoding UTF8

  @"
# Android Push-To-Talk Speech Evidence Review

- Reviewer: Contract Test
- Review date: 2026-07-06
- Support decision: pass
- Android device: Pixel contract
- Android version: 15
- App version: 1.0.0
- Source commit: $ReviewSourceCommit
- Diagnostics export path: ANDROID_DIAGNOSTICS_EXPORT.json
- Logcat path: android_speech_logcat.txt
- Robot serial log path: robot_speech_serial.log
- Speech recognizer decision: pass
- Transcript submission decision: pass
- Robot response-frame decision: pass
- Privacy decision: pass
"@ | Set-Content -Path (Join-Path $Root "ANDROID_SPEECH_REVIEW.md") -Encoding UTF8
}

try {
  Set-Location $repoRoot

  $readyRoot = New-TempEvidenceRoot
  Write-ReadySpeechEvidence -Root $readyRoot
  $readyResult = Invoke-SpeechEvidenceCheck -EvidenceRoot $readyRoot -RequireReady
  if ([int]$readyResult.exitCode -ne 0) {
    throw "Expected complete Android speech evidence to pass. Output:`n$($readyResult.text)"
  }
  if ($readyResult.report.status -ne "android-speech-ready" -or $readyResult.report.sourceCommit -ne $sourceCommit -or $readyResult.report.expectedSourceCommit -ne $sourceCommit) {
    throw "Expected android-speech-ready with matching sourceCommit and expectedSourceCommit."
  }
  foreach ($id in @("speech-turn-present", "robot-connected", "raw-audio-retention", "transcript-export", "speech-logcat-markers", "speech-logcat-errors", "robot-response-frames", "speech-review", "speech-review-source-commit-match")) {
    Assert-CheckStatus -Report $readyResult.report -Id $id -Status "pass"
  }
  Write-Host "[ok] complete Android speech evidence is accepted"

  $missingRobotRoot = New-TempEvidenceRoot
  Write-ReadySpeechEvidence -Root $missingRobotRoot -MissingRobotResponse
  $missingRobotResult = Invoke-SpeechEvidenceCheck -EvidenceRoot $missingRobotRoot
  if ($missingRobotResult.report.status -ne "pending-android-speech-evidence") {
    throw "Expected missing robot response frames to keep speech evidence pending, got $($missingRobotResult.report.status)."
  }
  Assert-CheckStatus -Report $missingRobotResult.report -Id "robot-response-frames" -Status "pending"
  Write-Host "[ok] missing Android speech robot response frames remain pending"

  $privacyLeakRoot = New-TempEvidenceRoot
  Write-ReadySpeechEvidence -Root $privacyLeakRoot -LeakyTranscript
  $privacyLeakResult = Invoke-SpeechEvidenceCheck -EvidenceRoot $privacyLeakRoot -RequireReady
  if ([int]$privacyLeakResult.exitCode -eq 0) {
    throw "Expected Android speech diagnostics transcript privacy leak to fail."
  }
  Assert-CheckStatus -Report $privacyLeakResult.report -Id "transcript-export" -Status "fail"
  Write-Host "[ok] Android speech diagnostics transcript privacy leak is rejected"

  $staleReviewRoot = New-TempEvidenceRoot
  Write-ReadySpeechEvidence -Root $staleReviewRoot -ReviewSourceCommit ("b" * 40)
  $staleReviewResult = Invoke-SpeechEvidenceCheck -EvidenceRoot $staleReviewRoot -RequireReady
  if ([int]$staleReviewResult.exitCode -eq 0) {
    throw "Expected stale Android speech review source commit to fail."
  }
  Assert-CheckStatus -Report $staleReviewResult.report -Id "speech-review-source-commit-match" -Status "fail"
  Write-Host "[ok] stale Android speech review source commit is rejected"

  Write-Host "Android speech evidence contract tests passed."
} finally {
  foreach ($root in $createdRoots) {
    if (Test-Path -LiteralPath $root) {
      Remove-Item -LiteralPath $root -Recurse -Force
    }
  }
}
